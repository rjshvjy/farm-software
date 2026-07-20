// https://github.com/rjshvjy/farm-software/blob/main/components/entry/ui.tsx
// components/entry/ui.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — shared leaf pieces of the entry screens.
//
// EXTRACTED VERBATIM from app/entry/VoucherEntry.tsx on 20-07-2026 so the
// receipt screen (Stage A, §17.6) can use the same bands, pickers and
// amount-in-words WITHOUT copy-pasting 1,900 lines that would then drift —
// the CAPEX/CAPITAL fallback bug is exactly what drift looks like.
//
// WHAT BELONGS HERE: leaf pieces with NO business logic and NO screen
// state — style constants, the band frame, the select, the type-ahead,
// amount in words. Nothing here knows what a voucher is.
//
// WHAT DOES NOT BELONG HERE (deliberately, keep it that way):
//   - AddPartyPanel, deriveCode, bumpCode — they carry the default-kind
//     decision, which differs per screen (DAILY LABOUR on payments; a
//     trade kind on receipts). They move here only when that default
//     becomes a prop, in the receipt-screen commit where the intent is
//     explicit.
//   - The preview panel, eff(), the five-band composition — per-screen by
//     design. A shared preview panel becomes a component with fifteen
//     boolean props; two honest copies are cheaper than one dishonest
//     abstraction.
//
// THE FOCUS RULE TRAVELS WITH THE CODE: these are module level because a
// component defined inside a screen component is re-created on every
// keystroke — React unmounts and remounts the field and the cursor falls
// out (19-07 evening bug). Never define components inside a screen.
// ---------------------------------------------------------------------------
"use client";

import React, { useState } from "react";

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
export const inputCls =
  "border border-input bg-background rounded px-2 py-1.5 text-base w-full " +
  "focus:outline-none focus:ring-2 focus:ring-ring";
export const labelCls = "block text-sm text-muted-foreground mb-1";
export const numCls = inputCls + " text-right tabular-nums";

/**
 * One labelled band of the line. The heading is the QUESTION the fields
 * answer — Where, What work, On what, How much, Who and why. A shaded
 * heading strip over a bordered body makes the five bands read as five
 * sections at a glance; items-end keeps every input box on one baseline
 * even where a label wraps to two lines.
 */
export function FieldBand({
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
export function BandHint({ children }: { children: React.ReactNode }) {
  return (
    <div className="col-span-2 md:col-span-6 text-sm text-muted-foreground -mt-1">
      {children}
    </div>
  );
}

export function Sel({
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
export function Combo({
  value,
  display,
  onChange,
  options,
  placeholder,
  onFocus,
  onAddNew,
  inputRef,
  disabled,
}: {
  value: string;
  display: string; // label shown when not searching
  onChange: (code: string) => void;
  options: { code: string; label: string; sub?: string }[];
  placeholder?: string;
  onFocus?: () => void;
  onAddNew?: (typed: string) => void;
  inputRef?: React.RefObject<HTMLInputElement | null>;
  /** Locked: no typing, no list, no "+ Add". Used by the one-time toggle,
   *  which must not leave a door open to creating a party at the same
   *  moment the line declares it has no party. */
  disabled?: boolean;
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
  const showAdd = !!onAddNew && !disabled && q.length > 0 && !exact;
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
        className={
          inputCls +
          (disabled ? " opacity-60 cursor-not-allowed bg-muted" : "")
        }
        disabled={disabled}
        value={open && !disabled ? text : display}
        placeholder={placeholder}
        onFocus={() => {
          if (disabled) return;
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
      {open && !disabled && rows > 0 && (
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
