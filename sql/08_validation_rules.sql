-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 8 : THE VALIDATION DECISIONS (owner's decision table, 19 July 2026)
--
-- Run AFTER files 01-07, in the Supabase SQL editor.
-- Do NOT re-run files 01-04: they drop and recreate tables.
-- Re-runnable on its own. No table structure changes, no existing row touched.
--
-- REVISION 19-07-2026, after testing: the four flag appends carry an explicit
-- ::text cast. Without it Postgres reads a bare quoted literal on the right
-- of || against a text[] as an ARRAY literal and refuses it ("malformed array
-- literal"). Appending a typed variable never had the problem, which is why
-- no earlier file hit it. This file supersedes 08a_fix_flag_append.sql, which
-- contained only the corrected function.
--
--
-- WHY THIS FILE EXISTS
--
-- Sixteen fields were walked one by one and each given one of three answers:
-- REFUSE (the save fails), FLAG (it saves and lands in the review queue), or
-- ALLOW. The governing principle is section 5B: vagueness stays possible but
-- costs something. Textbook practice makes everything mandatory; this system
-- deliberately does not, because an accountant blocked at 6pm invents worse
-- data than an honest blank.
--
-- WHAT WAS DECIDED, AND WHAT THIS FILE BUILDS
--
--   REFUSED (save fails)
--     - Narration shorter than 5 characters, on EVERY line. The owner's
--       reasoning: it is the last chance to identify a wrong posting. Five,
--       not fifteen - "wages" must pass; "x" must not. Vague heads still
--       need their full 15 (file 06).
--     - Period from and period to, both compulsory. Typed once in the header
--       and inherited by every line, so this costs two keystrokes per voucher.
--     - Period to earlier than period from. Arithmetic, not strictness.
--     - A BANK-kind payment with no party. A bank transfer always has a
--       beneficiary; there is no anonymous NEFT.
--     - Cost nature blank. MIS is the point of this system: activity says
--       what the money was for, cost nature says how it was spent, and the
--       two together are what makes "grow fodder or buy it" answerable.
--     - A MODE master value with no mode_kind (schema gap found in testing).
--
--   FLAGGED (saves, lands in the review queue)
--     - A CASH payment naming nobody - no payee and no party.
--     - A block left unchosen WHEN THE FARM ACTUALLY HAS BLOCKS. Silent when
--       it has none, so the rule switches itself on farm by farm as the land
--       survey fills the master in. Nobody configures it.
--
--   ALLOWED, deliberately
--     Blank qty where the activity has no required unit; half-filled
--     mandays/rate; future period dates; a party without a mobile.
--
--   UNCHANGED
--     Amount vs mandays x rate stays a warning. The duplicate guard stays a
--     warning. Both would fire on legitimate entries often enough to teach
--     people to ignore flags, which is the one thing a flag-based system
--     cannot survive.
--
-- ALSO IN HERE, because the decisions require them:
--   - fn_party_upsert. Making party compulsory on bank payments is
--     unbuildable without a way to create a party - there was none. The entry
--     screen will add parties inline, so a bank voucher never hits a wall.
--   - v_new_parties, so the review queue can show parties created mid-entry
--     and merge the duplicates before they compound.
--   - MULTIPLE FLAGS PER ROW. Until now a line could carry one flag; with
--     four automatic reasons a line can honestly earn two. The flags table
--     always allowed it; fn_save_voucher did not.
--
-- NOT IN HERE, deliberately: the correction-evidence minimum (decision B1).
-- It needs full replacements of fn_correct_line, fn_reverse_line and
-- fn_cancel_voucher, and nothing calls those until the corrections screen
-- exists. It goes in the file that builds that screen.


-- ---------------------------------------------------------------------------
-- 1. CONFIG: the narration floor
--
--    Separate from VAGUE_NARRATION_MIN on purpose. They answer different
--    questions: 5 is "you said something"; 15 is "you said something because
--    the classification says nothing".
-- ---------------------------------------------------------------------------
insert into config (key, value, description) values
 ('NARRATION_MIN',
  '5',
  'Minimum narration length on any voucher line (decision A2). Vague heads use the higher VAGUE_NARRATION_MIN.')
on conflict (key) do nothing;


-- ---------------------------------------------------------------------------
-- 2. THE TWO NEW FLAG REASONS
--
--    Both attributed to NOBODY: neither is a fault. A bus fare has no
--    meaningful payee, and a block cannot be chosen before the survey names
--    it. The flag exists so the owner SEES the row, not so anyone is blamed.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from master_values
                  where list_name = 'FLAG_REASON' and code = 'NO PAYEE') then
    perform fn_master_append(
      'FLAG_REASON', 'NO PAYEE',
      'Cash paid, nobody named',
      '{"attributed_to":"NOBODY","sort_order":140,
        "notes":"Cash payment with neither payee nor party (decision A1). Not a fault - some cash genuinely has no named recipient."}'::jsonb);
  end if;

  if not exists (select 1 from master_values
                  where list_name = 'FLAG_REASON' and code = 'BLOCK NOT CHOSEN') then
    perform fn_master_append(
      'FLAG_REASON', 'BLOCK NOT CHOSEN',
      'Farm has blocks, none chosen',
      '{"attributed_to":"NOBODY","sort_order":150,
        "notes":"Raised only when the farm has block values in the master and the line still says YET TO ASSIGN (decision A6). Silent for farms with no blocks yet."}'::jsonb);
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 3. fn_party_upsert — THE MISSING WRITE PATH FOR PARTIES
--
--    Same shape as fn_master_append: MASTER_APPEND is enough, so the
--    accountant can create a party inline while entering a voucher without
--    calling the owner. MASTER_MANAGE (owner) is also accepted.
--
--    Upsert, not insert: re-entering an existing party updates the name and
--    mobile rather than failing. party_code is the stable identity and is
--    never rewritten - the same rename ban as masters (section 13).
--
--    Mobile stays optional (decision C3). A party master that demands full
--    KYC never gets used, and then payees stay free text forever, which is
--    the outcome the party master exists to prevent.
-- ---------------------------------------------------------------------------
create or replace function fn_party_upsert(
  p_code   text,
  p_name   text,
  p_kind   text default 'BOTH',
  p_mobile text default null,
  p_notes  text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_actor text := fn_actor_email();
  v_code  text := upper(trim(p_code));
  v_name  text := trim(p_name);
begin
  if not (fn_has_capability('MASTER_MANAGE') or fn_has_capability('MASTER_APPEND')) then
    raise exception 'Not permitted: add or edit a party';
  end if;

  if v_code is null or v_code = '' then
    raise exception 'A party needs a code';
  end if;
  if v_name is null or v_name = '' then
    raise exception 'A party needs a name';
  end if;
  if p_kind not in ('SUPPLIER','CUSTOMER','BOTH') then
    raise exception 'Party kind must be SUPPLIER, CUSTOMER or BOTH';
  end if;

  insert into parties (party_code, name, kind, mobile, notes, created_by)
  values (v_code, v_name, p_kind, nullif(trim(p_mobile), ''), nullif(trim(p_notes), ''), v_actor)
  on conflict (party_code) do update
    set name   = excluded.name,
        kind   = excluded.kind,
        mobile = coalesce(excluded.mobile, parties.mobile),
        notes  = coalesce(excluded.notes,  parties.notes);

  return v_code;
end $$;

comment on function fn_party_upsert(text, text, text, text, text) is
  'Create or update a party. MASTER_APPEND is enough, so the accountant can add one inline during entry. party_code is immutable.';


-- ---------------------------------------------------------------------------
-- 4. v_new_parties — the review queue's clutter check
--
--    The owner asked for inline party creation to be reviewable. A flag was
--    the obvious answer and is the wrong one: flags hang off a transaction
--    row, and a party is not a transaction. This view is the honest shape -
--    parties created recently, with how many rows have used each. One created
--    yesterday and used once, sitting next to an older party with a similar
--    name, is exactly the clutter to merge before it compounds.
-- ---------------------------------------------------------------------------
create or replace view v_new_parties as
select p.party_code,
       p.name,
       p.kind,
       p.mobile,
       p.created_by,
       p.created_at,
       fn_local_date(p.created_at)                      as created_on,
       count(t.row_id)                                  as rows_using,
       coalesce(sum(t.paid_out_dr), 0)                  as total_paid
from parties p
left join transactions t
       on t.party_code = p.party_code and t.status = 'LIVE'
group by p.party_code, p.name, p.kind, p.mobile, p.created_by, p.created_at
order by p.created_at desc;

comment on view v_new_parties is
  'Parties newest first, with usage counts. The review queue reads this to catch duplicate parties created inline during entry.';


-- ---------------------------------------------------------------------------
-- 5. A MODE MUST KNOW ITS KIND — decision C2
--
--    A mode with no mode_kind breaks posting mapping and slips past the
--    credit-party rule silently. There is no meaningful blank. Enforced in
--    both write paths rather than as a column constraint, because mode_kind
--    is legitimately null on every list that is not MODE.
--
--    Both functions are otherwise identical to their file 05 versions.
-- ---------------------------------------------------------------------------
create or replace function fn_master_append(
  p_list text, p_code text, p_label text, p_attrs jsonb default '{}')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (fn_has_capability('MASTER_MANAGE') or fn_has_capability('MASTER_APPEND')) then
    raise exception 'Not permitted: master append';
  end if;

  -- decision C2
  if p_list = 'MODE' and coalesce(p_attrs->>'mode_kind', '') = '' then
    raise exception
      'A MODE needs a kind: CASH, BANK, CREDIT or OWNER. Without it the posting rules cannot place the money.';
  end if;

  insert into master_values (list_name, code, label,
    cost_object_type, output_unit, sellable, mode_kind, parent_farm,
    required_unit, attributed_to, aliases, sort_order, notes)
  values (p_list, p_code, p_label,
    p_attrs->>'cost_object_type', p_attrs->>'output_unit',
    (p_attrs->>'sellable')::boolean, p_attrs->>'mode_kind', p_attrs->>'parent_farm',
    p_attrs->>'required_unit', p_attrs->>'attributed_to', p_attrs->>'aliases',
    coalesce((p_attrs->>'sort_order')::int, 999), p_attrs->>'notes');
end $$;


create or replace function fn_master_set_attrs(
  p_list  text,
  p_code  text,
  p_attrs jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_exists boolean;
begin
  perform fn_require('MASTER_MANAGE');

  select exists (select 1 from master_values
                  where list_name = p_list and code = p_code)
    into v_exists;
  if not v_exists then
    raise exception 'No such master value %/%', p_list, p_code;
  end if;

  -- decision C2: a MODE may not have its kind cleared
  if p_list = 'MODE' and p_attrs ? 'mode_kind'
     and coalesce(p_attrs->>'mode_kind', '') = '' then
    raise exception
      'A MODE needs a kind: CASH, BANK, CREDIT or OWNER. It cannot be cleared.';
  end if;

  if p_attrs ? 'required_unit' then
    perform fn_assert_master('UNIT', p_attrs->>'required_unit');
  end if;
  if p_attrs ? 'output_unit' then
    perform fn_assert_master('UNIT', p_attrs->>'output_unit');
  end if;
  if p_attrs ? 'parent_farm' then
    perform fn_assert_master('FARM', p_attrs->>'parent_farm');
  end if;

  update master_values set
    aliases          = case when p_attrs ? 'aliases'
                            then p_attrs->>'aliases'          else aliases          end,
    required_unit    = case when p_attrs ? 'required_unit'
                            then p_attrs->>'required_unit'    else required_unit    end,
    notes            = case when p_attrs ? 'notes'
                            then p_attrs->>'notes'            else notes            end,
    sort_order       = case when p_attrs ? 'sort_order'
                            then coalesce((p_attrs->>'sort_order')::int, sort_order)
                            else sort_order end,
    cost_object_type = case when p_attrs ? 'cost_object_type'
                            then p_attrs->>'cost_object_type' else cost_object_type end,
    output_unit      = case when p_attrs ? 'output_unit'
                            then p_attrs->>'output_unit'      else output_unit      end,
    sellable         = case when p_attrs ? 'sellable'
                            then (p_attrs->>'sellable')::boolean else sellable      end,
    mode_kind        = case when p_attrs ? 'mode_kind'
                            then p_attrs->>'mode_kind'        else mode_kind        end,
    parent_farm      = case when p_attrs ? 'parent_farm'
                            then p_attrs->>'parent_farm'      else parent_farm      end,
    attributed_to    = case when p_attrs ? 'attributed_to'
                            then p_attrs->>'attributed_to'    else attributed_to    end
  where list_name = p_list and code = p_code;
end $$;


-- ---------------------------------------------------------------------------
-- 6. fn_save_voucher — REPLACED
--
--    Everything the file 07 version did, it still does: the estate clock,
--    prior-period handling, transactional serials, the vagueness rule,
--    postings, the duplicate and stale warnings.
--
--    NEW, per the decision table:
--      REFUSALS  - narration under NARRATION_MIN (A2)
--                - period from or to missing (A5)
--                - period to before period from (A5)
--                - BANK-kind mode with no party (A1)
--                - cost nature blank (A7)
--      FLAGS     - CASH with neither payee nor party (A1)
--                - block unchosen where the farm has blocks (A6)
--      TRIMMING  - every text field trimmed before any check (D2), so
--                  "   " is recognised as the blank it is
--
--    STRUCTURAL: a line can now carry SEVERAL flags. They are collected in an
--    array, the first becomes transactions.flag_reason (the row's headline),
--    and every one gets its own row in flags. Previously the missing-quantity
--    flag was skipped whenever any other flag existed - that dodge is gone
--    now that the table can say two true things about one line.
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

    -- ---- REFUSALS -------------------------------------------------------

    -- A2: narration on every line. Vague heads need the longer one.
    if v_is_vague then
      if length(v_narration) < v_vague_min then
        raise exception
          'Line %: "%" is a last resort - say what this was actually for. A real description of at least % characters is required, not "misc".',
          v_line_no, v_activity, v_vague_min;
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

    -- ---- FLAGS ----------------------------------------------------------

    -- A1: cash that names nobody
    if v_mode_kind = 'CASH' and v_payee is null and v_party is null then
      v_flags := v_flags || 'NO PAYEE'::text;
      v_notes := v_notes || format('Cash paid, nobody named. %s', v_narration);
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
  'The front door. Enforces the validation decisions of 19-07-2026: narration floor, compulsory period, bank-needs-party, compulsory cost nature, cash-with-no-payee and unchosen-block flags. A line may carry several flags.';


-- After this runs clean, fold files 05 to 08 into the schema.sql snapshot.
-- Section 14 keeps one current-state file, not a chain of migrations.
--
-- NOTE FOR THE SCREEN: voucher 26/0012 and every other row saved before this
-- file predate the new rules. They keep their blanks - rows are immutable
-- (section 13) and nothing retro-flags them. The sample data is cleared at
-- the final reset in any case.
