-- https://github.com/rjshvjy/farm-software/blob/main/sql/15_voucher_shapes.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — FILE 15 : VOUCHER SHAPES
-- Written 20-07-2026 against DB_SCHEMA_CURRENT generated 20/07 12:25 IST.
-- Run after file 14. Re-runnable. Regenerate the snapshot after applying.
-- Spec: Requirements v3.0 Part 0.3, Part 0.5, §18.5, §16.15, §16.20.
--
-- WHAT THIS FILE IS FOR
--
--   The flat table was designed when every row was an expense: farm,
--   cost_object and activity are all NOT NULL. A settlement — a customer
--   paying his account — has none of them, because nothing happened on the
--   land; a balance moved. So a receipt CANNOT BE STORED today without
--   inventing values, and inventing them is what Part 0.5 forbids.
--
--   This file makes the table able to hold both shapes, and teaches the save
--   and posting functions which shape they are looking at.
--
-- THE SHAPE IS DATA, NOT A LIST IN CODE
--
--   VOUCHER_TYPE gains voucher_shape and voucher_direction. fn_save_voucher
--   reads them. Adding a voucher type stays a master row (§1.9), and no
--   function carries a list of which types mean what.
--
--     PURCHASE  TRANSACTION  OUT  PB/    SALES    TRANSACTION  IN   SI/
--     PAYMENT   SETTLEMENT   OUT  PV/    RECEIPT  SETTLEMENT   IN   RV/
--     CONTRA    TRANSFER     -    CV/    JOURNAL  JOURNAL      -    JV/
--
--   Owner ruling 20-07: every type carries a prefix, including expenses.
--   Prefixes are master data (file 12), so changing a letter later is one
--   UPDATE, not a migration. CONTRA and JOURNAL are seeded and REFUSED by
--   this path — they have their own screens (§18.5) and their own second-leg
--   problems, and a type that half-works is worse than one that says so.
--
-- WHERE THE OTHER SIDE OF A SETTLEMENT COMES FROM
--
--   parties.control_account (file 14). NOT from an activity with a posting
--   rule of its own — that would be two sources of truth for one account,
--   and they would drift. The branch is on the ROW, not on the voucher type:
--   a line with no activity takes its account from the party. One rule, and
--   it stays true if a future voucher type does the same thing.
--
-- WHAT TALLY DOES, AND WHERE THIS FOLLOWS IT (§0.7)
--
--   Tally never asks for a placeholder: cost centres are absent on a receipt,
--   not filled with a value meaning "not applicable". It hangs the decision
--   on the LEDGER — every ledger carries "Cost Centres are Applicable:
--   Yes/No" — not on the voucher type. chart_of_accounts.dimensions_applicable
--   below is that flag.
--
--   IT IS SEEDED BUT NOT YET ENFORCED ON TRANSACTION ROWS. Household spend
--   posts to 3020 Owner Drawings, a CAPITAL account, which would mean no farm
--   and no cost object — but the live purchase screen sends HOME / NA today
--   and the household treatment is explicitly the next thing to settle (owner,
--   20 July). Enforcing it now would refuse rows the deployed screen still
--   produces. The flag is therefore available to screens and reports, and the
--   refusal is deferred deliberately rather than forgotten.
--
-- A LATENT BUG THIS FILE HAS TO FIX
--
--   fn_reverse_line builds its voucher row with
--       split_part(v_vno,'/',1) as fy_prefix, split_part(v_vno,'/',2) as serial
--   i.e. the FIRST two segments. File 12 fixed exactly this in fn_save_voucher
--   but not here, because payments were unprefixed then. Prefixing every type
--   breaks every reversal: 'PV/26/0001' would store fy_prefix 'PV' and serial
--   26. Fixed below, prefix-safely, and the reversal now takes the voucher
--   type of the row it reverses instead of always drawing the payment series.
--
-- VERIFIED BEFORE WRITING (handover Part 3 §6):
--   - transactions.farm, cost_object, activity are NOT NULL; entity and mode
--     also are and STAY so — every row has an entity and moved through a
--     pocket, settlements included.
--   - cost_nature is already nullable; only fn_save_voucher required it.
--   - period_from / period_to are already nullable; likewise.
--   - fn_save_voucher and fn_reverse_line bodies read from the snapshot;
--     the versions below are those, with the changes marked -- 15:.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. VOUCHER_TYPE — shape, direction, and a prefix on every type
-- ---------------------------------------------------------------------------
alter table master_values add column if not exists voucher_shape text;
alter table master_values add column if not exists voucher_direction text;

comment on column master_values.voucher_shape is
  'VOUCHER_TYPE rows only. TRANSACTION = something happened on the estate, so the line carries activity, farm and cost object. SETTLEMENT = a party balance moved and it carries none of them (Part 0.5). TRANSFER and JOURNAL have their own paths.';
comment on column master_values.voucher_direction is
  'VOUCHER_TYPE rows only. IN = the voucher must receive money on at least one line; OUT = it must pay out on at least one. Mixed vouchers stay legal both ways — sale proceeds with harvest labour deducted is one paper.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'master_values_voucher_shape_chk') then
    alter table master_values add constraint master_values_voucher_shape_chk
      check (voucher_shape is null or voucher_shape in
             ('TRANSACTION','SETTLEMENT','TRANSFER','JOURNAL'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'master_values_voucher_direction_chk') then
    alter table master_values add constraint master_values_voucher_direction_chk
      check (voucher_direction is null or voucher_direction in ('IN','OUT'));
  end if;
end $$;

insert into master_values (list_name, code, label, sort_order, notes) values
 ('VOUCHER_TYPE','PURCHASE','Purchase / expense bill', 5,
  'Something was bought or work was done. Dr expense, Cr pocket or creditor.'),
 ('VOUCHER_TYPE','SALES','Sales invoice', 15,
  'Produce, livestock or lease sold. Dr debtor or pocket, Cr income. Carries the crop, farm and quantity.'),
 ('VOUCHER_TYPE','CONTRA','Contra — between pockets', 25,
  'Bank to cash and back. Reserved; its own screen (§18.5).'),
 ('VOUCHER_TYPE','JOURNAL','Journal', 35,
  'Adjustments with no pocket: depreciation, debit and credit notes, opening balances. Its own path (§17.3).')
on conflict (list_name, code) do nothing;

update master_values set voucher_shape = 'TRANSACTION', voucher_direction = 'OUT',
       voucher_prefix = 'PB'
 where list_name = 'VOUCHER_TYPE' and code = 'PURCHASE';
update master_values set voucher_shape = 'TRANSACTION', voucher_direction = 'IN',
       voucher_prefix = 'SI'
 where list_name = 'VOUCHER_TYPE' and code = 'SALES';
update master_values set voucher_shape = 'SETTLEMENT', voucher_direction = 'OUT',
       voucher_prefix = 'PV'
 where list_name = 'VOUCHER_TYPE' and code = 'PAYMENT';
update master_values set voucher_shape = 'SETTLEMENT', voucher_direction = 'IN',
       voucher_prefix = 'RV'
 where list_name = 'VOUCHER_TYPE' and code = 'RECEIPT';
update master_values set voucher_shape = 'TRANSFER', voucher_prefix = 'CV'
 where list_name = 'VOUCHER_TYPE' and code = 'CONTRA';
update master_values set voucher_shape = 'JOURNAL', voucher_prefix = 'JV'
 where list_name = 'VOUCHER_TYPE' and code = 'JOURNAL';


-- ---------------------------------------------------------------------------
-- 2. chart_of_accounts.dimensions_applicable — Tally's ledger-level flag.
--    Seeded from account_type, then owner-editable: the account declares
--    itself, so a CA-replaced chart keeps working (Part 0.2).
--    SEEDED, NOT YET ENFORCED — see the header.
-- ---------------------------------------------------------------------------
alter table chart_of_accounts
  add column if not exists dimensions_applicable boolean;

update chart_of_accounts
   set dimensions_applicable = (account_type in ('INCOME','EXPENSE'))
 where dimensions_applicable is null;

alter table chart_of_accounts
  alter column dimensions_applicable set default true;

comment on column chart_of_accounts.dimensions_applicable is
  'Does a line posting here carry farm, block, cost object and quantity? Tally''s "Cost Centres are Applicable" (§0.7). True for income and expense — they describe what happened on the land; false for asset, liability and capital, which only say where money sits. Seeded from account_type, owner-editable. Read by screens and reports; the save-time refusal is deferred until the household treatment is settled.';


-- ---------------------------------------------------------------------------
-- 3. THE TABLE CAN NOW HOLD BOTH SHAPES
--    entity and mode stay NOT NULL: every row has an entity, and every row
--    moved through a pocket — settlements included. Only the three dimension
--    columns become nullable.
-- ---------------------------------------------------------------------------
alter table transactions alter column farm        drop not null;
alter table transactions alter column cost_object drop not null;
alter table transactions alter column activity    drop not null;

-- Defence in depth beneath the save function: a line with no activity is a
-- settlement, so it must name a party and carry no dimensions. A line with an
-- activity is a transaction. Nothing in between is a shape this system has.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'transactions_shape_chk') then
    alter table transactions add constraint transactions_shape_chk
      check (
        activity is not null
        or (farm is null and cost_object is null and block is null
            and qty is null and mandays is null and party_code is not null)
      );
  end if;
end $$;

comment on constraint transactions_shape_chk on transactions is
  'Two shapes, no third (Part 0.5). With an activity: a transaction line, dimensions allowed. Without: a settlement — it names a party and carries no dimensions, because nothing happened on the land.';


-- ---------------------------------------------------------------------------
-- 4. fn_generate_postings — a settlement takes its other side from the party
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

  -- 15: THE OTHER SIDE.
  -- A line with NO ACTIVITY is a settlement: the account is the party's own
  -- control account (file 14, Part 0.4). Deliberately branched on the ROW and
  -- not on the voucher type — one rule, and it stays true if another voucher
  -- type ever does the same thing. Deliberately NOT via an activity with its
  -- own posting rule: that would be two sources of truth for one account.
  if p_row.activity is null then
    select control_account into v_side
      from parties where party_code = p_row.party_code;

  -- activity side, with PERSONAL precedence (§1.3)
  elsif p_row.entity = 'PERSONAL' then
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
            case when p_row.activity is null
                 then 'settlement: party '||coalesce(p_row.party_code,'(none)')||' has no control account'
                 else 'activity='||p_row.activity end
            ||' mode='||p_row.mode, 'SYSTEM');
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
  'Two balanced legs per line (§10.3). File 12 added the entity x account-type guard. File 15: a line with NO activity is a settlement and takes its other side from the party''s control account (Part 0.4) — branched on the row, not the voucher type.';


-- ---------------------------------------------------------------------------
-- 5. fn_save_voucher — shape-aware. Full replace; every change is marked
--    -- 15:. The three-argument signature is dropped first (the file 11
--    lesson: never leave a stale overload beside a new one).
-- ---------------------------------------------------------------------------
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
  v_vtype        text := upper(coalesce(nullif(trim(p_voucher_type), ''), 'PURCHASE'));
  -- 15: the type's own shape and direction, read from the VOUCHER_TYPE master
  v_shape        text;      -- TRANSACTION | SETTLEMENT | TRANSFER | JOURNAL
  v_dir          text;      -- IN | OUT | null
  v_settle       boolean;   -- shorthand: this voucher settles a party balance
  v_ctrl         text;      -- the party's control account, settlements only
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

  -- 15: shape and direction come from the VOUCHER_TYPE master, never from a
  -- list in here. Adding a voucher type stays a master row (§1.9).
  select voucher_shape, voucher_direction into v_shape, v_dir
    from master_values
   where list_name = 'VOUCHER_TYPE' and code = v_vtype and active;
  if not found then
    raise exception 'Unknown or inactive voucher type "%".', v_vtype;
  end if;
  v_settle := (v_shape = 'SETTLEMENT');

  if v_shape not in ('TRANSACTION','SETTLEMENT') then
    raise exception
      'Voucher type "%" is not entered through this path yet. Contra and journal have their own screens (§18.5).',
      v_vtype;
  end if;

  -- 15: direction, from the master. Mixed vouchers stay legal both ways —
  -- sale proceeds minus harvest labour deducted is one paper — so what a
  -- type demands is at least one line in ITS OWN direction.
  if v_dir = 'IN' and v_cr_total = 0 then
    raise exception
      'A % voucher must receive money on at least one line. For money out only, use an out voucher.', v_vtype;
  end if;
  if v_dir = 'OUT' and v_dr_total = 0 then
    raise exception
      'A % voucher must pay money out on at least one line. For money in only, use an in voucher.', v_vtype;
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

    select mode_kind into v_mode_kind
      from master_values where list_name = 'MODE' and code = v_mode;

    -- 15: THE SHAPE RULES. A settlement moves a balance; nothing happened on
    -- the land, so it carries no dimension and no activity (Part 0.5, §16.15).
    -- A transaction line is the opposite: it must say what and where.
    if v_settle then
      if v_party is null then
        raise exception
          'Line %: a settlement must name the party whose balance is moving. Without it the money has nowhere to land.',
          v_line_no;
      end if;
      if v_activity is not null or v_farm is not null
         or nullif(trim(coalesce(v_line->>'cost_object','')),'') is not null
         or (v_line->>'qty') is not null or (v_line->>'mandays') is not null
         or v_cost_nature is not null then
        raise exception
          'Line %: a settlement carries no activity, farm, cost object, quantity or cost nature — nothing happened on the land, a balance moved (Part 0.5). The screen should not be sending them.',
          v_line_no;
      end if;
      if v_mode_kind = 'CREDIT' then
        raise exception
          'Line %: money cannot be settled "on credit". Pick the pocket it actually moved through.',
          v_line_no;
      end if;
      -- the party's own control account is the other side of the posting
      select control_account into v_ctrl from parties where party_code = v_party;
      if v_ctrl is null then
        raise exception
          'Line %: party "%" has no control account, so the balance has nowhere to live (Part 0.4). Set it on the party first.',
          v_line_no, v_party;
      end if;
      -- a settlement covers no work period; the payment date IS the date
      if v_pfrom is null then v_pfrom := v_pdate; end if;
      if v_pto   is null then v_pto   := v_pdate; end if;
    else
      if v_activity is null then
        raise exception 'Line %: an activity is needed — what was bought, done or sold.', v_line_no;
      end if;
      if v_farm is null then
        raise exception 'Line %: a farm is needed.', v_line_no;
      end if;
      if nullif(trim(coalesce(v_line->>'cost_object','')),'') is null then
        raise exception 'Line %: a cost object is needed — what carries this.', v_line_no;
      end if;
    end if;

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
    if coalesce(v_is_vague, false) or v_is_onetime then
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

    -- A5: the period, typed once in the header and inherited. A settlement
    -- has already had it defaulted to the payment date (15).
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

    -- A7: cost nature - what KIND of spending this was. Transaction lines
    -- only: 15 forbids it outright on a settlement, above.
    if not v_settle and v_cost_nature is null then
      raise exception
        'Line %: cost nature is needed - labour, material, machine hire, transport, contract or other. Split the line if the work used more than one.',
        v_line_no;
    end if;

    -- A1: a bank movement always names its counterparty
    -- 12: same rule both directions, wording per direction — on a receipt
    -- the bank statement names who paid, and the book must match it.
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

    -- A6: block unchosen, but ONLY where the farm actually has blocks.
    -- 15: skipped entirely on a settlement — there is no farm to ask about.
    select exists (
      select 1 from master_values
       where list_name = 'BLOCK' and active
         and parent_farm = v_farm)
      into v_farm_blocks;

    if not v_settle and v_farm_blocks
       and coalesce(v_block, 'YET TO ASSIGN') = 'YET TO ASSIGN' then
      v_flags := v_flags || 'BLOCK NOT CHOSEN'::text;
      v_notes := v_notes || format('%s has blocks in the master; none chosen', v_farm);
    end if;

    -- section 5B: a vague head is always flagged
    if coalesce(v_is_vague, false) then
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
    if not v_settle and v_req_unit is not null and (v_line->>'qty') is null then
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
  'The front door for TRANSACTION and SETTLEMENT vouchers (file 15). Shape and direction are read from the VOUCHER_TYPE master, never from a list in here: a transaction line must say what and where, a settlement must name a party and carry no dimensions (Part 0.5). Contra and journal are refused — they have their own paths.';


-- ---------------------------------------------------------------------------
-- 6. fn_reverse_line — prefix-safe, and it inherits the voucher type.
--    Full replace. The two -- 15: blocks are the only changes; everything
--    else is byte-for-byte the live function from the 12:25 snapshot.
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
  v_vtype text;      -- 15:
  v_parts text[];    -- 15:
begin
  perform fn_require('REVERSE_LINE');
  perform fn_ledger_write_on();

  select * into v_old from transactions where row_id = p_row_id for update;
  if not found then raise exception 'Row % not found', p_row_id; end if;
  if v_old.status <> 'LIVE' then
    raise exception 'Row % is % - nothing to reverse', p_row_id, v_old.status;
  end if;

  -- 15: a reversal belongs to the same book as the row it reverses. Until now
  -- it always drew the payment series, which was harmless only while payments
  -- were the one prefix-less type.
  select voucher_type into v_vtype from vouchers where voucher_no = v_old.voucher_no;
  v_vtype := coalesce(v_vtype, 'PURCHASE');

  v_vno  := fn_next_voucher_no(v_today, v_vtype);
  v_corr := fn_next_row_id('C');
  v_rev  := fn_next_row_id('T');

  -- 15: PREFIX-SAFE. This read split_part(v_vno,'/',1) and (...,2) — the FIRST
  -- two segments — so 'PV/26/0001' would have stored fy_prefix 'PV' and serial
  -- 26. File 12 fixed the same bug in fn_save_voucher and missed this one,
  -- because payments carried no prefix then. fy and serial are the LAST two
  -- segments, whatever prefix the master gave the series.
  v_parts := string_to_array(v_vno, '/');
  insert into vouchers (voucher_no, voucher_type, fy_prefix, serial_no, created_by)
  values (v_vno, v_vtype,
          v_parts[array_length(v_parts,1) - 1],
          v_parts[array_length(v_parts,1)]::int, v_actor);

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

  update transactions set status = 'REVERSED' where row_id = p_row_id;

  insert into correction_log (correction_id, target_row_id, category,
                              reversal_row_id, evidence, created_by)
  values (v_corr, p_row_id, 'REVERSAL', v_rev, p_evidence, v_actor);

  if p_corrected_line is not null then
    v_cor := (fn_save_voucher(jsonb_build_array(p_corrected_line), 'CORRECTION')
              ->>'voucher_no');
    update correction_log set replacement_row_id = v_cor where correction_id = v_corr;
  end if;

  return jsonb_build_object('reversal_voucher_no', v_vno, 'reversal_row_id', v_rev,
                            'correction_id', v_corr, 'replacement', v_cor);
end $$;

comment on function fn_reverse_line(text, text, jsonb) is
  'Equal-and-opposite row after period lock or export (§6). File 15: takes the voucher type of the row it reverses, and parses the serial prefix-safely — it read the first two segments, which broke the moment every type carried a prefix.';


-- ---------------------------------------------------------------------------
-- 7. PostgREST schema cache (convention since 20-07-2026).
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';


-- ============================================================================
-- SMOKE TESTS — one paste, one table, no residue.
--
-- The headline test is the one file 14 could not run: a credit sale, then the
-- collection that clears it, and the balance back to zero. That full cycle has
-- never been possible in this system until now.
-- ============================================================================

drop table if exists zz_s15;
create temp table zz_s15 (seq int, what text, expected text, result text, detail text);

do $$
declare
  v_date date := date '2026-07-17';
  v_pfx  text := fn_fy_prefix(date '2026-07-17');
  v_party text := 'ZZCYCLE';
  v_v text[] := '{}';
  v_before jsonb := '{}'::jsonb;
  v_bal numeric; v_res jsonb; v_no text; v_seq int := 0; v_lines jsonb; v_n int;
begin
  -- remember every counter this test may touch, to restore afterwards
  select jsonb_object_agg(voucher_type, last_no) into v_before
    from voucher_serials where fy_prefix = v_pfx;

  perform fn_party_upsert(v_party, 'ZZ Full Cycle Buyer', 'CUSTOMER');

  -- 1. credit sale — a TRANSACTION line, dimensions and all
  v_seq := v_seq + 1;
  v_lines := jsonb_build_array(jsonb_build_object(
    'payment_date', v_date, 'period_from', v_date, 'period_to', v_date,
    'entity','BUSINESS','farm','NTH','block','YET TO ASSIGN',
    'cost_object','COCONUT','activity','PRODUCE SALE',
    'capex_flag','RECURRING','cost_nature','OTHER',
    'qty',500,'unit','NOS','received_cr',12000,
    'mode','ON CREDIT','party_code',v_party,
    'narration','Full cycle test: nuts sold on credit'));
  v_res := fn_save_voucher(v_lines, null, 'SALES');
  v_no := v_res->>'voucher_no'; v_v := v_v || v_no;
  select balance into v_bal from v_party_balances where party_code = v_party;
  insert into zz_s15 values (v_seq, 'Sales invoice takes the SI series and raises the balance',
    'SI/26/nnnn, Rs.12,000 owed',
    case when v_no like 'SI/'||v_pfx||'/%' and v_bal = 12000 then 'PASS' else 'FAIL' end,
    v_no || ', balance ' || v_bal);

  -- 2. THE COLLECTION — a SETTLEMENT line. No activity, no farm, no crop.
  v_seq := v_seq + 1;
  v_lines := jsonb_build_array(jsonb_build_object(
    'payment_date', v_date, 'entity','BUSINESS',
    'received_cr',12000,'mode','CASH','party_code',v_party,
    'narration','Full cycle test: buyer settles his account'));
  v_res := fn_save_voucher(v_lines, null, 'RECEIPT');
  v_no := v_res->>'voucher_no'; v_v := v_v || v_no;
  select balance into v_bal from v_party_balances where party_code = v_party;
  insert into zz_s15 values (v_seq, 'Receipt clears it — THE CYCLE THAT NEVER WORKED',
    'RV/26/nnnn, balance back to 0',
    case when v_no like 'RV/'||v_pfx||'/%' and v_bal = 0 then 'PASS' else 'FAIL' end,
    v_no || ', balance ' || v_bal);

  -- 3. the settlement posted to the control account, not to suspense
  v_seq := v_seq + 1;
  select count(*) into v_n from ledger_entries le
    join transactions t on t.row_id = le.txn_row_id
   where t.voucher_no = v_no and le.account_code = '1310' and le.cr is not null;
  insert into zz_s15 values (v_seq, 'It credited debtors 1310, not Suspense',
    '1 credit leg on 1310',
    case when v_n = 1 then 'PASS' else 'FAIL' end, 'legs found: ' || v_n);

  -- 4. a settlement carrying dimensions is refused
  v_seq := v_seq + 1;
  begin
    v_lines := jsonb_build_array(jsonb_build_object(
      'payment_date', v_date, 'entity','BUSINESS','farm','NTH',
      'cost_object','COCONUT','activity','PRODUCE SALE',
      'received_cr',100,'mode','CASH','party_code',v_party,
      'narration','Settlement wrongly carrying a crop'));
    v_res := fn_save_voucher(v_lines, null, 'RECEIPT');
    v_v := v_v || (v_res->>'voucher_no');
    insert into zz_s15 values (v_seq, 'Settlement carrying a crop', 'refused', 'FAIL',
      'it saved as ' || (v_res->>'voucher_no'));
  exception when others then
    insert into zz_s15 values (v_seq, 'Settlement carrying a crop', 'refused', 'PASS', SQLERRM);
  end;

  -- 5. a settlement with no party is refused
  v_seq := v_seq + 1;
  begin
    v_lines := jsonb_build_array(jsonb_build_object(
      'payment_date', v_date, 'entity','BUSINESS',
      'received_cr',100,'mode','CASH',
      'narration','Settlement naming nobody at all'));
    v_res := fn_save_voucher(v_lines, null, 'RECEIPT');
    v_v := v_v || (v_res->>'voucher_no');
    insert into zz_s15 values (v_seq, 'Settlement naming no party', 'refused', 'FAIL',
      'it saved as ' || (v_res->>'voucher_no'));
  exception when others then
    insert into zz_s15 values (v_seq, 'Settlement naming no party', 'refused', 'PASS', SQLERRM);
  end;

  -- 6. a purchase still needs its dimensions
  v_seq := v_seq + 1;
  begin
    v_lines := jsonb_build_array(jsonb_build_object(
      'payment_date', v_date, 'period_from', v_date, 'period_to', v_date,
      'entity','BUSINESS','cost_nature','LABOUR',
      'paid_out_dr',500,'mode','CASH','payee','ZZ TEST',
      'narration','Purchase with no activity at all'));
    v_res := fn_save_voucher(v_lines, null, 'PURCHASE');
    v_v := v_v || (v_res->>'voucher_no');
    insert into zz_s15 values (v_seq, 'Purchase without an activity', 'refused', 'FAIL',
      'it saved as ' || (v_res->>'voucher_no'));
  exception when others then
    insert into zz_s15 values (v_seq, 'Purchase without an activity', 'refused', 'PASS', SQLERRM);
  end;

  -- 7. contra is seeded but not enterable here, and says so
  v_seq := v_seq + 1;
  begin
    v_lines := jsonb_build_array(jsonb_build_object(
      'payment_date', v_date, 'entity','FUNDING',
      'paid_out_dr',1000,'mode','CASH','party_code',v_party,
      'narration','Contra attempted through the wrong path'));
    v_res := fn_save_voucher(v_lines, null, 'CONTRA');
    v_v := v_v || (v_res->>'voucher_no');
    insert into zz_s15 values (v_seq, 'Contra through this path', 'refused, own screen', 'FAIL',
      'it saved as ' || (v_res->>'voucher_no'));
  exception when others then
    insert into zz_s15 values (v_seq, 'Contra through this path', 'refused, own screen', 'PASS', SQLERRM);
  end;

  -- ---- clean up ----------------------------------------------------------
  perform fn_ledger_write_on();
  delete from ledger_entries where txn_row_id in
    (select row_id from transactions where voucher_no = any (v_v));
  delete from flags where row_id in
    (select row_id from transactions where voucher_no = any (v_v));
  delete from transactions where voucher_no = any (v_v);
  delete from vouchers    where voucher_no = any (v_v);
  delete from parties     where party_code = v_party;

  delete from voucher_serials
   where fy_prefix = v_pfx and not (v_before ? voucher_type);
  update voucher_serials vs set last_no = (v_before ->> vs.voucher_type)::int
   where vs.fy_prefix = v_pfx and v_before ? vs.voucher_type;

  v_seq := v_seq + 1;
  select count(*) into v_n from transactions where voucher_no = any (v_v);
  insert into zz_s15 values (v_seq, 'Cleanup: nothing left behind', '0 rows',
    case when v_n = 0 then 'PASS' else 'FAIL' end,
    v_n || ' rows remain; ' || coalesce(array_length(v_v,1),0) || ' vouchers made and removed');
end $$;

select seq, what, expected, result, detail from zz_s15 order by seq;
