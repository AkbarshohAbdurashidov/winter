import {
  isSignInWithEmailLink, onAuthStateChanged, signInWithEmailLink, signOut as fbSignOut, type User,
} from "firebase/auth";
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { auth } from "./api";

export const EMAIL_KEY = "winterEmailForSignIn";

// A sign-in link works once; never complete it twice (React StrictMode
// runs effects twice in development).
let linkHandled = false;

interface SessionState {
  user: User | null;
  loading: boolean;
  /// The page was opened from a sign-in email on a browser that doesn't
  /// remember the address: ask for it, then call `completeEmailLink`.
  needsEmailForLink: boolean;
  linkError: string | null;
  completeEmailLink: (email: string) => Promise<void>;
}

const Ctx = createContext<SessionState>({
  user: null, loading: true, needsEmailForLink: false, linkError: null, completeEmailLink: async () => {},
});

/// Drops Firebase's sign-in parameters but keeps ours (code, next).
function cleanUrl() {
  const url = new URL(window.location.href);
  for (const p of ["apiKey", "oobCode", "mode", "lang", "continueUrl", "tenantId"]) url.searchParams.delete(p);
  window.history.replaceState(null, "", url.toString());
}

export function SessionProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [needsEmailForLink, setNeedsEmail] = useState(false);
  const [linkError, setLinkError] = useState<string | null>(null);

  const completeEmailLink = useCallback(async (email: string) => {
    setLinkError(null);
    try {
      await signInWithEmailLink(auth, email.trim(), window.location.href);
      localStorage.removeItem(EMAIL_KEY);
      setNeedsEmail(false);
      cleanUrl();
    } catch (e) {
      const code = (e as { code?: string }).code ?? "";
      setLinkError(code.includes("invalid-action-code") || code.includes("expired")
        ? "This sign-in link has expired or was already used. Request a new one."
        : code.includes("invalid-email") ? "That email doesn't match the link." : String(e));
      if (code.includes("invalid-action-code") || code.includes("expired")) {
        cleanUrl();
        setNeedsEmail(false);
      }
    }
  }, []);

  useEffect(() => {
    if (!linkHandled && isSignInWithEmailLink(auth, window.location.href)) {
      linkHandled = true;
      let saved: string | null = null;
      try { saved = localStorage.getItem(EMAIL_KEY); } catch { /* private mode */ }
      if (saved) completeEmailLink(saved);
      else setNeedsEmail(true);
    }
    return onAuthStateChanged(auth, (u) => {
      setUser(u);
      setLoading(false);
    });
  }, [completeEmailLink]);

  return (
    <Ctx.Provider value={{ user, loading, needsEmailForLink, linkError, completeEmailLink }}>
      {children}
    </Ctx.Provider>
  );
}

export const useSession = () => useContext(Ctx);
export const signOut = () => fbSignOut(auth);
