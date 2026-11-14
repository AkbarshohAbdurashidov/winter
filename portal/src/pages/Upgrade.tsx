import { useState } from "react";
import { Link } from "react-router-dom";
import { SignIn } from "../components/SignIn";
import { Notice, RequestBadge, Shell, Snowflake, Spinner } from "../components/ui";
import { ApiError, callApp, formatDate, type ProRequest } from "../lib/api";
import { useSession } from "../lib/session";
import { useAccount } from "./Account";

const perks = [
  ["Heavy snowfall & blizzards", "The two strongest snow intensities."],
  ["High & Ultra quality", "More flakes, smoother piles, finer detail."],
  ["All your computers", "Pro follows your account on every Mac and PC."],
];

const errors: Record<string, string> = {
  name: "Please enter your name (2–80 characters).",
  telegram: "Telegram username: 4–32 letters, digits or _ (e.g. @winter_fan).",
  phone: "Phone number: digits, spaces, + ( ) - only.",
  pending: "You already have a request waiting for review.",
  "already-pro": "You already have Winter Pro.",
};

/// "Leave your contact to get Pro": the request is bound to the signed-in
/// account's email; an admin approves it in the panel or the Telegram bot.
export function UpgradePage() {
  const { user, loading } = useSession();
  const { info, error, reload } = useAccount();

  if (loading) return <Shell><div className="grid place-items-center py-24"><Spinner /></div></Shell>;
  if (!user) {
    return (
      <Shell>
        <div className="pt-10">
          <SignIn title="Get Winter Pro" subtitle="Sign in first — Pro is given to your account's email." />
        </div>
      </Shell>
    );
  }

  const request = info?.request ?? null;
  return (
    <Shell>
      <div className="mx-auto grid max-w-4xl gap-6 pt-4 lg:grid-cols-[1fr_1.1fr]">
        <section className="relative overflow-hidden p-2 lg:pt-6">
          <div className="pointer-events-none absolute -left-24 -top-24 h-72 w-72 rounded-full bg-sky-400/10 blur-3xl" />
          <span className="mb-5 grid h-14 w-14 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
            <Snowflake className="h-7 w-7 text-sky-200" />
          </span>
          <h1 className="text-3xl font-bold tracking-tight text-white sm:text-4xl">Get Winter Pro</h1>
          <p className="mt-3 text-slate-400">
            Leave your contact and we'll turn on Pro for <b className="text-slate-200">{user.email}</b>. Usually within a day.
          </p>
          <ul className="mt-8 space-y-4">
            {perks.map(([title, text]) => (
              <li key={title} className="flex gap-3">
                <span className="mt-0.5 grid h-6 w-6 shrink-0 place-items-center rounded-full bg-emerald-400/15 text-xs text-emerald-200 ring-1 ring-emerald-300/30">✓</span>
                <div>
                  <p className="font-medium text-slate-100">{title}</p>
                  <p className="text-sm text-slate-400">{text}</p>
                </div>
              </li>
            ))}
          </ul>
        </section>

        <section className="glass p-6 sm:p-8">
          {error && <Notice tone="error">Couldn't load your account: {error}</Notice>}
          {!info && !error && <div className="grid place-items-center py-24"><Spinner /></div>}
          {info?.pro && <ProActive expiresAt={info.expiresAt} />}
          {info && !info.pro && request?.status === "pending" && <Pending request={request} />}
          {info && !info.pro && request?.status !== "pending" && (
            <RequestForm email={user.email ?? ""} defaultName={request?.name ?? user.displayName ?? ""}
              previous={request} onSent={() => reload()} />
          )}
        </section>
      </div>
    </Shell>
  );
}

function ProActive({ expiresAt }: { expiresAt: string | null }) {
  return (
    <div className="py-8 text-center">
      <span className="mx-auto mb-5 grid h-16 w-16 place-items-center rounded-2xl bg-sky-300/15 ring-1 ring-sky-200/30">
        <Snowflake className="h-8 w-8 text-sky-200" />
      </span>
      <h2 className="text-2xl font-semibold text-white">You have Winter Pro</h2>
      <p className="mt-2 text-sm text-slate-400">
        {expiresAt ? `Active until ${formatDate(expiresAt)}.` : "Enjoy the blizzards!"} Winter on your computer updates
        within 30 minutes, or choose “Refresh Pro Status” in its ❄ menu.
      </p>
      <Link to="/account" className="btn-primary mt-6">Go to account</Link>
    </div>
  );
}

function Pending({ request }: { request: ProRequest }) {
  return (
    <div className="py-6">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xl font-semibold text-white">Request sent</h2>
        <RequestBadge status="pending" />
      </div>
      <p className="text-sm text-slate-400">
        We got your request on {formatDate(request.created_at, true)}. Once it's approved, Pro turns on for this
        account automatically — nothing else to do.
      </p>
      <dl className="mt-6 space-y-3 rounded-xl bg-white/[0.03] p-4 text-sm ring-1 ring-white/10">
        <Row label="Name" value={request.name} />
        <Row label="Email" value={request.email} />
        <Row label="Telegram" value={request.telegram ? `@${request.telegram}` : "—"} />
        <Row label="Phone" value={request.phone ?? "—"} />
      </dl>
      <Link to="/account" className="btn-ghost mt-6 w-full">Back to account</Link>
    </div>
  );
}

const Row = ({ label, value }: { label: string; value: string }) => (
  <div className="flex justify-between gap-4"><dt className="text-slate-500">{label}</dt><dd className="truncate text-slate-200">{value}</dd></div>
);

function RequestForm({ email, defaultName, previous, onSent }: {
  email: string; defaultName: string; previous: ProRequest | null; onSent: () => void;
}) {
  const [name, setName] = useState(defaultName);
  const [telegram, setTelegram] = useState(previous?.telegram ? `@${previous.telegram}` : "");
  const [phone, setPhone] = useState(previous?.phone ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await callApp("/pro/request", { name: name.trim(), telegram: telegram.trim(), phone: phone.trim() });
      onSent();
    } catch (err) {
      const code = err instanceof ApiError ? err.message : "";
      setError(errors[code] ?? (err instanceof Error ? err.message : String(err)));
      if (code === "pending" || code === "already-pro") onSent();
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold text-white">Leave your contact</h2>
        <p className="mt-1 text-sm text-slate-400">We'll reach out if we need anything.</p>
      </div>
      {previous && previous.status !== "pending" && (
        <Notice tone="info">
          {previous.status === "rejected" ? "Your previous request wasn't approved." : "Your Pro was turned off."} You can
          send a new request.
        </Notice>
      )}
      <div>
        <label className="label" htmlFor="name">Name <span className="text-rose-300">*</span></label>
        <input id="name" className="input" required minLength={2} maxLength={80} autoComplete="name"
          placeholder="Your name" value={name} onChange={(e) => setName(e.target.value)} />
      </div>
      <div>
        <label className="label" htmlFor="email">Email <span className="text-rose-300">*</span></label>
        <div className="relative">
          <input id="email" className="input cursor-not-allowed pr-24 text-slate-400" value={email} readOnly />
          <span className="absolute right-3 top-1/2 -translate-y-1/2 text-xs text-slate-500">your account</span>
        </div>
        <p className="mt-1 text-xs text-slate-500">Pro is given to this email. Sign in with another account to use a different one.</p>
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label className="label" htmlFor="tg">Telegram</label>
          <input id="tg" className="input" maxLength={33} placeholder="@username" pattern="@?[A-Za-z0-9_]{4,32}"
            title="4–32 letters, digits or _" value={telegram} onChange={(e) => setTelegram(e.target.value)} />
        </div>
        <div>
          <label className="label" htmlFor="phone">Phone</label>
          <input id="phone" type="tel" className="input" maxLength={20} autoComplete="tel" placeholder="+998 90 123 45 67"
            pattern={"\\+?[0-9 \\(\\)\\-]{7,20}"} title="Digits, spaces, + ( ) -" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </div>
      </div>
      {error && <Notice tone="error">{error}</Notice>}
      <button className="btn-primary w-full !py-3" disabled={busy}>{busy ? <Spinner className="h-4 w-4" /> : "Request Winter Pro"}</button>
    </form>
  );
}
