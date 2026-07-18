// lib/dates.ts
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — dates as the user sees them.
//
// THE RULE (project-wide): every date a person reads or types is DD/MM/YYYY.
// Every date on the wire, in the database, or in a payload is ISO yyyy-mm-dd.
// This file is the ONLY place the user-facing format lives. No screen formats
// or parses a date by hand; if the format ever changes, it changes here.
//
// No date library. Thirty lines of our own beats a dependency to pin.
// ---------------------------------------------------------------------------

/** ISO yyyy-mm-dd → DD/MM/YYYY for display. Empty in, empty out. */
export function formatDMY(iso: string | null | undefined): string {
  if (!iso) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return iso; // not ISO — show as-is rather than mangle it
  return `${m[3]}/${m[2]}/${m[1]}`;
}

/**
 * What the user typed → ISO yyyy-mm-dd, or null if it isn't a real date.
 *
 * Accepts, in day-month-year order always (this is India, §-settled):
 *   18/07/2026   18-07-2026   18.07.2026
 *   18/07/26     (2-digit year → 20xx)
 *   18072026     (bare 8 digits)
 *   180726       (bare 6 digits)
 *
 * Rejects anything else, including real-but-impossible dates (31/02/2026).
 * Never guesses month-first: 07/18/2026 is simply not a date here.
 */
export function parseDMY(text: string): string | null {
  const t = text.trim();
  if (!t) return null;

  let d: number, mo: number, y: number;

  const sep = /^(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2}|\d{4})$/.exec(t);
  const bare8 = /^(\d{2})(\d{2})(\d{4})$/.exec(t);
  const bare6 = /^(\d{2})(\d{2})(\d{2})$/.exec(t);

  if (sep) {
    d = +sep[1]; mo = +sep[2]; y = +sep[3];
  } else if (bare8) {
    d = +bare8[1]; mo = +bare8[2]; y = +bare8[3];
  } else if (bare6) {
    d = +bare6[1]; mo = +bare6[2]; y = +bare6[3];
  } else {
    return null;
  }

  if (y < 100) y += 2000;

  // Reject impossible dates: build the date and check it round-trips.
  // (JS Date happily turns 31 Feb into 3 Mar; the round-trip catches that.)
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (
    dt.getUTCFullYear() !== y ||
    dt.getUTCMonth() !== mo - 1 ||
    dt.getUTCDate() !== d
  )
    return null;

  const pad = (n: number) => String(n).padStart(2, "0");
  return `${y}-${pad(mo)}-${pad(d)}`;
}

/** ₹ figure in Indian digit grouping: 123456.5 → "1,23,456.50" */
export function formatINR(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return "";
  return n.toLocaleString("en-IN", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}
