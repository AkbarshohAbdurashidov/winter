import { lazy, StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Link, Route, Routes } from "react-router-dom";
import "./index.css";
import { Shell, Snowflake, Spinner } from "./components/ui";
import { config } from "./lib/api";
import { SessionProvider } from "./lib/session";
import { AccountPage } from "./pages/Account";
import { LinkPage } from "./pages/Link";

// The admin panel and the RevenueCat paywall are loaded on demand.
const AdminPage = lazy(() => import("./pages/Admin").then((m) => ({ default: m.AdminPage })));
const UpgradePage = lazy(() => import("./pages/Upgrade").then((m) => ({ default: m.UpgradePage })));

function Home() {
  return (
    <Shell>
      <section className="pt-14 text-center sm:pt-24">
        <span className="mx-auto mb-6 grid h-16 w-16 place-items-center rounded-3xl bg-sky-300/15 ring-1 ring-sky-200/30">
          <Snowflake className="h-8 w-8 text-sky-200" />
        </span>
        <h1 className="mx-auto max-w-2xl text-4xl font-bold tracking-tight text-white sm:text-6xl">
          Let it snow on your desktop.
        </h1>
        <p className="mx-auto mt-5 max-w-xl text-lg text-slate-400">
          Snow that piles up on your windows and Dock, snowmen you can build, icicles you can break.
        </p>
        <div className="mt-8 flex flex-wrap justify-center gap-3">
          <a href={config.downloadMac} className="btn-primary !px-6 !py-3">Download for Mac</a>
          <a href={config.downloadWindows} className="btn-ghost !px-6 !py-3">Download for Windows</a>
        </div>
        <p className="mt-4 text-sm text-slate-500">Free to use · <Link to="/upgrade" className="text-sky-300 hover:underline">Winter Pro</Link> unlocks blizzards and ultra quality</p>
      </section>
    </Shell>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <SessionProvider>
      <BrowserRouter>
        <Suspense fallback={<div className="grid min-h-screen place-items-center"><Spinner /></div>}>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/link" element={<LinkPage />} />
          <Route path="/account" element={<AccountPage />} />
          <Route path="/upgrade" element={<UpgradePage />} />
          <Route path="/admin" element={<AdminPage />} />
          <Route path="*" element={<Home />} />
        </Routes>
        </Suspense>
      </BrowserRouter>
    </SessionProvider>
  </StrictMode>,
);
