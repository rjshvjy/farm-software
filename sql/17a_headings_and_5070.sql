-- sql/17a_headings_and_5070.sql
-- github.com/rjshvjy/farm-software
--
-- FILE 17a — ACTIVITY GROUP HEADINGS, AND ACCOUNT 5070 SWITCHED OFF
-- 21 July 2026 · extends file 17 · must run BEFORE file 18
--
-- ============================================================================
-- WHY THIS FILE EXISTS
-- ============================================================================
--
-- File 17 put a group_code on all 77 ACTIVITY rows, by direct UPDATE. That
-- works, and the data is correct today. What does not work is managing those
-- groups from a masters admin screen, because fn_master_set_group refuses a
-- group that does not exist as a row in the same list:
--
--     'Group "%" does not exist in list %. Create the heading first.'
--
-- Owner ruling, 21/07: groups are managed through masters, not by typing
-- UPDATE statements. So the headings become real rows.
--
-- That creates a second problem. fn_assert_master accepts ANY active row in a
-- list. The moment HOUSEHOLD exists as an ACTIVITY row, it is a pickable
-- activity: it would appear in the supervisor's dropdown among the real ones,
-- the database would accept a wage line posted to it, no posting rule would
-- match, and the line would land in Suspense with a flag. A folder name is not
-- a piece of work.
--
-- So the list needs a way to say "this row is a heading, not a choice".
-- That is master_values.is_heading, added here. Dropdowns skip it; file 18
-- teaches fn_assert_master to refuse it, at the one choke point every
-- master-validated value already passes through (same discipline as file 12's
-- entity guard).
--
-- Separately: account 5070 Household Expenses is switched off. Under v3.2 the
-- household can never reach the P&L — it is Dr 3020 Drawings — so an EXPENSE
-- account named "Household Expenses" is a trapdoor waiting for whoever builds
-- the account picker. Nothing points at it today.
--
-- ============================================================================
-- WHAT THIS FILE DOES
-- ============================================================================
--
--   1. master_values.is_heading           new boolean column, default false
--   2. six ACTIVITY heading rows          DERIVED from the group_code values
--                                         file 17 already wrote — never typed
--                                         out here, so the spelling cannot
--                                         drift from what is in the database
--   3. chart_of_accounts 5070             active = false
--
-- ============================================================================
-- WHAT THIS FILE DOES NOT DO
-- ============================================================================
--
--   - It does not touch fn_assert_master. Refusing a heading at save time is
--     file 18's job, because file 18 is already replacing that call path and
--     two files editing one guard is how the 16 / 16b correction happened.
--   - It does not touch fn_save_voucher, fn_generate_postings or any screen.
--   - It does not re-run file 17's grouping. It reads it.
--
-- ============================================================================
-- HONEST LIMITATIONS
-- ============================================================================
--
--   - Deactivating 5070 ENFORCES NOTHING TODAY. Verified against the snapshot
--     of 21/07 15:37: fn_generate_postings reads chart_of_accounts only for
--     account_type, and nothing in the database reads .active at all. This is
--     a signpost for the account picker and masters admin when those are
--     built. It is not a lock.
--
--   - Headings stay active = true. Using active = false would make
--     fn_assert_master refuse them for free with no new column, but 'active'
--     means "a real value, now retired". Overloading it with "never was a
--     choice" would put six retired-looking activities in front of whoever
--     opens masters admin, and one of them will get switched back on.
--
--   - The heading rows are ACTIVITY rows, so ACTIVITY goes from 77 active to
--     83 active. Any count written down elsewhere as "77 activities" now
--     means "77 pickable activities, 6 headings". The verify block below
--     reports both numbers separately for exactly this reason.
--
-- ============================================================================
-- RUN ORDER
-- ============================================================================
--
--   file 17   (done, verified 21/07)
--   file 17a  (this file)          <- must be verified before 18 is written
--   file 18   (fn_save_voucher restructured for tasks)
--
-- ============================================================================


begin;


-- ----------------------------------------------------------------------------
-- 1. THE COLUMN
-- ----------------------------------------------------------------------------
-- NOT NULL with a default of false, so all 77 existing activity rows and every
-- row of every other list become "pickable" without being touched. Adding a
-- defaulted boolean does not rewrite the table on Postgres 11+.

alter table master_values
  add column if not exists is_heading boolean not null default false;

comment on column master_values.is_heading is
  'TRUE = this row is a group heading, not a selectable value. It exists so '
  'that group_code has something to point at and so fn_master_set_group can '
  'be used from masters admin. Headings are NEVER offered in an entry '
  'dropdown and are refused by fn_assert_master (file 18). Set from masters '
  'admin when a group is created; never inferred from the code. See file 17a.';


-- ----------------------------------------------------------------------------
-- 2. GUARD BEFORE INSERTING — a group name that is already a real activity
-- ----------------------------------------------------------------------------
-- If file 17 happened to use a group_code that is ALSO the code of a genuine
-- activity, inserting the heading would collide on the primary key
-- (list_name, code), and the only ways out are both wrong: skipping the
-- heading silently leaves fn_master_set_group broken for that group, and
-- flipping the existing row to is_heading = true would make a real activity
-- unpickable and orphan every transaction already posted to it.
--
-- That is an ambiguity only the owner can resolve, so the file refuses rather
-- than choosing. Re-running is safe: rows already marked as headings are
-- excluded, so the second run sees no collision.

do $$
declare
  v_clash text;
begin
  select string_agg(distinct a.group_code, ', ' order by a.group_code)
    into v_clash
    from master_values a
    join master_values b
      on b.list_name = 'ACTIVITY'
     and b.code      = a.group_code
     and b.is_heading = false          -- an existing REAL activity, not a heading
   where a.list_name = 'ACTIVITY'
     and a.group_code is not null;

  if v_clash is not null then
    raise exception
      'Refusing to create headings. These group codes are already real, '
      'pickable ACTIVITY values: %. A group heading and an activity cannot '
      'share a code (primary key is list_name + code). Rename the group with '
      'a direct UPDATE, or retire the activity, then re-run file 17a.',
      v_clash;
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 3. THE HEADING ROWS
-- ----------------------------------------------------------------------------
-- Derived, not typed. The snapshot excludes master values other than
-- VOUCHER_TYPE, so the exact spelling of each group is knowable only from the
-- database itself. Selecting the distinct group_code values guarantees the
-- headings match what file 17 wrote, character for character. Typing six
-- names here would be the file 16 constraint-name mistake in another costume.
--
-- label starts as the code. Codes are immutable (trg_master_code_immutable);
-- labels are not, so the owner can title-case them in masters admin later.
--
-- sort_order 1 only affects how masters admin lists them. Headings never
-- reach an entry dropdown, so it has no effect on entry.

insert into master_values (list_name, code, label, active, sort_order,
                           is_heading, notes)
select
  'ACTIVITY',
  a.group_code,
  a.group_code,
  true,
  1,
  true,
  'Group heading, created by file 17a. Not a selectable activity.'
from (
  select distinct group_code
    from master_values
   where list_name = 'ACTIVITY'
     and group_code is not null
     and is_heading = false
) a
on conflict (list_name, code) do nothing;


-- ----------------------------------------------------------------------------
-- 4. A HEADING MUST NOT ITSELF BE GROUPED
-- ----------------------------------------------------------------------------
-- One level of grouping is all §16.13 asks for, and fn_master_set_group
-- already refuses a value that is its own group. Belt and braces: the six new
-- rows carry no group_code, so no rollup can loop.

update master_values
   set group_code = null
 where list_name = 'ACTIVITY'
   and is_heading = true
   and group_code is not null;


-- ----------------------------------------------------------------------------
-- 5. ACCOUNT 5070 — HOUSEHOLD EXPENSES — SWITCHED OFF
-- ----------------------------------------------------------------------------
-- v3.2 §10.3: the P&L never sees a rupee of household spending. 5070 is an
-- EXPENSE account, so anything reaching it would appear in the P&L. Nothing
-- points at it: no posting rule references it, no activity resolves to it.
--
-- effective_to is set alongside active so the account has a stated end date
-- rather than a silent flag, matching how the chart already carries
-- effective_from on every row.

update chart_of_accounts
   set active       = false,
       effective_to = fn_today(),
       notes = trim(both ' ' from
                 coalesce(notes, '') ||
                 ' Deactivated 21/07/2026 (file 17a). Household spending is '
                 'owner drawings and posts to 3020; it can never be a P&L '
                 'expense (v3.2 sections 10.3, 20.1). Do not reactivate '
                 'without reopening that decision.')
 where account_code = '5070'
   and active = true;


commit;


-- ============================================================================
-- VERIFY — run this block on its own after the commit above succeeds.
-- Every row must read PASS. If any row reads FAIL, do not proceed to file 18.
-- ============================================================================

select check_name, expected, actual,
       case when expected = actual then 'PASS' else 'FAIL' end as result
from (

  -- the column exists
  select '1. is_heading column exists' as check_name,
         '1' as expected,
         count(*)::text as actual
    from information_schema.columns
   where table_schema = 'public'
     and table_name   = 'master_values'
     and column_name  = 'is_heading'

  union all

  -- nothing outside ACTIVITY was touched
  select '2. headings outside ACTIVITY',
         '0',
         count(*)::text
    from master_values
   where is_heading = true
     and list_name <> 'ACTIVITY'

  union all

  -- one heading per distinct group, and no more
  select '3. headings = distinct groups',
         (select count(distinct group_code)::text
            from master_values
           where list_name = 'ACTIVITY'
             and group_code is not null),
         (select count(*)::text
            from master_values
           where list_name = 'ACTIVITY'
             and is_heading = true)

  union all

  -- the 77 real activities are untouched and still pickable
  select '4. pickable activities still 77',
         '77',
         count(*)::text
    from master_values
   where list_name  = 'ACTIVITY'
     and is_heading = false
     and active     = true

  union all

  -- file 17''s grouping survived: nothing became ungrouped
  select '5. ungrouped activities',
         '0',
         count(*)::text
    from master_values
   where list_name  = 'ACTIVITY'
     and is_heading = false
     and active     = true
     and group_code is null

  union all

  -- every group_code now points at a heading row that really exists,
  -- which is the whole point of the file: fn_master_set_group will work
  select '6. group_codes with no heading',
         '0',
         count(*)::text
    from master_values a
   where a.list_name = 'ACTIVITY'
     and a.is_heading = false
     and a.group_code is not null
     and not exists (
           select 1 from master_values h
            where h.list_name  = 'ACTIVITY'
              and h.code       = a.group_code
              and h.is_heading = true)

  union all

  -- no heading is itself grouped
  select '7. headings carrying a group',
         '0',
         count(*)::text
    from master_values
   where list_name  = 'ACTIVITY'
     and is_heading = true
     and group_code is not null

  union all

  -- 5070 is off
  select '8. account 5070 inactive',
         '1',
         count(*)::text
    from chart_of_accounts
   where account_code = '5070'
     and active = false

  union all

  -- and nothing was ever posted to it, so switching it off strands no history
  select '9. ledger entries on 5070',
         '0',
         count(*)::text
    from ledger_entries
   where account_code = '5070'

  union all

  -- no other account was disturbed
  select '10. other inactive accounts',
         '0',
         count(*)::text
    from chart_of_accounts
   where active = false
     and account_code <> '5070'

) checks
order by check_name;


-- ============================================================================
-- AFTER THIS FILE
-- ============================================================================
--
-- Headings exist and are marked, but NOTHING REFUSES THEM YET. Between 17a and
-- 18 the six headings are pickable in the activity dropdown, exactly as
-- described in the WHY block above. LIVE_MODE = SAMPLE, so the exposure is a
-- disposable row, but file 18 should follow without a long gap.
--
-- File 18 adds, at the choke point:
--
--     if exists (select 1 from master_values
--                 where list_name = p_list and code = p_code and is_heading)
--     then raise exception '% "%" is a group heading, not a value you can
--                           choose.', p_list, p_code;
--     end if;
--
-- and the entry screens add "and is_heading = false" to the activity query.
--
-- Spec amendments owed once this is verified (draft as v3.3, never ahead of
-- the database): §3F gains the heading flag; §20.1's table row for cost
-- nature changes from "as on any other voucher" to optional on DRAWINGS;
-- §12's open-decisions list drops all three of the 21/07 rulings.
-- ============================================================================
