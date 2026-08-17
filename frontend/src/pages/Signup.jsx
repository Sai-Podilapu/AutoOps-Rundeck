import React, { useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { LogoMark } from "../components/ui";
import { tiers } from "../data/saasData";
import { GoogleLogo, MicrosoftLogo } from "../components/BrandLogos";
import { useStore } from "../store/store";
import { api, oauthUrl } from "../lib/api";
import Icon from "../components/Icon";

export default function Signup() {
  const navigate = useNavigate();
  const location = useLocation();
  const { signUp, verifySignup, resendSignupCode, refreshWorkspace, pushToast } =
    useStore();
  const [step, setStep] = useState("form"); // "form" | "verify"
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [workspaceName, setWorkspaceName] = useState("");
  const [code, setCode] = useState("");
  const [plan, setPlan] = useState("Team");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const order = ["Starter", "Team", "Business", "Enterprise"];

  // Login redirects unverified accounts here with the email to verify.
  useEffect(() => {
    const pending = location.state && location.state.verify;
    if (pending) {
      setEmail(pending);
      setStep("verify");
      resendSignupCode(pending).catch(() => {});
      pushToast("We emailed you a new verification code", "cyan");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const submit = async (e) => {
    e.preventDefault();
    if (busy) return;
    setError("");
    if (password.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    setBusy(true);
    try {
      const payload = {
        name: name.trim(),
        email: email.trim(),
        password,
      };
      if (workspaceName.trim()) payload.workspaceName = workspaceName.trim();
      await signUp(payload);
      setStep("verify");
      pushToast("Check your email for a verification code", "cyan");
    } catch (err) {
      setError(err.message || "Could not create your account.");
    } finally {
      setBusy(false);
    }
  };

  const verify = async (e) => {
    e.preventDefault();
    if (busy) return;
    setError("");
    setBusy(true);
    try {
      const res = await verifySignup(email.trim(), code.trim());
      // Start the selected plan's trial for the new workspace. Non-fatal:
      // the Billing page can pick a plan later if this call fails.
      try {
        await api.subscribePlan(plan);
        // The sign-in above fetched the plan BEFORE this subscribe existed —
        // refresh so the sidebar/profile don't show "Free" all session.
        refreshWorkspace();
      } catch {
        /* workspace exists; plan can be chosen in Billing */
      }
      pushToast("Workspace created — welcome to AutoOps", "emerald");
      navigate(res && res.context === "provider" ? "/provider" : "/onboarding");
    } catch (err) {
      setError(err.message || "Invalid or expired code.");
    } finally {
      setBusy(false);
    }
  };

  const resend = async () => {
    if (busy) return;
    setError("");
    try {
      await resendSignupCode(email.trim());
      pushToast("We emailed you a new code", "cyan");
    } catch (err) {
      setError(err.message || "Could not resend the code.");
    }
  };

  const oauth = (provider) => {
    window.location.href = oauthUrl(provider);
  };

  if (step === "verify") {
    return (
      <div className="grid-bg relative flex min-h-screen items-center justify-center overflow-hidden bg-white px-6 py-12">
        <div className="w-full max-w-md animate-fade-up">
          <Link to="/" className="mb-8 flex items-center justify-center gap-2.5">
            <LogoMark size={34} />
          </Link>
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-8 shadow-2xl shadow-slate-300/40 backdrop-blur-sm">
            <h1 className="text-xl font-semibold text-slate-900">
              Verify your email
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              We sent a 6-digit code to{" "}
              <span className="font-medium text-slate-900">{email}</span>.
            </p>
            <form onSubmit={verify} className="mt-6 space-y-4">
              <input
                value={code}
                autoFocus
                inputMode="numeric"
                required
                onChange={(e) =>
                  setCode(e.target.value.replace(/\D/g, "").slice(0, 8))
                }
                placeholder="123456"
                className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-center text-lg font-semibold tracking-[0.4em] text-slate-900 outline-none transition placeholder:tracking-normal placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
              />
              {error && (
                <p className="rounded-lg border border-red-400/30 bg-red-400/10 px-3 py-2 text-xs text-red-600">
                  {error}
                </p>
              )}
              <button
                type="submit"
                disabled={busy || !code}
                className="flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40 disabled:opacity-50"
              >
                {busy ? "Verifying…" : "Verify & continue →"}
              </button>
              <p className="text-center text-xs text-slate-500">
                Didn’t get it?{" "}
                <button
                  type="button"
                  onClick={resend}
                  disabled={busy}
                  className="text-slate-900 hover:underline disabled:opacity-50"
                >
                  Resend code
                </button>
              </p>
            </form>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="grid-bg relative flex min-h-screen items-center justify-center overflow-hidden bg-white px-6 py-12">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-0 h-[420px] w-[620px] rounded-full bg-emerald-600/15 blur-[150px]" />
      </div>

      <div className="w-full max-w-xl animate-fade-up">
        <Link to="/" className="mb-8 flex items-center justify-center gap-2.5">
          <LogoMark size={34} />
        </Link>

        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-8 shadow-2xl shadow-slate-300/40 backdrop-blur-sm">
          <h1 className="text-xl font-semibold text-slate-900">
            Start your free trial
          </h1>
          <p className="mt-1 text-sm text-slate-500">
            Spin up your AutoOps workspace in under a minute.
          </p>

          <form onSubmit={submit} className="mt-6 space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Full name
                </label>
                <input
                  value={name}
                  required
                  onChange={(e) => setName(e.target.value)}
                  placeholder="Your Name"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Work email
                </label>
                <input
                  type="email"
                  value={email}
                  required
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@company.com"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Password
                </label>
                <div className="relative">
                  <input
                    type={showPassword ? "text" : "password"}
                    value={password}
                    required
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="At least 8 characters"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 pr-10 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600 focus:outline-none"
                    aria-label={showPassword ? "Hide password" : "Show password"}
                  >
                    <Icon name={showPassword ? "eye-slash" : "eye"} size={18} />
                  </button>
                </div>
              </div>
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Organization name
                </label>
                <input
                  value={workspaceName}
                  onChange={(e) => setWorkspaceName(e.target.value)}
                  placeholder="Company Name"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>
            </div>

            <div>
              <label className="mb-2 block text-xs font-medium text-slate-500">
                Choose a plan
              </label>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                {order.map((t) => (
                  <button
                    type="button"
                    key={t}
                    onClick={() => setPlan(t)}
                    className={`rounded-xl border p-3 text-left transition ${plan === t ? "border-blue-500 bg-blue-50" : "border-slate-200 bg-slate-50 hover:border-blue-500"}`}
                  >
                    <p className="text-sm font-semibold text-slate-900">{t}</p>
                    <p className="text-xs text-slate-500">
                      ${tiers[t].price}/mo
                    </p>
                  </button>
                ))}
              </div>
            </div>

            {error && (
              <p className="rounded-lg border border-red-400/30 bg-red-400/10 px-3 py-2 text-xs text-red-600">
                {error}
              </p>
            )}

            <button
              type="submit"
              disabled={busy}
              className="flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:bg-blue-600 hover:shadow-blue-300/40 disabled:opacity-50"
            >
              {busy ? "Creating workspace…" : "Create workspace"}{" "}
              {!busy && <Icon name="arrow-right" size={16} />}
            </button>
          </form>

          <div className="my-6 flex items-center gap-3 text-xs text-slate-600">
            <span className="h-px flex-1 bg-slate-50" /> or continue with{" "}
            <span className="h-px flex-1 bg-slate-50" />
          </div>

          <div className="grid gap-2.5 sm:grid-cols-2">
            <button
              type="button"
              onClick={() => oauth("google")}
              className="flex items-center justify-center gap-2.5 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
            >
              <GoogleLogo size={18} /> Google
            </button>
            <button
              type="button"
              onClick={() => oauth("microsoft")}
              className="flex items-center justify-center gap-2.5 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
            >
              <MicrosoftLogo size={16} /> Microsoft
            </button>
          </div>
        </div>

        <p className="mt-6 text-center text-sm text-slate-500">
          Already have an account?{" "}
          <Link to="/login" className="text-slate-900 hover:underline">
            Sign in
          </Link>
        </p>
      </div>
    </div>
  );
}
