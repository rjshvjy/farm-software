-- sql/18_fn_save_voucher_tasks.sql
-- github.com/rjshvjy/farm-software
--
-- FILE 18 — fn_save_voucher RESTRUCTURED FOR TASKS
-- 21 July 2026 · replaces the function of file 15 · requires file 17a
--
-- ============================================================================
-- WHAT THIS FILE DOES
-- ============================================================================
--
--   1. fn_assert_master   gains one refusal: a group heading is not a value
--                         you can choose (file 17a's is_heading column)
--   2. fn_save_voucher    DROPPED and recreated with two new parameters:
--                            p_tasks   the nested voucher -> task -> row shape
--                            p_header  what the tasks need above them
--                         plus the DRAWINGS branch, job_id, task_no, the
--                         document reference, and the within-voucher
--                         duplicate check
--
-- Written against the function body as it stands in the snapshot of
-- 21/07/2026 15:37 IST, read in full rather than reasoned about. Every
-- refusal, flag and warning in that body is carried across; §7 of the plan
-- lists them and §9 of the verify block re-counts them.
--
-- ============================================================================
-- THREE THINGS FOUND WHILE READING THAT THE PLAN DID NOT HAVE
-- ============================================================================
--
-- FINDING 1 — CREATE OR REPLACE WILL NOT DO. This is the one that changes how
-- the file is applied. Postgres cannot add parameters to an existing function
-- through CREATE OR REPLACE; it creates a SECOND function with a different
-- signature. Both would then exist, and a three-argument call would match the
-- old one exactly AND the new one through its defaults, so Postgres would
-- refuse it as ambiguous: "function fn_save_voucher(jsonb, text, text) is not
-- unique". Every existing screen would break instantly.
--
--   So the old function is DROPPED first. That is not cosmetic and it is not
--   reversible in the same breath: between the DROP and the CREATE the front
--   door does not exist. Both statements are inside one transaction, so a
--   failure rolls back to the working function rather than leaving a hole.
--
--   The snapshot does NOT capture function grants, so I cannot see what was
--   granted on the old function. A dropped function loses its grants. The
--   defaults are restored explicitly at the end of section 2 — but this is a
--   blind spot in the snapshot query worth closing before the next function
--   replacement.
--
-- FINDING 2 — THE ENTITY HOLE IS STILL OPEN, AND THIS FILE DOES NOT CLOSE IT.
-- fn_generate_postings sends ANY line with entity = 'PERSONAL' to 3020,
-- whatever voucher type it is on. So a PURCHASE voucher through the deployed
-- /entry screen with entity PERSONAL still lands in Drawings, bypassing the
-- drawings voucher type entirely — which is exactly the habit v3.2 §20 exists
-- to end.
--
--   Refusing PERSONAL on a TRANSACTION voucher would close it in three lines.
--   It is NOT done here, deliberately: /entry is deployed and I cannot see
--   what it sends, so a refusal added blind could break a working screen. It
--   is a screen-level fix (entity fixed to BUSINESS, §19.2) plus a later
--   database refusal once the screen is rebuilt. Recorded so it is not
--   forgotten, not silently patched.
--
-- FINDING 3 — THERE ARE NOW TWO WAYS TO MARK A GROUP HEADING. File 17a added
-- master_values.is_heading. But trg_party_validate already refuses PARTY_KIND
-- headings by a different test:
--
--     coalesce(notes,'') like 'GROUP HEADER%'
--
--   A hardcoded string prefix inside a notes field, which is the sort of thing
--   §1.9 exists to prevent, and which no masters admin screen could manage.
--   Nothing is broken — PARTY_KIND headings keep is_heading = false and stay
--   caught by their own test — but two mechanisms for one idea is how the
--   wrong one gets maintained. Unifying them means backfilling is_heading on
--   the PARTY_KIND headers and simplifying that trigger. That is masters work,
--   not save-path work, so it is flagged here and left for its own file.
--
-- ============================================================================
-- CORRECTION MADE AFTER THE FIRST RUN (21/07/2026)
-- ============================================================================
--
-- Verify checks 2 and 3 originally compared
-- pg_get_function_identity_arguments(p.oid) against the string
-- 'jsonb, text, text'. On this instance that function returns parameter NAMES
-- as well as types — 'p_lines jsonb, p_entry_type text, ...' — so neither
-- string could ever match. Check 3 failed spuriously and check 2 passed
-- VACUOUSLY, which is the worse of the two: it would have reported success
-- whether or not the old signature survived.
--
-- Both now count p.pronargs instead. The function itself was correct on the
-- first run and is UNCHANGED by this correction; only the verify block moved.
-- Recorded here so the repo copy and the version that ran are the same file
-- (the 21/07 lesson, third instance).
--
-- ============================================================================
-- OWNER RULINGS APPLIED (21/07/2026)
-- ============================================================================
--
--   1. Cost nature is OPTIONAL on a DRAWINGS line. §20.1's table says "as on
--      any other voucher", which reads as required; the owner ruled optional,
--      because "material" on a grocery bill is friction that answers nothing.
--      The spec needs the amendment — see the tail of this file.
--   2. Account 5070 deactivated (file 17a).
--   3. Group headings are rows, marked by is_heading (file 17a), refused here.
--
-- ============================================================================
-- WHAT DOES NOT CHANGE
-- ============================================================================
--
--   - The flat path. A call passing only p_lines behaves byte-identically to
--     today: p_tasks is null, the normaliser stamps task_no 1 and marks every
--     line a task head, and every rule downstream sees exactly what it saw
--     before. /entry (PB) and /sales (SI) need no change.
--   - Every refusal, flag and warning listed in the plan's §7.
--   - THE PARTY PATTERN CHECK STAYS ABOVE THE INSERT. File 13 moved it there
--     because the party's own history otherwise contained the line being
--     judged, so the check could never fire — dead from file 09 to file 13.
--     Moving it back while restructuring the loop is the single easiest
--     regression in this file. It is still above the insert. Verify check 10.
--   - Prefix-safe serial parsing: fy and serial are the LAST two segments.
--   - fn_generate_postings, untouched and uncalled-differently.
--
-- ============================================================================
-- RUN ORDER
-- ============================================================================
--
--   file 17    done, verified 21/07
--   file 17a   done, verified 21/07   <- REQUIRED: is_heading must exist
--   file 18    this file
--
-- Then the test plan in §8 of PLAN_file18_fn_save_voucher_tasks.md, in order.
-- Tests 1 and 2 are regression and nothing else matters if they fail.
-- ============================================================================


begin;


-- ============================================================================
-- SECTION 1 — fn_assert_master: a heading is not a value
-- ============================================================================
-- The choke point every master-validated value already passes through
-- (trg_txn_validate calls it ten times per row). Enforcing here means headings
-- are unpickable everywhere at once, including on screens not yet written,
-- with no per-screen logic. Same discipline as file 12's entity guard.
--
-- Unchanged from the original apart from the second IF: still STABLE, still
-- returns silently on a null code, still refuses an inactive value first.

create or replace function public.fn_assert_master(p_list text, p_code text)
 returns void
 language plpgsql
 stable
as $function$
begin
  if p_code is null then return; end if;

  if not exists (select 1 from master_values
                 where list_name = p_list and code = p_code and active) then
    raise exception '% "%" is not an active value in masters', p_list, p_code;
  end if;

  -- file 18: a group heading exists so that group_code has something to point
  -- at and so fn_master_set_group can be used from masters admin. It is a
  -- folder name, not a piece of work. Refused rather than flagged: a line
  -- posted to HOUSEHOLD would find no posting rule, land in Suspense and have
  -- to be corrected by hand.
  if exists (select 1 from master_values
              where list_name = p_list and code = p_code and is_heading) then
    raise exception
      '% "%" is a group heading, not a value you can choose. Pick one of the values inside it.',
      p_list, p_code;
  end if;
end $function$;


-- ============================================================================
-- SECTION 2 — fn_save_voucher
-- ============================================================================
-- See FINDING 1: the drop is required, not tidiness. Inside the transaction,
-- so a failure below leaves the old function in place.

drop function if exists public.fn_save_voucher(jsonb, text, text);

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

    if p_lines is not null then
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
      if v_farm is null then
        raise exception 'Line %: a farm is needed.', v_line_no;
      end if;
      if v_cost_obj is null then
        raise exception 'Line %: a cost object is needed — what carries this.', v_line_no;
      end if;
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
-- Structural only. It proves the function is INSTALLED correctly; it does not
-- prove it BEHAVES correctly. That is the test plan, and tests 1 and 2 are
-- regression: nothing else matters if they fail.
-- ============================================================================

select check_name, expected, actual,
       case when expected = actual then 'PASS' else 'FAIL' end as result
from (

  select '1. exactly one fn_save_voucher' as check_name, '1' as expected,
         count(*)::text as actual
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  -- The old 3-arg signature must be GONE, or every existing call is ambiguous.
  -- Counted by pronargs, not by an argument STRING: the text form of
  -- pg_get_function_identity_arguments includes parameter names on some
  -- Postgres versions ("p_lines jsonb, ...") and bare types on others, so a
  -- string comparison silently matches nothing and the check passes for the
  -- wrong reason. Found on the 21/07 run of this file, where it did exactly
  -- that. The argument COUNT is what distinguishes the two signatures.
  select '2. old 3-arg signature gone', '0',
         count(*)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'
     and p.pronargs = 3

  union all
  select '3. new 5-arg signature present', '1',
         count(*)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'
     and p.pronargs = 5

  union all
  select '4. still SECURITY DEFINER', 'true',
         bool_and(p.prosecdef)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  select '5. search_path still pinned', 'true',
         bool_and(p.proconfig::text like '%search_path=public%')::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_save_voucher'

  union all
  -- job_id and task_no are in the INSERT list at last (§16.28 finding 2)
  select '6. job_id written', 'true',
         (position('job_id' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '7. task_no written', 'true',
         (position('task_no' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '8. DRAWINGS admitted', 'true',
         (position('''DRAWINGS''' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  -- CONTRA and JOURNAL must still be refused by the guard
  select '9. guard still lists 3 shapes only', 'true',
         (position('not in (''TRANSACTION'',''SETTLEMENT'',''DRAWINGS'')' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  -- THE ONE THAT MATTERS MOST (file 13). The party pattern check reads
  -- v_party_payment_stats; that read must come BEFORE the insert into
  -- transactions, or the check is dead again and nothing will tell you.
  select '10. pattern check above the insert', 'true',
         (position('v_party_payment_stats' in prosrc)
            < position('insert into transactions' in prosrc))::text
    from pg_proc where proname = 'fn_save_voucher'

  union all
  select '11. fn_assert_master refuses headings', 'true',
         (position('is_heading' in prosrc) > 0)::text
    from pg_proc where proname = 'fn_assert_master'

  union all
  -- nothing else was touched
  select '12. fn_generate_postings untouched', '1',
         count(*)::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_generate_postings'

  union all
  -- the books are still square and the series still gap-free
  select '13. posting breaks', '0', count(*)::text from v_posting_breaks

  union all
  select '14. serial gaps', '0', count(*)::text from v_serial_gaps

) checks
order by lpad(split_part(check_name, '.', 1), 3, '0');


-- ============================================================================
-- AFTER THIS FILE
-- ============================================================================
--
-- WHAT IS NOW POSSIBLE: the database accepts the nested voucher and the
-- drawings voucher. WHAT IS NOT: the screens. §19's expense screen and §20's
-- drawings screen do not exist, so nothing can yet be entered through either.
-- File 18 is the door, not the room.
--
-- TEST BEFORE BUILDING ANYTHING ON IT — plan §8, in order:
--   1. a purchase through the deployed /entry            REGRESSION
--   2. a sales invoice through /sales, then settle it    REGRESSION
--      (SI -> RV must still close to zero against 1310)
--   3. the 13/07/2026 paper as tasks: 13 tasks, ~40 rows, Rs.48,575.
--      task_no runs 1..13; qty appears on exactly 13 rows and is null on the
--      rest; the acres sum to the paper and not to a multiple of it; no
--      spurious QTY NOT WRITTEN
--   4. a drawings voucher: cook, 7 days x Rs.200. Dr 3020, Cr the pocket,
--      entity PERSONAL, and absent from the P&L
--   5. the same watchman on a business AND a drawings voucher — one party
--      record, two accounts, one balance
--   6. refusals: a DRAWINGS line carrying a farm; a DRAWINGS line with no
--      party; a task whose rows do not sum to its stated total; a CLOSED
--      job_id; an activity that is a group heading
--   7. the within-voucher duplicate warning: same person twice on one task
--
-- SPEC AMENDMENTS OWED, once the tests pass — draft as v3.3, never ahead of
-- the database:
--   §20.1  cost nature on a DRAWINGS line: "as on any other voucher" becomes
--          optional (owner ruling, 21/07)
--   §3F    the is_heading flag on master lists
--   §19.5  the corrected cross-voucher duplicate test, on document reference
--   §12    the three 21/07 rulings drop off the open-decisions list; the
--          entity hole (FINDING 2) and the two heading mechanisms (FINDING 3)
--          go on it
--
-- AND THE SAFETY NET: LIVE_MODE is still SAMPLE. Everything entered so far is
-- disposable. If the task model is going to change, it changes now — after
-- go-live this function cannot be restructured casually again.
-- ============================================================================
