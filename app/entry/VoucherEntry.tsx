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

import { useMemo, useRef, useState } from "react";
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
  cost_nature: string; // blank = inherit header cost nature
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

export default function VoucherEntry({
  masters,
  parties: initialParties,
  today,
  vagueActivities,
  narrationMin,
  vagueNarrationMin,
  sampleMode,
  initialCashBalance,
  userEmail,
}: Props) {
  // ---- header: defaults for every line, set once per paper slip ----------
  const [dateText, setDateText] = useState(formatDMY(today));
  const [mode, setMode] = useState(
    masters["MODE"]?.find((m) => m.code === "CASH")?.code ??
      masters["MODE"]?.[0]?.code ??
      "",
  );
  const [headerPayee, setHeaderPayee] = useState("");
  const [periodFromText, setPeriodFromText] = useState("");
  const [periodToText, setPeriodToText] = useState("");
  const [headerParty, setHeaderParty] = useState("");
  const [headerCostNature, setHeaderCostNature] = useState("");

  // ---- lines: committed ones plus the one being edited --------------------
  const [lines, setLines] = useState<EditLine[]>([]);
  const [draft, setDraft] = useState<EditLine>(emptyLine());
  const [draftMsg, setDraftMsg] = useState<string | null>(null);

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

  // Effective (post-inheritance) values for one line — the same resolution
  // the payload applies, reused by every preview check so they cannot drift
  // from what is actually sent.
  const eff = (l: EditLine) => ({
    payee: l.payee.trim() || headerPayee.trim(),
    party: l.party_code || headerParty,
    costNature: l.cost_nature || headerCostNature,
  });

  const narrFloor = (activity: string) =>
    vagueActivities.includes(activity) ? vagueNarrationMin : narrationMin;

  // A draft counts as a line the moment it is complete — she typed it, she
  // means it. "Complete" = what commitDraft would accept.
  function draftProblems(d: EditLine): string[] {
    const p: string[] = [];
    if (!d.farm) p.push("farm");
    if (!d.cost_object) p.push("cost object");
    if (!d.activity) p.push("activity");
    if (!(num(d.amount) !== null && num(d.amount)! > 0)) p.push("amount");
    if (d.narration.trim().length < narrFloor(d.activity))
      p.push(`narration (min ${narrFloor(d.activity)})`);
    return p;
  }

  const draftComplete = draftProblems(draft).length === 0;
  const allLines: EditLine[] = draftComplete ? [...lines, draft] : lines;

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

  allLines.forEach((l, i) => {
    const n = i + 1;
    const e = eff(l);
    const floor = narrFloor(l.activity);
    const narr = l.narration.trim();

    // -- red: the DB will refuse --
    if (narr.length < floor)
      redMsgs.push(
        vagueActivities.includes(l.activity)
          ? `Line ${n}: ${l.activity} is a last resort — say what it was actually for (min ${floor} characters).`
          : `Line ${n}: narration needs at least ${floor} characters.`,
      );
    if (!e.costNature)
      redMsgs.push(
        `Line ${n}: cost nature is needed — set it once in the header, or on the line.`,
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
    const amt = num(l.amount);
    if (md !== null && rt !== null && amt !== null && Math.abs(md * rt - amt) > 0.005)
      amberMsgs.push(
        `Line ${n}: amount ₹ ${formatINR(amt)} ≠ mandays × rate ₹ ${formatINR(md * rt)}.`,
      );
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
    !saving && allLines.length > 0 && redMsgs.length === 0;

  // Which committed line did the DB refuse? ("Line 3: …" in its message.)
  const refusedLine =
    lastResult && !lastResult.ok
      ? Number(/^Line (\d+):/.exec(lastResult.message)?.[1] ?? 0)
      : 0;

  // ---- line handling -------------------------------------------------------

  function setD<K extends keyof EditLine>(k: K, v: EditLine[K]) {
    setDraft((d) => ({ ...d, [k]: v }));
    setDraftMsg(null);
    setArmed(false); // any edit disarms a pending confirm
  }

  function commitDraft(): boolean {
    const probs = draftProblems(draft);
    if (probs.length) {
      setDraftMsg(`Still needed: ${probs.join(", ")}.`);
      return false;
    }
    setLines((ls) => [...ls, draft]);
    // §5: the next line opens as a copy of this one. Amount, qty and mandays
    // clear (they belong to the line); NARRATION NOW CARRIES FORWARD
    // (handover §2.3) — a twenty-line muster is one narration, not twenty.
    setDraft({ ...draft, qty: "", mandays: "", amount: "" });
    setDraftMsg(null);
    setArmed(false);
    setTimeout(() => amountRef.current?.focus(), 0);
    return true;
  }

  function removeLine(i: number) {
    // Removing an UNSAVED line is allowed — nothing exists yet; immutability
    // (§13) begins at save, not at typing.
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
      setDraft(emptyLine());
      setHeaderPayee("");
      setHeaderParty("");
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
  function helpFor(key: string | null): string {
    switch (key) {
      case "date":
        return 'Payment date, DD/MM/YYYY — or just "19" for the 19th of this month, "19/6", "1907". The line below shows how it will be read.';
      case "mode": {
        const base =
          "How the money moved. Bank and credit modes need a party.";
        return modeRow?.notes ? `${base}  ·  ${mode}: ${modeRow.notes}` : base;
      }
      case "payee":
        return "Default payee for every line, as written on the slip. A line can override it.";
      case "pfrom":
        return "First day the work covers. Required — typed once here, every line inherits it.";
      case "pto":
        return "Last day the work covers. Required. Same-day work: same as period from.";
      case "party":
        return "Type to search by name or code. If nothing matches, the last row of the list adds what you typed as a new party — you never leave the voucher.";
      case "costnature": {
        const cn = (masters["COST_NATURE"] ?? []).find(
          (c) => c.code === headerCostNature,
        );
        const base =
          "How the money was spent: labour, material, machine hire… Default for every line; a line can override. One job, two natures → split into two lines.";
        return cn?.notes ? `${base}  ·  ${cn.code}: ${cn.notes}` : base;
      }
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
          ? `How much work — ${a.code} expects ${a.required_unit}. Blank saves, but is flagged.`
          : "How much work, in the unit alongside. Optional where the activity has no required unit.";
      }
      case "unit":
        return "Unit for the quantity.";
      case "mandays":
        return "Workers × days. Optional — but if rate is also filled, amount should equal mandays × rate (a warning, not a refusal).";
      case "rate":
        return "₹ per manday.";
      case "amount":
        return "₹ paid on this line. Enter commits the line and opens the next.";
      case "narration": {
        const floor = narrFloor(draft.activity);
        return `What this line was for — at least ${floor} characters. The last chance to catch a wrong posting. Copies into the next line, so a twenty-line muster is typed once.`;
      }
      case "linepayee":
        return "Payee for this line only, when it differs from the header's.";
      case "lineparty":
        return "Party for this line only, when it differs from the header's.";
      case "linecostnature":
        return "Cost nature for this line only — this is how one job splits into labour + machine hire.";
      default:
        return "Tab moves forward · Enter adds the line · Esc clears the line being typed";
    }
  }

  // ---- styling helpers (tokens, not colours: dark mode + the future shell) --

  const inputCls =
    "border border-input bg-background rounded px-2 py-1 text-sm w-full " +
    "focus:outline-none focus:ring-2 focus:ring-ring";
  const labelCls = "block text-xs text-muted-foreground mb-0.5";
  const numCls = inputCls + " text-right tabular-nums";

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

  // ------------------------------------------------------------------------
  // Combo — one type-ahead for every long list. Substring match on code and
  // label; arrows + Enter select; Esc closes. When `onAddNew` is given and
  // the typed text matches nothing exactly, the last row offers to add it —
  // the party picker's inline-add path.
  // ------------------------------------------------------------------------
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
          <ul className="absolute z-20 mt-1 w-full max-h-64 overflow-auto rounded border border-input bg-background shadow-md text-sm">
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

  // ------------------------------------------------------------------------
  // AddPartyPanel — inline, not a modal, not a page. Name prefilled from
  // what she typed; code derived and collision-checked live against the
  // loaded list (fn_party_upsert overwrites on collision by design — the
  // screen owns this question). On a clash: use the existing party, or take
  // the auto-bumped code. Mobile optional (decision C3).
  // ------------------------------------------------------------------------
  function AddPartyPanel({ typed }: { typed: string }) {
    const [name, setName] = useState(typed);
    const [code, setCode] = useState(deriveCode(typed));
    const [kind, setKind] = useState<PartyKind>("SUPPLIER");
    const [mobile, setMobile] = useState("");

    const clash = partyByCode.get(code.trim().toUpperCase()) ?? null;
    const codeOk = code.trim().length > 0 && !clash;

    return (
      <div className="border border-input rounded-lg p-3 bg-muted/50 mt-2 text-sm">
        <div className="font-medium mb-2">New party</div>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
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
            <button
              className="underline"
              onClick={() => {
                setHeaderParty(clash.party_code);
                setAddingParty(null);
                setTimeout(() => partyInputRef.current?.focus(), 0);
              }}
            >
              Use the existing party
            </button>{" "}
            ·{" "}
            <button
              className="underline"
              onClick={() =>
                setCode(
                  bumpCode(deriveCode(name), (c) =>
                    partyByCode.has(c.toUpperCase()),
                  ),
                )
              }
            >
              Create new as “
              {bumpCode(deriveCode(name), (c) => partyByCode.has(c.toUpperCase()))}
              ”
            </button>
          </div>
        )}

        {partyErr && (
          <div className="mt-2 text-red-700 dark:text-red-400">{partyErr}</div>
        )}

        <div className="mt-3 flex gap-2">
          <button
            className="bg-primary text-primary-foreground rounded px-3 py-1.5 disabled:opacity-50"
            disabled={!codeOk || !name.trim() || partyBusy}
            onClick={() => submitAddParty(code.trim(), name.trim(), kind, mobile)}
          >
            {partyBusy ? "Saving…" : "Save party"}
          </button>
          <button
            className="border border-input rounded px-3 py-1.5"
            onClick={() => {
              setAddingParty(null);
              setPartyErr(null);
            }}
          >
            Cancel
          </button>
        </div>
      </div>
    );
  }

  // ---- render -------------------------------------------------------------

  const dateEcho = (text: string, iso: string | null) => (
    <div className="text-xs mt-0.5 text-muted-foreground h-4">
      {text && (iso ? formatDMY(iso) : "not a date")}
    </div>
  );

  return (
    <main className="max-w-6xl mx-auto p-4 pb-24">
      {/* ---------------- title row: who, and cash in hand ---------------- */}
      <header className="flex items-baseline justify-between mb-4 gap-4 flex-wrap">
        <h1 className="text-xl font-semibold">Voucher entry — payment</h1>
        <div className="flex items-baseline gap-4">
          <span className="text-sm tabular-nums">
            Cash in hand:{" "}
            <strong>{cash === null ? "—" : `₹ ${formatINR(cash)}`}</strong>
            {sampleMode && (
              <span className="text-xs text-muted-foreground"> (SAMPLE)</span>
            )}
          </span>
          <span className="text-xs text-muted-foreground">{userEmail}</span>
        </div>
      </header>

      {/* ---------------- header: once per paper slip ---------------- */}
      <section className="grid grid-cols-2 md:grid-cols-7 gap-3 border border-input rounded-lg p-3 bg-muted/50 mb-4">
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
          <label className={labelCls}>Payee (default for lines)</label>
          <input
            className={inputCls}
            value={headerPayee}
            onChange={(e) => {
              setHeaderPayee(e.target.value);
              setArmed(false);
            }}
            onFocus={() => setFocusKey("payee")}
            placeholder="as written on the slip"
          />
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
        <div>
          <label className={labelCls}>
            Cost nature (default for lines)
          </label>
          <Sel
            value={headerCostNature}
            onChange={(v) => {
              setHeaderCostNature(v);
              setArmed(false);
            }}
            allowBlank
            options={masters["COST_NATURE"] ?? []}
            onFocus={() => setFocusKey("costnature")}
          />
        </div>
        {partyRequired && (
          <div>
            <label className={labelCls}>
              Party ({modeKind === "BANK" ? "bank — required" : "credit — required"})
            </label>
            <Combo
              value={headerParty}
              display={
                headerParty
                  ? partyByCode.get(headerParty.toUpperCase())?.name ??
                    headerParty
                  : ""
              }
              onChange={(v) => {
                setHeaderParty(v);
                setArmed(false);
              }}
              options={parties.map((p) => ({
                code: p.party_code,
                label: p.name,
                sub: p.party_code,
              }))}
              placeholder="type name or code…"
              onFocus={() => setFocusKey("party")}
              onAddNew={openAddParty}
              inputRef={partyInputRef}
            />
          </div>
        )}
      </section>

      {addingParty && <AddPartyPanel typed={addingParty.typed} />}

      {/* ---------------- committed lines ---------------- */}
      {lines.length > 0 && (
        <table className="w-full text-sm mb-2">
          <thead>
            <tr className="text-left text-xs text-muted-foreground">
              <th className="py-1">#</th>
              <th>Entity</th>
              <th>Farm</th>
              <th>Cost object</th>
              <th>Activity</th>
              <th>Nature</th>
              <th className="text-right">Qty</th>
              <th className="text-right">Amount ₹</th>
              <th>Narration</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr
                key={i}
                className={
                  "border-t border-input " +
                  (refusedLine === i + 1
                    ? "bg-red-50 dark:bg-red-950/40 ring-1 ring-red-400"
                    : "")
                }
              >
                <td className="py-1">{i + 1}</td>
                <td>{l.entity}</td>
                <td>{l.farm}</td>
                <td>{l.cost_object}</td>
                <td>{activityByCode.get(l.activity)?.label ?? l.activity}</td>
                <td>{l.cost_nature || headerCostNature || "—"}</td>
                <td className="text-right tabular-nums">{l.qty}</td>
                <td className="text-right tabular-nums">
                  {formatINR(num(l.amount) ?? 0)}
                </td>
                <td className="max-w-[16rem] truncate" title={l.narration}>
                  {l.narration}
                </td>
                <td className="text-right">
                  <button
                    className="text-xs text-muted-foreground hover:text-red-600"
                    onClick={() => removeLine(i)}
                    title="Remove this unsaved line"
                  >
                    ✕
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {/* ---------------- the line being typed ---------------- */}
      <section
        className="border border-input rounded-lg p-3 mb-4"
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            setDraft({ ...emptyLine(), narration: draft.narration });
            setDraftMsg(null);
          }
        }}
      >
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-3">
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
          <div>
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
          <div>
            <label className={labelCls}>Cost object</label>
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
        </div>

        <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-3">
          <div className="md:col-span-2">
            <label className={labelCls}>Activity (type to search)</label>
            <Combo
              value={draft.activity}
              display={activityByCode.get(draft.activity)?.label ?? draft.activity}
              onChange={(v) => setD("activity", v)}
              options={(masters["ACTIVITY"] ?? []).map((a) => ({
                code: a.code,
                label: a.label,
                sub: a.required_unit ? `expects ${a.required_unit}` : undefined,
              }))}
              placeholder="e.g. spray, fence, tholuvam…"
              onFocus={() => setFocusKey("activity")}
            />
          </div>
          <div>
            <label className={labelCls}>Qty</label>
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
          <div>
            <label className={labelCls}>Cost nature (this line)</label>
            <Sel
              value={draft.cost_nature}
              onChange={(v) => setD("cost_nature", v)}
              allowBlank
              options={masters["COST_NATURE"] ?? []}
              onFocus={() => setFocusKey("linecostnature")}
            />
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-6 gap-3 items-end">
          <div>
            <label className={labelCls}>Mandays</label>
            <input
              className={numCls}
              value={draft.mandays}
              onChange={(e) => setD("mandays", e.target.value)}
              onFocus={() => setFocusKey("mandays")}
            />
          </div>
          <div>
            <label className={labelCls}>Rate ₹</label>
            <input
              className={numCls}
              value={draft.rate}
              onChange={(e) => setD("rate", e.target.value)}
              onFocus={() => setFocusKey("rate")}
            />
          </div>
          <div>
            <label className={labelCls}>Amount ₹</label>
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
          <div className="md:col-span-2">
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
            />
          </div>
          <div>
            <label className={labelCls}>Payee (this line)</label>
            <input
              className={inputCls}
              value={draft.payee}
              onChange={(e) => setD("payee", e.target.value)}
              onFocus={() => setFocusKey("linepayee")}
              placeholder={headerPayee || "inherits header"}
            />
          </div>
        </div>

        <div className="flex items-center gap-3 mt-3">
          <button
            className="border border-input rounded px-3 py-1.5 text-sm bg-background hover:bg-accent"
            onClick={commitDraft}
            title="Enter"
          >
            Add line ⏎
          </button>
          {partyRequired && (
            <div className="w-56">
              <Combo
                value={draft.party_code}
                display={
                  draft.party_code
                    ? partyByCode.get(draft.party_code.toUpperCase())?.name ??
                      draft.party_code
                    : ""
                }
                onChange={(v) => setD("party_code", v)}
                options={parties.map((p) => ({
                  code: p.party_code,
                  label: p.name,
                  sub: p.party_code,
                }))}
                placeholder="party (this line) — inherits header"
                onFocus={() => setFocusKey("lineparty")}
              />
            </div>
          )}
          {draftMsg && (
            <span className="text-sm text-red-600 dark:text-red-400">
              {draftMsg}
            </span>
          )}
        </div>
      </section>

      {/* ---------------- preview panel: what save will do ---------------- */}
      {(redMsgs.length > 0 || amberMsgs.length > 0) && allLines.length > 0 && (
        <section className="mb-4 text-sm space-y-2">
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
            className="border border-input rounded px-3 py-2 text-sm"
            onClick={() => setArmed(false)}
          >
            Cancel
          </button>
        )}
        <span className="text-sm text-muted-foreground tabular-nums">
          {allLines.length} line{allLines.length === 1 ? "" : "s"} · total ₹{" "}
          {formatINR(linesTotal)}
        </span>
      </section>

      {/* ---------------- what the database said ---------------- */}
      {lastResult && !lastResult.ok && (
        <div className="border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-300 rounded p-3 mb-4 whitespace-pre-wrap text-sm">
          <strong>Not saved.</strong> {lastResult.message}
          {refusedLine > 0 && refusedLine <= lines.length && (
            <div className="mt-1 text-xs">Line {refusedLine} is highlighted above.</div>
          )}
        </div>
      )}
      {lastResult && lastResult.ok && (
        <div className="border border-green-300 dark:border-green-800 bg-green-50 dark:bg-green-950/30 rounded p-3 mb-4">
          <div className="text-sm text-green-900 dark:text-green-300 mb-1">
            Saved{lastResult.entry_type === "SAMPLE" ? " (SAMPLE mode)" : ""}.
            Write this number on the slip:
          </div>
          <div className="flex items-center gap-3">
            <span className="text-2xl font-semibold tabular-nums select-all">
              {lastResult.voucher_no}
            </span>
            <button
              className="text-xs border border-input rounded px-2 py-1"
              onClick={() =>
                navigator.clipboard?.writeText(lastResult.voucher_no)
              }
            >
              Copy
            </button>
          </div>
          {lastResult.warnings.length > 0 && (
            <div className="mt-2 text-sm text-amber-800 dark:text-amber-300">
              {lastResult.warnings.map((w, i) => (
                <div key={i}>· {w}</div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ---------------- session strip: this sitting ---------------- */}
      {session.length > 0 && (
        <section className="border border-input rounded-lg p-3 text-sm">
          <div className="text-xs text-muted-foreground mb-1">
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

      {/* ---------------- help strip: the Tally line ---------------- */}
      <div className="fixed bottom-0 inset-x-0 border-t border-input bg-background/95 backdrop-blur">
        <div className="max-w-6xl mx-auto px-4 py-2 text-xs text-muted-foreground truncate">
          {helpFor(focusKey)}
        </div>
      </div>
    </main>
  );
}
