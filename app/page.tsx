// app/page.tsx
// ---------------------------------------------------------------------------
// FARM & HOME ACCOUNTS — the root of the app.
//
// REPLACES the Vercel starter's marketing page (Hero, DeployButton, tutorial
// steps). This system has no landing page: signed in, you are at voucher
// entry; not signed in, the proxy bounces /entry to /auth/login.
// ---------------------------------------------------------------------------
import { redirect } from "next/navigation";

export default function Home() {
  redirect("/entry");
}
