import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { SignIn } from "../components/SignIn";
import { AccessBadge, Logo, Notice, RequestBadge, SnowBackground, Spinner } from "../components/ui";
import { formatDate, timeAgo, type Access, type ProRequest, type RequestStatus } from "../lib/api";
import * as data from "../lib/adminData";
import { signOut, useSession } from "../lib/session";

// ------------------------------------------------------------------ types

interface Stats {
  installs: number; active_1d: number; active_7d: number; active_30d: number; users: number;
  pro: number; requests: number; pending: number; approved: number; rejected: number; revoked: number;
  platforms: Record<string, number>; versions: Record<string, number>;
  new_installs_14d: { day: string; count: number }[];
}

interface UserRow {
  user_id: string; email: string; name: string | null; telegram: string | null; phone: string | null;
  request_id: string | null; request_status: RequestStatus | null;
  signed_up_at: string; last_sign_in_at: string | null; grant_id: string | null;
  grant_expires_at: string | null; grant_note: string | null; installs: number;
  last_seen: string | null; platforms: string | null; access: Access;
}

interface Grant {
  id: string; email: string; note: string | null; expires_at: string | null;
  created_by: string; created_at: string; revoked_at: string | null; request_id: string | null;
}

interface Install {
  install_id: string; user_id: string | null; platform: string; os_version: string | null;
  app_version: string | null; first_seen: string; last_seen: string; launches: number;
}

interface Device {
  token_hash: string; platform: string | null; created_at: string; last_seen: string; revoked_at: string | null;
}

type Tab = "overview" | "requests" | "users" | "grants" | "installs" | "admins";

// ------------------------------------------------------------------ page

export function AdminPage() {
  const { user, loading } = useSession();
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  const [tab, setTab] = useState<Tab>("overview");
  const [requests, setRequests] = useState<ProRequest[] | null>(null);
  const [requestsError, setRequestsError] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    data.isAdmin().then(setIsAdmin);
  }, [user]);

  // Live: a press in the Telegram bot shows up here without reloading.
  useEffect(() => {
    if (!isAdmin) return;
    return data.watchRequests((r) => { setRequests(r); setRequestsError(null); }, (e) => setRequestsError(e.message));
  }, [isAdmin]);
  const pending = requests?.filter((r) => r.status === "pending").length ?? 0;

  if (loading || (user && isAdmin === null)) {
    return <Centered><Spinner /></Centered>;
  }
  if (!user) {
    return <Centered><SignIn title="Winter Admin" subtitle="Sign in with an admin email." /></Centered>;
  }
  if (!isAdmin) {
    return (
      <Centered>
        <div className="glass max-w-md p-8 text-center">
          <h1 className="text-xl font-semibold text-white">No admin access</h1>
          <p className="mt-2 text-sm text-slate-400">{user.email} isn't an admin. Ask an admin to add you.</p>
          <div className="mt-6 flex justify-center gap-2">
            <Link to="/account" className="btn-ghost">My account</Link>
            <button className="btn-ghost" onClick={() => signOut()}>Sign out</button>
          </div>
        </div>
      </Centered>
    );
  }

  const tabs: { id: Tab; label: string; icon: ReactNode; badge?: number }[] = [
    { id: "overview", label: "Overview", icon: <IconChart /> },
    { id: "requests", label: "Pro requests", icon: <IconInbox />, badge: pending },
    { id: "users", label: "Users", icon: <IconUsers /> },
    { id: "grants", label: "Give Pro", icon: <IconGift /> },
    { id: "installs", label: "Installs", icon: <IconMonitor /> },
    { id: "admins", label: "Admins", icon: <IconShield /> },
  ];

  return (
    <div className="min-h-screen lg:flex">
      <SnowBackground />
      <aside className="border-b border-white/5 bg-night-950/60 backdrop-blur-xl lg:sticky lg:top-0 lg:h-screen lg:w-64 lg:shrink-0 lg:border-b-0 lg:border-r">
        <div className="flex items-center justify-between px-5 py-5">
          <Logo small />
          <span className="rounded-md bg-sky-300/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-sky-200 ring-1 ring-sky-200/20">Admin</span>
        </div>
        <nav className="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-col lg:pb-0">
          {tabs.map((t) => (
            <button key={t.id} onClick={() => setTab(t.id)}
              className={`flex shrink-0 items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition ${
                tab === t.id ? "bg-white/10 text-white" : "text-slate-400 hover:bg-white/5 hover:text-slate-200"}`}>
              <span className="h-4 w-4">{t.icon}</span>{t.label}
              {!!t.badge && (
                <span className="ml-auto grid h-5 min-w-5 place-items-center rounded-full bg-amber-400/20 px-1.5 text-[11px] font-semibold text-amber-100 ring-1 ring-amber-300/30">
                  {t.badge}
                </span>
              )}
            </button>
          ))}
        </nav>
        <div className="hidden px-5 py-5 text-xs text-slate-500 lg:absolute lg:bottom-0 lg:block lg:w-64">
          <p className="truncate">{user.email}</p>
          <button className="mt-1 text-slate-400 hover:text-white" onClick={() => signOut()}>Sign out</button>
        </div>
      </aside>
      <main className="min-w-0 flex-1 px-4 py-6 sm:px-8 lg:py-8">
        {tab === "overview" && <Overview onOpen={setTab} pendingLive={requests ? pending : null} />}
        {tab === "requests" && <Requests rows={requests} error={requestsError} />}
        {tab === "users" && <Users />}
        {tab === "grants" && <Grants />}
        {tab === "installs" && <Installs />}
        {tab === "admins" && <Admins self={user.email ?? ""} />}
      </main>
    </div>
  );
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="grid min-h-screen place-items-center px-4"><SnowBackground />{children}</div>;
}

function PageTitle({ title, subtitle, action }: { title: string; subtitle?: string; action?: ReactNode }) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-white">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-slate-400">{subtitle}</p>}
      </div>
      {action}
    </div>
  );
}

// -------------------------------------------------------------- overview

function Overview({ onOpen, pendingLive }: { onOpen: (t: Tab) => void; pendingLive: number | null }) {
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    data.fetchStats<Stats>().then(setStats).catch((e) => setError(String(e)));
  }, []);
  if (error) return <Notice tone="error">{error}</Notice>;
  if (!stats) return <div className="grid place-items-center py-24"><Spinner /></div>;

  const maxDay = Math.max(1, ...stats.new_installs_14d.map((d) => d.count));
  const platformTotal = Object.values(stats.platforms).reduce((a, b) => a + b, 0) || 1;

  return (
    <>
      <PageTitle title="Overview" subtitle="Who uses Winter, who asked for Pro and who has it." />
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Installs" value={stats.installs} hint={`${stats.active_7d} active this week`} />
        <Stat label="Active today" value={stats.active_1d} hint={`${stats.active_30d} in 30 days`} />
        <Stat label="Accounts" value={stats.users} hint="signed in at least once" onClick={() => onOpen("users")} />
        <Stat label="Winter Pro" value={stats.pro} tone="sky" hint="emails with active Pro" onClick={() => onOpen("users")} />
      </div>
      <div className="mt-3 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="Waiting for review" value={pendingLive ?? stats.pending} tone="amber" hint="Pro requests" onClick={() => onOpen("requests")} />
        <Stat label="Approved" value={stats.approved} tone="emerald" onClick={() => onOpen("requests")} />
        <Stat label="Rejected" value={stats.rejected} tone="rose" onClick={() => onOpen("requests")} />
        <Stat label="Pro removed" value={stats.revoked} hint={`${stats.requests} requests in total`} onClick={() => onOpen("requests")} />
      </div>

      <div className="mt-6 grid gap-3 lg:grid-cols-3">
        <section className="glass p-5 lg:col-span-2">
          <h3 className="mb-4 text-sm font-semibold text-white">New installs · last 14 days</h3>
          <div className="flex items-end gap-1.5">
            {stats.new_installs_14d.map((d) => (
              <div key={d.day} className="group flex flex-1 flex-col items-center gap-2">
                <div className="relative flex h-40 w-full items-end">
                  <div className="w-full rounded-t-md bg-gradient-to-t from-sky-500/40 to-sky-300/80 transition group-hover:to-sky-200"
                    style={{ height: `${Math.max(3, (d.count / maxDay) * 100)}%` }} />
                  <span className="absolute -top-6 left-1/2 -translate-x-1/2 rounded bg-night-800 px-1.5 py-0.5 text-[10px] text-white opacity-0 transition group-hover:opacity-100">
                    {d.count}
                  </span>
                </div>
                <span className="text-[10px] text-slate-500">{new Date(d.day).getDate()}</span>
              </div>
            ))}
          </div>
        </section>
        <section className="glass p-5">
          <h3 className="mb-4 text-sm font-semibold text-white">Platforms</h3>
          <div className="space-y-3">
            {Object.entries(stats.platforms).sort((a, b) => b[1] - a[1]).map(([p, n]) => (
              <div key={p}>
                <div className="mb-1 flex justify-between text-sm"><span className="text-slate-300">{platformName(p)}</span><span className="text-slate-400">{n}</span></div>
                <div className="h-2 overflow-hidden rounded-full bg-white/5"><div className="h-full rounded-full bg-sky-300/70" style={{ width: `${(n / platformTotal) * 100}%` }} /></div>
              </div>
            ))}
            {Object.keys(stats.platforms).length === 0 && <p className="text-sm text-slate-500">No installs yet.</p>}
          </div>
          <h3 className="mb-3 mt-6 text-sm font-semibold text-white">Versions</h3>
          <div className="flex flex-wrap gap-1.5">
            {Object.entries(stats.versions).map(([v, n]) => (
              <span key={v} className="rounded-lg bg-white/5 px-2 py-1 text-xs text-slate-300 ring-1 ring-white/10">{v} · {n}</span>
            ))}
          </div>
        </section>
      </div>
    </>
  );
}

const statTones = {
  default: "text-white", amber: "text-amber-200", emerald: "text-emerald-200", sky: "text-sky-200", rose: "text-rose-200",
};

function Stat({ label, value, hint, tone = "default", onClick }: {
  label: string; value: ReactNode; hint?: string; tone?: keyof typeof statTones; onClick?: () => void;
}) {
  return (
    <button onClick={onClick} disabled={!onClick}
      className="glass p-4 text-left transition enabled:hover:border-white/20 enabled:hover:bg-white/[0.06] sm:p-5">
      <p className="text-xs font-medium uppercase tracking-wider text-slate-400">{label}</p>
      <p className={`mt-2 text-2xl font-semibold sm:text-3xl ${statTones[tone]}`}>{value}</p>
      {hint && <p className="mt-1 text-xs text-slate-500">{hint}</p>}
    </button>
  );
}

const platformName = (p: string | null) =>
  p === "macos" ? "macOS" : p === "windows" ? "Windows" : p ? p[0].toUpperCase() + p.slice(1) : "—";

// ----------------------------------------------------------------- users

type UserFilter = "all" | Access | "pending";
const filters: { id: UserFilter; label: string }[] = [
  { id: "all", label: "All" }, { id: "pro", label: "Winter Pro" }, { id: "pending", label: "Waiting" }, { id: "none", label: "Free" },
];

function Users() {
  const [rows, setRows] = useState<UserRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<UserFilter>("all");
  const [selected, setSelected] = useState<UserRow | null>(null);

  const load = useCallback(async () => {
    try {
      const users = await data.fetchUsers<UserRow>();
      setRows(users);
      setSelected((s) => (s ? users.find((r) => r.user_id === s.user_id) ?? null : null));
    } catch (e) {
      setError(String(e));
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  const matches = (r: UserRow, f: UserFilter) =>
    f === "all" || (f === "pending" ? r.request_status === "pending" : r.access === f);
  const counts = useMemo(() => Object.fromEntries(filters.map((f) => [f.id, (rows ?? []).filter((r) => matches(r, f.id)).length])), [rows]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return (rows ?? []).filter((r) => matches(r, filter) &&
      (!q || [r.email, r.name, r.telegram, r.phone].some((v) => v?.toLowerCase().includes(q))));
  }, [rows, filter, query]);

  return (
    <>
      <PageTitle title="Users" subtitle="Everyone who signed in to Winter." action={
        <input className="input w-full sm:w-72" placeholder="Search name, email, @telegram…" value={query} onChange={(e) => setQuery(e.target.value)} />} />
      <div className="mb-4 flex flex-wrap gap-1.5">
        {filters.map((f) => (
          <button key={f.id} onClick={() => setFilter(f.id)}
            className={`rounded-full px-3 py-1.5 text-xs font-medium ring-1 transition ${
              filter === f.id ? "bg-sky-300/15 text-sky-100 ring-sky-200/40" : "bg-white/[0.03] text-slate-400 ring-white/10 hover:text-slate-200"}`}>
            {f.label} <span className="ml-1 text-slate-500">{counts[f.id] ?? 0}</span>
          </button>
        ))}
      </div>
      {error && <Notice tone="error">{error}</Notice>}
      {!rows && !error && <div className="grid place-items-center py-24"><Spinner /></div>}
      {rows && (
        <div className="glass overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[860px] text-left text-sm">
              <thead className="border-b border-white/5 text-xs uppercase tracking-wider text-slate-500">
                <tr>
                  <th className="px-5 py-3 font-medium">User</th>
                  <th className="px-3 py-3 font-medium">Access</th>
                  <th className="px-3 py-3 font-medium">Pro request</th>
                  <th className="px-3 py-3 font-medium">Contact</th>
                  <th className="px-3 py-3 font-medium">Computers</th>
                  <th className="px-5 py-3 font-medium">Last seen</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {visible.map((r) => (
                  <tr key={r.user_id} onClick={() => setSelected(r)} className="cursor-pointer transition hover:bg-white/[0.04]">
                    <td className="px-5 py-3">
                      <p className="font-medium text-slate-100">{r.name ?? r.email}</p>
                      <p className="text-xs text-slate-500">{r.name ? `${r.email} · ` : ""}joined {formatDate(r.signed_up_at)}</p>
                    </td>
                    <td className="px-3 py-3"><AccessBadge access={r.access} /></td>
                    <td className="px-3 py-3">{r.request_status ? <RequestBadge status={r.request_status} /> : <span className="text-slate-500">—</span>}</td>
                    <td className="px-3 py-3 text-slate-400" onClick={(e) => e.stopPropagation()}><Contact telegram={r.telegram} phone={r.phone} /></td>
                    <td className="px-3 py-3 text-slate-400">{r.installs > 0 ? `${r.installs} · ${(r.platforms ?? "").split(", ").map(platformName).join(", ")}` : "—"}</td>
                    <td className="px-5 py-3 text-slate-400">{timeAgo(r.last_seen)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {visible.length === 0 && <p className="px-5 py-10 text-center text-sm text-slate-500">No users match.</p>}
        </div>
      )}
      {selected && <UserDrawer user={selected} onClose={() => setSelected(null)} onChanged={load} />}
    </>
  );
}

function Contact({ telegram, phone }: { telegram: string | null; phone: string | null }) {
  if (!telegram && !phone) return <span className="text-slate-500">—</span>;
  return (
    <div className="flex flex-col gap-0.5 text-xs">
      {telegram && <a href={`https://t.me/${telegram}`} target="_blank" rel="noreferrer" className="text-sky-300 hover:underline">@{telegram}</a>}
      {phone && <a href={`tel:${phone.replace(/[^+0-9]/g, "")}`} className="text-slate-300 hover:underline">{phone}</a>}
    </div>
  );
}

function UserDrawer({ user, onClose, onChanged }: { user: UserRow; onClose: () => void; onChanged: () => void }) {
  const [devices, setDevices] = useState<Device[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);

  const loadDevices = useCallback(() => {
    data.fetchDevices(user.user_id).then(setDevices);
  }, [user.user_id]);
  useEffect(() => { loadDevices(); }, [loadDevices]);

  async function run(label: string, fn: () => Promise<string | void>) {
    setBusy(label);
    setMessage(null);
    try {
      const text = await fn();
      if (text) setMessage({ tone: "success", text });
      onChanged();
    } catch (e) {
      setMessage({ tone: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(null);
    }
  }

  const revokeGrant = () => run("revoke", async () => {
    if (user.grant_id) await data.revokeGrant(user.grant_id);
    return "Pro removed.";
  });

  const decide = (action: "approve" | "reject") => run(action, async () => {
    if (user.request_id) await data.decideRequest(user.request_id, action);
    return action === "approve" ? "Request approved — Pro is on." : "Request rejected.";
  });

  const signOutDevice = (hash: string) => run("device", async () => {
    await data.revokeDevice(hash);
    loadDevices();
    return "Computer signed out.";
  });

  return (
    <div className="fixed inset-0 z-50 flex justify-end">
      <div className="absolute inset-0 bg-black/50 backdrop-blur-sm" onClick={onClose} />
      <div className="relative h-full w-full max-w-lg overflow-y-auto border-l border-white/10 bg-night-900/95 p-6 shadow-2xl backdrop-blur-xl sm:p-8">
        <div className="mb-6 flex items-start justify-between gap-4">
          <div className="min-w-0">
            <p className="text-xs uppercase tracking-wider text-slate-500">User</p>
            <h2 className="truncate text-xl font-semibold text-white">{user.name ?? user.email}</h2>
            {user.name && <p className="truncate text-sm text-slate-400">{user.email}</p>}
            <p className="mt-1 font-mono text-[11px] text-slate-500">{user.user_id}</p>
          </div>
          <button onClick={onClose} className="btn-ghost !px-3 !py-1.5" aria-label="Close">✕</button>
        </div>

        {message && <div className="mb-4"><Notice tone={message.tone}>{message.text}</Notice></div>}

        <section className="glass mb-4 p-5">
          <div className="mb-3 flex items-center justify-between"><h3 className="text-sm font-semibold text-white">Winter Pro</h3><AccessBadge access={user.access} /></div>
          <dl className="mb-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
            <Field label="Pro request" value={user.request_status ? <RequestBadge status={user.request_status} /> : "—"} />
            <Field label="Contact" value={<Contact telegram={user.telegram} phone={user.phone} />} />
            <Field label="Signed up" value={formatDate(user.signed_up_at)} />
            <Field label="Last sign-in" value={formatDate(user.last_sign_in_at)} />
            {user.grant_id && <Field label="Pro until" value={user.grant_expires_at ? formatDate(user.grant_expires_at) : "Forever"} />}
            {user.grant_note && <Field label="Note" value={user.grant_note} />}
          </dl>
          {user.request_status === "pending" && !user.grant_id && (
            <div className="mb-4 grid grid-cols-2 gap-2">
              <button className="btn-primary" onClick={() => decide("approve")} disabled={busy !== null}>
                {busy === "approve" ? <Spinner className="h-4 w-4" /> : "Approve request"}
              </button>
              <button className="btn-danger" onClick={() => decide("reject")} disabled={busy !== null}>Reject</button>
            </div>
          )}
          {user.grant_id ? (
            <button className="btn-danger w-full" onClick={revokeGrant} disabled={busy !== null}>
              {busy === "revoke" ? <Spinner className="h-4 w-4" /> : "Remove Pro"}
            </button>
          ) : (
            <GrantForm email={user.email} compact onDone={(t) => { setMessage({ tone: "success", text: t }); onChanged(); }} />
          )}
        </section>

        <section className="glass p-5">
          <h3 className="mb-3 text-sm font-semibold text-white">Computers</h3>
          {devices.length === 0 && <p className="text-sm text-slate-500">Not signed in on any computer.</p>}
          <ul className="divide-y divide-white/5">
            {devices.map((d) => (
              <li key={d.token_hash} className="flex items-center justify-between gap-3 py-2.5">
                <div>
                  <p className="text-sm text-slate-200">{platformName(d.platform)}</p>
                  <p className="text-xs text-slate-500">Linked {formatDate(d.created_at)} · seen {timeAgo(d.last_seen)}</p>
                </div>
                {d.revoked_at ? <span className="text-xs text-slate-500">Signed out</span> : (
                  <button className="btn-ghost !py-1.5 text-xs" onClick={() => signOutDevice(d.token_hash)} disabled={busy !== null}>Sign out</button>
                )}
              </li>
            ))}
          </ul>
        </section>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div>
      <dt className="text-xs text-slate-500">{label}</dt>
      <dd className="mt-0.5 text-slate-200">{value}</dd>
    </div>
  );
}

// ---------------------------------------------------------------- grants

function GrantForm({ email: initialEmail = "", compact = false, onDone }: { email?: string; compact?: boolean; onDone: (text: string) => void }) {
  const [email, setEmail] = useState(initialEmail);
  const [duration, setDuration] = useState("forever");
  const [until, setUntil] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    let expires: string | null = null;
    const now = new Date();
    if (duration === "1m") expires = new Date(now.setMonth(now.getMonth() + 1)).toISOString();
    if (duration === "3m") expires = new Date(now.setMonth(now.getMonth() + 3)).toISOString();
    if (duration === "1y") expires = new Date(now.setFullYear(now.getFullYear() + 1)).toISOString();
    if (duration === "custom") expires = until ? new Date(`${until}T23:59:59`).toISOString() : null;
    if (duration === "custom" && !expires) { setBusy(false); return setError("Pick an end date."); }
    const clean = email.trim().toLowerCase();
    // One active grant per email: end the previous one first.
    try {
      await data.giveGrant(clean, expires ? new Date(expires) : null, note.trim() || null);
    } catch (e) {
      setBusy(false);
      return setError(String(e));
    }
    setBusy(false);
    if (!compact) { setEmail(""); setNote(""); }
    onDone(`${clean} now has Winter Pro${expires ? ` until ${formatDate(expires)}` : " forever"}.`);
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      {!compact && (
        <div>
          <label className="label">Email</label>
          <input type="email" required className="input" placeholder="friend@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
        </div>
      )}
      <div>
        <label className="label">Duration</label>
        <div className="flex flex-wrap gap-1.5">
          {[["forever", "Forever"], ["1m", "1 month"], ["3m", "3 months"], ["1y", "1 year"], ["custom", "Until…"]].map(([id, label]) => (
            <button type="button" key={id} onClick={() => setDuration(id)}
              className={`whitespace-nowrap rounded-lg px-3 py-2 text-xs font-medium ring-1 transition ${
                duration === id ? "bg-sky-300/15 text-sky-100 ring-sky-200/40" : "bg-white/[0.03] text-slate-400 ring-white/10 hover:text-slate-200"}`}>
              {label}
            </button>
          ))}
        </div>
      </div>
      {duration === "custom" && <input type="date" className="input" value={until} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setUntil(e.target.value)} />}
      <input className="input" placeholder="Note (optional) — e.g. beta tester" value={note} onChange={(e) => setNote(e.target.value)} />
      {error && <Notice tone="error">{error}</Notice>}
      <button className="btn-primary w-full" disabled={busy}>{busy ? <Spinner className="h-4 w-4" /> : "Give Pro"}</button>
    </form>
  );
}

function Grants() {
  const [grants, setGrants] = useState<Grant[] | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const load = useCallback(() => {
    data.fetchGrants().then((g) => setGrants(g as Grant[]));
  }, []);
  useEffect(() => { load(); }, [load]);

  async function revoke(id: string) {
    await data.revokeGrant(id);
    load();
  }

  const isActive = (g: Grant) => !g.revoked_at && (!g.expires_at || new Date(g.expires_at) > new Date());

  return (
    <>
      <PageTitle title="Give Pro" subtitle="Give Winter Pro to anyone by email — it works even before they sign up." />
      <div className="grid gap-4 lg:grid-cols-[360px_1fr]">
        <section className="glass h-fit p-5">
          <h3 className="mb-4 text-sm font-semibold text-white">Give Pro by email</h3>
          {message && <div className="mb-3"><Notice tone="success">{message}</Notice></div>}
          <GrantForm onDone={(t) => { setMessage(t); load(); }} />
        </section>
        <section className="glass overflow-hidden">
          {!grants ? <div className="grid place-items-center py-16"><Spinner /></div> : grants.length === 0 ? (
            <p className="px-5 py-12 text-center text-sm text-slate-500">Nobody has Pro yet.</p>
          ) : (
            <ul className="divide-y divide-white/5">
              {grants.map((g) => (
                <li key={g.id} className="flex flex-wrap items-center justify-between gap-3 px-5 py-3.5">
                  <div className="min-w-0">
                    <p className="truncate font-medium text-slate-100">{g.email}</p>
                    <p className="text-xs text-slate-500">
                      {g.expires_at ? `Until ${formatDate(g.expires_at)}` : "Forever"} · by {g.created_by} · {formatDate(g.created_at)}
                      {g.note && <> · <span className="text-slate-400">{g.note}</span></>}
                      {g.request_id && <> · <span className="text-sky-300/80">from request</span></>}
                    </p>
                  </div>
                  {isActive(g) ? (
                    <button className="btn-danger !py-1.5 text-xs" onClick={() => revoke(g.id)}>Remove</button>
                  ) : (
                    <span className="text-xs text-slate-500">{g.revoked_at ? "Removed" : "Ended"}</span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </>
  );
}

// --------------------------------------------------------------- requests

const requestFilters: { id: "all" | RequestStatus; label: string }[] = [
  { id: "pending", label: "Waiting" }, { id: "approved", label: "Approved" }, { id: "rejected", label: "Rejected" },
  { id: "revoked", label: "Pro removed" }, { id: "all", label: "All" },
];

function Requests({ rows, error }: { rows: ProRequest[] | null; error: string | null }) {
  const [filter, setFilter] = useState<"all" | RequestStatus>("pending");
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);
  const counts = useMemo(() => {
    const c: Record<string, number> = { all: rows?.length ?? 0 };
    rows?.forEach((r) => { c[r.status] = (c[r.status] ?? 0) + 1; });
    return c;
  }, [rows]);
  const visible = (rows ?? []).filter((r) => filter === "all" || r.status === filter);

  async function decide(r: ProRequest, action: "approve" | "reject" | "revoke") {
    setBusy(`${r.id}:${action}`);
    setMessage(null);
    try {
      const res = await data.decideRequest(r.id, action);
      setMessage(res.changed
        ? { tone: "success", text: `${r.email}: ${action === "approve" ? "Pro is on" : action === "reject" ? "rejected" : "Pro removed"}. The bot message was updated.` }
        : { tone: "error", text: `${r.email} was already changed (maybe in Telegram).` });
    } catch (e) {
      setMessage({ tone: "error", text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageTitle title="Pro requests" subtitle="Approve here or in the Telegram bot — both stay in sync, live." />
      <TelegramCard />
      <div className="mb-4 mt-6 flex flex-wrap gap-1.5">
        {requestFilters.map((f) => (
          <button key={f.id} onClick={() => setFilter(f.id)}
            className={`rounded-full px-3 py-1.5 text-xs font-medium ring-1 transition ${
              filter === f.id ? "bg-sky-300/15 text-sky-100 ring-sky-200/40" : "bg-white/[0.03] text-slate-400 ring-white/10 hover:text-slate-200"}`}>
            {f.label} <span className="ml-1 text-slate-500">{counts[f.id] ?? 0}</span>
          </button>
        ))}
      </div>
      {message && <div className="mb-4"><Notice tone={message.tone}>{message.text}</Notice></div>}
      {error && <Notice tone="error">{error}</Notice>}
      {!rows && !error && <div className="grid place-items-center py-24"><Spinner /></div>}
      {rows && visible.length === 0 && (
        <div className="glass px-5 py-14 text-center text-sm text-slate-500">
          {filter === "pending" ? "No requests waiting. 🎉" : "Nothing here."}
        </div>
      )}
      <div className="grid gap-3 xl:grid-cols-2">
        {visible.map((r) => (
          <article key={r.id} className={`glass p-5 transition ${r.status === "pending" ? "ring-1 ring-amber-300/20" : ""}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <h3 className="truncate text-base font-semibold text-white">{r.name}</h3>
                <p className="truncate text-sm text-slate-400">{r.email}</p>
              </div>
              <RequestBadge status={r.status} />
            </div>
            <div className="mt-4 flex flex-wrap gap-2 text-xs">
              {r.telegram && (
                <a href={`https://t.me/${r.telegram}`} target="_blank" rel="noreferrer"
                  className="rounded-lg bg-sky-400/10 px-2.5 py-1.5 text-sky-200 ring-1 ring-sky-300/20 hover:bg-sky-400/20">✈ @{r.telegram}</a>
              )}
              {r.phone && (
                <a href={`tel:${r.phone.replace(/[^+0-9]/g, "")}`}
                  className="rounded-lg bg-white/5 px-2.5 py-1.5 text-slate-200 ring-1 ring-white/10 hover:bg-white/10">☎ {r.phone}</a>
              )}
              {!r.telegram && !r.phone && <span className="text-slate-500">No contact besides email</span>}
            </div>
            <p className="mt-4 text-xs text-slate-500">
              Requested {formatDate(r.created_at, true)}
              {r.status !== "pending" && r.decided_by && <> · {decidedLabel(r.status)} by <span className="text-slate-400">{r.decided_by}</span> {timeAgo(r.decided_at)}</>}
            </p>
            <div className="mt-4 flex gap-2">
              {r.status === "pending" && (
                <>
                  <button className="btn-primary flex-1" disabled={busy !== null} onClick={() => decide(r, "approve")}>
                    {busy === `${r.id}:approve` ? <Spinner className="h-4 w-4" /> : "✓ Approve"}
                  </button>
                  <button className="btn-danger flex-1" disabled={busy !== null} onClick={() => decide(r, "reject")}>
                    {busy === `${r.id}:reject` ? <Spinner className="h-4 w-4" /> : "Reject"}
                  </button>
                </>
              )}
              {r.status === "approved" && (
                <button className="btn-danger flex-1" disabled={busy !== null} onClick={() => decide(r, "revoke")}>
                  {busy === `${r.id}:revoke` ? <Spinner className="h-4 w-4" /> : "Remove Pro"}
                </button>
              )}
              {(r.status === "rejected" || r.status === "revoked") && (
                <button className="btn-ghost flex-1" disabled={busy !== null} onClick={() => decide(r, "approve")}>
                  {busy === `${r.id}:approve` ? <Spinner className="h-4 w-4" /> : "Approve anyway"}
                </button>
              )}
            </div>
          </article>
        ))}
      </div>
    </>
  );
}

const decidedLabel = (s: RequestStatus) => (s === "approved" ? "approved" : s === "rejected" ? "rejected" : "Pro removed");

function TelegramCard() {
  const [status, setStatus] = useState<data.TelegramStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = useCallback(() => {
    data.telegramStatus().then((s) => { setStatus(s); setError(null); }).catch((e) => setError(String(e)));
  }, []);
  useEffect(() => { load(); }, [load]);

  async function connect() {
    setBusy(true);
    try {
      await data.telegramConnect();
      load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const connected = !!status?.webhookUrl && status.webhookUrl === status.expectedUrl;
  return (
    <section className="glass flex flex-wrap items-center justify-between gap-4 p-5">
      <div className="flex min-w-0 items-center gap-4">
        <span className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-sky-400/15 text-sky-200 ring-1 ring-sky-300/30"><IconSend /></span>
        <div className="min-w-0">
          <p className="text-sm font-semibold text-white">
            Telegram bot {status?.bot && <a href={`https://t.me/${status.bot.username}`} target="_blank" rel="noreferrer" className="font-normal text-sky-300 hover:underline">@{status.bot.username}</a>}
          </p>
          <p className="truncate text-xs text-slate-400">
            {!status && !error && "Checking…"}
            {error && <span className="text-rose-300">{error}</span>}
            {status && !status.configured && "Not set up: TELEGRAM_BOT_TOKEN secret and TELEGRAM_CHAT_ID are needed (see docs/MONETIZATION.md)."}
            {status?.configured && !status.bot && "The bot token was rejected by Telegram."}
            {status?.configured && status.bot && (connected
              ? <>New users and requests go to chat <span className="font-mono">{status.chatId}</span>; buttons work.</>
              : "Notifications work. Connect to make the bot's buttons work.")}
            {status?.lastError && <span className="ml-1 text-amber-300">· last error: {status.lastError}</span>}
          </p>
        </div>
      </div>
      {status?.configured && status.bot && (connected
        ? <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-400/15 px-2.5 py-1 text-xs font-medium text-emerald-200 ring-1 ring-emerald-300/30"><span className="h-1.5 w-1.5 rounded-full bg-current" />Connected</span>
        : <button className="btn-primary" onClick={connect} disabled={busy}>{busy ? <Spinner className="h-4 w-4" /> : "Connect buttons"}</button>)}
    </section>
  );
}

// -------------------------------------------------------------- installs

function Installs() {
  const [rows, setRows] = useState<Install[] | null>(null);
  const [emails, setEmails] = useState<Record<string, string>>({});
  useEffect(() => {
    data.fetchInstalls().then((r) => setRows(r as Install[]));
    data.fetchUsers<{ user_id: string; email: string }>().then((users) =>
      setEmails(Object.fromEntries(users.map((u) => [u.user_id, u.email]))));
  }, []);
  return (
    <>
      <PageTitle title="Installs" subtitle="Every copy of Winter that has started (anonymous unless signed in)." />
      <div className="glass overflow-hidden">
        {!rows ? <div className="grid place-items-center py-16"><Spinner /></div> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-left text-sm">
              <thead className="border-b border-white/5 text-xs uppercase tracking-wider text-slate-500">
                <tr>
                  <th className="px-5 py-3 font-medium">Computer</th>
                  <th className="px-3 py-3 font-medium">Version</th>
                  <th className="px-3 py-3 font-medium">Account</th>
                  <th className="px-3 py-3 font-medium">Launches</th>
                  <th className="px-3 py-3 font-medium">First seen</th>
                  <th className="px-5 py-3 font-medium">Last seen</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-white/5">
                {rows.map((r) => (
                  <tr key={r.install_id}>
                    <td className="px-5 py-3">
                      <p className="text-slate-100">{platformName(r.platform)}</p>
                      <p className="text-xs text-slate-500">{r.os_version ?? ""}</p>
                    </td>
                    <td className="px-3 py-3 text-slate-300">{r.app_version ?? "—"}</td>
                    <td className="px-3 py-3 text-slate-300">{r.user_id ? emails[r.user_id] ?? "signed in" : <span className="text-slate-500">anonymous</span>}</td>
                    <td className="px-3 py-3 tabular-nums text-slate-400">{r.launches}</td>
                    <td className="px-3 py-3 text-slate-400">{formatDate(r.first_seen)}</td>
                    <td className="px-5 py-3 text-slate-400">{timeAgo(r.last_seen)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {rows.length === 0 && <p className="px-5 py-12 text-center text-sm text-slate-500">No installs yet.</p>}
          </div>
        )}
      </div>
    </>
  );
}

// ---------------------------------------------------------------- admins

function Admins({ self }: { self: string }) {
  const [admins, setAdmins] = useState<{ email: string; added_at: string }[]>([]);
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => {
    data.fetchAdmins().then(setAdmins);
  }, []);
  useEffect(() => { load(); }, [load]);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    try {
      await data.addAdmin(email);
    } catch (e) {
      return setError(e instanceof Error ? e.message : String(e));
    }
    setEmail("");
    load();
  }

  async function remove(target: string) {
    await data.removeAdmin(target);
    load();
  }

  return (
    <>
      <PageTitle title="Admins" subtitle="People who can open this panel." />
      <div className="grid gap-4 lg:grid-cols-[360px_1fr]">
        <form onSubmit={add} className="glass h-fit space-y-3 p-5">
          <label className="label">Add admin by email</label>
          <input type="email" required className="input" placeholder="teammate@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
          {error && <Notice tone="error">{error}</Notice>}
          <button className="btn-primary w-full">Add admin</button>
        </form>
        <ul className="glass divide-y divide-white/5">
          {admins.map((a) => (
            <li key={a.email} className="flex items-center justify-between px-5 py-3.5">
              <div>
                <p className="text-slate-100">{a.email}{a.email === self.toLowerCase() && <span className="ml-2 text-xs text-slate-500">(you)</span>}</p>
                <p className="text-xs text-slate-500">Added {formatDate(a.added_at)}</p>
              </div>
              {a.email !== self.toLowerCase() && <button className="btn-danger !py-1.5 text-xs" onClick={() => remove(a.email)}>Remove</button>}
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

// ----------------------------------------------------------------- icons

const svg = (d: string) => () => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" className="h-4 w-4"><path d={d} /></svg>
);
const IconChart = svg("M4 20V10M10 20V4M16 20v-7M22 20H2");
const IconUsers = svg("M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8M22 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8");
const IconGift = svg("M20 12v10H4V12M2 7h20v5H2zM12 22V7M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7zM12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z");
const IconMonitor = svg("M2 3h20v14H2zM8 21h8M12 17v4");
const IconInbox = svg("M22 12h-6l-2 3h-4l-2-3H2M5.5 5.1 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.5-6.9A2 2 0 0 0 16.7 4H7.3a2 2 0 0 0-1.8 1.1z");
const IconSend = svg("M22 2 11 13M22 2l-7 20-4-9-9-4z");
const IconShield = svg("M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z");
