// https://github.com/rjshvjy/farm-software/blob/main/app/entry/actions.ts
// app/entry/actions.ts
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the write paths from the entry screen.
//
// THE CONTRACT (§5, restated): the screen collects fields, these actions call
// the database functions, and whatever comes back — voucher number, warnings,
// or a refusal — is returned untouched for the screen to display. No rule is
// checked here. No rule is checked in the screen. The rules live in the
// database, and this file's job is to carry the accountant's own session to
// it, so entered_by is her email and §2's "entered by cannot be faked" stays
// true.
//
// That is why this uses the cookie-session client from lib/supabase/server —
// NEVER a service-role key. A service-role call would save vouchers as a
// machine identity and bypass row-level security besides.
//
// TWO ACTIONS NOW (19-07-2026 update, handover Part 2 §2):
//   saveVoucher  → fn_save_voucher   (unchanged path; result now also carries
//                                     the fresh CASH balance for the header)
//   createParty  → fn_party_upsert   (inline party add — a BANK voucher must
//                                     never hit a wall for want of a party)
// ---------------------------------------------------------------------------
"use server";

import { createClient } from "@/lib/supabase/server";

/** One voucher line as fn_save_voucher expects it. All dates ISO yyyy-mm-dd. */
export type VoucherLine = {
  payment_date: string;
  period_from?: string | null; // REQUIRED by the DB since file 08 (A5);
  period_to?: string | null;   // optional in the type only so an old build
                               // still compiles — the DB is the judge.
  entity: string;
  farm: string;
  block?: string | null;
  cost_object: string;
  activity: string;
  capex_flag?: string;
  cost_nature?: string | null; // REQUIRED by the DB since file 08 (A7);
                               // same reason for staying optional here.
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
      /**
       * CASH in hand per v_pocket_balances, read AFTER the save so the header
       * figure is live without a page refresh. Null if the read failed — the
       * save itself succeeded regardless, and the screen shows "—" rather
       * than a stale number dressed up as a fresh one.
       */
      cash_balance: number | null;
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

  // The fresh CASH figure. A failure here must not fail the save — the
  // voucher exists; the header just cannot update this once.
  let cash: number | null = null;
  const bal = await supabase
    .from("v_pocket_balances")
    .select("mode, balance")
    .eq("mode", "CASH")
    .maybeSingle();
  if (!bal.error && bal.data) cash = Number(bal.data.balance);

  // fn_save_voucher returns:
  // { voucher_no, row_ids, entry_type, warnings: [] }
  return {
    ok: true,
    voucher_no: data.voucher_no as string,
    entry_type: data.entry_type as string,
    warnings: (data.warnings ?? []) as string[],
    cash_balance: cash,
  };
}

// ---------------------------------------------------------------------------
// createParty — inline party creation during entry (handover Part 2 §2.4).
//
// Calls fn_party_upsert, which demands MASTER_APPEND (the accountant has it)
// or MASTER_MANAGE (the owner). party_code is the stable identity and is
// never rewritten (§13's rename ban, applied to parties).
//
// NOTE ON THE UPSERT: fn_party_upsert overwrites name/kind on a code
// collision by design (re-entering a party updates it). The SCREEN therefore
// checks the proposed code against its loaded party list BEFORE calling this,
// and only sends a code it believes to be free — or one the user explicitly
// chose to reuse. This action does not re-implement that check: the screen
// owns the question ("use existing or create new?") because a database
// cannot ask a question.
// ---------------------------------------------------------------------------

/**
 * A party kind. Plain string since file 10: the permitted values live in the
 * PARTY_KIND master, not in a frozen union here. The old three-way
 * SUPPLIER/CUSTOMER/BOTH was a trade taxonomy, and this estate pays almost
 * nobody who fits it — 1,821 labour rows against 599 supplier rows in the v9
 * workbook. A tractor driver had to be filed as a SUPPLIER.
 *
 * The database validates against the master by trigger, so an invalid kind is
 * refused there with a message naming the fix. Nothing is lost by widening the
 * type; the authority simply moved to where it belongs.
 */
export type PartyKind = string;

export type CreatePartyResult =
  | {
      ok: true;
      /** As fn_party_upsert stored it (code uppercased/trimmed by the DB). */
      party: {
        party_code: string;
        name: string;
        kind: PartyKind;
        default_entity: string | null;
      };
    }
  | { ok: false; message: string };

export async function createParty(
  code: string,
  name: string,
  kind: PartyKind,
  mobile?: string | null,
  /** File 10. Omitted, the database takes it from the kind's own default. */
  defaultEntity?: string | null,
): Promise<CreatePartyResult> {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) {
    return { ok: false, message: "Not signed in. Refresh and log in again." };
  }

  const { data, error } = await supabase.rpc("fn_party_upsert", {
    p_code: code,
    p_name: name,
    p_kind: kind,
    p_mobile: mobile ?? null,
    p_notes: null,
    p_default_entity: defaultEntity ?? null,
  });

  if (error) {
    return { ok: false, message: error.message };
  }

  // fn_party_upsert returns the stored code (uppercased, trimmed).
  return {
    ok: true,
    party: {
      party_code: data as string,
      name: name.trim(),
      kind,
      default_entity: defaultEntity ?? null,
    },
  };
}
