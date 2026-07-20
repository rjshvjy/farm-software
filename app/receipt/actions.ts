// https://github.com/rjshvjy/farm-software/blob/main/app/receipt/actions.ts
// app/receipt/actions.ts
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the write path from the RECEIPT screen.
//
// Same contract as app/entry/actions.ts (§5): the screen collects, this
// carries, the database judges. One function only — createParty is shared
// with the payment screen and imported by the client component straight from
// app/entry/actions.ts, because a party is a party whichever direction the
// money moves.
//
// saveReceipt → fn_save_voucher with p_voucher_type = 'RECEIPT' (file 12).
// The type routes the voucher into its own gap-free series (R/26/0001) and
// tells the database to demand at least one money-in line. Everything else —
// narration floors, bank-needs-party, one-time rules, the entity guard, the
// receipt-side pattern warning — lives in the database and comes back either
// as warnings on success or as the refusal message verbatim.
// ---------------------------------------------------------------------------
"use server";

import { createClient } from "@/lib/supabase/server";

/**
 * One receipt line as fn_save_voucher expects it. All dates ISO yyyy-mm-dd.
 *
 * The single structural difference from VoucherLine: received_cr, not
 * paid_out_dr. The database enforces exactly-one-side per row
 * (num_nonnulls = 1, §13 "never both Dr and Cr on one row"); this type
 * mirrors that by simply not having the other column.
 *
 * capex_flag is deliberately ABSENT: a receipt is not spending, so the flag
 * is meaningless here, and fn_save_voucher's own coalesce supplies the
 * database default. Omitting it beats sending a literal the master owns.
 * mandays is likewise absent — nobody's labour is counted on a money-in line.
 */
export type ReceiptLine = {
  payment_date: string; // the DB column name; on this screen it is the receipt date
  period_from?: string | null; // REQUIRED by the DB (A5); optional in the
  period_to?: string | null;   // type only so the DB stays the judge.
  entity: string;
  farm: string;
  block?: string | null;
  cost_object: string;
  activity: string;
  cost_nature?: string | null; // REQUIRED by the DB (A7); same reasoning.
  qty?: number | null;         // blank saves, flagged QTY NOT WRITTEN where the
  unit?: string | null;        // activity's master carries a required_unit —
                               // owner's ruling 20-07: flag, never refuse.
  rate?: number | null;        // ₹ per unit sold; qty × rate is the DB's
                               // realisation check (warning on mismatch).
  received_cr: number;
  mode: string;
  party_code?: string | null;
  payee?: string | null;       // 'ONE TIME' when the one-time toggle is on
  narration?: string | null;
};

export type SaveReceiptResult =
  | {
      ok: true;
      voucher_no: string; // R/26/nnnn — its own series since file 12
      entry_type: string;
      warnings: string[];
      /** CASH in hand AFTER the save (a cash receipt raises it). Null if the
       *  read failed — the save succeeded regardless; the header shows "—". */
      cash_balance: number | null;
    }
  | {
      ok: false;
      /** The database's own words, verbatim. It names the line number. */
      message: string;
    };

export async function saveReceipt(
  lines: ReceiptLine[],
): Promise<SaveReceiptResult> {
  const supabase = await createClient();

  // Belt-and-braces: the proxy guards the route, but a server action is
  // callable on its own, so it checks for itself.
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) {
    return { ok: false, message: "Not signed in. Refresh and log in again." };
  }

  const { data, error } = await supabase.rpc("fn_save_voucher", {
    p_lines: lines,
    p_voucher_type: "RECEIPT", // file 12: routes to the R/ series and the
                               // at-least-one-money-in rule
  });

  if (error) {
    // The RAISE text from Postgres — already written for a human, already
    // naming the offending line. Pass it through untouched.
    return { ok: false, message: error.message };
  }

  // Fresh CASH figure; a failure here must not fail the save.
  let cash: number | null = null;
  const bal = await supabase
    .from("v_pocket_balances")
    .select("mode, balance")
    .eq("mode", "CASH")
    .maybeSingle();
  if (!bal.error && bal.data) cash = Number(bal.data.balance);

  return {
    ok: true,
    voucher_no: data.voucher_no as string,
    entry_type: data.entry_type as string,
    warnings: (data.warnings ?? []) as string[],
    cash_balance: cash,
  };
}
