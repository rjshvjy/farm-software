-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 6 : THE VAGUENESS RULE (spec section 5B)
--
-- Run AFTER files 01-05, in the Supabase SQL editor.
-- Do NOT re-run files 01-04: they drop and recreate tables.
-- This file is re-runnable on its own. It changes no table structure and
-- touches no existing ledger row.
--
--
-- WHY THIS FILE EXISTS
--
-- Section 5B says that choosing one of the vague activity heads
-- (GENERAL EXPENSES, MISC INCOME, PERSONAL MISC, UNCLASSIFIED) costs
-- something: the narration becomes compulsory, the row is flagged, and it
-- turns up in the owner's review queue.
--
-- None of that was enforced anywhere. fn_save_voucher would happily save
-- GENERAL EXPENSES with a blank narration. The flag reason the spec names
-- (ACTIVITY NOT LISTED) did not exist in the FLAG_REASON master at all, so a
-- screen that tried to send it would have had its save refused by the
-- validation trigger.
--
-- Putting the rule in the entry screen instead was the alternative. It was
-- rejected: section 5's design rules say screens never reimplement a rule,
-- and anything else that ever calls fn_save_voucher (an import, a second
-- screen, a script) would bypass a screen-side check silently.
--
--
-- WHAT THIS FILE DOES
--
--   1. Appends the missing flag reason, ACTIVITY NOT LISTED.
--   2. Adds two config rows: which activities count as vague, and how short a
--      narration is too short. Both owner-editable, neither hardcoded.
--   3. Replaces fn_save_voucher so it enforces the rule.
--
--
-- WHAT IT DELIBERATELY DOES NOT DO
--
-- The confirm dialog ("this will be flagged for review - save or cancel?")
-- stays in the screen. That is a question about intent, and the database
-- cannot ask a question. Everything the database CAN enforce, it enforces.


-- ---------------------------------------------------------------------------
-- 1. THE MISSING FLAG REASON
--
--    Attributed to NOBODY, exactly as the spec says: choosing a vague head is
--    not a fault. A photocopy really is a general expense. The flag exists so
--    the owner sees the row, not so anyone is blamed for it.
--
--    Wrapped in an existence check so this file can be re-run safely. The
--    append itself goes through fn_master_append rather than a raw INSERT,
--    so it takes the same permission path as masters admin would.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from master_values
                  where list_name = 'FLAG_REASON'
                    and code = 'ACTIVITY NOT LISTED') then
    perform fn_master_append(
      'FLAG_REASON',
      'ACTIVITY NOT LISTED',
      'Activity not listed - a general or misc head was chosen',
      '{"attributed_to":"NOBODY",
        "sort_order":130,
        "notes":"Raised automatically when a vague head is chosen (section 5B). Not a fault. Clears from the review queue."}'::jsonb);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 2. THE TWO CONFIG ROWS
--
--    VAGUE_ACTIVITIES is the list of activity codes that trigger the rule,
--    comma separated. It is config and not code because "which heads count as
--    too vague" is exactly the sort of thing that changes: if COMMON or
--    OFFICE & ADMIN start collecting slop, the owner adds them here and the
--    rule applies from the next voucher. No deployment.
--
--    VAGUE_NARRATION_MIN is the minimum number of characters. Set to 15,
--    which refuses "misc", "general" and "expenses" without needing a list of
--    banned words to maintain, and passes "printer toner refill". Edit the
--    number if it turns out to be wrong in practice.
--
--    ON CONFLICT DO NOTHING, not DO UPDATE: re-running this file must never
--    overwrite a value the owner has since changed.
-- ---------------------------------------------------------------------------
insert into config (key, value, description) values
 ('VAGUE_ACTIVITIES',
  'GENERAL EXPENSES,MISC INCOME,PERSONAL MISC,UNCLASSIFIED',
  'Activity codes that force a narration and raise a flag (section 5B). Comma separated. Owner-editable; blank disables the rule.'),
 ('VAGUE_NARRATION_MIN',
  '15',
  'Minimum narration length in characters on a vague-head line (section 5B).')
on conflict (key) do nothing;


-- ---------------------------------------------------------------------------
-- 3. fn_save_voucher - REPLACED
--
--    Everything the previous version did, it still does, unchanged: date
--    locks, prior-period handling, transactional serials, the missing
--    quantity flag, the mandays-times-rate check, screen-sent flags, posting
--    generation, suspense warnings, the duplicate guard.
--
--    Three things are new, all inside the per-line loop:
--
--    a) A vague-head line with a too-short narration is REFUSED. The whole
--       save fails and nothing is written - not the voucher, not the serial,
--       not one line. This is the single hard block in the function, and it
--       is deliberate: section 5B says blank and "misc" are refused, and
--       friction that can be clicked past is not friction.
--
--    b) The flag is raised by the database, not by the screen. If the screen
--       sends its own flag_reason that one wins (she may have a better
--       reason); otherwise ACTIVITY NOT LISTED is applied automatically.
--       This is why the rule cannot be bypassed by calling the function
--       directly.
--
--    c) A warning comes back saying the row was flagged, so the accountant
--       sees it happen rather than discovering it later.
--
--    One structural change worth noting: the flag reason is now worked out
--    BEFORE the row is inserted, and the row is inserted carrying it. The
--    old version read flag_reason straight out of the incoming JSON in the
--    INSERT itself. Since rows are immutable once saved, the flag has to be
--    right at insert time - it cannot be patched in afterwards.
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
  -- new, for the vagueness rule
  v_vague        text[];      -- the configured vague activity codes
  v_narr_min     int;         -- configured minimum narration length
  v_activity     text;        -- this line's activity
  v_narration    text;        -- this line's narration, trimmed
  v_is_vague     boolean;     -- is this line on a vague head
  v_flag_reason  text;        -- what this row is finally flagged as, if anything
  v_flag_note    text;
  v_flag_author  text;
begin
  perform fn_require('ENTER_VOUCHER');
  perform fn_ledger_write_on();

  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A voucher needs at least one line';
  end if;

  -- Read the vagueness settings once, not per line. A missing or blank
  -- config value leaves v_vague empty, which switches the rule off cleanly
  -- rather than erroring - the owner can disable it by blanking the row.
  select coalesce(array_agg(trim(x)) filter (where trim(x) <> ''), '{}')
    into v_vague
    from unnest(string_to_array(coalesce(fn_config('VAGUE_ACTIVITIES'), ''), ',')) as x;

  v_narr_min := coalesce(fn_config('VAGUE_NARRATION_MIN')::int, 15);

  -- all lines share the header payment date (v9 model: one date per voucher;
  -- PERIOD FROM/TO differ per line, section 2)
  v_pdate := (p_lines -> 0 ->> 'payment_date')::date;

  if v_pdate > current_date then
    raise exception 'Future payment dates are blocked (section 4)';
  end if;
  if v_pdate <= v_closed_upto then
    -- The PRIOR PERIOD exception to the lock (section 4): late voucher for a
    -- closed FY keeps its true date, takes the CURRENT-FY series, and is
    -- flagged. Note: this also admits a fat-fingered ancient date - the
    -- warning carries the date so the screen can make it loud.
    v_prior := true;
    v_warnings := v_warnings ||
      format('PRIOR PERIOD: date %s is in a closed period; current-FY serial taken', v_pdate);
  elsif v_pdate < v_open_from then
    raise exception 'Payment date before OPEN FROM % (section 4 fat-finger floor)', v_open_from;
  end if;

  -- serial: current-FY series for prior-period vouchers, else the date's own FY
  v_voucher_no := fn_next_voucher_no(case when v_prior then current_date else v_pdate end);

  insert into vouchers (voucher_no, fy_prefix, serial_no, prior_period, created_by)
  values (v_voucher_no,
          split_part(v_voucher_no,'/',1),
          split_part(v_voucher_no,'/',2)::int,
          v_prior, v_actor);

  -- stale-voucher soft flag (section 4)
  if current_date - v_pdate > v_stale_days then
    v_warnings := v_warnings || format('Stale voucher: %s days old', current_date - v_pdate);
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_line_no   := v_line_no + 1;
    v_row_id    := fn_next_row_id('T');
    v_amt       := coalesce((v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric);
    v_activity  := v_line->>'activity';
    v_narration := trim(coalesce(v_line->>'narration', ''));

    -- ---- the vagueness rule (section 5B) --------------------------------
    v_is_vague := v_activity = any (v_vague);

    if v_is_vague and length(v_narration) < v_narr_min then
      raise exception
        'Line %: "%" is a last resort - say what this was actually for. A real description of at least % characters is required, not "misc".',
        v_line_no, v_activity, v_narr_min;
    end if;

    -- What this row will carry as its flag. A reason sent by the screen wins:
    -- she may have a better one than the automatic default.
    v_flag_reason := coalesce(
                       nullif(v_line->>'flag_reason', ''),
                       case when v_is_vague then 'ACTIVITY NOT LISTED' end);

    -- Who the flag is credited to, and what note it carries.
    if (v_line->>'flag_reason') is not null then
      v_flag_note   := v_line->>'flag_note';
      v_flag_author := v_actor;
    else
      v_flag_note   := case when v_is_vague
                            then format('Vague head "%s" chosen. Narration: %s',
                                        v_activity, v_narration) end;
      v_flag_author := 'SYSTEM';
    end if;
    -- ---------------------------------------------------------------------

    insert into transactions (
      row_id, voucher_no, line_no, payment_date, period_from, period_to,
      entity, farm, block, cost_object, activity, capex_flag, cost_nature,
      qty, unit, mandays, rate, paid_out_dr, received_cr, mode, party_code,
      payee, narration, entry_type, entered_by,
      flagged, flag_reason)
    values (
      v_row_id, v_voucher_no, v_line_no, v_pdate,
      (v_line->>'period_from')::date, (v_line->>'period_to')::date,
      v_line->>'entity', v_line->>'farm', v_line->>'block',
      v_line->>'cost_object', v_activity,
      coalesce(v_line->>'capex_flag','RECURRING'), v_line->>'cost_nature',
      (v_line->>'qty')::numeric, v_line->>'unit',
      (v_line->>'mandays')::numeric, (v_line->>'rate')::numeric,
      (v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric,
      v_line->>'mode', v_line->>'party_code',
      v_line->>'payee', v_line->>'narration',
      v_entry_type, v_actor,
      v_flag_reason is not null, v_flag_reason)
    returning * into v_row;

    v_row_ids := v_row_ids || v_row_id;

    -- soft-block validations became flags at the screen (section 5); the
    -- screen sends flag_reason when the user chose "Continue?".
    -- Server-side re-checks:

    -- missing-metric warning (section 3F): measurable activity without qty.
    -- Skipped when the row already carries a flag, so one row never collects
    -- two flags for the same trip through the queue.
    select required_unit into v_req_unit
      from master_values where list_name = 'ACTIVITY' and code = v_activity;
    if v_req_unit is not null and (v_line->>'qty') is null
       and v_flag_reason is null then
      insert into flags (flag_id, row_id, reason_code, note, created_by)
      values (fn_next_row_id('G'), v_row_id, 'QTY NOT WRITTEN',
              format('%s expects %s', v_activity, v_req_unit), 'SYSTEM');
      v_warnings := v_warnings ||
        format('Line %s: %s has no %s recorded - flagged', v_line_no, v_activity, v_req_unit);
    end if;

    -- amount not equal to mandays times rate (section 5 soft check)
    if (v_line->>'mandays') is not null and (v_line->>'rate') is not null
       and v_amt is distinct from ((v_line->>'mandays')::numeric * (v_line->>'rate')::numeric) then
      v_warnings := v_warnings ||
        format('Line %s: amount %s does not equal mandays x rate %s', v_line_no, v_amt,
               (v_line->>'mandays')::numeric * (v_line->>'rate')::numeric);
    end if;

    -- the flag row itself - screen-sent or automatic, one insert either way
    if v_flag_reason is not null then
      insert into flags (flag_id, row_id, reason_code, note, created_by)
      values (fn_next_row_id('G'), v_row_id, v_flag_reason, v_flag_note, v_flag_author);
    end if;

    -- say it out loud when the vagueness rule fired
    if v_is_vague then
      v_warnings := v_warnings ||
        format('Line %s: %s is a general head - flagged for the owner''s review queue',
               v_line_no, v_activity);
    end if;

    perform fn_generate_postings(v_row);

    -- suspense parking must be SAID at save time, not just flagged (ruling 2)
    if exists (select 1 from flags
               where row_id = v_row_id and reason_code = 'NO POSTING RULE') then
      v_warnings := array_append(v_warnings,
        format('Line %s: no posting rule for %s - parked in Suspense, flagged',
               v_line_no, v_activity));
    end if;
  end loop;

  -- probable-duplicate warning (section 4): same date + total + payee
  if exists (
    select 1 from transactions t
    where t.payment_date = v_pdate and t.status = 'LIVE'
      and t.voucher_no <> v_voucher_no
      and coalesce(t.payee,'') = coalesce(p_lines -> 0 ->> 'payee','')
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
  'The front door. Validates, issues the serial transactionally, inserts lines, generates postings, raises flags, returns warnings. Enforces the vagueness rule (section 5B) using config VAGUE_ACTIVITIES and VAGUE_NARRATION_MIN.';


-- After this runs clean, fold files 05 and 06 into the schema.sql snapshot.
-- Section 14 keeps one current-state file, not a chain of migrations.
