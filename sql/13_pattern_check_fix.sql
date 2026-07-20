-- https://github.com/rjshvjy/farm-software/blob/main/sql/13_pattern_check_fix.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — FILE 13 : THE PATTERN CHECK HAS NEVER FIRED
-- Written 20-07-2026, immediately after the file 12 smoke tests.
-- Run after file 12. Re-runnable. Regenerate the snapshot after applying.
--
-- THE BUG (pre-existing, file 09, 19-07-2026 — not introduced by file 12)
--
--   The self-calibrating large-amount warning compares a line against the
--   party's own history: "warn when this exceeds their largest ever times
--   PARTY_WARN_MULT". It sat AFTER the insert into transactions.
--
--   So by the time it ran, the line being judged was already IN the history
--   it was being judged against. v_party_payment_stats returned max_paid =
--   the very amount under test, and the condition became
--
--        amount > amount x 2
--
--   which is false for every positive number. The check was dead in exactly
--   the case it exists for: a payment larger than anything that party has
--   ever been paid. It could never fire. It has never fired.
--
--   Found on 20-07-2026 by smoke test 9 of file 12, which built a party
--   with three Rs.1,000 receipts and then saved Rs.10,000 expecting a
--   warning. It got none. The receipt-side check added in file 12 was a
--   faithful copy of the payment-side one, so it inherited the fault.
--
-- THE FIX
--
--   Move the block above the insert. It needs nothing the insert produces
--   — only v_party, v_amt and v_is_cr, all set in the trim section — so
--   the move is free, and it is also the more honest order: check the
--   figure BEFORE writing it down, which is what the accountant is being
--   asked to do.
--
--   Consequence worth stating: "3+ prior payments" now genuinely means
--   three PRIOR ones, so the check first speaks on the fourth. Before the
--   fix it counted the current line as one of the three — the one place
--   the bug made it fire sooner, on a test it could never pass anyway.
--
-- WHAT ELSE CHANGES: nothing. Same function otherwise, byte for byte from
-- file 12. No table, view, config or master is touched.
--
-- WHAT TO EXPECT AFTER APPLYING: the accountant will start seeing a
-- warning she has never seen, on payments as well as receipts. That is
-- the fix working, not a new problem. The thresholds are unchanged and
-- still config-driven (PARTY_WARN_MULT, currently 2).
--
-- HOW TO VERIFY: re-run 12_smoke_tests.sql unchanged. Check 9 must flip
-- from FAIL to PASS; every other row must stay PASS.
-- ============================================================================


drop function if exists fn_save_voucher(jsonb, text, text);

create or replace function fn_save_voucher(
  p_lines jsonb,
  p_entry_type text default null,
  p_voucher_type text default 'PAYMENT')          -- 12:
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
  -- 12: type + direction machinery
  v_vtype        text := upper(coalesce(nullif(trim(p_voucher_type), ''), 'PAYMENT'));
  v_parts        text[];                 -- prefix-safe number parsing
  v_dr_total     numeric;               -- this voucher''s DR sum, from p_lines
  v_cr_total     numeric;               -- this voucher''s CR sum, from p_lines
  v_is_cr        boolean;               -- current line receives money
begin
  perform fn_require('ENTER_VOUCHER');
  perform fn_ledger_write_on();

  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A voucher needs at least one line';
  end if;

  -- 12: direction totals, used by the type rule and the duplicate check
  select coalesce(sum((l->>'paid_out_dr')::numeric), 0),
         coalesce(sum((l->>'received_cr')::numeric), 0)
    into v_dr_total, v_cr_total
    from jsonb_array_elements(p_lines) l;

  -- 12: the type''s direction rule. Mixed vouchers are legal both ways
  -- (sale proceeds minus harvest labour is one paper); what a type
  -- demands is at least one line in ITS direction.
  if v_vtype = 'RECEIPT' and v_cr_total = 0 then
    raise exception
      'A receipt voucher must receive money on at least one line. For money out only, use a payment voucher.';
  end if;
  if v_vtype = 'PAYMENT' and v_dr_total = 0 then
    raise exception
      'A payment voucher must pay money out on at least one line. For money in only, use a receipt voucher.';
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

  -- 12: the number comes from the type''s own series
  v_voucher_no := fn_next_voucher_no(
                    case when v_prior then v_today else v_pdate end, v_vtype);

  -- 12: parse prefix-safely — fy and serial are the LAST two segments,
  -- whatever prefix the master gave the series ('26/0041' or 'R/26/0007').
  v_parts := string_to_array(v_voucher_no, '/');
  insert into vouchers (voucher_no, voucher_type, fy_prefix, serial_no, prior_period, created_by)
  values (v_voucher_no, v_vtype,
          v_parts[array_length(v_parts,1) - 1],
          v_parts[array_length(v_parts,1)]::int,
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
    v_is_cr       := (v_line->>'received_cr') is not null;   -- 12: line direction

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
    -- 09: a ONE TIME line also needs the longer one — the person''s NAME
    -- lives in the narration, that being the entire design of the toggle.
    -- 12: wording knows the direction.
    if v_is_vague or v_is_onetime then
      if length(v_narration) < v_vague_min then
        if v_is_onetime then
          raise exception
            'Line %: a one-time party needs the person named in the narration - %, and for what. At least % characters.',
            v_line_no,
            case when v_is_cr then 'who paid us' else 'who was paid' end,
            v_vague_min;
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

    -- A1: a bank movement always names its counterparty
    -- 12: same rule both directions, wording per direction — on a receipt
    -- the bank statement names who paid, and the book must match it.
    select mode_kind into v_mode_kind
      from master_values where list_name = 'MODE' and code = v_mode;

    if v_mode_kind = 'BANK' and v_party is null then
      if v_is_cr then
        raise exception
          'Line %: a bank receipt needs a party - the statement will name who paid, and the book must match it. Pick one, or add them on the spot.',
          v_line_no;
      else
        raise exception
          'Line %: a bank payment needs a party. Pick one, or add the payee as a new party on the spot.',
          v_line_no;
      end if;
    end if;

    -- 09: you cannot owe money to nobody. 12: nor can nobody owe YOU -
    -- a one-time party on a CREDIT mode is refused in either direction.
    if v_is_onetime and v_mode_kind = 'CREDIT' then
      raise exception
        'Line %: a one-time party cannot be used on credit - there would be a debt % nobody. Name the party.',
        v_line_no, case when v_is_cr then 'owed by' else 'owed to' end;
    end if;

    -- ---- FLAGS ----------------------------------------------------------

    -- A1: cash that names nobody (both directions: cash received from
    -- nobody is as blind as cash paid to nobody)
    if v_mode_kind = 'CASH' and v_payee is null and v_party is null then
      v_flags := v_flags || 'NO PAYEE'::text;
      v_notes := v_notes || format('Cash %s, nobody named. %s',
                   case when v_is_cr then 'received' else 'paid' end,  -- 12:
                   v_narration);
    end if;

    -- 09: the deliberate one-off. Distinct from NO PAYEE: here someone WAS
    -- named, in the narration, and the accountant said so explicitly. The
    -- flag measures the escape hatch and feeds the promotion loop.
    if v_is_onetime then
      v_flags := v_flags || 'ONE TIME PAYEE'::text;
      v_notes := v_notes || format('One-time party. Narration: %s', v_narration);
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

    -- section 3F: measurable activity entered without its quantity.
    -- 12: unchanged in code, but now also the SALES rule (owner 20-07):
    -- income activities carry required_unit (seeded in section 9 of this
    -- file), so a sale without quantity FLAGS and saves - never refuses.
    -- The genuine lump-sum sale records qty 1, unit LUMPSUM, no flag.
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

    -- 13: MOVED ABOVE THE INSERT. Until file 13 this block sat AFTER the
    -- insert, so the party''s "own record" already contained the line being
    -- judged: max_paid WAS this amount, and "amount > max x 2" could never
    -- be true for the very line the check exists to catch. Dead since
    -- file 09. Found by the file 12 smoke tests, 20-07-2026.
    -- 09: pattern check against the party''s OWN record. Needs 3+ priors;
    -- under that there is no pattern and the check stays silent.
    -- 12: reads the MATCHING side - a receipt is measured against their
    -- receipt history, never their payment history. Same multiplier,
    -- same floor, still no per-party settings anywhere.
    if v_party is not null and v_amt is not null then
      if v_is_cr then
        select times_received as times_paid, max_received as max_paid into v_hist
          from v_party_receipt_stats where party_code = v_party;
        if found and v_hist.times_paid >= 3
           and v_amt > v_hist.max_paid * v_hist_mult then
          v_warnings := v_warnings ||
            format('Line %s: Rs.%s from %s - their largest ever receipt is Rs.%s across %s receipts. Check the figure.',
                   v_line_no, v_amt, v_party, v_hist.max_paid, v_hist.times_paid);
        end if;
      else
        select times_paid, max_paid into v_hist
          from v_party_payment_stats where party_code = v_party;
        if found and v_hist.times_paid >= 3
           and v_amt > v_hist.max_paid * v_hist_mult then
          v_warnings := v_warnings ||
            format('Line %s: Rs.%s to %s - their largest ever payment is Rs.%s across %s payments. Check the figure.',
                   v_line_no, v_amt, v_party, v_hist.max_paid, v_hist.times_paid);
        end if;
      end if;
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
    -- quantity ("Rs.20 per tree, 956 trees"). 12: on receipts this same
    -- check IS the realisation-rate check - qty sold x rate = proceeds.
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

    -- 09: one-time above ONE_TIME_MAX - probably deserves a named party.
    -- Warning, not block: a genuine one-off can be large. 12: direction word.
    if v_is_onetime and v_amt is not null and v_amt > v_onetime_max then
      v_warnings := v_warnings ||
        format('Line %s: Rs.%s %s a one-time party (threshold %s) - an amount this size probably deserves a named party',
               v_line_no, v_amt,
               case when v_is_cr then 'from' else 'to' end,
               v_onetime_max);
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
  -- 12: direction-scoped - DR totals compare with DR, CR with CR. Paying
  -- and receiving the same figure from the same name the same day is
  -- business, not a duplicate.
  if exists (
    select 1 from transactions t
    where t.payment_date = v_pdate and t.status = 'LIVE'
      and t.voucher_no <> v_voucher_no
      and coalesce(t.payee,'') = coalesce(trim(p_lines -> 0 ->> 'payee'),'')
    group by t.voucher_no
    having sum(coalesce(t.paid_out_dr, 0)) = v_dr_total
       and sum(coalesce(t.received_cr, 0)) = v_cr_total) then
    v_warnings := array_append(v_warnings, 'Probable duplicate: same date + total + payee (section 4)');
  end if;

  return jsonb_build_object(
    'voucher_no', v_voucher_no, 'voucher_type', v_vtype,     -- 12:
    'row_ids', to_jsonb(v_row_ids),
    'entry_type', v_entry_type, 'warnings', to_jsonb(v_warnings));
end $$;

comment on function fn_save_voucher(jsonb, text, text) is
  'The front door, both directions (file 12). File 13 moves the party-pattern check above the insert: it previously judged a line against a history that already contained it, so it could never fire. Files 08 and 09 rules otherwise unchanged.';


-- ============================================================================
-- VERIFY
--   Re-run 12_smoke_tests.sql exactly as before. Expected: check 9 flips to
--   PASS with a detail line quoting the party's own receipt record, and all
--   other rows stay PASS.
--
--   If you want the payment side proven too (it is the same code path, and
--   it is the one that has been broken since 19 July), the quickest check is
--   to run the smoke test file and read check 9's detail: it exercises the
--   CR branch, and the DR branch is the same block, moved by the same edit.
-- ============================================================================
