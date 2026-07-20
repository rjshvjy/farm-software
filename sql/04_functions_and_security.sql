-- ============================================================================
-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 4 of 4 : CORRECTIONS, AUDIT, FUNCTIONS, VIEWS, SECURITY
-- Run after 03_posting_layer.sql. Re-runnable.
--
-- This file is where the rules live. All writes to the ledger go through the
-- named functions here; they run as SECURITY DEFINER, check the actor's role,
-- set the write token, and enforce §4/§6/§10 rules. No role has direct
-- INSERT/UPDATE/DELETE on ledger tables.
-- ============================================================================

drop table if exists audit_marks    cascade;
drop table if exists flags          cascade;
drop table if exists correction_log cascade;

-- ---------------------------------------------------------------------------
-- 1. CORRECTION LOG — one row per correction of any kind (agreed taxonomy).
-- ---------------------------------------------------------------------------
create table correction_log (
  correction_id   text primary key,          -- 'C000001'
  target_row_id   text not null,             -- the row being corrected (T… or H…)
  category        text not null,             -- code from CORRECTION_CATEGORY master
  replacement_row_id text,                   -- new line (supersede) or correction row (reversal)
  reversal_row_id text,                      -- the reversal row, when category = POST LOCK REVERSAL
  evidence        text not null,             -- what established the fact (accountant ruling 1)
  slip_required   boolean not null default false,  -- PAPER WRONG case (ruling 3): enter now, slip pending
  slip_done       boolean not null default false,
  slip_done_at    timestamptz,
  created_by      text not null,
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. FLAGS (§7) — 'G' ids; reason from master carries automatic attribution.
-- ---------------------------------------------------------------------------
create table flags (
  flag_id     text primary key,              -- 'G000001'
  row_id      text not null,
  reason_code text not null,                 -- FLAG_REASON master
  note        text,
  status      text not null default 'OPEN' check (status in ('OPEN','CLEARED')),
  cleared_by  text,
  cleared_at  timestamptz,
  created_by  text not null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. AUDIT MARKS (agreed) — immutable ticks at voucher level, 'A' ids.
--    Current audit state is COMPUTED: audited iff latest mark postdates the
--    voucher's latest correction — a correction re-queues the voucher without
--    destroying the record that it was once checked.
-- ---------------------------------------------------------------------------
create table audit_marks (
  mark_id    text primary key,               -- 'A000001'
  voucher_no text not null references vouchers(voucher_no),
  marked_by  text not null,
  marked_at  timestamptz not null default now(),
  note       text
);

create trigger audit_marks_guard
  before update or delete on audit_marks
  for each row execute function trg_ledger_write_guard();

-- ---------------------------------------------------------------------------
-- 4. ACTOR AND PERMISSION HELPERS
--    Identity comes from the signed-in session (Supabase JWT email). When
--    running in the SQL editor as the owner (service role, no JWT), the
--    actor falls back to 'OWNER:SQL-EDITOR' — visible in ENTERED BY, so even
--    escape-hatch writes say who they were.
-- ---------------------------------------------------------------------------
create or replace function fn_actor_email() returns text
language sql stable as $$
  select coalesce(nullif(auth.jwt() ->> 'email', ''), 'OWNER:SQL-EDITOR')
$$;

-- SECURITY DEFINER: these helpers read role_grants/permissions, which carry
-- RLS whose policy calls these very helpers — definer (table owner) context
-- breaks that recursion.
create or replace function fn_actor_roles(p_email text default null) returns text[]
language sql stable security definer set search_path = public as $$
  select case
    when coalesce(p_email, fn_actor_email()) = 'OWNER:SQL-EDITOR' then array['OWNER']
    else coalesce(
      (select array_agg(rg.role)
         from role_grants rg
         join app_users u on u.email = rg.email and u.status = 'ACTIVE'
        where rg.email = coalesce(p_email, fn_actor_email())
          and rg.effective_from <= current_date
          and (rg.effective_to is null or rg.effective_to >= current_date)),
      array[]::text[])
  end
$$;

create or replace function fn_has_capability(p_capability text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from permissions p
    where p.capability = p_capability and p.allowed
      and p.role = any (fn_actor_roles()))
$$;

create or replace function fn_require(p_capability text) returns void
language plpgsql stable as $$
begin
  if not fn_has_capability(p_capability) then
    raise exception 'Not permitted: % (signed in as %)', p_capability, fn_actor_email();
  end if;
end $$;

create or replace function fn_config(p_key text) returns text
language sql stable as $$ select value from config where key = p_key $$;

-- Write-token wrapper: only these functions may modify ledger tables.
create or replace function fn_ledger_write_on() returns void
language sql as $$ select set_config('app.ledger_write','on', true) $$;  -- true = transaction-local

-- ---------------------------------------------------------------------------
-- 5. POSTING GENERATION (internal; called by save/correct/reverse)
--    Resolution order (agreed): PERSONAL→Drawings, then best ACTIVITY rule
--    by specificity, then Suspense + flag. Pocket side from MODE rule
--    (account_out on DR rows, account_in on CR rows).
-- ---------------------------------------------------------------------------
create or replace function fn_resolve_activity_account(
  p_activity text, p_entity text, p_capex text, p_date date)
returns text language sql stable as $$
  select account_out from posting_rules
   where rule_kind = 'ACTIVITY'
     and (match_code = p_activity or match_code = '*')
     and (match_entity is null or match_entity = p_entity)
     and (match_capex  is null or match_capex  = p_capex)
     and effective_from <= p_date
     and (effective_to is null or effective_to >= p_date)
   order by (match_entity is not null)::int + (match_capex is not null)::int desc,
            (match_code <> '*')::int desc,
            effective_from desc
   limit 1
$$;

create or replace function fn_generate_postings(p_row transactions) returns void
language plpgsql as $$
declare
  v_amount   numeric := coalesce(p_row.paid_out_dr, p_row.received_cr);
  v_is_dr    boolean := p_row.paid_out_dr is not null;   -- money going out
  v_side     text;                                       -- activity-side account
  v_pocket   text;                                       -- mode-side account
  v_accrual  date := coalesce(p_row.period_to, p_row.payment_date);
  v_flag_id  text;
begin
  -- pocket side, from the MODE rule
  select case when v_is_dr then account_out else coalesce(account_in, account_out) end
    into v_pocket
    from posting_rules
   where rule_kind = 'MODE' and match_code = p_row.mode
     and effective_from <= p_row.payment_date
     and (effective_to is null or effective_to >= p_row.payment_date)
   order by effective_from desc limit 1;

  -- activity side, with PERSONAL precedence (§1.3)
  if p_row.entity = 'PERSONAL' then
    v_side := '3020';
  else
    v_side := fn_resolve_activity_account(
                p_row.activity, p_row.entity, p_row.capex_flag, p_row.payment_date);
  end if;

  -- unmapped → Suspense + flag (agreed ruling 2: warn, save, park, report)
  if v_side is null or v_pocket is null then
    v_side   := coalesce(v_side,   '1990');
    v_pocket := coalesce(v_pocket, '1990');
    insert into flags (flag_id, row_id, reason_code, note, created_by)
    values (fn_next_row_id('G'), p_row.row_id, 'NO POSTING RULE',
            'activity='||p_row.activity||' mode='||p_row.mode, 'SYSTEM');
  end if;

  -- DR row (paid out): Dr activity-side, Cr pocket. CR row: mirrored.
  insert into ledger_entries (posting_id, txn_row_id, account_code, dr, cr, payment_date, accrual_date)
  values
   (fn_next_row_id('P'), p_row.row_id,
    case when v_is_dr then v_side else v_pocket end, v_amount, null,
    p_row.payment_date, v_accrual),
   (fn_next_row_id('P'), p_row.row_id,
    case when v_is_dr then v_pocket else v_side end, null, v_amount,
    p_row.payment_date, v_accrual);
end $$;

-- ---------------------------------------------------------------------------
-- 6. SAVE VOUCHER — the front door. Header + lines as JSON; validates,
--    issues the serial transactionally, inserts lines, generates postings,
--    raises soft flags. Returns voucher_no, row_ids, warnings.
--
--    lines: [{payment_date, period_from, period_to, entity, farm, block,
--             cost_object, activity, capex_flag, cost_nature, qty, unit,
--             mandays, rate, paid_out_dr, received_cr, mode, party_code,
--             payee, narration, flag_reason, flag_note}]
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
begin
  perform fn_require('ENTER_VOUCHER');
  perform fn_ledger_write_on();

  if jsonb_array_length(p_lines) = 0 then
    raise exception 'A voucher needs at least one line';
  end if;

  -- all lines share the header payment date (v9 model: one date per voucher;
  -- PERIOD FROM/TO differ per line, §2)
  v_pdate := (p_lines -> 0 ->> 'payment_date')::date;

  if v_pdate > current_date then
    raise exception 'Future payment dates are blocked (§4)';
  end if;
  if v_pdate <= v_closed_upto then
    -- The PRIOR PERIOD exception to the lock (§4): late voucher for a closed
    -- FY keeps its true date, takes the CURRENT-FY series, and is flagged.
    -- Note: this also admits a fat-fingered ancient date — the warning
    -- carries the date so the screen can make it loud.
    v_prior := true;
    v_warnings := v_warnings ||
      format('PRIOR PERIOD: date %s is in a closed period; current-FY serial taken', v_pdate);
  elsif v_pdate < v_open_from then
    raise exception 'Payment date before OPEN FROM % (§4 fat-finger floor)', v_open_from;
  end if;

  -- serial: current-FY series for prior-period vouchers, else the date's own FY
  v_voucher_no := fn_next_voucher_no(case when v_prior then current_date else v_pdate end);

  insert into vouchers (voucher_no, fy_prefix, serial_no, prior_period, created_by)
  values (v_voucher_no,
          split_part(v_voucher_no,'/',1),
          split_part(v_voucher_no,'/',2)::int,
          v_prior, v_actor);

  -- stale-voucher soft flag (§4)
  if current_date - v_pdate > v_stale_days then
    v_warnings := v_warnings || format('Stale voucher: %s days old', current_date - v_pdate);
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_line_no := v_line_no + 1;
    v_row_id  := fn_next_row_id('T');
    v_amt     := coalesce((v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric);

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
      v_line->>'cost_object', v_line->>'activity',
      coalesce(v_line->>'capex_flag','RECURRING'), v_line->>'cost_nature',
      (v_line->>'qty')::numeric, v_line->>'unit',
      (v_line->>'mandays')::numeric, (v_line->>'rate')::numeric,
      (v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric,
      v_line->>'mode', v_line->>'party_code',
      v_line->>'payee', v_line->>'narration',
      v_entry_type, v_actor,
      (v_line->>'flag_reason') is not null, v_line->>'flag_reason')
    returning * into v_row;

    v_row_ids := v_row_ids || v_row_id;

    -- soft-block validations became flags at the screen (§5); the screen sends
    -- flag_reason when the user chose "Continue?". Server-side re-checks:

    -- missing-metric warning (§3F): measurable activity without qty
    select required_unit into v_req_unit
      from master_values where list_name='ACTIVITY' and code = v_line->>'activity';
    if v_req_unit is not null and (v_line->>'qty') is null
       and (v_line->>'flag_reason') is null then
      insert into flags (flag_id, row_id, reason_code, note, created_by)
      values (fn_next_row_id('G'), v_row_id, 'QTY NOT WRITTEN',
              format('%s expects %s', v_line->>'activity', v_req_unit), 'SYSTEM');
      v_warnings := v_warnings ||
        format('Line %s: %s has no %s recorded — flagged', v_line_no, v_line->>'activity', v_req_unit);
    end if;

    -- amount ≠ mandays × rate (§5 soft check)
    if (v_line->>'mandays') is not null and (v_line->>'rate') is not null
       and v_amt is distinct from ((v_line->>'mandays')::numeric * (v_line->>'rate')::numeric) then
      v_warnings := v_warnings ||
        format('Line %s: amount %s ≠ mandays × rate %s', v_line_no, v_amt,
               (v_line->>'mandays')::numeric * (v_line->>'rate')::numeric);
    end if;

    -- user-chosen flag from the screen
    if (v_line->>'flag_reason') is not null then
      insert into flags (flag_id, row_id, reason_code, note, created_by)
      values (fn_next_row_id('G'), v_row_id, v_line->>'flag_reason',
              v_line->>'flag_note', v_actor);
    end if;

    perform fn_generate_postings(v_row);

    -- suspense parking must be SAID at save time, not just flagged (ruling 2)
    if exists (select 1 from flags
               where row_id = v_row_id and reason_code = 'NO POSTING RULE') then
      v_warnings := array_append(v_warnings,
        format('Line %s: no posting rule for %s — parked in Suspense, flagged',
               v_line_no, v_line->>'activity'));
    end if;
  end loop;

  -- probable-duplicate warning (§4): same date + total + payee
  if exists (
    select 1 from transactions t
    where t.payment_date = v_pdate and t.status = 'LIVE'
      and t.voucher_no <> v_voucher_no
      and coalesce(t.payee,'') = coalesce(p_lines -> 0 ->> 'payee','')
    group by t.voucher_no
    having sum(coalesce(t.paid_out_dr, t.received_cr)) =
           (select sum(coalesce((l->>'paid_out_dr')::numeric,(l->>'received_cr')::numeric))
              from jsonb_array_elements(p_lines) l)) then
    v_warnings := array_append(v_warnings, 'Probable duplicate: same date + total + payee (§4)');
  end if;

  return jsonb_build_object(
    'voucher_no', v_voucher_no, 'row_ids', to_jsonb(v_row_ids),
    'entry_type', v_entry_type, 'warnings', to_jsonb(v_warnings));
end $$;

-- ---------------------------------------------------------------------------
-- 7. CORRECT LINE — the supersede path (agreed model). Pre-lock, pre-export
--    only; line-level; voucher number never moves; old version kept, marked;
--    postings regenerated; audit tick voided by computation; fortnightly
--    report lists it (v_corrections_for_report below).
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
    raise exception 'Row % is % — only LIVE lines can be corrected', p_row_id, v_old.status;
  end if;

  -- the hard boundary (agreed): once exported or period-locked, reversal only
  if exists (select 1 from vouchers v where v.voucher_no = v_old.voucher_no
             and v.exported_at is not null) then
    raise exception 'Voucher % already exported to Tally — use fn_reverse_line (§6)', v_old.voucher_no;
  end if;
  if v_old.payment_date <= fn_config('CLOSED_UPTO')::date then
    raise exception 'Period closed upto % — use fn_reverse_line (§6)', fn_config('CLOSED_UPTO');
  end if;

  -- same-day amend window (§6): only your own row, only today
  if p_category = 'SAME DAY AMEND'
     and (v_old.entered_by <> v_actor or v_old.entered_at::date <> current_date) then
    raise exception 'Same-day amend is only for your own entries, today (§6)';
  end if;

  -- date corrections may not cross a financial year: the voucher serial
  -- belongs to its FY (§4). Cross-FY date errors go the reversal route.
  if p_new_line ? 'payment_date'
     and fn_fy_prefix((p_new_line->>'payment_date')::date)
         <> fn_fy_prefix(v_old.payment_date) then
    raise exception 'Date correction crosses the financial year — use fn_reverse_line (§4 serials are FY-bound)';
  end if;

  v_slip := (p_category = 'PAPER WRONG');   -- ruling 3: enter now, slip pending
  v_corr := fn_next_row_id('C');
  v_new_id := fn_next_row_id('T');

  -- retire the old version FIRST (one LIVE line per position — uq_txn_live_line)
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
-- 8. REVERSE LINE — the post-lock/post-export path (§6). Creates a NEW
--    voucher (current-FY serial) holding the reversal row and, optionally,
--    the corrected row. Original stamped REVERSED.
-- ---------------------------------------------------------------------------
create or replace function fn_reverse_line(
  p_row_id text, p_evidence text, p_corrected_line jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_actor text := fn_actor_email();
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
    raise exception 'Row % is % — nothing to reverse', p_row_id, v_old.status;
  end if;

  v_vno  := fn_next_voucher_no(current_date);
  v_corr := fn_next_row_id('C');
  v_rev  := fn_next_row_id('T');

  insert into vouchers (voucher_no, fy_prefix, serial_no, created_by)
  values (v_vno, split_part(v_vno,'/',1), split_part(v_vno,'/',2)::int, v_actor);

  -- equal-and-opposite row, REVERSAL OF:<id> via ref_row_id (§6)
  insert into transactions (
    row_id, voucher_no, line_no, payment_date, entity, farm, block,
    cost_object, activity, capex_flag, cost_nature, mode, party_code,
    paid_out_dr, received_cr, payee,
    narration, entry_type, ref_row_id, entered_by)
  values (
    v_rev, v_vno, 1, current_date, v_old.entity, v_old.farm, v_old.block,
    v_old.cost_object, v_old.activity, v_old.capex_flag, v_old.cost_nature,
    v_old.mode, v_old.party_code,
    v_old.received_cr, v_old.paid_out_dr,          -- swapped: the mirror
    v_old.payee,
    'Reversal of '||p_row_id||': '||p_evidence, 'REVERSAL', p_row_id, v_actor)
  returning * into v_row;
  perform fn_generate_postings(v_row);

  -- Mark the original REVERSED — a MARKER, not an exclusion. Unlike
  -- supersede, the original stays in the arithmetic (Tally already has it;
  -- §6): the mirror row nets it to zero. Its postings stay LIVE for the
  -- same reason. v_ledger therefore includes REVERSED rows.
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
      v_cor, v_vno, 2, current_date,
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
-- 9. CANCEL VOUCHER (§4: number kept, status CANCELLED; duplicates and
--    fictitious vouchers, per the taxonomy)
-- ---------------------------------------------------------------------------
create or replace function fn_cancel_voucher(p_voucher_no text, p_category text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_corr text;
begin
  perform fn_require('CANCEL_VOUCHER');
  if p_category not in ('DUPLICATE','FICTITIOUS') then
    raise exception 'Cancellation category must be DUPLICATE or FICTITIOUS';
  end if;
  perform fn_ledger_write_on();

  if exists (select 1 from vouchers where voucher_no = p_voucher_no and exported_at is not null) then
    raise exception 'Voucher % already exported — reverse its lines instead', p_voucher_no;
  end if;

  update vouchers set status='CANCELLED', cancel_reason=p_reason,
         cancelled_by=v_actor, cancelled_at=now()
   where voucher_no = p_voucher_no and status = 'ACTIVE';
  if not found then raise exception 'Voucher % not found or already cancelled', p_voucher_no; end if;

  update transactions set status='CANCELLED' where voucher_no=p_voucher_no and status='LIVE';
  update ledger_entries set status='REVERSED'
   where txn_row_id in (select row_id from transactions where voucher_no=p_voucher_no)
     and status='LIVE';

  v_corr := fn_next_row_id('C');
  insert into correction_log (correction_id, target_row_id, category, evidence, created_by)
  values (v_corr, p_voucher_no, p_category, p_reason, v_actor);
end $$;

-- ---------------------------------------------------------------------------
-- 10. AUDIT TICK (agreed): voucher-level, immutable marks, self-audit refused.
-- ---------------------------------------------------------------------------
create or replace function fn_tick_audited(p_voucher_no text, p_note text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_id text;
begin
  perform fn_require('AUDIT_TICK');
  if exists (select 1 from transactions
             where voucher_no = p_voucher_no and entered_by = v_actor) then
    raise exception 'Cannot audit your own entries (agreed rule)';
  end if;
  if not exists (select 1 from vouchers where voucher_no = p_voucher_no) then
    raise exception 'Voucher % not found', p_voucher_no;
  end if;
  v_id := fn_next_row_id('A');
  insert into audit_marks (mark_id, voucher_no, marked_by, note)
  values (v_id, p_voucher_no, v_actor, p_note);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 11. MASTERS ADMIN — append / relabel / deactivate (owner ruling on delete:
--     free only while unused).
-- ---------------------------------------------------------------------------
create or replace function fn_master_append(
  p_list text, p_code text, p_label text, p_attrs jsonb default '{}')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (fn_has_capability('MASTER_MANAGE') or fn_has_capability('MASTER_APPEND')) then
    raise exception 'Not permitted: master append';
  end if;
  insert into master_values (list_name, code, label,
    cost_object_type, output_unit, sellable, mode_kind, parent_farm,
    required_unit, attributed_to, sort_order, notes)
  values (p_list, p_code, p_label,
    p_attrs->>'cost_object_type', p_attrs->>'output_unit',
    (p_attrs->>'sellable')::boolean, p_attrs->>'mode_kind', p_attrs->>'parent_farm',
    p_attrs->>'required_unit', p_attrs->>'attributed_to',
    coalesce((p_attrs->>'sort_order')::int, 999), p_attrs->>'notes');
end $$;

create or replace function fn_master_relabel(p_list text, p_code text, p_label text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_require('MASTER_MANAGE');             -- accountant may NOT relabel (§13)
  update master_values set label = p_label
   where list_name = p_list and code = p_code;
  if not found then raise exception 'No such master value %/%', p_list, p_code; end if;
end $$;

create or replace function fn_master_set_active(p_list text, p_code text, p_active boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform fn_require('MASTER_MANAGE');
  update master_values set active = p_active
   where list_name = p_list and code = p_code;
  if not found then raise exception 'No such master value %/%', p_list, p_code; end if;
end $$;

create or replace function fn_master_delete(p_list text, p_code text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_used boolean;
begin
  perform fn_require('MASTER_MANAGE');
  -- delete only while unused (agreed): check the columns that reference lists
  select exists (select 1 from transactions where p_code in
           (farm, block, cost_object, activity, capex_flag, cost_nature, unit, mode, flag_reason))
      or exists (select 1 from history where p_code in
           (farm, block, cost_object, activity, capex_flag, cost_nature, unit, mode, flag_reason))
    into v_used;
  if v_used then
    raise exception '"%" is used by ledger rows — deactivate instead (§13)', p_code;
  end if;
  delete from master_values where list_name = p_list and code = p_code;
end $$;

-- ---------------------------------------------------------------------------
-- 12. USER MANAGEMENT — ADMIN limits (agreed): an ADMIN cannot touch an
--     OWNER account, grant OWNER, or revoke their own ADMIN.
-- ---------------------------------------------------------------------------
create or replace function fn_user_upsert(
  p_email text, p_name text, p_mobile text default null, p_status text default 'ACTIVE')
returns void
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_is_owner boolean := 'OWNER' = any(fn_actor_roles());
begin
  perform fn_require('USER_MANAGE');
  if not v_is_owner and 'OWNER' = any(fn_actor_roles(p_email)) then
    raise exception 'ADMIN cannot modify an OWNER account (agreed rule)';
  end if;
  insert into app_users (email, full_name, mobile, status, created_by)
  values (p_email, p_name, p_mobile, p_status, v_actor)
  on conflict (email) do update
    set full_name = excluded.full_name, mobile = excluded.mobile, status = excluded.status;
end $$;

create or replace function fn_role_grant(
  p_email text, p_role text, p_from date default current_date, p_to date default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_actor text := fn_actor_email(); v_is_owner boolean := 'OWNER' = any(fn_actor_roles());
begin
  perform fn_require('ROLE_GRANT');
  if p_role = 'OWNER' and not v_is_owner then
    raise exception 'Only an OWNER can grant OWNER (agreed rule)';
  end if;
  insert into role_grants (email, role, effective_from, effective_to, granted_by)
  values (p_email, p_role, p_from, p_to, v_actor);
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
  -- supersede, never delete (§4 effective-dating): end the grant today
  update role_grants set effective_to = current_date where id = p_grant_id;
end $$;

-- ---------------------------------------------------------------------------
-- 13. VIEWS — the read surface. Reports read these, never raw tables.
-- ---------------------------------------------------------------------------

-- The book: new + migrated, never physically merged (§8).
-- LIVE rows plus REVERSED rows: a reversed original stays in the arithmetic
-- (its mirror nets it, §6). SUPERSEDED and CANCELLED rows are excluded —
-- those were replacements/never-happened.
create or replace view v_ledger as
  select * from transactions where status in ('LIVE','REVERSED')
  union all
  select * from history where status in ('LIVE','REVERSED');

-- Pocket balances from the FLAT table (§10 trial-balance side A)
create or replace view v_pocket_balances as
  select mode,
         sum(coalesce(received_cr,0)) - sum(coalesce(paid_out_dr,0)) as balance
  from v_ledger group by mode;

-- Account balances from the POSTING layer (§10.3 side B)
create or replace view v_account_balances as
  select le.account_code, coa.name, coa.account_type, coa.cashflow_class,
         sum(coalesce(le.dr,0)) - sum(coalesce(le.cr,0)) as balance
  from ledger_entries le
  join chart_of_accounts coa on coa.account_code = le.account_code
  where le.status = 'LIVE'
  group by le.account_code, coa.name, coa.account_type, coa.cashflow_class;

-- Continuous agreement check (§10.3): flat table vs postings, per txn row.
-- Any row here is an incident, reported like a trial-balance break.
create or replace view v_posting_breaks as
  select t.row_id, coalesce(t.paid_out_dr, t.received_cr) as line_amount,
         sum(coalesce(le.dr,0)) as posted_dr, sum(coalesce(le.cr,0)) as posted_cr
  from transactions t
  left join ledger_entries le on le.txn_row_id = t.row_id and le.status = 'LIVE'
  where t.status = 'LIVE'
  group by t.row_id, t.paid_out_dr, t.received_cr
  having sum(coalesce(le.dr,0)) <> coalesce(t.paid_out_dr, t.received_cr)
      or sum(coalesce(le.cr,0)) <> coalesce(t.paid_out_dr, t.received_cr);

-- Suspense watch (agreed ruling 2): should read zero
create or replace view v_suspense_balance as
  select coalesce(sum(coalesce(dr,0)) - sum(coalesce(cr,0)), 0) as suspense_balance,
         count(distinct txn_row_id) as parked_rows
  from ledger_entries where account_code = '1990' and status = 'LIVE';

-- Voucher audit state (agreed): audited iff latest mark postdates latest correction
create or replace view v_voucher_audit_state as
  select v.voucher_no, v.status,
         max(am.marked_at) as last_audited_at,
         max(t.entered_at) filter (where t.entry_type = 'CORRECTION') as last_corrected_at,
         case
           when max(am.marked_at) is null then 'UNAUDITED'
           when max(t.entered_at) filter (where t.entry_type = 'CORRECTION')
                > max(am.marked_at) then 'RE-QUEUE'
           else 'AUDITED'
         end as audit_state
  from vouchers v
  left join audit_marks am on am.voucher_no = v.voucher_no
  left join transactions t on t.voucher_no = v.voucher_no
  group by v.voucher_no, v.status;

-- Fortnightly report feed (agreed): corrected vouchers + paper-mark status
create or replace view v_corrections_for_report as
  select c.created_at::date as corrected_on,
         t.voucher_no, c.target_row_id, c.category,
         mv.label as category_label, c.evidence,
         c.slip_required, c.slip_done, c.created_by
  from correction_log c
  left join transactions t on t.row_id = c.target_row_id
  left join master_values mv on mv.list_name='CORRECTION_CATEGORY' and mv.code=c.category
  order by c.created_at desc;

-- Party running balances (§10.4): positive = they owe us (debtor)
create or replace view v_party_balances as
  select p.party_code, p.name,
         sum(coalesce(l.received_cr,0)) - sum(coalesce(l.paid_out_dr,0)) as balance
  from parties p
  left join v_ledger l on l.party_code = p.party_code
  group by p.party_code, p.name;

-- Sequence integrity (§4): any gap is an incident
create or replace view v_serial_gaps as
  select fy_prefix, s.serial_no + 1 as missing_from
  from (select fy_prefix, serial_no,
               lead(serial_no) over (partition by fy_prefix order by serial_no) as next_no
        from vouchers) s
  where s.next_no is not null and s.next_no <> s.serial_no + 1;

-- ---------------------------------------------------------------------------
-- 14. ROW-LEVEL SECURITY
--     Reads: any ACTIVE user with a current role. Writes: nobody directly —
--     only the SECURITY DEFINER functions above (they bypass RLS as the
--     definer and enforce roles themselves). The service-role key bypasses
--     everything: server-side only (§14.1).
-- ---------------------------------------------------------------------------
create or replace function fn_is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select fn_actor_email() = 'OWNER:SQL-EDITOR'
      or array_length(fn_actor_roles(), 1) > 0
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'master_values','block_ownership','app_users','role_grants','permissions',
    'config','row_id_counters','parties','vouchers','voucher_serials',
    'transactions','history','chart_of_accounts','posting_rules',
    'ledger_entries','correction_log','flags','audit_marks']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists read_all on %I', t);
    execute format(
      'create policy read_all on %I for select using (fn_is_active_user())', t);
    -- no insert/update/delete policies: denied by default for all app roles
  end loop;
end $$;

-- ============================================================================
-- End of file 4. The ledger core is complete.
-- Smoke test (run in the SQL editor after all four files):
--   select fn_save_voucher('[{"payment_date":"2026-07-18","entity":"BUSINESS",
--     "farm":"KLN","cost_object":"LAND","activity":"FENCE VINE REMOVAL",
--     "qty":800,"unit":"FEET","mandays":12,"rate":333,
--     "paid_out_dr":4000,"mode":"CASH","payee":"Murugan",
--     "narration":"Wire fence vine removal, 800 ft"}]'::jsonb);
--   select * from v_pocket_balances;   -- CASH −4000
--   select * from v_account_balances;  -- 5020 Dr 4000 / 1020 Cr 4000
--   select * from v_posting_breaks;    -- must be empty
-- ============================================================================
