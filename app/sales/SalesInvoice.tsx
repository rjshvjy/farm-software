// https://github.com/rjshvjy/farm-software/blob/main/app/sales/SalesInvoice.tsx
// app/sales/SalesInvoice.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — SALES INVOICE. Spec v3.0 Part 0.3, §18.5 step 3.
//
// RENAMED FROM ReceiptEntry, 20-07-2026. What was built here was always a
// sales invoice: it carries the crop, the farm, the block and the quantity,
// and mode chooses whether the debit goes to the buyer (ON CREDIT) or to a
// pocket (CASH / BANK). A RECEIPT is the settlement that follows — money in
// against a party balance, no dimensions at all (Part 0.5) — and it is a
// separate, much smaller screen.
//
// DERIVED from app/entry/VoucherEntry.tsx on 20-07-2026 — deliberately a
// sibling, not a mode of that screen (§5: a screen that does both directions
// is forty fields nobody can follow). The two share their leaf pieces
// (components/entry/ui.tsx) and the party panel
// (components/entry/AddPartyPanel.tsx); the composition, wording and
// preview live per-screen and are ALLOWED to differ.
//
// WHAT IS DIFFERENT FROM THE PAYMENT SCREEN, AND WHY:
//   - saveReceipt sends received_cr and voucher type RECEIPT: own series
//     R/26/0001 (file 12), and the DB demands at least one money-in line.
//   - "Buyer" replaces "Payee". Same party register, same inline add — but
//     the panel defaults to CUSTOMER, not DAILY LABOUR: the person in front
//     of you is usually buying produce.
//
//   - THE LANGUAGE MUST NOT ASSUME THE MONEY HAS ARRIVED (20-07-2026). This
//     screen was renamed from ReceiptEntry and kept its wording for a few
//     hours: "Received from", "Money received", "Amount received". On a CASH
//     sale that is true; on an ON CREDIT sale it is the opposite of true —
//     the buyer takes the nuts today and pays next month, which is the whole
//     point of a credit sale. An invoice records what is DUE. Where the
//     wording genuinely depends on the mode it now follows modeKind, and
//     everywhere else it is neutral.
//   - QUANTITY IS THE POINT (§17.6): without it there is no realisation
//     rate and yield per acre stays unanswerable. Owner's ruling 20-07:
//     blank SAVES and is FLAGGED, never refused — a chopped tree sells as
//     a lumpsum (qty 1, unit LUMPSUM, no flag). The income activities
//     carry required_unit in the master (file 12 §9), so the same flag
//     machinery as payments does the work.
//   - NO capex field: a receipt is not spending. The DB default supplies
//     RECURRING. An asset SALE is the journal's job (§17.3/§17.4), not a
//     receipt's — its gain/loss cannot move through a pocket.
//   - NO mandays field: nobody's labour is counted on a money-in line.
//     Rate is therefore always ₹ per unit sold, and amount fills itself
//     as qty × rate — the realisation arithmetic, same as the paper.
//   - Cost nature defaults to OTHER (resolved against the loaded master,
//     never assumed): the DB requires the column on every row (A7), but
//     "what kind of spending" is a payment question. Editable; the odd
//     receipt that genuinely has a nature (e.g. TRANSPORT recovered) can
//     say so.
//   - THE RULE MOST LIKELY GOT WRONG IN A HURRY (§13): owner money in is
//     FUNDING, never income. The entity help teaches it, and file 12's
//     entity×account-type guard refuses FUNDING→income at save. The
//     screen does not duplicate that resolution (it would need posting
//     rules client-side); the DB's message names the fix.
//
// Everything else — serials, immutability-at-save, the red/amber preview,
// carry-forward, edit-in-place, the two-click amber confirm, the session
// strip, DD/MM/YYYY shorthand, amount in words — is the payment screen's
// machinery, kept line-for-line so the accountant learns ONE screen twice.
//
// Read §16.11 before touching this file; every rule in it cost an evening.
// ---------------------------------------------------------------------------
"use client";

import React, { useMemo, useRef, useState } from "react";
import { formatDMY, parseDMY, formatINR } from "@/lib/dates";
import {
  saveSalesInvoice,
  type SalesInvoiceLine,
  type SaveSalesResult,
} from "./actions";
// A party is a party whichever way the money moves: the shared register's
// write path stays in the payment screen's actions file.
import { createParty, type PartyKind } from "@/app/entry/actions";

// --- types coming from the server component --------------------------------

// The row shapes are the payment screen's own — type-only import, erased at
// build, so the single source of truth stays in one place.
import type {
  MasterRow,
  PartyRow,
  PartyKindRow,
} from "@/app/entry/VoucherEntry";

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
  // v_party_receipt_stats (file 12): each party's own RECEIPT record, for
  // the self-calibrating warning — a receipt is measured against what they
  // usually pay US, never against what we pay them. Empty on day one; the
  // warning stays silent until there is a pattern.
  receiptStats: Record<
    string,
    {
      times_received: number;
      max_received: number;
      avg_received: number;
      last_received: string;
    }
  >;
  /** Selectable party kinds, grouped. Empty means file 10 has not been run. */
  partyKinds: PartyKindRow[];
  userEmail: string;
};

// One line as the screen holds it (strings while editing; converted on save).
type EditLine = {
  entity: string;
  farm: string;
  block: string;
  cost_object: string;
  activity: string;
  qty: string;
  unit: string;
  rate: string;
  amount: string;
  payee: string; // blank = inherit header payee
  narration: string;
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
//
// FUNDING IS ABSENT ON THIS SCREEN, DELIBERATELY (Part 0.6, §16.18). Owner
// money coming in is capital, never income, and it arrives as a RECEIPT — a
// party balance moving, with no crop and no farm. Leaving FUNDING here would
// hold open the exact door file 12's entity guard exists to catch. The guard
// stays as the backstop; this removes the temptation.
const ENTITIES = ["BUSINESS", "PERSONAL"];

const emptyLine = (): EditLine => ({
  entity: "BUSINESS",
  farm: "",
  block: "YET TO ASSIGN",
  cost_object: "",
  activity: "",
  qty: "",
  unit: "",
  rate: "",
  amount: "",
  payee: "",
  narration: "",
  cost_nature: "",
});

// ---------------------------------------------------------------------------
// AddPartyPanel (and its deriveCode / bumpCode helpers) moved to
// components/entry/AddPartyPanel.tsx on 20-07-2026 — the receipt screen
// shares the panel, differing only in defaultKind (see the call site below).
// ---------------------------------------------------------------------------
import { AddPartyPanel } from "@/components/entry/AddPartyPanel";


// ---------------------------------------------------------------------------
// Shared leaf pieces — bands, pickers, styles, amount in words — moved to
// components/entry/ui.tsx on 20-07-2026 so the receipt screen shares them
// instead of copy-pasting. Pure move, no behaviour change. amountInWords is
// re-exported so any existing import from this file keeps working.
// ---------------------------------------------------------------------------
import {
  amountInWords,
  inputCls,
  labelCls,
  numCls,
  FieldBand,
  BandHint,
  Sel,
  Combo,
} from "@/components/entry/ui";

export { amountInWords };

// ---------------------------------------------------------------------------

export default function SalesInvoice({
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
  receiptStats,
  partyKinds,
  userEmail,
}: Props) {
  // ---- header: defaults for every line, set once per paper slip ----------
  const [dateText, setDateText] = useState(formatDMY(today));
  const [mode, setMode] = useState(
    masters["MODE"]?.find((m) => m.code === "CASH")?.code ??
      masters["MODE"]?.[0]?.code ??
      "",
  );
  const [periodFromText, setPeriodFromText] = useState("");
  const [periodToText, setPeriodToText] = useState("");
  const [headerParty, setHeaderParty] = useState("");
  // The one-time toggle (owner's design, 19-07): NOT a party row — a party
  // record invites duplicates and a meaningless balance. A checked toggle
  // sends the literal payee 'ONE TIME' with no party; the name goes in the
  // narration, and file 09 enforces exactly that.
  const [oneTime, setOneTime] = useState(false);

  // Cost nature is a payment question the schema asks of every row (A7).
  // Default OTHER — but only if the master actually holds it; an absent
  // code degrades to empty-and-red rather than to an invalid value.
  const costNatureDefault =
    masters["COST_NATURE"]?.some((c) => c.code === "OTHER") ? "OTHER" : "";

  // ---- lines: committed ones plus the one being edited --------------------
  const [lines, setLines] = useState<EditLine[]>([]);
  const [draft, setDraft] = useState<EditLine>({
    ...emptyLine(),
    cost_nature: costNatureDefault,
  });
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
  const [lastResult, setLastResult] = useState<SaveSalesResult | null>(null);
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

  // ---- rate: on a receipt it is always ₹ per unit SOLD --------------------
  // No mandays on money-in lines, so the payment screen's three-habit rule
  // collapses to one: rate belongs to the quantity. qty × rate = amount is
  // the realisation arithmetic, and the DB warns when they disagree.
  function rateLabel(l: EditLine): string {
    return l.unit ? `Rate \u20b9 / ${l.unit}` : "Rate \u20b9 / unit";
  }

  /** The amount the arithmetic implies, or null when it implies nothing. */
  function impliedAmount(l: EditLine): number | null {
    const r = num(l.rate);
    const q = num(l.qty);
    if (r === null || q === null) return null;
    return Math.round(q * r * 100) / 100;
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
  // 20-07-2026: there is no per-line buyer on an invoice, so there is nothing
  // to override the toggle. A checked toggle means payee 'ONE TIME' and no
  // party for the whole voucher, which is what file 09 expects.
  const eff = (l: EditLine) => {
    if (oneTime) {
      return { payee: "ONE TIME", party: "", costNature: l.cost_nature };
    }
    const party = headerParty;
    const partyName = party
      ? (partyByCode.get(party.toUpperCase())?.name ?? party)
      : "";
    return {
      payee: l.payee.trim() || partyName,
      party,
      costNature: l.cost_nature,
    };
  };

  const narrFloor = (activity: string) =>
    vagueActivities.includes(activity) || oneTime
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
    if (d.narration.trim().length < narrFloor(d.activity))
      p.push(`narration (min ${narrFloor(d.activity)})`);
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

  if (!dateISO) redMsgs.push(`Invoice date "${dateText}" is not a date.`);
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
      "A one-time buyer cannot be sold to on credit — nobody in particular cannot owe you money. Name the party.",
    );

  allLines.forEach((l, i) => {
    const n = i + 1;
    const e = eff(l);
    const lineOneTime = e.payee === "ONE TIME";
    const floor = narrFloor(l.activity);
    const narr = l.narration.trim();

    // -- red: the DB will refuse --
    if (narr.length < floor)
      redMsgs.push(
        lineOneTime
          ? `Line ${n}: a one-time buyer needs the person named in the narration — who bought, and what (min ${floor} characters).`
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
        modeKind === "BANK"
          ? `Line ${n}: a bank sale needs a party — the statement will name who paid, and the book must match it.`
          : `Line ${n}: a credit sale needs a party — somebody in particular owes this money.`,
      );

    // -- amber: it will save, and be flagged / warned --
    if (vagueActivities.includes(l.activity) && narr.length >= floor)
      amberMsgs.push(
        `Line ${n}: ${l.activity} will be flagged for the review queue.`,
      );
    if (modeKind === "CASH" && !e.payee && !e.party)
      amberMsgs.push(
        `Line ${n}: cash sale with nobody named — will be flagged (NO PAYEE).`,
      );
    if (farmHasBlocks(l.farm) && (l.block || "YET TO ASSIGN") === "YET TO ASSIGN")
      amberMsgs.push(
        `Line ${n}: ${l.farm} has blocks in the master and none is chosen — will be flagged.`,
      );
    const act = activityByCode.get(l.activity);
    if (act?.required_unit && num(l.qty) === null)
      amberMsgs.push(
        `Line ${n}: ${l.activity} expects ${act.required_unit} and none is recorded — saves, but flagged. No quantity means no realisation rate. A genuine lumpsum: qty 1, unit LUMPSUM.`,
      );
    const rt = num(l.rate);
    const qt = num(l.qty);
    const amt = num(l.amount);
    // file 09 mirror, receipt reading: qty × rate IS the realisation check.
    if (qt !== null && rt !== null && amt !== null &&
        Math.abs(qt * rt - amt) > 0.005)
      amberMsgs.push(
        `Line ${n}: amount ₹ ${formatINR(amt)} ≠ quantity × rate ₹ ${formatINR(qt * rt)}.`,
      );
    // file 09 mirror: one-time flag + threshold
    if (lineOneTime) {
      amberMsgs.push(`Line ${n}: one-time buyer — will be flagged for the review queue.`);
      if (amt !== null && amt > oneTimeMax)
        amberMsgs.push(
          `Line ${n}: ₹ ${formatINR(amt)} to a one-time buyer (limit ₹ ${formatINR(oneTimeMax)}) — a sale this size probably deserves a named party.`,
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
      const st = receiptStats[e.party];
      if (
        st &&
        st.times_received >= 3 &&
        amt > st.max_received * partyWarnMult
      ) {
        const pname = partyByCode.get(e.party.toUpperCase())?.name ?? e.party;
        amberMsgs.push(
          `Line ${n}: ₹ ${formatINR(amt)} from ${pname} — the most they have ever brought in is ₹ ${formatINR(st.max_received)} across ${st.times_received} times. Check the figure.`,
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
      setDraft({ ...draft, qty: "", amount: "" });
    } else {
      setLines((ls) => [...ls, draft]);
      // §5: the next line opens as a copy of this one. Amount and qty clear
      // (they belong to the line); NARRATION CARRIES FORWARD — one slip
      // covering several sales is one narration, not several.
      setDraft({ ...draft, qty: "", amount: "" });
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
    setDraft({ ...emptyLine(), cost_nature: draft.cost_nature || costNatureDefault });
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
      setDraft({ ...emptyLine(), cost_nature: draft.cost_nature || costNatureDefault });
    } else if (editingIndex !== null && editingIndex > i) {
      setEditingIndex(editingIndex - 1); // indices shift when a row leaves
    }
    setLines((ls) => ls.filter((_, idx) => idx !== i));
    setArmed(false);
  }

  // ---- payload -------------------------------------------------------------

  function buildPayload(): SalesInvoiceLine[] {
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
        // no capex_flag: the DB default (RECURRING) applies — a receipt is
        // not spending, and an asset sale is the journal's job (§17.4).
        cost_nature: e.costNature || null,
        qty: num(l.qty),
        unit: l.unit || null,
        rate: num(l.rate),
        received_cr: num(l.amount)!,
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
    const result = await saveSalesInvoice(buildPayload());
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
      setDraft({ ...emptyLine(), cost_nature: draft.cost_nature || costNatureDefault });
      setAmountTouched(false);
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
    defaultEntity: string | null,
  ) {
    setPartyBusy(true);
    setPartyErr(null);
    const res = await createParty(
      code,
      name,
      kind,
      mobile || null,
      defaultEntity,
    );
    setPartyBusy(false);
    if (!res.ok) {
      setPartyErr(res.message);
      return;
    }
    setParties((ps) =>
      [...ps, { ...res.party }].sort((a, b) => a.name.localeCompare(b.name)),
    );
    setHeaderParty(res.party.party_code);
    setOneTime(false); // naming a party is the opposite of a one-time payee
    if (res.party.default_entity && lines.length === 0) {
      setD("entity", res.party.default_entity);
    }
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
    date: "Invoice date",
    mode: "Mode",
    onetime: "One-time buyer",
    pfrom: "Period from",
    pto: "Period to",
    party: "Buyer",
    entity: "Entity",
    farm: "Farm",
    block: "Block",
    costobject: "Cost object",
    activity: "Activity",
    qty: "Qty sold",
    unit: "Unit",
    rate: "Rate",
    amount: "Invoice amount",
    narration: "Narration",

    linecostnature: "Cost nature",
  };

  function helpFor(key: string | null): string {
    switch (key) {
      case "date":
        return 'Invoice date, DD/MM/YYYY — or just "19" for the 19th of this month, "19/6", "1907". The line below shows how it will be read.';
      case "mode": {
        const base =
          "How this sale is settled. CASH or a bank mode means the money is in now; ON CREDIT means the buyer owes it and his balance rises until he pays. Bank and credit modes both need a party.";
        return modeRow?.notes ? `${base}  ·  ${mode}: ${modeRow.notes}` : base;
      }

      case "pfrom":
        return "First day this money covers — for a sale, usually the day itself; for lease rent, the period it pays for. Required; every line inherits it.";
      case "pto":
        return "Last day this money covers. Required. Same-day sale: same as period from.";
      case "party":
        return "Who the money came from. Type to search — the regular traders are one keystroke. Nothing matches? The last row adds what you typed as a new party. A passer-by you will never see again? Tick one-time instead.";
      case "onetime":
        return `Someone who will not pay you again — a stranger buying a load of firewood. Their NAME goes in the narration (${vagueNarrationMin}+ characters), the line is flagged for review, and above ₹ ${formatINR(oneTimeMax)} you will be nudged to name a real party. Not available on credit — nobody in particular cannot owe you money.`;
      case "entity":
        return "BUSINESS = farm income — sales, lease, recoveries. PERSONAL = household money in. FUNDING = OWNER MONEY COMING IN — it is capital, NEVER income (§13); pair it with the owner capital activity. The database refuses funding filed under an income head, and refuses business money into a capital head.";
      case "farm":
        return "Which farm this line belongs to.";
      case "block":
        return "Block within the farm, where the survey has named them. Leaving YET TO ASSIGN on a farm that has blocks saves, but is flagged for review.";
      case "costobject":
        return "What was sold or what the money relates to — the crop, LAND for lease rent. Type to search.";
      case "activity": {
        const a = activityByCode.get(draft.activity);
        let base = "What brought the money in — produce sale, lease rent, owner capital. Type to search.";
        if (a?.required_unit) base += `  ·  ${a.code} expects ${a.required_unit}.`;
        if (a?.notes) base += `  ·  ${a.notes}`;
        if (vagueActivities.includes(draft.activity))
          base += `  ·  Vague head: narration of ${vagueNarrationMin}+ characters required, and the line is flagged.`;
        return base;
      }
      case "qty": {
        const a = activityByCode.get(draft.activity);
        return a?.required_unit
          ? `How much was SOLD — ${a.code} is counted in ${a.required_unit}. This is the number the realisation rate and yield per acre are built from. Blank saves, but is flagged. A genuine lumpsum (a chopped tree): qty 1, unit LUMPSUM.`
          : "How much was sold — nuts, litres, loads. Fill it whenever it exists: no quantity means no realisation rate later.";
      }
      case "unit":
        return "What the quantity is counted in. Fills itself from the activity where the master says so — change it if this sale is different. LUMPSUM exists for the sale with no natural count.";
      case "rate":
        return draft.unit
          ? `₹ per ${draft.unit} — the price agreed. Amount fills itself as quantity × rate; overtype it if the slip says otherwise, and the mismatch becomes the realisation warning.`
          : "₹ per unit sold. Amount fills itself as quantity × rate.";
      case "amount":
        return "₹ this line comes to — received now on a cash sale, owed by the buyer on a credit one. Enter commits the line and opens the next.";
      case "narration": {
        const floor = narrFloor(draft.activity);
        return `Say what the boxes cannot — which part of the block, why it was needed, the chemical and dose, anything unusual. At least ${floor} characters. Do not repeat the farm, crop or labour count: those are already recorded. Copies into the next line.`;
      }
      case "linecostnature": {
        const cn = (masters["COST_NATURE"] ?? []).find(
          (c) => c.code === draft.cost_nature,
        );
        const base =
          "A cost classification the schema still asks of every transaction row. A sale has none, so this screen sends OTHER without asking (§16.3).";
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
        <h1 className="text-2xl font-semibold">Sales invoice</h1>
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
          <label className={labelCls}>Invoice date</label>
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
            Buyer{partyRequired ? " (required)" : ""}
          </label>
          <Combo
            value={headerParty}
            display={
              oneTime
                ? "— one-time buyer —"
                : headerParty
                  ? (partyByCode.get(headerParty.toUpperCase())?.name ??
                    headerParty)
                  : ""
            }
            onChange={(v) => {
              setHeaderParty(v);
              setOneTime(false);
              setArmed(false);
              // File 10: the party's usual entity PRE-FILLS the line. It never
              // enforces — the shopkeeper sells fertiliser (BUSINESS) and
              // household groceries (PERSONAL), same party, both entities. So
              // this only fills the draft, and only while no line is committed;
              // once she has started a voucher, changing the payee must not
              // quietly re-file the work she has already described.
              const de = partyByCode.get(v.toUpperCase())?.default_entity;
              if (de && lines.length === 0) setD("entity", de);
            }}
            options={parties.map((p) => ({
              code: p.party_code,
              label: p.name,
              sub: p.party_code,
            }))}
            placeholder={
              oneTime ? "one-time — untick to name a party" : "type name — pick, or add new…"
            }
            onFocus={() => setFocusKey("party")}
            // No add-new path while the toggle is on: creating a party at the
            // moment the line declares it has none is two contradictory
            // answers to "who got the money".
            onAddNew={oneTime ? undefined : openAddParty}
            inputRef={partyInputRef}
            disabled={oneTime}
          />
          {/* The one-off escape hatch, same design as payments. Unavailable
              on credit — nobody in particular cannot owe YOU money either. */}
          <label
            className={
              "flex items-center gap-1.5 mt-1 text-sm " +
              (modeKind === "CREDIT"
                ? "text-muted-foreground/50 cursor-not-allowed"
                : "text-muted-foreground cursor-pointer")
            }
            title={
              modeKind === "CREDIT"
                ? "Not on credit — nobody in particular cannot owe you money"
                : "Someone who will not pay you again. Their name goes in the narration."
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
                  // Abandon any half-typed new party: the two states are
                  // mutually exclusive and the screen must say so.
                  setAddingParty(null);
                  setPartyErr(null);
                }
                setArmed(false);
                setFocusKey("onetime");
              }}
            />
            One-time buyer
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
          partyKinds={partyKinds}
          // The receipt screen's common case: the person in front of you is
          // usually buying produce. The panel resolves this against the
          // loaded list; absent falls back to the first kind.
          defaultKind="CUSTOMER"
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
              setDraft({
                ...emptyLine(),
                narration: draft.narration,
                cost_nature: draft.cost_nature || costNatureDefault,
              });
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
          {/* Entity is BUSINESS on almost every sale — kept last in the
              band. No Capex field here: a sale is not spending, the DB
              default applies, and an asset sale is the journal's job
              (§17.4). FUNDING is the one that matters: owner money in is
              capital, never income, and the help strip teaches it. */}
          <div className="md:col-span-2">
            <label className={labelCls}>Entity</label>
            <Sel
              value={draft.entity}
              onChange={(v) => setD("entity", v)}
              options={ENTITIES.map((e) => ({ code: e, label: e }))}
              onFocus={() => setFocusKey("entity")}
            />
          </div>
        </FieldBand>

        {/* -------- WHAT WAS SOLD, UNDER WHICH HEAD -------- */}
        <FieldBand title="Income head">
          <div className="md:col-span-6">
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
              placeholder="e.g. produce sale, lease, owner capital…"
              onFocus={() => setFocusKey("activity")}
            />
          </div>
          {/* COST NATURE IS NOT SHOWN HERE (20-07-2026). It classifies a KIND
              OF SPENDING — labour, material, machine hire — and a sale has
              none. §16.3 already records that it drives nothing in the
              accounting layer. The database still requires the column on a
              TRANSACTION row, so the screen sends the master's OTHER without
              asking: a field whose answer is always the same trains the eye to
              skip fields, and the eye is what the red/amber panel depends on.
              Tidy owed — fn_save_voucher should require cost nature only where
              the resolved account is an EXPENSE, and then this can go. */}
        </FieldBand>

        {/* -------- WHAT WAS SOLD, AND HOW MUCH OF IT -------- */}
        <FieldBand title="What was sold">
          <div className="md:col-span-2">
            <label className={labelCls}>Cost object (crop / land)</label>
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
              How much sold
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
            nuts, litres, loads, trees — the number every realisation rate and
            yield per acre is built from. A genuine lumpsum: qty 1, unit
            LUMPSUM, no flag.
          </BandHint>
        </FieldBand>

        {/* -------- THE AMOUNT -------- */}
        <FieldBand title="Amount">
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
              Invoice amount ₹
              {oneTime && (
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
            {modeKind === "CREDIT"
              ? "ON CREDIT: no money moves today. This raises what the buyer owes, and it falls when he pays through a receipt."
              : "Cash or bank: the money is in now and cash in hand moves."}{" "}
            {draft.unit
              ? `₹ per ${draft.unit} × how much sold. Amount fills itself — overtype if the slip differs, and the gap becomes the realisation warning.`
              : "Amount fills itself as quantity × rate once both are in."}
          </BandHint>
        </FieldBand>

        {/* -------- WHY --------
            NO LINE-LEVEL BUYER HERE (removed 20-07-2026, owner ruling).
            It was inherited from the payment screen, where the paper justifies
            it: one muster slip lists twenty labourers, so one voucher carries
            twenty lines and twenty payees. An INVOICE is the opposite kind of
            document — it is addressed to ONE buyer. Tally enforces the same
            thing: a sales voucher has exactly one Party A/c name, and nuts
            split between two traders is two invoices, not one with two lines.

            The risk was not cosmetic. On ON CREDIT every line raises a debtor
            balance, so two parties on one invoice would have moved two
            people's balances under a single invoice number, with nothing
            downstream able to say whose invoice it was.

            Lines still earn their keep — 500 coconuts and 40 kg of copra to
            the same buyer is two crops, two quantities, one invoice. On an
            invoice a line is a different THING SOLD, never a different person.

            The rule this generalises to: a line-level party override belongs
            only where the paper document genuinely names several people. A
            muster does. An invoice never does.

            party_code is gone from EditLine altogether, not left blank in the
            type: a permanently-empty field is how the vestigial headerPayee
            accumulated on the payment screen, and one vestige per screen is
            how a file becomes unreadable. eff() now reads the header buyer
            directly. ------------------------------------------------- */}
        <FieldBand title="Why">
          <div className="md:col-span-6">
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
                oneTime
                  ? "name the person and what they bought"
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
