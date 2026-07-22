// https://github.com/rjshvjy/farm-software/blob/main/app/expense/ExpenseVoucher.tsx
// app/expense/ExpenseVoucher.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the business expense voucher screen (§19).
//
// THE SHAPE (§19.1, and the reason this screen exists):
//
//   VOUCHER   one payment, one serial          — the header, typed once
//   TASK      one piece of work: where, what,
//             how much of it                   — one numbered working on the
//                                                back of the paper
//   ROW       one person on that task,
//             days x rate                      — one line of that working
//
// The estate's weekly wage paper is a bundle of ~13 workings, each with its
// own place, work, measured output and several people at different rates
// (§16.23). The old flat screen could not express that without repeating the
// acreage on every labour row — which would report 22½ acres irrigated where
// 7½ were (§19.4). The screen should look like the paper, so checking her work
// is a matter of reading down two columns (build handover, Part Six).
//
// THE CONTRACT (§5, unchanged): this screen collects fields, calls
// saveExpenseVoucher, and DISPLAYS EVERYTHING that comes back. The rules live
// in the database. The screen PREVIEWS them — the red/amber panel — using
// thresholds handed to it from config, so she fixes a refusal before the
// round-trip; but the database re-derives everything and its verdict always
// wins and is always shown.
//
// WHAT THE SCREEN DELIBERATELY NEVER SENDS:
//   - task_no        the function numbers tasks and puts the work quantity on
//                    each task's first row. The screen cannot get that wrong
//                    if it never sends it (§19.4).
//   - entity         forced to BUSINESS in the action (§19.2).
//   - farm/block on a non-land cost object — the boxes are greyed out and
//                    cleared (owner ruling 21/07: greyed, not hidden, so she
//                    learns WHY they are not asked; a disabled field still
//                    cannot be answered wrongly, which is Part 0.5's intent).
//
// ROW BOXES FOLLOW THE TASK'S COST NATURE (§19.3 — no ENGAGEMENT_TYPE master):
//   LABOUR              days x rate = amount
//   CONTRACT            rate x the TASK's quantity = amount, or a lump amount
//   everything else     a single amount
//   Amount always computes and stays directly editable — overtype if the slip
//   differs (§5). Contract and lump rows carry no mandays, and
//   mandays-per-acre knowingly understates on contract work (§19.3).
//
// LINE NUMBERS: the database numbers LINES, not tasks — three tasks of two
// people each refuses at "Line 5", the first row of task 3. This screen maps
// that back to the task and row and highlights the right box.
// ---------------------------------------------------------------------------
"use client";

import React, { useMemo, useRef, useState } from "react";
import { formatDMY, parseDMY, formatINR } from "@/lib/dates";
import {
  saveExpenseVoucher,
  createExpenseParty,
  type ExpenseHeader,
  type ExpenseTask,
  type ExpenseRow,
} from "./expense-actions";

// ---------------------------------------------------------------------------
// Prop types. page.tsx imports these, so they are exported.
// ---------------------------------------------------------------------------

export type MasterRow = {
  list_name: string;
  code: string;
  label: string;
  /** Comma-separated search terms (§3F2). "cow" must find MILKING WAGES. */
  aliases: string | null;
  sort_order: number;
  required_unit: string | null;
  mode_kind: string | null;
  parent_farm: string | null;
  notes: string | null;
  group_code: string | null;
  is_heading: boolean;
  land_based: boolean;
};

export type PartyRow = {
  party_code: string;
  name: string;
  kind: string;
  default_entity: string | null;
  default_rate: number | null;
  labour_category: string | null;
  usual_farm: string | null;
};

export type PartyKindRow = {
  code: string;
  label: string;
  group_label: string | null;
  default_entity: string | null;
  sort_order: number;
};

export type JobRow = {
  job_id: string;
  description: string;
  farm: string;
  cost_object: string | null;
  start_date: string;
};

type Props = {
  masters: Record<string, MasterRow[]>;
  parties: PartyRow[];
  jobs: JobRow[];
  today: string; // ISO, from fn_today() — the estate's date, never the browser's
  vagueActivities: string[];
  unsplitFarms: string[]; // config UNSPLIT_FARMS (file 18a) — e.g. GENERAL
  narrationMin: number;
  vagueNarrationMin: number;
  sampleMode: boolean;
  oneTimeMax: number;
  lineAmountWarn: number;
  partyWarnMult: number;
  partyStats: Record<
    string,
    { times_paid: number; max_paid: number; avg_paid: number; last_paid: string }
  >;
  partyKinds: PartyKindRow[];
  initialPocketBalances: Record<string, number>;
  userEmail: string;
};

// ---------------------------------------------------------------------------
// Edit-state types. Everything is a STRING while editing (so "8.5" and a
// half-typed "21/07" are representable); conversion happens once, at save.
// ---------------------------------------------------------------------------

type EditRow = {
  key: number; // stable React key; never reused within a session
  party_code: string;
  oneTime: boolean;
  mandays: string;
  rate: string;
  amount: string;
  mode: string; // "" = inherit the header pocket
  narration: string; // "" = inherit the task narration
};

type EditTask = {
  key: number;
  farm: string;
  block: string;
  cost_object: string;
  activity: string;
  capex_flag: string;
  cost_nature: string;
  qty: string;
  unit: string;
  job_id: string;
  narration: string;
  paperTotal: string; // the task's own total off the paper; "" = not typed
  rows: EditRow[];
};

// One red or amber finding, addressed to a place on the screen.
type Finding = {
  level: "red" | "amber";
  text: string;
  taskIdx: number | null; // null = header / voucher level
  rowIdx: number | null;
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** "1234.5" -> 1234.5, ""/garbage -> null. Never NaN out of this function. */
function num(s: string): number | null {
  const t = s.trim();
  if (t === "") return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

/**
 * Auto-insert the slashes of DD/MM/YYYY as digits are typed, without fighting
 * deletion or the shorthand parseDMY accepts (21/7, 21/7/26). Slashes are only
 * ADDED at the natural boundaries; whatever the user types herself is left be.
 */
function autoSlashDMY(prev: string, next: string): string {
  if (next.length < prev.length) return next; // deleting - do not fight it
  const v = next.replace(/\/{2,}/g, "/");
  if (/^\d{2}$/.test(v)) return v + "/";
  if (/^\d{3}$/.test(v)) return v.slice(0, 2) + "/" + v[2];
  if (/^\d{2}\/\d{2}$/.test(v)) return v + "/";
  if (/^\d{2}\/\d{3}$/.test(v)) return v.slice(0, 5) + "/" + v.slice(5);
  return v;
}

/**
 * Amount in words, Indian system — the extra-zero catcher under the voucher
 * total (§5). Whole rupees only; paise are not read aloud on a wage paper.
 */
function inrWords(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "";
  const whole = Math.round(n);
  if (whole === 0) return "zero rupees";
  const ones = [
    "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
  ];
  const tens = [
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
    "eighty", "ninety",
  ];
  const two = (x: number): string =>
    x < 20 ? ones[x] : tens[Math.floor(x / 10)] + (x % 10 ? " " + ones[x % 10] : "");
  const three = (x: number): string =>
    (x >= 100 ? ones[Math.floor(x / 100)] + " hundred" + (x % 100 ? " " : "") : "") +
    (x % 100 ? two(x % 100) : "");
  let out = "";
  const crore = Math.floor(whole / 10000000);
  const lakh = Math.floor((whole % 10000000) / 100000);
  const thousand = Math.floor((whole % 100000) / 1000);
  const rest = whole % 1000;
  if (crore) out += two(crore) + " crore ";
  if (lakh) out += two(lakh) + " lakh ";
  if (thousand) out += two(thousand) + " thousand ";
  if (rest) out += three(rest);
  return out.trim() + " rupees";
}

// ---------------------------------------------------------------------------
// Combo — type-ahead over a long list. Self-contained rather than imported
// from app/entry (that folder is marked for deletion; importing from it would
// turn a tidy-up into a breakage). Same behaviour: type to filter, arrows to
// move, Enter to pick, Escape to close. Never pre-selects (§5A).
// ---------------------------------------------------------------------------

type ComboItem = {
  code: string;
  label: string;
  hint?: string;
  /**
   * Extra words this item should be findable by (§3F2). NOT displayed — the
   * list stays readable; only the matching widens. Seeded in SQL files 19 and
   * 20 after reading three years of narrations: typing "cow", "goat", "sheep",
   * "Dr fees" or "seema pul" returned NOTHING before this, because no
   * livestock activity contains those words in its code or label.
   */
  search?: string | null;
  /**
   * The section this item sits under when the list is browsed unfiltered
   * (§16.13 group_code). Items with a group render under headings, like the
   * add-person select; items without one render as a plain flat list. Only
   * affects the EMPTY/browse view — typing collapses everything to one ranked
   * list regardless of group.
   */
  group?: string | null;
  /**
   * When true, this item's whole GROUP floats to the top of the browse list
   * (e.g. livestock activities once COW/GOAT is the cost object). Promote, do
   * NOT hide: FREIGHT for cattle feed is not a livestock activity but must
   * stay reachable, so nothing is filtered out — the relevant group just
   * leads.
   */
  promoteGroup?: boolean;
};

function Combo({
  items,
  value,
  onPick,
  placeholder,
  disabled,
  onFocusHelp,
  invalid,
}: {
  items: ComboItem[];
  value: string;
  onPick: (code: string) => void;
  placeholder?: string;
  disabled?: boolean;
  onFocusHelp?: () => void;
  invalid?: boolean;
}) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const boxRef = useRef<HTMLInputElement>(null);

  const chosen = items.find((i) => i.code === value) ?? null;
  const shown = open ? text : chosen ? chosen.label : "";

  // TYPING -> one flat, ranked list (spec §690: ranked by use, matched on
  // substring, aliases included). BROWSING (empty box) -> the whole list,
  // grouped under headings, so she can SEE there are 78 activities and scroll,
  // instead of the first twelve with no sign of more.
  const typing = text.trim() !== "";

  const flatMatches = useMemo(() => {
    const q = text.trim().toUpperCase();
    if (!q) return [];
    return items.filter(
      (i) =>
        i.code.toUpperCase().includes(q) ||
        i.label.toUpperCase().includes(q) ||
        (i.search ?? "").toUpperCase().includes(q),
    );
    // No .slice: the list scrolls. Hiding matches is how "cow" looked broken.
  }, [items, text]);

  // Browse view: items bucketed by group, groups alphabetical, items
  // alphabetical within each — predictable to scan (SAMPLE mode has no usage
  // data to rank by anyway). A promoted group leads; ungrouped items, if any,
  // fall under a final "Other" heading rather than vanishing.
  const grouped = useMemo(() => {
    if (typing) return [];
    const buckets: Record<string, ComboItem[]> = {};
    let promoted: string | null = null;
    for (const i of items) {
      const g = i.group || "Other";
      (buckets[g] ??= []).push(i);
      if (i.promoteGroup && i.group) promoted = i.group;
    }
    let names = Object.keys(buckets).sort((a, b) => a.localeCompare(b));
    if (promoted)
      names = [promoted, ...names.filter((n) => n !== promoted)];
    return names.map((name) => ({
      name,
      items: buckets[name].sort((a, b) => a.label.localeCompare(b.label)),
    }));
  }, [items, typing]);

  // A single flat sequence of the currently-visible codes, so arrow keys and
  // Enter work identically whether browsing or typing.
  const visibleCodes = useMemo(
    () =>
      typing
        ? flatMatches.map((m) => m.code)
        : grouped.flatMap((g) => g.items.map((m) => m.code)),
    [typing, flatMatches, grouped],
  );

  function pick(code: string) {
    onPick(code);
    setOpen(false);
    setText("");
  }

  return (
    <div className="relative">
      <input
        ref={boxRef}
        type="text"
        value={shown}
        placeholder={placeholder}
        disabled={disabled}
        onFocus={() => {
          setOpen(true);
          setText("");
          setHi(0);
          onFocusHelp?.();
        }}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
        onChange={(e) => {
          setText(e.target.value);
          setOpen(true);
          setHi(0);
        }}
        onKeyDown={(e) => {
          if (!open) return;
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setHi((h) => Math.min(h + 1, visibleCodes.length - 1));
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            setHi((h) => Math.max(h - 1, 0));
          } else if (e.key === "Enter") {
            e.preventDefault();
            if (visibleCodes[hi]) pick(visibleCodes[hi]);
          } else if (e.key === "Escape") {
            setOpen(false);
          }
        }}
        className={
          "w-full border rounded px-2 py-1.5 bg-background text-sm " +
          (invalid ? "border-red-500 " : "border-input ") +
          (disabled ? "opacity-50 cursor-not-allowed bg-muted" : "")
        }
      />
      {open && (typing ? flatMatches.length > 0 : grouped.length > 0) && (
        <div className="absolute z-20 mt-1 w-full max-h-72 overflow-auto border border-input rounded bg-popover shadow">
          {typing
            ? flatMatches.map((m, i) => (
                <button
                  key={m.code}
                  type="button"
                  onMouseDown={(e) => {
                    e.preventDefault();
                    pick(m.code);
                  }}
                  className={
                    "block w-full text-left px-2 py-1.5 text-sm " +
                    (i === hi ? "bg-muted" : "hover:bg-muted/60")
                  }
                >
                  <span className="font-medium">{m.label}</span>
                  {m.hint ? (
                    <span className="text-muted-foreground"> · {m.hint}</span>
                  ) : null}
                </button>
              ))
            : (() => {
                // Browse view. A running counter maps each rendered row back to
                // its flat index in visibleCodes, so highlight tracks the
                // keyboard across section headers.
                let flat = -1;
                return grouped.map((section) => (
                  <div key={section.name}>
                    <div className="sticky top-0 bg-muted/95 backdrop-blur px-2 py-1 text-xs font-medium text-muted-foreground border-b border-border">
                      {section.name}
                    </div>
                    {section.items.map((m) => {
                      flat += 1;
                      const idx = flat;
                      return (
                        <button
                          key={m.code}
                          type="button"
                          onMouseDown={(e) => {
                            e.preventDefault();
                            pick(m.code);
                          }}
                          className={
                            "block w-full text-left px-2 py-1.5 text-sm " +
                            (idx === hi ? "bg-muted" : "hover:bg-muted/60")
                          }
                        >
                          <span className="font-medium">{m.label}</span>
                          {m.hint ? (
                            <span className="text-muted-foreground">
                              {" "}
                              · {m.hint}
                            </span>
                          ) : null}
                        </button>
                      );
                    })}
                  </div>
                ));
              })()}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

/**
 * What does the rate in this row MEAN right now? Days filled -> per day. Days
 * blank -> per unit of the TASK's quantity, named from the task's unit, so the
 * column reads "Rate ₹/tree", "Rate ₹/head", "Rate ₹/acre" instead of leaving
 * her to infer it from an empty box two columns to the left.
 */
function rateBasis(t: EditTask, r: EditRow): string {
  if (num(r.mandays) !== null) return "/day";
  if (t.unit) return "/" + t.unit.toLowerCase();
  return "";
}

let nextKey = 1;
function freshRow(): EditRow {
  return {
    key: nextKey++,
    party_code: "",
    oneTime: false,
    mandays: "",
    rate: "",
    amount: "",
    mode: "",
    narration: "",
  };
}
function freshTask(from?: EditTask): EditTask {
  // Carry-forward (§19.6, build handover §2.5): a new task inherits farm,
  // block, cost object and cost nature from the task above — the same paper
  // usually stays on one farm. Work-specific fields start clean.
  return {
    key: nextKey++,
    farm: from?.farm ?? "",
    block: from?.block ?? "",
    cost_object: from?.cost_object ?? "",
    activity: "",
    capex_flag: from?.capex_flag ?? "RECURRING",
    cost_nature: from?.cost_nature ?? "",
    qty: "",
    unit: "",
    job_id: "",
    narration: "",
    paperTotal: "",
    rows: [freshRow()],
  };
}

export default function ExpenseVoucher({
  masters,
  parties: initialParties,
  jobs,
  today,
  vagueActivities,
  unsplitFarms,
  narrationMin,
  vagueNarrationMin,
  sampleMode,
  oneTimeMax,
  lineAmountWarn,
  partyWarnMult,
  partyStats,
  partyKinds,
  initialPocketBalances,
  userEmail,
}: Props) {
  // ---- master lists, prepared once ---------------------------------------
  const farms = masters["FARM"] ?? [];
  const blocks = masters["BLOCK"] ?? [];
  const costObjects = masters["COST_OBJECT"] ?? [];
  const activities = masters["ACTIVITY"] ?? [];
  const costNatures = masters["COST_NATURE"] ?? [];
  const capexFlags = masters["CAPEX_FLAG"] ?? [];
  const units = masters["UNIT"] ?? [];
  const modes = masters["MODE"] ?? [];

  const modeKind = useMemo(() => {
    const m: Record<string, string> = {};
    for (const r of modes) if (r.mode_kind) m[r.code] = r.mode_kind;
    return m;
  }, [modes]);

  const landBased = useMemo(() => {
    const m: Record<string, boolean> = {};
    for (const r of costObjects) m[r.code] = r.land_based;
    return m;
  }, [costObjects]);

  const requiredUnit = useMemo(() => {
    const m: Record<string, string | null> = {};
    for (const r of activities) m[r.code] = r.required_unit;
    return m;
  }, [activities]);

  const masterNotes = useMemo(() => {
    const m: Record<string, string> = {};
    for (const list of Object.values(masters))
      for (const r of list) if (r.notes) m[`${r.list_name}:${r.code}`] = r.notes;
    return m;
  }, [masters]);

  // ---- header state (typed once per paper slip) ---------------------------
  const [dateText, setDateText] = useState(formatDMY(today));
  const [periodFromText, setPeriodFromText] = useState("");
  const [periodToText, setPeriodToText] = useState("");
  const [headerMode, setHeaderMode] = useState("");
  const [docRefNo, setDocRefNo] = useState("");
  const [docRefDateText, setDocRefDateText] = useState("");
  const [paperTotalText, setPaperTotalText] = useState("");

  // ---- tasks --------------------------------------------------------------
  const [tasks, setTasks] = useState<EditTask[]>([freshTask()]);

  // ---- parties (grows when one is added inline) ---------------------------
  const [parties, setParties] = useState<PartyRow[]>(initialParties);
  const partyByCode = useMemo(() => {
    const m: Record<string, PartyRow> = {};
    for (const p of parties) m[p.party_code] = p;
    return m;
  }, [parties]);

  // ---- inline add-party panel ---------------------------------------------
  const [addPartyFor, setAddPartyFor] = useState<{
    taskIdx: number;
    rowIdx: number;
  } | null>(null);
  const [npName, setNpName] = useState("");
  const [npCode, setNpCode] = useState("");
  const [npKind, setNpKind] = useState("");
  const [npBusy, setNpBusy] = useState(false);
  const [npError, setNpError] = useState<string | null>(null);

  // ---- pockets, save state, session ---------------------------------------
  const [pocketBalances, setPocketBalances] = useState(initialPocketBalances);
  const [saving, setSaving] = useState(false);
  const [confirmArmed, setConfirmArmed] = useState(false);
  const [dbError, setDbError] = useState<string | null>(null);
  const [savedThisSession, setSavedThisSession] = useState<
    { voucher_no: string; total: number; warnings: string[] }[]
  >([]);
  const [help, setHelp] = useState<string>(
    "Fill the header once — every task inherits it. Tab moves forward; Enter on an amount adds the next person.",
  );

  // ---- helpers over state --------------------------------------------------
  function patchTask(i: number, patch: Partial<EditTask>) {
    setTasks((ts) => ts.map((t, k) => (k === i ? { ...t, ...patch } : t)));
    setConfirmArmed(false);
    setDbError(null);
  }
  function patchRow(i: number, j: number, patch: Partial<EditRow>) {
    setTasks((ts) =>
      ts.map((t, k) =>
        k === i
          ? { ...t, rows: t.rows.map((r, l) => (l === j ? { ...r, ...patch } : r)) }
          : t,
      ),
    );
    setConfirmArmed(false);
    setDbError(null);
  }
  function addRow(i: number) {
    setTasks((ts) =>
      ts.map((t, k) => (k === i ? { ...t, rows: [...t.rows, freshRow()] } : t)),
    );
  }
  function removeRow(i: number, j: number) {
    setTasks((ts) =>
      ts.map((t, k) =>
        k === i ? { ...t, rows: t.rows.filter((_, l) => l !== j) } : t,
      ),
    );
  }
  function addTask() {
    setTasks((ts) => [...ts, freshTask(ts[ts.length - 1])]);
  }
  function removeTask(i: number) {
    setTasks((ts) => ts.filter((_, k) => k !== i));
  }

  /**
   * Which task and row does "Line N" in a database refusal point at? The
   * database numbers LINES, not tasks — three tasks of two people each refuses
   * at "Line 5", the first row of task 3.
   */
  const dbErrorLine: { taskIdx: number; rowIdx: number } | null = useMemo(() => {
    if (!dbError) return null;
    const m = dbError.match(/Line (\d+)/);
    if (!m) return null;
    let n = parseInt(m[1], 10);
    for (let i = 0; i < tasks.length; i++) {
      if (n <= tasks[i].rows.length) return { taskIdx: i, rowIdx: n - 1 };
      n -= tasks[i].rows.length;
    }
    return null;
  }, [dbError, tasks]);

  // ---- derived: totals -----------------------------------------------------
  const taskSums = tasks.map((t) =>
    t.rows.reduce((s, r) => s + (num(r.amount) ?? 0), 0),
  );
  const voucherTotal = taskSums.reduce((a, b) => a + b, 0);
  const paperTotal = num(paperTotalText);

  // ---- derived: the red/amber preview (§5, extended for §19) --------------
  // Mirrors the database's rules using the same thresholds it was handed.
  // The DB re-derives everything at save and its verdict always wins.
  const findings: Finding[] = useMemo(() => {
    const out: Finding[] = [];
    const red = (text: string, taskIdx: number | null = null, rowIdx: number | null = null) =>
      out.push({ level: "red", text, taskIdx, rowIdx });
    const amber = (text: string, taskIdx: number | null = null, rowIdx: number | null = null) =>
      out.push({ level: "amber", text, taskIdx, rowIdx });

    // -- header ------------------------------------------------------------
    const isoDate = parseDMY(dateText);
    const isoFrom = parseDMY(periodFromText);
    const isoTo = parseDMY(periodToText);
    if (!isoDate) red("Payment date is not a date (DD/MM/YYYY).");
    if (!isoFrom || !isoTo)
      red("Period from and period to are both needed — set them once, every task inherits them.");
    else if (isoTo < isoFrom) red("Period to is before period from.");
    if (!headerMode) red("Choose the default pocket — which pocket this paper was mostly paid from.");

    // -- tasks and rows ------------------------------------------------------
    tasks.forEach((t, i) => {
      const tno = i + 1;
      if (!t.cost_object) red(`Task ${tno}: a cost object is needed — what carries this.`, i);
      if (!t.activity) red(`Task ${tno}: an activity is needed — what was done.`, i);
      if (!t.cost_nature) red(`Task ${tno}: cost nature is needed — labour, material, contract…`, i);

      const isLand = t.cost_object ? (landBased[t.cost_object] ?? true) : true;
      if (isLand && !t.farm) red(`Task ${tno}: a farm is needed.`, i);

      // GENERAL (or any UNSPLIT farm): saves, and is counted (file 18a).
      if (t.farm && unsplitFarms.includes(t.farm))
        amber(
          `Task ${tno}: ${t.farm} covers more than one farm — this will be flagged FARM NOT SPLIT for splitting later.`,
          i,
        );

      // qty and unit go together (file 18a refusal).
      const qty = num(t.qty);
      if ((qty === null) !== (t.unit === ""))
        red(
          `Task ${tno}: quantity and unit go together — write both, or neither.`,
          i,
        );

      // Activity expects a unit and none written — flags, never blocks (§3F).
      const req = t.activity ? requiredUnit[t.activity] : null;
      if (req && qty === null)
        amber(`Task ${tno}: ${t.activity} expects ${req} — the quantity is not written. Saves flagged.`, i);

      // Block: only where the farm actually has blocks in the master.
      const farmHasBlocks = blocks.some((b) => b.parent_farm === t.farm);
      if (isLand && t.farm && farmHasBlocks && (!t.block || t.block === "YET TO ASSIGN"))
        amber(`Task ${tno}: ${t.farm} has blocks; none chosen. Saves flagged.`, i);

      // Vague head: flag once per task; the longer narration floor is per row.
      const vague = vagueActivities.includes(t.activity);
      if (vague)
        amber(`Task ${tno}: "${t.activity}" is a last resort — this will be flagged.`, i);

      // Task's own paper total vs its rows — the DB REFUSES a mismatch.
      const tPaper = num(t.paperTotal);
      if (tPaper !== null && Math.abs(tPaper - taskSums[i]) > 0.004)
        red(
          `Task ${tno}: the rows add to ${formatINR(taskSums[i])} but the task says ${formatINR(tPaper)}. One of them is wrong.`,
          i,
        );

      if (t.rows.length === 0) red(`Task ${tno}: a task with nobody on it records nothing.`, i);

      // Within-task duplicate: same person, same rate, twice (§19.5). The same
      // person under a DIFFERENT task stays silent — two jobs in one week is
      // the ordinary case on this paper.
      const seen: Record<string, number> = {};
      t.rows.forEach((r) => {
        if (!r.party_code) return;
        const k = `${r.party_code}|${r.rate.trim()}`;
        seen[k] = (seen[k] ?? 0) + 1;
      });
      for (const [k, c] of Object.entries(seen))
        if (c > 1)
          amber(
            `Task ${tno}: ${k.split("|")[0]} appears ${c} times at the same rate — probably one person entered twice.`,
            i,
          );

      t.rows.forEach((r, j) => {
        const where = `Task ${tno}, person ${j + 1}`;
        const amt = num(r.amount);
        const days = num(r.mandays);
        const rate = num(r.rate);
        const rowMode = r.mode || headerMode;
        const kind = rowMode ? modeKind[rowMode] : undefined;
        const effNarration = (r.narration || t.narration).trim();

        // Amount: must exist and be positive (file 18a refusal).
        if (amt === null || amt <= 0)
          red(`${where}: an amount is needed and must be more than zero.`, i, j);

        // Narration floor: 5 always; 15 on a vague head or a one-time person.
        const floor = vague || r.oneTime ? vagueNarrationMin : narrationMin;
        if (effNarration.length < floor)
          red(
            r.oneTime
              ? `${where}: a one-time person needs the NAME in the narration — who was paid, for what. At least ${floor} characters.`
              : `${where}: narration of at least ${floor} characters (task narration counts unless the row has its own).`,
            i,
            j,
          );

        // Party rules by pocket kind.
        if (kind === "BANK" && !r.party_code)
          red(`${where}: a bank payment needs a party — the statement will name who was paid.`, i, j);
        if (kind === "CREDIT" && !r.party_code)
          red(`${where}: money owed must be owed to somebody — credit needs a party.`, i, j);
        if (kind === "CREDIT" && r.oneTime)
          red(`${where}: a one-time person cannot be used on credit — there would be a debt owed to nobody.`, i, j);
        if (kind === "CASH" && !r.party_code && !r.oneTime)
          amber(`${where}: cash paid, nobody named — will be flagged NO PAYEE.`, i, j);
        if (r.oneTime)
          amber(`${where}: one-time person — flagged for the review queue; recurring names deserve a party.`, i, j);

        // Arithmetic (warnings, §5): days x rate per row; qty x rate on the
        // task's FIRST row only, and only when mandays is blank — a contract
        // task's quantity belongs to the task, not to each person.
        if (days !== null && rate !== null && amt !== null && Math.abs(days * rate - amt) > 0.004)
          amber(`${where}: amount ${formatINR(amt)} ≠ days × rate ${formatINR(days * rate)}.`, i, j);
        if (
          j === 0 &&
          days === null &&
          qty !== null &&
          rate !== null &&
          amt !== null &&
          Math.abs(qty * rate - amt) > 0.004
        )
          amber(`${where}: amount ${formatINR(amt)} ≠ quantity × rate ${formatINR(qty * rate)}.`, i, j);

        // Thresholds (§5A3).
        if (amt !== null && amt > lineAmountWarn)
          amber(`${where}: ${formatINR(amt)} is unusually large (threshold ${formatINR(lineAmountWarn)}).`, i, j);
        if (r.oneTime && amt !== null && amt > oneTimeMax)
          amber(`${where}: ${formatINR(amt)} to a one-time person (threshold ${formatINR(oneTimeMax)}) — probably deserves a named party.`, i, j);

        // The self-calibrating party pattern — per LABOURER now, because a
        // row is a person. Silent under 3 priors, sharper every month.
        if (r.party_code && amt !== null) {
          const st = partyStats[r.party_code];
          if (st && st.times_paid >= 3 && amt > st.max_paid * partyWarnMult)
            amber(
              `${where}: ${formatINR(amt)} to ${r.party_code} — their largest ever payment is ${formatINR(st.max_paid)} across ${st.times_paid} payments. Check the figure.`,
              i,
              j,
            );
        }
      });
    });

    // -- the voucher foot ----------------------------------------------------
    // Paper total vs lines: a WARNING, never a block — on the estate's real
    // weekly paper it SHOULD differ, because cooking wages is household. The
    // message says what is probably happening: this is the moment the
    // accountant learns the split, on her first real voucher (build handover
    // §2.7 — getting this message right matters more than it looks).
    if (paperTotal !== null && Math.abs(paperTotal - voucherTotal) > 0.004) {
      const diff = paperTotal - voucherTotal;
      amber(
        diff > 0
          ? `The paper says ${formatINR(paperTotal)} but the tasks add to ${formatINR(voucherTotal)} — ${formatINR(diff)} short. If that part is household (cooking, house repairs), it belongs on a Personal Drawings Voucher, not here.`
          : `The tasks add to ${formatINR(voucherTotal)} but the paper says ${formatINR(paperTotal)} — check for a line entered twice.`,
      );
    }

    return out;
  }, [
    tasks, dateText, periodFromText, periodToText, headerMode, paperTotalText,
    taskSums, voucherTotal, paperTotal, landBased, requiredUnit, modeKind,
    blocks, vagueActivities, unsplitFarms, narrationMin, vagueNarrationMin,
    oneTimeMax, lineAmountWarn, partyWarnMult, partyStats,
  ]);

  const reds = findings.filter((f) => f.level === "red");
  const ambers = findings.filter((f) => f.level === "amber");
  const canSave = reds.length === 0 && !saving;

  // ---- save ----------------------------------------------------------------
  async function doSave() {
    if (!canSave) return;
    // ALWAYS show the summary first, warnings or not (owner, 21/07). A saved
    // row is immutable (§6): it is superseded or reversed, never edited. The
    // one cheap moment to catch a wrong figure is before it exists.
    if (!confirmArmed) {
      setConfirmArmed(true);
      return;
    }
    setSaving(true);
    setDbError(null);

    const header: ExpenseHeader = {
      payment_date: parseDMY(dateText)!,
      period_from: parseDMY(periodFromText)!,
      period_to: parseDMY(periodToText)!,
      mode: headerMode,
      doc_ref_no: docRefNo.trim() || null,
      doc_ref_date: docRefDateText.trim() ? parseDMY(docRefDateText) : null,
      paper_total: paperTotal,
    };
    const payload: ExpenseTask[] = tasks.map((t) => {
      const isLand = t.cost_object ? (landBased[t.cost_object] ?? true) : true;
      return {
        // Farm and block are sent only where they are answerable (Part 0.5).
        farm: isLand ? t.farm || null : null,
        block: isLand ? t.block || null : null,
        cost_object: t.cost_object,
        activity: t.activity,
        capex_flag: t.capex_flag || "RECURRING",
        cost_nature: t.cost_nature,
        qty: num(t.qty),
        unit: t.unit || null,
        job_id: t.job_id || null,
        narration: t.narration.trim(),
        total: num(t.paperTotal),
        rows: t.rows.map<ExpenseRow>((r) => ({
          party_code: r.oneTime ? null : r.party_code || null,
          payee: r.oneTime ? "ONE TIME" : null,
          mandays: num(r.mandays),
          rate: num(r.rate),
          paid_out_dr: num(r.amount) ?? 0,
          mode: r.mode || null,
          narration: r.narration.trim() || null,
        })),
      };
    });

    const res = await saveExpenseVoucher(header, payload);
    setSaving(false);
    setConfirmArmed(false);

    if (!res.ok) {
      setDbError(res.message);
      return;
    }

    setSavedThisSession((s) => [
      { voucher_no: res.voucher_no, total: voucherTotal, warnings: res.warnings },
      ...s,
    ]);
    if (res.pocket_balance !== null && headerMode)
      setPocketBalances((b) => ({ ...b, [headerMode]: res.pocket_balance! }));

    // Fresh paper: keep the dates and pocket (batch working, §5 — the next
    // slip is usually from the same week), clear everything else.
    setDocRefNo("");
    setDocRefDateText("");
    setPaperTotalText("");
    setTasks([freshTask()]);
  }

  // ---- inline party add ----------------------------------------------------
  function openAddParty(taskIdx: number, rowIdx: number, typed: string) {
    setAddPartyFor({ taskIdx, rowIdx });
    setNpName(typed);
    setNpCode(
      typed
        .toUpperCase()
        .replace(/[^A-Z0-9 ]/g, "")
        .trim()
        .replace(/\s+/g, " "),
    );
    setNpKind("");
    setNpError(null);
  }
  async function submitAddParty() {
    if (!addPartyFor) return;
    const code = npCode.trim().toUpperCase();
    if (!code || !npName.trim() || !npKind) {
      setNpError("Code, name and kind are all needed.");
      return;
    }
    // fn_party_upsert OVERWRITES on a code collision by design, so the screen
    // owns the "use existing or create new?" question (it can ask; a database
    // cannot). A known code is offered for reuse instead of being sent.
    if (partyByCode[code]) {
      setNpError(
        `"${code}" already exists (${partyByCode[code].name}). Pick them from the list, or change the code.`,
      );
      return;
    }
    setNpBusy(true);
    const res = await createExpenseParty(code, npName.trim(), npKind);
    setNpBusy(false);
    if (!res.ok) {
      setNpError(res.message);
      return;
    }
    const p: PartyRow = {
      party_code: res.party.party_code,
      name: res.party.name,
      kind: res.party.kind,
      default_entity: res.party.default_entity,
      default_rate: null,
      labour_category: null,
      usual_farm: null,
    };
    setParties((ps) => [...ps, p].sort((a, b) => a.name.localeCompare(b.name)));
    patchRow(addPartyFor.taskIdx, addPartyFor.rowIdx, { party_code: p.party_code });
    setAddPartyFor(null);
  }

  // ---- render helpers ------------------------------------------------------
  const partyItems: ComboItem[] = useMemo(
    () =>
      parties.map((p) => ({
        code: p.party_code,
        label: p.name,
        hint:
          (p.labour_category ? p.labour_category + " · " : "") +
          (p.default_rate ? `₹${p.default_rate}/day` : p.kind),
      })),
    [parties],
  );
  // Base activity items carry their group_code so the browse view can section
  // them (§16.13). Livestock activities are tagged so a task on COW/GOAT can
  // float that whole section to the top — promote, never hide.
  const LIVESTOCK_ACTIVITIES = useMemo(
    () =>
      new Set(
        activities
          .filter((a) => a.group_code === "FARM")
          .map((a) => a.code)
          .filter((c) =>
            [
              "SHED CLEANING",
              "SHEPHERD WAGES",
              "MILKING WAGES",
              "VET & MEDICINE",
              "FEED",
              "FODDER CUTTING",
              "SHED CONSTRUCTION",
              "LIVESTOCK GENERAL",
            ].includes(c),
          ),
      ),
    [activities],
  );
  const activityItemsBase: ComboItem[] = activities.map((a) => ({
    code: a.code,
    label: a.label,
    hint: a.required_unit ? `expects ${a.required_unit}` : undefined,
    search: a.aliases,
    // Livestock work is scattered under FARM; give it its own browse section
    // so it reads as a block rather than hiding among 50 crop activities.
    group: LIVESTOCK_ACTIVITIES.has(a.code) ? "LIVESTOCK" : a.group_code,
  }));

  /**
   * Activities for one task. Same list every time — nothing is filtered out,
   * so FREIGHT for cattle feed stays reachable — but when the task's cost
   * object is a herd, the LIVESTOCK section is flagged to lead the browse
   * list (§690's "ranks by use" made to mean something in SAMPLE mode, where
   * there is no usage yet to rank by).
   */
  function activityItemsFor(costObject: string): ComboItem[] {
    const herd = costObject && (landBased[costObject] ?? true) === false;
    if (!herd) return activityItemsBase;
    return activityItemsBase.map((it) =>
      it.group === "LIVESTOCK" ? { ...it, promoteGroup: true } : it,
    );
  }
  const costObjectItems: ComboItem[] = costObjects.map((c) => ({
    code: c.code,
    label: c.label,
    hint: c.land_based ? undefined : "no farm asked",
    search: c.aliases,
    group: c.land_based ? "CROPS & LAND" : "LIVESTOCK & OTHER",
  }));

  const headerPocketBalance =
    headerMode && pocketBalances[headerMode] !== undefined
      ? pocketBalances[headerMode]
      : null;

  const inputCls =
    "w-full border border-input rounded px-2 py-1.5 bg-background text-sm";
  const selectCls = inputCls;
  const labelCls = "block text-xs text-muted-foreground mb-1";

  // -------------------------------------------------------------------------
  return (
    <main className="max-w-6xl mx-auto px-4 py-6 pb-40">
      <div className="flex items-baseline justify-between mb-4">
        <h1 className="text-lg font-semibold">
          Business expense voucher
          <span className="ml-2 text-sm font-normal text-muted-foreground">
            PB series · entity BUSINESS
          </span>
        </h1>
        <div className="text-sm text-muted-foreground">
          {headerMode ? (
            <>
              {headerMode} in hand:{" "}
              <span className="font-medium text-foreground tabular-nums">
                {headerPocketBalance === null ? "—" : formatINR(headerPocketBalance)}
              </span>
            </>
          ) : (
            "Pick a pocket to see its balance"
          )}
          {sampleMode && (
            <span className="ml-2 rounded bg-amber-100 dark:bg-amber-900/40 text-amber-800 dark:text-amber-300 px-1.5 py-0.5 text-xs">
              SAMPLE
            </span>
          )}
          <span className="ml-3">{userEmail}</span>
        </div>
      </div>

      {/* ---- HEADER: typed once, never again -------------------------------- */}
      <section className="border border-border rounded-lg p-4 mb-4 bg-card">
        <div className="grid grid-cols-2 md:grid-cols-6 gap-3">
          <div>
            <label className={labelCls}>Payment date</label>
            <input
              className={inputCls}
              value={dateText}
              placeholder="DD/MM/YYYY"
              onChange={(e) =>
                setDateText(autoSlashDMY(dateText, e.target.value))
              }
              onFocus={() => setHelp("When the cash actually moved. DD/MM/YYYY — shorthand like 21/7 works.")}
            />
          </div>
          <div>
            <label className={labelCls}>Period from</label>
            <input
              className={inputCls}
              value={periodFromText}
              placeholder="DD/MM/YYYY"
              onChange={(e) =>
                setPeriodFromText(autoSlashDMY(periodFromText, e.target.value))
              }
              onFocus={() => setHelp("The week the work covers — often not the payment date. Every task inherits this.")}
            />
          </div>
          <div>
            <label className={labelCls}>Period to</label>
            <input
              className={inputCls}
              value={periodToText}
              placeholder="DD/MM/YYYY"
              onChange={(e) =>
                setPeriodToText(autoSlashDMY(periodToText, e.target.value))
              }
              onFocus={() => setHelp("End of the work period.")}
            />
          </div>
          <div>
            <label className={labelCls}>Default pocket</label>
            <select
              className={selectCls}
              value={headerMode}
              onChange={(e) => setHeaderMode(e.target.value)}
              onFocus={() => setHelp("Which pocket paid most of this paper. Any row can still override it.")}
            >
              <option value="">— pick —</option>
              {modes.map((m) => (
                <option key={m.code} value={m.code}>
                  {m.label}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className={labelCls}>Paper ref no (optional)</label>
            <input
              className={inputCls}
              value={docRefNo}
              onChange={(e) => setDocRefNo(e.target.value)}
              onFocus={() => setHelp("The number written on the paper itself, if it has one. Catches the same slip entered twice.")}
            />
          </div>
          <div>
            <label className={labelCls}>Paper date (optional)</label>
            <input
              className={inputCls}
              value={docRefDateText}
              placeholder="DD/MM/YYYY"
              onChange={(e) =>
                setDocRefDateText(autoSlashDMY(docRefDateText, e.target.value))
              }
              onFocus={() => setHelp("The date written on the paper — not the payment date.")}
            />
          </div>
        </div>
      </section>

      {/* ---- TASKS ----------------------------------------------------------- */}
      {tasks.map((t, i) => {
        const isLand = t.cost_object ? (landBased[t.cost_object] ?? true) : true;
        const farmBlocks = blocks.filter(
          (b) => b.parent_farm === t.farm || b.code === "YET TO ASSIGN",
        );
        const isLabour = t.cost_nature === "LABOUR" || t.cost_nature === "";
        const tErr = dbErrorLine?.taskIdx === i;

        return (
          <section
            key={t.key}
            className={
              "border rounded-lg p-4 mb-4 bg-card " +
              (tErr ? "border-red-500" : "border-border")
            }
          >
            <div className="flex items-baseline justify-between mb-3">
              <div className="font-medium">
                Task {i + 1}
                <span className="ml-2 text-xs text-muted-foreground">
                  one piece of work — where, what, how much of it
                </span>
              </div>
              <div className="text-sm tabular-nums">
                {formatINR(taskSums[i])}
                {tasks.length > 1 && (
                  <button
                    type="button"
                    onClick={() => removeTask(i)}
                    className="ml-3 text-xs text-muted-foreground hover:text-red-600"
                  >
                    remove task
                  </button>
                )}
              </div>
            </div>

            <div className="grid grid-cols-2 md:grid-cols-6 gap-3 mb-2">
              <div>
                <label className={labelCls}>Cost object</label>
                <Combo
                  items={costObjectItems}
                  value={t.cost_object}
                  onPick={(code) => {
                    const nowLand = landBased[code] ?? true;
                    patchTask(i, {
                      cost_object: code,
                      // Greyed AND cleared on a non-land cost object: the box
                      // stays visible so she learns why it is not asked, but
                      // nothing is sent (owner ruling 21/07; Part 0.5).
                      farm: nowLand ? t.farm : "",
                      block: nowLand ? t.block : "",
                    });
                  }}
                  placeholder="crop / LAND / COW / NA…"
                  onFocusHelp={() =>
                    setHelp("What carries this cost. The one-question test: if this crop vanished tomorrow, would we still spend it? YES → LAND. Herd work → COW/GOAT (no farm asked). Office/admin → NA.")
                  }
                />
              </div>
              <div>
                <label className={labelCls}>
                  Farm{!isLand && " (not asked)"}
                </label>
                <select
                  className={selectCls + (isLand ? "" : " opacity-50 cursor-not-allowed bg-muted")}
                  value={t.farm}
                  disabled={!isLand}
                  title={isLand ? undefined : "A herd is an enterprise, not a place — no farm is asked for this cost object."}
                  onChange={(e) => patchTask(i, { farm: e.target.value, block: "" })}
                  onFocus={() => setHelp(isLand ? "Where the work happened. GENERAL = common to all farms — saves, but is flagged for splitting later." : "Greyed out: this cost object does not sit on land, so a farm is not asked.")}
                >
                  <option value="">— pick —</option>
                  {farms.map((f) => (
                    <option key={f.code} value={f.code}>
                      {f.label}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className={labelCls}>Block</label>
                <select
                  className={selectCls + (isLand && t.farm ? "" : " opacity-50 cursor-not-allowed bg-muted")}
                  value={t.block}
                  disabled={!isLand || !t.farm}
                  onChange={(e) => patchTask(i, { block: e.target.value })}
                  onFocus={() => setHelp("Which part of the farm, where blocks exist. Most farms have none seeded yet — YET TO ASSIGN saves with a soft flag.")}
                >
                  <option value="">— pick —</option>
                  {farmBlocks.map((b) => (
                    <option key={b.code} value={b.code}>
                      {b.label}
                    </option>
                  ))}
                </select>
              </div>
              <div className="col-span-2">
                <label className={labelCls}>Activity</label>
                <Combo
                  items={activityItemsFor(t.cost_object)}
                  value={t.activity}
                  onPick={(code) => {
                    const req = requiredUnit[code];
                    patchTask(i, {
                      activity: code,
                      // Unit pre-fills from the activity and stays overridable.
                      unit: t.unit || req || "",
                    });
                  }}
                  placeholder="weed, spray, irrigation, fence…"
                  invalid={!t.activity && reds.some((r) => r.taskIdx === i && r.text.includes("activity"))}
                  onFocusHelp={() => {
                    const note = t.activity ? masterNotes[`ACTIVITY:${t.activity}`] : null;
                    setHelp(note ?? "What was done. Farm work only — household activities live on the drawings voucher.");
                  }}
                />
              </div>
              <div>
                <label className={labelCls}>Cost nature</label>
                <select
                  className={selectCls}
                  value={t.cost_nature}
                  onChange={(e) => patchTask(i, { cost_nature: e.target.value })}
                  onFocus={() => setHelp("What KIND of spending. LABOUR shows days × rate; CONTRACT shows rate against the task's quantity; the rest take a single amount. One job, two natures → two tasks.")}
                >
                  <option value="">— pick —</option>
                  {costNatures.map((c) => (
                    <option key={c.code} value={c.code}>
                      {c.label}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="grid grid-cols-2 md:grid-cols-6 gap-3 mb-3">
              <div>
                <label className={labelCls}>How much covered</label>
                <input
                  className={inputCls + " text-right tabular-nums"}
                  value={t.qty}
                  onChange={(e) => patchTask(i, { qty: e.target.value })}
                  onFocus={() => setHelp("The work measured: 7.5 acres, 300 feet. Written ONCE per task — the database puts it on the first person's row only, so acres stay summable.")}
                />
              </div>
              <div>
                <label className={labelCls}>Unit</label>
                <select
                  className={selectCls}
                  value={t.unit}
                  onChange={(e) => patchTask(i, { unit: e.target.value })}
                  onFocus={() => setHelp("Pre-fills from the activity; override where the paper measures differently.")}
                >
                  <option value="">—</option>
                  {units.map((u) => (
                    <option key={u.code} value={u.code}>
                      {u.label}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className={labelCls}>Capex</label>
                <select
                  className={selectCls}
                  value={t.capex_flag}
                  onChange={(e) => patchTask(i, { capex_flag: e.target.value })}
                  onFocus={() => setHelp("CAPITAL routes this to Fixed Assets instead of the P&L. Almost always RECURRING.")}
                >
                  {capexFlags.map((c) => (
                    <option key={c.code} value={c.code}>
                      {c.label}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className={labelCls}>Job (rarely)</label>
                <select
                  className={selectCls}
                  value={t.job_id}
                  disabled={jobs.length === 0}
                  onChange={(e) => patchTask(i, { job_id: e.target.value })}
                  onFocus={() => setHelp(jobs.length === 0 ? "No open jobs — which is normal. A job is only for a well or a big contract followed across many vouchers." : "Attach only if this cost belongs to a named long-running job.")}
                >
                  <option value="">
                    {jobs.length === 0 ? "no open jobs" : "— none —"}
                  </option>
                  {jobs.map((j) => (
                    <option key={j.job_id} value={j.job_id}>
                      {j.job_id} · {j.description}
                    </option>
                  ))}
                </select>
              </div>
              <div className="col-span-2">
                <label className={labelCls}>
                  Task narration ({(t.narration.trim().length)}/
                  {vagueActivities.includes(t.activity) ? vagueNarrationMin : narrationMin} min)
                </label>
                <input
                  className={inputCls}
                  value={t.narration}
                  onChange={(e) => patchTask(i, { narration: e.target.value })}
                  onFocus={() => setHelp("Describe the work in the paper's words. Every person on this task inherits it; a row can still carry its own.")}
                />
              </div>
            </div>

            {/* ---- rows: one person each ---------------------------------- */}
            <div className="border-t border-border pt-2">
              {t.rows.map((r, j) => {
                const rErr = dbErrorLine?.taskIdx === i && dbErrorLine?.rowIdx === j;
                const party = r.party_code ? partyByCode[r.party_code] : null;
                return (
                  <div
                    key={r.key}
                    className={
                      "grid grid-cols-2 md:grid-cols-12 gap-2 items-start py-1.5 rounded " +
                      (rErr ? "ring-1 ring-red-500 px-1" : "")
                    }
                  >
                    <div className="md:col-span-3">
                      {j === 0 && <label className={labelCls}>Person</label>}
                      <Combo
                        items={partyItems}
                        value={r.party_code}
                        disabled={r.oneTime}
                        onPick={(code) => {
                          const p = partyByCode[code];
                          patchRow(i, j, {
                            party_code: code,
                            // Rate pre-fills from the person; the typed rate
                            // always wins (§19.2 — pre-fill, never enforce).
                            rate:
                              r.rate === "" && p?.default_rate
                                ? String(p.default_rate)
                                : r.rate,
                          });
                        }}
                        placeholder="type a name…"
                        onFocusHelp={() =>
                          setHelp("Who did this work. Type to search; a new name can be added without leaving the voucher.")
                        }
                      />
                      <div className="flex gap-3 mt-0.5 flex-wrap">
                        <label className="text-xs text-muted-foreground flex items-center gap-1">
                          <input
                            type="checkbox"
                            checked={r.oneTime}
                            onChange={(e) =>
                              patchRow(i, j, {
                                oneTime: e.target.checked,
                                party_code: e.target.checked ? "" : r.party_code,
                              })
                            }
                          />
                          one-time
                        </label>
                        <button
                          type="button"
                          className="text-xs text-primary hover:underline"
                          onClick={() => openAddParty(i, j, "")}
                        >
                          + add person
                        </button>
                        {party?.default_rate ? (
                          <span className="text-xs text-muted-foreground">
                            usual ₹{party.default_rate}
                          </span>
                        ) : null}
                      </div>
                    </div>

                    <div className="md:col-span-2">
                      {j === 0 && <label className={labelCls}>Days</label>}
                      <input
                        className={
                          inputCls +
                          " text-right tabular-nums" +
                          (isLabour ? "" : " opacity-50 bg-muted")
                        }
                        disabled={!isLabour}
                        title={isLabour ? undefined : "Contract and lump-sum rows carry no mandays — none were bought (§19.3)."}
                        value={r.mandays}
                        onChange={(e) => {
                          const days = num(e.target.value);
                          const rate = num(r.rate);
                          patchRow(i, j, {
                            mandays: e.target.value,
                            amount:
                              days !== null && rate !== null
                                ? String(days * rate)
                                : r.amount,
                          });
                        }}
                        onFocus={() => setHelp("Labour days. Halves are normal — 8.5, 10.5. LEAVE BLANK for piece-rate work: then the rate is per unit of the task's quantity — ₹3 per tree, ₹60 per goat, ₹40 per tank.")}
                      />
                    </div>

                    <div className="md:col-span-2">
                      {j === 0 && (
                        <label className={labelCls}>
                          {/* THE FIX FOR THE INVISIBLE MODE SWITCH.
                              "Rate" meant two different things depending on
                              whether a DIFFERENT box was empty, and nothing
                              said so. Now the label itself says which. */}
                          Rate ₹{rateBasis(t, r)}
                        </label>
                      )}
                      <input
                        className={inputCls + " text-right tabular-nums"}
                        value={r.rate}
                        onChange={(e) => {
                          const rate = num(e.target.value);
                          const days = num(r.mandays);
                          const q = num(t.qty);
                          let amount = r.amount;
                          // Days filled -> days x rate.
                          // Days BLANK on the task's FIRST row -> the rate
                          // belongs to the QUANTITY (file 09: "Rs.20 per tree,
                          // 956 trees"), WHATEVER the cost nature. Piece-rate
                          // labour is still LABOUR: the estate pays Rs.3 per
                          // tree for root feeding and Rs.60 per goat for
                          // vaccination, both under LABOUR/PROFESSIONAL.
                          // Rows 2..n hold no quantity, so their amount is
                          // typed off the paper.
                          if (days !== null && rate !== null)
                            amount = String(days * rate);
                          else if (j === 0 && q !== null && rate !== null)
                            amount = String(q * rate);
                          patchRow(i, j, { rate: e.target.value, amount });
                        }}
                        onFocus={() =>
                          setHelp(
                            num(r.mandays) !== null
                              ? "Rate per DAY for this person, because days are filled."
                              : t.unit
                                ? `Days is blank, so this rate is PER ${t.unit} — the task's quantity × this rate fills the amount. Fill days to make it per-day.`
                                : "Days is blank, so this rate is per unit of the task's quantity. Write the quantity and unit above, or fill days to make it per-day.",
                          )
                        }
                      />
                    </div>

                    <div className="md:col-span-2">
                      {j === 0 && <label className={labelCls}>Amount ₹</label>}
                      <input
                        className={inputCls + " text-right tabular-nums font-medium"}
                        value={r.amount}
                        onChange={(e) => patchRow(i, j, { amount: e.target.value })}
                        onKeyDown={(e) => {
                          // Enter on the last field of the last row adds the
                          // next person — the paper reads downwards (§5).
                          if (e.key === "Enter" && j === t.rows.length - 1) {
                            e.preventDefault();
                            addRow(i);
                          }
                        }}
                        onFocus={() => setHelp("Computed, and directly editable — the slip wins. Enter here adds the next person.")}
                      />
                    </div>

                    <div className="md:col-span-2">
                      {j === 0 && <label className={labelCls}>Pocket</label>}
                      <select
                        className={selectCls}
                        value={r.mode}
                        onChange={(e) => patchRow(i, j, { mode: e.target.value })}
                        onFocus={() => setHelp("Inherited from the header; override only where this one person was paid differently.")}
                      >
                        <option value="">
                          {headerMode ? `↑ ${headerMode}` : "↑ header"}
                        </option>
                        {modes.map((m) => (
                          <option key={m.code} value={m.code}>
                            {m.label}
                          </option>
                        ))}
                      </select>
                    </div>

                    <div className="md:col-span-1">
                      {j === 0 && <label className={labelCls}>&nbsp;</label>}
                      <button
                        type="button"
                        className="text-xs text-muted-foreground hover:text-red-600 py-1.5"
                        onClick={() => removeRow(i, j)}
                        disabled={t.rows.length === 1}
                        title="Remove this person"
                      >
                        ✕
                      </button>
                    </div>

                    {/* Optional per-row narration — "Savithri, half day" */}
                    <div className="col-span-2 md:col-span-12 -mt-1">
                      <input
                        className="w-full border-0 border-b border-dashed border-input bg-transparent px-2 py-0.5 text-xs text-muted-foreground focus:outline-none"
                        placeholder="(optional note for this person — otherwise the task narration applies)"
                        value={r.narration}
                        onChange={(e) => patchRow(i, j, { narration: e.target.value })}
                      />
                    </div>
                  </div>
                );
              })}

              <div className="flex items-center justify-between mt-2">
                <button
                  type="button"
                  onClick={() => addRow(i)}
                  className="text-sm text-primary hover:underline"
                >
                  + add person ⏎
                </button>
                <div className="text-xs text-muted-foreground flex items-center gap-2">
                  task total off the paper:
                  <input
                    className="w-28 border border-input rounded px-2 py-1 text-right tabular-nums bg-background"
                    value={t.paperTotal}
                    onChange={(e) => patchTask(i, { paperTotal: e.target.value })}
                    onFocus={() => setHelp("The total written against this working on the paper. If the rows disagree, the save is refused — one of them is wrong.")}
                  />
                </div>
              </div>
            </div>
          </section>
        );
      })}

      <button
        type="button"
        onClick={addTask}
        className="mb-6 text-sm border border-dashed border-input rounded-lg px-4 py-2 w-full text-muted-foreground hover:text-foreground hover:border-foreground/40"
      >
        + add task — the next numbered working on the paper
      </button>

      {/* ---- inline add-party panel ---------------------------------------- */}
      {addPartyFor && (
        <div className="fixed inset-0 z-30 bg-black/30 flex items-center justify-center p-4">
          <div className="bg-card border border-border rounded-lg p-4 w-full max-w-md">
            <div className="font-medium mb-2">Add a person</div>
            <label className={labelCls}>Name</label>
            <input
              className={inputCls + " mb-2"}
              value={npName}
              onChange={(e) => {
                setNpName(e.target.value);
                setNpCode(
                  e.target.value
                    .toUpperCase()
                    .replace(/[^A-Z0-9 ]/g, "")
                    .trim()
                    .replace(/\s+/g, " "),
                );
              }}
              autoFocus
            />
            <label className={labelCls}>Code (permanent — never renamed)</label>
            <input
              className={inputCls + " mb-2"}
              value={npCode}
              onChange={(e) => setNpCode(e.target.value.toUpperCase())}
            />
            <label className={labelCls}>Kind</label>
            <select
              className={selectCls + " mb-2"}
              value={npKind}
              onChange={(e) => setNpKind(e.target.value)}
            >
              <option value="">— pick —</option>
              {partyKinds.map((k) => (
                <option key={k.code} value={k.code}>
                  {k.group_label ? `${k.group_label} · ` : ""}
                  {k.label}
                </option>
              ))}
            </select>
            {npError && <div className="text-sm text-red-600 mb-2">{npError}</div>}
            <div className="flex justify-end gap-2">
              <button
                type="button"
                className="text-sm px-3 py-1.5 rounded border border-input"
                onClick={() => setAddPartyFor(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="text-sm px-3 py-1.5 rounded bg-primary text-primary-foreground disabled:opacity-50"
                disabled={npBusy}
                onClick={submitAddParty}
              >
                {npBusy ? "Adding…" : "Add person"}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ---- FOOT: totals, preview panel, save ------------------------------ */}
      <section className="border border-border rounded-lg p-4 bg-card">
        <div className="flex flex-wrap items-baseline justify-between gap-3 mb-1">
          <div>
            <div className="text-lg font-semibold tabular-nums">
              {tasks.length} task{tasks.length === 1 ? "" : "s"} · total{" "}
              {formatINR(voucherTotal)}
            </div>
            <div className="text-xs text-muted-foreground">
              {inrWords(voucherTotal)}
            </div>
          </div>
          <div className="text-sm flex items-center gap-2">
            the paper says ₹
            <input
              className="w-32 border border-input rounded px-2 py-1.5 text-right tabular-nums bg-background"
              value={paperTotalText}
              onChange={(e) => setPaperTotalText(e.target.value)}
              onFocus={() => setHelp("The grand total on the front of the paper. A mismatch WARNS, never blocks — on the real weekly paper the household part belongs on a drawings voucher, so they SHOULD differ.")}
            />
          </div>
        </div>

        {/* Red first — these are what the database will refuse. */}
        {reds.length > 0 && (
          <div className="mt-3 border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 text-red-900 dark:text-red-300 rounded p-3 text-sm">
            <div className="font-medium mb-1">
              The database will refuse this — fix before saving:
            </div>
            {reds.map((f, i) => (
              <div key={i}>· {f.text}</div>
            ))}
          </div>
        )}
        {ambers.length > 0 && (
          <div className="mt-3 border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/30 text-amber-900 dark:text-amber-300 rounded p-3 text-sm">
            <div className="font-medium mb-1">
              Will save, and will be flagged or warned:
            </div>
            {ambers.map((f, i) => (
              <div key={i}>· {f.text}</div>
            ))}
          </div>
        )}

        {/* The database's own words, verbatim, when it refused after all. */}
        {dbError && (
          <div className="mt-3 border border-red-400 bg-red-50 dark:bg-red-950/40 text-red-900 dark:text-red-300 rounded p-3 text-sm">
            <span className="font-medium">Not saved. </span>
            {dbError}
            {dbErrorLine && (
              <span className="block text-xs mt-1">
                (that is task {dbErrorLine.taskIdx + 1}, person{" "}
                {dbErrorLine.rowIdx + 1} — highlighted above)
              </span>
            )}
          </div>
        )}

        {/* THE CONFIRM STEP. What is about to become immutable, in the
            paper's own terms: tasks, people, total in words. */}
        {confirmArmed && (
          <div className="mt-3 border border-border rounded p-3 text-sm bg-muted/40">
            <div className="font-medium mb-2">
              About to save — check against the paper, then confirm.
            </div>
            <table className="w-full text-xs mb-2">
              <tbody>
                {tasks.map((t, i) => (
                  <tr key={t.key} className="border-b border-border/50">
                    <td className="py-1 pr-2 align-top w-8 text-muted-foreground">
                      {i + 1}
                    </td>
                    <td className="py-1 pr-2 align-top">
                      {[t.farm, t.block && t.block !== "YET TO ASSIGN" ? t.block : null,
                        t.cost_object, t.activity]
                        .filter(Boolean)
                        .join(" · ")}
                      {t.qty ? (
                        <span className="text-muted-foreground">
                          {" "}· {t.qty} {t.unit}
                        </span>
                      ) : null}
                    </td>
                    <td className="py-1 pr-2 align-top text-muted-foreground">
                      {t.rows.length} {t.rows.length === 1 ? "person" : "people"}
                    </td>
                    <td className="py-1 align-top text-right tabular-nums">
                      {formatINR(taskSums[i])}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="flex justify-between font-medium">
              <span>
                {tasks.length} task{tasks.length === 1 ? "" : "s"} ·{" "}
                {tasks.reduce((n, t) => n + t.rows.length, 0)} rows
              </span>
              <span className="tabular-nums">{formatINR(voucherTotal)}</span>
            </div>
            <div className="text-xs text-muted-foreground">
              {inrWords(voucherTotal)}
            </div>
            <div className="text-xs text-muted-foreground mt-1">
              Once saved a row cannot be edited — only reversed or superseded.
            </div>
          </div>
        )}

        <div className="mt-4 flex items-center gap-3">
          <button
            type="button"
            disabled={!canSave}
            onClick={doSave}
            className={
              "px-5 py-2 rounded text-sm font-medium " +
              (canSave
                ? confirmArmed
                  ? "bg-amber-600 text-white"
                  : "bg-primary text-primary-foreground"
                : "bg-muted text-muted-foreground cursor-not-allowed")
            }
          >
            {saving
              ? "Saving…"
              : confirmArmed
                ? ambers.length > 0
                  ? `Confirm and save — ${ambers.length} warning${ambers.length === 1 ? "" : "s"}`
                  : "Confirm and save"
                : "Review and save"}
          </button>
          {confirmArmed && (
            <button
              type="button"
              className="text-sm text-muted-foreground hover:underline"
              onClick={() => setConfirmArmed(false)}
            >
              go back and fix
            </button>
          )}
        </div>

        {/* Session strip — batch working (§5): the evening's papers, in order. */}
        {savedThisSession.length > 0 && (
          <div className="mt-4 border-t border-border pt-2 text-xs text-muted-foreground">
            Saved this session:{" "}
            {savedThisSession.map((s) => (
              <span key={s.voucher_no} className="mr-3">
                <span className="font-medium text-foreground">{s.voucher_no}</span>{" "}
                {formatINR(s.total)}
                {s.warnings.length > 0 && ` (${s.warnings.length} warn)`}
              </span>
            ))}
          </div>
        )}
      </section>

      {/* ---- HELP STRIP (the Tally convention): fixed at the foot ----------- */}
      <div className="fixed bottom-0 inset-x-0 border-t border-border bg-muted/95 backdrop-blur px-4 py-2 text-sm text-muted-foreground">
        <div className="max-w-6xl mx-auto">{help}</div>
      </div>
    </main>
  );
}
