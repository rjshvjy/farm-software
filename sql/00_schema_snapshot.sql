-- https://github.com/rjshvjy/farm-software  ·  Supabase SQL editor
-- 00_schema_snapshot.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — the living schema document.
--
-- WHAT THIS IS
--   One read-only query producing ONE markdown document describing the whole
--   database as it exists RIGHT NOW: tables, columns, constraints, triggers,
--   views, every fn_* and trg_* function WITH ITS FULL BODY, current config
--   values, and the master-list inventory.
--
-- HOW TO USE IT
--   1. Paste into the Supabase SQL editor. Run.
--   2. One row, one column comes back. Click the cell, copy all of it.
--   3. Save it over  DB_SCHEMA_CURRENT.md  in the Claude project folder.
--   4. Repeat after every SQL file applied, or whenever unsure what is live.
--
-- WHY IT EXISTS
--   All_files_Combined_schema.sql went stale — files 05-10 were never folded
--   in — and was nearly trusted as current during the 19-07 build. A generated
--   snapshot cannot go stale the same way: regenerating it is one paste. This
--   REPLACES the combined file as the current-state document (§14). The
--   numbered files stay in GitHub as history; they carry the REASONING, which
--   no dump can.
--
--   Function bodies are included deliberately. The rules of this system live
--   inside fn_save_voucher and its siblings — a schema without them says what
--   the tables look like but not what the database refuses, which is the more
--   important half.
--
--   Master VALUES are deliberately excluded — 76 activities are data, not
--   schema. Only the list inventory appears: which lists exist, how many
--   active values, and which attribute columns each actually uses.
--   ONE EXCEPTION, added 21-07-2026: see the voucher-types note below.
--
--   FOUR SECTIONS ADDED 20-07-2026, and they DO name specific tables, which
--   every other section deliberately avoids. The exception is earned: these
--   four hold data that BEHAVES LIKE SCHEMA — change a row and the system's
--   rules change — and their absence blocked three separate diagnoses in one
--   day:
--
--     Chart of accounts   'is 1310 really debtors?' could not be answered from
--                         this document while writing file 14. It was inferred
--                         from a foreign key instead.
--     Posting rules       whether ON CREDIT maps sales to debtors is the single
--                         line deciding whether every credit sale posts to the
--                         right side. It had to become a smoke test.
--     Permissions         six roles, ten capabilities, and no way to see who
--                         holds what. The launcher (20-07) is the first thing
--                         that reads this table for any purpose other than
--                         refusing somebody.
--     RLS and grants      when v_party_kinds went unreadable through the API,
--                         neither its policies nor its privileges could be
--                         checked here. The cause turned out to be PostgREST's
--                         schema cache — but ruling out the database took an
--                         evening it should not have.
--
--   Their columns are still read generically where they can be: anything
--   beyond the few structural columns is picked up from the row itself, so a
--   column added next month appears without this file being touched.
--
--   Changes nothing. Safe to run at any time, any number of times.
--
-- ----------------------------------------------------------------------------
-- TWO CHANGES, 21-07-2026
-- ----------------------------------------------------------------------------
--   1. BUG FIX — the security section would not run at all.
--
--      pg_policy.polcmd is Postgres's internal "char" type, and
--          text || "char"
--      is ambiguous: 42725, operator is not unique. It fails at PARSE time,
--      so it failed whether or not any policy existed. It is now cast
--      explicitly and mapped to the same words the earlier snapshots show
--      (SELECT / INSERT / UPDATE / DELETE / ALL) rather than the raw letters
--      r / a / w / d / *, which nobody would recognise.
--
--      Worth recording: the snapshot of 20-07 renders 'read_all (SELECT)',
--      which this file as written could never have produced. So the file in
--      the repo had DRIFTED from the version that actually ran — the exact
--      failure mode §14 exists to prevent, in the tool meant to prevent it.
--      The lesson is the standing one: what ran is the truth, and the editor
--      copy must be pushed back to GitHub, not the other way round.
--
--   2. NEW SECTION — voucher types, listed in full.
--
--      The rule above says master VALUES are data, not schema, and it holds
--      for the 77 activities. VOUCHER_TYPE is the exception that earns the
--      same treatment as chart of accounts and posting rules: fn_save_voucher
--      BRANCHES on voucher_shape and voucher_direction, so changing one of
--      these six rows changes what the database demands and refuses. That is
--      the definition this file already uses for an earned exception.
--
--      It was blind on 21-07 while adding the DRAWINGS type: this document
--      said 'VOUCHER_TYPE 6 active | uses: voucher_direction, voucher_prefix,
--      voucher_shape' and nothing more — not which six, not which shapes, not
--      which prefixes were taken.
--
--      Six rows. Activities stay excluded.
--
-- WILL IT SURVIVE FUTURE PHASES?
--   Yes, by design. Every section reads the CATALOGUE, never a list of names:
--     - new tables, columns, constraints, triggers    -> appear automatically
--     - new views AND materialised views              -> both covered
--     - new functions or procedures under ANY name    -> covered; only
--       extension-owned ones (pgcrypto etc.) are excluded, via pg_depend
--     - new master attribute columns                  -> derived from the row
--       itself, not from a hardcoded column list
--     - new config rows                               -> appear automatically
--   So the journal tables and functions of §17.3, the asset register of §17.4
--   and anything in Stages B-D will show up without this file being touched.
--
--   TWO THINGS IT WILL NEVER TELL YOU, by nature:
--     1. WHY anything is the way it is. That lives in the numbered SQL files
--        and in the requirements document. A dump records decisions, never
--        reasons.
--     2. Anything outside the `public` schema. If a future phase adds one,
--        this query needs a line changed.
-- ============================================================================

with

tables_md as (
  select string_agg(t.section, E'\n\n' order by t.tbl) as md
  from (
    select c.table_name as tbl,
           '### ' || c.table_name || E'\n' ||
           coalesce('*' || obj_description(pc.oid) || '*' || E'\n', '') ||
           string_agg(
             '- `' || c.column_name || '` ' || c.data_type ||
             case when c.character_maximum_length is not null
                  then '(' || c.character_maximum_length || ')' else '' end ||
             case when c.is_nullable = 'NO' then ' NOT NULL' else '' end ||
             case when c.column_default is not null
                  then ' default ' || left(c.column_default, 60) else '' end ||
             coalesce('  -- ' || col_description(pc.oid, c.ordinal_position), ''),
             E'\n' order by c.ordinal_position) as section
    from information_schema.columns c
    join pg_class pc on pc.relname = c.table_name and pc.relkind in ('r','p')
    join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = 'public'
    where c.table_schema = 'public'
    group by c.table_name, pc.oid
  ) t
),

constraints_md as (
  select string_agg(
           '- **' || rel.relname || '** `' || con.conname || '` ' ||
           pg_get_constraintdef(con.oid),
           E'\n' order by rel.relname, con.conname) as md
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace and n.nspname = 'public'
  where con.contype in ('c','f','u','p')
    and rel.relkind in ('r','p')
),

triggers_md as (
  select string_agg(x.line, E'\n' order by x.tbl, x.trg) as md
  from (
    select t.event_object_table as tbl,
           t.trigger_name       as trg,
           '- **' || t.event_object_table || '** `' || t.trigger_name || '` ' ||
           string_agg(distinct t.event_manipulation, '/') || ' -> ' ||
           replace(min(t.action_statement), 'EXECUTE FUNCTION ', '') as line
    from information_schema.triggers t
    where t.trigger_schema = 'public'
    group by t.event_object_table, t.trigger_name
  ) x
),

views_md as (
  -- Both ordinary and MATERIALISED views. pg_views omits matviews entirely,
  -- so a report matview added in Stage C would silently vanish from this
  -- document without the union below.
  select string_agg(
           '### ' || x.nm || case when x.matv then '  *(materialised)*' else '' end || E'\n' ||
           coalesce('*' || obj_description(x.oid) || '*' || E'\n', '') ||
           '```sql' || E'\n' || trim(x.def) || E'\n```',
           E'\n\n' order by x.nm) as md
  from (
    select v.viewname as nm, v.definition as def, pc.oid, false as matv
      from pg_views v
      join pg_class pc on pc.relname = v.viewname
      join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = 'public'
     where v.schemaname = 'public'
    union all
    select m.matviewname, m.definition, pc.oid, true
      from pg_matviews m
      join pg_class pc on pc.relname = m.matviewname
      join pg_namespace pn on pn.oid = pc.relnamespace and pn.nspname = 'public'
     where m.schemaname = 'public'
  ) x
),

functions_md as (
  -- NO NAME FILTER, deliberately. Filtering to fn_%/trg_% was fragile: a
  -- function added later under any other name would vanish from this document
  -- silently, which is the worst way for a schema record to be wrong. Instead
  -- only EXTENSION-owned functions are excluded (pgcrypto and friends), which
  -- is what "not ours" actually means.
  select string_agg(
           '### ' || p.proname || '(' ||
           pg_get_function_identity_arguments(p.oid) || ')' || E'\n' ||
           coalesce('*' || obj_description(p.oid) || '*' || E'\n', '') ||
           '```sql' || E'\n' || pg_get_functiondef(p.oid) || E'\n```',
           E'\n\n' order by p.proname) as md
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.prokind in ('f','p')          -- functions AND procedures
    and not exists (
      select 1 from pg_depend d
       where d.objid = p.oid
         and d.classid = 'pg_proc'::regclass
         and d.deptype = 'e')           -- owned by an extension: not ours
),

config_md as (
  select string_agg(
           '- `' || c.key || '` = **' || c.value || '**' ||
           coalesce('  -- ' || left(c.description, 140), ''),
           E'\n' order by c.key) as md
  from config c
),

masters_md as (
  -- The attribute columns are DERIVED from the catalogue, not listed here.
  -- Hardcoding them meant an eleventh attribute column added later would be
  -- invisible in this document. Everything that is not structural bookkeeping
  -- counts as an attribute.
  select string_agg(x.line, E'\n' order by x.list_name) as md
  from (
    select mv.list_name as list_name,
           '- **' || mv.list_name || '** ' || count(*) || ' active' ||
           coalesce(' | uses: ' || (
             select string_agg(distinct kv.key, ', ')
             from master_values m2,
                  lateral jsonb_each_text(to_jsonb(m2)) kv
             where m2.list_name = mv.list_name
               and m2.active
               and kv.value is not null
               and kv.key not in ('list_name','code','label','active',
                                  'sort_order','notes','created_at')
           ), '') as line
    from master_values mv
    where mv.active
    group by mv.list_name
  ) x
),

voucher_types_md as (
  -- ADDED 21-07-2026. The one master list whose VALUES behave like schema:
  -- fn_save_voucher reads voucher_shape and voucher_direction off these rows
  -- and branches on them, so a change here changes what the database demands
  -- and what it refuses. Same earned exception as chart_of_accounts and
  -- posting_rules. Inactive rows are shown too — a deactivated voucher type
  -- still owns its prefix and its serial series, which matters when choosing
  -- a prefix for a new one.
  select string_agg(
           '- `' || mv.code || '` ' || mv.label ||
           '  | shape **' || coalesce(mv.voucher_shape, '(none)') || '**' ||
           '  | direction ' || coalesce(mv.voucher_direction, '(none)') ||
           '  | prefix `' || coalesce(mv.voucher_prefix, '(none)') || '`' ||
           case when not mv.active then '  **INACTIVE**' else '' end ||
           coalesce('  -- ' || left(mv.notes, 120), ''),
           E'\n' order by mv.code) as md
  from master_values mv
  where mv.list_name = 'VOUCHER_TYPE'
),

accounts_md as (
  -- Reference data that behaves like schema (§10.3). Provisional pending the
  -- CA, and every posting resolves to one of these codes.
  select string_agg(
           '- `' || a.account_code || '` ' || a.name ||
           '  *(' || a.account_type || ')*' ||
           case when not a.active then '  **INACTIVE**' else '' end ||
           coalesce('  | ' || x.attrs, ''),
           E'\n' order by a.account_code) as md
  from chart_of_accounts a
  left join lateral (
    -- extras read from the row, so a column added later shows up untouched
    select string_agg(kv.key || '=' || kv.value, ', ' order by kv.key) as attrs
    from jsonb_each_text(to_jsonb(a)) kv
    where kv.value is not null
      and kv.key not in ('account_code','name','account_type','active',
                         'created_at','notes','effective_from','effective_to')
  ) x on true
),

posting_rules_md as (
  -- The mapping that decides which account every line lands on. One wrong row
  -- here silently misposts everything matching it.
  select string_agg(
           '- **' || r.rule_kind || '** `' || r.match_code || '`' ||
           coalesce(' entity=' || r.match_entity, '') ||
           coalesce(' capex='  || r.match_capex,  '') ||
           ' -> out `' || r.account_out || '`' ||
           coalesce(' / in `' || r.account_in || '`', '') ||
           ' from ' || to_char(r.effective_from, 'DD/MM/YYYY') ||
           coalesce(' to ' || to_char(r.effective_to, 'DD/MM/YYYY'), '') ||
           coalesce('  -- ' || left(r.notes, 80), ''),
           E'\n' order by r.rule_kind, r.match_code, r.effective_from desc) as md
  from posting_rules r
),

permissions_md as (
  -- Who may do what. Read as a matrix: one line per capability, the roles
  -- that hold it listed. A capability nobody holds is a capability nobody can
  -- exercise, and that is worth seeing at a glance.
  select string_agg(
           '- `' || p.capability || '` — ' ||
           coalesce(string_agg_roles, '**nobody**'),
           E'\n' order by p.capability) as md
  from (
    select capability,
           string_agg(role, ', ' order by role) filter (where allowed) as string_agg_roles
    from permissions
    group by capability
  ) p
),

security_md as (
  -- RLS on/off per table, its policies, and which API roles may read what.
  -- Supabase exposes tables through PostgREST as anon and authenticated, so
  -- a missing grant and a restrictive policy look identical from the app.
  --
  -- 21-07-2026 FIX: pg_policy.polcmd is "char", and text || "char" is
  -- ambiguous (42725) — it failed at parse time, so this whole query would
  -- not run at all. Cast explicitly and spell the command out.
  select
    coalesce((
      select string_agg(
               '- **' || c.relname || '** RLS ' ||
               case when c.relrowsecurity then 'ENABLED' else 'disabled' end ||
               coalesce('  | policies: ' || (
                 select string_agg(
                          pol.polname || ' (' ||
                          case pol.polcmd::text
                            when 'r' then 'SELECT'
                            when 'a' then 'INSERT'
                            when 'w' then 'UPDATE'
                            when 'd' then 'DELETE'
                            when '*' then 'ALL'
                            else pol.polcmd::text
                          end || ')', ', ')
                 from pg_policy pol where pol.polrelid = c.oid), '') ||
               coalesce('  | select: ' || (
                 select string_agg(g.grantee, ', ' order by g.grantee)
                 from information_schema.role_table_grants g
                 where g.table_schema = 'public'
                   and g.table_name = c.relname
                   and g.privilege_type = 'SELECT'
                   and g.grantee in ('anon','authenticated')), '  | select: **none**'),
               E'\n' order by c.relname)
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
      where c.relkind in ('r','p','v','m')
    ), '_none_') as md
)

select
  '# DATABASE SCHEMA -- CURRENT STATE' || E'\n' ||
  'Generated ' || to_char(now() at time zone 'Asia/Kolkata',
                          'DD/MM/YYYY HH24:MI') || ' IST' || E'\n\n' ||
  'Regenerate with 00_schema_snapshot.sql after every SQL file applied.' || E'\n' ||
  'This REPLACES All_files_Combined_schema.sql as current state.' || E'\n' ||
  'The numbered SQL files in GitHub are history and reasoning; THIS is what is.' || E'\n\n' ||
  '## Tables' || E'\n\n' || coalesce((select md from tables_md), '_none_') || E'\n\n' ||
  '## Constraints' || E'\n\n' || coalesce((select md from constraints_md), '_none_') || E'\n\n' ||
  '## Triggers' || E'\n\n' || coalesce((select md from triggers_md), '_none_') || E'\n\n' ||
  '## Views' || E'\n\n' || coalesce((select md from views_md), '_none_') || E'\n\n' ||
  '## Functions and trigger functions' || E'\n\n' || coalesce((select md from functions_md), '_none_') || E'\n\n' ||
  '## Config' || E'\n\n' || coalesce((select md from config_md), '_none_') || E'\n\n' ||
  '## Master lists' || E'\n\n' || coalesce((select md from masters_md), '_none_') || E'\n\n' ||
  '## Voucher types' || E'\n\n' ||
  '*The one master list whose values behave like schema: fn_save_voucher branches on shape and direction.*' || E'\n\n' ||
  coalesce((select md from voucher_types_md), '_none_') || E'\n\n' ||
  '## Chart of accounts' || E'\n\n' || coalesce((select md from accounts_md), '_none_') || E'\n\n' ||
  '## Posting rules' || E'\n\n' || coalesce((select md from posting_rules_md), '_none_') || E'\n\n' ||
  '## Permissions — who may do what' || E'\n\n' || coalesce((select md from permissions_md), '_none_') || E'\n\n' ||
  '## Row-level security and API grants' || E'\n\n' || coalesce((select md from security_md), '_none_')
  as schema_markdown;
