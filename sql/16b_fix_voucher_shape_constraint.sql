-- ============================================================================
-- github.com/rjshvjy/farm-software · sql/16b_fix_voucher_shape_constraint.sql
-- ============================================================================
-- FILE 16b · CORRECTION TO FILE 16 · run BEFORE re-running file 17
-- Paste whole into the Supabase SQL editor.
--
-- WHAT WENT WRONG
-- ----------------------------------------------------------------------------
-- File 16 section 6 tried to widen the voucher_shape guard to admit the fifth
-- shape, DRAWINGS. It dropped a constraint named
--     master_values_voucher_shape_check
-- which does not exist. The real one, seeded by file 12, is
--     master_values_voucher_shape_chk        (_chk, not _check)
-- and it still allows only TRANSACTION / SETTLEMENT / TRANSFER / JOURNAL.
--
-- So file 16 left the estate with TWO constraints on the same column: the
-- real one (four shapes, still enforcing) and a redundant new one (five
-- shapes, never reached because the older one refuses first). File 17's
-- DRAWINGS insert was refused, and — the editor running the script as one
-- transaction — everything else in file 17 rolled back with it.
--
-- WHY IT HAPPENED, recorded per section 16.11 because it cost a run: the
-- constraint name was GUESSED from Postgres's default naming instead of read
-- from DB_SCHEMA_CURRENT's "## Constraints" section, which lists every one
-- with its exact name and full definition. Section 14's precedence rule
-- applies to constraint names exactly as it applies to function bodies and
-- column lists: the snapshot is authoritative for WHAT EXISTS, and a
-- plausible name is not evidence.
--
-- THIS FILE: removes the redundant constraint, replaces the real one, and
-- adopts the existing idiom rather than a second one.
-- ============================================================================


-- ============================================================================
-- 1 · remove file 16's redundant constraint
-- ----------------------------------------------------------------------------
-- Harmless but confusing: two constraints saying overlapping things about one
-- column is how a rule ends up enforced in two places and changed in one.
-- ============================================================================

alter table master_values
  drop constraint if exists master_values_voucher_shape_check;


-- ============================================================================
-- 2 · replace the real guard, widened to five shapes
-- ----------------------------------------------------------------------------
-- WHY THE GUARD EXISTS AT ALL (v3.2 section 16.28): fn_save_voucher branches
-- on voucher_shape read from the VOUCHER_TYPE master. Section 3H's rule is
-- that a list the CODE BRANCHES ON must be closed — a value with no branch
-- behind it would not error, it would fall through and save something wrong.
-- Adding a sixth shape one day is therefore two deliberate acts in one file:
-- extend this constraint AND write its branch.
--
-- THE FIVE SHAPES, each stated as what fn_save_voucher demands of it:
--   TRANSACTION  activity + farm + cost object required. Something happened on
--                the land, so the management dimensions attach (Part 0.5).
--                PURCHASE (PB), SALES (SI).
--   SETTLEMENT   party required; activity and every dimension REFUSED; credit
--                mode refused. A balance moved, nothing happened on the land
--                (section 16.15). PAYMENT (PV), RECEIPT (RV).
--   TRANSFER     pocket to pocket, paired and system-written. CONTRA (CV).
--   JOURNAL      both sides named explicitly, no pocket, must balance. Never
--                touches the flat table (section 13). JOURNAL (JV).
--   DRAWINGS     party + activity required; farm, block, cost object and qty
--                REFUSED; days and rate allowed; credit mode ALLOWED (a house
--                shop account is ordinary — the one difference from
--                SETTLEMENT); entity forced to PERSONAL by the function.
--                Dr 3020 Owner Drawings, Cr the pocket. DRAWINGS (DV).
--
-- IDIOM: matches the existing constraint exactly — (voucher_shape IS NULL) OR
-- (voucher_shape = ANY (...)). NULL stays legal because master_values is one
-- generic table and every list other than VOUCHER_TYPE leaves this column
-- empty. File 16's version keyed off list_name instead; same effect, but two
-- idioms for one job is how the next person gets confused.
-- ============================================================================

alter table master_values
  drop constraint if exists master_values_voucher_shape_chk;

alter table master_values
  add constraint master_values_voucher_shape_chk
  check (
    voucher_shape is null
    or voucher_shape = any (array[
         'TRANSACTION'::text,
         'SETTLEMENT'::text,
         'TRANSFER'::text,
         'JOURNAL'::text,
         'DRAWINGS'::text
       ])
  );

comment on constraint master_values_voucher_shape_chk on master_values is
  'The five shapes fn_save_voucher and its siblings branch on (v3.2 section '
  '16.28). A new shape = extend this constraint AND write its branch, '
  'deliberately, in one SQL file (section 3H).';


-- ============================================================================
-- 3 · verify
-- ----------------------------------------------------------------------------
-- Expected: redundant_gone = 0 · real_guard = 1 · admits_drawings = true
-- Then re-run file 17 whole; its own verify block reports the seeding.
-- ============================================================================

select 'redundant constraint gone (want 0)' as checked,
       count(*)::text as result
  from information_schema.check_constraints
 where constraint_name = 'master_values_voucher_shape_check'
union all
select 'real guard present (want 1)',
       count(*)::text
  from information_schema.check_constraints
 where constraint_name = 'master_values_voucher_shape_chk'
union all
select 'guard admits DRAWINGS (want true)',
       (check_clause like '%DRAWINGS%')::text
  from information_schema.check_constraints
 where constraint_name = 'master_values_voucher_shape_chk';

-- ============================================================================
-- END OF FILE 16b. Next: re-run sql/17_seed_v32_masters.sql unchanged, then
-- regenerate DB_SCHEMA_CURRENT.
-- ============================================================================
