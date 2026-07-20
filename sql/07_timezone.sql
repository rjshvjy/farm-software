-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 7 : THE ESTATE'S CLOCK
--
-- Run AFTER files 01-06, in the Supabase SQL editor.
-- Do NOT re-run files 01-04: they drop and recreate tables.
-- This file is re-runnable. It changes no table structure and touches no
-- existing ledger row.
--
--
-- WHY THIS FILE EXISTS
--
-- The Supabase server runs on UTC. India is five and a half hours ahead. So
-- between midnight and 5:30am Indian time, the database still thinks it is
-- yesterday.
--
-- Found the hard way at 2:41am on 19 July: a test voucher dated 19 July was
-- refused as a future date, correctly, because in UTC it was still the 18th.
--
-- That is not only a testing nuisance. In live use it means:
--
--   - A voucher entered after midnight, dated today, is refused as "future".
--     Plausible during a month-end push, and utterly baffling to the person
--     it happens to.
--   - The stale-voucher warning and the seven-day window are a day out during
--     that same window.
--   - The same-day amend allowance (section 6) expires at 5:30am instead of
--     midnight, so an early-morning typo cannot be amended by its author.
--   - A voucher saved at 1am on 1 April takes the OLD financial year's serial,
--     because the serial follows the payment date's FY and the clock is still
--     in March. That one is a genuine numbering error, not an inconvenience.
--   - Role grants dated "from today" do not start until 5:30am.
--
--
-- WHAT THIS FILE DOES
--
--   1. Adds a TIMEZONE config row. Not hardcoded: the estate is in one place
--      today, but a timezone is exactly the sort of thing a system should be
--      told rather than assume.
--   2. Adds fn_today() - the estate's date - and fn_local_date() for turning
--      a stored timestamp into the estate's calendar day.
--   3. Replaces every function that read the server clock so it reads the
--      estate's clock instead: fn_save_voucher, fn_correct_line,
--      fn_reverse_line, fn_actor_roles, fn_role_grant, fn_role_revoke.
--   4. Fixes three column defaults that had the same problem.
--
-- Timestamps are NOT changed. entered_at, created_at and the rest stay as
-- timestamptz recording the exact instant, which is correct and unambiguous.
-- What changes is every place where the system asks "what day is it?" or
-- "was that the same day?" - questions that only have an answer relative to
-- a place.


-- ---------------------------------------------------------------------------
-- 1. THE TIMEZONE CONFIG ROW
--
--    Must be a valid IANA timezone name. India has one zone, no daylight
--    saving, so 'Asia/Kolkata' is correct and will stay correct.
--
--    ON CONFLICT DO NOTHING so re-running never overwrites an owner edit.
-- ---------------------------------------------------------------------------
insert into config (key, value, description) values
 ('TIMEZONE',
  'Asia/Kolkata',
  'The estate''s timezone, IANA name. Everything that asks "what day is it" uses this, never the server clock (which is UTC).')
on conflict (key) do nothing;


-- ---------------------------------------------------------------------------
-- 2. fn_today() AND fn_local_date()
--
--    fn_today() is what current_date should have been all along: the calendar
--    date at the estate, right now.
--
--    fn_local_date(ts) turns any stored timestamp into the estate's calendar
--    day. Used for "was this entered today?" questions, where casting a
--    timestamptz straight to date would use the server's UTC day and give the
--    wrong answer for anything entered after 5:30am IST.
--
--    Both fall back to Asia/Kolkata if the config row is missing or holds a
--    name Postgres does not recognise. A typo in one config row must not be
--    able to stop every save in the system - it would be a strange way to
--    lose an afternoon.
-- ---------------------------------------------------------------------------
create or replace function fn_timezone() returns text
language plpgsql stable as $$
declare v_tz text;
begin
  v_tz := coalesce(nullif(fn_config('TIMEZONE'), ''), 'Asia/Kolkata');
  -- prove the name is usable before anyone depends on it
  perform now() at time zone v_tz;
  return v_tz;
exception when others then
  return 'Asia/Kolkata';
end $$;

create or replace function fn_today() returns date
language sql stable as $$
  select (now() at time zone fn_timezone())::date
$$;

create or replace function fn_local_date(p_ts timestamptz) returns date
language sql stable as $$
  select (p_ts at time zone fn_timezone())::date
$$;

comment on function fn_today() is
  'The calendar date at the estate. Use instead of current_date everywhere: the server runs on UTC and is a day behind between midnight and 5:30am IST.';

comment on function fn_local_date(timestamptz) is
  'The estate''s calendar day for a stored timestamp. Use instead of casting a timestamptz to date.';


-- ---------------------------------------------------------------------------
-- 3. COLUMN DEFAULTS
--
--    Three effective-dated tables defaulted their start date to the server's
--    today. A rule or a role created at 1am would not take effect until
--    5:30am - and a backdated-looking effective_from is exactly the sort of
--    thing nobody notices until a report disagrees with itself.
-- ---------------------------------------------------------------------------
alter table role_grants       alter column effective_from set default fn_today();
alter table chart_of_accounts alter column effective_from set default fn_today();
alter table posting_rules     alter column effective_from set default fn_today();


-- ---------------------------------------------------------------------------
-- 4. fn_actor_roles - REPLACED
--
--    Role grants are effective-dated. Read against the server clock, a grant
--    starting "today" is invisible until 5:30am, and one ending "today"
--    lingers five and a half hours too long.
--
--    Unchanged in every other respect, including SECURITY DEFINER, which is
--    what lets it read role_grants whose own RLS policy calls this function.
-- ---------------------------------------------------------------------------
create or replace function fn_actor_roles(p_email text default null) returns text[]
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_email, fn_actor_email()) = 'OWNER:SQL-EDITOR' then array['OWNER']
    else coalesce(
      (select array_agg(rg.role)
         from role_grants rg
         join app_users u on u.email = rg.email and u.status = 'ACTIVE'
        where rg.email = coalesce(p_email, fn_actor_email())
          and rg.effective_from <= fn_today()
          and (rg.effective_to is null or rg.effective_to >= fn_today())),
      array[]::text[])
  end
$$;


-- ---------------------------------------------------------------------------
-- 5. fn_save_voucher - REPLACED
--
--    Identical to the file 06 version - all the date locks, prior-period
--    handling, the vagueness rule, flags, postings, warnings - except that
--    every current_date is now fn_today().
--
--    Four places, and each one mattered:
--      - the future-date refusal
--      - the serial's FY for a prior-period voucher
--      - the stale-voucher day count
--      - (via fn_today) the financial year a 1am 1-April voucher falls into
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
  v_today        date := fn_today();          -- the estate's date, read once
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
  -- the vagueness rule (section 5B)
  v_vague        text[];
  v_narr_min     int;
  v_activity     text;
  v_narration    text;
  v_is_vague     boolean;
  v_flag_reason  text;
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

  if v_pdate > v_today then
    raise exception 'Future payment dates are blocked (section 4). Today is %.', v_today;
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
  v_voucher_no := fn_next_voucher_no(case when v_prior then v_today else v_pdate end);

  insert into vouchers (voucher_no, fy_prefix, serial_no, prior_period, created_by)
  values (v_voucher_no,
          split_part(v_voucher_no,'/',1),
          split_part(v_voucher_no,'/',2)::int,
          v_prior, v_actor);

  -- stale-voucher soft flag (section 4)
  if v_today - v_pdate > v_stale_days then
    v_warnings := v_warnings || format('Stale voucher: %s days old', v_today - v_pdate);
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
  'The front door. Validates against the estate clock (fn_today), issues the serial transactionally, inserts lines, generates postings, raises flags, returns warnings. Enforces the vagueness rule (section 5B).';


-- ---------------------------------------------------------------------------
-- 6. fn_correct_line - REPLACED
--
--    One change, and it is the subtle one in this file. The same-day amend
--    window asked whether the row was entered "today" by casting a stored
--    timestamp to a date. That cast uses the server's UTC day, so a row
--    entered at 11am IST counted as a different day from a row entered at
--    2am IST, even though both are the same working day at the estate.
--
--    Now both sides of the comparison are the estate's calendar day.
--    Everything else is untouched.
-- ---------------------------------------------------------------------------
create or replace function fn_correct_line(
  p_row_id text, p_category text, p_new_line jsonb, p_evidence text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor  text := fn_actor_email();
  v_old    transactions;
  v_new_id text;
  v_corr   text;
  v_row    transactions;
  v_slip   boolean;
begin
  perform fn_require('CORRECT_LINE');
  perform fn_assert_master('CORRECTION_CATEGORY', p_category);
  perform fn_ledger_write_on();

  select * into v_old from transactions where row_id = p_row_id for update;
  if not found then raise exception 'Row % not found', p_row_id; end if;
  if v_old.status <> 'LIVE' then
    raise exception 'Row % is % - only LIVE lines can be corrected', p_row_id, v_old.status;
  end if;

  -- the hard boundary (agreed): once exported or period-locked, reversal only
  if exists (select 1 from vouchers v where v.voucher_no = v_old.voucher_no
             and v.exported_at is not null) then
    raise exception 'Voucher % already exported to Tally - use fn_reverse_line (section 6)', v_old.voucher_no;
  end if;
  if v_old.payment_date <= fn_config('CLOSED_UPTO')::date then
    raise exception 'Period closed upto % - use fn_reverse_line (section 6)', fn_config('CLOSED_UPTO');
  end if;

  -- same-day amend window (section 6): only your own row, only today.
  -- Both dates are the estate's calendar day, never the server's.
  if p_category = 'SAME DAY AMEND'
     and (v_old.entered_by <> v_actor
          or fn_local_date(v_old.entered_at) <> fn_today()) then
    raise exception 'Same-day amend is only for your own entries, today (section 6)';
  end if;

  -- date corrections may not cross a financial year: the voucher serial
  -- belongs to its FY (section 4). Cross-FY date errors go the reversal route.
  if p_new_line ? 'payment_date'
     and fn_fy_prefix((p_new_line->>'payment_date')::date)
         <> fn_fy_prefix(v_old.payment_date) then
    raise exception 'Date correction crosses the financial year - use fn_reverse_line (section 4, serials are FY-bound)';
  end if;

  v_slip := (p_category = 'PAPER WRONG');   -- ruling 3: enter now, slip pending
  v_corr := fn_next_row_id('C');
  v_new_id := fn_next_row_id('T');

  -- retire the old version FIRST (one LIVE line per position - uq_txn_live_line)
  update transactions set status = 'SUPERSEDED', superseded_by = v_new_id
    where row_id = p_row_id;
  update ledger_entries set status = 'SUPERSEDED'
    where txn_row_id = p_row_id and status = 'LIVE';

  -- new LIVE line: old values overlaid with the corrected fields
  insert into transactions (
    row_id, voucher_no, line_no, payment_date, period_from, period_to,
    entity, farm, block, cost_object, activity, capex_flag, cost_nature,
    qty, unit, mandays, rate, paid_out_dr, received_cr, mode, party_code,
    payee, narration, entry_type, ref_row_id, entered_by, correction_id,
    flagged, flag_reason)
  values (
    v_new_id, v_old.voucher_no, v_old.line_no,
    coalesce((p_new_line->>'payment_date')::date, v_old.payment_date),
    coalesce((p_new_line->>'period_from')::date, v_old.period_from),
    coalesce((p_new_line->>'period_to')::date,   v_old.period_to),
    coalesce(p_new_line->>'entity',      v_old.entity),
    coalesce(p_new_line->>'farm',        v_old.farm),
    coalesce(p_new_line->>'block',       v_old.block),
    coalesce(p_new_line->>'cost_object', v_old.cost_object),
    coalesce(p_new_line->>'activity',    v_old.activity),
    coalesce(p_new_line->>'capex_flag',  v_old.capex_flag),
    coalesce(p_new_line->>'cost_nature', v_old.cost_nature),
    coalesce((p_new_line->>'qty')::numeric,     v_old.qty),
    coalesce(p_new_line->>'unit',        v_old.unit),
    coalesce((p_new_line->>'mandays')::numeric, v_old.mandays),
    coalesce((p_new_line->>'rate')::numeric,    v_old.rate),
    case when p_new_line ? 'paid_out_dr' then (p_new_line->>'paid_out_dr')::numeric else v_old.paid_out_dr end,
    case when p_new_line ? 'received_cr' then (p_new_line->>'received_cr')::numeric else v_old.received_cr end,
    coalesce(p_new_line->>'mode',        v_old.mode),
    coalesce(p_new_line->>'party_code',  v_old.party_code),
    coalesce(p_new_line->>'payee',       v_old.payee),
    coalesce(p_new_line->>'narration',   v_old.narration),
    'CORRECTION', v_old.row_id, v_actor, v_corr,
    v_slip, case when v_slip then 'SLIP PENDING' end)
  returning * into v_row;

  perform fn_generate_postings(v_row);

  insert into correction_log (correction_id, target_row_id, category,
                              replacement_row_id, evidence, slip_required, created_by)
  values (v_corr, p_row_id, p_category, v_new_id, p_evidence, v_slip, v_actor);

  if v_slip then
    insert into flags (flag_id, row_id, reason_code, note, created_by)
    values (fn_next_row_id('G'), v_new_id, 'SLIP PENDING', p_evidence, v_actor);
  end if;

  return jsonb_build_object('correction_id', v_corr, 'new_row_id', v_new_id,
                            'slip_required', v_slip);
end $$;


-- ---------------------------------------------------------------------------
-- 7. fn_reverse_line - REPLACED
--
--    Three current_dates, all now fn_today(): the FY the new reversal voucher
--    takes its serial from, and the payment date stamped on both the reversal
--    row and the corrected row.
--
--    The 1 April case is the one that mattered. A reversal raised at 1am on
--    1 April would have taken the previous year's serial series and stamped
--    the previous year's date on rows that belong to the new year.
-- ---------------------------------------------------------------------------
create or replace function fn_reverse_line(
  p_row_id text, p_evidence text, p_corrected_line jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor text := fn_actor_email();
  v_today date := fn_today();
  v_old   transactions;
  v_vno   text;
  v_rev   text; v_cor text; v_corr text;
  v_row   transactions;
begin
  perform fn_require('REVERSE_LINE');
  perform fn_ledger_write_on();

  select * into v_old from transactions where row_id = p_row_id for update;
  if not found then raise exception 'Row % not found', p_row_id; end if;
  if v_old.status <> 'LIVE' then
    raise exception 'Row % is % - nothing to reverse', p_row_id, v_old.status;
  end if;

  v_vno  := fn_next_voucher_no(v_today);
  v_corr := fn_next_row_id('C');
  v_rev  := fn_next_row_id('T');

  insert into vouchers (voucher_no, fy_prefix, serial_no, created_by)
  values (v_vno, split_part(v_vno,'/',1), split_part(v_vno,'/',2)::int, v_actor);

  -- equal-and-opposite row, REVERSAL OF:<id> via ref_row_id (section 6)
  insert into transactions (
    row_id, voucher_no, line_no, payment_date, entity, farm, block,
    cost_object, activity, capex_flag, cost_nature, mode, party_code,
    paid_out_dr, received_cr, payee,
    narration, entry_type, ref_row_id, entered_by)
  values (
    v_rev, v_vno, 1, v_today, v_old.entity, v_old.farm, v_old.block,
    v_old.cost_object, v_old.activity, v_old.capex_flag, v_old.cost_nature,
    v_old.mode, v_old.party_code,
    v_old.received_cr, v_old.paid_out_dr,          -- swapped: the mirror
    v_old.payee,
    'Reversal of '||p_row_id||': '||p_evidence, 'REVERSAL', p_row_id, v_actor)
  returning * into v_row;
  perform fn_generate_postings(v_row);

  -- Mark the original REVERSED - a MARKER, not an exclusion. Unlike
  -- supersede, the original stays in the arithmetic (Tally already has it;
  -- section 6): the mirror row nets it to zero. Its postings stay LIVE for
  -- the same reason. v_ledger therefore includes REVERSED rows.
  update transactions set status = 'REVERSED', superseded_by = v_rev
    where row_id = p_row_id;

  -- fresh correct row CORRECTS:<id>, if supplied
  if p_corrected_line is not null then
    v_cor := fn_next_row_id('T');
    insert into transactions (
      row_id, voucher_no, line_no, payment_date, period_from, period_to,
      entity, farm, block, cost_object, activity, capex_flag, cost_nature,
      qty, unit, mandays, rate, paid_out_dr, received_cr, mode, party_code,
      payee, narration, entry_type, ref_row_id, entered_by, correction_id)
    values (
      v_cor, v_vno, 2, v_today,
      (p_corrected_line->>'period_from')::date, (p_corrected_line->>'period_to')::date,
      coalesce(p_corrected_line->>'entity',      v_old.entity),
      coalesce(p_corrected_line->>'farm',        v_old.farm),
      coalesce(p_corrected_line->>'block',       v_old.block),
      coalesce(p_corrected_line->>'cost_object', v_old.cost_object),
      coalesce(p_corrected_line->>'activity',    v_old.activity),
      coalesce(p_corrected_line->>'capex_flag',  v_old.capex_flag),
      coalesce(p_corrected_line->>'cost_nature', v_old.cost_nature),
      (p_corrected_line->>'qty')::numeric, p_corrected_line->>'unit',
      (p_corrected_line->>'mandays')::numeric, (p_corrected_line->>'rate')::numeric,
      (p_corrected_line->>'paid_out_dr')::numeric, (p_corrected_line->>'received_cr')::numeric,
      coalesce(p_corrected_line->>'mode', v_old.mode),
      coalesce(p_corrected_line->>'party_code', v_old.party_code),
      coalesce(p_corrected_line->>'payee', v_old.payee),
      coalesce(p_corrected_line->>'narration','Corrects '||p_row_id),
      'CORRECTION', p_row_id, v_actor, v_corr)
    returning * into v_row;
    perform fn_generate_postings(v_row);
  end if;

  insert into correction_log (correction_id, target_row_id, category,
                              replacement_row_id, reversal_row_id, evidence, created_by)
  values (v_corr, p_row_id, 'POST LOCK REVERSAL', v_cor, v_rev, p_evidence, v_actor);

  return jsonb_build_object('correction_id', v_corr, 'voucher_no', v_vno,
                            'reversal_row_id', v_rev, 'corrected_row_id', v_cor);
end $$;


-- ---------------------------------------------------------------------------
-- 8. fn_role_grant AND fn_role_revoke - REPLACED
--
--    "Admin for October" must start when the estate says October starts.
--    Both defaults now come from fn_today().
-- ---------------------------------------------------------------------------
create or replace function fn_role_grant(
  p_email text, p_role text, p_from date default null, p_to date default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_is_owner boolean := 'OWNER' = any(fn_actor_roles());
begin
  perform fn_require('ROLE_GRANT');
  if p_role = 'OWNER' and not v_is_owner then
    raise exception 'Only an OWNER can grant OWNER (agreed rule)';
  end if;
  insert into role_grants (email, role, effective_from, effective_to, granted_by)
  values (p_email, p_role, coalesce(p_from, fn_today()), p_to, v_actor);
end $$;

create or replace function fn_role_revoke(p_grant_id bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_is_owner boolean := 'OWNER' = any(fn_actor_roles());
        v_g role_grants;
begin
  perform fn_require('ROLE_GRANT');
  select * into v_g from role_grants where id = p_grant_id;
  if not found then raise exception 'Grant % not found', p_grant_id; end if;
  if not v_is_owner then
    if v_g.role = 'OWNER' then raise exception 'ADMIN cannot revoke an OWNER grant'; end if;
    if v_g.email = v_actor and v_g.role = 'ADMIN' then
      raise exception 'ADMIN cannot revoke their own ADMIN (agreed rule)';
    end if;
  end if;
  -- supersede, never delete (section 4 effective-dating): end the grant today
  update role_grants set effective_to = fn_today() where id = p_grant_id;
end $$;


-- A NOTE FOR THE SCREENS
--
-- The entry screen must not default its date field from the browser either -
-- a laptop with a wrong clock is just as capable of producing a refused
-- voucher. Every screen that needs "today" calls fn_today() through the
-- database, so the paper, the screen and the ledger all agree on what day it
-- is.
--
-- After this runs clean, fold files 05, 06 and 07 into the schema.sql
-- snapshot. Section 14 keeps one current-state file, not a chain of
-- migrations.
