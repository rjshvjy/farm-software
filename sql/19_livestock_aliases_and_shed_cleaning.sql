-- sql/19_livestock_aliases_and_shed_cleaning.sql
-- github.com/rjshvjy/farm-software
--
-- APPLIED 21/07/2026 via the Supabase connector, migration
-- `file_19_livestock_activity_aliases_and_shed_cleaning`. The body below was
-- read back OUT of supabase_migrations.schema_migrations, so this file is what
-- actually ran rather than a retyped copy of it (the 21/07 drift lesson).
-- Re-running is safe - every statement guards itself - but unnecessary.
--
-- VERIFIED AFTER APPLYING:
--   SHED CLEANING / FARM / sort 360, posting to 5030 Livestock Expenses
--   FEED required_unit = KG
--   10 activities carrying aliases (was 1 in the whole master)
--   78 pickable activities, 0 without a posting rule
--   search "cow"  -> FEED, FODDER CUTTING, MILKING WAGES, SHED CLEANING,
--                    SHED CONSTRUCTION, SHEPHERD WAGES, VET & MEDICINE
--   search "goat" -> FEED, SHED CLEANING, SHED CONSTRUCTION, SHEPHERD WAGES,
--                    VET & MEDICINE
--   (both returned NOTHING before this file)

-- WHY, from the workbook narrations read on 21/07:
--   Livestock has a fixed weekly rhythm running three years — cow shed
--   cleaning, cow herding, cow fodder harvest, goat herding, goat shed
--   cleaning. SHED CLEANING is the single most frequent livestock line in the
--   book and has no activity of its own: it can only land in LIVESTOCK
--   GENERAL, which is a VAGUE head that forces a flag and a 15-character
--   narration on every one of them.
--
--   And nothing is findable. Typing "cow", "cattle" or "goat" into the
--   activity box returns NOTHING, because the search matches code and label
--   only and no livestock activity contains those words. The aliases column
--   (section 3F2) exists for exactly this and had ONE populated row in the
--   entire master.

-- 1. SHED CLEANING — sort_order 360, inside the livestock block (350-400).
insert into master_values (list_name, code, label, active, sort_order,
                           group_code, notes)
values ('ACTIVITY', 'SHED CLEANING',
        'Shed cleaning — cow shed, goat shed, cattle yard',
        true, 360, 'FARM',
        'Weekly work on this estate: "7 labours Cow shed cleaning wages", '
        '"Goat shed cleaning wages". Distinct from SHED CONSTRUCTION, which '
        'is building or altering the shed and posts to property upkeep. '
        'Added file 19 after reading three years of narrations.')
on conflict (list_name, code) do nothing;

-- Its posting rule. Cleaning the shed is a cost of KEEPING the animals, so
-- 5030 Livestock Expenses — same as herding, feed, vet and milking. (Shed
-- CONSTRUCTION posts to 5020 because building is a property improvement.)
-- Without this the line would park in Suspense and raise NO POSTING RULE.
insert into posting_rules (rule_kind, match_code, account_out, effective_from, notes)
select 'ACTIVITY', 'SHED CLEANING', '5030', date '2020-01-01',
       'Livestock upkeep, same as SHEPHERD WAGES and FEED (file 19).'
where not exists (
  select 1 from posting_rules
   where rule_kind='ACTIVITY' and match_code='SHED CLEANING');

-- 2. FEED is always bought by weight in this book — cotton seed 34 Kg @ Rs.44,
--    40 Kg @ Rs.50, sorghum seed 200 Kg @ Rs.55. Prompt for it.
--    VET & MEDICINE is deliberately NOT given a required unit: vaccination is
--    per head (193 goats @ Rs.60) but a single calf's Dr fee is not, and a
--    required unit would flag half those lines for nothing.
update master_values
   set required_unit = 'KG'
 where list_name='ACTIVITY' and code='FEED' and required_unit is null;

-- 3. ALIASES — the words actually written on the paper, English and Tamil.
--    Comma separated (section 3F2). Owner-editable in masters admin.
--    NOTE: 'cow'/'goat' are deliberately NOT put on LIVESTOCK GENERAL. It is a
--    vague head; making it an easy first hit for "cow" would send routine work
--    into the catch-all, which is what section 3F(C) warns about.
update master_values set aliases = 'cow herding,goat herding,sheep,shepherd,herding,grazing,meithal,aadu,kidai,maadu,cattle,cow,goat'
 where list_name='ACTIVITY' and code='SHEPHERD WAGES';

update master_values set aliases = 'cow shed cleaning,goat shed cleaning,cattle shed,sheep shed,shed cleaning,dung,saani,cow,goat,cattle,sheep'
 where list_name='ACTIVITY' and code='SHED CLEANING';

update master_values set aliases = 'milk,milking,paal,cow,cattle'
 where list_name='ACTIVITY' and code='MILKING WAGES';

update master_values set aliases = 'cotton seed,cattle feed,goat feed,thavidu,bran,horse gram,kollu,cowpea,karamani,feed,cow,goat,cattle,sheep'
 where list_name='ACTIVITY' and code='FEED';

update master_values set aliases = 'doctor,dr fees,vet,veterinary,vaccination,injection,deworming,medicine,treatment,sinai oosi,insemination,fertilization,pregnancy,fever,disentry,maggot,cow,goat,cattle,sheep,calf'
 where list_name='ACTIVITY' and code='VET & MEDICINE';

update master_values set aliases = 'seema pul,fodder,fodder harvest,grass cutting,napier,kolukattai,naripairu,silage,sorghum fodder,cow fodder'
 where list_name='ACTIVITY' and code='FODDER CUTTING';

update master_values set aliases = 'goat shed,cow shed,cattle shed,sheep shed,shed work,reaper,shed construction,platform'
 where list_name='ACTIVITY' and code='SHED CONSTRUCTION';

update master_values set aliases = 'livestock,rope,mookanan kairu,thaali,animal'
 where list_name='ACTIVITY' and code='LIVESTOCK GENERAL';

-- LABOUR WELFARE picks up the recurring shed-injury lines ("Devaraj cattle
-- shed labour hand fingers injured", "Hand Injury (Cow Attack)").
update master_values set aliases = 'medical,injury,accident,hospital,welfare,labour medical,cattle shed injury'
 where list_name='ACTIVITY' and code='LABOUR WELFARE';
