import React, { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { LogoMark } from "../components/ui";
import { GoogleLogo, MicrosoftLogo } from "../components/BrandLogos";
import { useStore } from "../store/store";
import { oauthUrl, enterpriseSsoUrl } from "../lib/api";
import Icon from "../components/Icon";

export default function Login() {
  const navigate = useNavigate();
  const { signIn, requestOtp, signInWithOtp, forgotPassword, resetPassword, pushToast } =
    useStore();
  const [mode, setMode] = useState("password"); // "password" | "otp" | "reset"
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [otpSent, setOtpSent] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [showPassword, setShowPassword] = useState(false);

  const routeAfter = (res) => {
    if (res.context === "provider") {
      pushToast("Signed in to provider console", "violet");
      navigate("/provider");
    } else if (res.context === "no-workspace") {
      pushToast("Signed in — finish setting up your workspace", "cyan");
      navigate("/onboarding");
    } else {
      pushToast("Signed in", "emerald");
      navigate("/app");
    }
  };

  const submit = async (e) => {
    e.preventDefault();
    if (busy) return;
    setError("");
    setBusy(true);
    try {
      const res = await signIn(email.trim(), password);
      routeAfter(res);
    } catch (err) {
      if (err.data && err.data.error === "email_unverified") {
        // Correct password, unverified email: send them to the verify step.
        navigate("/signup", { state: { verify: email.trim() } });
        return;
      }
      if (err.data && err.data.error === "sso_required") {
        // Workspace enforces company SSO — route to their IdP.
        pushToast("Redirecting to your company's sign-in…", "cyan");
        window.location.href = enterpriseSsoUrl(email.trim());
        return;
      }
      setError(err.message || "Unable to sign in. Check your credentials.");
    } finally {
      setBusy(false);
    }
  };

  const sendResetCode = async (e) => {
    e.preventDefault();
    if (busy) return;
    if (!email.trim()) {
      setError("Enter your email to receive a reset code.");
      return;
    }
    setError("");
    setBusy(true);
    try {
      await forgotPassword(email.trim());
      setOtpSent(true);
      pushToast("We emailed you a password reset code", "cyan");
    } catch (err) {
      setError(err.message || "Could not send a reset code. Try again.");
    } finally {
      setBusy(false);
    }
  };

  const completeReset = async (e) => {
    e.preventDefault();
    if (busy) return;
    if (password.length < 8) {
      setError("New password must be at least 8 characters.");
      return;
    }
    setError("");
    setBusy(true);
    try {
      const res = await resetPassword(email.trim(), code.trim(), password);
      pushToast("Password updated — you're signed in", "emerald");
      routeAfter(res);
    } catch (err) {
      setError(err.message || "Invalid or expired code.");
    } finally {
      setBusy(false);
    }
  };

  const sendCode = async (e) => {
    e.preventDefault();
    if (busy) return;
    if (!email.trim()) {
      setError("Enter your email to receive a code.");
      return;
    }
    setError("");
    setBusy(true);
    try {
      await requestOtp(email.trim());
      setOtpSent(true);
      pushToast("We sent a sign-in code to your email", "cyan");
    } catch (err) {
      setError(err.message || "Could not send a code. Try again.");
    } finally {
      setBusy(false);
    }
  };

  const verifyCode = async (e) => {
    e.preventDefault();
    if (busy) return;
    setError("");
    setBusy(true);
    try {
      const res = await signInWithOtp(email.trim(), code.trim());
      routeAfter(res);
    } catch (err) {
      if (err.data && err.data.error === "sso_required") {
        pushToast("Redirecting to your company's sign-in…", "cyan");
        window.location.href = enterpriseSsoUrl(email.trim());
        return;
      }
      setError(err.message || "Invalid or expired code.");
    } finally {
      setBusy(false);
    }
  };

  const switchMode = (m) => {
    setMode(m);
    setError("");
    setOtpSent(false);
    setCode("");
    setPassword("");
  };

  const oauth = (provider) => {
    window.location.href = oauthUrl(provider);
  };

  return (
    <div className="grid-bg relative flex min-h-screen items-center justify-center overflow-hidden bg-white px-6 py-12">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-0 h-[420px] w-[620px] rounded-full bg-slate-100 blur-[150px]" />
      </div>

      <div className="w-full max-w-md animate-fade-up">
        <Link to="/" className="mb-8 flex items-center justify-center gap-2.5">
          <LogoMark size={34} />
        </Link>

        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-8 shadow-2xl shadow-slate-300/40 backdrop-blur-sm">
          <h1 className="text-xl font-semibold text-slate-900">Welcome back</h1>
          <p className="mt-1 text-sm text-slate-500">
            Sign in to your AutoOps console.
          </p>

          {mode === "password" ? (
            <form onSubmit={submit} autoComplete="off" className="mt-6 space-y-4">
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Email
                </label>
                <input
                  type="email"
                  value={email}
                  autoFocus
                  required
                  autoComplete="off"
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@company.com"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
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
                    autoComplete="new-password"
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="••••••••"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 pr-10 text-sm text-slate-900 outline-none transition placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
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
                {busy ? "Signing in…" : "Sign in →"}
              </button>

              <div className="flex items-center justify-between text-xs font-medium">
                <button
                  type="button"
                  onClick={() => switchMode("otp")}
                  className="text-slate-900 transition hover:underline"
                >
                  Sign in with an email code
                </button>
                <button
                  type="button"
                  onClick={() => switchMode("reset")}
                  className="text-slate-900 transition hover:underline"
                >
                  Forgot password?
                </button>
              </div>
            </form>
          ) : mode === "reset" ? (
            <form
              onSubmit={otpSent ? completeReset : sendResetCode}
              autoComplete="off"
              className="mt-6 space-y-4"
            >
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Email
                </label>
                <input
                  type="email"
                  value={email}
                  autoFocus
                  required
                  disabled={otpSent}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@company.com"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300 disabled:opacity-60"
                />
              </div>

              {otpSent && (
                <>
                  <div>
                    <label className="mb-1.5 block text-xs font-medium text-slate-500">
                      Reset code
                    </label>
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
                    <p className="mt-1.5 text-xs text-slate-500">
                      Didn’t get it?{" "}
                      <button
                        type="button"
                        onClick={sendResetCode}
                        disabled={busy}
                        className="text-slate-900 hover:underline disabled:opacity-50"
                      >
                        Resend code
                      </button>
                    </p>
                  </div>
                  <div>
                    <label className="mb-1.5 block text-xs font-medium text-slate-500">
                      New password
                    </label>
                    <input
                      type="password"
                      value={password}
                      required
                      autoComplete="new-password"
                      onChange={(e) => setPassword(e.target.value)}
                      placeholder="At least 8 characters"
                      className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                    />
                  </div>
                </>
              )}

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
                {busy
                  ? otpSent
                    ? "Updating…"
                    : "Sending…"
                  : otpSent
                    ? "Set new password →"
                    : "Send reset code"}
              </button>

              <button
                type="button"
                onClick={() => switchMode("password")}
                className="w-full text-center text-xs font-medium text-slate-900 transition hover:underline"
              >
                Back to sign in
              </button>
            </form>
          ) : (
            <form
              onSubmit={otpSent ? verifyCode : sendCode}
              autoComplete="off"
              className="mt-6 space-y-4"
            >
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Email
                </label>
                <input
                  type="email"
                  value={email}
                  autoFocus
                  required
                  disabled={otpSent}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="you@company.com"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300 disabled:opacity-60"
                />
              </div>

              {otpSent && (
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    Sign-in code
                  </label>
                  <input
                    value={code}
                    autoFocus
                    inputMode="numeric"
                    onChange={(e) =>
                      setCode(e.target.value.replace(/\D/g, "").slice(0, 8))
                    }
                    placeholder="123456"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-center text-lg font-semibold tracking-[0.4em] text-slate-900 outline-none transition placeholder:tracking-normal placeholder:text-slate-600 focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                  <p className="mt-1.5 text-xs text-slate-500">
                    Didn’t get it?{" "}
                    <button
                      type="button"
                      onClick={sendCode}
                      disabled={busy}
                      className="text-slate-900 hover:underline disabled:opacity-50"
                    >
                      Resend code
                    </button>
                  </p>
                </div>
              )}

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
                {busy
                  ? otpSent
                    ? "Verifying…"
                    : "Sending…"
                  : otpSent
                    ? "Verify & sign in →"
                    : "Send code"}
              </button>

              <button
                type="button"
                onClick={() => switchMode("password")}
                className="w-full text-center text-xs font-medium text-slate-900 transition hover:underline"
              >
                Use password instead
              </button>
            </form>
          )}

          <div className="my-6 flex items-center gap-3 text-xs text-slate-600">
            <span className="h-px flex-1 bg-slate-50" /> or continue with{" "}
            <span className="h-px flex-1 bg-slate-50" />
          </div>

          <div className="grid gap-2.5 sm:grid-cols-2">
            <button
              onClick={() => oauth("google")}
              className="flex w-full items-center justify-center gap-2.5 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
            >
              <GoogleLogo size={18} /> Google
            </button>
            <button
              onClick={() => oauth("microsoft")}
              className="flex w-full items-center justify-center gap-2.5 rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-semibold text-slate-900 transition hover:border-blue-500 hover:bg-slate-100"
            >
              <MicrosoftLogo size={16} /> Microsoft
            </button>
          </div>
        </div>

        <p className="mt-6 text-center text-sm text-slate-500">
          Don’t have an account?{" "}
          <Link to="/signup" className="text-slate-900 hover:underline">
            Start free
          </Link>
        </p>
      </div>
    </div>
  );
}
