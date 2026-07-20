// https://github.com/rjshvjy/farm-software/blob/main/app/page.tsx
// app/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the landing page. Everyone who signs in arrives here.
//
// WHY IT EXISTS (20-07-2026). Until today `/` redirected straight to voucher
// entry and login landed on the starter's `/protected` page, so there was no
// front door at all — every screen was reached by typing a URL. Fine for one
// developer, impossible for an accountant with twenty slips.
//
// WHAT IT SHOWS
//
//   Everything the system will have, grouped by the JOB rather than by the
//   accounting: enter, find and fix, ledgers, reports, admin. Each tile is in
//   one of three states, and they must LOOK different from one another or the
//   feedback that comes back is noise:
//
//     LIVE AND YOURS   normal tile, clickable
//     NOT YOURS        greyed, and it SAYS WHOSE ("Owner only") — a dim box
//                      with no reason invites clicking and breeds "this thing
//                      is broken"
//     NOT BUILT YET    greyed, and it says so
//
//   Owner's ruling 20-07: during the trial, show locked tiles rather than
//   hiding them. Two reasons — the team can see what the system will do and
//   ask for what they need, and it makes THE PERMISSIONS TABLE ITSELF
//   TESTABLE. If the accountant sees Masters greyed and says she needs it
//   weekly, the matrix is wrong, and that is a table nobody has stress-tested.
//
//   HOW TO FLIP IT LATER, WITHOUT A DEPLOY: insert a config row
//       MENU_SHOW_LOCKED = 'NO'
//   and tiles the person cannot use disappear instead of greying. Absent
//   means YES, the trial behaviour. "Temporary" becomes permanent unless
//   there is a switch, so here is the switch.
//
// WHY IT READS CAPABILITIES ONE BY ONE
//
//   fn_has_capability is SECURITY DEFINER, so it needs no grant on the
//   permissions table — whose grants cannot be verified from the schema
//   snapshot, because the snapshot does not inventory table rows or
//   privileges. Half a dozen parallel RPCs are cheaper than a wrong
//   assumption about table privileges (the 20-07 PostgREST evening).
//
//   IT FAILS SAFE, NOT OPEN: if the capability reads fail, the everyday entry
//   tiles stay available — the common case, and the database refuses anything
//   improper regardless — and the ADMIN group is hidden. Better to offer a
//   screen that might refuse than to lock the accountant out of her day.
// ---------------------------------------------------------------------------
import { Suspense } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { LogoutButton } from "@/components/logout-button";

export default function HomePage() {
  return (
    <Suspense
      fallback={
        <main className="p-8 text-sm text-muted-foreground">Loading…</main>
      }
    >
      <HomeLoader />
    </Suspense>
  );
}

/** One tile. `href` null means the screen does not exist yet. */
type Tile = {
  title: string;
  /** The sentence that stops her guessing between two similar screens. */
  hint: string;
  href: string | null;
  /** Capability the database enforces. Null = anyone signed in. */
  needs: string | null;
  /** Shown when she lacks the capability. */
  whose?: string;
};

type Group = { name: string; blurb: string; tiles: Tile[] };

// The whole system, including what is not built. Adding a screen later is one
// line here rather than a re-layout — which is why the groups exist now, not
// when there are finally enough of them to hurt.
const GROUPS: Group[] = [
  {
    name: "Enter",
    blurb: "Recording what happened. One screen per kind of paper.",
    tiles: [
      {
        title: "Bought something",
        hint: "Wages, fertiliser, diesel, repairs — anything the estate paid for, or now owes for.",
        href: "/entry",
        needs: "ENTER_VOUCHER",
      },
      {
        title: "Sold something",
        hint: "Nuts, livestock, lease. Cash, or on credit — on credit raises what the buyer owes.",
        href: "/sales",
        needs: "ENTER_VOUCHER",
      },
      {
        title: "Received money",
        hint: "A buyer paying his account, or the owner putting money in. Not a sale — the sale was invoiced earlier.",
        href: null,
        needs: "ENTER_VOUCHER",
      },
      {
        title: "Paid someone what we owe",
        hint: "Settling a supplier's account. Not a purchase — the purchase was recorded when the goods arrived.",
        href: null,
        needs: "ENTER_VOUCHER",
      },
      {
        title: "Moved cash between pockets",
        hint: "Bank to hand, hand to bank. No expense and no income — the money is simply somewhere else.",
        href: null,
        needs: "ENTER_VOUCHER",
      },
      {
        title: "Adjustment, no money moved",
        hint: "Depreciation, a damaged-goods note, opening balances. Both accounts named by hand.",
        href: null,
        needs: "ENTER_VOUCHER",
      },
    ],
  },
  {
    name: "Find and fix",
    blurb:
      "Looking things up, and putting things right. Rows are never edited — they are reversed or reclassified.",
    tiles: [
      {
        title: "Search vouchers",
        hint: "By date, party, farm, amount, or anything written in a narration.",
        href: null,
        needs: null,
      },
      {
        title: "Review queue",
        hint: "Everything flagged as it was entered — no payee, no quantity, block not chosen.",
        href: null,
        needs: null,
      },
      {
        title: "Corrections and reversals",
        hint: "Undo a line properly, with the reason recorded. The original stays visible.",
        href: null,
        needs: "CORRECT_LINE",
        whose: "Accountant and above",
      },
    ],
  },
  {
    name: "Ledgers",
    blurb: "What the books currently say.",
    tiles: [
      {
        title: "Party balances",
        hint: "Who owes the estate, and whom the estate owes. Positive means they owe us.",
        href: null,
        needs: null,
      },
      {
        title: "Cash and bank book",
        hint: "Every movement through each pocket, and what should be in hand right now.",
        href: null,
        needs: null,
      },
      {
        title: "Asset register",
        hint: "What the estate owns, what it cost, and what it has cost to run.",
        href: null,
        needs: null,
      },
    ],
  },
  {
    name: "Reports",
    blurb: "The four statements, cost per acre, and the year-end export.",
    tiles: [
      {
        title: "Statements",
        hint: "Profit and loss, balance sheet, cash flow, and cost per acre by farm and crop.",
        href: null,
        needs: null,
      },
      {
        title: "Export to Tally",
        hint: "Hand the year over in the form the accountant already works in.",
        href: null,
        needs: null,
      },
      {
        title: "Audit list",
        hint: "Tick vouchers as checked. Nobody may tick their own work.",
        href: null,
        needs: "AUDIT_TICK",
        whose: "Auditor only",
      },
    ],
  },
  {
    name: "Admin",
    blurb: "Settings that shape how everything above behaves.",
    tiles: [
      {
        title: "Masters",
        hint: "Farms, blocks, crops, activities, units, party kinds. Added to, never renamed.",
        href: null,
        needs: "MASTER_MANAGE",
        whose: "Owner only",
      },
      {
        title: "People and roles",
        hint: "Who may sign in, and what each of them may do.",
        href: null,
        needs: "USER_MANAGE",
        whose: "Owner only",
      },
      {
        title: "Close a period",
        hint: "Lock a month or a year so nothing can be backdated into it.",
        href: null,
        needs: "MASTER_MANAGE",
        whose: "Owner only",
      },
    ],
  },
];

async function HomeLoader() {
  const supabase = await createClient();

  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) redirect("/auth/login");
  const email = String(claims.claims.email ?? "");

  // Every capability any tile mentions, asked once each, in parallel.
  const needed = Array.from(
    new Set(
      GROUPS.flatMap((g) => g.tiles.map((t) => t.needs)).filter(
        (c): c is string => !!c,
      ),
    ),
  );

  const [capResults, cfgRes] = await Promise.all([
    Promise.all(
      needed.map((c) => supabase.rpc("fn_has_capability", { p_capability: c })),
    ),
    supabase
      .from("config")
      .select("key, value")
      .in("key", ["LIVE_MODE", "MENU_SHOW_LOCKED"]),
  ]);

  const can: Record<string, boolean> = {};
  let capsFailed = false;
  needed.forEach((c, i) => {
    const r = capResults[i];
    if (r.error) capsFailed = true;
    can[c] = r.data === true;
  });

  // Fail safe on admin, fail open on the day's work — see the header.
  if (capsFailed) {
    can["ENTER_VOUCHER"] = true;
    can["CORRECT_LINE"] = true;
  }

  const cfg = Object.fromEntries(
    (cfgRes.data ?? []).map((r) => [r.key, r.value]),
  );
  const sample = (cfg["LIVE_MODE"] ?? "") === "SAMPLE";
  // Absent means YES: greying is the trial default (owner ruling, 20-07).
  const showLocked = (cfg["MENU_SHOW_LOCKED"] ?? "YES").toUpperCase() !== "NO";

  return (
    <main className="max-w-5xl mx-auto p-6">
      <header className="flex flex-wrap items-baseline justify-between gap-3 mb-2">
        <h1 className="text-2xl font-semibold">Farm &amp; Home Accounts</h1>
        <div className="flex items-center gap-3 text-sm text-muted-foreground">
          {sample && (
            <span className="rounded bg-amber-100 dark:bg-amber-950/40 text-amber-900 dark:text-amber-300 px-2 py-0.5">
              SAMPLE — nothing here is real yet
            </span>
          )}
          <span>{email}</span>
          <LogoutButton />
        </div>
      </header>

      {capsFailed && (
        <div className="mb-4 border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/30 text-amber-900 dark:text-amber-300 rounded p-3 text-sm">
          Could not read your permissions, so the admin tools are hidden and the
          entry screens are shown. The database still refuses anything you are
          not allowed to do.
        </div>
      )}

      <p className="text-muted-foreground mb-8">
        Greyed tiles are either not built yet or not yours to use — both say
        which. Tell me if something you need is locked.
      </p>

      <div className="space-y-8">
        {GROUPS.map((group) => {
          // A whole group disappears only when nothing in it is available AND
          // the owner has switched locked tiles off.
          const visible = group.tiles.filter(
            (t) => showLocked || !t.needs || can[t.needs],
          );
          if (visible.length === 0) return null;

          return (
            <section key={group.name}>
              <h2 className="text-lg font-medium">{group.name}</h2>
              <p className="text-sm text-muted-foreground mb-3">{group.blurb}</p>
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {visible.map((t) => {
                  const allowed = !t.needs || can[t.needs];
                  const built = t.href !== null;
                  const open = allowed && built;

                  const body = (
                    <>
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="font-medium">{t.title}</span>
                        {!built && (
                          <span className="text-xs text-muted-foreground whitespace-nowrap">
                            not built yet
                          </span>
                        )}
                        {built && !allowed && (
                          <span className="text-xs whitespace-nowrap text-amber-700 dark:text-amber-500">
                            {t.whose ?? "not yours"}
                          </span>
                        )}
                      </div>
                      <p className="text-sm text-muted-foreground mt-1">
                        {t.hint}
                      </p>
                    </>
                  );

                  const base = "rounded border p-4 block h-full";

                  return open ? (
                    <Link
                      key={t.title}
                      href={t.href!}
                      className={
                        base +
                        " border-foreground/20 hover:border-foreground/50 hover:bg-accent transition-colors"
                      }
                    >
                      {body}
                    </Link>
                  ) : (
                    <div
                      key={t.title}
                      aria-disabled
                      className={base + " border-dashed opacity-50"}
                    >
                      {body}
                    </div>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>

      <p className="text-xs text-muted-foreground mt-10">
        Dates are DD/MM/YYYY. The financial year runs April to March.
      </p>
    </main>
  );
}
