// https://github.com/rjshvjy/farm-software/blob/main/app/entry/VoucherEntry.tsx
// app/entry/VoucherEntry.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the voucher entry screen (§5; rewritten 19-07-2026
// to catch up with SQL file 08, handover Part 2 §2).
//
// WHAT THIS SCREEN IS
//   Payment vouchers only: money out. One paper slip = one voucher = a header
//   filled once plus lines. Receipts, transfers, advances are Stage B screens.
//
// THE CONTRACT (repeated because it is the whole design):
//   This screen collects fields, calls saveVoucher, and DISPLAYS EVERYTHING
//   that comes back. The rules live in the database. The screen PREVIEWS the
//   rules — the red/amber panel below — using thresholds handed to it from
//   config, so she fixes a refusal before the round-trip; but the database
//   re-derives everything and its verdict always wins and is always shown.
//
// NEW IN THIS REWRITE (all settled in the plan of 19-07-2026):
//   - COST NATURE: header default (COST_NATURE master), per-line override.
//     One job, two natures → two lines (the owner's training point).
//   - PERIOD FROM/TO required in the header, inherited by every line.
//     Deliberately NOT defaulted from the payment date (owner's decision:
//     the period often differs from the payment date; choose consciously).
//   - NARRATION carries forward when a new line copies the one above, with a
//     live character counter (floor 5, or 15 on a vague head — both from
//     config, never literals).
//   - PARTY on BANK and CREDIT kinds: type-ahead with inline "+ Add" that
//     calls createParty (fn_party_upsert). Code auto-derived from the name,
//     collision-checked against the loaded list BEFORE calling — because
//     fn_party_upsert overwrites on collision by design, the screen owns the
//     "use existing or create new?" question.
//   - PREVIEW PANEL replaces window.confirm: red = the DB will refuse (Save
//     is disabled with reasons shown); amber = it will save and be flagged
//     (Save becomes an explicit two-click "Save with N flags → Confirm").
//   - CASH IN HAND in the header, from v_pocket_balances at load and from
//     the save result after each save. Labelled SAMPLE while LIVE_MODE is.
//   - DB refusals that name a line ("Line 3: …") highlight that line.
//   - HELP STRIP fixed at the bottom (the Tally convention): what the
//     focused field wants, plus the chosen master value's notes — the notes
//     are DATA from the master, so the strip improves as masters admin
//     fills them in, with no screen change.
//   - Type-ahead (Combo) on the long lists: activity, cost object, party.
//     Short fixed lists (entity, capex, mode, unit, cost nature, farm,
//     block) stay native selects — a 4-item list is faster as a select, and
//     native selects already jump on first letter.
//   - Design tokens (bg-muted, text-muted-foreground, …) instead of raw
//     colours, so dark mode works and the shell (build order #6) inherits
//     a consistent base. Amounts right-aligned in tabular-nums.
//
// STILL DELIBERATELY OWED (ergonomics pass, handover §8): the denser
// twelve-line grid rework and field-level (not line-level) error placement.
// ---------------------------------------------------------------------------
"use client";

import React, { useMemo, useRef, useState } from "react";
import { formatDMY, parseDMY, formatINR } from "@/lib/dates";
import {
  saveVoucher,
  createParty,
  type VoucherLine,
  type SaveResult,
  type PartyKind,
} from "./actions";

// --- types coming from the server component --------------------------------

export type MasterRow = {
  list_name: string;
  code: string;
  label: string;
  sort_order: number;
  required_unit: string | null;
  mode_kind: string | null;
  parent_farm: string | null;
  notes: string | null;
};

export type PartyRow = { party_code: string; name: string; kind: string };

type Props = {
  masters: Record<string, MasterRow[]>;
  parties: PartyRow[];
  today: string; // ISO, from fn_today() — the estate's date, never the browser's
  vagueActivities: string[]; // config VAGUE_ACTIVITIES
  narrationMin: number; // config NARRATION_MIN (5): floor on EVERY line
  vagueNarrationMin: number; // config VAGUE_NARRATION_MIN (15): vague heads
  sampleMode: boolean; // config LIVE_MODE === 'SAMPLE'
  initialCashBalance: number | null; // v_pocket_balances CASH at page load
  oneTimeMax: number; // config ONE_TIME_MAX (file 09)
  lineAmountWarn: number; // config LINE_AMOUNT_WARN (file 09)
  partyWarnMult: number; // config PARTY_WARN_MULT (file 09)
  // v_party_payment_stats: each party's own record, for the self-calibrating
  // warning. Empty on day one — the warning simply stays silent until there
  // is a pattern to compare against.
  partyStats: Record<
    string,
    { times_paid: number; max_paid: number; avg_paid: number; last_paid: string }
  >;
  userEmail: string;
};

// One line as the screen holds it (strings while editing; converted on save).
type EditLine = {
  entity: string;
  farm: string;
  block: string;
  cost_object: string;
  activity: string;
  capex_flag: string;
  qty: string;
  unit: string;
  mandays: string;
  rate: string;
  amount: string;
  payee: string; // blank = inherit header payee
  narration: string;
  party_code: string; // blank = inherit header party
  cost_nature: string; // carries forward as each new line copies the one above
};

type SavedVoucher = {
  voucher_no: string;
  payee: string;
  total: number;
  dateISO: string;
};

// ENTITY is a fixed CHECK constraint in the schema (§1.3), not a master list —
// the one list that is legitimately literal here.
const ENTITIES = ["BUSINESS", "PERSONAL", "FUNDING"];

const emptyLine = (): EditLine => ({
  entity: "BUSINESS",
  farm: "",
  block: "YET TO ASSIGN",
  cost_object: "",
  activity: "",
  capex_flag: "RECURRING",
  qty: "",
  unit: "",
  mandays: "",
  rate: "",
  amount: "",
  payee: "",
  narration: "",
  party_code: "",
  cost_nature: "",
});

// ---------------------------------------------------------------------------
// Party code derivation — the screen's half of the inline-add bargain.
// Full name uppercased (the schema's own convention: "short stable code,
// e.g. 'RAJENDRAN'"), NOT abbreviated: dropping vowels merges exactly the
// letters that distinguish similar names. Collision safety comes from the
// check against the loaded list, not from squeezing.
// ---------------------------------------------------------------------------
function deriveCode(name: string): string {
  let c = name
    .toUpperCase()
    .replace(/[^A-Z0-9 ]+/g, " ") // punctuation → space
    .replace(/\s+/g, " ")
    .trim();
  if (c.length > 24) {
    c = c.slice(0, 24);
    const cut = c.lastIndexOf(" ");
    if (cut > 8) c = c.slice(0, cut); // break at a word, not mid-word
  }
  return c;
}

function bumpCode(base: string, taken: (code: string) => boolean): string {
  for (let n = 2; n < 100; n++) {
    const c = `${base} ${n}`;
    if (!taken(c)) return c;
  }
  return `${base} X`; // 99 same-named parties means a bigger problem
}

// ---------------------------------------------------------------------------
// Amount in words, Indian system — the oldest anti-typo device in banking.
// Misreading 40000 as 4000 is easy; misreading "forty thousand" as "four
// thousand" is not. Whole rupees only: paise are not where digit errors live.
// ---------------------------------------------------------------------------
const ONES = [
  "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
  "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
  "seventeen", "eighteen", "nineteen",
];
const TENS = [
  "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
  "eighty", "ninety",
];

function twoDigits(n: number): string {
  if (n < 20) return ONES[n];
  return (TENS[Math.floor(n / 10)] + " " + ONES[n % 10]).trim();
}

export function amountInWords(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return "";
  const w = Math.floor(Math.abs(n));
  if (w === 0) return "";
  const crore = Math.floor(w / 10000000);
  const lakh = Math.floor((w % 10000000) / 100000);
  const thousand = Math.floor((w % 100000) / 1000);
  const hundred = Math.floor((w % 1000) / 100);
  const rest = w % 100;
  const parts: string[] = [];
  if (crore) parts.push(twoDigits(crore) + " crore");
  if (lakh) parts.push(twoDigits(lakh) + " lakh");
  if (thousand) parts.push(twoDigits(thousand) + " thousand");
  if (hundred) parts.push(ONES[hundred] + " hundred");
  if (rest) parts.push(twoDigits(rest));
  return parts.join(" ") + " rupees";
}

// ---------------------------------------------------------------------------
// SHARED STYLES + SMALL COMPONENTS — module level, deliberately.
//
// These were originally defined INSIDE VoucherEntry. That is the bug the
// 19-07 evening test found: every keystroke re-renders VoucherEntry, which
// re-CREATES any component defined inside it; React sees a new component
// type, unmounts the old field and mounts a fresh one, and the cursor falls
// out after every character. Hoisted here, their identity is stable across
// renders and focus survives typing. Rule for this file: no component
// definitions inside VoucherEntry, ever.
// ---------------------------------------------------------------------------

// One step up from the original xs/sm scale — the labels were unreadable at
// a desk. Inputs at text-base, labels at text-sm.
const inputCls =
  "border border-input bg-background rounded px-2 py-1.5 text-base w-full " +
  "focus:outline-none focus:ring-2 focus:ring-ring";
const labelCls = "block text-sm text-muted-foreground mb-1";
const numCls = inputCls + " text-right tabular-nums";

/**
 * One labelled band of the line. The heading is the QUESTION the fields
 * answer — Where, What work, On what, How much, Who and why. A shaded
 * heading strip over a bordered body makes the five bands read as five
 * sections at a glance; items-end keeps every input box on one baseline
 * even where a label wraps to two lines.
 */
function FieldBand({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  // NOTE: no `overflow-hidden` here, ever. It clips the type-ahead dropdowns,
  // which are absolutely positioned and must escape the band. Rounded corners
  // are done per-child instead, which achieves the same look without clipping.
  return (
    <div className="mb-4 rounded-lg border border-input">
      <div className="bg-muted rounded-t-lg px-3 py-1.5 text-sm font-semibold tracking-wide text-muted-foreground uppercase border-b border-input">
        {title}
      </div>
      <div className="p-3 grid grid-cols-2 md:grid-cols-6 gap-3 items-end bg-background rounded-b-lg">
        {children}
      </div>
    </div>
  );
}

/** Full-width hint line inside a band — spans the grid, never breaks
 *  the column rhythm the way an inline flex span did. */
function BandHint({ children }: { children: React.ReactNode }) {
  return (
    <div className="col-span-2 md:col-span-6 text-sm text-muted-foreground -mt-1">
      {children}
    </div>
  );
}

function Sel({
  value,
  onChange,
  options,
  allowBlank,
  onFocus,
}: {
  value: string;
  onChange: (v: string) => void;
  options: { code: string; label: string }[];
  allowBlank?: boolean;
  onFocus?: () => void;
}) {
  return (
    <select
      className={inputCls}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      onFocus={onFocus}
    >
      {allowBlank && <option value="">—</option>}
      {options.map((o) => (
        <option key={o.code} value={o.code}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

// ---------------------------------------------------------------------------
// Combo — one type-ahead for every long list. Substring match on code and
// label; arrows + Enter select; Esc closes. When `onAddNew` is given and the
// typed text matches nothing exactly, the last row offers to add it — the
// party picker's inline-add path.
// ---------------------------------------------------------------------------
function Combo({
  value,
  display,
  onChange,
  options,
  placeholder,
  onFocus,
  onAddNew,
  inputRef,
}: {
  value: string;
  display: string; // label shown when not searching
  onChange: (code: string) => void;
  options: { code: string; label: string; sub?: string }[];
  placeholder?: string;
  onFocus?: () => void;
  onAddNew?: (typed: string) => void;
  inputRef?: React.RefObject<HTMLInputElement | null>;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [hi, setHi] = useState(0);

  const q = text.trim().toLowerCase();
  const matches = q
    ? options.filter(
        (o) =>
          o.code.toLowerCase().includes(q) ||
          o.label.toLowerCase().includes(q),
      )
    : options;
  const shown = matches.slice(0, 12);
  const exact = options.some(
    (o) => o.label.toLowerCase() === q || o.code.toLowerCase() === q,
  );
  const showAdd = !!onAddNew && q.length > 0 && !exact;
  const rows = shown.length + (showAdd ? 1 : 0);

  function pick(i: number) {
    if (i < shown.length) {
      onChange(shown[i].code);
      setText("");
      setOpen(false);
    } else if (showAdd) {
      setOpen(false);
      onAddNew!(text.trim());
      setText("");
    }
  }

  return (
    <div className="relative">
      <input
        ref={inputRef}
        className={inputCls}
        value={open ? text : display}
        placeholder={placeholder}
        onFocus={() => {
          setOpen(true);
          setText("");
          setHi(0);
          onFocus?.();
        }}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        onChange={(e) => {
          setText(e.target.value);
          setHi(0);
          if (!open) setOpen(true);
        }}
        onKeyDown={(e) => {
          if (!open) return;
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setHi((h) => Math.min(h + 1, rows - 1));
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            setHi((h) => Math.max(h - 1, 0));
          } else if (e.key === "Enter") {
            e.preventDefault();
            if (rows > 0) pick(hi);
          } else if (e.key === "Escape") {
            setOpen(false);
          }
        }}
      />
      {open && rows > 0 && (
        <ul className="absolute z-50 mt-1 w-full max-h-72 overflow-auto rounded-md border border-input bg-background shadow-lg text-base">
          {shown.map((o, i) => (
            <li
              key={o.code}
              className={
                "px-2 py-1 cursor-pointer " +
                (i === hi ? "bg-accent text-accent-foreground" : "")
              }
              onMouseDown={(e) => {
                e.preventDefault();
                pick(i);
              }}
              onMouseEnter={() => setHi(i)}
            >
              {o.label}
              {o.sub && (
                <span className="text-muted-foreground"> · {o.sub}</span>
              )}
            </li>
          ))}
          {showAdd && (
            <li
              className={
                "px-2 py-1 cursor-pointer border-t border-input " +
                (hi === shown.length
                  ? "bg-accent text-accent-foreground"
                  : "text-muted-foreground")
              }
              onMouseDown={(e) => {
                e.preventDefault();
                pick(shown.length);
              }}
              onMouseEnter={() => setHi(shown.length)}
            >
              + Add “{text.trim()}” as a new party
            </li>
          )}
        </ul>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// AddPartyPanel — inline, not a modal, not a page. Name prefilled from what
// she typed; code derived and collision-checked live against the loaded list
// (fn_party_upsert overwrites on collision by design — the screen owns this
// question). On a clash: use the existing party, or take the auto-bumped
// code. Mobile optional (decision C3). Parent state arrives as props so this
// component can live at module level and keep focus while typing.
// ---------------------------------------------------------------------------
function AddPartyPanel({
  typed,
  partyByCode,
  busy,
  err,
  onSave,
  onUseExisting,
  onCancel,
}: {
  typed: string;
  partyByCode: Map<string, PartyRow>;
  busy: boolean;
  err: string | null;
  onSave: (code: string, name: string, kind: PartyKind, mobile: string) => void;
  onUseExisting: (code: string) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(typed);
  const [code, setCode] = useState(deriveCode(typed));
  const [kind, setKind] = useState<PartyKind>("SUPPLIER");
  const [mobile, setMobile] = useState("");

  const clash = partyByCode.get(code.trim().toUpperCase()) ?? null;
  const codeOk = code.trim().length > 0 && !clash;
  const bumped = bumpCode(deriveCode(name), (c) =>
    partyByCode.has(c.toUpperCase()),
  );

  return (
    <div className="border border-input rounded-lg p-3 bg-muted/50 mt-2 mb-4 text-base">
      <div className="font-medium mb-2">New party</div>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3 items-end">
        <div>
          <label className={labelCls}>Name</label>
          <input
            className={inputCls}
            value={name}
            autoFocus
            onChange={(e) => {
              setName(e.target.value);
              setCode(deriveCode(e.target.value));
            }}
          />
        </div>
        <div>
          <label className={labelCls}>Code (stable, never renamed)</label>
          <input
            className={inputCls + (clash ? " border-red-500" : "")}
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
          />
        </div>
        <div>
          <label className={labelCls}>Kind</label>
          <select
            className={inputCls}
            value={kind}
            onChange={(e) => setKind(e.target.value as PartyKind)}
          >
            <option value="SUPPLIER">SUPPLIER</option>
            <option value="CUSTOMER">CUSTOMER</option>
            <option value="BOTH">BOTH</option>
          </select>
        </div>
        <div>
          <label className={labelCls}>Mobile (optional)</label>
          <input
            className={inputCls}
            value={mobile}
            onChange={(e) => setMobile(e.target.value)}
          />
        </div>
      </div>

      {clash && (
        <div className="mt-2 text-amber-700 dark:text-amber-400">
          Code <strong>{clash.party_code}</strong> already belongs to “
          {clash.name}”.{" "}
          <button className="underline" onClick={() => onUseExisting(clash.party_code)}>
            Use the existing party
          </button>{" "}
          ·{" "}
          <button className="underline" onClick={() => setCode(bumped)}>
            Create new as “{bumped}”
          </button>
        </div>
      )}

      {err && <div className="mt-2 text-red-700 dark:text-red-400">{err}</div>}

      <div className="mt-3 flex gap-2">
        <button
          className="bg-primary text-primary-foreground rounded px-3 py-1.5 disabled:opacity-50"
          disabled={!codeOk || !name.trim() || busy}
          onClick={() => onSave(code.trim(), name.trim(), kind, mobile)}
        >
          {busy ? "Saving…" : "Save party"}
        </button>
        <button className="border border-input rounded px-3 py-1.5" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------

export default function VoucherEntry({
  masters,
  parties: initialParties,
  today,
  vagueActivities,
  narrationMin,
  vagueNarrationMin,
  sampleMode,
  initialCashBalance,
  oneTimeMax,
  lineAmountWarn,
  partyWarnMult,
  partyStats,
  userEmail,
}: Props) {
  // ---- header: defaults for every line, set once per paper slip ----------
  const [dateText, setDateText] = useState(formatDMY(today));
  const [mode, setMode] = useState(
    masters["MODE"]?.find((m) => m.code === "CASH")?.code ??
      masters["MODE"]?.[0]?.code ??
      "",
  );
  // Vestigial after the 19-07 evening change: the free-text header payee is
  // gone (payee = picked party, or ONE TIME). Kept as an always-empty
  // fallback in eff() so old drafts do not break; remove in a later tidy.
  const [headerPayee, setHeaderPayee] = useState("");
  const [periodFromText, setPeriodFromText] = useState("");
  const [periodToText, setPeriodToText] = useState("");
  const [headerParty, setHeaderParty] = useState("");
  // The one-time toggle (owner's design, 19-07): NOT a party row — a party
  // record invites duplicates and a meaningless balance. A checked toggle
  // sends the literal payee 'ONE TIME' with no party; the name goes in the
  // narration, and file 09 enforces exactly that.
  const [oneTime, setOneTime] = useState(false);

  // ---- lines: committed ones plus the one being edited --------------------
  const [lines, setLines] = useState<EditLine[]>([]);
  const [draft, setDraft] = useState<EditLine>(emptyLine());
  const [draftMsg, setDraftMsg] = useState<string | null>(null);

  // Which committed line the editor is currently holding, or null when the
  // editor is composing a NEW line. Editing an unsaved line is free: nothing
  // exists in the book yet, so §13's immutability has not started. Only after
  // save does a line become a thing that can be corrected but never altered.
  const [editingIndex, setEditingIndex] = useState<number | null>(null);
  // The line as it was when editing began, so Cancel can put it back.
  const [editBackup, setEditBackup] = useState<EditLine | null>(null);

  // ---- parties are state now: inline add appends without a refresh --------
  const [parties, setParties] = useState<PartyRow[]>(initialParties);

  // ---- save machinery -----------------------------------------------------
  const [saving, setSaving] = useState(false);
  const [armed, setArmed] = useState(false); // amber two-click confirm
  const [lastResult, setLastResult] = useState<SaveResult | null>(null);
  const [session, setSession] = useState<SavedVoucher[]>([]);
  const [cash, setCash] = useState<number | null>(initialCashBalance);

  // ---- inline party add panel ---------------------------------------------
  const [addingParty, setAddingParty] = useState<{ typed: string } | null>(
    null,
  );
  const [partyBusy, setPartyBusy] = useState(false);
  const [partyErr, setPartyErr] = useState<string | null>(null);

  // ---- help strip: which field has focus ----------------------------------
  const [focusKey, setFocusKey] = useState<string | null>(null);

  // Has the person typed in Amount themselves? Until they do, Amount is
  // filled from the arithmetic they were doing on paper anyway (labours x
  // rate, or quantity x rate). The moment they overtype it, we stop
  // interfering — the paper slip is the authority, not our multiplication.
  const [amountTouched, setAmountTouched] = useState(false);

  const amountRef = useRef<HTMLInputElement>(null);
  const partyInputRef = useRef<HTMLInputElement>(null);

  // ---- derived ------------------------------------------------------------
  const dateISO = parseDMY(dateText, today);
  const periodFromISO = periodFromText ? parseDMY(periodFromText, today) : null;
  const periodToISO = periodToText ? parseDMY(periodToText, today) : null;

  const modeRow = masters["MODE"]?.find((m) => m.code === mode);
  const modeKind = modeRow?.mode_kind ?? null;
  // File 08: BANK-kind refuses without a party; CREDIT has needed one since
  // day one. Same field, same rule shape.
  const partyRequired = modeKind === "BANK" || modeKind === "CREDIT";

  const activityByCode = useMemo(() => {
    const m = new Map<string, MasterRow>();
    for (const a of masters["ACTIVITY"] ?? []) m.set(a.code, a);
    return m;
  }, [masters]);

  const partyByCode = useMemo(() => {
    const m = new Map<string, PartyRow>();
    for (const p of parties) m.set(p.party_code.toUpperCase(), p);
    return m;
  }, [parties]);

  // Blocks belonging to the chosen farm — and whether the farm HAS any,
  // which is what switches the BLOCK NOT CHOSEN flag on (file 08, A6).
  const blocksForFarm = (farm: string) =>
    (masters["BLOCK"] ?? []).filter((b) => b.parent_farm === farm);
  const farmHasBlocks = (farm: string) => blocksForFarm(farm).length > 0;

  const num = (s: string): number | null => {
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : null;
  };

  // ---- rate: what is this rate PER? ---------------------------------------
  // The workbook shows three habits in one field:
  //   "12 women labours @ Rs.220 per head"      -> rate is per MANDAY
  //   "@ Rs.20 per tree, total 956 trees"       -> rate is per TREE (qty unit)
  //   "20 labours ... 956 trees"                -> mandays AND qty, day wage
  // The rule, shown to the user rather than assumed: rate belongs to mandays
  // when mandays is present, otherwise to quantity.
  function rateBasis(l: EditLine): "MANDAY" | "UNIT" | "NONE" {
    if (l.mandays.trim() !== "") return "MANDAY";
    if (l.qty.trim() !== "" || l.unit) return "UNIT";
    return "NONE";
  }

  function rateLabel(l: EditLine): string {
    const b = rateBasis(l);
    if (b === "MANDAY") return "Rate \u20b9 / labour";
    if (b === "UNIT" && l.unit) return `Rate \u20b9 / ${l.unit}`;
    return "Rate \u20b9";
  }

  /** The amount the arithmetic implies, or null when it implies nothing. */
  function impliedAmount(l: EditLine): number | null {
    const r = num(l.rate);
    if (r === null) return null;
    const b = rateBasis(l);
    if (b === "MANDAY") {
      const m = num(l.mandays);
      return m === null ? null : Math.round(m * r * 100) / 100;
    }
    if (b === "UNIT") {
      const q = num(l.qty);
      return q === null ? null : Math.round(q * r * 100) / 100;
    }
    return null;
  }

  // What the columns already hold — shown beside Narration so she stops
  // retyping the farm, crop and labour count into prose and starts writing
  // the part no column can hold. Deliberately NOT used to auto-generate the
  // narration: an independent account is the last chance to catch a wrong
  // posting, and a narration assembled from the fields can never disagree
  // with them.
  function alreadyRecorded(l: EditLine): string {
    const bits: string[] = [];
    if (l.farm) bits.push(l.farm);
    if (l.block && l.block !== "YET TO ASSIGN") bits.push(l.block);
    if (l.cost_object) bits.push(l.cost_object);
    if (l.activity) bits.push(l.activity);
    if (l.cost_nature) bits.push(l.cost_nature);
    if (l.mandays.trim()) bits.push(`${l.mandays} labours`);
    if (l.qty.trim()) bits.push(`${l.qty} ${l.unit || ""}`.trim());
    const a = num(l.amount);
    if (a !== null) bits.push(`\u20b9 ${formatINR(a)}`);
    return bits.join(" \u00b7 ");
  }

  // "Salary + Petrol + cellphone recharge" — 279 such rows in the workbook,
  // bundled because splitting in a spreadsheet meant retyping a whole row.
  // Here it is three keystrokes, so the screen says so. A nudge, never a block.
  function looksBundled(text: string): boolean {
    const t = text.trim();
    if (t.length < 8) return false;
    if (/\s\+\s/.test(t)) return true;                 // "a + b"
    if (/\b\w+\s+and\s+\w+\s+(charges|expenses|allowance|wages)\b/i.test(t))
      return true;
    return false;
  }

  // Effective (post-inheritance) values for one line — the same resolution
  // the payload applies, reused by every preview check so they cannot drift
  // from what is actually sent.
  // Effective values after inheritance and the one-time toggle. A line that
  // names its own party overrides the toggle (a muster can pay Murugan the
  // party and one stranger); otherwise a checked toggle means payee 'ONE
  // TIME' and no party, exactly what file 09 expects.
  const eff = (l: EditLine) => {
    if (oneTime && !l.party_code) {
      return { payee: "ONE TIME", party: "", costNature: l.cost_nature };
    }
    const party = l.party_code || headerParty;
    const partyName = party
      ? (partyByCode.get(party.toUpperCase())?.name ?? party)
      : "";
    return {
      payee: l.payee.trim() || partyName || headerPayee.trim(),
      party,
      costNature: l.cost_nature,
    };
  };

  const narrFloor = (activity: string, lineHasParty = false) =>
    vagueActivities.includes(activity) || (oneTime && !lineHasParty)
      ? vagueNarrationMin
      : narrationMin;

  // A draft counts as a line the moment it is complete — she typed it, she
  // means it. "Complete" = what commitDraft would accept.
  function draftProblems(d: EditLine): string[] {
    const p: string[] = [];
    if (!d.farm) p.push("farm");
    if (!d.cost_object) p.push("cost object");
    if (!d.activity) p.push("activity");
    if (!(num(d.amount) !== null && num(d.amount)! > 0)) p.push("amount");
    if (d.narration.trim().length < narrFloor(d.activity, !!d.party_code))
      p.push(`narration (min ${narrFloor(d.activity, !!d.party_code)})`);
    return p;
  }

  const draftComplete = draftProblems(draft).length === 0;
  // While a committed line is being edited, the editor's contents STAND IN for
  // that line — so the totals and the preview panel describe what will
  // actually be saved, not the stale version still drawn in the table.
  const allLines: EditLine[] =
    editingIndex !== null
      ? lines.map((l, i) => (i === editingIndex ? draft : l))
      : draftComplete
        ? [...lines, draft]
        : lines;

  const linesTotal = allLines.reduce((s, l) => s + (num(l.amount) ?? 0), 0);

  // ---------------------------------------------------------------------
  // THE PREVIEW PANEL — the screen's mirror of file 08's decision table.
  // RED mirrors the REFUSALS; AMBER mirrors the FLAGS and the warnings.
  // Everything threshold-driven comes from props (config). Advisory only:
  // the database re-derives all of it and is the judge.
  // ---------------------------------------------------------------------
  const redMsgs: string[] = [];
  const amberMsgs: string[] = [];

  if (!dateISO) redMsgs.push(`Payment date "${dateText}" is not a date.`);
  if (!periodFromISO)
    redMsgs.push(
      periodFromText
        ? `Period from "${periodFromText}" is not a date.`
        : "Period from is needed — every line inherits it.",
    );
  if (!periodToISO)
    redMsgs.push(
      periodToText
        ? `Period to "${periodToText}" is not a date.`
        : "Period to is needed — every line inherits it.",
    );
  if (periodFromISO && periodToISO && periodToISO < periodFromISO)
    redMsgs.push("Period to is before period from. A period cannot run backwards.");
  if (oneTime && modeKind === "CREDIT")
    redMsgs.push(
      "A one-time payee cannot be used on credit — there would be a debt owed to nobody. Name the party.",
    );

  allLines.forEach((l, i) => {
    const n = i + 1;
    const e = eff(l);
    const lineOneTime = e.payee === "ONE TIME";
    const floor = narrFloor(l.activity, !!l.party_code);
    const narr = l.narration.trim();

    // -- red: the DB will refuse --
    if (narr.length < floor)
      redMsgs.push(
        lineOneTime
          ? `Line ${n}: a one-time payee needs the person named in the narration — who was paid, and for what (min ${floor} characters).`
          : vagueActivities.includes(l.activity)
            ? `Line ${n}: ${l.activity} is a last resort — say what it was actually for (min ${floor} characters).`
            : `Line ${n}: narration needs at least ${floor} characters.`,
      );
    if (!e.costNature)
      redMsgs.push(
        `Line ${n}: cost nature is needed — labour, material, machine hire, transport, contract or other.`,
      );
    if (partyRequired && !e.party)
      redMsgs.push(
        `Line ${n}: a ${modeKind === "BANK" ? "bank" : "credit"} payment needs a party — pick one, or add it on the spot.`,
      );

    // -- amber: it will save, and be flagged / warned --
    if (vagueActivities.includes(l.activity) && narr.length >= floor)
      amberMsgs.push(
        `Line ${n}: ${l.activity} will be flagged for the review queue.`,
      );
    if (modeKind === "CASH" && !e.payee && !e.party)
      amberMsgs.push(`Line ${n}: cash with nobody named — will be flagged (NO PAYEE).`);
    if (farmHasBlocks(l.farm) && (l.block || "YET TO ASSIGN") === "YET TO ASSIGN")
      amberMsgs.push(
        `Line ${n}: ${l.farm} has blocks in the master and none is chosen — will be flagged.`,
      );
    const act = activityByCode.get(l.activity);
    if (act?.required_unit && num(l.qty) === null)
      amberMsgs.push(
        `Line ${n}: ${l.activity} expects ${act.required_unit} and none is recorded — will be flagged.`,
      );
    const md = num(l.mandays);
    const rt = num(l.rate);
    const qt = num(l.qty);
    const amt = num(l.amount);
    if (md !== null && rt !== null && amt !== null && Math.abs(md * rt - amt) > 0.005)
      amberMsgs.push(
        `Line ${n}: amount ₹ ${formatINR(amt)} ≠ labours × rate ₹ ${formatINR(md * rt)}.`,
      );
    // file 09 mirror: piece-rate arithmetic — mandays blank, qty and rate present
    if (md === null && qt !== null && rt !== null && amt !== null &&
        Math.abs(qt * rt - amt) > 0.005)
      amberMsgs.push(
        `Line ${n}: amount ₹ ${formatINR(amt)} ≠ quantity × rate ₹ ${formatINR(qt * rt)}.`,
      );
    // file 09 mirror: one-time flag + threshold
    if (lineOneTime) {
      amberMsgs.push(`Line ${n}: one-time payee — will be flagged for the review queue.`);
      if (amt !== null && amt > oneTimeMax)
        amberMsgs.push(
          `Line ${n}: ₹ ${formatINR(amt)} to a one-time payee (limit ₹ ${formatINR(oneTimeMax)}) — a payment this size probably deserves a named party.`,
        );
    }
    // file 09 mirror: flat large-amount check — the extra-zero catcher
    if (amt !== null && amt > lineAmountWarn)
      amberMsgs.push(
        `Line ${n}: ₹ ${formatINR(amt)} is unusually large — ${amountInWords(amt)}. Check the figure.`,
      );
    // file 09 mirror: the party's own payment pattern. Silent under 3
    // payments — no pattern to compare against. Self-calibrating.
    if (e.party && amt !== null) {
      const st = partyStats[e.party];
      if (st && st.times_paid >= 3 && amt > st.max_paid * partyWarnMult) {
        const pname = partyByCode.get(e.party.toUpperCase())?.name ?? e.party;
        amberMsgs.push(
          `Line ${n}: ₹ ${formatINR(amt)} to ${pname} — their largest ever payment is ₹ ${formatINR(st.max_paid)} across ${st.times_paid} payments. Check the figure.`,
        );
      }
    }
  });

  // Duplicate hint from THIS SITTING — free, no query; the DB runs the same
  // check against the whole book after the fact.
  if (dateISO && allLines.length > 0) {
    const firstEff = eff(allLines[0]);
    const dup = session.find(
      (s) =>
        s.dateISO === dateISO &&
        s.payee === firstEff.payee &&
        Math.abs(s.total - linesTotal) < 0.005,
    );
    if (dup)
      amberMsgs.push(
        `Looks like ${dup.voucher_no}, saved this sitting: same date, payee and total.`,
      );
  }

  const canSave =
    !saving &&
    allLines.length > 0 &&
    redMsgs.length === 0 &&
    // An edit in progress must be finished (or cancelled) first. Saving
    // half-edited would quietly write the incomplete version.
    (editingIndex === null || draftComplete);

  // Which committed line did the DB refuse? ("Line 3: …" in its message.)
  const refusedLine =
    lastResult && !lastResult.ok
      ? Number(/^Line (\d+):/.exec(lastResult.message)?.[1] ?? 0)
      : 0;

  // ---- line handling -------------------------------------------------------

  function setD<K extends keyof EditLine>(k: K, v: EditLine[K]) {
    setDraft((d) => {
      const next = { ...d, [k]: v };

      // Choosing an activity preselects the unit it expects (masters own this
      // — WEEDICIDE SPRAY expects ACRE, FENCE VINE REMOVAL expects FEET).
      // Overridable; only fills a blank, never overwrites a choice.
      if (k === "activity") {
        const req = activityByCode.get(String(v))?.required_unit;
        if (req && !next.unit) next.unit = req;
      }

      // Amount follows the arithmetic until the person overtypes it.
      if (!amountTouched && k !== "amount") {
        const implied = impliedAmount(next);
        if (implied !== null) next.amount = String(implied);
      }
      return next;
    });
    if (k === "amount") setAmountTouched(true);
    setDraftMsg(null);
    setArmed(false); // any edit disarms a pending confirm
  }

  function commitDraft(): boolean {
    const probs = draftProblems(draft);
    if (probs.length) {
      setDraftMsg(`Still needed: ${probs.join(", ")}.`);
      return false;
    }

    if (editingIndex !== null) {
      // Updating a line already in the list: it goes back in ITS OWN place,
      // never to the end. Line order is the order on the paper slip.
      const at = editingIndex;
      setLines((ls) => ls.map((l, i) => (i === at ? draft : l)));
      setEditingIndex(null);
      setEditBackup(null);
      // After an update the editor returns to composing a new line, seeded
      // from the line just updated — the same carry-forward as any new line.
      setDraft({ ...draft, qty: "", mandays: "", amount: "" });
    } else {
      setLines((ls) => [...ls, draft]);
      // §5: the next line opens as a copy of this one. Amount, qty and mandays
      // clear (they belong to the line); NARRATION CARRIES FORWARD
      // (handover §2.3) — a twenty-line muster is one narration, not twenty.
      setDraft({ ...draft, qty: "", mandays: "", amount: "" });
    }

    setAmountTouched(false);
    setDraftMsg(null);
    setArmed(false);
    setTimeout(() => amountRef.current?.focus(), 0);
    return true;
  }

  /** Pull a committed line back into the editor. Nothing is lost: the row
   *  stays visible in the table, marked as the one being edited. */
  function editLine(i: number) {
    if (editingIndex !== null && editBackup) {
      // Already editing something else — put that one back first, so a stray
      // click never silently discards half an edit.
      const prev = editingIndex;
      const backup = editBackup;
      setLines((ls) => ls.map((l, idx) => (idx === prev ? backup : l)));
    }
    setEditBackup(lines[i]);
    setEditingIndex(i);
    setDraft(lines[i]);
    setAmountTouched(true); // an existing line's amount is already decided
    setDraftMsg(null);
    setArmed(false);
    setTimeout(() => amountRef.current?.focus(), 0);
  }

  /** Abandon the edit and restore the line exactly as it was. */
  function cancelEdit() {
    if (editingIndex === null) return;
    const at = editingIndex;
    const backup = editBackup;
    if (backup) setLines((ls) => ls.map((l, i) => (i === at ? backup : l)));
    setEditingIndex(null);
    setEditBackup(null);
    setDraft({ ...emptyLine(), cost_nature: draft.cost_nature });
    setAmountTouched(false);
    setDraftMsg(null);
    setArmed(false);
  }

  function removeLine(i: number) {
    // Removing an UNSAVED line is allowed — nothing exists yet; immutability
    // (§13) begins at save, not at typing.
    if (editingIndex === i) {
      setEditingIndex(null);
      setEditBackup(null);
      setDraft({ ...emptyLine(), cost_nature: draft.cost_nature });
    } else if (editingIndex !== null && editingIndex > i) {
      setEditingIndex(editingIndex - 1); // indices shift when a row leaves
    }
    setLines((ls) => ls.filter((_, idx) => idx !== i));
    setArmed(false);
  }

  // ---- payload -------------------------------------------------------------

  function buildPayload(): VoucherLine[] {
    return allLines.map((l) => {
      const e = eff(l);
      return {
        payment_date: dateISO!,
        period_from: periodFromISO,
        period_to: periodToISO,
        entity: l.entity,
        farm: l.farm,
        block: l.block || null,
        cost_object: l.cost_object,
        activity: l.activity,
        capex_flag: l.capex_flag,
        cost_nature: e.costNature || null,
        qty: num(l.qty),
        unit: l.unit || null,
        mandays: num(l.mandays),
        rate: num(l.rate),
        paid_out_dr: num(l.amount)!,
        mode,
        party_code: e.party || null,
        payee: e.payee || null,
        narration: l.narration.trim() || null,
      };
    });
  }

  async function onSave() {
    if (!canSave) return;
    // Amber = informed consent: first click arms, second click sends.
    if (amberMsgs.length > 0 && !armed) {
      setArmed(true);
      return;
    }
    setArmed(false);
    setLastResult(null);
    setSaving(true);
    const result = await saveVoucher(buildPayload());
    setSaving(false);
    setLastResult(result);

    if (result.ok) {
      if (result.cash_balance !== null) setCash(result.cash_balance);
      const firstEff = eff(allLines[0]);
      setSession((ss) => [
        ...ss,
        {
          voucher_no: result.voucher_no,
          payee: firstEff.payee,
          total: linesTotal,
          dateISO: dateISO!,
        },
      ]);
      // §5 batch working: date, mode AND cost nature survive into the next
      // voucher — she is working a stack from one day, one pocket, and
      // usually one kind of spending. Lines, payee, party and periods clear.
      setLines([]);
      setEditingIndex(null);
      setEditBackup(null);
      // Cost nature survives with the date and mode: a stack of slips from one
      // day is usually one kind of spending too. Everything else on the line
      // clears.
      setDraft({ ...emptyLine(), cost_nature: draft.cost_nature });
      setAmountTouched(false);
      setHeaderPayee("");
      setHeaderParty("");
      setOneTime(false);
      setPeriodFromText("");
      setPeriodToText("");
    }
  }

  // ---- inline party add ----------------------------------------------------

  function openAddParty(typed: string) {
    setPartyErr(null);
    setAddingParty({ typed });
  }

  async function submitAddParty(
    code: string,
    name: string,
    kind: PartyKind,
    mobile: string,
  ) {
    setPartyBusy(true);
    setPartyErr(null);
    const res = await createParty(code, name, kind, mobile || null);
    setPartyBusy(false);
    if (!res.ok) {
      setPartyErr(res.message);
      return;
    }
    setParties((ps) =>
      [...ps, { ...res.party }].sort((a, b) => a.name.localeCompare(b.name)),
    );
    setHeaderParty(res.party.party_code);
    setAddingParty(null);
    setTimeout(() => partyInputRef.current?.focus(), 0);
  }

  // ---- help strip content --------------------------------------------------
  // Layer 1 (static): how the field is used — screen behaviour, so it
  // honestly lives here. Layer 2 (data): the chosen master value's notes,
  // appended where one exists — that part improves as masters admin fills
  // notes in, with no screen change.
  //
  // The strip sits directly under the entry card (not pinned to the bottom of
  // the window) and names the field in bold. Both changes are deliberate: a
  // hint 600px from the cursor in the shape of a page footer is invisible,
  // however correct its text. Named + near + tinted reads as an answer to the
  // question the cursor just asked.

  // Field name for the bold prefix, keyed the same as helpFor.
  const FIELD_LABEL: Record<string, string> = {
    date: "Payment date",
    mode: "Mode",
    onetime: "One-time payee",
    pfrom: "Period from",
    pto: "Period to",
    party: "Payee / party",
    entity: "Entity",
    farm: "Farm",
    block: "Block",
    costobject: "Cost object",
    activity: "Activity",
    capex: "Capex",
    qty: "Qty",
    unit: "Unit",
    mandays: "Mandays",
    rate: "Rate",
    amount: "Amount",
    narration: "Narration",

    lineparty: "Party (this line)",
    linecostnature: "Cost nature",
  };

  function helpFor(key: string | null): string {
    switch (key) {
      case "date":
        return 'Payment date, DD/MM/YYYY — or just "19" for the 19th of this month, "19/6", "1907". The line below shows how it will be read.';
      case "mode": {
        const base =
          "How the money moved. Bank and credit modes need a party.";
        return modeRow?.notes ? `${base}  ·  ${mode}: ${modeRow.notes}` : base;
      }

      case "pfrom":
        return "First day the work covers. Required — typed once here, every line inherits it.";
      case "pto":
        return "Last day the work covers. Required. Same-day work: same as period from.";
      case "party":
        return "Type to search by name or code — the regulars are one keystroke. Nothing matches? The last row adds what you typed as a new party, without leaving the voucher. Someone you will never pay again? Tick one-time instead.";
      case "onetime":
        return `A person you will not pay again — the blade sharpener, the auto driver. Their NAME goes in the narration (${vagueNarrationMin}+ characters), the line is flagged for review, and above ₹ ${formatINR(oneTimeMax)} you will be nudged to name a real party. Not available on credit.`;
      case "entity":
        return "BUSINESS = the farms. PERSONAL = the household. FUNDING = owner money moving in or out.";
      case "farm":
        return "Which farm this line belongs to.";
      case "block":
        return "Block within the farm, where the survey has named them. Leaving YET TO ASSIGN on a farm that has blocks saves, but is flagged for review.";
      case "costobject":
        return "What the money was FOR — the thing that carries the cost (a crop, LAND, an asset). Type to search.";
      case "activity": {
        const a = activityByCode.get(draft.activity);
        let base = "What was done. Type to search.";
        if (a?.required_unit) base += `  ·  ${a.code} expects ${a.required_unit}.`;
        if (a?.notes) base += `  ·  ${a.notes}`;
        if (vagueActivities.includes(draft.activity))
          base += `  ·  Vague head: narration of ${vagueNarrationMin}+ characters required, and the line is flagged.`;
        return base;
      }
      case "capex":
        return "RECURRING = an expense of the period. CAPEX = builds or improves an asset.";
      case "qty": {
        const a = activityByCode.get(draft.activity);
        return a?.required_unit
          ? `How much was covered — ${a.code} is measured in ${a.required_unit}. This is the denominator every ₹-per-unit standard depends on. Blank saves, but is flagged.`
          : "How much was covered — acres, trees, feet, bags. Optional where the activity has no standard unit, but fill it whenever you can: no quantity means no cost-per-unit later.";
      }
      case "unit":
        return "What the quantity is counted in. Fills itself from the activity where the master says so — change it if this line is different.";
      case "mandays":
        return "How many labours, the way you write it on the slip. Half days are fine — 6.5. Leave blank for piece work paid per tree or per foot.";
      case "rate": {
        const b = rateBasis(draft);
        if (b === "MANDAY")
          return "₹ per labour per day. Amount fills itself as labours × rate — overtype it if the slip says otherwise.";
        if (b === "UNIT" && draft.unit)
          return `₹ per ${draft.unit} — piece work. Amount fills itself as how-much-covered × rate.`;
        return "₹ per labour if you filled labours, otherwise ₹ per unit of what was covered.";
      }
      case "amount":
        return "₹ paid on this line. Enter commits the line and opens the next.";
      case "narration": {
        const floor = narrFloor(draft.activity);
        return `Say what the boxes cannot — which part of the block, why it was needed, the chemical and dose, anything unusual. At least ${floor} characters. Do not repeat the farm, crop or labour count: those are already recorded. Copies into the next line.`;
      }
      case "lineparty":
        return "This line's payee, when it differs from the header's — a muster paying Murugan and Selvi is one voucher, two lines, two parties. Overrides the one-time toggle for this line.";
      case "linecostnature": {
        const cn = (masters["COST_NATURE"] ?? []).find(
          (c) => c.code === draft.cost_nature,
        );
        const base =
          "How the money was spent: labour, material, machine hire… Required. Carries into the next line, so a muster is set once. One job using two natures → two lines.";
        return cn?.notes ? `${base}  ·  ${cn.code}: ${cn.notes}` : base;
      }
      default:
        return "Tab moves forward · Enter adds the line · Esc clears it (or cancels an edit) · ✎ on a line above reopens it";
    }
  }

  // ---- render -------------------------------------------------------------

  const dateEcho = (text: string, iso: string | null) => (
    <div className="text-sm mt-0.5 text-muted-foreground h-5">
      {text && (iso ? formatDMY(iso) : "not a date")}
    </div>
  );

  return (
    <main className="max-w-6xl mx-auto p-4 pb-24">
      {/* ---------------- title row: who, and cash in hand ---------------- */}
      <header className="flex items-baseline justify-between mb-4 gap-4 flex-wrap">
        <h1 className="text-2xl font-semibold">Voucher entry — payment</h1>
        <div className="flex items-baseline gap-4">
          <span className="text-base tabular-nums">
            Cash in hand:{" "}
            <strong>{cash === null ? "—" : `₹ ${formatINR(cash)}`}</strong>
            {sampleMode && (
              <span className="text-sm text-muted-foreground"> (SAMPLE)</span>
            )}
          </span>
          <span className="text-sm text-muted-foreground">{userEmail}</span>
        </div>
      </header>

      {/* ---------------- header: once per paper slip ---------------- */}
      <section className="grid grid-cols-2 md:grid-cols-6 gap-3 border border-input rounded-lg p-3 bg-muted/50 mb-4">
        <div>
          <label className={labelCls}>Payment date</label>
          <input
            className={inputCls + (dateISO ? "" : " border-red-500")}
            value={dateText}
            onChange={(e) => {
              setDateText(e.target.value);
              setArmed(false);
            }}
            onFocus={() => setFocusKey("date")}
            placeholder="DD/MM/YYYY"
          />
          {dateEcho(dateText, dateISO)}
        </div>
        <div>
          <label className={labelCls}>Mode</label>
          <Sel
            value={mode}
            onChange={(v) => {
              setMode(v);
              setArmed(false);
            }}
            options={masters["MODE"] ?? []}
            onFocus={() => setFocusKey("mode")}
          />
        </div>
        <div>
          <label className={labelCls}>
            Payee / party{partyRequired ? " (required)" : ""}
          </label>
          <Combo
            value={headerParty}
            display={
              oneTime
                ? "— one-time payee —"
                : headerParty
                  ? (partyByCode.get(headerParty.toUpperCase())?.name ??
                    headerParty)
                  : ""
            }
            onChange={(v) => {
              setHeaderParty(v);
              setOneTime(false);
              setArmed(false);
            }}
            options={
              oneTime
                ? []
                : parties.map((p) => ({
                    code: p.party_code,
                    label: p.name,
                    sub: p.party_code,
                  }))
            }
            placeholder="type name — pick, or add new…"
            onFocus={() => setFocusKey("party")}
            onAddNew={openAddParty}
            inputRef={partyInputRef}
          />
          {/* The one-off escape hatch. A checkbox, NOT a list entry: a party
              row called One Time invites duplicates and a balance owed to
              nobody. Unavailable on credit — you cannot owe money to nobody. */}
          <label
            className={
              "flex items-center gap-1.5 mt-1 text-sm " +
              (modeKind === "CREDIT"
                ? "text-muted-foreground/50 cursor-not-allowed"
                : "text-muted-foreground cursor-pointer")
            }
            title={
              modeKind === "CREDIT"
                ? "Not on credit — a debt cannot be owed to nobody"
                : "A person you will not pay again. Their name goes in the narration."
            }
          >
            <input
              type="checkbox"
              checked={oneTime}
              disabled={modeKind === "CREDIT"}
              onChange={(e) => {
                setOneTime(e.target.checked);
                if (e.target.checked) {
                  setHeaderParty("");
                  setHeaderPayee("");
                }
                setArmed(false);
                setFocusKey("onetime");
              }}
            />
            One-time payee
          </label>
        </div>
        <div>
          <label className={labelCls}>Period from (required)</label>
          <input
            className={inputCls + (periodFromISO ? "" : " border-red-500")}
            value={periodFromText}
            onChange={(e) => {
              setPeriodFromText(e.target.value);
              setArmed(false);
            }}
            onFocus={() => setFocusKey("pfrom")}
            placeholder="DD/MM/YYYY"
          />
          {dateEcho(periodFromText, periodFromISO)}
        </div>
        <div>
          <label className={labelCls}>Period to (required)</label>
          <input
            className={inputCls + (periodToISO ? "" : " border-red-500")}
            value={periodToText}
            onChange={(e) => {
              setPeriodToText(e.target.value);
              setArmed(false);
            }}
            onFocus={() => setFocusKey("pto")}
            placeholder="DD/MM/YYYY"
          />
          {dateEcho(periodToText, periodToISO)}
        </div>
      </section>

      {addingParty && (
        <AddPartyPanel
          typed={addingParty.typed}
          partyByCode={partyByCode}
          busy={partyBusy}
          err={partyErr}
          onSave={submitAddParty}
          onUseExisting={(code) => {
            setHeaderParty(code);
            setAddingParty(null);
            setTimeout(() => partyInputRef.current?.focus(), 0);
          }}
          onCancel={() => {
            setAddingParty(null);
            setPartyErr(null);
          }}
        />
      )}

      {/* ---------------- lines already added to this voucher --------------
          Its own bordered card, clearly a DIFFERENT object from the editor
          below: these are settled, that one is in progress. Rows can be
          edited or removed freely — nothing is in the book until Save. --- */}
      {lines.length > 0 && (
        <section className="border border-input rounded-lg p-3 mb-4">
          <div className="text-sm text-muted-foreground mb-2">
            Lines in this voucher
          </div>
          <table className="w-full text-base">
            <thead>
              <tr className="text-left text-sm text-muted-foreground">
                <th className="py-1 w-8">#</th>
                <th>Entity</th>
                <th>Farm</th>
                <th>Cost object</th>
                <th>Activity</th>
                <th>Nature</th>
                <th className="text-right">Qty</th>
                <th className="text-right">Amount ₹</th>
                <th>Narration</th>
                <th className="w-20" />
              </tr>
            </thead>
            <tbody>
              {lines.map((l, i) => {
                // The row being edited shows the EDITOR's live values, so the
                // table and the fields never disagree while typing.
                const shown = editingIndex === i ? draft : l;
                const isEditing = editingIndex === i;
                return (
                  <tr
                    key={i}
                    className={
                      "border-t border-input " +
                      (isEditing
                        ? "bg-primary/10 ring-1 ring-primary "
                        : refusedLine === i + 1
                          ? "bg-red-50 dark:bg-red-950/40 ring-1 ring-red-400 "
                          : "")
                    }
                  >
                    <td className="py-1.5">{i + 1}</td>
                    <td>{shown.entity}</td>
                    <td>{shown.farm}</td>
                    <td>{shown.cost_object}</td>
                    <td>
                      {activityByCode.get(shown.activity)?.label ??
                        shown.activity}
                    </td>
                    <td>{shown.cost_nature || "—"}</td>
                    <td className="text-right tabular-nums">{shown.qty}</td>
                    <td className="text-right tabular-nums">
                      {formatINR(num(shown.amount) ?? 0)}
                    </td>
                    <td
                      className="max-w-[16rem] truncate"
                      title={shown.narration}
                    >
                      {shown.narration}
                    </td>
                    <td className="text-right whitespace-nowrap">
                      {isEditing ? (
                        <span className="text-sm text-primary font-medium">
                          editing…
                        </span>
                      ) : (
                        <>
                          <button
                            className="text-sm text-muted-foreground hover:text-primary px-1"
                            onClick={() => editLine(i)}
                            title="Edit this line"
                          >
                            ✎
                          </button>
                          <button
                            className="text-sm text-muted-foreground hover:text-red-600 px-1"
                            onClick={() => removeLine(i)}
                            title="Remove this line"
                          >
                            ✕
                          </button>
                        </>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      )}

      {/* ---------------- the editor: a new line, or one being changed -----
          Visually separate from the list above — thicker top rule, its own
          heading, a tinted band while editing. The two were previously one
          undifferentiated wall of fields, which is why a filled line and an
          empty one read the same. ------------------------------------- */}
      <section
        className={
          "border rounded-lg p-3 mb-4 " +
          (editingIndex !== null
            ? "border-primary bg-primary/5"
            : "border-input")
        }
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            if (editingIndex !== null) {
              cancelEdit(); // put the line back exactly as it was
            } else {
              setDraft({ ...emptyLine(), narration: draft.narration });
              setAmountTouched(false);
              setDraftMsg(null);
            }
          }
        }}
      >
        <div className="flex items-center justify-between mb-3">
          <div className="text-sm font-medium">
            {editingIndex !== null ? (
              <span className="text-primary">
                Editing line {editingIndex + 1}
              </span>
            ) : lines.length > 0 ? (
              <span className="text-muted-foreground">
                New line {lines.length + 1}
              </span>
            ) : (
              <span className="text-muted-foreground">First line</span>
            )}
          </div>
          {editingIndex !== null && (
            <button
              className="text-sm border border-input rounded px-2 py-1"
              onClick={cancelEdit}
              title="Escape"
            >
              Cancel edit ⎋
            </button>
          )}
        </div>

        {/* ============================================================
            THE LINE, IN THE ORDER IT IS WRITTEN.

            The workbook's narrations are remarkably consistent:
              "30 labours Manuring work North thottam Young coconut trees
               South side 110 Nos"
            i.e. how many people -> what work -> where -> on what, how many.
            The old layout asked for Entity and Capex first (near-constant,
            so trained the eye to tab past) and Mandays almost last. These
            five bands follow the writing order instead, and name the
            question each answers.
            ============================================================ */}

        {/* -------- WHERE -------- */}
        <FieldBand title="Where">
          <div className="md:col-span-2">
            <label className={labelCls}>Farm</label>
            <Sel
              value={draft.farm}
              onChange={(v) => {
                setD("farm", v);
                setD("block", "YET TO ASSIGN");
              }}
              allowBlank
              options={masters["FARM"] ?? []}
              onFocus={() => setFocusKey("farm")}
            />
          </div>
          <div className="md:col-span-2">
            <label className={labelCls}>
              Block{" "}
              {draft.farm && farmHasBlocks(draft.farm) && (
                <span className="text-amber-600 dark:text-amber-400">
                  (this farm has blocks)
                </span>
              )}
            </label>
            <Sel
              value={draft.block}
              onChange={(v) => setD("block", v)}
              options={[
                { code: "YET TO ASSIGN", label: "YET TO ASSIGN" },
                ...blocksForFarm(draft.farm).map((b) => ({
                  code: b.code,
                  label: b.label,
                })),
              ]}
              onFocus={() => setFocusKey("block")}
            />
          </div>
          {/* Entity and Capex are BUSINESS/RECURRING on almost every line.
              Kept visible and changeable, but last in the band so they do
              not stand between the person and the work. */}
          <div>
            <label className={labelCls}>Entity</label>
            <Sel
              value={draft.entity}
              onChange={(v) => setD("entity", v)}
              options={ENTITIES.map((e) => ({ code: e, label: e }))}
              onFocus={() => setFocusKey("entity")}
            />
          </div>
          <div>
            <label className={labelCls}>Capex</label>
            <Sel
              value={draft.capex_flag}
              onChange={(v) => setD("capex_flag", v)}
              options={
                masters["CAPEX_FLAG"] ?? [
                  { code: "RECURRING", label: "RECURRING" },
                  { code: "CAPEX", label: "CAPEX" },
                ]
              }
              onFocus={() => setFocusKey("capex")}
            />
          </div>
        </FieldBand>

        {/* -------- WHAT WORK -------- */}
        <FieldBand title="What work">
          <div className="md:col-span-4">
            <label className={labelCls}>Activity (type to search)</label>
            <Combo
              value={draft.activity}
              display={
                activityByCode.get(draft.activity)?.label ?? draft.activity
              }
              onChange={(v) => setD("activity", v)}
              options={(masters["ACTIVITY"] ?? []).map((a) => ({
                code: a.code,
                label: a.label,
                sub: a.required_unit ? `expects ${a.required_unit}` : undefined,
              }))}
              placeholder="e.g. weed, spray, manuring, fence…"
              onFocus={() => setFocusKey("activity")}
            />
          </div>
          <div className="md:col-span-2">
            <label className={labelCls}>Cost nature</label>
            <Sel
              value={draft.cost_nature}
              onChange={(v) => setD("cost_nature", v)}
              allowBlank
              options={masters["COST_NATURE"] ?? []}
              onFocus={() => setFocusKey("linecostnature")}
            />
          </div>
        </FieldBand>

        {/* -------- ON WHAT -------- */}
        <FieldBand title="On what">
          <div className="md:col-span-2">
            <label className={labelCls}>Cost object (crop / land / asset)</label>
            <Combo
              value={draft.cost_object}
              display={
                (masters["COST_OBJECT"] ?? []).find(
                  (c) => c.code === draft.cost_object,
                )?.label ?? draft.cost_object
              }
              onChange={(v) => setD("cost_object", v)}
              options={(masters["COST_OBJECT"] ?? []).map((c) => ({
                code: c.code,
                label: c.label,
              }))}
              placeholder="type to search…"
              onFocus={() => setFocusKey("costobject")}
            />
          </div>
          <div className="md:col-span-2">
            <label className={labelCls}>
              How much covered
              {activityByCode.get(draft.activity)?.required_unit && (
                <span className="text-amber-600 dark:text-amber-400">
                  {" "}
                  (saves blank, but flagged)
                </span>
              )}
            </label>
            <input
              className={numCls}
              value={draft.qty}
              onChange={(e) => setD("qty", e.target.value)}
              onFocus={() => setFocusKey("qty")}
            />
          </div>
          <div>
            <label className={labelCls}>Unit</label>
            <Sel
              value={draft.unit}
              onChange={(v) => setD("unit", v)}
              allowBlank
              options={masters["UNIT"] ?? []}
              onFocus={() => setFocusKey("unit")}
            />
          </div>
          <BandHint>
            acres, trees, feet — whatever the standard for this work is
            measured in
          </BandHint>
        </FieldBand>

        {/* -------- HOW MUCH -------- */}
        <FieldBand title="How much">
          <div>
            {/* Every narration in the workbook says "labours", never
                "mandays". Their word first, ours in brackets. */}
            <label className={labelCls}>Labours (mandays)</label>
            <input
              className={numCls}
              value={draft.mandays}
              onChange={(e) => setD("mandays", e.target.value)}
              onFocus={() => setFocusKey("mandays")}
              placeholder="6.5"
            />
          </div>
          <div>
            <label className={labelCls}>{rateLabel(draft)}</label>
            <input
              className={numCls}
              value={draft.rate}
              onChange={(e) => setD("rate", e.target.value)}
              onFocus={() => setFocusKey("rate")}
            />
          </div>
          <div>
            <label className={labelCls}>
              Amount ₹
              {oneTime && !draft.party_code && (
                <span className="text-amber-600 dark:text-amber-400">
                  {" "}
                  (max ₹ {formatINR(oneTimeMax)} for one-time)
                </span>
              )}
              {!amountTouched && impliedAmount(draft) !== null && (
                <span className="text-muted-foreground"> (calculated)</span>
              )}
            </label>
            <input
              ref={amountRef}
              className={numCls}
              value={draft.amount}
              onChange={(e) => setD("amount", e.target.value)}
              onFocus={() => setFocusKey("amount")}
              onKeyDown={(e) => {
                if (e.key === "Enter") commitDraft();
              }}
            />
          </div>
          <BandHint>
            {num(draft.amount) !== null && num(draft.amount)! > 0 ? (
              <strong className="text-foreground">
                ₹ {formatINR(num(draft.amount)!)} — {amountInWords(num(draft.amount)!)}.
              </strong>
            ) : null}{" "}
            {rateBasis(draft) === "MANDAY"
              ? "Half days are fine — 6.5 labours. Amount fills itself; overtype if the slip differs."
              : rateBasis(draft) === "UNIT" && draft.unit
                ? `Piece work: ₹ per ${draft.unit} × how much covered. Amount fills itself.`
                : "Day wage: fill labours. Piece work: leave labours blank and fill how much covered."}
          </BandHint>
        </FieldBand>

        {/* -------- WHO AND WHY -------- */}
        <FieldBand title="Who and why">
          <div className="md:col-span-2">
            <label className={labelCls}>Payee / party (this line)</label>
            <Combo
              value={draft.party_code}
              display={
                draft.party_code
                  ? (partyByCode.get(draft.party_code.toUpperCase())?.name ??
                    draft.party_code)
                  : ""
              }
              onChange={(v) => setD("party_code", v)}
              options={parties.map((p) => ({
                code: p.party_code,
                label: p.name,
                sub: p.party_code,
              }))}
              placeholder={oneTime ? "one-time (header)" : "inherits header"}
              onFocus={() => setFocusKey("lineparty")}
            />
          </div>
          <div className="md:col-span-4">
            <label className={labelCls}>
              Narration{" "}
              <span
                className={
                  draft.narration.trim().length < narrFloor(draft.activity)
                    ? "text-red-600 dark:text-red-400"
                    : "text-muted-foreground"
                }
              >
                ({draft.narration.trim().length}/{narrFloor(draft.activity)} min)
              </span>
            </label>
            <input
              className={
                inputCls +
                (draft.narration.trim().length < narrFloor(draft.activity)
                  ? " border-amber-500"
                  : "")
              }
              value={draft.narration}
              onChange={(e) => setD("narration", e.target.value)}
              onFocus={() => setFocusKey("narration")}
              onKeyDown={(e) => {
                if (e.key === "Enter") commitDraft();
              }}
              placeholder={
                oneTime && !draft.party_code
                  ? "name the person and what they did"
                  : "say what the boxes above cannot"
              }
            />
            {/* What the columns already hold. Stops the narration repeating
                the farm, crop and labour count — which is most of what the
                old sheet's narrations were spending their words on. */}
            {alreadyRecorded(draft) && (
              <div className="text-sm text-muted-foreground mt-1 truncate">
                Already recorded: {alreadyRecorded(draft)}
              </div>
            )}
            {looksBundled(draft.narration) && (
              <div className="text-sm text-amber-700 dark:text-amber-400 mt-1">
                This looks like more than one thing — Add line splits it, and
                each part keeps its own head.
              </div>
            )}
          </div>
        </FieldBand>

        <div className="flex items-center gap-3 mt-3">
          <button
            className={
              "rounded px-3 py-2 text-base " +
              (editingIndex !== null
                ? "bg-primary text-primary-foreground"
                : "border border-input bg-background hover:bg-accent")
            }
            onClick={commitDraft}
            title="Enter"
          >
            {editingIndex !== null ? "Update line ⏎" : "Add line ⏎"}
          </button>

          {draftMsg && (
            <span className="text-base text-red-600 dark:text-red-400">
              {draftMsg}
            </span>
          )}
        </div>
      </section>

      {/* ---------------- help strip: anchored under the entry card --------
          Fixed height (h-10) so nothing jumps as the text changes length.
          Left accent bar + tint + bold field name: it must read as a reply
          to the cursor, not as page furniture. Roughly 40px from whatever
          field has focus, which is the whole point. -------------------- */}
      <div className="h-12 mb-4 flex items-center gap-2 rounded border border-input border-l-4 border-l-primary bg-muted/60 px-3">
        <span className="text-sm leading-snug line-clamp-2">
          {focusKey && FIELD_LABEL[focusKey] && (
            <strong className="font-semibold">
              {FIELD_LABEL[focusKey]}
              {" · "}
            </strong>
          )}
          <span className="text-muted-foreground">{helpFor(focusKey)}</span>
        </span>
      </div>

      {/* ---------------- preview panel: what save will do ---------------- */}
      {(redMsgs.length > 0 || amberMsgs.length > 0) && allLines.length > 0 && (
        <section className="mb-4 text-base space-y-2">
          {redMsgs.length > 0 && (
            <div className="border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-300 rounded p-3">
              <div className="font-medium mb-1">
                The database will refuse this voucher:
              </div>
              {redMsgs.map((m, i) => (
                <div key={i}>· {m}</div>
              ))}
            </div>
          )}
          {amberMsgs.length > 0 && (
            <div className="border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/30 text-amber-800 dark:text-amber-300 rounded p-3">
              <div className="font-medium mb-1">
                Saves, but will be flagged or warned:
              </div>
              {amberMsgs.map((m, i) => (
                <div key={i}>· {m}</div>
              ))}
            </div>
          )}
        </section>
      )}

      {/* ---------------- save row ---------------- */}
      <section className="flex items-center gap-4 mb-4">
        <button
          className={
            "rounded px-5 py-2 font-medium disabled:opacity-50 " +
            (armed
              ? "bg-amber-600 text-white"
              : "bg-primary text-primary-foreground")
          }
          disabled={!canSave}
          onClick={onSave}
        >
          {saving
            ? "Saving…"
            : armed
              ? `Confirm — save with ${amberMsgs.length} flag${amberMsgs.length === 1 ? "" : "s"}`
              : amberMsgs.length > 0
                ? `Save with ${amberMsgs.length} flag${amberMsgs.length === 1 ? "" : "s"}…`
                : "Save voucher"}
        </button>
        {armed && (
          <button
            className="border border-input rounded px-3 py-2 text-base"
            onClick={() => setArmed(false)}
          >
            Cancel
          </button>
        )}
        <span className="text-base text-muted-foreground tabular-nums">
          {allLines.length} line{allLines.length === 1 ? "" : "s"} · total ₹{" "}
          {formatINR(linesTotal)}
          {linesTotal > 0 && (
            <span className="text-sm"> — {amountInWords(linesTotal)}</span>
          )}
        </span>
      </section>

      {/* ---------------- what the database said ---------------- */}
      {lastResult && !lastResult.ok && (
        <div className="border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-300 rounded p-3 mb-4 whitespace-pre-wrap text-base">
          <strong>Not saved.</strong> {lastResult.message}
          {refusedLine > 0 && refusedLine <= lines.length && (
            <div className="mt-1 text-sm">Line {refusedLine} is highlighted above.</div>
          )}
        </div>
      )}
      {lastResult && lastResult.ok && (
        <div className="border border-green-300 dark:border-green-800 bg-green-50 dark:bg-green-950/30 rounded p-3 mb-4">
          <div className="text-base text-green-900 dark:text-green-300 mb-1">
            Saved{lastResult.entry_type === "SAMPLE" ? " (SAMPLE mode)" : ""}.
            Write this number on the slip:
          </div>
          <div className="flex items-center gap-3">
            <span className="text-3xl font-semibold tabular-nums select-all">
              {lastResult.voucher_no}
            </span>
            <button
              className="text-sm border border-input rounded px-2 py-1"
              onClick={() =>
                navigator.clipboard?.writeText(lastResult.voucher_no)
              }
            >
              Copy
            </button>
          </div>
          {lastResult.warnings.length > 0 && (
            <div className="mt-2 text-base text-amber-800 dark:text-amber-300">
              {lastResult.warnings.map((w, i) => (
                <div key={i}>· {w}</div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ---------------- session strip: this sitting ---------------- */}
      {session.length > 0 && (
        <section className="border border-input rounded-lg p-3 text-base">
          <div className="text-sm text-muted-foreground mb-1">
            Saved this sitting — write each number on its slip:
          </div>
          <table className="w-full">
            <tbody>
              {session.map((s, i) => (
                <tr key={i} className="border-t border-input first:border-t-0">
                  <td className="py-0.5 font-medium tabular-nums">
                    {s.voucher_no}
                  </td>
                  <td>{s.payee || "—"}</td>
                  <td className="text-right tabular-nums">
                    ₹ {formatINR(s.total)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

    </main>
  );
}
