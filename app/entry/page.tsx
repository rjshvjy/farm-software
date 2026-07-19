// https://github.com/rjshvjy/farm-software/blob/main/app/entry/page.tsx
// app/entry/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — voucher entry, server side.
//
// This is a server component. It loads everything the screen needs, once per
// page load, and hands it to the client screen as props so no dropdown ever
// waits on the network mid-typing:
//
//   1. Confirms the session (the proxy already guards the route; this is the
//      second lock on the same door).
//   2. Loads every ACTIVE master value in one query. RLS allows selects for
//      any active user; the lists are grouped here so the screen never
//      filters by list_name itself.
//   3. Loads active parties (needed the moment mode is ON CREDIT or a
//      BANK-kind — file 08 makes party compulsory on bank payments).
//   4. Asks the database for the estate's date (fn_today), the narration
//      floors and the vagueness settings — the screen must not trust the
//      browser's clock (file 07), and must not hardcode a single threshold
//      (§1.8): NARRATION_MIN and VAGUE_NARRATION_MIN are config rows.
//   5. Reads CASH in hand from v_pocket_balances for the header figure.
//      After each save the action returns a fresh one; this is only the
//      opening number.
//
// Nothing here writes. The one write path is actions.ts.
//
// -- WHY THE <Suspense> WRAPPER ---------------------------------------------
// This project runs Next 16 with Cache Components enabled (next.config.ts).
// Under that setting, uncached data access — every query below — MUST sit
// inside a Suspense boundary, or the build fails with "Uncached data was
// accessed outside of <Suspense>". So the fetching lives in EntryLoader and
// the page's job is only to draw the boundary around it.
//
// Two consequences worth knowing before the next screen is built:
//   - `export const dynamic = "force-dynamic"` is BANNED under Cache
//     Components. It is also unnecessary: nothing is cached unless explicitly
//     marked, so this page is dynamic by default.
//   - Every future screen that reads the database follows this same shape.
// ---------------------------------------------------------------------------
import { Suspense } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import VoucherEntry, { type MasterRow, type PartyRow } from "./VoucherEntry";

export default function EntryPage() {
  return (
    <Suspense
      fallback={
        <main className="p-8 text-sm text-muted-foreground">
          Loading masters…
        </main>
      }
    >
      <EntryLoader />
    </Suspense>
  );
}

async function EntryLoader() {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) redirect("/auth/login");

  // --- everything the screen needs, fetched in parallel -------------------
  const [mastersRes, partiesRes, configRes, todayRes, cashRes, statsRes] =
    await Promise.all([
      supabase
        .from("master_values")
        .select(
          "list_name, code, label, sort_order, required_unit, mode_kind, parent_farm, notes",
        )
        .eq("active", true)
        .order("sort_order", { ascending: true }),
      supabase
        .from("parties")
        // kind is new here: a party created inline mid-voucher must render
        // exactly like a preloaded one, and the add panel defaults kind from
        // context — so the screen needs to know it for existing parties too.
        .select("party_code, name, kind")
        .eq("status", "ACTIVE")
        .order("name", { ascending: true }),
      supabase
        .from("config")
        .select("key, value")
        // NARRATION_MIN is new here (file 08): the 5-character floor on every
        // line. VAGUE_NARRATION_MIN stays the 15-character floor for vague
        // heads. LIVE_MODE tells the screen to label the cash figure SAMPLE.
        .in("key", [
          "VAGUE_ACTIVITIES",
          "VAGUE_NARRATION_MIN",
          "NARRATION_MIN",
          "LIVE_MODE",
          "ONE_TIME_MAX",
          "LINE_AMOUNT_WARN",
          "PARTY_WARN_MULT",
        ]),
      supabase.rpc("fn_today"),
      supabase
        .from("v_pocket_balances")
        .select("mode, balance")
        .eq("mode", "CASH")
        .maybeSingle(),
      // Each party's own payment record (file 09). Small — one row per party
      // ever paid. Feeds the self-calibrating large-amount warning: silent
      // with no history, sharper every month, no per-party settings anywhere.
      supabase
        .from("v_party_payment_stats")
        .select("party_code, times_paid, max_paid, avg_paid, last_paid"),
    ]);

  // A failed masters load means an unusable screen — say so plainly rather
  // than render empty dropdowns that look like data loss.
  if (mastersRes.error || !mastersRes.data?.length) {
    return (
      <main className="p-8 max-w-xl mx-auto">
        <h1 className="text-lg font-semibold mb-2">Voucher entry</h1>
        <p className="text-red-700">
          Could not load the master lists
          {mastersRes.error ? `: ${mastersRes.error.message}` : ""}. Nothing can
          be entered without them — refresh, and if it persists check that this
          login has an ACTIVE row in app_users.
        </p>
      </main>
    );
  }

  // Group masters by list once, here, so the screen receives ready lists.
  const masters: Record<string, MasterRow[]> = {};
  for (const row of mastersRes.data as MasterRow[]) {
    (masters[row.list_name] ??= []).push(row);
  }

  const parties: PartyRow[] = partiesRes.data ?? [];

  // Config, mirroring the database's own defaults (files 06 and 08) so a
  // missing row degrades to the same behaviour the DB would apply — the
  // screen's preview and the DB's verdict must not disagree over a default.
  const cfg = Object.fromEntries(
    (configRes.data ?? []).map((r) => [r.key, r.value]),
  );
  const vagueActivities = (cfg["VAGUE_ACTIVITIES"] ?? "")
    .split(",")
    .map((s: string) => s.trim())
    .filter(Boolean);
  const vagueNarrationMin =
    parseInt(cfg["VAGUE_NARRATION_MIN"] ?? "15", 10) || 15;
  const narrationMin = parseInt(cfg["NARRATION_MIN"] ?? "5", 10) || 5;
  const sampleMode = (cfg["LIVE_MODE"] ?? "") === "SAMPLE";
  // Mirrors of file 09's defaults, so a missing config row degrades to the
  // same behaviour the database applies.
  const oneTimeMax = parseFloat(cfg["ONE_TIME_MAX"] ?? "2000") || 2000;
  const lineAmountWarn =
    parseFloat(cfg["LINE_AMOUNT_WARN"] ?? "50000") || 50000;
  const partyWarnMult = parseFloat(cfg["PARTY_WARN_MULT"] ?? "2") || 2;

  // Party stats as a plain object keyed by code. A failed read (e.g. file 09
  // not yet run) degrades to no pattern warnings, never to a dead screen.
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

  // The estate's date (file 07). If even this fails, fall back to the
  // server's UTC date — a wrong default the user can retype beats a dead
  // screen; the database will still refuse a genuinely future date.
  const today: string =
    (todayRes.data as string | null) ?? new Date().toISOString().slice(0, 10);

  // Opening CASH figure. Null (no CASH row yet, or read failed) renders as
  // "—" — an honest blank beats a zero that looks like a counted zero.
  const cashBalance: number | null =
    !cashRes.error && cashRes.data ? Number(cashRes.data.balance) : null;

  return (
    <VoucherEntry
      masters={masters}
      parties={parties}
      today={today}
      vagueActivities={vagueActivities}
      narrationMin={narrationMin}
      vagueNarrationMin={vagueNarrationMin}
      sampleMode={sampleMode}
      oneTimeMax={oneTimeMax}
      lineAmountWarn={lineAmountWarn}
      partyWarnMult={partyWarnMult}
      partyStats={partyStats}
      initialCashBalance={cashBalance}
      userEmail={String(claims.claims.email ?? "")}
    />
  );
}
