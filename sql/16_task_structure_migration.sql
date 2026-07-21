-- ============================================================================
-- github.com/rjshvjy/farm-software · sql/16_task_structure_migration.sql
-- ============================================================================
-- FILE 16 · THE TASK STRUCTURE MIGRATION · v3.2 §18.6 step 1
-- Paste whole into the Supabase SQL editor. Regenerate DB_SCHEMA_CURRENT after.
--
-- WHAT THIS FILE DOES, AGAINST THE GOLDEN RULES
-- ----------------------------------------------------------------------------
-- Nothing in this file moves a rupee, so nothing here has a debit or a credit.
-- Every change is IDENTITY or PRE-FILL data:
--
--   task_no        identity: WHICH numbered working on the paper a row came
--                  from. Same family as voucher_no and line_no beside it.
--   doc_ref_*      identity: WHICH physical paper produced this voucher.
--   parties.*      pre-fill: a person's usual category, rate and farm. These
--                  SUGGEST; the transaction decides (§16.13's rule).
--   jobs           an optional MIS grouping. Carries no money. Its cost is
--                  always a view over transactions, never a stored figure.
--   shape guard    protects the function that DOES apply the golden rules:
--                  fn_save_voucher branches on voucher_shape, and a typo'd
--                  shape must fail at insert, not fall through at save.
--
-- Everything is additive. No existing column changes meaning. Sample data
-- (LIVE_MODE = SAMPLE) is unaffected: task_no defaults to 1 on old rows,
-- which is true — each old voucher line was its own single task.
-- ============================================================================


-- ============================================================================
-- 1 · transactions.task_no  — which piece of work this row belongs to
-- ----------------------------------------------------------------------------
-- WHY IT EXISTS (v3.2 §16.24): the weekly wage paper is one payment covering
-- ~13 distinct pieces of work, each with several people under it. One flat-
-- table row = one person on one piece of work (§19). Without this column, two
-- rows of one task are indistinguishable from two unrelated rows, and the work
-- quantity — written ONCE per task, on its first row, so acres never multiply
-- by heads — sits on one row for no visible reason.
--
-- WHY NOT DERIVED from farm+block+activity: irrigating the same plot twice in
-- one week on one voucher would silently read as one task. §16.24.
--
-- HOW IT CONNECTS: numbered 1..n within each voucher, matching the numbers the
-- supervisor already writes on the back of the paper. DEFAULT 1 means every
-- other voucher type (sales, receipt, payment, drawings) has exactly one task
-- and never thinks about it. fn_save_voucher (file 17+) assigns it; screens
-- group by it; the future cost-per-task report reads it.
-- ============================================================================

alter table transactions
  add column if not exists task_no integer not null default 1;

comment on column transactions.task_no is
  'Which numbered working on the paper this row belongs to (v3.2 §16.24). '
  'Numbered from 1 within each voucher. Rows sharing a task_no are one piece '
  'of work; the FIRST row of a task carries the work quantity, the rest hold '
  'null there so the qty column stays summable. Default 1 = single-task '
  'voucher, true of every non-expense voucher type.';


-- ============================================================================
-- 2 · history.task_no — the empty twin stays a twin
-- ----------------------------------------------------------------------------
-- WHY: §13 — history is the column-for-column twin of transactions for the
-- optional legacy import. A column added to one and not the other breaks the
-- union view the day the import happens. history already carries job_id for
-- the same reason.
-- ============================================================================

alter table history
  add column if not exists task_no integer not null default 1;

comment on column history.task_no is
  'Twin of transactions.task_no (§13: the two tables stay column-for-column). '
  'Legacy rows import as single-task vouchers, task_no 1.';


-- ============================================================================
-- 3 · vouchers.doc_ref_no / doc_ref_date — the paper names the system,
--     the system names the paper
-- ----------------------------------------------------------------------------
-- WHY THEY EXIST (v3.1 §2): §4 already sends one half of the link — the system
-- voucher number written back on the paper in pen is the "accounted" stamp.
-- These two columns are the RETURN half: from a screen entry, an auditor can
-- pull the exact slip that produced it. One paper = one voucher (§16.27 item
-- 3), so this belongs on the voucher header, not on 40 rows.
--
-- WHY OPTIONAL AND NEVER VALIDATED: the paper's own numbering carries no
-- meaning here (§4 — old voucher books are harmless). This is a finding aid,
-- not an identifier. Blank is always legal.
--
-- WHY ON vouchers AND NOT transactions: it is a fact about the slip as a
-- whole, and vouchers is the thin control table that holds exactly those
-- facts (§2). On the lines it would repeat ~40 times and invite disagreement.
-- ============================================================================

alter table vouchers
  add column if not exists doc_ref_no   text,
  add column if not exists doc_ref_date date;

comment on column vouchers.doc_ref_no is
  'The paper voucher''s own reference number, if it has one (v3.1 §2). '
  'Optional, audit finding-aid only, never validated. The other half of the '
  'paper<->system link whose first half is §4''s pen-written system number.';

comment on column vouchers.doc_ref_date is
  'The date printed/written on the paper voucher itself. Optional. Distinct '
  'from payment_date on the lines: this identifies the DOCUMENT, that drives '
  'the ACCOUNTING.';


-- ============================================================================
-- 4 · parties: labour_category, default_rate, usual_farm
-- ----------------------------------------------------------------------------
-- WHY HERE AND NOT A NEW TABLE (§16.13, §16.26): one register of humans.
-- HR Master is NOT built as a table — a second registry of the same people
-- always drifts from the first. A labourer who takes an advance is already a
-- party with a control account; these columns complete the picture.
--
-- WHY EACH ONE EXISTS:
--   labour_category  §16.6: rates cluster by category (men Rs.450/400, women
--                    Rs.220 on the 13/07/2026 paper) and the category list is
--                    open-ended — so it lives on the person, NEVER on the
--                    transaction. Validated against the LABOUR_CATEGORY
--                    master (file 17) by the screen; free here because
--                    masters are data, not DDL (§1.9).
--   default_rate     pre-fills the rate box when this person is picked on a
--                    wage row (§19.2). PRE-FILL, NEVER ENFORCE — the day
--                    someone is paid differently is a fact about that day,
--                    and the typed rate always wins.
--   usual_farm       pre-fills/filters. Same rule: suggests, never decides.
--
-- HOW THEY CONNECT: the §19 row picks a party -> rate box fills from
-- default_rate -> accountant overrides or accepts -> the ROW stores what was
-- actually paid. Reports join transactions.party_code back to these columns,
-- so "how many women-days" is answerable without a category column on 4,000
-- rows (§12, settled 21-07).
-- ============================================================================

alter table parties
  add column if not exists labour_category text,
  add column if not exists default_rate    numeric,
  add column if not exists usual_farm      text;

comment on column parties.labour_category is
  'Category of labour this person usually supplies (LABOUR_CATEGORY master). '
  'Lives on the person, never on the transaction (§16.6). Null for parties '
  'who are not labour.';

comment on column parties.default_rate is
  'Usual daily/piece rate in Rs. Pre-fills the rate box when this party is '
  'picked on a wage row (§19.2). Never enforced; the typed rate wins.';

comment on column parties.usual_farm is
  'Farm this person usually works on (FARM master). Pre-fill only.';


-- ============================================================================
-- 5 · jobs — the optional long-running work register
-- ----------------------------------------------------------------------------
-- WHY IT EXISTS, AND WHY THIS THIN (§16.25, owner ruling 21-07): a week''s
-- fence clearing is a complete fact on its own voucher — money, feet, week —
-- and needs no parent. A job is created DELIBERATELY, described first, for
-- work worth following across several vouchers: a well dug on lumpsum terms,
-- a large contract with subcontractors. transactions.job_id (which already
-- exists on both transactions and history, and which fn_save_voucher must
-- START WRITING — v3.2 §16.28 finding 2) points here.
--
-- WHY NO COST AND NO QUANTITY COLUMNS: a stored total drifts from the rows
-- the first time a correction supersedes one. Cost is ALWAYS
--     sum over transactions where job_id = this
-- read through a view, so it cannot lie. Same reasoning as party balances
-- being read from postings, never stored (§2).
--
-- FIELD BY FIELD:
--   job_id       'J000001' from the J counter — §2 reserved the J prefix for
--                jobs on day one; this file finally gives it a table.
--   description  what the work IS, in words. The picker shows this.
--   farm         where. FARM master. A job sits on one farm; work genuinely
--                spanning farms is two jobs, same as two crops = two lines
--                (§13 one-value-per-dimension).
--   cost_object  optional — a well serves LAND, a shed serves COW.
--   start_date / end_date
--                effective-dating like everything else (§4). end_date filled
--                when the job closes. §4''s rule stands: jobs are NOT
--                FY-scoped; a job''s FY for norm comparison is its end date.
--   status       OPEN shows in the task picker; CLOSED disappears from it
--                but old rows keep pointing. Same deactivate pattern as
--                masters (§3H).
--   notes        the contract terms in prose — "lumpsum Rs.85,000, incl
--                materials" — the one place that sentence belongs.
--   created_by/at  same audit pair as every other table.
--
-- RLS: same pattern as every table — read for app users, writes only through
-- a future SECURITY DEFINER function (the jobs admin screen, Stage B). Until
-- that function exists the owner creates jobs through the SQL editor, which
-- is the owner''s documented escape hatch (§5 design rules).
-- ============================================================================

create table if not exists jobs (
  job_id       text primary key,
  description  text not null,
  farm         text not null,
  cost_object  text,
  start_date   date not null,
  end_date     date,
  status       text not null default 'OPEN'
               constraint jobs_status_check check (status in ('OPEN','CLOSED')),
  notes        text,
  created_by   text not null,
  created_at   timestamptz not null default now(),
  constraint jobs_dates_check check (end_date is null or end_date >= start_date)
);

comment on table jobs is
  'Optional register of long-running work worth following across vouchers '
  '(v3.1 §16.25): a well on lumpsum, a big contract with subcontractors. '
  'Ordinary weekly work never appears here. NO stored cost or quantity — '
  'cost is always a view over transactions.job_id, so it cannot drift.';

-- the J counter — §2 reserved the prefix; make sure the counter row exists.
insert into row_id_counters (prefix, last_no)
select 'J', 0
where not exists (select 1 from row_id_counters where prefix = 'J');

-- read like every other table; writes stay function-only
alter table jobs enable row level security;

drop policy if exists read_all on jobs;
create policy read_all on jobs for select using (true);

grant select on jobs to anon, authenticated;


-- ============================================================================
-- 6 · the voucher_shape guard
-- ----------------------------------------------------------------------------
-- WHY (v3.2 §16.28 finding 1): fn_save_voucher branches on voucher_shape read
-- from the VOUCHER_TYPE master. The DRAWINGS shape (file 17) makes it five
-- legal values. voucher_shape is data, so §3H''s "code branches on it" rule
-- applies: a value the code has no branch for must be IMPOSSIBLE to insert,
-- not silently mis-saved. Adding a sixth shape one day is then what it should
-- be — a deliberate act: extend this constraint AND write the branch, in one
-- file.
--
-- The check is conditional on list_name because master_values is one generic
-- table: other lists leave voucher_shape null and must stay free to.
-- ============================================================================

alter table master_values
  drop constraint if exists master_values_voucher_shape_check;

alter table master_values
  add constraint master_values_voucher_shape_check
  check (
    list_name <> 'VOUCHER_TYPE'
    or voucher_shape in ('TRANSACTION','SETTLEMENT','TRANSFER','JOURNAL','DRAWINGS')
  );

comment on constraint master_values_voucher_shape_check on master_values is
  'The five shapes fn_save_voucher and its siblings branch on (v3.2 §16.28). '
  'A new shape = extend this constraint AND write its branch, deliberately, '
  'in one SQL file (§3H).';


-- ============================================================================
-- 7 · verify — read back what this file claims to have done
-- ----------------------------------------------------------------------------
-- Expected: 4 column rows (2x task_no, doc_ref_no, doc_ref_date appear via
-- their tables), 3 parties columns, jobs table present, J counter present,
-- constraint present. Anything missing means a statement above failed.
-- ============================================================================

select 'transactions.task_no' as added, count(*) as ok
  from information_schema.columns
 where table_name = 'transactions' and column_name = 'task_no'
union all
select 'history.task_no', count(*)
  from information_schema.columns
 where table_name = 'history' and column_name = 'task_no'
union all
select 'vouchers.doc_ref_no/date', count(*)
  from information_schema.columns
 where table_name = 'vouchers' and column_name in ('doc_ref_no','doc_ref_date')
union all
select 'parties labour columns', count(*)
  from information_schema.columns
 where table_name = 'parties'
   and column_name in ('labour_category','default_rate','usual_farm')
union all
select 'jobs table', count(*)
  from information_schema.tables
 where table_name = 'jobs'
union all
select 'J row-id counter', count(*)
  from row_id_counters where prefix = 'J'
union all
select 'voucher_shape guard', count(*)
  from information_schema.check_constraints
 where constraint_name = 'master_values_voucher_shape_check';

-- ============================================================================
-- END OF FILE 16. Next: sql/17_seed_v32_masters.sql, then regenerate
-- DB_SCHEMA_CURRENT (00_schema_snapshot.sql) so the snapshot shows all of it.
-- ============================================================================
