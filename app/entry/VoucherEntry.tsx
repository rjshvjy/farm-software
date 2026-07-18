// app/entry/VoucherEntry.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the voucher entry screen (§5, settled behaviour).
//
// WHAT THIS SCREEN IS
//   Payment vouchers only: money out. One paper slip = one voucher = a header
//   filled once plus lines. Receipts, transfers, advances are Stage B screens.
//
// THE CONTRACT (repeated because it is the whole design):
//   This screen collects fields, calls saveVoucher, and DISPLAYS EVERYTHING
//   that comes back. It re-implements no rule. Dates, vagueness, duplicates,
//   quantities — all judged by the database. The one thing the screen owns is
//   the confirm question ("this will be flagged — save anyway?"), because a
//   database cannot ask a question.
//
// SETTLED BEHAVIOUR BUILT HERE (§5 / handover):
//   - Header carries defaults (date, mode, period, payee), inherited by every
//     line, overridable per line. The payload is per-line regardless.
//   - Each new line opens as a copy of the one above, amount blanked, cursor
//     on the amount.
//   - On save the screen never fully resets: date and mode survive; only
//     lines clear. She is working a stack from one day and one pocket.
//   - A session strip lists every voucher saved this sitting — number, payee,
//     total — because the pen-writing happens per stack, not per slip.
//   - Keyboard-first: Enter commits a line, Escape backs out of it, the
//     activity picker is type-ahead with substring matching. Mouse optional.
//   - Every warning is shown, never swallowed. The voucher number is large
//     and copyable: the next physical act is writing it on the slip in pen.
// ---------------------------------------------------------------------------
"use client";

import { useMemo, useRef, useState } from "react";
import { formatDMY, parseDMY, formatINR } from "@/lib/dates";
import { saveVoucher, type VoucherLine, type SaveResult } from "./actions";

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

export type PartyRow = { party_code: string; name: string };

type Props = {
  masters: Record<string, MasterRow[]>;
  parties: PartyRow[];
  today: string; // ISO, from fn_today()
  vagueActivities: string[]; // from config VAGUE_ACTIVITIES
  narrationMin: number; // from config VAGUE_NARRATION_MIN
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
  party_code: string; // blank = inherit header party (credit mode only)
};

type SavedVoucher = { voucher_no: string; payee: string; total: number };

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
});

// ---------------------------------------------------------------------------

export default function VoucherEntry({
  masters,
  parties,
  today,
  vagueActivities,
  narrationMin,
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

  // ---- lines: committed ones plus the one being edited --------------------
  const [lines, setLines] = useState<EditLine[]>([]);
  const [draft, setDraft] = useState<EditLine>(emptyLine());

  // ---- result of the last save, and the strip of this sitting -------------
  const [saving, setSaving] = useState(false);
  const [lastResult, setLastResult] = useState<SaveResult | null>(null);
  const [session, setSession] = useState<SavedVoucher[]>([]);

  const amountRef = useRef<HTMLInputElement>(null);

  // ---- derived ------------------------------------------------------------
  const dateISO = parseDMY(dateText);
  const periodFromISO = periodFromText ? parseDMY(periodFromText) : null;
  const periodToISO = periodToText ? parseDMY(periodToText) : null;

  const modeKind =
    masters["MODE"]?.find((m) => m.code === mode)?.mode_kind ?? null;
  const creditMode = modeKind === "CREDIT";

  const activityByCode = useMemo(() => {
    const m = new Map<string, MasterRow>();
    for (const a of masters["ACTIVITY"] ?? []) m.set(a.code, a);
    return m;
  }, [masters]);

  const draftAmount = parseFloat(draft.amount);
  const linesTotal = lines.reduce(
    (s, l) => s + (parseFloat(l.amount) || 0),
    0,
  );
  const voucherTotal = linesTotal + (Number.isFinite(draftAmount) ? draftAmount : 0);

  // ---- draft editing ------------------------------------------------------

  function setD<K extends keyof EditLine>(key: K, value: EditLine[K]) {
    setDraft((d) => {
      const next = { ...d, [key]: value };
      // Activity chosen → adopt its required unit if the unit is empty.
      if (key === "activity") {
        const act = activityByCode.get(value as string);
        if (act?.required_unit && !d.unit) next.unit = act.required_unit;
      }
      // mandays × rate fills the amount, but the amount stays the truth (§5):
      // only auto-fill while the user hasn't typed an amount of their own.
      if (key === "mandays" || key === "rate") {
        const md = parseFloat(key === "mandays" ? (value as string) : d.mandays);
        const rt = parseFloat(key === "rate" ? (value as string) : d.rate);
        const auto =
          Number.isFinite(md) && Number.isFinite(rt)
            ? String(Math.round(md * rt * 100) / 100)
            : d.amount;
        const prevAuto =
          Number.isFinite(parseFloat(d.mandays)) &&
          Number.isFinite(parseFloat(d.rate))
            ? String(
                Math.round(parseFloat(d.mandays) * parseFloat(d.rate) * 100) /
                  100,
              )
            : "";
        if (d.amount === "" || d.amount === prevAuto) next.amount = auto;
      }
      return next;
    });
  }

  /** What stops the draft committing, in the user's language. */
  function draftProblems(d: EditLine): string[] {
    const p: string[] = [];
    if (!d.farm) p.push("farm");
    if (!d.cost_object) p.push("cost object");
    if (!d.activity) p.push("activity");
    const amt = parseFloat(d.amount);
    if (!Number.isFinite(amt) || amt <= 0) p.push("amount");
    return p;
  }

  function commitDraft(): boolean {
    if (draftProblems(draft).length) return false;
    setLines((ls) => [...ls, draft]);
    // §5: the next line opens as a COPY of the one above, amount blanked,
    // cursor on the amount. Quantity and mandays also clear — they belong to
    // the line, not the pattern.
    setDraft({ ...draft, qty: "", mandays: "", amount: "", narration: "" });
    setTimeout(() => amountRef.current?.focus(), 0);
    return true;
  }

  function removeLine(i: number) {
    // Removing an UNSAVED line is allowed — nothing exists yet; immutability
    // (§13) begins at save, not at typing.
    setLines((ls) => ls.filter((_, idx) => idx !== i));
  }

  // ---- save ---------------------------------------------------------------

  function buildPayload(): { lines: VoucherLine[] } | { error: string } {
    if (!dateISO)
      return { error: `"${dateText}" is not a date. Use DD/MM/YYYY.` };
    if (periodFromText && !periodFromISO)
      return { error: `Period from "${periodFromText}" is not a date.` };
    if (periodToText && !periodToISO)
      return { error: `Period to "${periodToText}" is not a date.` };

    // Include the draft if it's complete — she typed it, she means it.
    const all = draftProblems(draft).length === 0 ? [...lines, draft] : lines;
    if (all.length === 0)
      return { error: "Nothing to save — the voucher has no lines." };

    if (creditMode && !headerParty) {
      const missing = all.some((l) => !l.party_code);
      if (missing)
        return {
          error:
            "Mode is ON CREDIT: pick the party (supplier) in the header, or on each line.",
        };
    }

    const num = (s: string) => {
      const n = parseFloat(s);
      return Number.isFinite(n) ? n : null;
    };

    return {
      lines: all.map((l) => ({
        payment_date: dateISO,
        period_from: periodFromISO,
        period_to: periodToISO,
        entity: l.entity,
        farm: l.farm,
        block: l.block || null,
        cost_object: l.cost_object,
        activity: l.activity,
        capex_flag: l.capex_flag,
        qty: num(l.qty),
        unit: l.unit || null,
        mandays: num(l.mandays),
        rate: num(l.rate),
        paid_out_dr: num(l.amount)!,
        mode,
        party_code: l.party_code || headerParty || null,
        payee: l.payee || headerPayee || null,
        narration: l.narration || null,
      })),
    };
  }

  /**
   * The one question the screen owns (§5B): things the database will accept
   * but flag. Listed before saving so "Save" is informed consent. Everything
   * here is ADVISORY — the database re-derives all of it and is the judge.
   */
  function flagsToConfirm(payload: VoucherLine[]): string[] {
    const msgs: string[] = [];
    payload.forEach((l, i) => {
      const n = i + 1;
      if (vagueActivities.includes(l.activity)) {
        const narr = (l.narration ?? "").trim();
        if (narr.length < narrationMin) {
          // The DB will REFUSE this one — surface it as a hard stop here so
          // she fixes it before the round-trip, in the DB's own spirit.
          msgs.push(
            `Line ${n}: ${l.activity} is a last resort — a real narration of at least ${narrationMin} characters is required.`,
          );
        } else {
          msgs.push(
            `Line ${n}: ${l.activity} will be flagged for the owner's review queue.`,
          );
        }
      }
      const act = activityByCode.get(l.activity);
      if (act?.required_unit && l.qty == null) {
        msgs.push(
          `Line ${n}: ${l.activity} expects ${act.required_unit} and none is recorded — will be flagged.`,
        );
      }
      const md = l.mandays, rt = l.rate;
      if (md != null && rt != null && Math.abs(md * rt - l.paid_out_dr) > 0.005) {
        msgs.push(
          `Line ${n}: amount ${formatINR(l.paid_out_dr)} ≠ mandays × rate ${formatINR(md * rt)}.`,
        );
      }
    });
    return msgs;
  }

  async function onSave() {
    setLastResult(null);
    const built = buildPayload();
    if ("error" in built) {
      setLastResult({ ok: false, message: built.error });
      return;
    }

    const notices = flagsToConfirm(built.lines);
    if (notices.length) {
      const hardStops = notices.filter((m) => m.includes("required"));
      if (hardStops.length) {
        setLastResult({ ok: false, message: hardStops.join("\n") });
        return;
      }
      const goAhead = window.confirm(
        "Before saving:\n\n" + notices.join("\n") + "\n\nSave anyway?",
      );
      if (!goAhead) return;
    }

    setSaving(true);
    const result = await saveVoucher(built.lines);
    setSaving(false);
    setLastResult(result);

    if (result.ok) {
      const total = built.lines.reduce((s, l) => s + l.paid_out_dr, 0);
      setSession((ss) => [
        ...ss,
        {
          voucher_no: result.voucher_no,
          payee: built.lines[0].payee ?? "",
          total,
        },
      ]);
      // §5 batch working: date and mode SURVIVE into the next voucher.
      // Only the lines, the payee and the periods clear.
      setLines([]);
      setDraft(emptyLine());
      setHeaderPayee("");
      setHeaderParty("");
      setPeriodFromText("");
      setPeriodToText("");
    }
  }

  // ---- small render helpers ----------------------------------------------

  const inputCls =
    "border rounded px-2 py-1 text-sm w-full focus:outline-none focus:ring-2 focus:ring-blue-400";
  const labelCls = "block text-xs text-gray-500 mb-0.5";

  function Sel({
    value,
    onChange,
    options,
    allowBlank,
  }: {
    value: string;
    onChange: (v: string) => void;
    options: { code: string; label: string }[];
    allowBlank?: boolean;
  }) {
    return (
      <select
        className={inputCls}
        value={value}
        onChange={(e) => onChange(e.target.value)}
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

  // ---- render -------------------------------------------------------------

  return (
    <main className="max-w-6xl mx-auto p-4 pb-24">
      <header className="flex items-baseline justify-between mb-4">
        <h1 className="text-xl font-semibold">Voucher entry — payment</h1>
        <span className="text-xs text-gray-500">{userEmail}</span>
      </header>

      {/* ---------------- header: once per paper slip ---------------- */}
      <section className="grid grid-cols-2 md:grid-cols-6 gap-3 border rounded-lg p-3 bg-gray-50 mb-4">
        <div>
          <label className={labelCls}>Payment date (DD/MM/YYYY)</label>
          <input
            className={inputCls + (dateISO ? "" : " border-red-500")}
            value={dateText}
            onChange={(e) => setDateText(e.target.value)}
            placeholder="DD/MM/YYYY"
          />
          {/* echo the parsed date so 010203 is never a mystery */}
          <div className="text-xs mt-0.5 text-gray-500 h-4">
            {dateText && (dateISO ? formatDMY(dateISO) : "not a date")}
          </div>
        </div>
        <div>
          <label className={labelCls}>Mode</label>
          <Sel
            value={mode}
            onChange={setMode}
            options={masters["MODE"] ?? []}
          />
        </div>
        <div>
          <label className={labelCls}>Payee (default for lines)</label>
          <input
            className={inputCls}
            value={headerPayee}
            onChange={(e) => setHeaderPayee(e.target.value)}
            placeholder="as written on the slip"
          />
        </div>
        <div>
          <label className={labelCls}>Period from</label>
          <input
            className={inputCls}
            value={periodFromText}
            onChange={(e) => setPeriodFromText(e.target.value)}
            placeholder="optional"
          />
        </div>
        <div>
          <label className={labelCls}>Period to</label>
          <input
            className={inputCls}
            value={periodToText}
            onChange={(e) => setPeriodToText(e.target.value)}
            placeholder="optional"
          />
        </div>
        {creditMode && (
          <div>
            <label className={labelCls}>Party (ON CREDIT — required)</label>
            <Sel
              value={headerParty}
              onChange={setHeaderParty}
              allowBlank
              options={parties.map((p) => ({
                code: p.party_code,
                label: p.name,
              }))}
            />
          </div>
        )}
      </section>

      {/* ---------------- committed lines ---------------- */}
      {lines.length > 0 && (
        <table className="w-full text-sm mb-2">
          <thead>
            <tr className="text-left text-xs text-gray-500">
              <th className="py-1">#</th>
              <th>Entity</th>
              <th>Farm</th>
              <th>Cost object</th>
              <th>Activity</th>
              <th className="text-right">Qty</th>
              <th className="text-right">Amount ₹</th>
              <th>Narration</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i} className="border-t">
                <td className="py-1">{i + 1}</td>
                <td>{l.entity}</td>
                <td>{l.farm}</td>
                <td>{l.cost_object}</td>
                <td>{activityByCode.get(l.activity)?.label ?? l.activity}</td>
                <td className="text-right">
                  {l.qty && `${l.qty} ${l.unit}`}
                </td>
                <td className="text-right">{formatINR(parseFloat(l.amount))}</td>
                <td className="text-gray-600">{l.narration}</td>
                <td>
                  <button
                    className="text-red-600 text-xs"
                    onClick={() => removeLine(i)}
                    title="Remove (nothing is saved yet)"
                  >
                    remove
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {/* ---------------- the line being typed ---------------- */}
      <section
        className="border rounded-lg p-3 mb-4"
        onKeyDown={(e) => {
          // §5 keyboard-first: Enter commits the line, Escape backs out.
          if (e.key === "Enter" && (e.target as HTMLElement).tagName !== "TEXTAREA") {
            e.preventDefault();
            commitDraft();
          }
          if (e.key === "Escape") setDraft(emptyLine());
        }}
      >
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-3">
          <div>
            <label className={labelCls}>Entity</label>
            <Sel
              value={draft.entity}
              onChange={(v) => setD("entity", v)}
              options={ENTITIES.map((e) => ({ code: e, label: e }))}
            />
          </div>
          <div>
            <label className={labelCls}>Farm</label>
            <Sel
              value={draft.farm}
              onChange={(v) => setD("farm", v)}
              allowBlank
              options={masters["FARM"] ?? []}
            />
          </div>
          <div>
            <label className={labelCls}>Block</label>
            <Sel
              value={draft.block}
              onChange={(v) => setD("block", v)}
              options={masters["BLOCK"] ?? []}
            />
          </div>
          <div>
            <label className={labelCls}>Cost object</label>
            <Sel
              value={draft.cost_object}
              onChange={(v) => setD("cost_object", v)}
              allowBlank
              options={masters["COST_OBJECT"] ?? []}
            />
          </div>
          <div>
            <label className={labelCls}>Capex</label>
            <Sel
              value={draft.capex_flag}
              onChange={(v) => setD("capex_flag", v)}
              options={masters["CAPEX_FLAG"] ?? []}
            />
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-6 gap-3 mb-3">
          <div className="md:col-span-2">
            <label className={labelCls}>Activity (type to search)</label>
            <ActivityPicker
              activities={masters["ACTIVITY"] ?? []}
              value={draft.activity}
              onPick={(code) => setD("activity", code)}
            />
          </div>
          <div>
            <label className={labelCls}>
              Qty
              {(() => {
                const ru = activityByCode.get(draft.activity)?.required_unit;
                return ru ? ` (${ru} expected)` : "";
              })()}
            </label>
            <input
              className={inputCls}
              value={draft.qty}
              onChange={(e) => setD("qty", e.target.value)}
              inputMode="decimal"
            />
          </div>
          <div>
            <label className={labelCls}>Unit</label>
            <Sel
              value={draft.unit}
              onChange={(v) => setD("unit", v)}
              allowBlank
              options={masters["UNIT"] ?? []}
            />
          </div>
          <div>
            <label className={labelCls}>Mandays</label>
            <input
              className={inputCls}
              value={draft.mandays}
              onChange={(e) => setD("mandays", e.target.value)}
              inputMode="decimal"
            />
          </div>
          <div>
            <label className={labelCls}>Rate ₹</label>
            <input
              className={inputCls}
              value={draft.rate}
              onChange={(e) => setD("rate", e.target.value)}
              inputMode="decimal"
            />
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-6 gap-3 items-end">
          <div>
            <label className={labelCls}>Amount ₹</label>
            <input
              ref={amountRef}
              className={inputCls + " font-semibold"}
              value={draft.amount}
              onChange={(e) => setD("amount", e.target.value)}
              inputMode="decimal"
            />
          </div>
          <div className="md:col-span-2">
            <label className={labelCls}>
              Narration
              {vagueActivities.includes(draft.activity) &&
                " — REQUIRED: what was this actually for?"}
            </label>
            <input
              className={
                inputCls +
                (vagueActivities.includes(draft.activity) &&
                draft.narration.trim().length < narrationMin
                  ? " border-amber-500"
                  : "")
              }
              value={draft.narration}
              onChange={(e) => setD("narration", e.target.value)}
            />
          </div>
          <div>
            <label className={labelCls}>Payee (this line)</label>
            <input
              className={inputCls}
              value={draft.payee}
              onChange={(e) => setD("payee", e.target.value)}
              placeholder={headerPayee || "inherits header"}
            />
          </div>
          {creditMode && (
            <div>
              <label className={labelCls}>Party (this line)</label>
              <Sel
                value={draft.party_code}
                onChange={(v) => setD("party_code", v)}
                allowBlank
                options={parties.map((p) => ({
                  code: p.party_code,
                  label: p.name,
                }))}
              />
            </div>
          )}
          <div className="flex gap-2">
            <button
              className="border rounded px-3 py-1.5 text-sm bg-white hover:bg-gray-50"
              onClick={commitDraft}
              title="Enter"
            >
              Add line ⏎
            </button>
          </div>
        </div>
      </section>

      {/* ---------------- save row ---------------- */}
      <section className="flex items-center gap-4 mb-4">
        <button
          className="bg-blue-700 text-white rounded px-5 py-2 font-medium disabled:opacity-50"
          disabled={saving}
          onClick={onSave}
        >
          {saving ? "Saving…" : "Save voucher"}
        </button>
        <span className="text-sm text-gray-600">
          {lines.length + (draftProblems(draft).length === 0 ? 1 : 0)} line
          {lines.length === 1 ? "" : "s"} · total ₹ {formatINR(voucherTotal)}
        </span>
      </section>

      {/* ---------------- what the database said ---------------- */}
      {lastResult && !lastResult.ok && (
        <div className="border border-red-300 bg-red-50 text-red-800 rounded p-3 mb-4 whitespace-pre-wrap text-sm">
          <strong>Not saved.</strong> {lastResult.message}
        </div>
      )}
      {lastResult && lastResult.ok && (
        <div className="border border-green-300 bg-green-50 rounded p-3 mb-4">
          <div className="text-sm text-green-900 mb-1">
            Saved{lastResult.entry_type === "SAMPLE" ? " (SAMPLE mode)" : ""}.
            Write this number on the slip:
          </div>
          {/* §5: the number, large and copyable — the next act is a pen */}
          <div
            className="text-3xl font-mono font-bold tracking-wide select-all cursor-pointer"
            title="Click to copy"
            onClick={() =>
              navigator.clipboard?.writeText(lastResult.voucher_no)
            }
          >
            {lastResult.voucher_no}
          </div>
          {lastResult.warnings.length > 0 && (
            <ul className="mt-2 text-sm text-amber-800 list-disc pl-5">
              {lastResult.warnings.map((w, i) => (
                <li key={i}>{w}</li>
              ))}
            </ul>
          )}
        </div>
      )}

      {/* ---------------- session strip (§5 batch working) ---------------- */}
      {session.length > 0 && (
        <section className="fixed bottom-0 left-0 right-0 bg-gray-900 text-gray-100 text-sm px-4 py-2 flex gap-6 overflow-x-auto">
          <span className="text-gray-400 shrink-0">This sitting:</span>
          {session.map((s, i) => (
            <span key={i} className="shrink-0 font-mono">
              <strong>{s.voucher_no}</strong>
              {s.payee && <span className="text-gray-400"> · {s.payee}</span>}
              <span className="text-gray-400"> · ₹{formatINR(s.total)}</span>
            </span>
          ))}
        </section>
      )}
    </main>
  );
}

// ---------------------------------------------------------------------------
// ActivityPicker — type-ahead over the ACTIVITY master.
//
// Substring match, not prefix (§3F2: "spray" must find WEEDICIDE SPRAY),
// against the LABEL. Alias search and ranking-by-use are deferred by owner
// decision (19-07-2026); when they arrive they arrive as fn_search_activities
// server-side, and this component swaps its filter for that call — the
// keyboard behaviour stays.
//
// Keys: type to filter, ↑↓ to move, Enter to pick, Escape to close.
// ---------------------------------------------------------------------------
function ActivityPicker({
  activities,
  value,
  onPick,
}: {
  activities: MasterRow[];
  value: string;
  onPick: (code: string) => void;
}) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);

  const picked = activities.find((a) => a.code === value);
  const shown = open ? text : (picked?.label ?? "");

  const matches = useMemo(() => {
    const q = text.trim().toLowerCase();
    if (!q) return activities.slice(0, 12);
    return activities
      .filter((a) => a.label.toLowerCase().includes(q))
      .slice(0, 12);
  }, [text, activities]);

  function choose(a: MasterRow) {
    onPick(a.code);
    setOpen(false);
    setText("");
  }

  return (
    <div className="relative">
      <input
        className="border rounded px-2 py-1 text-sm w-full focus:outline-none focus:ring-2 focus:ring-blue-400"
        value={shown}
        placeholder="e.g. spray, fence, tholuvam…"
        onFocus={() => {
          setOpen(true);
          setText("");
          setHi(0);
        }}
        onChange={(e) => {
          setText(e.target.value);
          setOpen(true);
          setHi(0);
        }}
        onKeyDown={(e) => {
          if (!open) return;
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setHi((h) => Math.min(h + 1, matches.length - 1));
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            setHi((h) => Math.max(h - 1, 0));
          } else if (e.key === "Enter") {
            e.preventDefault();
            e.stopPropagation(); // don't commit the line while picking
            if (matches[hi]) choose(matches[hi]);
          } else if (e.key === "Escape") {
            e.stopPropagation(); // close the picker, don't clear the line
            setOpen(false);
          }
        }}
        onBlur={() => setTimeout(() => setOpen(false), 150)}
      />
      {open && matches.length > 0 && (
        <ul className="absolute z-10 mt-1 w-full max-h-64 overflow-auto border rounded bg-white shadow-lg text-sm">
          {matches.map((a, i) => (
            <li
              key={a.code}
              className={
                "px-2 py-1.5 cursor-pointer " +
                (i === hi ? "bg-blue-600 text-white" : "hover:bg-gray-100")
              }
              onMouseDown={(e) => {
                e.preventDefault();
                choose(a);
              }}
              onMouseEnter={() => setHi(i)}
            >
              {a.label}
              {a.required_unit && (
                <span
                  className={
                    "ml-2 text-xs " +
                    (i === hi ? "text-blue-200" : "text-gray-400")
                  }
                >
                  {a.required_unit}
                </span>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
