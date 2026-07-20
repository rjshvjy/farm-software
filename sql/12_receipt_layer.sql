-- https://github.com/rjshvjy/farm-software/blob/main/sql/12_receipt_layer.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — FILE 12 : THE RECEIPT LAYER
-- Written 20-07-2026 against DB_SCHEMA_CURRENT generated 20/07 11:12 IST.
-- Run after file 11. Re-runnable. Regenerate the snapshot after applying.
--
-- WHAT THIS FILE DOES (plan confirmed 20-07-2026):
--   1. VOUCHER TYPES. Vouchers gain a type (PAYMENT / RECEIPT), each type
--      numbered in its OWN gap-free per-FY series with its own prefix:
--      payments stay 26/0041 exactly as today; receipts become R/26/0001.
--      Owner's ruling: option (b), prefix from a master — the paper serial
--      is inconsequential, the system series per type is what matters.
--      The prefix lives in a new VOUCHER_TYPE master, so the journal's
--      JV/ series later is a master row plus one function call, not DDL.
--   2. THE ENTITY x ACCOUNT-TYPE GUARD. The single most likely receipt
--      error: owner puts in Rs.5,00,000, accountant books it as income.
--      After the activity account is resolved, its account_type (from
--      chart_of_accounts) is checked against the entity:
--        FUNDING  money may never land in an INCOME or EXPENSE account.
--        BUSINESS money may never land in a CAPITAL account.
--      Data-driven: it reads the resolved account's TYPE, never a list of
--      account codes, so it survives the CA replacing the whole chart.
--   3. RECEIPT-SIDE PATTERN WARNING. v_party_receipt_stats, a sibling of
--      v_party_payment_stats (which is left untouched — the deployed
--      screen reads its exact columns). An abnormally large receipt from
--      a party with a history of smaller receipts warns, same
--      PARTY_WARN_MULT config, same 3-prior floor.
--   4. DIRECTION-SCOPED DUPLICATE CHECK. Paying Murugan Rs.5,000 and
--      receiving Rs.5,000 from him the same day is not a duplicate.
--      DR totals compare with DR, CR with CR.
--   5. QUANTITY ON SALES — owner's ruling 20-07: FLAG, never refuse.
--      A chopped tree sells as a lumpsum; forcing a quantity invents
--      data. The existing QTY NOT WRITTEN mechanism (required_unit on
--      the ACTIVITY master) already fires on CR lines — it only needed
--      the income activities to carry a required_unit, seeded here as
--      EDITABLE DATA. The UNIT master already holds LUMPSUM for the
--      genuine lump-sum sale: qty 1, unit LUMPSUM, no flag.
--
-- VERIFIED AGAINST THE SNAPSHOT BEFORE WRITING (per handover Part 3 §6):
--   - fn_save_voucher DOES write received_cr — both amount columns are in
--     its insert and v_amt coalesces both sides. No fix needed there.
--   - fn_generate_postings mirrors CR rows correctly (Dr pocket / Cr side).
--   - v_pocket_balances nets CR minus DR. Correct for receipts as-is.
--   - vouchers UNIQUE (fy_prefix, serial_no) would COLLIDE the moment
--     R/26/0001 and 26/0001 coexist — replaced with a per-type unique.
--   - fn_reverse_line also calls fn_next_voucher_no (one-arg). The new
--     signature defaults to PAYMENT, so reversal vouchers keep taking the
--     payment series. DELIBERATE for now: a reversal has no paper slip of
--     its own. Revisit when the corrections screen is built.
--   - The snapshot does NOT carry posting_rules row data, so the
--     ON CREDIT -> debtors (1310) mapping could not be verified from it.
--     Smoke test 0 below verifies it from the live table. (Suggestion:
--     extend 00_schema_snapshot.sql to inventory posting_rules.)
--
-- WHAT THIS FILE DOES NOT DO:
--   - No journal path. That is the next file, planned separately.
--   - No screen. app/receipt/* follows after the snapshot is regenerated.
--   - fn_correct_line / fn_reverse_line untouched — they compile and run
--     unchanged (vouchers.voucher_type has a default; reversal parsing
--     of unprefixed numbers still holds).
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. VOUCHER_TYPE MASTER + its prefix attribute
--    voucher_prefix is a per-list attribute column, same pattern as
--    mode_kind / required_unit / parent_farm. NULL or '' = no prefix
--    (payments keep their exact current numbers).
-- ---------------------------------------------------------------------------
alter table master_values add column if not exists voucher_prefix text;

comment on column master_values.voucher_prefix is
  'VOUCHER_TYPE rows only: the series prefix (RECEIPT -> R gives R/26/0001). NULL or empty = unprefixed (PAYMENT keeps 26/0041). Codes are immutable as ever; the prefix is data.';

insert into master_values (list_name, code, label, voucher_prefix, sort_order, notes) values
 ('VOUCHER_TYPE','PAYMENT','Payment Voucher', null, 10,
  'Money out. The original series, unprefixed: 26/0041.'),
 ('VOUCHER_TYPE','RECEIPT','Receipt Voucher', 'R', 20,
  'Money in. Own gap-free per-FY series: R/26/0001. Owner ruling 20-07-2026.')
on conflict (list_name, code) do nothing;


-- ---------------------------------------------------------------------------
-- 2. voucher_serials — one counter per (voucher_type, FY)
--    Existing row(s) backfill as PAYMENT via the column default, keeping
--    the live payment counter exactly where it is: the next payment after
--    this file is the next number in the existing run, no gap, no reset.
-- ---------------------------------------------------------------------------
alter table voucher_serials
  add column if not exists voucher_type text not null default 'PAYMENT';

do $$
begin
  -- PK was (fy_prefix); becomes (voucher_type, fy_prefix). Guarded so the
  -- file is re-runnable.
  if exists (select 1 from pg_constraint
              where conname = 'voucher_serials_pkey'
                and pg_get_constraintdef(oid) not like '%voucher_type%') then
    alter table voucher_serials drop constraint voucher_serials_pkey;
    alter table voucher_serials add constraint voucher_serials_pkey
      primary key (voucher_type, fy_prefix);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. vouchers — carry the type; make uniqueness per-type
--    The old UNIQUE (fy_prefix, serial_no) would refuse R/26/0001 the
--    moment payment 26/0001 exists (both are fy 26, serial 1).
-- ---------------------------------------------------------------------------
alter table vouchers
  add column if not exists voucher_type text not null default 'PAYMENT';

comment on column vouchers.voucher_type is
  'VOUCHER_TYPE master code. Each type numbers in its own series (file 12). Validated in fn_next_voucher_no — the only path that issues numbers.';

do $$
begin
  if exists (select 1 from pg_constraint
              where conname = 'vouchers_fy_prefix_serial_no_key') then
    alter table vouchers drop constraint vouchers_fy_prefix_serial_no_key;
  end if;
  if not exists (select 1 from pg_constraint
                  where conname = 'vouchers_type_fy_serial_key') then
    alter table vouchers add constraint vouchers_type_fy_serial_key
      unique (voucher_type, fy_prefix, serial_no);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 4. fn_next_voucher_no — now takes the type
--    The one-argument overload is DROPPED, not left beside the new one:
--    file 11 exists because a stale overload lingered. The default keeps
--    every existing caller (fn_reverse_line) compiling and behaving
--    exactly as before: unqualified calls draw the PAYMENT series.
-- ---------------------------------------------------------------------------
drop function if exists fn_next_voucher_no(date);

create or replace function fn_next_voucher_no(
  p_series_date date,
  p_voucher_type text default 'PAYMENT')
returns text
language plpgsql as $$
declare
  pfx    text := fn_fy_prefix(p_series_date);
  v_pre  text;
  n      integer;
begin
  -- the type must be a live master row — this is the gate that validates
  -- vouchers.voucher_type, since this function is the only number source
  select voucher_prefix into v_pre
    from master_values
   where list_name = 'VOUCHER_TYPE' and code = p_voucher_type and active;
  if not found then
    raise exception 'Unknown or inactive voucher type "%". Add it to the VOUCHER_TYPE master first.', p_voucher_type;
  end if;

  insert into voucher_serials (voucher_type, fy_prefix)
  values (p_voucher_type, pfx)
  on conflict (voucher_type, fy_prefix) do nothing;

  update voucher_serials set last_no = last_no + 1
   where voucher_type = p_voucher_type and fy_prefix = pfx
  returning last_no into n;

  return case when coalesce(v_pre, '') = ''
              then pfx || '/' || lpad(n::text, 4, '0')
              else v_pre || '/' || pfx || '/' || lpad(n::text, 4, '0') end;
end $$;

comment on function fn_next_voucher_no(date, text) is
  'Gap-free serial per (voucher_type, FY). Prefix from the VOUCHER_TYPE master: PAYMENT -> 26/0041 (unchanged), RECEIPT -> R/26/0001. Adding a voucher type is a master row, never DDL (file 12).';


-- ---------------------------------------------------------------------------
-- 5. fn_generate_postings — the entity x account-type guard
--    Full replace; the -- 12: block is the only change, everything else
--    is byte-for-byte the live function.
--
--    THE RULE (data-driven, plan confirmed 20-07):
--      After the activity side resolves to an account, read that
--      account''s TYPE from chart_of_accounts.
--        entity FUNDING  + type INCOME/EXPENSE -> REFUSE.
--          Owner money in is capital, never income (section 13) — the
--          Rs.5-lakh-booked-as-income error, caught structurally.
--        entity BUSINESS + type CAPITAL        -> REFUSE.
--          The mirror: OWNER CAPITAL activity on a BUSINESS line, or a
--          household activity (mapped 3020) filed as farm spend.
--      PERSONAL is exempt BY DESIGN: the precedence rule sends every
--      PERSONAL rupee to 3020 Owner Drawings, which IS a capital account.
--      Skipped for REVERSAL rows (reversing a pre-rule row must never be
--      blocked — reversal is the cleanup tool) and MIGRATED rows (the
--      4,002 legacy rows predate every rule, section 12; if imported,
--      they import as they were).
-- ---------------------------------------------------------------------------
create or replace function fn_generate_postings(p_row transactions) returns void
language plpgsql as $$
declare
  v_amount   numeric := coalesce(p_row.paid_out_dr, p_row.received_cr);
  v_is_dr    boolean := p_row.paid_out_dr is not null;   -- money going out
  v_side     text;                                       -- activity-side account
  v_pocket   text;                                       -- mode-side account
  v_accrual  date := coalesce(p_row.period_to, p_row.payment_date);
  v_flag_id  text;
  v_side_type text;                                      -- 12: resolved account''s type
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

  -- 12: entity x account-type guard (see file header). Checks the RESOLVED
  -- account''s type, never a code list, so a CA-replaced chart still works.
  if v_side is not null
     and p_row.entry_type not in ('REVERSAL','MIGRATED') then
    select account_type into v_side_type
      from chart_of_accounts where account_code = v_side;

    if p_row.entity = 'FUNDING' and v_side_type in ('INCOME','EXPENSE') then
      raise exception
        'Activity "%" posts to % account % — FUNDING money can never be income or expense (section 13). Owner money in is capital. If this is a real sale or cost, the entity is BUSINESS.',
        p_row.activity, lower(v_side_type), v_side;
    end if;

    if p_row.entity = 'BUSINESS' and v_side_type = 'CAPITAL' then
      raise exception
        'Activity "%" posts to capital account % — BUSINESS money can never land in capital (section 1.3). Owner capital movement is entity FUNDING; household spend is PERSONAL.',
        p_row.activity, v_side;
    end if;
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

comment on function fn_generate_postings(transactions) is
  'Two balanced legs per line (§10.3). File 12 adds the entity x account-type guard: FUNDING never posts to income/expense, BUSINESS never to capital — checked on the RESOLVED account''s type, skipped for REVERSAL and MIGRATED rows.';


-- ---------------------------------------------------------------------------
-- 6. v_party_receipt_stats — the receipt mirror of v_party_payment_stats
--    A SIBLING, not a change: the deployed entry screen reads the payment
--    view''s exact columns, and views that screens read do not change
--    shape under them. Same LIVE-only scope, same SAMPLE-rows-included
--    stance (handover Part 3 §3: excluding SAMPLE would leave nothing to
--    demonstrate against; revisit at the final reset).
-- ---------------------------------------------------------------------------
create or replace view v_party_receipt_stats as
  select party_code,
         count(*)           as times_received,
         max(received_cr)   as max_received,
         round(avg(received_cr)) as avg_received,
         max(payment_date)  as last_received
    from transactions
   where party_code is not null
     and received_cr is not null
     and status = 'LIVE'
   group by party_code;

comment on view v_party_receipt_stats is
  'Per-party RECEIPT pattern for the self-calibrating large-amount warning (file 12) — sibling of v_party_payment_stats, which stays untouched for the deployed screen. The receipt screen reads this at load; fn_save_voucher reads it at save.';


-- ---------------------------------------------------------------------------
-- 7. fn_save_voucher — REPLACED IN FULL, now direction- and type-aware
--
--    File 09''s function with the file-12 additions, each marked -- 12:
--    below. Every unmarked line is byte-for-byte the live function (read
--    from the 20/07 11:12 snapshot, not from the numbered files).
--
--    The old two-argument overload is DROPPED first — the file-11 lesson.
--    PostgREST calls with named params resolve to the new signature, and
--    the default keeps every existing app call working unchanged.
--
--    WHAT -- 12: ADDS:
--      a. p_voucher_type (default PAYMENT). Validated against the master
--         by fn_next_voucher_no. A RECEIPT voucher must carry at least one
--         received_cr line; a PAYMENT at least one paid_out_dr. Mixed
--         vouchers stay legal both ways — the real case: sale proceeds
--         with harvest labour deducted is one paper, CR + DR lines.
--         (CONTRA / JOURNAL types will state their own rule when built.)
--      b. Serial from the type''s own series; fy_prefix and serial_no
--         parsed prefix-safely (last two segments, not the first two).
--      c. Bank-needs-party wording knows the direction: on a receipt the
--         statement names who paid, and we record it.
--      d. ONE TIME wording knows the direction (who was paid / who paid
--         us); the rules themselves are unchanged — a one-time party on
--         CREDIT is refused in either direction, since a debt owed BY
--         nobody is as dishonest as one owed TO nobody.
--      e. The pattern warning reads the matching side: DR lines against
--         v_party_payment_stats, CR lines against v_party_receipt_stats.
--         Same PARTY_WARN_MULT, same 3-prior floor.
--      f. The duplicate check compares DR totals with DR and CR with CR —
--         a payment and a receipt of the same figure to the same name on
--         the same day is business, not a duplicate.
-- ---------------------------------------------------------------------------
drop function if exists fn_save_voucher(jsonb, text);

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
  'The front door, both directions since file 12: voucher_type picks the series (PAYMENT 26/0041, RECEIPT R/26/0001), the pattern warning reads the matching side, the duplicate check is direction-scoped, and the entity x account-type guard in fn_generate_postings refuses capital-as-income. Files 08 and 09 rules unchanged.';


-- ---------------------------------------------------------------------------
-- 8. v_serial_gaps — gap-free is now a per-type promise
--    DROPPED and recreated, not replaced: CREATE OR REPLACE VIEW cannot
--    change a view's column list, and voucher_type is a new first column.
--    Safe: nothing in the schema references this view (verified against
--    the snapshot); it is read by hand as an incident check.
-- ---------------------------------------------------------------------------
drop view if exists v_serial_gaps;

create view v_serial_gaps as
  select voucher_type, fy_prefix, s.serial_no + 1 as missing_from
  from (select voucher_type, fy_prefix, serial_no,
               lead(serial_no) over (partition by voucher_type, fy_prefix
                                     order by serial_no) as next_no
        from vouchers) s
  where s.next_no is not null and s.next_no <> s.serial_no + 1;

comment on view v_serial_gaps is
  'Sequence integrity (§4), per (voucher_type, FY) since file 12. Any row is an incident.';


-- ---------------------------------------------------------------------------
-- 9. required_unit on the income activities — DATA, not rule
--    This is what makes the owner''s 20-07 quantity ruling real: a sale
--    without quantity flags QTY NOT WRITTEN and saves. These units are
--    EDITABLE through masters admin / fn_master_set_attrs like any master
--    attribute - they are starting values on a coconut-first estate, not
--    law. Direct UPDATE (the file-01/03 seeding convention for migration
--    context; the MASTER_MANAGE gate guards the app path, not this one).
--    "where required_unit is null" so a value the owner has already set
--    is never clobbered on re-run.
--
--    LEASE RENT and MISC INCOME deliberately get NO required_unit: rent
--    has no natural quantity, and MISC INCOME is already a vague head
--    (VAGUE_ACTIVITIES config) demanding the long narration.
-- ---------------------------------------------------------------------------
update master_values set required_unit = 'NOS'
 where list_name = 'ACTIVITY' and code = 'PRODUCE SALE'  and required_unit is null;
update master_values set required_unit = 'NOS'
 where list_name = 'ACTIVITY' and code = 'LIVESTOCK SALE' and required_unit is null;
update master_values set required_unit = 'LITRE'
 where list_name = 'ACTIVITY' and code = 'MILK SALE'     and required_unit is null;
update master_values set required_unit = 'TREE'
 where list_name = 'ACTIVITY' and code = 'TREE SALE'     and required_unit is null;
update master_values set required_unit = 'NOS'
 where list_name = 'ACTIVITY' and code = 'PRODUCE CONSUMED AT HOME' and required_unit is null;


-- ============================================================================
-- SMOKE TESTS (run by hand, read the output; SAMPLE mode assumed)
--
--  0. VERIFY FIRST (could not be confirmed from the snapshot, which holds
--     no posting_rules rows):
--       select match_code, account_out, account_in from posting_rules
--        where rule_kind = 'MODE' and match_code = 'ON CREDIT';
--     Expect account_out 2010 (creditors), account_in 1310 (debtors).
--     If this row is wrong or absent, STOP - credit sales would post to
--     creditors - and fix the rule before any receipt is saved.
--
--  1. SERIES. Save a receipt (any CASH line with received_cr, entity
--     BUSINESS, activity PRODUCE SALE, qty + unit given, narration fine)
--     -> voucher R/26/0001. Save a payment -> the NEXT number in the
--     existing payment run (no reset, no gap, no R). Save a second
--     receipt -> R/26/0002.
--
--  2. TYPE RULE. Call fn_save_voucher with voucher_type RECEIPT and only
--     paid_out_dr lines -> refused, told to use a payment voucher.
--     Mixed voucher (CR 10000 PRODUCE SALE + DR 2000 FRUIT PLUCKING /
--     HARVEST) as RECEIPT -> saves; cash rises by the net 8000.
--
--  3. THE GUARD, income side. Line: entity FUNDING, activity MISC INCOME,
--     received_cr 500000 -> REFUSED: funding can never be income.
--     Same line with entity BUSINESS -> saves (vague-head narration
--     rules apply). Owner money in done RIGHT - entity FUNDING, activity
--     OWNER CAPITAL / CURRENT A/C -> saves, credits 3010.
--
--  4. THE GUARD, capital side. Line: entity BUSINESS, activity OWNER
--     CAPITAL / CURRENT A/C, paid_out_dr 10000 -> REFUSED: business can
--     never land in capital. Entity PERSONAL, any household activity ->
--     still saves to 3020 (the precedence rule is exempt by design).
--
--  5. QTY FLAG ON SALES. Receipt, PRODUCE SALE, no qty -> saves with
--     QTY NOT WRITTEN flag ("expects NOS"). Same with qty 1, unit
--     LUMPSUM -> saves clean (the chopped-tree case). Qty 200, rate 45,
--     amount 8000 -> warning: does not equal qty x rate (realisation
--     check for free).
--
--  6. RECEIPT PATTERN. After 3+ saved receipts from one party, save one
--     at 3x their largest -> warning quoting their own receipt record.
--     Then a large PAYMENT to the same party -> measured against their
--     payment history only, not their receipts.
--
--  7. DUPLICATE, direction-scoped. Payment Rs.5000 payee Murugan, then
--     receipt Rs.5000 payee Murugan same date -> NO duplicate warning.
--     Second identical receipt -> duplicate warning fires.
--
--  8. REVERSAL SAFETY. fn_reverse_line on any pre-file-12 line -> still
--     works; reversal voucher takes the PAYMENT series (deliberate,
--     see header) and the guard does not fire on REVERSAL rows.
--
-- AFTER RUNNING CLEAN: run 00_schema_snapshot.sql, replace
-- DB_SCHEMA_CURRENT in the project folder. The receipt screen TypeScript
-- will be written against that snapshot, not against this file.
-- ============================================================================
