// https://github.com/rjshvjy/farm-software/blob/main/app/expense/expense-actions.ts
// app/expense/expense-actions.ts
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the write path from the business expense screen (§19).
//
// THE CONTRACT (§5, restated, unchanged from app/entry/actions.ts): the screen
// collects fields, this action calls the database function, and whatever comes
// back — voucher number, warnings, or a refusal — is returned untouched for the
// screen to display. No rule is checked here. No rule is checked in the screen.
// The rules live in the database, and this file's job is to carry the
// accountant's own session to it, so entered_by is her email and §2's "entered
// by cannot be faked" stays true.
//
// That is why this uses the cookie-session client from lib/supabase/server —
// NEVER a service-role key. A service-role call would save vouchers as a
// machine identity and bypass row-level security besides.
//
// ---------------------------------------------------------------------------
// WHY THIS IS A SECOND ACTION FILE AND NOT A CHANGE TO app/entry/actions.ts
// ---------------------------------------------------------------------------
//
// app/entry sends a FLAT list of lines. Under §19 the business expense voucher
// is three levels — voucher, task, row — because the estate's weekly wage paper
// is a bundle of about thirteen workings, each with its own place, work,
// measured output and several people at different rates (§16.23).
//
// The database has accepted that shape since file 18: fn_save_voucher takes
// p_tasks and p_header alongside the old p_lines, and flattens the nested form
// into the flat one before any rule runs. THE FLAT PATH IS UNCHANGED, which is
// why app/entry and app/sales needed no edit when file 18 landed.
//
// app/entry is left alone and will be DELETED once this screen is proven on the
// real 13/07 paper. It is not repaired: it sends no p_voucher_type at all, so
// it defaults to PAYMENT, whose shape is SETTLEMENT, and every save has been
// refused since file 15 gave settlements their own rules. Repairing a screen
// that is about to be deleted is work thrown away.
//
// ---------------------------------------------------------------------------
// THE CALL, AND WHY IT LOOKS LIKE THIS
// ---------------------------------------------------------------------------
//
//   fn_save_voucher(
//     p_lines        => '[]',        -- unused on this path
//     p_voucher_type => 'PURCHASE',  -- PB/ series, TRANSACTION shape
//     p_header       => { ... },     -- what every line shares
//     p_tasks        => [ ... ]      -- the workings, each with its people
//   )
//
// Verified working end to end on 21/07/2026: two tasks, three rows, saved as
// PB/26/0004 with the quantity landing on the first row of each task and
// nowhere else.
//
// p_lines is sent as an EMPTY ARRAY rather than omitted. File 18 originally
// refused that — it tested "p_lines is not null", and an empty array is not
// null — which would have rejected this exact call. File 18a fixed it so
// emptiness counts as absence. Sending '[]' is therefore safe AND is what the
// build handover documented, so it is what this sends.
//
// ---------------------------------------------------------------------------
// WHAT THIS ACTION DECIDES, RATHER THAN TRUSTING THE SCREEN
// ---------------------------------------------------------------------------
//
// ENTITY IS FORCED TO 'BUSINESS' HERE. §19.2 says the expense screen fixes it
// and does not offer it — household is §20's own voucher type. Setting it in
// the action rather than in the form means no amount of screen state can send
// anything else. This is the same discipline fn_save_voucher itself applies on
// the drawings path, where the function overrides entity to PERSONAL and does
// not take the screen's word for it (§20.1).
//
// TASK NUMBERS ARE NOT SENT. The function assigns task_no in document order and
// writes the work quantity to each task's FIRST row only (§19.4). The screen
// cannot get that wrong if it never sends it — which is the point.
//
// Everything else is passed through exactly as typed. In particular this action
// does NOT drop empty tasks, does NOT total anything, and does NOT round. A
// task with no rows is refused by the database with a message the accountant
// can act on, and that is better than a screen silently discarding her work.
// ---------------------------------------------------------------------------
"use server";

import { createClient } from "@/lib/supabase/server";

// ---------------------------------------------------------------------------
// THE SHAPES
//
// All dates ISO yyyy-mm-dd. The screen shows and accepts DD/MM/YYYY (§16.12)
// and converts at the edge with lib/dates — the database is never handed a
// display format.
//
// Optional fields are optional in the TYPE only, so a partly-filled screen
// still compiles. The database is the judge of what is actually required, and
// its refusal text names the offending line. Mirrors the note in
// app/entry/actions.ts on period_from and cost_nature.
// ---------------------------------------------------------------------------

/** Typed once per paper slip. Every task and row inherits from it. */
export type ExpenseHeader = {
  payment_date: string;
  period_from: string;
  period_to: string;
  /** The default pocket. Every row inherits it; any row may override. */
  mode: string;
  /** The paper's own reference number, if it has one (§2). Optional. */
  doc_ref_no?: string | null;
  /** The date printed on the paper itself — NOT the payment date (§2). */
  doc_ref_date?: string | null;
  /**
   * The total written on the paper. Optional, and a WARNING when it disagrees
   * with the lines — never a refusal. On the estate's real weekly paper it
   * SHOULD disagree, because cooking wages belongs on a drawings voucher.
   */
  paper_total?: number | null;
};

/** One person on one task: days x rate. A row IS a person (§16.23). */
export type ExpenseRow = {
  /** A real party, or leave null and set payee to 'ONE TIME' for a one-off. */
  party_code?: string | null;
  /** 'ONE TIME' triggers the one-off rules; the name goes in the narration. */
  payee?: string | null;
  /** Halves are normal — 8.5, 10.5. Null on contract and lump-sum rows. */
  mandays?: number | null;
  /** Pre-filled from parties.default_rate, always overridable (§19.2). */
  rate?: number | null;
  paid_out_dr: number;
  /** Overrides the header pocket for this row only. */
  mode?: string | null;
  /** Overrides the task narration for this row only ("Savithri, half day"). */
  narration?: string | null;
};

/**
 * One piece of work: where, what, and how much of it. One numbered working on
 * the back of the paper.
 *
 * farm and block are OPTIONAL because since file 18a the farm is demanded only
 * when the cost object sits on land. A herd is an enterprise, not a place, so
 * cattle and goat work carries no farm; nor does administration, whose cost
 * object is NA. The screen greys those fields out for such cost objects and
 * sends nothing.
 */
export type ExpenseTask = {
  farm?: string | null;
  block?: string | null;
  cost_object: string;
  activity: string;
  capex_flag?: string | null;
  cost_nature: string;
  /** Written ONCE per task. The function puts it on the first row only. */
  qty?: number | null;
  unit?: string | null;
  /** Only for a well or a big contract; blank on ordinary work (§16.25). */
  job_id?: string | null;
  narration: string;
  /**
   * The task's own total off the paper, if the accountant typed it. REFUSED
   * when the rows disagree — the paper says what this piece of work cost, and
   * if the rows do not add to it, one of them is wrong or missing.
   */
  total?: number | null;
  rows: ExpenseRow[];
};

export type ExpenseSaveResult =
  | {
      ok: true;
      voucher_no: string;
      /** How many tasks the database numbered. Should match what was sent. */
      tasks: number;
      entry_type: string;
      warnings: string[];
      /**
       * The header pocket's balance per v_pocket_balances, read AFTER the save
       * so the header figure is live without a page refresh. Null if the read
       * failed — the save itself succeeded regardless, and the screen shows
       * "—" rather than a stale number dressed up as a fresh one.
       */
      pocket_balance: number | null;
    }
  | {
      ok: false;
      /** The database's own words, verbatim. It names the line number. */
      message: string;
    };

// ---------------------------------------------------------------------------
// saveExpenseVoucher
// ---------------------------------------------------------------------------

export async function saveExpenseVoucher(
  header: ExpenseHeader,
  tasks: ExpenseTask[],
): Promise<ExpenseSaveResult> {
  const supabase = await createClient();

  // Belt-and-braces: the page already redirects unauthenticated users, but a
  // server action is callable on its own, so it checks for itself.
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) {
    return { ok: false, message: "Not signed in. Refresh and log in again." };
  }

  const { data, error } = await supabase.rpc("fn_save_voucher", {
    // Empty, not omitted — see the note at the top of this file.
    p_lines: [],
    p_voucher_type: "PURCHASE",
    p_header: {
      payment_date: header.payment_date,
      period_from: header.period_from,
      period_to: header.period_to,
      // Forced here, never taken from the form (§19.2).
      entity: "BUSINESS",
      mode: header.mode,
      doc_ref_no: header.doc_ref_no ?? null,
      doc_ref_date: header.doc_ref_date ?? null,
      paper_total: header.paper_total ?? null,
    },
    p_tasks: tasks,
  });

  if (error) {
    // error.message is the RAISE text from Postgres — already written for a
    // human, already naming the offending line. Pass it through untouched.
    //
    // Worth knowing when reading these: the database numbers LINES, not tasks.
    // A voucher of three tasks with two people each refuses at "Line 5", which
    // is the first row of the third task. The screen maps line numbers back to
    // task and row so it can highlight the right box.
    return { ok: false, message: error.message };
  }

  // The fresh pocket figure. A failure here must not fail the save — the
  // voucher exists; the header just cannot update this once.
  //
  // Reads the header's OWN pocket rather than always CASH, because an expense
  // voucher may be paid from a bank pocket and showing the cash balance after
  // a bank payment would be worse than showing nothing.
  let pocket: number | null = null;
  const bal = await supabase
    .from("v_pocket_balances")
    .select("mode, balance")
    .eq("mode", header.mode)
    .maybeSingle();
  if (!bal.error && bal.data) pocket = Number(bal.data.balance);

  // fn_save_voucher returns:
  // { voucher_no, voucher_type, tasks, row_ids, entry_type, warnings: [] }
  return {
    ok: true,
    voucher_no: data.voucher_no as string,
    tasks: Number(data.tasks ?? 0),
    entry_type: data.entry_type as string,
    warnings: (data.warnings ?? []) as string[],
    pocket_balance: pocket,
  };
}

// ---------------------------------------------------------------------------
// createExpenseParty — inline party creation during entry
//
// DELIBERATE DUPLICATE, TEMPORARILY. app/entry/actions.ts has an identical
// createParty. It is copied rather than imported because app/entry is going to
// be deleted, and importing from a folder marked for deletion would turn a
// tidy-up into a breakage. When app/entry goes, this becomes the only copy and
// the duplication ends. The name differs (createExpenseParty) so the two are
// never confused while both exist.
//
// Calls fn_party_upsert, which demands MASTER_APPEND (the accountant has it)
// or MASTER_MANAGE (the owner). party_code is the stable identity and is never
// rewritten (§13's rename ban, applied to parties).
//
// NOTE ON THE UPSERT: fn_party_upsert overwrites name/kind on a code collision
// BY DESIGN. The SCREEN therefore checks the proposed code against its loaded
// party list BEFORE calling this, and only sends a code it believes to be free
// — or one the user explicitly chose to reuse. This action does not
// re-implement that check: the screen owns the question ("use existing or
// create new?") because a database cannot ask a question.
//
// WHY THIS MATTERS MORE ON THIS SCREEN THAN THE OLD ONE. Under §19 a row IS a
// person, so a thirteen-task wage paper names thirty or forty people. The
// first time a new labourer appears, entry must not hit a wall.
// ---------------------------------------------------------------------------

/**
 * A party kind. Plain string since file 10: the permitted values live in the
 * PARTY_KIND master, not in a frozen union here. The database validates
 * against the master by trigger, so an invalid kind is refused there with a
 * message naming the fix.
 */
export type PartyKind = string;

export type CreateExpensePartyResult =
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

export async function createExpenseParty(
  code: string,
  name: string,
  kind: PartyKind,
  mobile?: string | null,
  /** File 10. Omitted, the database takes it from the kind's own default. */
  defaultEntity?: string | null,
): Promise<CreateExpensePartyResult> {
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
