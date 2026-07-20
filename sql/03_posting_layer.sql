-- ============================================================================
-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 3 of 4 : POSTING LAYER (§10.3)
-- Run after 02_entry_layer.sql. Re-runnable.
--
-- The entry layer does not change; this sits beneath it. On save, every
-- transaction line generates two balanced ledger_entries rows through
-- mapping RULES — the accountant never chooses a debit and a credit.
-- P&L and all §7 metrics read the flat table; balance sheet and cash flow
-- read this layer; the two must agree continuously (§10.3).
--
-- The chart of accounts seeded here is PROVISIONAL (agreed): derived from
-- the v9 activity and mode lists, enough to make postings work, visibly
-- flagged so the CA's version supersedes it cleanly (§12 parked decision).
-- ============================================================================

drop table if exists ledger_entries    cascade;
drop table if exists posting_rules     cascade;
drop table if exists chart_of_accounts cascade;

-- ---------------------------------------------------------------------------
-- 1. CHART OF ACCOUNTS — editable master (owner ruling): add / relabel /
--    deactivate; never delete once used (enforced in the manage function,
--    file 4). Effective-dated. Every account carries type + cash-flow class,
--    which is what makes the cash flow statement mechanical (§10.3).
-- ---------------------------------------------------------------------------
create table chart_of_accounts (
  account_code   text primary key,           -- immutable once used (same rule as master codes)
  name           text not null,              -- editable label
  account_type   text not null check (account_type in
                   ('ASSET','LIABILITY','CAPITAL','INCOME','EXPENSE')),
  cashflow_class text not null default 'O' check (cashflow_class in ('O','I','F')),
  provisional    boolean not null default true,  -- true = my seed; CA's list flips this
  active         boolean not null default true,
  effective_from date not null default current_date,
  effective_to   date,
  notes          text
);

comment on table chart_of_accounts is
  'Balance-sheet backbone (§10.3). PROVISIONAL seed pending CA (§12). Owner-editable master.';

-- ---- Provisional seed -------------------------------------------------------
-- Assets (1xxx): one account per money pocket + control accounts
insert into chart_of_accounts (account_code, name, account_type, cashflow_class, notes) values
 ('1010','Cash — Supervisor Float','ASSET','O','pocket: MODE SUPERVISOR FLOAT'),
 ('1020','Cash in Hand','ASSET','O','pocket: MODE CASH'),
 ('1030','Canara Bank','ASSET','O','pocket: MODE CANARA BANK'),
 ('1040','IOB Bank','ASSET','O','pocket: MODE IOB BANK'),
 ('1050','UPI Pocket','ASSET','O','pocket: MODE UPI; owner may merge into a bank account later'),
 ('1210','Staff Advances','ASSET','O','washes to zero per worker (§10)'),
 ('1310','Sundry Debtors','ASSET','O','credit sales control (§10.4)'),
 ('1410','Stock of Inputs','ASSET','O','stock ledger control (§10.4, Stage C)'),
 ('1510','Fixed Assets','ASSET','I','provisional single block; CA will split'),
 ('1990','Suspense','ASSET','O','unmapped postings park here (agreed ruling 2); target balance zero');

-- Liabilities (2xxx)
insert into chart_of_accounts (account_code, name, account_type, cashflow_class, notes) values
 ('2010','Sundry Creditors','LIABILITY','O','credit purchases control (§10.4)'),
 ('2110','Advances Received','LIABILITY','O','ADVANCE RECEIVED activity'),
 ('2510','Loans Outstanding','LIABILITY','F','loan register control (§10.4, Stage C)');

-- Capital (3xxx) — §1.3: PERSONAL = drawings, FUNDING = capital movement
insert into chart_of_accounts (account_code, name, account_type, cashflow_class, notes) values
 ('3010','Owner Capital / Current A/c','CAPITAL','F','owner money in/out; MD DIRECT pocket posts here'),
 ('3020','Owner Drawings','CAPITAL','F','every PERSONAL-entity rupee lands here (§1.3)'),
 ('3910','Opening Balance Equity','CAPITAL','F','balancing account for ENTRY TYPE=OPENING (§10.2)');

-- Income (4xxx): one per income-side activity
insert into chart_of_accounts (account_code, name, account_type, notes) values
 ('4010','Produce Sale','INCOME','activity PRODUCE SALE'),
 ('4020','Livestock Sale','INCOME','activity LIVESTOCK SALE'),
 ('4030','Milk Sale','INCOME','activity MILK SALE'),
 ('4040','Tree Sale','INCOME','activity TREE SALE'),
 ('4050','Lease Rent','INCOME','activity LEASE RENT'),
 ('4060','Produce Consumed at Home','INCOME','transfer-priced (§9); parked decision §12'),
 ('4990','Misc Income','INCOME','activity MISC INCOME');

-- Expenses (5xxx): grouped provisional heads. Deliberately COARSER than the
-- 76 activities — the flat table keeps full activity detail for every farm
-- metric; the CoA only needs statement lines. CA will regroup.
insert into chart_of_accounts (account_code, name, account_type, notes) values
 ('5010','Cultivation Expenses','EXPENSE','sprays, fertilizer, irrigation, weeding, harvest…'),
 ('5020','Land & Property Upkeep','EXPENSE','fencing, desilting, levelling, building repairs…'),
 ('5030','Livestock Expenses','EXPENSE','feed, vet, shepherd/milking wages…'),
 ('5040','Salaries & Establishment','EXPENSE','staff/driver/watchman salary, welfare, office'),
 ('5050','Vehicle & Machinery','EXPENSE','fuel, maintenance, freight, machine hire'),
 ('5060','General Expenses','EXPENSE','general/misc/unclassified — vagueness metric watches this'),
 ('5070','Household Expenses','EXPENSE','NOT posted: PERSONAL rows go to 3020; head kept for CA discussion'),
 ('5510','Interest Expense','EXPENSE','loan register interest leg (§10.4, Stage C)');

-- ---------------------------------------------------------------------------
-- 2. POSTING RULES — what keeps the posting layer soft (agreed design).
--    Adding an activity = adding a mapping row here, not code.
--
--    Two rule kinds:
--      ACTIVITY : which account carries the activity side of the line.
--                 Optional narrower matches (entity / capex_flag) win over
--                 plain activity rules — specificity = count of non-null
--                 match columns; ties broken by newest effective_from.
--      MODE     : which account is the pocket. account_out when money leaves
--                 (DR rows), account_in when money arrives (CR rows) — the
--                 same account for normal modes, DIFFERENT for ON CREDIT
--                 (creditors when buying, debtors when selling).
--
--    Resolution (implemented in file 4's posting function):
--      1. entity = PERSONAL           → Owner Drawings (3020), always (§1.3)
--      2. best-match ACTIVITY rule    → that account
--      3. no rule                     → Suspense (1990) + flag (agreed ruling 2)
-- ---------------------------------------------------------------------------
create table posting_rules (
  rule_id        bigint generated always as identity primary key,
  rule_kind      text not null check (rule_kind in ('ACTIVITY','MODE')),
  match_code     text not null,              -- activity code or mode code
  match_entity   text check (match_entity in ('BUSINESS','PERSONAL','FUNDING')),
  match_capex    text,                       -- 'CAPITAL' to route capex to an asset account
  account_out    text not null references chart_of_accounts(account_code),
  account_in     text references chart_of_accounts(account_code), -- MODE rules only; null = same as out
  effective_from date not null default current_date,
  effective_to   date,
  notes          text
);

-- ---- MODE rules (one per mode; ON CREDIT splits out/in) --------------------
insert into posting_rules (rule_kind, match_code, account_out, account_in, notes) values
 ('MODE','SUPERVISOR FLOAT','1010',null,null),
 ('MODE','CASH','1020',null,null),
 ('MODE','CANARA BANK','1030',null,null),
 ('MODE','IOB BANK','1040',null,null),
 ('MODE','UPI','1050',null,null),
 ('MODE','MD DIRECT','3010','3010','owner paid/received directly = capital movement (§1.3)'),
 ('MODE','ON CREDIT','2010','1310','buy on credit → creditors; sell on credit → debtors');

-- ---- ACTIVITY rules (provisional; grouped to the 5xxx heads) ---------------
-- Income side
insert into posting_rules (rule_kind, match_code, account_out, notes) values
 ('ACTIVITY','PRODUCE SALE','4010',null),
 ('ACTIVITY','LIVESTOCK SALE','4020',null),
 ('ACTIVITY','MILK SALE','4030',null),
 ('ACTIVITY','TREE SALE','4040',null),
 ('ACTIVITY','LEASE RENT','4050',null),
 ('ACTIVITY','PRODUCE CONSUMED AT HOME','4060','parked §12; rule ready'),
 ('ACTIVITY','MISC INCOME','4990',null);

-- Funding / balance-sheet activities (§1.3: money movement, not cost)
insert into posting_rules (rule_kind, match_code, account_out, notes) values
 ('ACTIVITY','OWNER CAPITAL / CURRENT A/C','3010',null),
 ('ACTIVITY','BANK / CASH TRANSFER','1990','inter-mode transfers are written pairs (§10); each leg posts its own mode account against this bridge, which nets to zero per pair'),
 ('ACTIVITY','STAFF ADVANCE GIVEN','1210',null),
 ('ACTIVITY','STAFF ADVANCE DEDUCTED','1210','deduction credits the advance back'),
 ('ACTIVITY','ADVANCE RECEIVED','2110',null);

-- Capex routing: any CAPITAL-flagged line → Fixed Assets, whatever the activity
insert into posting_rules (rule_kind, match_code, match_capex, account_out, notes) values
 ('ACTIVITY','EQUIPMENT / VEHICLE PURCHASE', null, '1510','always an asset'),
 ('ACTIVITY','*', 'CAPITAL', '1510','wildcard: CAPEX FLAG=CAPITAL routes to Fixed Assets; specificity beats plain activity rules');

-- Expense groupings (every remaining activity → a 5xxx head)
insert into posting_rules (rule_kind, match_code, account_out) values
 ('ACTIVITY','WEEDICIDE SPRAY','5010'), ('ACTIVITY','PESTICIDE SPRAY','5010'),
 ('ACTIVITY','WATER SOLUBLE FERTILIZER SPRAY','5010'), ('ACTIVITY','MANURING & FERTILIZER','5010'),
 ('ACTIVITY','FERTILIZER APPLICATION','5010'), ('ACTIVITY','FERTILIZER ROOT APPLICATION','5010'),
 ('ACTIVITY','PAATHI TAKING','5010'), ('ACTIVITY','IRRIGATION','5010'),
 ('ACTIVITY','HOSE ROLLING','5010'), ('ACTIVITY','WEED PICKING','5010'),
 ('ACTIVITY','WEED CUTTING','5010'), ('ACTIVITY','WEED SHIFTING FOR DESTROY','5010'),
 ('ACTIVITY','THORN CLEANING (MUL CHEDI)','5010'), ('ACTIVITY','MATTAI PICKING','5010'),
 ('ACTIVITY','FRUIT PLUCKING / HARVEST','5010'), ('ACTIVITY','PLOUGHING','5010'),
 ('ACTIVITY','SEEDS & SOWING','5010'), ('ACTIVITY','PIT DIGGING & PLANTING','5010'),
 ('ACTIVITY','PRUNING','5010'), ('ACTIVITY','IRRIGATION SETUP','5010'),
 ('ACTIVITY','FODDER CUTTING','5010'),
 ('ACTIVITY','FENCE VINE REMOVAL','5020'), ('ACTIVITY','FENCING WORK','5020'),
 ('ACTIVITY','STONE REMOVAL','5020'), ('ACTIVITY','LAND LEVELLING','5020'),
 ('ACTIVITY','POND DESILTING','5020'), ('ACTIVITY','VAIKAL DESILTING','5020'),
 ('ACTIVITY','TREE REMOVAL AROUND WELL/POND','5020'), ('ACTIVITY','BOREWELL','5020'),
 ('ACTIVITY','WELL RENOVATION','5020'), ('ACTIVITY','SHED CONSTRUCTION','5020'),
 ('ACTIVITY','BUILDING & PROPERTY REPAIRS','5020'), ('ACTIVITY','REPAIRS & MAINTENANCE','5020'),
 ('ACTIVITY','ELECTRICITY','5020'),
 ('ACTIVITY','SHEPHERD WAGES','5030'), ('ACTIVITY','THOLUVAM WAGES','5030'),
 ('ACTIVITY','MILKING WAGES','5030'), ('ACTIVITY','FEED','5030'),
 ('ACTIVITY','VET & MEDICINE','5030'), ('ACTIVITY','LIVESTOCK GENERAL','5030'),
 ('ACTIVITY','WATCHMAN WAGES','5040'), ('ACTIVITY','STAFF SALARY','5040'),
 ('ACTIVITY','DRIVER SALARY','5040'), ('ACTIVITY','LABOUR WELFARE','5040'),
 ('ACTIVITY','OFFICE & ADMIN','5040'),
 ('ACTIVITY','FREIGHT','5050'), ('ACTIVITY','TRAVEL & FUEL','5050'),
 ('ACTIVITY','VEHICLE & MACHINERY MAINTENANCE','5050'),
 ('ACTIVITY','GENERAL EXPENSES','5060'), ('ACTIVITY','UNCLASSIFIED','5060'),
 -- household activities: normally caught by the PERSONAL→3020 precedence rule;
 -- mapped to 3020 too as a belt-and-braces default
 ('ACTIVITY','HOUSEHOLD STAFF','3020'), ('ACTIVITY','KITCHEN & PROVISIONS','3020'),
 ('ACTIVITY','UTILITIES','3020'), ('ACTIVITY','VEHICLE-PERSONAL','3020'),
 ('ACTIVITY','MEDICAL','3020'), ('ACTIVITY','EDUCATION','3020'),
 ('ACTIVITY','FUNCTIONS, GIFTS & GUESTS','3020'), ('ACTIVITY','RELIGIOUS & CHARITY','3020'),
 ('ACTIVITY','CLOTHING & PERSONAL','3020'), ('ACTIVITY','TRAVEL-PERSONAL','3020'),
 ('ACTIVITY','HOUSE REPAIRS','3020'), ('ACTIVITY','PETS','3020'),
 ('ACTIVITY','PERSONAL MISC','3020');

-- Seeded rules and accounts take effect from well before any date the book
-- can contain (prior-period vouchers, history import): a rule "from today"
-- would silently fail to match backdated lines — found in testing.
update posting_rules     set effective_from = date '2020-01-01';
update chart_of_accounts set effective_from = date '2020-01-01';

-- ---------------------------------------------------------------------------
-- 3. LEDGER_ENTRIES — generated, never hand-entered (§10.3). 'P' row ids.
--    Two+ rows per transaction line; per-line Dr = Cr enforced at generation
--    and checked continuously (view in file 4). Status mirrors the source:
--    superseding a line supersedes its postings and generates fresh ones.
-- ---------------------------------------------------------------------------
create table ledger_entries (
  posting_id   text primary key,             -- 'P000001'
  txn_row_id   text not null references transactions(row_id),
  account_code text not null references chart_of_accounts(account_code),
  dr           numeric(14,2) check (dr is null or dr > 0),
  cr           numeric(14,2) check (cr is null or cr > 0),
  payment_date date not null,                -- drives the cash flow statement (§10.4)
  accrual_date date not null,                -- drives P&L / balance sheet (§10: accrual)
  status       text not null default 'LIVE' check (status in ('LIVE','SUPERSEDED','REVERSED')),
  generated_at timestamptz not null default now(),
  check (num_nonnulls(dr, cr) = 1)
);

create index idx_le_txn     on ledger_entries (txn_row_id);
create index idx_le_account on ledger_entries (account_code, status);
create index idx_le_dates   on ledger_entries (accrual_date);

create trigger ledger_entries_guard
  before update or delete on ledger_entries
  for each row execute function trg_ledger_write_guard();

comment on table ledger_entries is
  'Posting layer (§10.3). System-writes only, via the save/correct functions. Balance sheet & cash flow read this; P&L and farm metrics read the flat table; the two must agree continuously.';

-- ============================================================================
-- End of file 3. Next: 04_functions_and_security.sql
-- ============================================================================
