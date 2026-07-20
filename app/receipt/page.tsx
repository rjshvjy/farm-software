// https://github.com/rjshvjy/farm-software/blob/main/app/receipt/page.tsx
// app/receipt/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — receipt entry, server side.
//
// The mirror of app/entry/page.tsx, and deliberately the same shape: loads
// everything once, hands it to the client screen as props, writes nothing.
// The one substantive difference is WHICH pattern view it reads —
// v_party_receipt_stats (file 12), never the payment stats: a receipt is
// measured against what a party usually pays US, and mixing the directions
// is precisely the bug file 12's direction-scoped checks exist to prevent.
//
// The <Suspense> wrapper is required under Cache Components (Next 16) — see
// the long note in app/entry/page.tsx; every screen that reads the database
// follows this shape.
// ---------------------------------------------------------------------------
import { Suspense } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type {
  MasterRow,
  PartyRow,
  PartyKindRow,
} from "@/app/entry/VoucherEntry";
import ReceiptEntry from "./ReceiptEntry";

export default function ReceiptPage() {
  return (
    <Suspense
      fallback={
        <main className="p-8 text-sm text-muted-foreground">
          Loading masters…
        </main>
      }
    >
      <ReceiptLoader />
    </Suspense>
  );
}

async function ReceiptLoader() {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) redirect("/auth/login");

  // --- everything the screen needs, fetched in parallel -------------------
  const [
    mastersRes,
    partiesRes,
    configRes,
    todayRes,
    cashRes,
    statsRes,
    kindsRes,
  ] = await Promise.all([
    supabase
      .from("master_values")
      .select(
        "list_name, code, label, sort_order, required_unit, mode_kind, parent_farm, notes",
      )
      .eq("active", true)
      .order("sort_order", { ascending: true }),
    supabase
      .from("parties")
      .select("party_code, name, kind, default_entity")
      .eq("status", "ACTIVE")
      .order("name", { ascending: true }),
    supabase
      .from("config")
      .select("key, value")
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
    // Each party's own RECEIPT record (file 12). One row per party that has
    // ever paid us. Feeds the self-calibrating warning on the screen; the
    // database runs the same check again at save.
    supabase
      .from("v_party_receipt_stats")
      .select(
        "party_code, times_received, max_received, avg_received, last_received",
      ),
    supabase
      .from("v_party_kinds")
      .select("code, label, group_label, default_entity, sort_order")
      .order("sort_order", { ascending: true }),
  ]);

  // A failed masters load means an unusable screen — say so plainly.
  if (mastersRes.error || !mastersRes.data?.length) {
    return (
      <main className="p-8 max-w-xl mx-auto">
        <h1 className="text-lg font-semibold mb-2">Receipt entry</h1>
        <p className="text-red-700">
          Could not load the master lists
          {mastersRes.error ? `: ${mastersRes.error.message}` : ""}. Nothing can
          be entered without them — refresh, and if it persists check that this
          login has an ACTIVE row in app_users.
        </p>
      </main>
    );
  }

  const masters: Record<string, MasterRow[]> = {};
  for (const row of mastersRes.data as MasterRow[]) {
    (masters[row.list_name] ??= []).push(row);
  }

  const parties: PartyRow[] = partiesRes.data ?? [];
  const partyKinds: PartyKindRow[] = kindsRes.data ?? [];

  // Config, mirroring the database's own defaults (files 06/08/09) so a
  // missing row degrades to the same behaviour the DB applies — the screen's
  // preview and the DB's verdict must not disagree over a default.
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
  const oneTimeMax = parseFloat(cfg["ONE_TIME_MAX"] ?? "2000") || 2000;
  const lineAmountWarn =
    parseFloat(cfg["LINE_AMOUNT_WARN"] ?? "50000") || 50000;
  const partyWarnMult = parseFloat(cfg["PARTY_WARN_MULT"] ?? "2") || 2;

  // Receipt stats keyed by party code. A failed read (file 12 not applied)
  // degrades to no pattern warnings, never to a dead screen.
  const receiptStats: Record<
    string,
    {
      times_received: number;
      max_received: number;
      avg_received: number;
      last_received: string;
    }
  > = {};
  for (const r of statsRes.data ?? []) {
    receiptStats[String(r.party_code)] = {
      times_received: Number(r.times_received),
      max_received: Number(r.max_received),
      avg_received: Number(r.avg_received),
      last_received: String(r.last_received),
    };
  }

  // The estate's date (file 07); server UTC only as a last resort — a wrong
  // default the user can retype beats a dead screen.
  const today: string =
    (todayRes.data as string | null) ?? new Date().toISOString().slice(0, 10);

  // Opening CASH figure. Null renders as "—" — an honest blank beats a zero
  // that looks like a counted zero.
  const cashBalance: number | null =
    !cashRes.error && cashRes.data ? Number(cashRes.data.balance) : null;

  return (
    <ReceiptEntry
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
      receiptStats={receiptStats}
      partyKinds={partyKinds}
      initialCashBalance={cashBalance}
      userEmail={String(claims.claims.email ?? "")}
    />
  );
}
