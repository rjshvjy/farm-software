-- ============================================================================
-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 1 of 4 : FOUNDATIONS
-- Run first, in the Supabase SQL editor. Re-runnable (drops and recreates).
--
-- Contents: the fixed lists (documented once, here), master_values (all
-- dropdown lists), users, role_grants, permissions, config, row-id counters.
--
-- Spec references: Requirements v2.3 §1, §2, §3, §4, §13, §14.1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. FIXED LISTS — the ONLY lists not editable through any screen.
--    Everything else in this system is master data (§ working-style rule:
--    never hardcode a likely variable). These are fixed because CODE BRANCHES
--    on them: adding a value here without code to handle it produces silently
--    wrong numbers. Changing them = owner runs SQL, deliberately.
--
--    ENTITY        BUSINESS | PERSONAL | FUNDING                     (§1.3)
--    ENTRY TYPE    NORMAL | TRANSFER | REVERSAL | CORRECTION |
--                  MIGRATED | SAMPLE | OPENING                       (§2)
--    ROW STATUS    LIVE | SUPERSEDED | REVERSED | CANCELLED   (corrections)
--    ROLES         OWNER | ADMIN | ACCOUNTANT | ASSISTANT |
--                  AUDITOR | SUPERVISOR                       (agreed 18-07)
--    COST OBJECT TYPE  FINAL | SUPPORT | SERVICE POOL | NON-OPERATING (§3A)
--    ACCOUNT TYPE  ASSET | LIABILITY | CAPITAL | INCOME | EXPENSE  (§10.3)
--    CASHFLOW CLASS    O | I | F   (Operations/Investing/Financing) (§10.3)
--
--    They are enforced as CHECK constraints on the tables that carry them.
-- ---------------------------------------------------------------------------

-- Clean slate (safe: database is empty / sample-data phase only).
drop table if exists row_id_counters cascade;
drop table if exists config          cascade;
drop table if exists permissions     cascade;
drop table if exists role_grants     cascade;
drop table if exists app_users       cascade;
drop table if exists block_ownership cascade;
drop table if exists master_values   cascade;

-- ---------------------------------------------------------------------------
-- 1. MASTER_VALUES — one table for every dropdown list (agreed design).
--    code  = immutable internal key; ledger rows reference it; NEVER changes.
--    label = display text; freely editable (fixing a typo is safe).
--    §13's rename ban is enforced by a trigger below: UPDATE may not touch
--    code once the row exists. Deactivate hides from dropdowns; old rows
--    keep pointing at a valid code. Delete is allowed ONLY while unused
--    (enforced in the masters-admin function in file 4, not here).
--
--    Lists seeded below (from the v9 Masters / Script Masters tabs, verified
--    18-07-2026): FARM, BLOCK, COST_OBJECT, ACTIVITY, CAPEX_FLAG,
--    COST_NATURE, UNIT, MODE, FLAG_REASON, CORRECTION_CATEGORY,
--    LEGAL_ENTITY. New lists later = INSERT rows, no DDL.
--
--    Attribute columns are used by specific lists and NULL elsewhere:
--      cost_object_type / output_unit / sellable . . COST_OBJECT rows (§3A)
--      mode_kind / is_credit_mode  . . . . . . . . . MODE rows (§10.4)
--      parent_farm . . . . . . . . . . . . . . . . . BLOCK rows (block→farm)
--      required_unit . . . . . . . . . . . . . . . . ACTIVITY rows (§3F)
--      attributed_to . . . . . . . . . . . . . . . . FLAG_REASON rows (§3C)
-- ---------------------------------------------------------------------------
create table master_values (
  list_name        text        not null,
  code             text        not null,
  label            text        not null,
  active           boolean     not null default true,
  sort_order       integer     not null default 100,
  notes            text,
  -- list-specific attributes (documented above)
  cost_object_type text        check (cost_object_type in
                                 ('FINAL','SUPPORT','SERVICE POOL','NON-OPERATING')),
  output_unit      text,
  sellable         boolean,
  mode_kind        text        check (mode_kind in ('CASH','BANK','CREDIT','OWNER')),
  parent_farm      text,
  required_unit    text,
  attributed_to    text        check (attributed_to in
                                 ('SUPERVISOR','ACCOUNTANT','NOBODY','OWNER','UNASSIGNED')),
  created_at       timestamptz not null default now(),
  primary key (list_name, code)
);

comment on table master_values is
  'Every dropdown list in the system. code is immutable (rename ban, §13); label is editable.';

-- Rename ban, enforced in the database itself (§13, agreed design):
create or replace function trg_master_code_immutable() returns trigger
language plpgsql as $$
begin
  if new.list_name <> old.list_name or new.code <> old.code then
    raise exception 'Master codes are immutable (§13). Edit the label, or deactivate and add a new value.';
  end if;
  return new;
end $$;

create trigger master_code_immutable
  before update on master_values
  for each row execute function trg_master_code_immutable();

-- ---- Seeds: exact values from the v9 workbook (verified against the file) --

-- FARM (Masters col B)
insert into master_values (list_name, code, label, sort_order) values
 ('FARM','NTH','NTH',10), ('FARM','KPN','KPN',20), ('FARM','NPA','NPA',30),
 ('FARM','KLN','KLN',40), ('FARM','GENERAL','GENERAL',50), ('FARM','HOME','HOME',60);

-- BLOCK (Masters col C; parent farm from the Block register; acreage blank in
-- v9 — §8 cleanup task. Block acreage & effective-dated ownership live in
-- block_ownership below, not here, because they change over time (§4, §11).)
insert into master_values (list_name, code, label, parent_farm, sort_order) values
 ('BLOCK','YET TO ASSIGN','YET TO ASSIGN', null, 10),
 ('BLOCK','MADAKKADU','MADAKKADU', 'KPN', 20);  -- parent farm provisional: §12 parked (Madakkadu parent + survey)

-- COST_OBJECT (Masters col D + types from Script Masters A)
insert into master_values (list_name, code, label, cost_object_type, output_unit, sellable, sort_order, notes) values
 ('COST_OBJECT','LAND','LAND','SERVICE POOL','ACRE',false,10,'property upkeep; allocation optional'),
 ('COST_OBJECT','COCONUT','COCONUT','FINAL','NOS',true,20,null),
 ('COST_OBJECT','AMLA','AMLA','FINAL','KG',true,30,null),
 ('COST_OBJECT','GUAVA','GUAVA','FINAL','KG',true,40,null),
 ('COST_OBJECT','MANGO','MANGO','FINAL','KG',true,50,null),
 ('COST_OBJECT','SILK COTTON','SILK COTTON','FINAL','KG',true,60,null),
 ('COST_OBJECT','PADDY','PADDY','FINAL','KG',true,70,null),
 ('COST_OBJECT','GOAT','GOAT','FINAL','NOS',true,80,null),
 ('COST_OBJECT','COW','COW','FINAL','LITRE',true,90,'milk; dung is a by-product'),
 ('COST_OBJECT','FODDER','FODDER','SUPPORT','KG',false,100,'grown for cattle; transfers to COW'),
 ('COST_OBJECT','COMMON','COMMON','SERVICE POOL',null,false,110,'use sparingly — vagueness metric watches this'),
 ('COST_OBJECT','NA','NA','NON-OPERATING',null,false,120,'admin / funding / household rows');

-- ACTIVITY (Masters col E, all 76, in sheet order; required_unit seeded only
-- where §3F names it — owner fills the rest through masters admin)
insert into master_values (list_name, code, label, required_unit, sort_order) values
 ('ACTIVITY','WEEDICIDE SPRAY','WEEDICIDE SPRAY','ACRE',10),
 ('ACTIVITY','PESTICIDE SPRAY','PESTICIDE SPRAY','ACRE',20),
 ('ACTIVITY','WATER SOLUBLE FERTILIZER SPRAY','WATER SOLUBLE FERTILIZER SPRAY','ACRE',30),
 ('ACTIVITY','MANURING & FERTILIZER','MANURING & FERTILIZER','TREE',40),
 ('ACTIVITY','FERTILIZER APPLICATION','FERTILIZER APPLICATION','TREE',50),
 ('ACTIVITY','FERTILIZER ROOT APPLICATION','FERTILIZER ROOT APPLICATION','TREE',60),
 ('ACTIVITY','PAATHI TAKING','PAATHI TAKING',null,70),
 ('ACTIVITY','IRRIGATION','IRRIGATION',null,80),
 ('ACTIVITY','HOSE ROLLING','HOSE ROLLING',null,90),
 ('ACTIVITY','WEED PICKING','WEED PICKING',null,100),
 ('ACTIVITY','WEED CUTTING','WEED CUTTING',null,110),
 ('ACTIVITY','WEED SHIFTING FOR DESTROY','WEED SHIFTING FOR DESTROY',null,120),
 ('ACTIVITY','THORN CLEANING (MUL CHEDI)','THORN CLEANING (MUL CHEDI)',null,130),
 ('ACTIVITY','MATTAI PICKING','MATTAI PICKING',null,140),
 ('ACTIVITY','FRUIT PLUCKING / HARVEST','FRUIT PLUCKING / HARVEST',null,150),
 ('ACTIVITY','PLOUGHING','PLOUGHING','ACRE',160),
 ('ACTIVITY','SEEDS & SOWING','SEEDS & SOWING',null,170),
 ('ACTIVITY','PIT DIGGING & PLANTING','PIT DIGGING & PLANTING',null,180),
 ('ACTIVITY','PRUNING','PRUNING',null,190),
 ('ACTIVITY','IRRIGATION SETUP','IRRIGATION SETUP',null,200),
 ('ACTIVITY','FENCE VINE REMOVAL','FENCE VINE REMOVAL','FEET',210),
 ('ACTIVITY','FENCING WORK','FENCING WORK','FEET',220),
 ('ACTIVITY','STONE REMOVAL','STONE REMOVAL',null,230),
 ('ACTIVITY','LAND LEVELLING','LAND LEVELLING',null,240),
 ('ACTIVITY','POND DESILTING','POND DESILTING',null,250),
 ('ACTIVITY','VAIKAL DESILTING','VAIKAL DESILTING',null,260),
 ('ACTIVITY','TREE REMOVAL AROUND WELL/POND','TREE REMOVAL AROUND WELL/POND',null,270),
 ('ACTIVITY','BOREWELL','BOREWELL',null,280),
 ('ACTIVITY','WELL RENOVATION','WELL RENOVATION',null,290),
 ('ACTIVITY','SHED CONSTRUCTION','SHED CONSTRUCTION',null,300),
 ('ACTIVITY','BUILDING & PROPERTY REPAIRS','BUILDING & PROPERTY REPAIRS',null,310),
 ('ACTIVITY','REPAIRS & MAINTENANCE','REPAIRS & MAINTENANCE',null,320),
 ('ACTIVITY','ELECTRICITY','ELECTRICITY',null,330),
 ('ACTIVITY','TREE SALE','TREE SALE','NOS',340),
 ('ACTIVITY','SHEPHERD WAGES','SHEPHERD WAGES',null,350),
 ('ACTIVITY','THOLUVAM WAGES','THOLUVAM WAGES',null,360),
 ('ACTIVITY','MILKING WAGES','MILKING WAGES',null,370),
 ('ACTIVITY','FEED','FEED',null,380),
 ('ACTIVITY','VET & MEDICINE','VET & MEDICINE',null,390),
 ('ACTIVITY','LIVESTOCK GENERAL','LIVESTOCK GENERAL',null,400),
 ('ACTIVITY','WATCHMAN WAGES','WATCHMAN WAGES',null,410),
 ('ACTIVITY','STAFF SALARY','STAFF SALARY',null,420),
 ('ACTIVITY','DRIVER SALARY','DRIVER SALARY',null,430),
 ('ACTIVITY','LABOUR WELFARE','LABOUR WELFARE',null,440),
 ('ACTIVITY','OFFICE & ADMIN','OFFICE & ADMIN',null,450),
 ('ACTIVITY','GENERAL EXPENSES','GENERAL EXPENSES',null,460),
 ('ACTIVITY','FREIGHT','FREIGHT',null,470),
 ('ACTIVITY','TRAVEL & FUEL','TRAVEL & FUEL',null,480),
 ('ACTIVITY','VEHICLE & MACHINERY MAINTENANCE','VEHICLE & MACHINERY MAINTENANCE',null,490),
 ('ACTIVITY','EQUIPMENT / VEHICLE PURCHASE','EQUIPMENT / VEHICLE PURCHASE',null,500),
 ('ACTIVITY','PRODUCE SALE','PRODUCE SALE','KG',510),
 ('ACTIVITY','LIVESTOCK SALE','LIVESTOCK SALE','NOS',520),
 ('ACTIVITY','MILK SALE','MILK SALE','LITRE',530),
 ('ACTIVITY','LEASE RENT','LEASE RENT',null,540),
 ('ACTIVITY','PRODUCE CONSUMED AT HOME','PRODUCE CONSUMED AT HOME',null,550),
 ('ACTIVITY','MISC INCOME','MISC INCOME',null,560),
 ('ACTIVITY','OWNER CAPITAL / CURRENT A/C','OWNER CAPITAL / CURRENT A/C',null,570),
 ('ACTIVITY','BANK / CASH TRANSFER','BANK / CASH TRANSFER',null,580),
 ('ACTIVITY','STAFF ADVANCE GIVEN','STAFF ADVANCE GIVEN',null,590),
 ('ACTIVITY','STAFF ADVANCE DEDUCTED','STAFF ADVANCE DEDUCTED',null,600),
 ('ACTIVITY','ADVANCE RECEIVED','ADVANCE RECEIVED',null,610),
 ('ACTIVITY','HOUSEHOLD STAFF','HOUSEHOLD STAFF',null,620),
 ('ACTIVITY','KITCHEN & PROVISIONS','KITCHEN & PROVISIONS',null,630),
 ('ACTIVITY','UTILITIES','UTILITIES',null,640),
 ('ACTIVITY','VEHICLE-PERSONAL','VEHICLE-PERSONAL',null,650),
 ('ACTIVITY','MEDICAL','MEDICAL',null,660),
 ('ACTIVITY','EDUCATION','EDUCATION',null,670),
 ('ACTIVITY','FUNCTIONS, GIFTS & GUESTS','FUNCTIONS, GIFTS & GUESTS',null,680),
 ('ACTIVITY','RELIGIOUS & CHARITY','RELIGIOUS & CHARITY',null,690),
 ('ACTIVITY','CLOTHING & PERSONAL','CLOTHING & PERSONAL',null,700),
 ('ACTIVITY','TRAVEL-PERSONAL','TRAVEL-PERSONAL',null,710),
 ('ACTIVITY','HOUSE REPAIRS','HOUSE REPAIRS',null,720),
 ('ACTIVITY','PETS','PETS',null,730),
 ('ACTIVITY','PERSONAL MISC','PERSONAL MISC',null,740),
 ('ACTIVITY','UNCLASSIFIED','UNCLASSIFIED',null,750),
 ('ACTIVITY','FODDER CUTTING','FODDER CUTTING',null,760);

-- CAPEX_FLAG (Masters col F) — kept as a master per owner ruling (not enum)
insert into master_values (list_name, code, label, sort_order) values
 ('CAPEX_FLAG','RECURRING','RECURRING',10),
 ('CAPEX_FLAG','CAPITAL','CAPITAL',20);

-- COST_NATURE (Masters col G) — lookup, not enum (owner ruling)
insert into master_values (list_name, code, label, sort_order) values
 ('COST_NATURE','LABOUR','LABOUR',10), ('COST_NATURE','MATERIAL','MATERIAL',20),
 ('COST_NATURE','MACHINE HIRE','MACHINE HIRE',30), ('COST_NATURE','TRANSPORT','TRANSPORT',40),
 ('COST_NATURE','CONTRACT','CONTRACT',50), ('COST_NATURE','OTHER','OTHER',60);

-- UNIT (Masters col H)
insert into master_values (list_name, code, label, sort_order) values
 ('UNIT','FEET','FEET',10), ('UNIT','METRE','METRE',20), ('UNIT','ACRE','ACRE',30),
 ('UNIT','CENT','CENT',40), ('UNIT','TREE','TREE',50), ('UNIT','MANDAY','MANDAY',60),
 ('UNIT','HOUR','HOUR',70), ('UNIT','KG','KG',80), ('UNIT','LITRE','LITRE',90),
 ('UNIT','NOS','NOS',100), ('UNIT','LOAD','LOAD',110), ('UNIT','LUMPSUM','LUMPSUM',120);

-- MODE (Masters col I) + ON CREDIT added per §10.4.
-- mode_kind drives posting + bank rec: CASH pockets are counted (Cash Verify),
-- BANK pockets are reconciled, CREDIT raises a party balance, OWNER means the
-- owner paid directly (posts to owner current account, §1.3 FUNDING logic).
insert into master_values (list_name, code, label, mode_kind, sort_order, notes) values
 ('MODE','SUPERVISOR FLOAT','SUPERVISOR FLOAT','CASH',10,null),
 ('MODE','CASH','CASH','CASH',20,null),
 ('MODE','CANARA BANK','CANARA BANK','BANK',30,null),
 ('MODE','IOB BANK','IOB BANK','BANK',40,null),
 ('MODE','UPI','UPI','BANK',50,'UPI rides on a bank account; owner may relabel/split later'),
 ('MODE','MD DIRECT','MD DIRECT','OWNER',60,'owner paid directly = capital movement'),
 ('MODE','ON CREDIT','ON CREDIT','CREDIT',70,'added v2.3 §10.4; party mandatory');

-- FLAG_REASON (Script Masters C, verbatim, with automatic attribution)
insert into master_values (list_name, code, label, attributed_to, sort_order, notes) values
 ('FLAG_REASON','VOUCHER LATE','Voucher received late','SUPERVISOR',10,null),
 ('FLAG_REASON','QTY NOT WRITTEN','Voucher incomplete — qty not written','SUPERVISOR',20,'must be verifiable against the paper'),
 ('FLAG_REASON','DETAILS MISSING','Voucher incomplete — details missing','SUPERVISOR',30,null),
 ('FLAG_REASON','ILLEGIBLE','Voucher illegible / arithmetic wrong on paper','SUPERVISOR',40,null),
 ('FLAG_REASON','ENTRY DELAYED','Entry delayed by accountant','ACCOUNTANT',50,null),
 ('FLAG_REASON','ENTERED UNCHECKED','Entered without checking voucher','ACCOUNTANT',60,null),
 ('FLAG_REASON','NOT MEASURABLE','Measurement not possible for this work','NOBODY',70,'genuine; no-fault'),
 ('FLAG_REASON','NORM BREACH','Norm breach — cost genuinely higher (explained)','NOBODY',80,'genuine; note required'),
 ('FLAG_REASON','AWAITING OWNER','Awaiting clarification from owner / MD','OWNER',90,null),
 ('FLAG_REASON','OTHER','Other (note required)','UNASSIGNED',100,'owner reviews'),
 -- added for the v2.3 posting layer (suspense parking, agreed):
 ('FLAG_REASON','NO POSTING RULE','No posting rule — parked in Suspense','NOBODY',110,'clears when owner adds the mapping'),
 -- added for the correction model (paper-wrong case, agreed):
 ('FLAG_REASON','SLIP PENDING','Paper correction slip pending','SUPERVISOR',120,'entry passed on established fact; slip to be attached');

-- CORRECTION_CATEGORY — the ten-type taxonomy agreed in design discussion.
-- Codes are stable (functions branch on them); labels editable like any master.
insert into master_values (list_name, code, label, sort_order, notes) values
 ('CORRECTION_CATEGORY','AMOUNT TYPO','Amount typed wrong (paper correct)',10,'replace line'),
 ('CORRECTION_CATEGORY','RECLASSIFY','Wrong classification (farm/crop/activity/entity), money right',20,'replace line, amounts unchanged'),
 ('CORRECTION_CATEGORY','WRONG MODE','Wrong pocket (mode)',30,'replace line'),
 ('CORRECTION_CATEGORY','WRONG DATE','Wrong payment date',40,'replace line; reversal if true date in a closed period'),
 ('CORRECTION_CATEGORY','QTY AMEND','Qty / mandays wrong, money right',50,'replace line; no ledger effect'),
 ('CORRECTION_CATEGORY','PAPER WRONG','Paper voucher itself wrong; fact established by accountant',60,'replace line + correction slip on paper'),
 ('CORRECTION_CATEGORY','DUPLICATE','Same payment entered twice',70,'cancel the duplicate voucher'),
 ('CORRECTION_CATEGORY','FICTITIOUS','Voucher for something that never happened',80,'cancel voucher'),
 ('CORRECTION_CATEGORY','SAME DAY AMEND','Own typo, same day (§6 amend window)',90,'replace line, lighter logging'),
 ('CORRECTION_CATEGORY','POST LOCK REVERSAL','After period lock / Tally export',100,'reversal pair, §6');

-- LEGAL_ENTITY (Script Masters D — provisioned, populated later with CA, §11)
insert into master_values (list_name, code, label, sort_order) values
 ('LEGAL_ENTITY','UNASSIGNED','UNASSIGNED',10);

-- ---------------------------------------------------------------------------
-- 2. BLOCK_OWNERSHIP — effective-dated facts about blocks (§4, §11):
--    acreage and owning legal entity, from/to dated, superseded never deleted.
--    Empty now (v9 register is blank — §8 cleanup fills it).
-- ---------------------------------------------------------------------------
create table block_ownership (
  id                 bigint generated always as identity primary key, -- internal only, not a ledger row
  block_code         text  not null,
  farm_code          text  not null,
  acres              numeric(10,2),
  owner_legal_entity text  not null default 'UNASSIGNED',
  effective_from     date  not null,
  effective_to       date,           -- null = current
  notes              text,
  created_at         timestamptz not null default now()
);
-- Note: block_code / farm_code / owner_legal_entity cannot be plain foreign
-- keys — master_values has a composite key (list_name, code) and Postgres
-- cannot put the constant 'BLOCK' inside an FK. A validation trigger does the
-- same job (same pattern used for transactions in file 2):

create or replace function fn_assert_master(p_list text, p_code text) returns void
language plpgsql stable as $$
begin
  if p_code is null then return; end if;
  if not exists (select 1 from master_values
                 where list_name = p_list and code = p_code and active) then
    raise exception '% "%" is not an active value in masters', p_list, p_code;
  end if;
end $$;

create or replace function trg_block_ownership_check() returns trigger
language plpgsql as $$
begin
  perform fn_assert_master('BLOCK', new.block_code);
  perform fn_assert_master('FARM', new.farm_code);
  perform fn_assert_master('LEGAL_ENTITY', new.owner_legal_entity);
  return new;
end $$;

create trigger block_ownership_check
  before insert or update on block_ownership
  for each row execute function trg_block_ownership_check();

-- ---------------------------------------------------------------------------
-- 3. USERS and ROLES (§3E + agreed role model)
--    Identity = Gmail address. App refuses unknown/disabled accounts.
--    Roles fixed: OWNER, ADMIN, ACCOUNTANT, ASSISTANT, AUDITOR, SUPERVISOR.
--    ADMIN = everything OWNER can do EXCEPT: add/remove/disable an OWNER,
--    grant OWNER, or revoke their own ADMIN (enforced in file 4 functions).
--    Grants are effective-dated: "Admin for October" expires by itself (§4).
-- ---------------------------------------------------------------------------
create table app_users (
  email       text primary key,              -- the Gmail; exact match at sign-in
  full_name   text not null,
  mobile      text,                          -- contact only, not identity
  status      text not null default 'ACTIVE' check (status in ('ACTIVE','DISABLED')),
  created_at  timestamptz not null default now(),
  created_by  text
);

create table role_grants (
  id             bigint generated always as identity primary key,
  email          text not null references app_users(email),
  role           text not null check (role in
                   ('OWNER','ADMIN','ACCOUNTANT','ASSISTANT','AUDITOR','SUPERVISOR')),
  effective_from date not null default current_date,
  effective_to   date,                       -- null = open-ended
  granted_by     text not null,
  created_at     timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

-- ---------------------------------------------------------------------------
-- 4. PERMISSIONS — the role × capability grid as EDITABLE DATA (agreed).
--    Owner can tighten/loosen by updating rows. Three capabilities are
--    hard-wired in code regardless of this table (documented here):
--      USER_MANAGE, ROLE_GRANT        → OWNER always; ADMIN with the
--                                       owner-protection limits above
--      (PERIOD_CLOSE is grantable — ADMIN needs it to run the books)
-- ---------------------------------------------------------------------------
create table permissions (
  role       text not null check (role in
               ('OWNER','ADMIN','ACCOUNTANT','ASSISTANT','AUDITOR','SUPERVISOR')),
  capability text not null,
  allowed    boolean not null default true,
  primary key (role, capability)
);

insert into permissions (role, capability) values
 -- entry work. OWNER/ADMIN hold these capabilities too: the "owner does not
 -- enter vouchers" ruling is WORKING PRACTICE, not a lock — the mechanical
 -- protection is the self-audit refusal (a voucher you entered, you cannot
 -- tick). Owner needs entry rights for testing and emergencies.
 ('ACCOUNTANT','ENTER_VOUCHER'), ('ASSISTANT','ENTER_VOUCHER'),
 ('OWNER','ENTER_VOUCHER'), ('ADMIN','ENTER_VOUCHER'),
 ('ACCOUNTANT','CORRECT_LINE'),                    -- assistant may NOT correct (agreed)
 ('OWNER','CORRECT_LINE'), ('ADMIN','CORRECT_LINE'),
 ('ACCOUNTANT','REVERSE_LINE'), ('OWNER','REVERSE_LINE'), ('ADMIN','REVERSE_LINE'),
 ('ACCOUNTANT','CANCEL_VOUCHER'), ('OWNER','CANCEL_VOUCHER'), ('ADMIN','CANCEL_VOUCHER'),
 ('ACCOUNTANT','CLEANUP_QUEUE'), ('ASSISTANT','CLEANUP_QUEUE'),
 ('OWNER','CLEANUP_QUEUE'), ('ADMIN','CLEANUP_QUEUE'),
 ('ACCOUNTANT','MASTER_APPEND'),                   -- append only, never relabel (§13)
 -- audit
 ('AUDITOR','AUDIT_TICK'), ('OWNER','AUDIT_TICK'), ('ADMIN','AUDIT_TICK'),
 -- governance (owner + admin)
 ('OWNER','MASTER_MANAGE'), ('ADMIN','MASTER_MANAGE'),
 ('OWNER','COA_MANAGE'),    ('ADMIN','COA_MANAGE'),
 ('OWNER','POSTING_RULES_MANAGE'), ('ADMIN','POSTING_RULES_MANAGE'),
 ('OWNER','PERIOD_CLOSE'),  ('ADMIN','PERIOD_CLOSE'),
 ('OWNER','OPENING_BALANCES'), ('ADMIN','OPENING_BALANCES'),
 ('OWNER','CONFIG_MANAGE'), ('ADMIN','CONFIG_MANAGE'),
 ('OWNER','USER_MANAGE'),   ('ADMIN','USER_MANAGE'),   -- admin limits enforced in code
 ('OWNER','ROLE_GRANT'),    ('ADMIN','ROLE_GRANT'),    -- admin limits enforced in code
 -- reading (everyone signed-in and active can read reports; row-level detail
 -- differences are handled in views/RLS, file 4)
 ('OWNER','VIEW_REPORTS'), ('ADMIN','VIEW_REPORTS'), ('ACCOUNTANT','VIEW_REPORTS'),
 ('ASSISTANT','VIEW_REPORTS'), ('AUDITOR','VIEW_REPORTS'), ('SUPERVISOR','VIEW_REPORTS');

-- ---------------------------------------------------------------------------
-- 5. CONFIG (§4 / v9 Config tab). Key–value; owner/admin edit only.
--    CURRENT FY is NOT stored — it is derived from dates (a stored copy
--    would drift every April).
-- ---------------------------------------------------------------------------
create table config (
  key         text primary key,
  value       text not null,
  description text
);

insert into config (key, value, description) values
 ('CLOSED_UPTO',        '2026-03-31', 'No payment date on or before this (§4). Year-end needs nothing else (§10.2).'),
 ('OPEN_FROM',          '2026-04-01', 'Fat-finger floor: no payment date before this (§4).'),
 ('STALE_VOUCHER_DAYS', '7',          'Soft flag when payment date older than this at entry (§4).'),
 ('EMAIL_CYCLE_DAYS',   '15',         'Fortnightly exception report (§7).'),
 ('QTY_TARGET_PCT',     '60',         'Current qty-capture ratchet step: 60 → 80 → 95 (§7).'),
 ('ENTRY_LAG_TARGET',   '3',          'Median days payment→entry (§7).'),
 ('LIVE_MODE',          'SAMPLE',     'SAMPLE while building; LIVE after the final reset (§12). Save function stamps ENTRY TYPE=SAMPLE while SAMPLE.');

-- ---------------------------------------------------------------------------
-- 6. ROW-ID COUNTERS (§4): global, immutable, prefixed row ids.
--    H=history T=transactions J=jobs M=movements G=flags P=postings
--    C=corrections A=audit marks. Issued inside the save functions under
--    row lock — concurrency-safe, same mechanism as voucher serials.
-- ---------------------------------------------------------------------------
create table row_id_counters (
  prefix  text primary key,
  last_no bigint not null default 0
);
insert into row_id_counters (prefix) values
 ('H'),('T'),('J'),('M'),('G'),('P'),('C'),('A');

create or replace function fn_next_row_id(p_prefix text) returns text
language plpgsql as $$
declare v bigint;
begin
  update row_id_counters set last_no = last_no + 1
   where prefix = p_prefix returning last_no into v;
  if v is null then raise exception 'Unknown row-id prefix %', p_prefix; end if;
  return p_prefix || lpad(v::text, 6, '0');
end $$;

-- ============================================================================
-- End of file 1. Next: 02_entry_layer.sql
-- ============================================================================
