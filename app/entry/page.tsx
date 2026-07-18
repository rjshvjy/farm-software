// app/entry/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — voucher entry, server side.
//
// This is a server component. It does four things, once per page load, and
// hands everything to the client screen as props so no dropdown ever waits on
// the network mid-typing:
//
//   1. Confirms the session (the proxy already guards the route; this is the
//      second lock on the same door).
//   2. Loads every ACTIVE master value in one query. RLS allows selects for
//      any active user; the lists are grouped here so the screen never
//      filters by list_name itself.
//   3. Loads active parties (needed the moment mode is ON CREDIT).
//   4. Asks the database for the estate's date (fn_today) and the vagueness
//      settings — the screen must not trust the browser's clock (file 07),
//      and must not hardcode which activities count as vague (§1.8).
//
// Nothing here writes. The one write path is actions.ts.
// ---------------------------------------------------------------------------
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import VoucherEntry, { type MasterRow, type PartyRow } from "./VoucherEntry";

// Masters can change (masters admin); never serve a stale cached page.
export const dynamic = "force-dynamic";

export default async function EntryPage() {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) redirect("/auth/login");

  // --- everything the screen needs, fetched in parallel -------------------
  const [mastersRes, partiesRes, configRes, todayRes] = await Promise.all([
    supabase
      .from("master_values")
      .select(
        "list_name, code, label, sort_order, required_unit, mode_kind, parent_farm, notes",
      )
      .eq("active", true)
      .order("sort_order", { ascending: true }),
    supabase
      .from("parties")
      .select("party_code, name")
      .eq("status", "ACTIVE")
      .order("name", { ascending: true }),
    supabase
      .from("config")
      .select("key, value")
      .in("key", ["VAGUE_ACTIVITIES", "VAGUE_NARRATION_MIN"]),
    supabase.rpc("fn_today"),
  ]);

  // A failed masters load means an unusable screen — say so plainly rather
  // than render empty dropdowns that look like data loss.
  if (mastersRes.error || !mastersRes.data?.length) {
    return (
      <main className="p-8 max-w-xl mx-auto">
        <h1 className="text-lg font-semibold mb-2">Voucher entry</h1>
        <p className="text-red-700">
          Could not load the master lists
          {mastersRes.error ? `: ${mastersRes.error.message}` : ""}. Nothing
          can be entered without them — refresh, and if it persists check that
          this login has an ACTIVE row in app_users.
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

  // Vagueness settings, mirroring file 06's server-side reading of the same
  // rows: blank/missing disables the client-side confirm cleanly. The
  // database still enforces regardless — this only decides whether the
  // screen ASKS before saving.
  const cfg = Object.fromEntries(
    (configRes.data ?? []).map((r) => [r.key, r.value]),
  );
  const vagueActivities = (cfg["VAGUE_ACTIVITIES"] ?? "")
    .split(",")
    .map((s: string) => s.trim())
    .filter(Boolean);
  const narrationMin = parseInt(cfg["VAGUE_NARRATION_MIN"] ?? "15", 10) || 15;

  // The estate's date (file 07). If even this fails, fall back to the
  // server's UTC date — a wrong default the user can retype beats a dead
  // screen; the database will still refuse a genuinely future date.
  const today: string =
    (todayRes.data as string | null) ?? new Date().toISOString().slice(0, 10);

  return (
    <VoucherEntry
      masters={masters}
      parties={parties}
      today={today}
      vagueActivities={vagueActivities}
      narrationMin={narrationMin}
      userEmail={String(claims.claims.email ?? "")}
    />
  );
}
