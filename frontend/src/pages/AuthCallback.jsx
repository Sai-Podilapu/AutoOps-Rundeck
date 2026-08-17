import React, { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { LogoMark } from "../components/ui";
import { useStore } from "../store/store";

// Handles the SSO redirect from the auth-service. Tokens arrive in the URL
// FRAGMENT (never sent to servers / access logs):
//   /auth/callback#accessToken=...&refreshToken=...
// Legacy query-param form is still accepted as a fallback.
export default function AuthCallback() {
  const navigate = useNavigate();
  const { completeOAuth } = useStore();
  const [error, setError] = useState("");
  const ran = useRef(false);

  useEffect(() => {
    if (ran.current) return;
    ran.current = true;
    const fragment = new URLSearchParams(
      window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "",
    );
    const query = new URLSearchParams(window.location.search);
    const pick = (key) => fragment.get(key) || query.get(key);
    const accessToken = pick("accessToken");
    const refreshToken = pick("refreshToken");
    const context = pick("context");
    const backendMessage = pick("message"); // errorToBrowser fragment
    // Scrub tokens from the address bar / history immediately.
    if (accessToken) {
      window.history.replaceState(null, "", window.location.pathname);
    }
    if (!accessToken) {
      // e.g. company_exists: "An organization for @acme.com already exists…"
      setError(backendMessage || "Sign-in was cancelled or failed.");
      return;
    }
    completeOAuth({ accessToken, refreshToken, context })
      .then((res) => {
        navigate(res && res.context === "provider" ? "/provider" : "/app", {
          replace: true,
        });
      })
      .catch(() => setError("Could not complete sign-in. Please try again."));
  }, [completeOAuth, navigate]);

  return (
    <div className="grid-bg flex min-h-screen items-center justify-center bg-white px-6">
      <div className="flex flex-col items-center gap-4 text-center">
        <LogoMark size={40} />
        {error ? (
          <>
            <p className="text-sm text-red-600">{error}</p>
            <button
              onClick={() => navigate("/login", { replace: true })}
              className="rounded-lg border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-900 transition hover:bg-slate-100"
            >
              Back to sign in
            </button>
          </>
        ) : (
          <p className="animate-pulse text-sm text-slate-500">
            Completing sign-in…
          </p>
        )}
      </div>
    </div>
  );
}
