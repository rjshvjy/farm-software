-- ============================================================================
-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 2 of 4 : ENTRY LAYER
-- Run after 01_foundations.sql. Re-runnable.
--
-- Contents: parties, vouchers (thin control table), transactions (THE flat
-- table, v9 columns 1:1), history (empty twin), voucher serials.
--
-- Spec references: §1.1, §2, §4, §6, §10.2, §10.4, §12
-- ============================================================================

drop table if exists transactions    cascade;
drop table if exists history         cascade;
drop table if exists vouchers        cascade;
drop table if exists voucher_serials cascade;
drop table if exists parties         cascade;

-- ---------------------------------------------------------------------------
-- 1. PARTIES (§10.4) — suppliers and customers behind credit rows.
--    Built now because ON CREDIT transactions reference it from day one.
--    Running balance is COMPUTED from rows (view in file 4), never stored.
-- ---------------------------------------------------------------------------
create table parties (
  party_code text primary key,               -- short stable code, e.g. 'RAJENDRAN'
  name       text not null,
  kind       text not null default 'BOTH' check (kind in ('SUPPLIER','CUSTOMER','BOTH')),
  mobile     text,
  status     text not null default 'ACTIVE' check (status in ('ACTIVE','DISABLED')),
  notes      text,
  created_at timestamptz not null default now(),
  created_by text
);

-- ---------------------------------------------------------------------------
-- 2. VOUCHERS — the thin control table (agreed ruling 1).
--    Holds ONLY what belongs to the paper slip as a whole; every rupee and
--    every classification stays on the lines (§1.1 intact).
-- ---------------------------------------------------------------------------
create table vouchers (
  voucher_no    text primary key,            -- '26/0001'
  fy_prefix     text not null,               -- '26' = FY start year of PAYMENT DATE (§4)
  serial_no     integer not null,
  status        text not null default 'ACTIVE'
                  check (status in ('ACTIVE','CANCELLED')),  -- number NEVER reused (§4)
  cancel_reason text,
  cancelled_by  text,
  cancelled_at  timestamptz,
  exported_at   timestamptz,                 -- set by the Tally exporter (Stage D);
                                             -- non-null = corrections must reverse, not supersede
  export_batch  text,
  prior_period  boolean not null default false, -- late voucher for a closed FY (§4)
  created_by    text not null,
  created_at    timestamptz not null default now(),
  unique (fy_prefix, serial_no)
);

comment on table vouchers is
  'Thin control table: serial, cancellation, export marker. Audit state is computed from audit_marks (file 4).';

-- ---------------------------------------------------------------------------
-- 3. VOUCHER SERIALS (§4) — gap-free, lock-safe, per FY prefix.
--    Issued INSIDE the save transaction (file 4): an abandoned form burns
--    nothing; concurrent saves cannot collide; gaps are impossible, so the
--    monthly sequence-integrity check treats any gap as an incident.
-- ---------------------------------------------------------------------------
create table voucher_serials (
  fy_prefix text primary key,
  last_no   integer not null default 0
);

create or replace function fn_fy_prefix(p_date date) returns text
language sql immutable as $$
  select case when extract(month from p_date) >= 4
              then to_char(p_date, 'YY')
              else to_char(p_date - interval '1 year', 'YY') end
$$;

create or replace function fn_fy_label(p_date date) returns text
language sql immutable as $$
  select case when extract(month from p_date) >= 4
    then to_char(p_date,'YYYY') || '-' || to_char(p_date + interval '1 year','YY')
    else to_char(p_date - interval '1 year','YYYY') || '-' || to_char(p_date,'YY') end
$$;

-- Serial issue. Late voucher for a CLOSED FY takes the CURRENT-FY series (§4);
-- that decision is made by the caller (file 4), which passes the series date.
create or replace function fn_next_voucher_no(p_series_date date) returns text
language plpgsql as $$
declare pfx text := fn_fy_prefix(p_series_date); n integer;
begin
  insert into voucher_serials (fy_prefix) values (pfx)
    on conflict (fy_prefix) do nothing;
  update voucher_serials set last_no = last_no + 1
    where fy_prefix = pfx returning last_no into n;
  return pfx || '/' || lpad(n::text, 4, '0');
end $$;

-- ---------------------------------------------------------------------------
-- 4. TRANSACTIONS — the book. One row = one voucher line (§1.1).
--    v9 columns 1:1 (verified against the workbook 18-07-2026) plus the
--    correction-model columns agreed in design: status / superseded_by /
--    correction_id.
--
--    Immutability (§1.6): no role has UPDATE/DELETE here. A trigger blocks
--    even accidental service-role edits unless a write token is set — the
--    named functions in file 4 set it. The owner's dashboard escape hatch
--    still exists (owner can disable the trigger deliberately).
-- ---------------------------------------------------------------------------
create table transactions (
  row_id         text primary key,                       -- 'T000001' (§4)
  voucher_no     text not null references vouchers(voucher_no),
  line_no        integer not null,                       -- position within the voucher
  payment_date   date not null,                          -- cash movement; drives FY, cash book
  period_from    date,                                   -- days the work covers, PER LINE (§2)
  period_to      date,
  fy             text generated always as (fn_fy_label(payment_date)) stored,
  month          integer generated always as (extract(month from payment_date)::int) stored,
  entity         text not null check (entity in ('BUSINESS','PERSONAL','FUNDING')), -- fixed list (§1.3)
  farm           text not null,
  block          text,
  cost_object    text not null,
  activity       text not null,
  capex_flag     text not null default 'RECURRING',
  cost_nature    text,
  qty            numeric(14,3),
  unit           text,
  qty_metre      numeric(14,3) generated always as (
                   case when unit = 'FEET'  then round(qty * 0.3048, 3)
                        when unit = 'METRE' then qty end) stored,
  mandays        numeric(10,2),
  rate           numeric(14,2),
  paid_out_dr    numeric(14,2) check (paid_out_dr  is null or paid_out_dr  > 0),
  received_cr    numeric(14,2) check (received_cr is null or received_cr > 0),
  mode           text not null,                          -- §13: never blank
  job_id         text,                                   -- FK added when Jobs table ships (Stage B)
  party_code     text references parties(party_code),    -- mandatory when mode is a CREDIT kind
  payee          text,                                   -- free-text payee as on the paper
  narration      text,                                   -- describes its own row's amount (§13)
  review         text,
  old_ledger     text,                                   -- audit column from migration; null on new rows
  entry_type     text not null default 'NORMAL' check (entry_type in
                   ('NORMAL','TRANSFER','REVERSAL','CORRECTION','MIGRATED','SAMPLE','OPENING')),
  ref_row_id     text,                                   -- REVERSAL OF / CORRECTS target (§6)
  legal_entity   text not null default 'UNASSIGNED',     -- derived from block ownership (§11)
  paid_by_entity text,                                   -- inter-entity receivable marker (§11)
  flagged        boolean not null default false,
  flag_reason    text,                                   -- code from FLAG_REASON master
  entered_by     text not null,                          -- server-stamped (§2); functions set from session
  entered_at     timestamptz not null default now(),
  -- correction model (agreed): versioning, never editing
  status         text not null default 'LIVE' check (status in
                   ('LIVE','SUPERSEDED','REVERSED','CANCELLED')),
  superseded_by  text,                                   -- row_id of the replacement line
  correction_id  text,                                   -- correction_log id when this row was born as a fix
  -- §13: never both DR and CR on one row; exactly one, positive
  check (num_nonnulls(paid_out_dr, received_cr) = 1)
);

-- Exactly one LIVE line per voucher position. A partial index, not a plain
-- unique constraint: a line corrected twice leaves several SUPERSEDED
-- versions at the same position, which is fine — only LIVE must be unique.
create unique index uq_txn_live_line on transactions (voucher_no, line_no)
  where status = 'LIVE';

create index idx_txn_payment_date on transactions (payment_date);
create index idx_txn_voucher      on transactions (voucher_no);
create index idx_txn_status       on transactions (status);
create index idx_txn_dims         on transactions (farm, cost_object, activity);
create index idx_txn_party        on transactions (party_code) where party_code is not null;

comment on table transactions is
  'THE flat table (§1.1). One row per voucher line. Rows are never edited: corrections supersede or reverse (§6 + agreed model).';

-- Master-code validation (composite-key lookup; the constant-in-FK problem —
-- see block_ownership in file 1 for the same pattern):
create or replace function trg_txn_validate() returns trigger
language plpgsql as $$
declare v_mode_kind text;
begin
  perform fn_assert_master('FARM',        new.farm);
  perform fn_assert_master('BLOCK',       new.block);
  perform fn_assert_master('COST_OBJECT', new.cost_object);
  perform fn_assert_master('ACTIVITY',    new.activity);
  perform fn_assert_master('CAPEX_FLAG',  new.capex_flag);
  perform fn_assert_master('COST_NATURE', new.cost_nature);
  perform fn_assert_master('UNIT',        new.unit);
  perform fn_assert_master('MODE',        new.mode);
  perform fn_assert_master('FLAG_REASON', new.flag_reason);
  perform fn_assert_master('LEGAL_ENTITY',new.legal_entity);

  select mode_kind into v_mode_kind
    from master_values where list_name='MODE' and code=new.mode;
  if v_mode_kind = 'CREDIT' and new.party_code is null then
    raise exception 'Credit mode "%" requires a party (§10.4)', new.mode;
  end if;

  if new.period_from is not null and new.period_to is not null
     and new.period_from > new.period_to then
    raise exception 'PERIOD FROM after PERIOD TO';
  end if;
  return new;
end $$;

create trigger txn_validate
  before insert on transactions
  for each row execute function trg_txn_validate();

-- Immutability guard: writes only through the named functions (file 4),
-- which set the token. Everything else — app, accident, curiosity — bounces.
create or replace function trg_ledger_write_guard() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.ledger_write', true), '') <> 'on' then
    raise exception 'Rows are immutable (§1.6). Use the correction functions, never UPDATE/DELETE.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger txn_update_guard
  before update or delete on transactions
  for each row execute function trg_ledger_write_guard();

-- ---------------------------------------------------------------------------
-- 5. HISTORY — same shape, 'H' row ids, ENTRY TYPE=MIGRATED, created now,
--    stays empty unless an import is ever chosen (§8, §12). Reports read the
--    union view (file 4) from day one, so a later import changes nothing
--    downstream. There is never a physical merge (§8).
--    No FK to vouchers: history rows carry their old voucher text as-is.
-- ---------------------------------------------------------------------------
create table history (
  like transactions including defaults including constraints
);
-- LIKE copies columns + check constraints, NOT foreign keys and NOT the
-- generated-column expressions (fy/month/qty_metre become plain columns here,
-- which is what the import script needs — it writes them directly from v9).
alter table history add primary key (row_id);

create trigger history_update_guard
  before update or delete on history
  for each row execute function trg_ledger_write_guard();

comment on table history is
  'The 4,002 migrated rows IF ever imported (§8: optional, not planned). Import script is the only writer; truncate-and-reload; physically incapable of touching transactions (§12).';

-- ============================================================================
-- End of file 2. Next: 03_posting_layer.sql
-- ============================================================================
