-- https://github.com/rjshvjy/farm-software  ·  run in Supabase SQL editor
-- 09_payee_and_amount_checks.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — file 09: the payee decisions of 19-07-2026 (evening)
-- and the piece-rate arithmetic gap found while stress-testing the workbook.
--
-- RUN AFTER file 08. Idempotent: safe to run twice.
--
-- WHAT THIS FILE DOES
--   1. Config: three numbers, all editable, none hardcoded anywhere.
--        ONE_TIME_MAX      — above this, a ONE TIME payment draws a warning
--        LINE_AMOUNT_WARN  — above this, ANY line draws a warning
--        PARTY_WARN_MULT   — history check: warn when a payment exceeds the
--                            party's own largest-ever × this multiplier
--   2. One new flag reason: ONE TIME PAYEE.
--   3. v_party_payment_stats — each party's own payment record (count,
--      largest, average, last date). The entry screen reads this at load and
--      the pattern warning calibrates ITSELF as the ledger fills. No manual
--      per-party limits, ever: fifty numbers nobody can set confidently is a
--      rule that is always wrong.
--   4. fn_save_voucher, replaced in full, with FOUR additions and nothing
--      removed:
--        a. ONE TIME payee: narration must reach the vague floor (the name
--           goes in the narration — that is the whole design), the line is
--           flagged ONE TIME PAYEE, refused outright on CREDIT modes, and
--           warned above ONE_TIME_MAX.
--        b. Piece-rate arithmetic: when mandays is blank but qty and rate
--           are both present, amount is checked against qty × rate. Before
--           this file, a 956-trees-at-Rs-20 contract got NO check at all —
--           the one line type where a slipped digit is lakhs, unwatched.
--        c. LINE_AMOUNT_WARN on every line.
--        d. Payment-pattern warning: with 3+ prior payments to the party,
--           warn when this one exceeds their largest × PARTY_WARN_MULT.
--
-- THE PHILOSOPHY, UNCHANGED (file 08 §): refusals are for lines that are
-- STRUCTURALLY unusable; everything about judgement is a flag or a warning.
-- An accountant blocked at 6pm invents worse data than one warned at 6pm.
-- All four additions above are warnings/flags except the two that make a
-- line structurally dishonest: a one-time payment on credit (you cannot owe
-- money to nobody) and a one-time line whose narration does not name anyone.
--
-- WHY 'ONE TIME' IS A MAGIC PAYEE STRING AND NOT A PARTY ROW (owner's call,
-- 19-07): a party record invites duplicates ("One Time", "ONETIME", "1 time")
-- and would accrue a meaningless balance. The screen sends payee = 'ONE TIME'
-- with party_code null; this function recognises the string. The screen's
-- toggle is the only intended writer, but the rule is enforced HERE so a
-- hand-typed 'one time' behaves identically.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. CONFIG: the three numbers
-- ---------------------------------------------------------------------------
insert into config (key, value, description) values
 ('ONE_TIME_MAX',
  '2000',
  'Rs. above which a ONE TIME payee payment draws a warning — a payment this size probably deserves a named party. Warning only, never a block: a genuine one-off can be large.')
on conflict (key) do nothing;

insert into config (key, value, description) values
 ('LINE_AMOUNT_WARN',
  '50000',
  'Rs. above which any single line draws a check-the-figure warning. Catches the extra-zero error. Warning only.')
on conflict (key) do nothing;

insert into config (key, value, description) values
 ('PARTY_WARN_MULT',
  '2',
  'Payment-pattern check: warn when a payment to a party exceeds their own largest-ever payment times this multiplier. Needs 3+ prior payments before it says anything — under that, there is no pattern to compare against. Self-calibrating; no per-party limits exist or should.')
on conflict (key) do nothing;


-- ---------------------------------------------------------------------------
-- 2. FLAG REASON: ONE TIME PAYEE
--
--    Attributed to NOBODY — choosing it is legitimate, not a fault. The flag
--    exists so the review queue can measure the escape hatch: this estate's
--    own history (COMMON absorbing 53% of weed spend) shows an unmeasured
--    catch-all becomes the main road. The queue also gives the promotion
--    loop: a name that keeps appearing behind ONE TIME should become a party.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from master_values
                  where list_name = 'FLAG_REASON' and code = 'ONE TIME PAYEE') then
    perform fn_master_append(
      'FLAG_REASON', 'ONE TIME PAYEE',
      'Deliberate one-off payee; name is in the narration',
      '{"attributed_to":"NOBODY","sort_order":160,
        "notes":"The accountant chose the one-time toggle: recipient will not recur, name recorded in narration. Distinct from NO PAYEE (nobody named at all). Review monthly: a name recurring behind this flag should be promoted to a party."}'::jsonb);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. v_party_payment_stats — each party's own payment record
--
--    One row per party that has ever been paid: how many times, the largest,
--    the average, the most recent date. The entry screen loads this once per
--    page and the pattern warning compares against it — so the warning gets
--    sharper by itself as history accumulates, and is silent while there is
--    none (correct behaviour on day one, not a bug).
--
--    LIVE rows only: reversed/corrected lines must not distort the pattern.
--    SAMPLE rows are included while sample mode lasts — they are deleted at
--    the final reset anyway, and excluding them would leave the screen with
--    nothing to demonstrate against.
-- ---------------------------------------------------------------------------
create or replace view v_party_payment_stats as
select party_code,
       count(*)                              as times_paid,
       max(paid_out_dr)                      as max_paid,
       round(avg(paid_out_dr))               as avg_paid,
       max(payment_date)                     as last_paid
  from transactions
 where party_code is not null
   and paid_out_dr is not null
   and status = 'LIVE'
 group by party_code;

comment on view v_party_payment_stats is
  'Per-party payment pattern for the self-calibrating large-amount warning (19-07-2026). LIVE rows only. The screen reads it at page load; fn_save_voucher reads it at save.';


-- ---------------------------------------------------------------------------
-- 4. fn_save_voucher — REPLACED IN FULL
--
--    File 08''s function with four additions, clearly marked  -- 09:  below.
--    Everything else is byte-for-byte the same logic; if a line is not
--    marked 09 it came from 08 unchanged.
-- ---------------------------------------------------------------------------
create or replace function fn_save_voucher(p_lines jsonb, p_entry_type text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor        text := fn_actor_email();
  v_entry_type   text := coalesce(p_entry_type,
                          case when fn_config('LIVE_MODE') = 'SAMPLE' then 'SAMPLE' else 'NORMAL' end);
  v_closed_upto  date := fn_config('CLOSED_UPTO')::date;
  v_open_from    date := fn_config('OPEN_FROM')::date;
  v_stale_days   int  := fn_config('STALE_VOUCHER_DAYS')::int;
  v_today        date := fn_today();
  v_line         jsonb;
  v_pdate        date;
  v_voucher_no   text;
  v_prior        boolean := false;
  v_row_id       text;
  v_row          transactions;
  v_line_no      int := 0;
  v_row_ids      text[] := '{}';
  v_warnings     text[] := '{}';
  v_req_unit     text;
  v_amt          numeric;
  -- vagueness rule (file 06)
  v_vague        text[];
  v_narr_min     int;
  v_vague_min    int;
  -- 09: the three thresholds
  v_onetime_max  numeric := coalesce(fn_config('ONE_TIME_MAX')::numeric, 2000);
  v_amt_warn     numeric := coalesce(fn_config('LINE_AMOUNT_WARN')::numeric, 50000);
  v_hist_mult    numeric := coalesce(fn_config('PARTY_WARN_MULT')::numeric, 2);
  v_hist         record;
  -- per line, trimmed
  v_activity     text;
  v_narration    text;
  v_payee        text;
  v_party        text;
  v_farm         text;
  v_block        text;
  v_cost_nature  text;
  v_mode         text;
  v_mode_kind    text;
  v_pfrom        date;
  v_pto          date;
  v_is_vague     boolean;
  v_is_onetime   boolean;  -- 09
  v_farm_blocks  boolean;
  -- flags: a line may earn more than one
  v_flags        text[];
  v_notes        text[];
  v_flag_author  text;
  i              int;
begin
  perform fn_require('ENTER_VOUCHER');
  perform fn_ledger_write_on();

  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A voucher needs at least one line';
  end if;

  select coalesce(array_agg(trim(x)) filter (where trim(x) <> ''), '{}')
    into v_vague
    from unnest(string_to_array(coalesce(fn_config('VAGUE_ACTIVITIES'), ''), ',')) as x;

  v_narr_min  := coalesce(fn_config('NARRATION_MIN')::int, 5);
  v_vague_min := coalesce(fn_config('VAGUE_NARRATION_MIN')::int, 15);

  v_pdate := (p_lines -> 0 ->> 'payment_date')::date;

  if v_pdate > v_today then
    raise exception 'Future payment dates are blocked (section 4). Today is %.', v_today;
  end if;
  if v_pdate <= v_closed_upto then
    v_prior := true;
    v_warnings := v_warnings ||
      format('PRIOR PERIOD: date %s is in a closed period; current-FY serial taken', v_pdate);
  elsif v_pdate < v_open_from then
    raise exception 'Payment date before OPEN FROM % (section 4 fat-finger floor)', v_open_from;
  end if;

  v_voucher_no := fn_next_voucher_no(case when v_prior then v_today else v_pdate end);

  insert into vouchers (voucher_no, fy_prefix, serial_no, prior_period, created_by)
  values (v_voucher_no,
          split_part(v_voucher_no,'/',1),
          split_part(v_voucher_no,'/',2)::int,
          v_prior, v_actor);

  if v_today - v_pdate > v_stale_days then
    v_warnings := v_warnings || format('Stale voucher: %s days old', v_today - v_pdate);
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_line_no := v_line_no + 1;
    v_row_id  := fn_next_row_id('T');
    v_flags   := '{}';
    v_notes   := '{}';

    -- ---- trim first, then judge (decision D2) ---------------------------
    v_activity    := nullif(trim(coalesce(v_line->>'activity','')), '');
    v_narration   := trim(coalesce(v_line->>'narration', ''));
    v_payee       := nullif(trim(coalesce(v_line->>'payee','')), '');
    v_party       := nullif(trim(coalesce(v_line->>'party_code','')), '');
    v_farm        := nullif(trim(coalesce(v_line->>'farm','')), '');
    v_block       := nullif(trim(coalesce(v_line->>'block','')), '');
    v_cost_nature := nullif(trim(coalesce(v_line->>'cost_nature','')), '');
    v_mode        := nullif(trim(coalesce(v_line->>'mode','')), '');
    v_pfrom       := (v_line->>'period_from')::date;
    v_pto         := (v_line->>'period_to')::date;
    v_amt         := coalesce((v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric);

    v_is_vague := v_activity = any (v_vague);

    -- 09: the one-time toggle arrives as the literal payee 'ONE TIME'.
    -- Recognised case-insensitively so a hand-typed variant cannot slip
    -- past the rules by casing alone; stored normalised as 'ONE TIME'.
    v_is_onetime := v_payee is not null and upper(v_payee) = 'ONE TIME';
    if v_is_onetime then
      v_payee := 'ONE TIME';
    end if;

    -- ---- REFUSALS -------------------------------------------------------

    -- A2: narration on every line. Vague heads need the longer one.
    -- 09: a ONE TIME line also needs the longer one — the recipient''s NAME
    -- lives in the narration, that being the entire design of the toggle.
    if v_is_vague or v_is_onetime then
      if length(v_narration) < v_vague_min then
        if v_is_onetime then
          raise exception
            'Line %: a one-time payee needs the person named in the narration - who was paid, and for what. At least % characters.',
            v_line_no, v_vague_min;
        else
          raise exception
            'Line %: "%" is a last resort - say what this was actually for. A real description of at least % characters is required, not "misc".',
            v_line_no, v_activity, v_vague_min;
        end if;
      end if;
    elsif length(v_narration) < v_narr_min then
      raise exception
        'Line %: a narration of at least % characters is needed. It is the last chance to spot a wrong posting.',
        v_line_no, v_narr_min;
    end if;

    -- A5: the period, typed once in the header and inherited
    if v_pfrom is null or v_pto is null then
      raise exception
        'Line %: period from and period to are both needed. Set them once in the header - every line inherits them.',
        v_line_no;
    end if;
    if v_pto < v_pfrom then
      raise exception
        'Line %: period to (%) is before period from (%). A period cannot run backwards.',
        v_line_no, v_pto, v_pfrom;
    end if;

    -- A7: cost nature - what KIND of spending this was
    if v_cost_nature is null then
      raise exception
        'Line %: cost nature is needed - labour, material, machine hire, transport, contract or other. Split the line if the work used more than one.',
        v_line_no;
    end if;

    -- A1: a bank payment always has a beneficiary
    select mode_kind into v_mode_kind
      from master_values where list_name = 'MODE' and code = v_mode;

    if v_mode_kind = 'BANK' and v_party is null then
      raise exception
        'Line %: a bank payment needs a party. Pick one, or add the payee as a new party on the spot.',
        v_line_no;
    end if;

    -- 09: you cannot owe money to nobody. A one-time payee on a CREDIT mode
    -- would create a payable with no creditor - structurally dishonest, so
    -- refused rather than flagged. (On BANK modes the party rule above
    -- already fires first, since a one-time line carries no party.)
    if v_is_onetime and v_mode_kind = 'CREDIT' then
      raise exception
        'Line %: a one-time payee cannot be used on credit - there would be a debt owed to nobody. Name the party.',
        v_line_no;
    end if;

    -- ---- FLAGS ----------------------------------------------------------

    -- A1: cash that names nobody
    if v_mode_kind = 'CASH' and v_payee is null and v_party is null then
      v_flags := v_flags || 'NO PAYEE'::text;
      v_notes := v_notes || format('Cash paid, nobody named. %s', v_narration);
    end if;

    -- 09: the deliberate one-off. Distinct from NO PAYEE: here someone WAS
    -- named, in the narration, and the accountant said so explicitly. The
    -- flag measures the escape hatch and feeds the promotion loop.
    if v_is_onetime then
      v_flags := v_flags || 'ONE TIME PAYEE'::text;
      v_notes := v_notes || format('One-time payee. Narration: %s', v_narration);
    end if;

    -- A6: block unchosen, but ONLY where the farm actually has blocks
    select exists (
      select 1 from master_values
       where list_name = 'BLOCK' and active
         and parent_farm = v_farm)
      into v_farm_blocks;

    if v_farm_blocks and coalesce(v_block, 'YET TO ASSIGN') = 'YET TO ASSIGN' then
      v_flags := v_flags || 'BLOCK NOT CHOSEN'::text;
      v_notes := v_notes || format('%s has blocks in the master; none chosen', v_farm);
    end if;

    -- section 5B: a vague head is always flagged
    if v_is_vague then
      v_flags := v_flags || 'ACTIVITY NOT LISTED'::text;
      v_notes := v_notes || format('Vague head "%s" chosen. Narration: %s', v_activity, v_narration);
    end if;

    -- section 3F: measurable activity entered without its quantity
    select required_unit into v_req_unit
      from master_values where list_name = 'ACTIVITY' and code = v_activity;
    if v_req_unit is not null and (v_line->>'qty') is null then
      v_flags := v_flags || 'QTY NOT WRITTEN'::text;
      v_notes := v_notes || format('%s expects %s', v_activity, v_req_unit);
    end if;

    -- a reason sent by the screen wins the headline: she may have a better one
    if nullif(v_line->>'flag_reason','') is not null then
      v_flags := array_prepend(v_line->>'flag_reason', v_flags);
      v_notes := array_prepend(coalesce(v_line->>'flag_note', ''), v_notes);
      v_flag_author := v_actor;
    else
      v_flag_author := 'SYSTEM';
    end if;

    -- ---- the row --------------------------------------------------------
    insert into transactions (
      row_id, voucher_no, line_no, payment_date, period_from, period_to,
      entity, farm, block, cost_object, activity, capex_flag, cost_nature,
      qty, unit, mandays, rate, paid_out_dr, received_cr, mode, party_code,
      payee, narration, entry_type, entered_by,
      flagged, flag_reason)
    values (
      v_row_id, v_voucher_no, v_line_no, v_pdate, v_pfrom, v_pto,
      v_line->>'entity', v_farm, v_block,
      v_line->>'cost_object', v_activity,
      coalesce(v_line->>'capex_flag','RECURRING'), v_cost_nature,
      (v_line->>'qty')::numeric, v_line->>'unit',
      (v_line->>'mandays')::numeric, (v_line->>'rate')::numeric,
      (v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric,
      v_mode, v_party,
      v_payee, nullif(v_narration, ''),
      v_entry_type, v_actor,
      array_length(v_flags, 1) is not null,
      v_flags[1])
    returning * into v_row;

    v_row_ids := v_row_ids || v_row_id;

    -- every flag the line earned, one row each
    if array_length(v_flags, 1) is not null then
      for i in 1 .. array_length(v_flags, 1) loop
        insert into flags (flag_id, row_id, reason_code, note, created_by)
        values (fn_next_row_id('G'), v_row_id, v_flags[i],
                nullif(v_notes[i], ''),
                case when i = 1 then v_flag_author else 'SYSTEM' end);
      end loop;

      v_warnings := v_warnings ||
        format('Line %s: flagged - %s', v_line_no, array_to_string(v_flags, ', '));
    end if;

    -- amount not equal to mandays x rate (warning only, decision A8)
    if (v_line->>'mandays') is not null and (v_line->>'rate') is not null
       and v_amt is distinct from ((v_line->>'mandays')::numeric * (v_line->>'rate')::numeric) then
      v_warnings := v_warnings ||
        format('Line %s: amount %s does not equal mandays x rate %s', v_line_no, v_amt,
               (v_line->>'mandays')::numeric * (v_line->>'rate')::numeric);
    end if;

    -- 09: piece-rate arithmetic. When mandays is blank, rate belongs to the
    -- quantity ("Rs.20 per tree, 956 trees"). Before this check a contract
    -- line got no arithmetic check at all - the one line type where a
    -- slipped digit is lakhs. Warning, not refusal, same as A8.
    if (v_line->>'mandays') is null
       and (v_line->>'qty') is not null and (v_line->>'rate') is not null
       and v_amt is distinct from ((v_line->>'qty')::numeric * (v_line->>'rate')::numeric) then
      v_warnings := v_warnings ||
        format('Line %s: amount %s does not equal qty x rate %s', v_line_no, v_amt,
               (v_line->>'qty')::numeric * (v_line->>'rate')::numeric);
    end if;

    -- 09: unusually large line, flat threshold. The extra-zero catcher.
    if v_amt is not null and v_amt > v_amt_warn then
      v_warnings := v_warnings ||
        format('Line %s: Rs.%s is unusually large (threshold %s) - check the figure', v_line_no, v_amt, v_amt_warn);
    end if;

    -- 09: one-time payment above ONE_TIME_MAX - probably deserves a named
    -- party. Warning only: a genuine one-off can be large.
    if v_is_onetime and v_amt is not null and v_amt > v_onetime_max then
      v_warnings := v_warnings ||
        format('Line %s: Rs.%s to a one-time payee (threshold %s) - a payment this size probably deserves a named party', v_line_no, v_amt, v_onetime_max);
    end if;

    -- 09: payment-pattern check against the party''s OWN record. Needs 3+
    -- prior payments; under that there is no pattern, and the check stays
    -- silent - correct on day one, sharper every month, no per-party
    -- settings anywhere.
    if v_party is not null and v_amt is not null then
      select times_paid, max_paid into v_hist
        from v_party_payment_stats where party_code = v_party;
      if found and v_hist.times_paid >= 3
         and v_amt > v_hist.max_paid * v_hist_mult then
        v_warnings := v_warnings ||
          format('Line %s: Rs.%s to %s - their largest ever payment is Rs.%s across %s payments. Check the figure.',
                 v_line_no, v_amt, v_party, v_hist.max_paid, v_hist.times_paid);
      end if;
    end if;

    perform fn_generate_postings(v_row);

    if exists (select 1 from flags
               where row_id = v_row_id and reason_code = 'NO POSTING RULE') then
      v_warnings := array_append(v_warnings,
        format('Line %s: no posting rule for %s - parked in Suspense, flagged',
               v_line_no, v_activity));
    end if;
  end loop;

  -- probable duplicate (warning only, decision A9)
  if exists (
    select 1 from transactions t
    where t.payment_date = v_pdate and t.status = 'LIVE'
      and t.voucher_no <> v_voucher_no
      and coalesce(t.payee,'') = coalesce(trim(p_lines -> 0 ->> 'payee'),'')
    group by t.voucher_no
    having sum(coalesce(t.paid_out_dr, t.received_cr)) =
           (select sum(coalesce((l->>'paid_out_dr')::numeric,(l->>'received_cr')::numeric))
              from jsonb_array_elements(p_lines) l)) then
    v_warnings := array_append(v_warnings, 'Probable duplicate: same date + total + payee (section 4)');
  end if;

  return jsonb_build_object(
    'voucher_no', v_voucher_no, 'row_ids', to_jsonb(v_row_ids),
    'entry_type', v_entry_type, 'warnings', to_jsonb(v_warnings));
end $$;

comment on function fn_save_voucher(jsonb, text) is
  'The front door. File 08 rules plus 19-07 evening additions: ONE TIME payee (flagged, name-in-narration enforced, refused on credit), piece-rate qty x rate check, flat large-amount warning, self-calibrating payment-pattern warning against v_party_payment_stats.';


-- ============================================================================
-- SMOKE TEST (run by hand, read the output; sample mode assumed)
--
--  1. One-time, small:   payee 'ONE TIME', cash, narration naming a person,
--     Rs.150  -> saves; warnings mention the ONE TIME PAYEE flag only.
--  2. One-time, short narration ('sharpening') -> REFUSED, names the rule.
--  3. One-time, Rs.5000 -> saves; warning about ONE_TIME_MAX.
--  4. One-time on an ON CREDIT mode -> REFUSED: debt owed to nobody.
--  5. Piece rate: qty 956, rate 20, amount 19120, mandays blank -> clean.
--     Same with amount 1912 -> warning: does not equal qty x rate.
--  6. Any line Rs.60000 -> unusually-large warning.
--  7. Pattern: after 3+ saved payments to one party, save one at 3x their
--     largest -> warning quoting their own record.
--
-- After this runs clean, fold into All_files_Combined_schema.sql (section 14:
-- one current-state file, not a chain of migrations).
-- ============================================================================
