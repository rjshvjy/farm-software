-- sql/18a_dimensions_by_cost_object.sql
-- github.com/rjshvjy/farm-software
--
-- FILE 18a — THE COST OBJECT DECIDES WHETHER A FARM IS ASKED
-- 21 July 2026 · corrects and extends file 18 · requires files 17a and 18
--
-- ============================================================================
-- WHAT THIS FILE DOES
-- ============================================================================
--
--   1. master_values.land_based    new attribute on COST_OBJECT rows. A cost
--                                  object either sits on land or it does not.
--                                  COW and GOAT do not; the crops do.
--   2. config UNSPLIT_FARMS        which FARM codes mean "not split between
--                                  farms yet". Seeded GENERAL. Owner-editable,
--                                  blank disables the rule.
--   3. FLAG_REASON FARM NOT SPLIT  so the escape hatch is COUNTED
--   4. fn_save_voucher             four corrections, listed below
--
-- ============================================================================
-- WHY — THE DECISION BEHIND IT (owner, 21/07/2026)
-- ============================================================================
--
-- A business expense line has always demanded a farm. That is right for
-- weedicide spraying and wrong for cattle maintenance, because a herd is an
-- enterprise, not a place. Section 1 of the spec already says the system must
-- answer "which farm AND which crop or livestock enterprise is profitable" —
-- two axes, not one. The cows and goats intermingle and are not comparable
-- farm-wise, so "which farm" has no true answer for them and Part 0.5 says a
-- dimension is collected only where it is genuinely answerable.
--
-- THE FACT LIVES ON THE COST OBJECT, so that is where it is stored. COCONUT
-- sits on land. COW does not. NA does not. One attribute on a master the owner
-- already maintains, and no judgement is made at entry: the accountant picks
-- what the money was FOR, and the farm question answers itself.
--
-- Three alternatives were considered and dropped:
--   - a COMMON or ESTATE farm value: unnecessary. GENERAL already exists.
--   - deriving it from the account (direct vs indirect expense): that is a
--     P&L presentation question and belongs to the CA, not to entry. It also
--     fails the case it was meant to solve — a bulk weedicide purchase is a
--     DIRECT cost that still spans four farms.
--   - wiring chart_of_accounts.dimensions_applicable: no longer needed. Staff
--     travel carries cost object NA, NA is not land-based, and the same single
--     test covers it.
--
-- ============================================================================
-- GENERAL, AND WHY IT IS FLAGGED
-- ============================================================================
--
-- GENERAL is for the case land_based cannot reach: a real land cost that
-- genuinely spans farms, like a bulk weedicide purchase for all four. It is
-- not livestock and not administration; it is farm work that has not been
-- split.
--
-- It is an escape hatch and the estate has already proved what happens to
-- those. Section 3F(C): COMMON absorbed Rs.2,35,820 of Rs.4,47,345 of weed
-- spending — 53%, more than every real crop combined — "because a valid,
-- always-correct option is faster than the right one under a stack of slips
-- at 6pm. Any escape hatch left unmeasured becomes the main road."
--
-- So GENERAL saves, and raises FARM NOT SPLIT, attributed to NOBODY — it is
-- not a fault. Amber, never red, exactly like NO PAYEE, BLOCK NOT CHOSEN and
-- ONE TIME PAYEE. The review queue reports it as a RATE, not a count, and if
-- it climbs the owner sees it while it is still fixable.
--
-- Which farm codes count as unsplit is a CONFIG row, not a literal in this
-- function — the same pattern as VAGUE_ACTIVITIES, and for the same reason.
--
-- ============================================================================
-- THE FOUR CORRECTIONS TO fn_save_voucher
-- ============================================================================
--
-- 1. THE FARM REQUIREMENT IS NOW CONDITIONAL. Cost object is validated first,
--    its land_based attribute is read, and the farm is demanded only when the
--    cost object sits on land. An unknown or unseeded cost object defaults to
--    land-based, so the rule fails SAFE — it keeps asking rather than
--    silently stops.
--
--    NOTE WHAT THIS DOES NOT DO: it does not REFUSE a farm on a non-land
--    cost object. Refusing would be tidier and matches how settlements and
--    drawings are handled, but /sales is deployed and working and I cannot
--    see whether it sends a farm on a livestock sale. Breaking the one
--    working screen to gain tidiness is a bad trade. The screen simply stops
--    offering the field; the database stops insisting on it. Tighten to a
--    refusal once the screens are rebuilt.
--
--    qty and unit are UNAFFECTED. Milk sold by the litre carries cost object
--    COW and a quantity that matters enormously — the realisation rate
--    depends on it. land_based governs FARM and BLOCK, nothing else.
--
-- 2. AN EMPTY p_lines ARRAY NO LONGER COLLIDES WITH p_tasks. File 18 refused
--    when p_lines was merely NOT NULL, but the expense screen's documented
--    call sends p_lines => '[]'::jsonb alongside p_tasks, and an empty array
--    is not null. As written, file 18 would have refused the very screen it
--    was built for. Now emptiness counts as absence.
--
-- 3. AN AMOUNT OF ZERO OR LESS IS REFUSED (section 19.5). A zero-rupee line
--    records nothing; a negative one is a reversal wearing the wrong clothes,
--    and section 6 says a correction supersedes or reverses, never sneaks in
--    as a minus. Tally will not accept a zero voucher either.
--
-- 4. A QUANTITY WITHOUT ITS UNIT IS REFUSED, BOTH WAYS (section 19.5). In
--    Tally a quantity is inseparable from its unit because the unit lives on
--    the stock item. Here they are two columns, so "7.5" with no unit is
--    storable and meaningless, and it quietly poisons every per-acre figure.
--    A unit with no quantity is equally empty.
--
-- ============================================================================
-- WHAT DOES NOT CHANGE
-- ============================================================================
--
--   - The signature. Same five arguments, so this is a plain CREATE OR
--     REPLACE with NO DROP. File 18's drop was needed because parameters were
--     being added; nothing is added here, so nothing is dropped and no grant
--     is lost.
--   - fn_assert_master, replaced by file 18 and untouched here.
--   - Every other refusal, flag and warning.
--   - THE PARTY PATTERN CHECK STAYS ABOVE THE INSERT (file 13). Verify 10.
--
-- ============================================================================
-- STILL OPEN AFTER THIS FILE — flagged, deliberately not fixed
-- ============================================================================
--
--   - THE FIVE FUNDING ACTIVITIES are pre-Part-0 machinery. OWNER CAPITAL
--     (3010), STAFF ADVANCE GIVEN and DEDUCTED (1210), ADVANCE RECEIVED
--     (2110) and BANK / CASH TRANSFER (1990) each now have a proper home:
--     a contra, or a settlement against the party whose control account is
--     that account (Part 0.4). ADVANCE RECEIVED is the worst — it puts a
--     buyer's advance in 2110 while his invoice sits in 1310, which Part 0.4
--     forbids outright: one account per party, and the negative balance is
--     correct. NOT retired here, because until the settlement and contra
--     screens exist these are the only route capital movements have.
--
--   - FARM CODE 'HOME' is a leftover. Household spending is now a drawings
--     voucher carrying no farm at all (section 20). Retire with the same
--     work.
--
--   - THE FODDER -> COW TRANSFER has no Postgres home. Nineteen tables, none
--     for transfer rules. Fodder cultivation books to cost object FODDER with
--     its farm and acres, so the per-acre metric is preserved and nothing is
--     lost; the roll-up into COW waits for the mechanism. Joins Norms and the
--     legacy import on the open-decisions list.
--
--   - DIRECT vs INDIRECT EXPENSE for the CA, together with the observation
--     that 5060 General Expenses is currently doing an administrative job it
--     is not named for.
--
-- ============================================================================
-- RUN ORDER
-- ============================================================================
--
--   17a  done, verified 21/07
--   18   done, verified 21/07
--   18a  this file
--
-- ============================================================================


begin;


-- ============================================================================
-- SECTION 1 — land_based on the COST_OBJECT master
-- ============================================================================
-- A cost object either sits on land or it does not. NOT NULL with a default of
-- true so every existing row and every future list keeps today's behaviour
-- until the owner says otherwise: the rule fails SAFE, still asking for a farm
-- rather than silently ceasing to.

alter table master_values
  add column if not exists land_based boolean not null default true;

comment on column master_values.land_based is
  'COST_OBJECT rows. TRUE = this cost object sits on land, so a line carrying '
  'it must name a farm and may name a block. FALSE = it does not: a herd is an '
  'enterprise, not a place (section 1), and administration is neither. Read by '
  'fn_save_voucher to decide whether to demand a farm, and by the screens to '
  'decide whether to offer the field. Does NOT affect qty or unit — milk sold '
  'by the litre carries cost object COW and a quantity that matters. Owner-'
  'editable in masters admin. See file 18a.';

-- The three that are not land. Named explicitly rather than derived from
-- cost_object_type, because type does not distinguish them: COW and COCONUT
-- are both FINAL. NA is NON-OPERATING and covers administration - staff
-- travel, audit fee, bank charges - which has no farm either.
update master_values
   set land_based = false
 where list_name = 'COST_OBJECT'
   and code in ('COW', 'GOAT', 'NA');

-- Everything else stays land-based, stated rather than assumed:
--   AMLA, COCONUT, GUAVA, MANGO, PADDY, SILK COTTON  - crops
--   FODDER                                            - a crop (section 3A),
--                                                       grown on land, per
--                                                       acre, and only then
--                                                       transferred to COW
--   LAND, COMMON                                      - service pools, both on
--                                                       land


-- ============================================================================
-- SECTION 2 — which farm codes mean "not split yet"
-- ============================================================================
-- A config row, not a literal in the function. Exactly the VAGUE_ACTIVITIES
-- pattern: comma separated, owner-editable, and blank disables the rule
-- without a deployment (section 1.9).

insert into config (key, value, description)
values ('UNSPLIT_FARMS', 'GENERAL',
        'FARM codes meaning "a real farm cost, not yet split between farms". '
        'Choosing one saves and raises FARM NOT SPLIT for the review queue '
        '(file 18a). Comma separated. Owner-editable; blank disables the rule. '
        'Not for livestock or administration - those are answered by the cost '
        'object''s land_based attribute and raise nothing.')
on conflict (key) do nothing;


-- ============================================================================
-- SECTION 3 — the flag reason
-- ============================================================================
-- Attributed to NOBODY. It is not a fault: somebody chose a valid value that
-- happens to defer a question. It exists to be COUNTED (section 3F(C)).

insert into master_values (list_name, code, label, active, sort_order,
                           attributed_to, notes)
values ('FLAG_REASON', 'FARM NOT SPLIT',
        'Cost is common to more than one farm, not yet split',
        true, 100, 'NOBODY',
        'Raised when the farm is one of config UNSPLIT_FARMS on a business '
        'expense line. Amber, never red. Report it as a RATE, not a count: '
        'COMMON absorbed 53% of weed spending in the old book because an '
        'always-correct option is faster at 6pm than the right one.')
on conflict (list_name, code) do nothing;


-- ============================================================================
-- SECTION 4 — fn_save_voucher
-- ============================================================================
-- Same five-argument signature as file 18, so this is a plain CREATE OR
-- REPLACE. No drop, no lost grants, no ambiguity window.

create or replace function public.fn_save_voucher(
  p_lines        jsonb default null,   -- the flat path, unchanged
  p_entry_type   text  default null,   -- unchanged
  p_voucher_type text  default 'PAYMENT',
  p_tasks        jsonb default null,   -- file 18: the nested path
  p_header       jsonb default null    -- file 18: what tasks need above them
)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
  v_cost_obj     text;
  v_cost_nature  text;
  v_mode         text;
  v_mode_kind    text;
  v_pfrom        date;
  v_pto          date;
  v_is_vague     boolean;
  v_is_onetime   boolean;
  v_farm_blocks  boolean;
  -- flags: a line may earn more than one
  v_flags        text[];
  v_notes        text[];
  v_flag_author  text;
  i              int;
  -- 12: type + direction machinery
  v_vtype        text := upper(coalesce(nullif(trim(p_voucher_type), ''), 'PURCHASE'));
  -- 15: the type's own shape and direction, read from the VOUCHER_TYPE master
  v_shape        text;      -- TRANSACTION | SETTLEMENT | TRANSFER | JOURNAL | DRAWINGS
  v_dir          text;      -- IN | OUT | null
  v_settle       boolean;   -- shorthand: this voucher settles a party balance
  v_draw         boolean;   -- 18: shorthand: this voucher is owner drawings
  v_ctrl         text;      -- the party's control account, settlements only
  v_parts        text[];
  v_dr_total     numeric;
  v_cr_total     numeric;
  v_is_cr        boolean;
  -- 18: the normaliser
  v_lines        jsonb := '[]'::jsonb;   -- the flattened array every rule reads
  v_task         jsonb;
  v_trow         jsonb;
  v_task_no      int := 0;
  v_row_j        int;
  v_task_sum     numeric;
  v_task_total   numeric;
  v_entity       text;
  v_job          text;
  v_is_head      boolean;
  v_doc_ref      text;
  v_doc_date     date;
  v_paper_total  numeric;
  v_dup          text;
  -- 18a
  v_land_based   boolean;   -- does this cost object sit on land
  v_unsplit      text[];    -- FARM codes meaning "not split yet"
begin
  perform fn_require('ENTER_VOUCHER');
  perform fn_ledger_write_on();

  -- ==========================================================================
  -- 18 · NORMALISATION — the whole trick of this file
  -- ==========================================================================
  -- p_tasks is flattened into the flat line array BEFORE anything else runs.
  -- The nesting is an input adapter, not a second code path: one validation
  -- path, one set of refusals, one loop. Everything below this block is the
  -- function as it was, plus the DRAWINGS branch.
  --
  -- The reason for nesting rather than letting the screen stamp task_no on
  -- flat lines: under nesting a task's dimensions are stated ONCE and copied
  -- down, so two rows of one task cannot disagree about the farm. Nothing
  -- would have caught that (§19, plan §2.1).

  if p_tasks is not null then

    -- 18a: EMPTINESS COUNTS AS ABSENCE. File 18 tested "is not null", but the
    -- expense screen's documented call sends p_lines => '[]'::jsonb alongside
    -- p_tasks, and an empty array is not null — so file 18 would have refused
    -- the very screen it was written for.
    if p_lines is not null and jsonb_array_length(p_lines) > 0 then
      raise exception
        'Send either p_lines (flat) or p_tasks (nested), not both. Two shapes in one voucher is ambiguous about what belongs to which task.';
    end if;
    if p_header is null then
      raise exception
        'The nested path needs p_header — the payment date, period and entity live above the tasks.';
    end if;
    if jsonb_array_length(p_tasks) = 0 then
      raise exception 'A voucher needs at least one task.';
    end if;

    v_doc_ref     := nullif(trim(coalesce(p_header->>'doc_ref_no','')), '');
    v_doc_date    := (p_header->>'doc_ref_date')::date;
    v_paper_total := (p_header->>'paper_total')::numeric;

    for v_task in select value from jsonb_array_elements(p_tasks) with ordinality o(value, n) order by o.n loop
      v_task_no := v_task_no + 1;
      v_row_j   := 0;
      v_task_sum := 0;

      if coalesce(jsonb_array_length(v_task->'rows'), 0) = 0 then
        raise exception
          'Task %: no rows. A task is a piece of work with people under it; a task with nobody on it records nothing.',
          v_task_no;
      end if;

      for v_trow in select value from jsonb_array_elements(v_task->'rows') with ordinality o(value, n) order by o.n loop
        v_row_j := v_row_j + 1;

        -- The copy-down. Row beats task beats header, and a key holding an
        -- explicit JSON null falls back exactly as a missing key does —
        -- hence nullif(..., 'null'::jsonb) rather than plain coalesce.
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(

          -- from the header, identical on every line of the voucher
          'payment_date', p_header->'payment_date',
          'period_from',  coalesce(nullif(v_task->'period_from','null'::jsonb),
                                   nullif(p_header->'period_from','null'::jsonb)),
          'period_to',    coalesce(nullif(v_task->'period_to','null'::jsonb),
                                   nullif(p_header->'period_to','null'::jsonb)),
          'entity',       p_header->'entity',

          -- from the task, copied onto every row of that task
          'farm',         v_task->'farm',
          'block',        v_task->'block',
          'cost_object',  v_task->'cost_object',
          'activity',     v_task->'activity',
          'capex_flag',   v_task->'capex_flag',
          'cost_nature',  coalesce(nullif(v_trow->'cost_nature','null'::jsonb),
                                   nullif(v_task->'cost_nature','null'::jsonb)),
          'job_id',       v_task->'job_id',

          -- from the row — a row IS a person (§19.1)
          'party_code',   v_trow->'party_code',
          'payee',        v_trow->'payee',
          'mandays',      v_trow->'mandays',
          'rate',         v_trow->'rate',
          'paid_out_dr',  v_trow->'paid_out_dr',
          'received_cr',  v_trow->'received_cr',

          -- row, else the level above
          'mode',         coalesce(nullif(v_trow->'mode','null'::jsonb),
                                   nullif(p_header->'mode','null'::jsonb)),
          'narration',    coalesce(nullif(v_trow->'narration','null'::jsonb),
                                   nullif(v_task->'narration','null'::jsonb)),
          'flag_reason',  v_trow->'flag_reason',
          'flag_note',    v_trow->'flag_note',

          -- THE POINT OF THE WHOLE EXERCISE (§19.4).
          -- The work quantity belongs to the TASK and is written to its FIRST
          -- row only. Repeating 7.5 acres across three labour rows would
          -- report 22.5 acres irrigated, and every rupees-per-acre figure the
          -- estate is run on would be wrong in a way no report would reveal.
          'qty',          case when v_row_j = 1 then v_task->'qty'  else null end,
          'unit',         case when v_row_j = 1 then v_task->'unit' else null end,

          -- internal, read by this function and then dropped
          'task_no',      v_task_no,
          'is_task_head', (v_row_j = 1)
        ));

        v_task_sum := v_task_sum + coalesce(
                        (v_trow->>'paid_out_dr')::numeric,
                        (v_trow->>'received_cr')::numeric, 0);
      end loop;

      -- A stated task total that its own rows contradict is refused, not
      -- warned: the paper says what this piece of work cost, and if the rows
      -- do not add to it one of them is wrong or missing.
      v_task_total := (v_task->>'total')::numeric;
      if v_task_total is not null and v_task_total <> v_task_sum then
        raise exception
          'Task %: the rows add to Rs.% but the task says Rs.%. One of them is wrong.',
          v_task_no, v_task_sum, v_task_total;
      end if;
    end loop;

  else
    -- THE FLAT PATH, UNCHANGED. Every line is its own task and its own task
    -- head, so every rule below behaves exactly as it did before file 18.
    if p_lines is null or jsonb_array_length(p_lines) = 0 then
      raise exception 'A voucher needs at least one line';
    end if;

    select coalesce(jsonb_agg(l.value || jsonb_build_object(
                      'task_no', 1, 'is_task_head', true) order by l.n), '[]'::jsonb)
      into v_lines
      from jsonb_array_elements(p_lines) with ordinality l(value, n);

    -- the document reference is accepted on the flat path too, when sent
    v_doc_ref     := nullif(trim(coalesce(p_header->>'doc_ref_no','')), '');
    v_doc_date    := (p_header->>'doc_ref_date')::date;
    v_paper_total := (p_header->>'paper_total')::numeric;
  end if;

  if jsonb_array_length(v_lines) = 0 then
    raise exception 'A voucher needs at least one line';
  end if;

  -- ==========================================================================
  -- from here down: the function as it was, reading v_lines instead of p_lines
  -- ==========================================================================

  -- 12: direction totals, used by the type rule and the duplicate check
  select coalesce(sum((l->>'paid_out_dr')::numeric), 0),
         coalesce(sum((l->>'received_cr')::numeric), 0)
    into v_dr_total, v_cr_total
    from jsonb_array_elements(v_lines) l;

  -- 15: shape and direction come from the VOUCHER_TYPE master, never from a
  -- list in here. Adding a voucher type stays a master row (§1.9).
  select voucher_shape, voucher_direction into v_shape, v_dir
    from master_values
   where list_name = 'VOUCHER_TYPE' and code = v_vtype and active;
  if not found then
    raise exception 'Unknown or inactive voucher type "%".', v_vtype;
  end if;
  v_settle := (v_shape = 'SETTLEMENT');
  v_draw   := (v_shape = 'DRAWINGS');     -- 18

  -- 18: DRAWINGS admitted. CONTRA and JOURNAL stay refused — a journal moves
  -- no money and that property is what makes the cash book trustworthy
  -- (§16.22); they have their own paths (§17.3, §18.6 step 7).
  if v_shape not in ('TRANSACTION','SETTLEMENT','DRAWINGS') then
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

  -- 18a: which farm codes mean "not split between farms yet". Config, not a
  -- literal — same pattern as VAGUE_ACTIVITIES above, and blank disables it.
  select coalesce(array_agg(trim(x)) filter (where trim(x) <> ''), '{}')
    into v_unsplit
    from unnest(string_to_array(coalesce(fn_config('UNSPLIT_FARMS'), ''), ',')) as x;

  v_narr_min  := coalesce(fn_config('NARRATION_MIN')::int, 5);
  v_vague_min := coalesce(fn_config('VAGUE_NARRATION_MIN')::int, 15);

  v_pdate := (v_lines -> 0 ->> 'payment_date')::date;
  if v_pdate is null then
    raise exception 'A payment date is needed — it is the date the money moved, and it drives the FY, the cash book and the cash flow statement.';
  end if;

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

  -- 18: within-voucher duplicate check. After normalisation, before the
  -- insert loop. WARNING ONLY.
  -- Same party + same task + same rate twice in one voucher is probably one
  -- person entered twice on one piece of work. The same party under a
  -- DIFFERENT task_no stays silent — that is a person who did two jobs that
  -- week, the ordinary case on this estate's paper (§19.5, §16.23).
  -- A null rate is treated as a value, so two rate-less rows for one person on
  -- one task also warn; on a lumpsum task that is the likeliest way to
  -- double-enter somebody.
  select string_agg(format('%s on task %s (%s times)', d.pc, d.tn, d.c), '; ')
    into v_dup
    from (
      select l->>'party_code'          as pc,
             (l->>'task_no')::int      as tn,
             (l->>'rate')              as rt,
             count(*)                  as c
        from jsonb_array_elements(v_lines) l
       where nullif(trim(coalesce(l->>'party_code','')), '') is not null
       group by 1, 2, 3
      having count(*) > 1
    ) d;
  if v_dup is not null then
    v_warnings := v_warnings ||
      format('Possible double entry: %s. Same person, same task, same rate. Check the paper.', v_dup);
  end if;

  -- 12: the number comes from the type's own series
  v_voucher_no := fn_next_voucher_no(
                    case when v_prior then v_today else v_pdate end, v_vtype);

  -- 12: parse prefix-safely — fy and serial are the LAST two segments,
  -- whatever prefix the master gave the series ('26/0041' or 'R/26/0007').
  v_parts := string_to_array(v_voucher_no, '/');
  insert into vouchers (voucher_no, voucher_type, fy_prefix, serial_no,
                        prior_period, created_by, doc_ref_no, doc_ref_date)
  values (v_voucher_no, v_vtype,
          v_parts[array_length(v_parts,1) - 1],
          v_parts[array_length(v_parts,1)]::int,
          v_prior, v_actor, v_doc_ref, v_doc_date);

  if v_today - v_pdate > v_stale_days then
    v_warnings := v_warnings || format('Stale voucher: %s days old', v_today - v_pdate);
  end if;

  for v_line in select value from jsonb_array_elements(v_lines) with ordinality o(value, n) order by o.n loop
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
    v_cost_obj    := nullif(trim(coalesce(v_line->>'cost_object','')), '');
    v_cost_nature := nullif(trim(coalesce(v_line->>'cost_nature','')), '');
    v_mode        := nullif(trim(coalesce(v_line->>'mode','')), '');
    v_job         := nullif(trim(coalesce(v_line->>'job_id','')), '');
    v_pfrom       := (v_line->>'period_from')::date;
    v_pto         := (v_line->>'period_to')::date;
    v_amt         := coalesce((v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric);
    v_is_cr       := (v_line->>'received_cr') is not null;
    v_entity      := v_line->>'entity';
    -- 18: task machinery
    v_task_no     := coalesce((v_line->>'task_no')::int, 1);
    v_is_head     := coalesce((v_line->>'is_task_head')::boolean, true);

    select mode_kind into v_mode_kind
      from master_values where list_name = 'MODE' and code = v_mode;

    -- 18: MOVED UP from below the shape block. The DRAWINGS branch needs to
    -- know whether the one-time toggle was used before it can judge "a party
    -- is required". Nothing between the old position and here read v_payee,
    -- so the move changes no behaviour on any existing path.
    -- 09: the one-time toggle arrives as the literal payee 'ONE TIME'.
    -- Recognised case-insensitively so a hand-typed variant cannot slip
    -- past the rules by casing alone; stored normalised as 'ONE TIME'.
    v_is_onetime := v_payee is not null and upper(v_payee) = 'ONE TIME';
    if v_is_onetime then
      v_payee := 'ONE TIME';
    end if;

    -- 15 + 18: THE SHAPE RULES, now three branches.
    if v_settle then
      -- A settlement moves a balance; nothing happened on the land, so it
      -- carries no dimension and no activity (Part 0.5, §16.15).
      if v_party is null then
        raise exception
          'Line %: a settlement must name the party whose balance is moving. Without it the money has nowhere to land.',
          v_line_no;
      end if;
      if v_activity is not null or v_farm is not null
         or v_cost_obj is not null
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

    elsif v_draw then
      -- 18 · THE DRAWINGS BRANCH (§20.1). Payment-shaped underneath: money
      -- leaves a pocket exactly as on an expense voucher, so the cash book
      -- sees every rupee through one kind of door. Only the debit differs,
      -- and fn_generate_postings already handles that — entity PERSONAL
      -- resolves to 3020 ahead of any activity rule, so one activity and one
      -- person can land in two different accounts depending on which voucher
      -- they are on. That is what makes the SHARED group work (§20.4).
      if v_party is null and not v_is_onetime then
        raise exception
          'Line %: household spending is always somebody — the cook, the watchman, the shop. Name the party, or use the one-time toggle for a genuine one-off.',
          v_line_no;
      end if;
      if v_activity is null then
        raise exception
          'Line %: an activity is needed — it is the household purpose, and the only breakdown drawings has (§10.5).',
          v_line_no;
      end if;
      if v_farm is not null or v_block is not null or v_cost_obj is not null
         or (v_line->>'qty') is not null or (v_line->>'unit') is not null then
        raise exception
          'Line %: a drawings line carries no farm, block, cost object, quantity or unit — none of them describes a house (Part 0.5). The screen should not be sending them.',
          v_line_no;
      end if;
      -- Mode kind CREDIT is ALLOWED here and refused on a settlement: a
      -- household shop account is ordinary. This is the one deliberate
      -- difference between the two shapes (§20.1).
      --
      -- A grocery bill covers no period; a cook's week does. So the period
      -- defaults to the payment date when absent rather than being demanded.
      if v_pfrom is null then v_pfrom := v_pdate; end if;
      if v_pto   is null then v_pto   := v_pdate; end if;
      -- entity is FORCED, not trusted from the screen (§20.1), the same
      -- discipline as file 12's entity guard.
      v_entity := 'PERSONAL';

    else
      -- a transaction line is the opposite of a settlement: it must say what
      -- and where.
      if v_activity is null then
        raise exception 'Line %: an activity is needed — what was bought, done or sold.', v_line_no;
      end if;

      -- 18a: THE COST OBJECT IS VALIDATED FIRST, because it decides whether a
      -- farm is even answerable. It is what the money was FOR, and that is
      -- always askable.
      if v_cost_obj is null then
        raise exception 'Line %: a cost object is needed — what carries this.', v_line_no;
      end if;

      -- 18a: does this cost object sit on land? A herd is an enterprise, not
      -- a place (section 1); administration is neither. An unknown or unseeded
      -- cost object defaults to TRUE so the rule fails SAFE — it keeps asking
      -- rather than silently stopping.
      select land_based into v_land_based
        from master_values
       where list_name = 'COST_OBJECT' and code = v_cost_obj;
      v_land_based := coalesce(v_land_based, true);

      if v_land_based and v_farm is null then
        raise exception 'Line %: a farm is needed.', v_line_no;
      end if;

      -- Deliberately NOT refusing a farm when v_land_based is false. Refusing
      -- would be tidier and would match the settlement and drawings branches,
      -- but /sales is deployed and I cannot see whether it sends a farm on a
      -- livestock sale. Breaking the one working screen for tidiness is a bad
      -- trade. The screen stops offering the field; the database stops
      -- insisting on it. Tighten once the screens are rebuilt.
    end if;

    -- 18: a job follows the work, so it belongs to a transaction line only.
    -- No deployed screen sends it on anything else; the refusal exists so a
    -- future one cannot start.
    if v_job is not null and (v_settle or v_draw) then
      raise exception
        'Line %: a job describes work on the estate, so it belongs on a business expense line and nowhere else.',
        v_line_no;
    end if;

    -- 18: a CLOSED job is REFUSED, not warned. A closed job quietly accepting
    -- new cost is how a contract total becomes wrong months later, and there
    -- is no report that would show it. Reopening is a deliberate act.
    -- Validated by existence, not fn_assert_master: jobs is a table, not a
    -- master list.
    if v_job is not null and not exists (
         select 1 from jobs where job_id = v_job and status = 'OPEN') then
      raise exception
        'Line %: job "%" is not an open job. Reopen it in the jobs screen if this cost really belongs to it.',
        v_line_no, v_job;
    end if;

    v_is_vague := v_activity = any (v_vague);

    -- ---- REFUSALS -------------------------------------------------------

    -- A2: narration on every line. Vague heads need the longer one.
    -- 09: a ONE TIME line also needs the longer one — the person's NAME
    -- lives in the narration, that being the entire design of the toggle.
    -- 12: wording knows the direction.
    -- Stays PER ROW under nesting: the task's narration is copied down, so
    -- the rule survives unchanged, and a row may still carry its own
    -- ("Savithri, half day") which wins when present.
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
    -- and a drawings line have already had it defaulted to the payment date.
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

    -- A7: cost nature - what KIND of spending this was.
    -- 15 forbids it outright on a settlement.
    -- 18 (OWNER RULING 21/07): OPTIONAL on a drawings line. §20.1 reads as
    -- required; the owner ruled otherwise, because household spending has no
    -- cost structure worth analysing — which is the whole reason it leaves
    -- the P&L. "Material" on a grocery bill is friction that answers nothing.
    -- It is still ACCEPTED when sent, and still validated by trg_txn_validate
    -- against the COST_NATURE master.
    if not v_settle and not v_draw and v_cost_nature is null then
      raise exception
        'Line %: cost nature is needed - labour, material, machine hire, transport, contract or other. Split the line if the work used more than one.',
        v_line_no;
    end if;

    -- 18a (section 19.5): AN AMOUNT OF ZERO OR LESS IS REFUSED. A zero-rupee
    -- line records nothing. A negative one is a reversal wearing the wrong
    -- clothes, and section 6 is absolute that a saved figure is superseded or
    -- reversed, never quietly negated. Tally will not accept a zero voucher
    -- either.
    if v_amt is null or v_amt <= 0 then
      raise exception
        'Line %: an amount is needed and it must be more than zero. To undo something already saved, reverse or supersede it (section 6) — never enter a minus.',
        v_line_no;
    end if;

    -- 18a (section 19.5): A QUANTITY WITHOUT ITS UNIT, OR A UNIT WITHOUT ITS
    -- QUANTITY, IS REFUSED. In Tally the two are inseparable because the unit
    -- lives on the stock item; here they are two columns, so "7.5" with no
    -- unit is storable and meaningless and it poisons every per-acre figure
    -- silently. Under nesting, rows 2..n of a task hold BOTH as null, which
    -- passes this test cleanly.
    if ((v_line->>'qty') is null) <> (nullif(trim(coalesce(v_line->>'unit','')),'') is null) then
      raise exception
        'Line %: quantity and unit go together — %. Write both, or neither.',
        v_line_no,
        case when (v_line->>'qty') is null
             then 'a unit was chosen with no quantity against it'
             else 'a quantity was written with no unit to measure it in' end;
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
    --
    -- 18 · THE is_task_head GATING.
    -- Three of these flags describe the TASK, not the person. Under nesting,
    -- rows 2..n of a task hold null qty BY DESIGN and repeat the task's block
    -- and activity, so ungated they would fire on every row: a thirteen-task
    -- paper would raise thirty spurious flags and the flag queue would be
    -- useless within a week. They are raised on the FIRST row of a task only.
    --
    -- Person-derived flags — NO PAYEE, ONE TIME PAYEE — stay PER ROW, because
    -- they describe that row and that person.
    --
    -- On the flat path every line is its own task head, so all of this is a
    -- no-op and behaviour is identical to before.

    -- A1: cash that names nobody (both directions: cash received from
    -- nobody is as blind as cash paid to nobody). PER ROW.
    if v_mode_kind = 'CASH' and v_payee is null and v_party is null then
      v_flags := v_flags || 'NO PAYEE'::text;
      v_notes := v_notes || format('Cash %s, nobody named. %s',
                   case when v_is_cr then 'received' else 'paid' end,
                   v_narration);
    end if;

    -- 09: the deliberate one-off. Distinct from NO PAYEE: here someone WAS
    -- named, in the narration, and the accountant said so explicitly. The
    -- flag measures the escape hatch and feeds the promotion loop. PER ROW.
    if v_is_onetime then
      v_flags := v_flags || 'ONE TIME PAYEE'::text;
      v_notes := v_notes || format('One-time party. Narration: %s', v_narration);
    end if;

    -- A6: block unchosen, but ONLY where the farm actually has blocks.
    -- 15: skipped entirely on a settlement — there is no farm to ask about.
    -- 18: and on drawings, which has no farm either. TASK HEAD ONLY.
    select exists (
      select 1 from master_values
       where list_name = 'BLOCK' and active
         and parent_farm = v_farm)
      into v_farm_blocks;

    if not v_settle and not v_draw and v_is_head and v_farm_blocks
       and coalesce(v_block, 'YET TO ASSIGN') = 'YET TO ASSIGN' then
      v_flags := v_flags || 'BLOCK NOT CHOSEN'::text;
      v_notes := v_notes || format('%s has blocks in the master; none chosen', v_farm);
    end if;

    -- 18a: the farm was named but it is a catch-all — a real farm cost that
    -- spans farms and has not been split. Saves, and is COUNTED. Attributed to
    -- NOBODY: it is not a fault. TASK HEAD ONLY, or a seven-person task raises
    -- it seven times. Livestock and administration never reach here — their
    -- cost object is not land-based, so no farm was asked for in the first
    -- place and nothing is flagged.
    if not v_settle and not v_draw and v_is_head
       and v_farm is not null and v_farm = any (v_unsplit) then
      v_flags := v_flags || 'FARM NOT SPLIT'::text;
      v_notes := v_notes || format('%s covers more than one farm. Split it when the share is known.', v_farm);
    end if;

    -- section 5B: a vague head is always flagged. TASK HEAD ONLY — the head
    -- is copied down, so ungated this fires once per person on the task.
    -- NOTE the narration floor above is NOT gated: every row still has to
    -- describe itself.
    if coalesce(v_is_vague, false) and v_is_head then
      v_flags := v_flags || 'ACTIVITY NOT LISTED'::text;
      v_notes := v_notes || format('Vague head "%s" chosen. Narration: %s', v_activity, v_narration);
    end if;

    -- section 3F: measurable activity entered without its quantity.
    -- 12: also the SALES rule (owner 20-07): income activities carry
    -- required_unit, so a sale without quantity FLAGS and saves - never
    -- refuses. The genuine lump-sum sale records qty 1, unit LUMPSUM, no flag.
    -- 18: TASK HEAD ONLY. This is the one that would have hurt most — rows
    -- 2..n hold null qty by design (§19.4).
    select required_unit into v_req_unit
      from master_values where list_name = 'ACTIVITY' and code = v_activity;
    if not v_settle and not v_draw and v_is_head
       and v_req_unit is not null and (v_line->>'qty') is null then
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

    -- 13: MOVED ABOVE THE INSERT AND IT STAYS THERE. Until file 13 this block
    -- sat AFTER the insert, so the party's "own record" already contained the
    -- line being judged: max_paid WAS this amount, and "amount > max x 2"
    -- could never be true for the very line the check exists to catch. Dead
    -- from file 09 to file 13. Found by the file 12 smoke tests, 20-07-2026.
    -- 09: pattern check against the party's OWN record. Needs 3+ priors;
    -- under that there is no pattern and the check stays silent.
    -- 12: reads the MATCHING side - a receipt is measured against their
    -- receipt history, never their payment history.
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
    -- 18: job_id and task_no join the INSERT list. job_id has existed on the
    -- table since file 16 and has never been written by anything (§16.28
    -- finding 2) — the column was dead.
    insert into transactions (
      row_id, voucher_no, line_no, task_no, payment_date, period_from, period_to,
      entity, farm, block, cost_object, activity, capex_flag, cost_nature,
      qty, unit, mandays, rate, paid_out_dr, received_cr, mode, job_id, party_code,
      payee, narration, entry_type, entered_by,
      flagged, flag_reason)
    values (
      v_row_id, v_voucher_no, v_line_no, v_task_no, v_pdate, v_pfrom, v_pto,
      v_entity, v_farm, v_block,
      v_cost_obj, v_activity,
      coalesce(v_line->>'capex_flag','RECURRING'), v_cost_nature,
      (v_line->>'qty')::numeric, v_line->>'unit',
      (v_line->>'mandays')::numeric, (v_line->>'rate')::numeric,
      (v_line->>'paid_out_dr')::numeric, (v_line->>'received_cr')::numeric,
      v_mode, v_job, v_party,
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

    -- amount not equal to mandays x rate (warning only, decision A8).
    -- PER ROW and correctly so: mandays and rate both belong to the person.
    if (v_line->>'mandays') is not null and (v_line->>'rate') is not null
       and v_amt is distinct from ((v_line->>'mandays')::numeric * (v_line->>'rate')::numeric) then
      v_warnings := v_warnings ||
        format('Line %s: amount %s does not equal mandays x rate %s', v_line_no, v_amt,
               (v_line->>'mandays')::numeric * (v_line->>'rate')::numeric);
    end if;

    -- 09: piece-rate arithmetic. When mandays is blank, rate belongs to the
    -- quantity ("Rs.20 per tree, 956 trees"). 12: on receipts this same check
    -- IS the realisation-rate check - qty sold x rate = proceeds.
    -- 18: TASK HEAD ONLY. On a contract task the quantity sits on row 1 and a
    -- rate sits on every row, so ungated this would compare one person's rate
    -- against the WHOLE TASK's quantity and warn falsely on every contract
    -- task with more than one row. Gating costs nothing on the flat path,
    -- where every line is its own head.
    if v_is_head
       and (v_line->>'mandays') is null
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

  -- 18: the voucher total against the figure typed off the paper (§19.2).
  -- Warning, never a block — the paper is sometimes added up wrongly, and
  -- that is worth knowing rather than worth refusing.
  if v_paper_total is not null
     and v_paper_total <> greatest(v_dr_total, v_cr_total) then
    v_warnings := v_warnings ||
      format('The lines add to Rs.%s but the paper says Rs.%s. Check before you file it.',
             greatest(v_dr_total, v_cr_total), v_paper_total);
  end if;

  -- ---- probable duplicate, ACROSS vouchers (warning only, decision A9) ----
  -- 18: CORRECTED, NOT WEAKENED.
  -- The old test compared whole-voucher DR and CR totals plus the payee on
  -- line 0 against other vouchers on the same date. Under §19 line 0's payee
  -- stops being a header name and becomes the first labourer on the first
  -- task, so two weekly wage vouchers starting with the same person and
  -- totalling the same would warn falsely.
  -- The better test is the document reference: the same slip entered twice IS
  -- a duplicate, whoever it starts with. The old totals-plus-payee test is
  -- kept as the fallback for when no reference was typed.
  if v_doc_ref is not null then
    if exists (
      select 1 from vouchers v
       where v.doc_ref_no = v_doc_ref
         and v.status = 'ACTIVE'
         and v.voucher_no <> v_voucher_no) then
      v_warnings := array_append(v_warnings,
        format('Probable duplicate: document reference "%s" is already on another live voucher. The same slip may have been entered twice.', v_doc_ref));
    end if;
  else
    if exists (
      select 1 from transactions t
      where t.payment_date = v_pdate and t.status = 'LIVE'
        and t.voucher_no <> v_voucher_no
        and coalesce(t.payee,'') = coalesce(trim(v_lines -> 0 ->> 'payee'),'')
      group by t.voucher_no
      having sum(coalesce(t.paid_out_dr, 0)) = v_dr_total
         and sum(coalesce(t.received_cr, 0)) = v_cr_total) then
      v_warnings := array_append(v_warnings, 'Probable duplicate: same date + total + payee (section 4)');
    end if;
  end if;

  return jsonb_build_object(
    'voucher_no', v_voucher_no, 'voucher_type', v_vtype,
    'tasks', v_task_no,                                    -- 18
    'row_ids', to_jsonb(v_row_ids),
    'entry_type', v_entry_type, 'warnings', to_jsonb(v_warnings));
end $function$;


-- The drop above took the old function's grants with it. These are the
-- Postgres defaults, restored explicitly because the snapshot does not record
-- what was there. The permission model lives INSIDE the function
-- (fn_require('ENTER_VOUCHER')) and is unaffected either way.
grant execute on function public.fn_save_voucher(jsonb, text, text, jsonb, jsonb) to public;


commit;



-- ============================================================================
-- VERIFY — run this block on its own after the commit above succeeds.
-- Structural only. It proves the file INSTALLED; the behaviour tests follow.
-- ============================================================================

select check_name, expected, actual,
       case when expected = actual then 'PASS' else 'FAIL' end as result
from (

  select '1. land_based column exists' as check_name, '1' as expected,
         count(*)::text as actual
    from information_schema.columns
   where table_schema = 'public' and table_name = 'master_values'
     and column_name = 'land_based'

  union all
  -- COW, GOAT and NA, and nothing else
  select '2. non-land cost objects', '3',
         count(*)::text
    from master_values
   where list_name = 'COST_OBJECT' and land_based = false

  union all
  select '3. they are the right three', 'COW,GOAT,NA',
         string_agg(code, ',' order by code)
    from master_values
   where list_name = 'COST_OBJECT' and land_based = false

  union all
  -- FODDER must stay land-based: it is a crop, grown per acre (section 3A)
  select '4. FODDER still land-based', 'true',
         bool_and(land_based)::text
    from master_values
   where list_name = 'COST_OBJECT' and code = 'FODDER'

  union all
  select '5. UNSPLIT_FARMS config set', 'GENERAL',
         coalesce(fn_config('UNSPLIT_FARMS'), '(missing)')

  union all
  -- and it names a farm that actually exists
  select '6. UNSPLIT_FARMS names a real farm', '1',
         count(*)::text
    from master_values
   where list_name = 'FARM' and code = 'GENERAL' and active

  union all
  select '7. FARM NOT SPLIT flag reason', 'NOBODY',
         coalesce(max(attributed_to), '(missing)')
    from master_values
   where list_name = 'FLAG_REASON' and code = 'FARM NOT SPLIT' and active

  union all
  -- signature UNCHANGED — this file replaces in place, it does not drop
  select '8. still exactly one fn_save_voucher', '1',
         count(*)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  select '9. still 5 arguments', '5',
         max(p.pronargs)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  select '10. still SECURITY DEFINER', 'true',
         bool_and(p.prosecdef)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  -- THE ONE THAT MATTERS MOST (file 13). Dead from file 09 to file 13
  -- because it sat below the insert, and nothing at runtime would tell you.
  select '11. pattern check above the insert', 'true',
         (position('v_party_payment_stats' in prosrc)
            < position('insert into transactions' in prosrc))::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '12. farm requirement is conditional', 'true',
         (position('v_land_based and v_farm is null' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '13. UNSPLIT_FARMS read from config', 'true',
         (position('UNSPLIT_FARMS' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  -- file 18's work must survive
  select '14. DRAWINGS still admitted', 'true',
         (position('''DRAWINGS''' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '15. task_no still written', 'true',
         (position('task_no' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '16. job_id still written', 'true',
         (position('job_id' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '17. fn_assert_master still refuses headings', 'true',
         (position('is_heading' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_assert_master'

  union all
  select '18. posting breaks', '0', count(*)::text from v_posting_breaks

  union all
  select '19. serial gaps', '0', count(*)::text from v_serial_gaps

) checks
order by lpad(split_part(check_name, '.', 1), 3, '0');


-- ============================================================================
-- AFTER THIS FILE
-- ============================================================================
--
-- WHAT CHANGES FOR THE ACCOUNTANT: nothing yet. No screen reads land_based.
-- The database has stopped demanding a farm where none exists; the screens
-- have to stop offering the field, and that is the expense screen build.
--
-- WHAT THE SCREENS MUST NOW DO
--   - Activity dropdown: add "and is_heading = false". The six group headings
--     from file 17a are currently VISIBLE AND PICKABLE in /entry. The database
--     refuses them, so the only symptom is a confusing error; the list should
--     not be offering them at all.
--   - Activity dropdown, expense screen: filter group_code in
--     ('FARM','WEED MGMT','SHARED'). It is currently unfiltered, so the 14
--     household activities are one keystroke away on a farm voucher, which is
--     exactly what section 20.3 exists to prevent.
--   - Farm and block: hide when the chosen cost object has land_based = false.
--   - GENERAL: keep it, and say plainly beneath it that the cost will be
--     flagged for splitting later. An escape hatch that announces itself is
--     used less than one that does not.
--
-- TESTS FOR THIS FILE, from the SQL editor
--   1. cattle maintenance, cost object COW, NO farm            -> saves
--   2. the same line with cost object COCONUT and no farm      -> refused
--   3. staff travel, cost object NA, no farm                   -> saves
--   4. weedicide, farm GENERAL, cost object COCONUT            -> saves, and
--      raises exactly ONE flag: FARM NOT SPLIT
--   5. a line with amount 0, and one with -500                 -> both refused
--   6. qty 3 with no unit; unit ACRE with no qty               -> both refused
--   7. a nested call sending p_lines => '[]' with p_tasks      -> saves
--   8. milk sale, cost object COW, qty 40 LITRE, no farm       -> saves WITH
--      its quantity intact. land_based must not touch qty.
--
-- SPEC AMENDMENTS OWED (draft as v3.3, never ahead of the database)
--   section 1.2 / Part 0.5  the cost object decides whether a farm is asked
--   section 3A              land_based as a COST_OBJECT attribute
--   section 3F(C)           FARM NOT SPLIT joins the NOBODY-attributed flags
--   section 19.5            the amount and qty/unit refusals now enforced
--   section 12              open decisions: the five FUNDING activities, farm
--                           code HOME, the FODDER -> COW transfer, and the
--                           direct/indirect question for the CA
-- ============================================================================
