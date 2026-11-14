import { useEffect, useRef, type ReactNode } from "react";
import { Link } from "react-router-dom";
import type { Access } from "../lib/api";
import { accessLabel, supabase } from "../lib/api";
import { useSession } from "../lib/session";

export function Logo({ small = false }: { small?: boolean }) {
  return (
    <Link to="/" className="flex items-center gap-2.5 font-semibold tracking-tight text-white">
      <span className={`grid place-items-center rounded-xl bg-gradient-to-b from-sky-300/30 to-sky-500/10 ring-1 ring-sky-200/30 ${small ? "h-8 w-8" : "h-9 w-9"}`}>
        <Snowflake className="h-4.5 w-4.5 text-sky-200" />
      </span>
      <span className={small ? "text-base" : "text-lg"}>Winter</span>
    </Link>
  );
}

export function Snowflake({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round">
      <path d="M12 2v20M3.3 7l17.4 10M3.3 17L20.7 7" />
      <path d="M9 4l3 2.5L15 4M9 20l3-2.5 3 2.5" />
    </svg>
  );
}

/// Light snowfall behind the page (paused when the tab is hidden).
export function SnowBackground() {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current!;
    const ctx = canvas.getContext("2d")!;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let w = 0, h = 0, raf = 0;
    const flakes = Array.from({ length: 90 }, () => ({
      x: Math.random(), y: Math.random(), r: 0.6 + Math.random() * 1.8,
      s: 0.15 + Math.random() * 0.45, d: Math.random() * Math.PI * 2,
    }));
    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = window.innerWidth; h = window.innerHeight;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };
    const tick = () => {
      ctx.clearRect(0, 0, w, h);
      for (const f of flakes) {
        f.y += (f.s * f.r) / h * 1.2;
        f.d += 0.01;
        if (f.y > 1.02) { f.y = -0.02; f.x = Math.random(); }
        ctx.globalAlpha = 0.25 + f.r / 4;
        ctx.beginPath();
        ctx.arc(f.x * w + Math.sin(f.d) * 8, f.y * h, f.r, 0, Math.PI * 2);
        ctx.fillStyle = "#e0f2fe";
        ctx.fill();
      }
      if (!reduce) raf = requestAnimationFrame(tick);
    };
    resize();
    tick();
    window.addEventListener("resize", resize);
    return () => { cancelAnimationFrame(raf); window.removeEventListener("resize", resize); };
  }, []);
  return <canvas ref={ref} className="pointer-events-none fixed inset-0 -z-10 opacity-70" aria-hidden />;
}

export function Shell({ children, wide = false }: { children: ReactNode; wide?: boolean }) {
  const { session } = useSession();
  return (
    <div className="min-h-screen">
      <SnowBackground />
      <header className={`mx-auto flex items-center justify-between px-4 py-5 sm:px-6 ${wide ? "max-w-7xl" : "max-w-5xl"}`}>
        <Logo />
        <nav className="flex items-center gap-2 text-sm">
          {session ? (
            <>
              <Link to="/account" className="btn-ghost !py-2">Account</Link>
              <button className="btn !px-3 !py-2 text-slate-400 hover:text-white" onClick={() => supabase.auth.signOut()}>
                Sign out
              </button>
            </>
          ) : (
            <Link to="/account" className="btn-ghost !py-2">Sign in</Link>
          )}
        </nav>
      </header>
      <main className={`mx-auto px-4 pb-16 sm:px-6 ${wide ? "max-w-7xl" : "max-w-5xl"}`}>{children}</main>
    </div>
  );
}

const badgeTone: Record<Access, string> = {
  free: "bg-violet-400/15 text-violet-200 ring-violet-300/30",
  trial: "bg-amber-400/15 text-amber-200 ring-amber-300/30",
  active: "bg-emerald-400/15 text-emerald-200 ring-emerald-300/30",
  lifetime: "bg-sky-400/15 text-sky-200 ring-sky-300/30",
  expired: "bg-slate-400/10 text-slate-300 ring-slate-300/20",
  refunded: "bg-rose-400/15 text-rose-200 ring-rose-300/30",
  none: "bg-white/5 text-slate-400 ring-white/10",
};

export function AccessBadge({ access }: { access: Access }) {
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium ring-1 ${badgeTone[access]}`}>
      <span className="h-1.5 w-1.5 rounded-full bg-current" />
      {accessLabel[access]}
    </span>
  );
}

export function Spinner({ className = "h-5 w-5" }: { className?: string }) {
  return <span className={`inline-block animate-spin rounded-full border-2 border-current border-t-transparent ${className}`} />;
}

export function Notice({ tone = "info", children }: { tone?: "info" | "error" | "success"; children: ReactNode }) {
  const tones = {
    info: "border-sky-300/20 bg-sky-400/10 text-sky-100",
    error: "border-rose-300/30 bg-rose-500/10 text-rose-100",
    success: "border-emerald-300/30 bg-emerald-500/10 text-emerald-100",
  };
  return <div className={`rounded-xl border px-4 py-3 text-sm ${tones[tone]}`}>{children}</div>;
}
