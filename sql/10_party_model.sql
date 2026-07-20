-- https://github.com/rjshvjy/farm-software  ·  Supabase SQL editor
-- 10_party_model.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — file 10: one register of everyone.
--
-- RUN AFTER file 09. Idempotent: safe to run twice.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS
--
-- parties.kind was a hardcoded CHECK: ('SUPPLIER','CUSTOMER','BOTH'). That is a
-- trade taxonomy — people you buy from, people you sell to — and this estate
-- pays almost nobody who fits it. Counted from the v9 workbook's narrations:
--
--     labour / worker   1,821        institution (bank, EB, tax)   187
--     shop / supplier     599        salary / staff                 83
--     transport            79        mason, carpenter, electrician  58
--     driver               52        professional (auditor, vet)    38
--
-- The single largest class of beneficiary — daily labour, 1,821 rows — had no
-- honest value available. A tractor driver had to be filed as a SUPPLIER.
--
-- It was also the one list in the whole system frozen into DDL rather than held
-- in master_values, which §1.8 bans everywhere else. This file corrects that.
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES
--   1. master_values.group_code — a GENERIC grouping column. Serves PARTY_KIND
--      now (HOUSE COOK belongs to HOUSEHOLD) and the ACTIVITY rollup later
--      (WEED CUTTING belongs to WEED MANAGEMENT, §12). Built once, used twice.
--   2. master_values.default_entity — the usual BUSINESS/PERSONAL for a kind.
--      A list-specific attribute, same pattern as mode_kind for MODE and
--      required_unit for ACTIVITY.
--   3. PARTY_KIND seeded with 27 values in 6 groups, grounded in the counts
--      above rather than invented.
--   4. parties: the CHECK dropped, kind validated against the master by
--      trigger instead, and default_entity added.
--   5. Existing parties migrated: SUPPLIER and CUSTOMER keep their meaning,
--      BOTH becomes TRADER.
--   6. fn_party_upsert and the two master writers extended.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS FILE DELIBERATELY DOES *NOT* DO
--
--   No "affects debit or credit" attribute on a party. Direction is decided per
--   transaction by the money, never by who the person is. A daily labourer
--   normally receives — but returns an advance, and now he is paying. A
--   supplier taking back damaged goods becomes a receipt. Encoding direction on
--   the person is a rule that is wrong exactly when life is interesting.
--
--   No separate HR table. One register of humans, because two registries of the
--   same people always drift apart. When Muster arrives (§16.6), a worker's
--   extra attributes — usual rate, gender, skill — become columns on the party
--   or a satellite table keyed to party_code, never a second list of names.
--
--   default_entity does NOT drive entity. It PRE-FILLS it, and the accountant
--   overrides freely. The shopkeeper sells fertiliser (BUSINESS) and household
--   groceries (PERSONAL) — same party, both entities, routinely. The
--   transaction stays the authority; the party record only guesses well.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. GENERIC GROUPING ON MASTER VALUES
--
--    group_code is free text pointing at another code in the SAME list — a
--    parent value. Deliberately NOT a foreign key: masters are append-only and
--    a self-referencing FK would make seeding order matter and deletion
--    impossible. The grouping is for reporting; a dangling group is a reporting
--    oddity, not a corruption.
-- ---------------------------------------------------------------------------
alter table master_values
  add column if not exists group_code text;

comment on column master_values.group_code is
  'Optional parent value within the same list, for reporting rollups. PARTY_KIND: HOUSE COOK -> HOUSEHOLD. ACTIVITY (later): WEED CUTTING -> WEED MANAGEMENT. Free text by design, not an FK.';

alter table master_values
  add column if not exists default_entity text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'master_values_default_entity_chk') then
    alter table master_values
      add constraint master_values_default_entity_chk
      check (default_entity is null
             or default_entity in ('BUSINESS','PERSONAL','FUNDING'));
  end if;
end $$;

comment on column master_values.default_entity is
  'PARTY_KIND only: the entity a party of this kind usually belongs to. Pre-fills the entry screen; never enforces. Entity itself is a fixed three-way split (§1.3), so the literal list here is legitimate, not a hardcode.';


-- ---------------------------------------------------------------------------
-- 2. PARTY_KIND — the master list, with groups
--
--    The GROUP HEADERS are themselves rows, with group_code null. That keeps
--    one mechanism instead of two: a report groups by coalesce(group_code,
--    code), and masters admin edits headers and members through the same
--    screen. Headers are marked in notes so nobody picks one by mistake on a
--    voucher; the screen shows them as headings, not choices.
--
--    Values grounded in the workbook counts, not invented. Add freely as new
--    kinds of beneficiary appear — that is the entire point of moving this out
--    of a CHECK constraint.
-- ---------------------------------------------------------------------------
insert into master_values (list_name, code, label, group_code, default_entity, sort_order, notes) values
  -- group headers ----------------------------------------------------------
  ('PARTY_KIND','FARM LABOUR',  'Farm labour',        null, 'BUSINESS', 100, 'GROUP HEADER — not selectable on a voucher'),
  ('PARTY_KIND','HOUSEHOLD',    'Household',          null, 'PERSONAL', 200, 'GROUP HEADER — not selectable on a voucher'),
  ('PARTY_KIND','TRADE',        'Trade',              null, 'BUSINESS', 300, 'GROUP HEADER — not selectable on a voucher'),
  ('PARTY_KIND','INSTITUTION',  'Institution',        null, 'BUSINESS', 400, 'GROUP HEADER — not selectable on a voucher'),
  ('PARTY_KIND','PROFESSIONAL', 'Professional',       null, 'BUSINESS', 500, 'GROUP HEADER — not selectable on a voucher'),
  ('PARTY_KIND','OWNER GROUP',  'Owner and family',   null, 'FUNDING',  600, 'GROUP HEADER — not selectable on a voucher'),

  -- FARM LABOUR — 1,821 labour rows, 52 driver, 58 skilled -----------------
  ('PARTY_KIND','DAILY LABOUR',    'Daily labour',       'FARM LABOUR','BUSINESS',110,'The largest class of beneficiary on this estate'),
  ('PARTY_KIND','TRACTOR DRIVER',  'Tractor driver',     'FARM LABOUR','BUSINESS',120,null),
  ('PARTY_KIND','SPRAY MAN',       'Spray man',          'FARM LABOUR','BUSINESS',130,null),
  ('PARTY_KIND','TREE CUTTER',     'Tree cutter',        'FARM LABOUR','BUSINESS',140,null),
  ('PARTY_KIND','MASON',           'Mason',              'FARM LABOUR','BUSINESS',150,'Rates cluster near Rs.900 in the narrations'),
  ('PARTY_KIND','CARPENTER',       'Carpenter',          'FARM LABOUR','BUSINESS',160,null),
  ('PARTY_KIND','ELECTRICIAN',     'Electrician',        'FARM LABOUR','BUSINESS',170,null),
  ('PARTY_KIND','PLUMBER',         'Plumber',            'FARM LABOUR','BUSINESS',180,null),
  ('PARTY_KIND','CONTRACT LABOUR', 'Contract labour',    'FARM LABOUR','BUSINESS',190,'Paid per tree, per foot, per pit — not per day'),
  ('PARTY_KIND','FARM STAFF',      'Farm staff (salaried)','FARM LABOUR','BUSINESS',195,'Watchman, supervisor — monthly, not daily'),

  -- HOUSEHOLD ---------------------------------------------------------------
  ('PARTY_KIND','HOUSE COOK',    'House cook',       'HOUSEHOLD','PERSONAL',210,null),
  ('PARTY_KIND','HOUSE MAID',    'House maid',       'HOUSEHOLD','PERSONAL',220,null),
  ('PARTY_KIND','HOUSE GARDENER','House gardener',   'HOUSEHOLD','PERSONAL',230,null),
  ('PARTY_KIND','HOUSE DRIVER',  'House driver',     'HOUSEHOLD','PERSONAL',240,null),
  ('PARTY_KIND','HOUSE STAFF',   'Household staff',  'HOUSEHOLD','PERSONAL',250,'Anything household not listed above'),

  -- TRADE — 599 supplier rows, 79 transport --------------------------------
  ('PARTY_KIND','SUPPLIER',  'Supplier',  'TRADE','BUSINESS',310,'Goods and materials'),
  ('PARTY_KIND','CUSTOMER',  'Customer',  'TRADE','BUSINESS',320,'Buys produce'),
  ('PARTY_KIND','TRADER',    'Trader',    'TRADE','BUSINESS',330,'Both directions — replaces the old BOTH'),
  ('PARTY_KIND','TRANSPORT', 'Transport', 'TRADE','BUSINESS',340,'Lorry, tempo, auto hire'),

  -- INSTITUTION — 187 rows --------------------------------------------------
  ('PARTY_KIND','BANK',        'Bank',              'INSTITUTION','BUSINESS',410,null),
  ('PARTY_KIND','ELECTRICITY', 'Electricity board', 'INSTITUTION','BUSINESS',420,null),
  ('PARTY_KIND','INSURANCE',   'Insurance',         'INSTITUTION','BUSINESS',430,null),
  ('PARTY_KIND','GOVERNMENT',  'Government',        'INSTITUTION','BUSINESS',440,'Tax, licence, registration, subsidy'),

  -- PROFESSIONAL — 38 rows --------------------------------------------------
  ('PARTY_KIND','AUDITOR',    'Auditor',     'PROFESSIONAL','BUSINESS',510,null),
  ('PARTY_KIND','ADVOCATE',   'Advocate',    'PROFESSIONAL','BUSINESS',520,null),
  ('PARTY_KIND','VETERINARY', 'Veterinary',  'PROFESSIONAL','BUSINESS',530,null),
  ('PARTY_KIND','CONSULTANT', 'Consultant',  'PROFESSIONAL','BUSINESS',540,null),

  -- OWNER -------------------------------------------------------------------
  ('PARTY_KIND','OWNER',  'Owner',           'OWNER GROUP','FUNDING',610,'Money in or out of estate capital — FUNDING, never income (§13)'),
  ('PARTY_KIND','FAMILY', 'Family member',   'OWNER GROUP','PERSONAL',620,null),

  -- the escape hatch, same philosophy as ACTIVITY NOT LISTED (§5B) ----------
  ('PARTY_KIND','KIND NOT LISTED','Kind not listed', null, 'BUSINESS', 900,
   'Last resort. Review monthly: a kind used repeatedly should become its own value.')
on conflict (list_name, code) do nothing;


-- ---------------------------------------------------------------------------
-- 3. PARTIES — the CHECK dropped, the master made authoritative
--
--    A CHECK cannot reference another table, so validation moves to a trigger.
--    That is the right home anyway: the rule now lives beside the data it
--    guards, and a new kind added through masters admin is usable immediately
--    with no DDL.
-- ---------------------------------------------------------------------------

-- 3a. migrate BEFORE relaxing anything, so no row is ever unvalidated
update parties set kind = 'TRADER' where kind = 'BOTH';

-- 3b. drop the frozen list
alter table parties drop constraint if exists parties_kind_check;

-- 3c. default_entity on the person: the pre-fill, overridable on every line
alter table parties
  add column if not exists default_entity text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'parties_default_entity_chk') then
    alter table parties
      add constraint parties_default_entity_chk
      check (default_entity is null
             or default_entity in ('BUSINESS','PERSONAL','FUNDING'));
  end if;
end $$;

comment on column parties.default_entity is
  'Pre-fills the entity box when this party is chosen. NEVER enforces: the shopkeeper sells fertiliser (BUSINESS) and groceries (PERSONAL). Seeded from the kind at creation; the transaction always wins.';

comment on column parties.kind is
  'A PARTY_KIND master value. Was a hardcoded CHECK until file 10; now data, so a new kind of beneficiary is a row rather than a migration.';

-- 3d. backfill default_entity from the kind, where the kind knows
update parties p
   set default_entity = m.default_entity
  from master_values m
 where m.list_name = 'PARTY_KIND'
   and m.code = p.kind
   and p.default_entity is null;

-- 3e. validation by trigger, replacing the CHECK
create or replace function trg_party_kind_valid() returns trigger
language plpgsql as $$
begin
  if new.kind is null or trim(new.kind) = '' then
    raise exception 'A party needs a kind. See the PARTY_KIND master.';
  end if;
  if not exists (select 1 from master_values
                  where list_name = 'PARTY_KIND'
                    and code = new.kind
                    and active) then
    raise exception
      'Party kind "%" is not an active PARTY_KIND value. Add it in masters admin first.',
      new.kind;
  end if;
  -- A group header describes a family of kinds; it is not one itself.
  if exists (select 1 from master_values
              where list_name = 'PARTY_KIND' and code = new.kind
                and group_code is null
                and coalesce(notes,'') like 'GROUP HEADER%') then
    raise exception
      '"%" is a group heading, not a kind. Choose one of the kinds inside it.',
      new.kind;
  end if;
  return new;
end $$;

drop trigger if exists parties_kind_valid on parties;
create trigger parties_kind_valid
  before insert or update of kind on parties
  for each row execute function trg_party_kind_valid();


-- ---------------------------------------------------------------------------
-- 4. fn_party_upsert — REPLACED
--
--    Same contract as file 08: MASTER_APPEND is enough, so the accountant
--    creates a party inline mid-voucher without calling the owner. party_code
--    remains the stable identity and is never rewritten (§13 rename ban).
--
--    NEW: kind now defaults to DAILY LABOUR rather than BOTH. On this estate
--    that is right far more often than any trade value — 1,821 rows against
--    599. Defaults should match the common case, not the alphabet.
--    NEW: default_entity, taken from the kind when not supplied.
-- ---------------------------------------------------------------------------
create or replace function fn_party_upsert(
  p_code           text,
  p_name           text,
  p_kind           text default 'DAILY LABOUR',
  p_mobile         text default null,
  p_notes          text default null,
  p_default_entity text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code   text := upper(trim(p_code));
  v_kind   text := upper(trim(coalesce(p_kind, 'DAILY LABOUR')));
  v_entity text;
begin
  if not (fn_has_permission('MASTER_APPEND') or fn_has_permission('MASTER_MANAGE')) then
    raise exception 'You do not have permission to add parties';
  end if;

  if v_code = '' then
    raise exception 'A party needs a code';
  end if;
  if trim(coalesce(p_name,'')) = '' then
    raise exception 'A party needs a name';
  end if;

  -- the trigger will judge the kind too; this gives the friendlier message
  if not exists (select 1 from master_values
                  where list_name = 'PARTY_KIND' and code = v_kind and active) then
    raise exception
      'Party kind "%" is not an active PARTY_KIND value. Add it in masters admin first.',
      v_kind;
  end if;

  v_entity := coalesce(
    nullif(trim(coalesce(p_default_entity,'')), ''),
    (select default_entity from master_values
      where list_name = 'PARTY_KIND' and code = v_kind));

  insert into parties (party_code, name, kind, mobile, notes, default_entity, created_by)
  values (v_code, trim(p_name), v_kind, nullif(trim(coalesce(p_mobile,'')),''),
          nullif(trim(coalesce(p_notes,'')),''), v_entity, fn_actor_email())
  on conflict (party_code) do update set
    name           = excluded.name,
    kind           = excluded.kind,
    mobile         = coalesce(excluded.mobile, parties.mobile),
    notes          = coalesce(excluded.notes, parties.notes),
    default_entity = coalesce(excluded.default_entity, parties.default_entity);

  return v_code;
end $$;

comment on function fn_party_upsert(text,text,text,text,text,text) is
  'Create or update a party. MASTER_APPEND is enough — the accountant adds parties inline mid-voucher. party_code is never rewritten. Kind validated against the PARTY_KIND master (file 10).';


-- ---------------------------------------------------------------------------
-- 5. THE MASTER WRITERS — teach them the two new columns
--
--    Patch semantics unchanged: a key absent from p_attrs leaves its column
--    alone, so existing callers are unaffected.
-- ---------------------------------------------------------------------------
create or replace function fn_master_set_group(
  p_list   text,
  p_code   text,
  p_group  text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_require('MASTER_MANAGE');

  if not exists (select 1 from master_values
                  where list_name = p_list and code = p_code) then
    raise exception 'No such master value %/%', p_list, p_code;
  end if;

  -- the parent must live in the same list, and must not be the value itself
  if p_group is not null and trim(p_group) <> '' then
    if upper(trim(p_group)) = p_code then
      raise exception 'A value cannot be its own group';
    end if;
    if not exists (select 1 from master_values
                    where list_name = p_list and code = upper(trim(p_group))) then
      raise exception
        'Group "%" does not exist in list %. Create the heading first.',
        upper(trim(p_group)), p_list;
    end if;
  end if;

  update master_values
     set group_code = nullif(upper(trim(coalesce(p_group,''))), '')
   where list_name = p_list and code = p_code;
end $$;

comment on function fn_master_set_group(text,text,text) is
  'Set or clear a master value''s reporting group. Used by PARTY_KIND now and by the ACTIVITY rollup later (§12).';


-- ---------------------------------------------------------------------------
-- 6. v_party_kinds — what masters admin and the entry screen read
--
--    Group headers excluded: they are headings, never choices. The heading
--    label rides along so a screen can render an optgroup without a second
--    query.
-- ---------------------------------------------------------------------------
create or replace view v_party_kinds as
select v.code,
       v.label,
       v.group_code,
       coalesce(g.label, 'Other') as group_label,
       v.default_entity,
       v.sort_order,
       v.notes
  from master_values v
  left join master_values g
         on g.list_name = 'PARTY_KIND'
        and g.code      = v.group_code
 where v.list_name = 'PARTY_KIND'
   and v.active
   and coalesce(v.notes,'') not like 'GROUP HEADER%'
 order by v.sort_order;

comment on view v_party_kinds is
  'Selectable party kinds with their group heading and usual entity. Group headers filtered out — they are headings, not choices.';


-- ---------------------------------------------------------------------------
-- 7. v_parties_by_group — the payoff
--
--    "What did all household staff cost this year" becomes one query instead of
--    remembering which four kinds count as household.
-- ---------------------------------------------------------------------------
create or replace view v_parties_by_group as
select p.party_code,
       p.name,
       p.kind,
       coalesce(k.group_code, 'UNGROUPED') as kind_group,
       p.default_entity,
       p.status
  from parties p
  left join master_values k
         on k.list_name = 'PARTY_KIND' and k.code = p.kind;


-- ============================================================================
-- VERIFY — run this after, read the four rows
--
--   select 'kinds seeded' as check, count(*)::text as result from v_party_kinds
--   union all
--   select 'groups', count(distinct group_code)::text from v_party_kinds
--   union all
--   select 'parties migrated',
--          count(*) filter (where kind = 'BOTH')::text || ' left as BOTH (want 0)'
--     from parties
--   union all
--   select 'check dropped',
--          case when exists (select 1 from pg_constraint
--                             where conname = 'parties_kind_check')
--               then 'STILL THERE - rerun' else 'gone' end;
--
-- SMOKE TEST
--   1. select fn_party_upsert('SEMALAI','Semalai','TRACTOR DRIVER');
--      -> saves; default_entity becomes BUSINESS from the kind.
--   2. select fn_party_upsert('KUPPU','Kuppu','HOUSEHOLD');
--      -> REFUSED: that is a group heading, not a kind.
--   3. select fn_party_upsert('X','X','SHEPHERD');
--      -> REFUSED: not an active PARTY_KIND value, add it in masters admin.
--   4. select fn_party_upsert('LATHA','Latha','HOUSE COOK');
--      -> saves; default_entity becomes PERSONAL.
--
-- STILL TO DO IN THE SCREEN (not this file):
--   - the New party panel's Kind dropdown reads v_party_kinds, grouped by
--     group_label, instead of the three hardcoded options
--   - its default becomes DAILY LABOUR, not SUPPLIER
--   - choosing a party pre-fills the line's entity from default_entity
--
-- Then fold files 05-10 into All_files_Combined_schema.sql (§14: one
-- current-state file, not a chain of migrations). That file is now five
-- releases stale and should not be read as current.
-- ============================================================================
