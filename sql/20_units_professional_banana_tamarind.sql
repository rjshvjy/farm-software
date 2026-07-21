-- sql/20_units_professional_banana_tamarind.sql
-- github.com/rjshvjy/farm-software
--
-- APPLIED 21/07/2026 via the Supabase connector, migration
-- `file_20_units_professional_cost_nature_banana_tamarind`. Body read back out
-- of supabase_migrations.schema_migrations - this is what ran.
--
-- VERIFIED AFTER APPLYING:
--   UNIT         12 -> 18  (+ TANK CAN BUNDLE BAG MT POTHI)
--   COST_NATURE   6 -> 7   (+ PROFESSIONAL)
--   COST_OBJECT  12 -> 14  (+ BANANA TAMARIND, both FINAL/KG/sellable/land)
--   aliases: "white wash" -> BUILDING & PROPERTY REPAIRS
--            "transplanting" -> SEEDS & SOWING
--   0 activities without a posting rule

-- Every value here was found by reading three years of the estate's own
-- narrations and testing a real week through fn_save_voucher (21/07). Each is
-- a measure or a thing the paper already uses and the masters could not hold.

-- 1. UNITS — six the paper prices work in, none of which existed.
--    Without them a spray charge cannot record its quantity at all: the
--    accountant either invents a unit or leaves it blank and takes a flag.
insert into master_values (list_name, code, label, active, sort_order, notes)
select 'UNIT', v.code, v.label, true,
       (select coalesce(max(sort_order),0) from master_values where list_name='UNIT') + v.bump,
       v.note
  from (values
    ('TANK',  'Tank (spray)',      10, 'Spray charges are priced per tank: "46 tanks @ Rs.40 per tank", "150 Tanks". The estate''s commonest spray measure.'),
    ('CAN',   'Can',               20, 'White wash and spray: "44 cans @ Rs.65 per can", "20 Cans @ Rs.40".'),
    ('BUNDLE','Bundle',            30, 'Paddy straw and fodder: "197 Nos bundles @ Rs.40 per bundle", "116 bundles @ Rs.50".'),
    ('BAG',   'Bag',               40, 'Fertilizer, salt, paddy: "55 bags @ Rs.280 per bag", "187 fertilizer bags".'),
    ('MT',    'Metric tonne',      50, 'Timber and trunk sales: "8.89 MT neem @ Rs.1600 per MT".'),
    ('POTHI', 'Pothi (paddy)',     60, 'Local paddy measure: "4.25 pothi @ Rs.5700 per pothi". Kept as the paper writes it rather than converted, so entry matches the slip.')
  ) as v(code, label, bump, note)
on conflict (list_name, code) do nothing;

-- 2. COST NATURE — PROFESSIONAL, the seventh.
--    PARTY_KIND has carried a PROFESSIONAL group since file 10 (ADVOCATE,
--    AUDITOR, CONSULTANT, VETERINARY) but COST_NATURE was never extended to
--    match: the system could record WHO was paid and not WHAT KIND of
--    spending it was. A vet fee is not labour, material, machine hire,
--    transport or contract, and filing it under OTHER destroys the question
--    "how much of the farm's cost is professional fees" (section 16.4 - cost
--    nature is one of the five dimensions; section 16.5 records that only
--    three of six values were ever used, so under-use was the disease).
insert into master_values (list_name, code, label, active, sort_order, notes)
select 'COST_NATURE', 'PROFESSIONAL', 'Professional fees', true,
       (select coalesce(max(sort_order),0) from master_values where list_name='COST_NATURE') + 10,
       'Veterinary, auditor, advocate, surveyor, consulting engineer. Mirrors '
       'the PROFESSIONAL group that PARTY_KIND has carried since file 10. '
       'Added file 20.'
on conflict (list_name, code) do nothing;

-- 3. COST OBJECTS — BANANA and TAMARIND.
--    Both are on the EXPENSE side, which is why they matter here: "Kallankadu
--    weeding work at Banana trees area 1.10 acres", "Tamarind harvest and
--    processing work 44 women labours". Without them that money lands on LAND
--    or COMMON and what banana costs can never be known - the same leak
--    section 3F(C) records, where COMMON swallowed 53% of weed spending.
--
--    land_based stays TRUE (the default) for both: they grow on land, so the
--    farm is asked for, unlike COW and GOAT.
--
--    The WORK quantity is chosen per task, so tamarind work is counted in
--    TREE and banana in ACRE without either being fixed here (owner, 21/07).
--    output_unit below is the SOLD output, for realisation rates on the
--    invoice side only.
insert into master_values (list_name, code, label, active, sort_order,
                           cost_object_type, output_unit, sellable, notes)
select 'COST_OBJECT', v.code, v.label, true,
       (select coalesce(max(sort_order),0) from master_values where list_name='COST_OBJECT') + v.bump,
       'FINAL', 'KG', true, v.note
  from (values
    ('BANANA',  'Banana',   10, 'Kallankadu banana farm, ~1.10 acres. Measured in ACRE like paddy - no tree count is kept.'),
    ('TAMARIND','Tamarind', 20, 'A tree crop like coconut, counted in TREE. Harvested and processed by hand ("44 women labours"); trunks also sold as timber.')
  ) as v(code, label, bump, note)
on conflict (list_name, code) do nothing;

-- 4. Two aliases instead of two new activities.
--    White wash and paddy transplanting recur, but both already have a home.
--    Minting near-duplicate activities is the fragmentation section 5C warns
--    about; re-pointing and adding her words is the review queue's own
--    pattern, and it compounds.
update master_values
   set aliases = trim(both ',' from coalesce(aliases,'') || ',white wash,whitewash,painting,paint,lime powder,kilnjal sunambu')
 where list_name='ACTIVITY' and code='BUILDING & PROPERTY REPAIRS';

update master_values
   set aliases = trim(both ',' from coalesce(aliases,'') || ',transplanting,paddy transplanting,nursery,sowing,seedling,nadavu')
 where list_name='ACTIVITY' and code='SEEDS & SOWING';
