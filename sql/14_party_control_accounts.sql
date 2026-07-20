-- https://github.com/rjshvjy/farm-software/blob/main/sql/14_party_control_accounts.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — FILE 14 : CONTROL ACCOUNTS, AND THE BALANCE FIX
-- Written 20-07-2026 against DB_SCHEMA_CURRENT generated 20/07 12:25 IST.
-- Run after file 13. Re-runnable. Regenerate the snapshot after applying.
-- Spec: Requirements v3.0, Part 0.4, §18.1, §18.2, §18.5 steps 1 and 2, §16.20.
--
-- WHY THIS FILE EXISTS
--
--   1. v_party_balances IS WRONG TODAY, and wrong in the direction that makes
--      the estate chase people who have already paid. It nets the FLAT TABLE:
--
--          sum(received_cr) - sum(paid_out_dr)   group by party_code
--
--      A credit sale and the collection that clears it are BOTH money-in rows,
--      so a buyer who took Rs.1,20,000 of nuts and paid in full showed
--      Rs.2,40,000 owed. A cash sale — which creates no receivable at all —
--      also raised his "balance". The flat table records what the accountant
--      DID; the postings record what it MEANT. A balance is an accounting
--      fact and must be read from ledger_entries: the party's own control
--      account, Dr minus Cr. §18.2.
--
--   2. A PARTY HAS NO CONTROL ACCOUNT. Part 0.4 requires one per party, held
--      ON THE PARTY — parties.control_account — with a per-kind default that
--      pre-fills and never enforces.
--
--      NOT on the kind (§16.20). Kind is management data (tractor driver,
--      spray man, house cook); control account is accounting data. Letting the
--      first determine the second is the inversion Part 0.5 forbids. Tally
--      settles it: it has no party kinds at all — a ledger is placed in a
--      GROUP when created, and nothing infers that from the person's trade.
--      The pattern already exists here in file 10's default_entity: the kind
--      SUGGESTS, the record HOLDS, the transaction WINS.
--
-- SIGN CONVENTION (Part 0.4, and it works for both sides without a special
-- case): balance = Dr - Cr on the control account.
--      POSITIVE -> they owe the estate      (debtor: sale debits 1310)
--      NEGATIVE -> the estate owes them     (supplier: purchase credits 2010;
--                                            or a buyer's advance before his
--                                            invoice exists — a real state, and
--                                            §13 forbids any screen blocking it)
--
-- WHAT THIS FILE DOES NOT DO
--   - No settlement posting yet. Nothing resolves to a control account on
--     save, so a collection still cannot be ENTERED; that arrives with the
--     receipt screen (§18.5 step 4). This file makes the balance correct and
--     gives the receipt screen the account to post to.
--   - No screen changes. fn_party_upsert takes the account so the inline-add
--     panel can send it later; until it does, the kind's default applies.
--   - No ageing. Party-level outstanding only, bill-wise deliberately not
--     adopted (§16.17).
--
-- VERIFIED BEFORE WRITING (handover Part 3 §6 — check, do not assert):
--   - The snapshot carries no chart_of_accounts ROWS, so the account codes
--     could not be read from it directly. They are proven another way:
--     posting_rules.account_in has an FK to chart_of_accounts and file 12's
--     smoke test 0 returned 2010/1310 from it, so both accounts exist; file
--     12's smoke test 5 posted to 3010 through ledger_entries, which also has
--     an FK, so 3010 exists. 3020 is hardcoded in fn_generate_postings.
--     Section 0 below re-checks all four at run time anyway.
--     (Standing suggestion: extend 00_schema_snapshot.sql to inventory
--     chart_of_accounts and posting_rules rows. This is the third file whose
--     verification was blocked by their absence.)
--   - fn_party_upsert's exact body was read from the snapshot; section 5
--     reproduces it with the control-account resolution added and nothing
--     else changed.
--   - v_party_balances has three columns today, so CREATE OR REPLACE cannot
--     add one (the file-12 lesson from v_serial_gaps). It is dropped first.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. GUARD — the four control accounts must exist before anything references
--    them. Fail loudly here rather than leave parties pointing at nothing.
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(c, ', ') into v_missing
    from unnest(array['1310','2010','3010','3020']) c
   where not exists (select 1 from chart_of_accounts where account_code = c);
  if v_missing is not null then
    raise exception
      'Missing control account(s): %. File 14 needs debtors 1310, creditors 2010, owner capital 3010 and owner drawings 3020 in chart_of_accounts. Add them (or tell me the real codes) before running this.',
      v_missing;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. THE COLUMNS
--    parties.control_account  — the accounting fact, owner-editable, FK'd so a
--                               typo cannot create a ledger that does not exist
--    master_values.default_control_account — PARTY_KIND rows only. A PRE-FILL.
--                               Never enforced, exactly like default_entity.
-- ---------------------------------------------------------------------------
alter table parties
  add column if not exists control_account text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'parties_control_account_fkey') then
    alter table parties add constraint parties_control_account_fkey
      foreign key (control_account) references chart_of_accounts(account_code);
  end if;
end $$;

comment on column parties.control_account is
  'The account this party''s balance lives on (Part 0.4). Dr - Cr on it IS the balance: positive they owe us, negative we owe them. Held on the PARTY, not derived from the kind — kind is farm data, this is accounting data (§16.20). Seeded from the kind''s default at creation; owner-editable thereafter.';

alter table master_values
  add column if not exists default_control_account text;

comment on column master_values.default_control_account is
  'PARTY_KIND rows only: the control account a party of this kind USUALLY has. Pre-fills at party creation and never enforces — the one labourer who runs a permanent advance is overridden on his own record, not by changing this master (§16.20).';


-- ---------------------------------------------------------------------------
-- 2. THE PRE-FILL DEFAULTS
--    Reasoning, so the next person can argue with it rather than guess:
--
--    Everyone who supplies goods, services or labour and may be owed money at
--    a moment in time is a CREDITOR (2010). By Tally's logic a daily labourer
--    owed three days' wages is simply Sundry Creditors — he gave services, the
--    estate owes him, credit the giver — and there is no separate wages-payable
--    account unless volume ever justifies a distinct balance-sheet line (§12).
--    In practice most labour is paid the same day in cash and never carries a
--    balance at all.
--
--    CUSTOMER buys produce, so 1310. TRADER is the interesting one: file 10
--    describes it as "both directions", and one account is deliberate (§16.16)
--    — the balance simply swings sign, which is the honest net position and
--    avoids the unanswerable "which of these two numbers does he owe?". It
--    defaults to 1310 because a trader on this estate is usually buying nuts.
--
--    OWNER is capital (3010). FAMILY is drawings (3020): money to a family
--    member is the household taking money out, not an estate cost (§1.3).
--
--    Group headings get nothing — they are not selectable on a voucher.
--
--    These are DEFAULTS. Change them freely in masters admin; existing parties
--    are unaffected, which is the whole point of holding the account on the
--    party.
-- ---------------------------------------------------------------------------
update master_values set default_control_account = '2010'
 where list_name = 'PARTY_KIND'
   and group_code in ('FARM LABOUR','HOUSEHOLD','INSTITUTION','PROFESSIONAL')
   and default_control_account is null;

update master_values set default_control_account = '2010'
 where list_name = 'PARTY_KIND'
   and code in ('SUPPLIER','TRANSPORT')
   and default_control_account is null;

update master_values set default_control_account = '1310'
 where list_name = 'PARTY_KIND'
   and code in ('CUSTOMER','TRADER')
   and default_control_account is null;

update master_values set default_control_account = '3010'
 where list_name = 'PARTY_KIND' and code = 'OWNER'
   and default_control_account is null;

update master_values set default_control_account = '3020'
 where list_name = 'PARTY_KIND' and code = 'FAMILY'
   and default_control_account is null;


-- ---------------------------------------------------------------------------
-- 3. BACKFILL EXISTING PARTIES from their kind's default.
--    "where control_account is null" so a party the owner has already set is
--    never overwritten on a re-run.
-- ---------------------------------------------------------------------------
update parties p
   set control_account = mv.default_control_account
  from master_values mv
 where mv.list_name = 'PARTY_KIND'
   and mv.code = p.kind
   and p.control_account is null
   and mv.default_control_account is not null;


-- ---------------------------------------------------------------------------
-- 4. A PARTY WITH NO CONTROL ACCOUNT IS VISIBLE, NOT SILENT.
--    Deliberately a view, not a NOT NULL constraint: an unmapped party must
--    not block entry (the Suspense philosophy, §2 — blocking the accountant
--    teaches people to route around the system). It is reported instead, and
--    the review queue will read this later.
-- ---------------------------------------------------------------------------
create or replace view v_parties_without_control_account as
  select p.party_code, p.name, p.kind, p.status
    from parties p
   where p.control_account is null
     and p.status = 'ACTIVE';

comment on view v_parties_without_control_account is
  'Active parties whose balance has nowhere to live (file 14). Should be empty; a row means the kind had no default when the party was made. Fix on the party, not by changing the master.';


-- ---------------------------------------------------------------------------
-- 5. fn_party_upsert — resolves the control account the same way it already
--    resolves the entity. The 6-argument overload is DROPPED, not left
--    beside the new one: file 11 exists because a stale overload lingered.
--    Existing callers (app/entry/actions.ts createParty, named params) resolve
--    to this signature because the new argument has a default.
-- ---------------------------------------------------------------------------
drop function if exists fn_party_upsert(text, text, text, text, text, text);

create or replace function fn_party_upsert(
  p_code text,
  p_name text,
  p_kind text default 'DAILY LABOUR',
  p_mobile text default null,
  p_notes text default null,
  p_default_entity text default null,
  p_control_account text default null)          -- 14:
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code    text := upper(trim(p_code));
  v_kind    text := upper(trim(coalesce(p_kind, 'DAILY LABOUR')));
  v_entity  text;
  v_account text;                                -- 14:
begin
  -- MASTER_APPEND covers the accountant; MASTER_MANAGE covers the owner.
  if not (fn_has_capability('MASTER_APPEND')
          or fn_has_capability('MASTER_MANAGE')) then
    raise exception
      'You do not have permission to add parties (signed in as %)',
      fn_actor_email();
  end if;

  if v_code = '' then
    raise exception 'A party needs a code';
  end if;
  if trim(coalesce(p_name,'')) = '' then
    raise exception 'A party needs a name';
  end if;

  -- The trigger from file 10 judges the kind too; this gives the friendlier
  -- message, naming the fix rather than the failure.
  if not exists (select 1 from master_values
                  where list_name = 'PARTY_KIND' and code = v_kind and active) then
    raise exception
      'Party kind "%" is not an active PARTY_KIND value. Add it in masters admin first.',
      v_kind;
  end if;

  v_entity := coalesce(
    nullif(trim(coalesce(p_default_entity,'')), ''),
    (select default_entity from master_values
      where list_name = 'PARTY_KIND' and code = v_kind));

  -- 14: same shape as the entity above — what was passed wins, else the
  -- kind's pre-fill. The kind never overrides an explicit choice.
  v_account := coalesce(
    nullif(trim(coalesce(p_control_account,'')), ''),
    (select default_control_account from master_values
      where list_name = 'PARTY_KIND' and code = v_kind));

  insert into parties (party_code, name, kind, mobile, notes, default_entity,
                       control_account, created_by)
  values (v_code, trim(p_name), v_kind,
          nullif(trim(coalesce(p_mobile,'')),''),
          nullif(trim(coalesce(p_notes,'')),''),
          v_entity, v_account, fn_actor_email())
  on conflict (party_code) do update set
    name            = excluded.name,
    kind            = excluded.kind,
    mobile          = coalesce(excluded.mobile, parties.mobile),
    notes           = coalesce(excluded.notes, parties.notes),
    default_entity  = coalesce(excluded.default_entity, parties.default_entity),
    -- 14: never silently re-file an existing party's balance because their
    -- kind was edited. An explicit new account wins; otherwise keep theirs.
    control_account = coalesce(excluded.control_account, parties.control_account);

  return v_code;
end $$;

comment on function fn_party_upsert(text, text, text, text, text, text, text) is
  'One register of everyone (§16.13). File 14 adds the control account: passed value wins, else the kind''s pre-fill, and an existing party''s account is never overwritten by a kind change.';


-- ---------------------------------------------------------------------------
-- 6. v_party_balances — READ FROM THE POSTINGS (§18.2)
--
--    Dropped and recreated: the column list changes, and CREATE OR REPLACE
--    VIEW cannot do that.
--
--    The join is the whole fix. Only postings that land on THIS party's
--    control account count. So:
--      credit sale       Dr 1310  -> raises his balance     (he owes)
--      collection        Cr 1310  -> lowers it              (settled)
--      CASH sale         no 1310 leg at all -> NO EFFECT    (nothing is owed)
--      cash wages to him no 2010 leg at all -> NO EFFECT
--    The old view moved the balance on all four.
-- ---------------------------------------------------------------------------
drop view if exists v_party_balances;

create view v_party_balances as
  select p.party_code,
         p.name,
         p.kind,
         p.control_account,
         coalesce(sum(le.dr), 0) - coalesce(sum(le.cr), 0) as balance
    from parties p
    left join transactions t
           on t.party_code = p.party_code
          and t.status = 'LIVE'
    left join ledger_entries le
           on le.txn_row_id = t.row_id
          and le.status = 'LIVE'
          and le.account_code = p.control_account
   group by p.party_code, p.name, p.kind, p.control_account;

comment on view v_party_balances is
  'Party outstanding, from the POSTINGS (§18.2). balance = Dr - Cr on the party''s own control account: positive they owe the estate, negative the estate owes them (a buyer''s advance before his invoice — a real state, never blocked). Was computed from the flat table until 20-07-2026 and double-counted every settled sale.';


-- ---------------------------------------------------------------------------
-- 7. PostgREST schema cache. NEW CONVENTION from 20-07-2026: every numbered
--    file ends with this. File 12 altered master_values and dropped two
--    functions; the cache did not catch up, v_party_kinds became unreadable
--    through the API while remaining perfectly readable in SQL, and an evening
--    went into diagnosing a layer the SQL tests cannot see. Harmless when
--    unnecessary.
-- ---------------------------------------------------------------------------
notify pgrst, 'reload schema';


-- ============================================================================
-- SMOKE TESTS — one paste, one result table, no residue. Same convention as
-- 12_smoke_tests.sql: it saves real vouchers, checks, then deletes its own
-- rows and restores the serial counters.
--
-- WHAT IT CANNOT TEST YET: a collection. Nothing resolves to a control
-- account on save until the receipt screen's posting path exists (§18.5
-- step 4), so the Cr 1310 leg cannot be entered from SQL either. The tests
-- below instead use the case that discriminates the old view from the new
-- one just as sharply — a CASH sale, which creates no receivable at all and
-- which the old view wrongly counted as money owed.
-- ============================================================================

drop table if exists zz_pb_results;
create temp table zz_pb_results (
  seq int, what text, expected text, result text, detail text);

do $$
declare
  v_date   date := date '2026-07-17';
  v_pfx    text := fn_fy_prefix(date '2026-07-17');
  v_party  text := 'ZZBALTEST';
  v_vouchers text[] := '{}';
  v_rec_before int;
  v_bal    numeric;
  v_acct   text;
  v_res    jsonb;
  v_seq    int := 0;
  v_lines  jsonb;

begin
  select last_no into v_rec_before from voucher_serials
   where voucher_type = 'RECEIPT' and fy_prefix = v_pfx;

  -- a CUSTOMER, created through the real function so the default is exercised
  perform fn_party_upsert(v_party, 'ZZ Balance Test Buyer', 'CUSTOMER');

  -- 1. the pre-fill reached the party
  v_seq := v_seq + 1;
  select control_account into v_acct from parties where party_code = v_party;
  insert into zz_pb_results values (v_seq, 'CUSTOMER gets debtors by default',
    '1310',
    case when v_acct = '1310' then 'PASS' else 'FAIL' end,
    'got ' || coalesce(v_acct, '(null)'));

  -- 2. a CREDIT sale raises the balance
  v_seq := v_seq + 1;
  v_lines := jsonb_build_array(jsonb_build_object(
    'payment_date', v_date, 'period_from', v_date, 'period_to', v_date,
    'entity','BUSINESS','farm','NTH','block','YET TO ASSIGN',
    'cost_object','COCONUT','activity','PRODUCE SALE',
    'capex_flag','RECURRING','cost_nature','OTHER',
    'qty',500,'unit','NOS','received_cr',12000,
    'mode','ON CREDIT','party_code',v_party,
    'narration','Balance test credit sale of nuts'));
  v_res := fn_save_voucher(v_lines, null, 'RECEIPT');
  v_vouchers := v_vouchers || (v_res->>'voucher_no');

  select balance into v_bal from v_party_balances where party_code = v_party;
  insert into zz_pb_results values (v_seq, 'Credit sale raises the balance',
    'Rs.12,000 owed',
    case when v_bal = 12000 then 'PASS' else 'FAIL' end,
    'balance = ' || v_bal);

  -- 3. THE DISCRIMINATOR. A CASH sale creates no receivable. The old view
  --    added it to what he owed; the new one must not move at all.
  v_seq := v_seq + 1;
  v_lines := jsonb_build_array(jsonb_build_object(
    'payment_date', v_date, 'period_from', v_date, 'period_to', v_date,
    'entity','BUSINESS','farm','NTH','block','YET TO ASSIGN',
    'cost_object','COCONUT','activity','PRODUCE SALE',
    'capex_flag','RECURRING','cost_nature','OTHER',
    'qty',200,'unit','NOS','received_cr',5000,
    'mode','CASH','party_code',v_party,
    'narration','Balance test cash sale over the counter'));
  v_res := fn_save_voucher(v_lines, null, 'RECEIPT');
  v_vouchers := v_vouchers || (v_res->>'voucher_no');

  select balance into v_bal from v_party_balances where party_code = v_party;
  insert into zz_pb_results values (v_seq, 'Cash sale does NOT raise it',
    'still Rs.12,000 — cash sales owe nothing',
    case when v_bal = 12000 then 'PASS' else 'FAIL' end,
    'balance = ' || v_bal || ' (the old view would say 17000)');

  -- 4. no active party left without an account
  v_seq := v_seq + 1;
  insert into zz_pb_results
  select v_seq, 'Every active party has a control account', '0 rows',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         count(*) || ' without: ' ||
         coalesce(string_agg(party_code, ', '), '(none)')
    from v_parties_without_control_account;

  -- ---- clean up ----------------------------------------------------------
  perform fn_ledger_write_on();
  delete from ledger_entries where txn_row_id in
    (select row_id from transactions where voucher_no = any (v_vouchers));
  delete from flags where row_id in
    (select row_id from transactions where voucher_no = any (v_vouchers));
  delete from transactions where voucher_no = any (v_vouchers);
  delete from vouchers    where voucher_no = any (v_vouchers);
  delete from parties     where party_code = v_party;

  if v_rec_before is null then
    delete from voucher_serials where voucher_type = 'RECEIPT' and fy_prefix = v_pfx;
  else
    update voucher_serials set last_no = v_rec_before
     where voucher_type = 'RECEIPT' and fy_prefix = v_pfx;
  end if;

  v_seq := v_seq + 1;
  insert into zz_pb_results
  select v_seq, 'Cleanup: nothing left behind', '0 rows',
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         count(*) || ' test rows remain'
    from transactions where voucher_no = any (v_vouchers);
end $$;

select seq, what, expected, result, detail from zz_pb_results order by seq;
