// https://github.com/rjshvjy/farm-software/blob/main/components/entry/AddPartyPanel.tsx
// components/entry/AddPartyPanel.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the inline "New party" panel, shared by the payment
// and receipt screens.
//
// MOVED from app/entry/VoucherEntry.tsx on 20-07-2026, in the receipt-screen
// commit, for one stated reason: the panel is identical on both screens
// EXCEPT for which kind it defaults to — DAILY LABOUR on payments (1,821
// labour rows against 599 supplier rows in the v9 workbook), CUSTOMER on
// receipts (the person in front of you is usually buying produce). That
// difference is now the `defaultKind` prop; each screen states its own, and
// the panel resolves it AGAINST THE LOADED LIST — an absent kind falls back
// to the first selectable one, so the panel never sends a value the master
// does not hold.
//
// Everything else is verbatim from the payment screen, including the
// collision behaviour: fn_party_upsert overwrites on a code clash BY DESIGN,
// so this panel checks the proposed code against the loaded list first and
// makes the person choose — use the existing party, or take the auto-bumped
// code. The database cannot ask a question; the screen owns this one.
//
// Module level for the same reason as everything in ui.tsx: a component
// defined inside a screen is re-created every keystroke and drops focus.
// ---------------------------------------------------------------------------
"use client";

import React, { useState } from "react";
import { inputCls, labelCls } from "@/components/entry/ui";
import type { PartyKind } from "@/app/entry/actions";
// Type-only imports are erased at build time, so this creates no runtime
// cycle with the screens that import this panel.
import type { PartyRow, PartyKindRow } from "@/app/entry/VoucherEntry";

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
// AddPartyPanel — inline, not a modal, not a page. Name prefilled from what
// she typed; code derived and collision-checked live against the loaded list
// (fn_party_upsert overwrites on collision by design — the screen owns this
// question). On a clash: use the existing party, or take the auto-bumped
// code. Mobile optional (decision C3). Parent state arrives as props so this
// component can live at module level and keep focus while typing.
// ---------------------------------------------------------------------------
export function AddPartyPanel({
  typed,
  partyByCode,
  partyKinds,
  defaultKind,
  busy,
  err,
  onSave,
  onUseExisting,
  onCancel,
}: {
  typed: string;
  partyByCode: Map<string, PartyRow>;
  partyKinds: PartyKindRow[];
  /** The kind this SCREEN thinks a new party most likely is. Resolved against
   *  the loaded list; absent or unknown falls back to the first selectable
   *  kind. Payments pass DAILY LABOUR, receipts pass CUSTOMER. */
  defaultKind?: string;
  busy: boolean;
  err: string | null;
  onSave: (
    code: string,
    name: string,
    kind: PartyKind,
    mobile: string,
    defaultEntity: string | null,
  ) => void;
  onUseExisting: (code: string) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(typed);
  const [code, setCode] = useState(deriveCode(typed));
  // The screen's stated default, resolved against the list actually loaded.
  // Defaults should match each screen's common case, not the alphabet.
  const [kind, setKind] = useState<PartyKind>(
    defaultKind && partyKinds.some((k) => k.code === defaultKind)
      ? defaultKind
      : (partyKinds[0]?.code ?? ""),
  );
  const [mobile, setMobile] = useState("");

  const clash = partyByCode.get(code.trim().toUpperCase()) ?? null;
  const codeOk = code.trim().length > 0 && !clash;
  const bumped = bumpCode(deriveCode(name), (c) =>
    partyByCode.has(c.toUpperCase()),
  );

  // Kinds grouped for the dropdown, preserving the view's sort order.
  const grouped: { group: string; rows: PartyKindRow[] }[] = [];
  for (const k of partyKinds) {
    const last = grouped[grouped.length - 1];
    if (last && last.group === k.group_label) last.rows.push(k);
    else grouped.push({ group: k.group_label, rows: [k] });
  }

  const chosen = partyKinds.find((k) => k.code === kind) ?? null;

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
          <label className={labelCls}>
            Kind
            {chosen?.default_entity && (
              <span className="text-muted-foreground">
                {" "}
                · usually {chosen.default_entity.toLowerCase()}
              </span>
            )}
          </label>
          {partyKinds.length === 0 ? (
            // File 10 not run: say so plainly rather than offer a wrong list.
            <div className="text-sm text-red-700 dark:text-red-400 py-1.5">
              No party kinds loaded — run SQL file 10.
            </div>
          ) : (
            <select
              className={inputCls}
              value={kind}
              onChange={(e) => setKind(e.target.value)}
            >
              {grouped.map((g) => (
                <optgroup key={g.group} label={g.group}>
                  {g.rows.map((k) => (
                    <option key={k.code} value={k.code}>
                      {k.label}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          )}
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
          disabled={!codeOk || !name.trim() || !kind || busy}
          onClick={() =>
            onSave(
              code.trim(),
              name.trim(),
              kind,
              mobile,
              chosen?.default_entity ?? null,
            )
          }
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
