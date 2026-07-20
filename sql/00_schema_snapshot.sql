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
--
--   Changes nothing. Safe to run at any time, any number of times.
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
  '## Master lists' || E'\n\n' || coalesce((select md from masters_md), '_none_')
  as schema_markdown;
