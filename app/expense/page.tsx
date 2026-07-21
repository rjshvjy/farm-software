// https://github.com/rjshvjy/farm-software/blob/main/app/expense/page.tsx
// app/expense/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the business expense voucher, server side (§19).
//
// This is a server component. It loads everything the screen needs, once per
// page load, and hands it to the client screen as props so no dropdown ever
// waits on the network mid-typing. Nothing here writes. The one write path is
// expense-actions.ts.
//
// It follows app/entry/page.tsx almost exactly, because that shape works and
// was arrived at by fixing real failures. FOUR THINGS ARE NEW, and each exists
// because of a decision taken on 21/07/2026:
//
//   1. GROUP HEADINGS ARE EXCLUDED FROM EVERY LIST. File 17a created six
//      ACTIVITY rows — FARM, WEED MGMT, SHARED, HOUSEHOLD, INCOME, FUNDING —
//      so that group_code has something to point at and masters admin can
//      manage groups. They are folder names, not choices. The database refuses
//      them (fn_assert_master, file 18), but /entry currently OFFERS them in
//      its activity dropdown, which is how they were spotted. A list must not
//      offer what the database will refuse.
//
//   2. THE ACTIVITY LIST IS FILTERED TO FARM WORK. group_code in FARM, WEED
//      MGMT and SHARED — 51 of the 77. The 14 household activities are NOT
//      loaded, because cooking wages on a farm voucher is exactly what §20.3
//      exists to prevent: "Cooking and weedicide spraying in one dropdown make
//      both lists worse and invite the wrong choice at 6pm." The 7 income and
//      5 funding activities are not loaded either — income is entered through
//      the sales invoice (Part 0.6) and funding movements belong to the
//      settlement and contra screens.
//
//   3. COST OBJECTS CARRY land_based (file 18a). It decides whether the task
//      block asks for a farm and a block at all. A herd is an enterprise, not
//      a place (§1), so COW and GOAT carry no farm; nor does administration,
//      whose cost object is NA. The database stopped DEMANDING a farm for
//      those; this screen stops OFFERING it.
//
//   4. ALL POCKET BALANCES ARE LOADED, not just CASH. The header chooses the
//      default pocket, so the figure beside it must follow that choice. Paying
//      from a bank pocket while the header shows the cash balance is worse
//      than showing nothing.
//
// -- WHY THE <Suspense> WRAPPER ---------------------------------------------
// This project runs Next 16 with Cache Components enabled (next.config.ts).
// Under that setting, uncached data access — every query below — MUST sit
// inside a Suspense boundary, or the build fails with "Uncached data was
// accessed outside of <Suspense>". So the fetching lives in ExpenseLoader and
// the page's job is only to draw the boundary around it.
//
//   - `export const dynamic = "force-dynamic"` is BANNED under Cache
//     Components. It is also unnecessary: nothing is cached unless explicitly
//     marked, so this page is dynamic by default.
//
// -- A READ THAT FAILS MUST SAY SO ------------------------------------------
// Carried over from app/entry/page.tsx, and worth repeating because it was
// learned the hard way on 20/07: every secondary read used to end in `?? []`,
// which threw the error away and left the screen to invent an explanation.
// The Kind dropdown went empty and the panel blamed "run SQL file 10" — file
// 10 had been run months earlier. Three rounds of diagnosis went into a
// question the screen could have answered in one line. A read that fails must
// SAY it failed and NAME the object, so the next person starts from a fact
// rather than a guess.
// ---------------------------------------------------------------------------
import { Suspense } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import ExpenseVoucher, {
  type MasterRow,
  type PartyRow,
  type PartyKindRow,
  type JobRow,
} from "./ExpenseVoucher";

export default function ExpensePage() {
  return (
    <Suspense
      fallback={
        <main className="p-8 text-sm text-muted-foreground">
          Loading masters…
        </main>
      }
    >
      <ExpenseLoader />
    </Suspense>
  );
}

/**
 * Which activity groups belong on THIS screen (§19.2, §20.3).
 *
 * A literal list here rather than a config row, deliberately and narrowly:
 * this is a statement about what KIND OF SCREEN this is, not a tunable. The
 * drawings screen will carry its own list of one — HOUSEHOLD — for the same
 * reason. Adding an activity is still a master row and needs no deployment;
 * only adding a whole new GROUP would touch this line, and a new group is a
 * change of design, not of data.
 */
const EXPENSE_ACTIVITY_GROUPS = ["FARM", "WEED MGMT", "SHARED"];

/**
 * Farm codes not offered on this screen.
 *
 * HOME is a leftover from before v3.2. Household spending is now a drawings
 * voucher carrying no farm at all (§20), so a farm called HOME can only ever
 * be chosen by mistake. It is not deactivated in the master because rows
 * already point at it; it is simply not offered here.
 *
 * GENERAL is deliberately NOT in this list. It is a real answer — a farm cost
 * genuinely common to all four — and the database flags it FARM NOT SPLIT so
 * it can be counted (file 18a). Hiding it would push those costs onto a
 * wrongly-named farm, which is worse than a flag.
 */
const FARMS_NOT_OFFERED = ["HOME"];

async function ExpenseLoader() {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) redirect("/auth/login");

  // --- everything the screen needs, fetched in parallel -------------------
  const [
    mastersRes,
    partiesRes,
    configRes,
    todayRes,
    pocketsRes,
    statsRes,
    kindsRes,
    jobsRes,
  ] = await Promise.all([
    supabase
      .from("master_values")
      // group_code, is_heading and land_based are new here (files 17, 17a,
      // 18a). They are what let this screen show farm work only, hide the six
      // group headings, and stop asking for a farm on a herd.
      .select(
        "list_name, code, label, sort_order, required_unit, mode_kind, parent_farm, notes, group_code, is_heading, land_based",
      )
      .eq("active", true)
      .order("sort_order", { ascending: true }),
    supabase
      .from("parties")
      // default_rate, labour_category and usual_farm are new here (file 16).
      // Under §19 a ROW IS A PERSON, so a thirteen-task wage paper names
      // thirty or forty people and the rate must pre-fill from the person
      // rather than be typed forty times. Pre-fill, never enforce — the day
      // someone is paid differently is a fact about that day (§19.2).
      .select(
        "party_code, name, kind, default_entity, default_rate, labour_category, usual_farm",
      )
      .eq("status", "ACTIVE")
      .order("name", { ascending: true }),
    supabase
      .from("config")
      .select("key, value")
      // UNSPLIT_FARMS is new here (file 18a): the farm codes that mean "a real
      // farm cost, not split yet". The screen previews the amber flag so she
      // sees it before the round-trip, exactly as it previews the others.
      .in("key", [
        "VAGUE_ACTIVITIES",
        "VAGUE_NARRATION_MIN",
        "NARRATION_MIN",
        "LIVE_MODE",
        "ONE_TIME_MAX",
        "LINE_AMOUNT_WARN",
        "PARTY_WARN_MULT",
        "UNSPLIT_FARMS",
      ]),
    supabase.rpc("fn_today"),
    // ALL pockets, not just CASH — the header picks one and the figure beside
    // it must follow that choice.
    supabase.from("v_pocket_balances").select("mode, balance"),
    // Each party's own payment record (file 09). Feeds the self-calibrating
    // large-amount warning: silent with no history, sharper every month, no
    // per-party settings anywhere. Under §19 this finally fires PER LABOURER,
    // because a row is a person.
    supabase
      .from("v_party_payment_stats")
      .select("party_code, times_paid, max_paid, avg_paid, last_paid"),
    // Selectable party kinds with their group heading (file 10). Group headers
    // are already filtered out by the view — they are headings, never choices.
    supabase
      .from("v_party_kinds")
      .select("code, label, group_label, default_entity, sort_order")
      .order("sort_order", { ascending: true }),
    // Open jobs only (file 16, §16.25). A job is for a well or a big contract
    // and is blank on almost every voucher, so this is usually empty and that
    // is correct. fn_save_voucher REFUSES a closed job rather than warning: a
    // closed job quietly accepting new cost is how a contract total becomes
    // wrong months later, and no report would show it.
    supabase
      .from("jobs")
      .select("job_id, description, farm, cost_object, start_date")
      .eq("status", "OPEN")
      .order("start_date", { ascending: false }),
  ]);

  // A failed masters load means an unusable screen — say so plainly rather
  // than render empty dropdowns that look like data loss.
  if (mastersRes.error || !mastersRes.data?.length) {
    return (
      <main className="p-8 max-w-xl mx-auto">
        <h1 className="text-lg font-semibold mb-2">Business expense voucher</h1>
        <p className="text-red-700">
          Could not load the master lists
          {mastersRes.error ? `: ${mastersRes.error.message}` : ""}. Nothing can
          be entered without them — refresh, and if it persists check that this
          login has an ACTIVE row in app_users.
        </p>
      </main>
    );
  }

  // -- Group masters by list, applying this screen's two exclusions --------
  //
  // Done HERE rather than in the screen so there is one place to look when
  // asking "why is X not in the dropdown", and so the screen cannot
  // accidentally widen it.
  const masters: Record<string, MasterRow[]> = {};
  for (const row of mastersRes.data as MasterRow[]) {
    // 1. A group heading is a folder name, never a choice — in ANY list.
    if (row.is_heading) continue;

    // 2. This screen shows farm work only.
    if (
      row.list_name === "ACTIVITY" &&
      !EXPENSE_ACTIVITY_GROUPS.includes(row.group_code ?? "")
    ) {
      continue;
    }

    // 3. HOME is a pre-v3.2 leftover (see FARMS_NOT_OFFERED above).
    if (row.list_name === "FARM" && FARMS_NOT_OFFERED.includes(row.code)) {
      continue;
    }

    (masters[row.list_name] ??= []).push(row);
  }

  const parties: PartyRow[] = partiesRes.data ?? [];
  const partyKinds: PartyKindRow[] = kindsRes.data ?? [];
  const jobs: JobRow[] = jobsRes.data ?? [];

  // -- A read that fails must SAY it failed, and name the object -----------
  // Non-fatal by design: masters failing is a dead screen (handled above), but
  // a missing pattern view, kinds list or job list should degrade, not block.
  const loadWarnings: string[] = [];
  if (kindsRes.error)
    loadWarnings.push(
      `Party kinds (v_party_kinds) did not load: ${kindsRes.error.message}. Adding a party inline will not work until this is fixed.`,
    );
  else if (partyKinds.length === 0)
    loadWarnings.push(
      "Party kinds (v_party_kinds) returned no rows. The view exists but is empty for this login — check RLS, then PostgREST's schema cache (notify pgrst, 'reload schema').",
    );
  if (partiesRes.error)
    loadWarnings.push(`Parties did not load: ${partiesRes.error.message}.`);
  if (statsRes.error)
    loadWarnings.push(
      `Party payment history (v_party_payment_stats) did not load: ${statsRes.error.message}. The large-amount warning will stay silent.`,
    );
  if (configRes.error)
    loadWarnings.push(
      `Config did not load: ${configRes.error.message}. Screen defaults are in use — the database still applies its own.`,
    );
  if (todayRes.error)
    loadWarnings.push(
      `fn_today() failed: ${todayRes.error.message}. The date box is seeded from the server clock, not the estate's.`,
    );
  if (pocketsRes.error)
    loadWarnings.push(
      `Pocket balances (v_pocket_balances) did not load: ${pocketsRes.error.message}. The header figure shows "—"; entry is unaffected.`,
    );
  if (jobsRes.error)
    loadWarnings.push(
      `Jobs did not load: ${jobsRes.error.message}. The optional job box is unavailable; everything else works.`,
    );
  // NOT a warning when jobs is simply empty — no open job is the normal state
  // of this estate, and saying so would train her to ignore this banner.

  // -- The activity list must not be silently empty ------------------------
  // If file 17's grouping were ever undone, every activity would fall outside
  // EXPENSE_ACTIVITY_GROUPS and the dropdown would be blank with no
  // explanation. Name the cause rather than let her wonder.
  if ((masters["ACTIVITY"]?.length ?? 0) === 0) {
    loadWarnings.push(
      "No farm activities loaded. Every ACTIVITY row is expected to carry group_code FARM, WEED MGMT or SHARED (SQL file 17). Check that file 17 ran, then reload.",
    );
  }

  // Config, mirroring the database's own defaults (files 06, 08, 09, 18a) so a
  // missing row degrades to the same behaviour the DB would apply — the
  // screen's preview and the DB's verdict must not disagree over a default.
  const cfg: Record<string, string> = Object.fromEntries(
    (configRes.data ?? []).map((r: { key: string; value: string }) => [
      r.key,
      r.value,
    ]),
  );
  const vagueActivities = (cfg["VAGUE_ACTIVITIES"] ?? "")
    .split(",")
    .map((s: string) => s.trim())
    .filter(Boolean);
  const unsplitFarms = (cfg["UNSPLIT_FARMS"] ?? "")
    .split(",")
    .map((s: string) => s.trim())
    .filter(Boolean);
  const vagueNarrationMin =
    parseInt(cfg["VAGUE_NARRATION_MIN"] ?? "15", 10) || 15;
  const narrationMin = parseInt(cfg["NARRATION_MIN"] ?? "5", 10) || 5;
  const sampleMode = (cfg["LIVE_MODE"] ?? "") === "SAMPLE";
  const oneTimeMax = parseFloat(cfg["ONE_TIME_MAX"] ?? "2000") || 2000;
  const lineAmountWarn =
    parseFloat(cfg["LINE_AMOUNT_WARN"] ?? "50000") || 50000;
  const partyWarnMult = parseFloat(cfg["PARTY_WARN_MULT"] ?? "2") || 2;

  // Party stats as a plain object keyed by code. A failed read degrades to no
  // pattern warnings, never to a dead screen.
  const partyStats: Record<
    string,
    { times_paid: number; max_paid: number; avg_paid: number; last_paid: string }
  > = {};
  for (const r of statsRes.data ?? []) {
    partyStats[String(r.party_code)] = {
      times_paid: Number(r.times_paid),
      max_paid: Number(r.max_paid),
      avg_paid: Number(r.avg_paid),
      last_paid: String(r.last_paid),
    };
  }

  // Pocket balances keyed by mode. A pocket with no row yet is absent rather
  // than zero — an honest blank beats a zero that looks like a counted zero.
  const pocketBalances: Record<string, number> = {};
  for (const r of pocketsRes.data ?? []) {
    pocketBalances[String(r.mode)] = Number(r.balance);
  }

  // The estate's date (file 07). If even this fails, fall back to the server's
  // UTC date — a wrong default she can retype beats a dead screen, and the
  // database will still refuse a genuinely future date.
  const today: string =
    (todayRes.data as string | null) ?? new Date().toISOString().slice(0, 10);

  return (
    <>
      {loadWarnings.length > 0 && (
        <div className="max-w-6xl mx-auto px-4 pt-4">
          <div className="border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/30 text-amber-900 dark:text-amber-300 rounded p-3 text-base">
            <div className="font-medium mb-1">
              Part of this screen did not load. Entry still works; what is named
              below does not.
            </div>
            {loadWarnings.map((w, i) => (
              <div key={i}>· {w}</div>
            ))}
          </div>
        </div>
      )}
      <ExpenseVoucher
        masters={masters}
        parties={parties}
        jobs={jobs}
        today={today}
        vagueActivities={vagueActivities}
        unsplitFarms={unsplitFarms}
        narrationMin={narrationMin}
        vagueNarrationMin={vagueNarrationMin}
        sampleMode={sampleMode}
        oneTimeMax={oneTimeMax}
        lineAmountWarn={lineAmountWarn}
        partyWarnMult={partyWarnMult}
        partyStats={partyStats}
        partyKinds={partyKinds}
        initialPocketBalances={pocketBalances}
        userEmail={String(claims.claims.email ?? "")}
      />
    </>
  );
}
