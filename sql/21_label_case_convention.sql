-- sql/21_label_case_convention.sql
-- github.com/rjshvjy/farm-software
--
-- FILE 21 — LABEL CASE, PUT BACK TO THE HOUSE CONVENTION
-- 22 July 2026 · labels only · no code, no structure
--
-- APPLIED 22/07/2026 via the Supabase connector, migration
-- `file_21_label_case_convention`.
--
-- The estate already had a convention and nobody had written it down. Owner
-- spotted the drift on 22/07 when PROFESSIONAL read "Professional fees" beside
-- LABOUR and MATERIAL in the same dropdown.
--
-- THE RULE, as the data itself states it:
--
--   LINE-DIMENSION LISTS ARE ALL CAPS — the values the accountant picks on a
--   voucher line, which read as codes rather than sentences:
--     ACTIVITY (83 of 84 already), COST_OBJECT, COST_NATURE, UNIT,
--     FARM, BLOCK, MODE, CAPEX_FLAG
--
--   DESCRIPTIVE LISTS ARE SENTENCE CASE — values that read as a phrase and
--   are shown as explanation rather than chosen as a code:
--     FLAG_REASON (17 of 17), CORRECTION_CATEGORY (10 of 10),
--     PARTY_KIND (36 of 36), VOUCHER_TYPE (7 of 7)
--
-- Every exception in the first group was introduced by files 19 and 20 earlier
-- the same day. This corrects them. Labels are editable by design — only CODES
-- are immutable (section 13) — so nothing is lost and no row is orphaned.
--
-- The explanatory text those labels carried is not thrown away: it moves into
-- `notes`, which is what the help strip shows at the foot of the entry screen.
--
-- VERIFIED AFTER APPLYING: 0 mixed-case labels remaining across all eight
-- line-dimension lists.

update master_values set label = 'SHED CLEANING'
 where list_name='ACTIVITY' and code='SHED CLEANING';

update master_values set label = 'PROFESSIONAL'
 where list_name='COST_NATURE' and code='PROFESSIONAL';

update master_values set label = code
 where list_name='COST_OBJECT' and code in ('BANANA','TAMARIND');

update master_values set label = code
 where list_name='UNIT' and code in ('TANK','CAN','BUNDLE','BAG','MT','POTHI');

-- MT and POTHI are the two that are not self-explanatory. The notes carry the
-- meaning, and the help strip reads notes, so the short label costs nothing.
update master_values
   set notes = 'Metric tonne. Timber and trunk sales: "8.89 MT neem @ Rs.1600 per MT".'
 where list_name='UNIT' and code='MT';

update master_values
   set notes = 'Local paddy measure, about 260 Kg. "4.25 pothi @ Rs.5700 per pothi". Kept as the paper writes it rather than converted, so entry matches the slip.'
 where list_name='UNIT' and code='POTHI';

update master_values
   set notes = 'Spray tank. Charges are priced per tank: "46 tanks @ Rs.40 per tank", "150 Tanks". The estate''s commonest spray measure.'
 where list_name='UNIT' and code='TANK';
