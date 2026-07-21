-- ============================================================================
-- github.com/rjshvjy/farm-software · sql/17_seed_v32_masters.sql
-- ============================================================================
-- FILE 17 · MASTER SEEDING FOR v3.2 · run AFTER file 16
-- Paste whole into the Supabase SQL editor. Regenerate DB_SCHEMA_CURRENT after.
--
-- WHAT THIS FILE SEEDS, AND THE EVIDENCE FOR EACH VALUE
-- ----------------------------------------------------------------------------
-- Every value here was checked against the LIVE master dump of 21-07-2026
-- (owner-supplied query result) before writing, because masters are
-- append-only and codes are immutable (§3H) — a duplicate seeded today is a
-- duplicate forever. What that check found:
--
--   · All 25 printed activities on the 13/07/2026 wage paper already map to
--     seeded codes. ONE gap: cooking wages (Rs.7,130 on that paper).
--   · The household activity list ALREADY EXISTS — 12+ values seeded on day
--     one. What is missing is only the group_code that separates them from
--     farm work: null on every one of the 76 ACTIVITY rows.
--   · ENGAGEMENT_TYPE is NOT seeded here and never will be: COST_NATURE
--     (LABOUR/CONTRACT/...) + UNIT (incl LUMPSUM) already answer the same
--     question, and §13 refuses a second way of saying the same thing.
--     The screen derives its boxes from cost_nature (§19.3 as revised).
--
-- GOLDEN-RULES NOTE: only section 4 below touches the accounting — the
-- DRAWINGS voucher type, whose posting is Dr 3020 Owner Drawings (the owner
-- receives value out of the business: DEBIT THE RECEIVER), Cr the pocket
-- (CREDIT WHAT GOES OUT). Everything else in this file is dropdown data.
--
-- WHY SOME STATEMENTS ARE DIRECT SQL, NOT fn_master_* CALLS: read from the
-- function bodies in the snapshot before writing (per §14) —
-- fn_master_append and fn_master_set_attrs handle the ORIGINAL attribute set
-- only. Neither knows group_code (added file 10) nor voucher_shape /
-- voucher_direction / voucher_prefix (file 12). Files 10/12/15 seeded those
-- by direct SQL for the same reason, and the SQL editor is the owner's
-- documented escape hatch. KNOWN GAP, carried to the file-18 function work:
-- the two fn_master_* functions should learn the newer attributes so masters
-- admin can manage them from the screen.
-- ============================================================================


-- ============================================================================
-- 1 · COOKING WAGES — the one activity the 13/07/2026 paper adds
-- ----------------------------------------------------------------------------
-- WHY: Rs.7,130 on that paper, and nothing seeded matches. HOUSEHOLD STAFF
-- exists but is broader — the paper itself separates cooking wages from other
-- house staff, and §10.5's "ask the rows on what" only works if the rows can
-- say cooking. Goes through fn_master_append because the standard attributes
-- suffice; group_code follows in section 2 with the rest.
-- Tamil alias: the supervisor writes "samayal" (சமையல்) — §3F2.
-- ============================================================================

select fn_master_append(
  'ACTIVITY',
  'COOKING WAGES',
  'COOKING WAGES',
  jsonb_build_object(
    'aliases', 'samayal, cook, cooking',
    'notes',   'Household cook''s wages. Personal Drawings Voucher only (v3.2 '
               'section 20) - never a farm cost, never in the P&L.'
  )
);


-- ============================================================================
-- 2 · group_code on every ACTIVITY — the split the two screens filter on
-- ----------------------------------------------------------------------------
-- WHY IT EXISTS: two voucher screens, two dropdowns, one master (§20.3).
-- The drawings screen shows HOUSEHOLD (and SHARED); the business expense
-- screen shows everything EXCEPT household/funding/income; the sales screen
-- takes INCOME; the settlement screens take FUNDING's movement heads. Plus
-- §12's proven rollup: the four weed activities total Rs.4,47,345 across 161
-- rows, and WEED MGMT makes that one filter instead of a code list inside a
-- report.
--
-- THE GROUPS, kept deliberately few (resist speculative taxonomy):
--   HOUSEHOLD  drawings screen only. Dr 3020 territory.
--   SHARED     appears in BOTH dropdowns — for people who serve both worlds.
--              The watchman ruling (§20.4): the supervisor's paper decides
--              which voucher a night goes on; the activity must therefore be
--              offerable on both screens. Same for the driver.
--   INCOME     sales invoice screen (§16.18: income only through an invoice).
--   FUNDING    movement heads: owner capital, transfers, advances. Neither
--              expense screen offers these (§13: owner cash movements are
--              FUNDING, never income, never expense).
--   WEED MGMT  farm work, sub-grouped for the §12 rollup.
--   FARM       everything else the estate does on the land.
--
-- JUDGMENT CALLS, recorded so they are arguable rather than buried:
--   ELECTRICITY -> FARM (posting rule already sends it to 5020, Land &
--     Property Upkeep: pumpsets and farm connections dominate).
--   UTILITIES -> HOUSEHOLD. An earlier draft of this file called it FARM on
--     the pumpset argument; the POSTING RULES had already ruled, sending
--     UTILITIES to 3020. Corrected 21-07 after reading them. The rule table
--     is evidence, not background — same lesson as the constraint names.
--   SHEPHERD WAGES -> FARM. Goat and cow are FINAL cost objects (§3A) —
--     livestock that produces for sale is farm, settled 21-07.
--   BUILDING & PROPERTY REPAIRS -> FARM (sheds, walls); the house has its
--     own HOUSE REPAIRS under HOUSEHOLD.
--   STAFF SALARY -> SHARED. Farm supervisor is farm; a house driver's monthly
--     pay may go either side — same person-splits-by-voucher rule as the
--     watchman.
--   GENERAL EXPENSES / UNCLASSIFIED -> FARM, PERSONAL MISC -> HOUSEHOLD:
--     each screen keeps exactly ONE vague head, so §5B's vagueness price
--     stays payable on both sides without offering four escape hatches.
-- ============================================================================

-- household: the drawings dropdown (§20.3)
update master_values set group_code = 'HOUSEHOLD'
 where list_name = 'ACTIVITY'
   and code in (
     'COOKING WAGES', 'HOUSEHOLD STAFF', 'KITCHEN & PROVISIONS',
     'HOUSE REPAIRS', 'MEDICAL', 'EDUCATION', 'CLOTHING & PERSONAL',
     'FUNCTIONS, GIFTS & GUESTS', 'RELIGIOUS & CHARITY', 'PETS',
     'TRAVEL-PERSONAL', 'VEHICLE-PERSONAL', 'PERSONAL MISC',
     'UTILITIES'
   );

-- shared people: offered on BOTH expense and drawings screens (§20.4)
update master_values set group_code = 'SHARED'
 where list_name = 'ACTIVITY'
   and code in ('WATCHMAN WAGES', 'DRIVER SALARY', 'STAFF SALARY');

-- income: the sales invoice screen only (§16.18)
update master_values set group_code = 'INCOME'
 where list_name = 'ACTIVITY'
   and code in (
     'PRODUCE SALE', 'LIVESTOCK SALE', 'MILK SALE', 'TREE SALE',
     'LEASE RENT', 'MISC INCOME', 'PRODUCE CONSUMED AT HOME'
   );

-- funding: movement heads, no expense screen offers them (§13)
update master_values set group_code = 'FUNDING'
 where list_name = 'ACTIVITY'
   and code in (
     'OWNER CAPITAL / CURRENT A/C', 'BANK / CASH TRANSFER',
     'STAFF ADVANCE GIVEN', 'STAFF ADVANCE DEDUCTED', 'ADVANCE RECEIVED'
   );

-- the proven rollup (§12: Rs.4,47,345 across 161 rows in the workbook)
update master_values set group_code = 'WEED MGMT'
 where list_name = 'ACTIVITY'
   and code in (
     'WEED CUTTING', 'WEED PICKING', 'WEED SHIFTING FOR DESTROY',
     'WEEDICIDE SPRAY'
   );

-- everything still ungrouped is ordinary farm work
update master_values set group_code = 'FARM'
 where list_name = 'ACTIVITY'
   and group_code is null;


-- ============================================================================
-- 3 · required_unit — evidence from the 13/07/2026 paper (§3F)
-- ----------------------------------------------------------------------------
-- WHY: required_unit is what fires the missing-quantity flag and preselects
-- the unit box. Blank = never prompted, never flagged. The paper measures
-- irrigation in acres (item 8: three plots) and the weed items in acres —
-- so leaving these blank would lose exactly the metric the paper proves is
-- collectable. Owner ruling 21-07 on irrigation: sometimes acres, sometimes
-- trees — ACRE preselects, the accountant overrides to TREE when the work
-- was per-tree, and the flag fires on a BLANK quantity either way (§3F:
-- preselect is overridable, only ever into a blank).
--
-- Through fn_master_set_attrs, which validates the unit against the UNIT
-- master before writing — the check we want.
-- ============================================================================

select fn_master_set_attrs('ACTIVITY', 'IRRIGATION',
  jsonb_build_object('required_unit', 'ACRE'));

select fn_master_set_attrs('ACTIVITY', 'WEED CUTTING',
  jsonb_build_object('required_unit', 'ACRE'));

select fn_master_set_attrs('ACTIVITY', 'WEED PICKING',
  jsonb_build_object('required_unit', 'ACRE'));

select fn_master_set_attrs('ACTIVITY', 'WEED SHIFTING FOR DESTROY',
  jsonb_build_object('required_unit', 'ACRE'));


-- ============================================================================
-- 4 · the DRAWINGS voucher type — the one accounting change in this file
-- ----------------------------------------------------------------------------
-- THE POSTING (Part 0.3, v3.2): Dr 3020 OWNER DRAWINGS — the owner is the
-- receiver of value taken out of the business (personal account: DEBIT THE
-- RECEIVER). Cr the pocket — cash or bank leaves (real account: CREDIT WHAT
-- GOES OUT). The P&L never sees it (§10.3); the balance sheet shows it as a
-- deduction from capital; cash flow classes it F (§10.5); it closes to
-- capital at year end by a manual journal, the one deliberate year-end entry.
--
-- FIELD BY FIELD ON THIS ROW:
--   code DRAWINGS          immutable forever (§3H) — chosen to read as the
--                          accounting fact, not the screen name.
--   label                  the screen name, freely editable later.
--   voucher_prefix DV      its own gap-free serial series (DV/26/0001),
--                          because settlement of the paper<->system link is
--                          per-series (§4). PV/RV/CV/JV/PB/SI are taken; DV
--                          is free — verified against the live dump.
--   voucher_shape DRAWINGS the fifth shape (guarded by file 16's constraint).
--                          fn_save_voucher's branch for it (file 18) enforces:
--                          party REQUIRED (household spending is always
--                          somebody), activity REQUIRED (the only breakdown
--                          there is, §10.5), farm/block/cost object/qty
--                          REFUSED (nothing describes a house, Part 0.5),
--                          days+rate allowed, CREDIT mode allowed (a house
--                          shop account is ordinary — the one difference from
--                          SETTLEMENT), entity FORCED to PERSONAL by the
--                          function, never trusted from the screen (§20.1).
--   voucher_direction OUT  drawings only ever pays out. Value returned by the
--                          household is not a negative drawing — it is owner
--                          capital coming in, a RECEIPT with entity FUNDING
--                          (§10.5's table, first row).
--
-- WHY DIRECT INSERT: fn_master_append predates the voucher_* attributes
-- (see header). Same route files 12/15 used for the other six types.
-- ON CONFLICT DO NOTHING keeps the file idempotent — masters are append-only,
-- so re-running must never duplicate or overwrite.
-- ============================================================================

insert into master_values
  (list_name, code, label, voucher_prefix, voucher_shape, voucher_direction,
   sort_order, notes)
values
  ('VOUCHER_TYPE', 'DRAWINGS', 'Personal Drawings Voucher',
   'DV', 'DRAWINGS', 'OUT', 70,
   'Household spending = owner drawings (v3.2 section 20). Dr 3020, Cr the '
   'pocket. Payment-shaped underneath so the cash book sees every rupee '
   'through one kind of door (section 16.22); never a journal. P&L never '
   'sees it. Own activity list: group_code HOUSEHOLD plus SHARED.')
on conflict (list_name, code) do nothing;


-- ============================================================================
-- 4b · the posting rule for COOKING WAGES
-- ----------------------------------------------------------------------------
-- STRICTLY SPEAKING UNNECESSARY, and added anyway. fn_generate_postings tests
-- the ENTITY before it consults the rules:
--     elsif p_row.entity = 'PERSONAL' then v_side := '3020';
-- so any line on a drawings voucher lands on 3020 whatever its activity.
--
-- But every other household activity carries an explicit 3020 rule, and a
-- rule table with one member missing stops being readable as the answer to
-- 'where does this land'. Someone checking COOKING WAGES here would find
-- nothing and conclude it was unmapped. Rs.0 of ambiguity for one row.
--
-- Dr 3020 Owner Drawings: the owner receives value taken out of the business.
-- effective_from matches the rest of the seeded rules.
-- ============================================================================

insert into posting_rules
  (rule_kind, match_code, account_out, effective_from, notes)
select 'ACTIVITY', 'COOKING WAGES', '3020', date '2020-01-01',
       'Household cook. Drawings, never a farm cost (v3.2 section 20). '
       'Belt-and-braces: the PERSONAL entity branch in fn_generate_postings '
       'reaches 3020 before this rule is consulted.'
where not exists (
  select 1 from posting_rules
   where rule_kind = 'ACTIVITY' and match_code = 'COOKING WAGES');


-- ============================================================================
-- 5 · verify — read back what this file claims
-- ----------------------------------------------------------------------------
-- Expected: cooking=1 · household=14 · shared=3 · income=7 · funding=5 ·
-- weed=4 · farm=44 · ungrouped=0 (77 total activities) · acre_units=4 ·
-- drawings_type=1 · cooking_rule=1. Any other number: read section 2's lists
-- against the live dump before touching anything.
-- ============================================================================

select 'COOKING WAGES seeded' as checked, count(*) as n
  from master_values
 where list_name = 'ACTIVITY' and code = 'COOKING WAGES'
union all
select 'group HOUSEHOLD', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'HOUSEHOLD'
union all
select 'group SHARED', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'SHARED'
union all
select 'group INCOME', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'INCOME'
union all
select 'group FUNDING', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'FUNDING'
union all
select 'group WEED MGMT', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'WEED MGMT'
union all
select 'group FARM', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code = 'FARM'
union all
select 'ACTIVITY still ungrouped (want 0)', count(*) from master_values
 where list_name = 'ACTIVITY' and group_code is null
union all
select 'required_unit ACRE set (want 4 new)', count(*) from master_values
 where list_name = 'ACTIVITY'
   and code in ('IRRIGATION','WEED CUTTING','WEED PICKING',
                'WEED SHIFTING FOR DESTROY')
   and required_unit = 'ACRE'
union all
select 'DRAWINGS voucher type', count(*) from master_values
 where list_name = 'VOUCHER_TYPE' and code = 'DRAWINGS'
   and voucher_shape = 'DRAWINGS' and voucher_prefix = 'DV'
union all
select 'COOKING WAGES posting rule', count(*) from posting_rules
 where rule_kind = 'ACTIVITY' and match_code = 'COOKING WAGES'
   and account_out = '3020';

-- ============================================================================
-- END OF FILE 17. Regenerate DB_SCHEMA_CURRENT so the snapshot carries all of
-- this — including, for the first time, values it should list per master.
-- Next: file 18, fn_save_voucher rewritten for tasks (§18.6 step 3) — the
-- DRAWINGS branch, job_id into the INSERT, the within-voucher duplicate
-- check, and teaching fn_master_append / fn_master_set_attrs the newer
-- attributes.
-- ============================================================================
