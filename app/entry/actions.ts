// app/entry/actions.ts
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the one write path from the entry screen.
//
// THE CONTRACT (§5, restated): the screen collects fields, this action calls
// fn_save_voucher, and whatever comes back — voucher number, warnings, or a
// refusal — is returned untouched for the screen to display. No rule is
// checked here. No rule is checked in the screen. The rules live in the
// database, and this file's job is to carry the accountant's own session to
// it, so entered_by is her email and §2's "entered by cannot be faked" stays
// true.
//
// That is why this uses the cookie-session client from lib/supabase/server —
// NEVER a service-role key. A service-role call would save vouchers as a
// machine identity and bypass row-level security besides.
// ---------------------------------------------------------------------------
"use server";

import { createClient } from "@/lib/supabase/server";

/** One voucher line as fn_save_voucher expects it. All dates ISO yyyy-mm-dd. */
export type VoucherLine = {
  payment_date: string;
  period_from?: string | null;
  period_to?: string | null;
  entity: string;
  farm: string;
  block?: string | null;
  cost_object: string;
  activity: string;
  capex_flag?: string;
  cost_nature?: string | null;
  qty?: number | null;
  unit?: string | null;
  mandays?: number | null;
  rate?: number | null;
  paid_out_dr: number;
  mode: string;
  party_code?: string | null;
  payee?: string | null;
  narration?: string | null;
};

export type SaveResult =
  | {
      ok: true;
      voucher_no: string;
      entry_type: string;
      warnings: string[];
    }
  | {
      ok: false;
      /** The database's own words, verbatim. It names the line number. */
      message: string;
    };

export async function saveVoucher(lines: VoucherLine[]): Promise<SaveResult> {
  const supabase = await createClient();

  // Belt-and-braces: the page already redirects unauthenticated users, but a
  // server action is callable on its own, so it checks for itself.
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) {
    return { ok: false, message: "Not signed in. Refresh and log in again." };
  }

  const { data, error } = await supabase.rpc("fn_save_voucher", {
    p_lines: lines,
  });

  if (error) {
    // error.message is the RAISE text from Postgres — already written for a
    // human, already naming the offending line. Pass it through untouched.
    return { ok: false, message: error.message };
  }

  // fn_save_voucher returns:
  // { voucher_no, row_ids, entry_type, warnings: [] }
  return {
    ok: true,
    voucher_no: data.voucher_no as string,
    entry_type: data.entry_type as string,
    warnings: (data.warnings ?? []) as string[],
  };
}
