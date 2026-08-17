import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import Login from "./Login";

// The sign-in page has more branching than any other screen: password, email
// code, password reset, plus three server-driven detours (unverified email,
// enforced SSO, provider account). Each detour is a different destination.
const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual("react-router-dom");
  return { ...actual, useNavigate: () => navigate };
});

const store = {
  signIn: vi.fn(),
  requestOtp: vi.fn(),
  signInWithOtp: vi.fn(),
  forgotPassword: vi.fn(),
  resetPassword: vi.fn(),
  pushToast: vi.fn(),
};
vi.mock("../store/store", () => ({ useStore: () => store }));

const renderLogin = () =>
  render(
    <MemoryRouter>
      <Login />
    </MemoryRouter>,
  );

// "Sign in →" and "Sign in with an email code" both start with "Sign in", so
// the submit button needs the arrow to be addressed unambiguously.
const submitButton = () => screen.getByRole("button", { name: /sign in →/i });

const signInAs = async (email = "ada@acme.io", password = "correct-horse") => {
  const user = userEvent.setup();
  await user.type(screen.getByPlaceholderText("you@company.com"), email);
  await user.type(screen.getByPlaceholderText("••••••••"), password);
  await user.click(submitButton());
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe("password sign-in", () => {
  it("submits trimmed credentials and lands in the app", async () => {
    store.signIn.mockResolvedValue({ context: "client" });
    renderLogin();

    await signInAs("  ada@acme.io  ");

    await waitFor(() => expect(store.signIn).toHaveBeenCalledWith("ada@acme.io", "correct-horse"));
    expect(navigate).toHaveBeenCalledWith("/app");
  });

  it("sends a provider account to the provider console", async () => {
    store.signIn.mockResolvedValue({ context: "provider" });
    renderLogin();

    await signInAs("ops@intertec.io");

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/provider"));
  });

  it("sends an account with no workspace to onboarding", async () => {
    store.signIn.mockResolvedValue({ context: "no-workspace" });
    renderLogin();

    await signInAs();

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/onboarding"));
  });

  it("shows the server's message when credentials are rejected", async () => {
    store.signIn.mockRejectedValue(
      Object.assign(new Error("login_failed"), { data: { error: "login_failed" } }),
    );
    renderLogin();

    await signInAs();

    expect(await screen.findByText("login_failed")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });

  /** Correct password but an unverified email: continue the sign-up, don't scold. */
  it("routes an unverified account to the verification step", async () => {
    store.signIn.mockRejectedValue(
      Object.assign(new Error("verify"), { data: { error: "email_unverified" } }),
    );
    renderLogin();

    await signInAs("new@acme.io");

    await waitFor(() =>
      expect(navigate).toHaveBeenCalledWith("/signup", { state: { verify: "new@acme.io" } }),
    );
    // No error banner — this is a redirect, not a failure.
    expect(screen.queryByText(/unable to sign in/i)).not.toBeInTheDocument();
  });

  it("falls back to a friendly message when the error has none", async () => {
    store.signIn.mockRejectedValue(Object.assign(new Error(""), { data: null }));
    renderLogin();

    await signInAs();

    expect(await screen.findByText(/unable to sign in/i)).toBeInTheDocument();
  });

  it("re-enables the button after a failure so the user can retry", async () => {
    store.signIn.mockRejectedValue(Object.assign(new Error("nope"), { data: null }));
    renderLogin();

    await signInAs();

    await waitFor(() =>
      expect(submitButton()).not.toBeDisabled(),
    );
  });

  it("ignores a second submit while the first is in flight", async () => {
    let release;
    store.signIn.mockReturnValue(new Promise((resolve) => (release = resolve)));
    renderLogin();
    const user = userEvent.setup();

    await user.type(screen.getByPlaceholderText("you@company.com"), "ada@acme.io");
    await user.type(screen.getByPlaceholderText("••••••••"), "pw");
    await user.click(submitButton());
    await user.click(screen.getByRole("button", { name: /signing in/i }));

    expect(store.signIn).toHaveBeenCalledTimes(1);
    release({ context: "client" });
  });
});

describe("password visibility", () => {
  it("toggles between hidden and visible", async () => {
    renderLogin();
    const user = userEvent.setup();
    const field = screen.getByPlaceholderText("••••••••");

    expect(field).toHaveAttribute("type", "password");
    await user.click(screen.getByRole("button", { name: /show password/i }));
    expect(field).toHaveAttribute("type", "text");
    await user.click(screen.getByRole("button", { name: /hide password/i }));
    expect(field).toHaveAttribute("type", "password");
  });
});

describe("email-code sign-in", () => {
  it("requests a code, then exchanges it for a session", async () => {
    store.requestOtp.mockResolvedValue({});
    store.signInWithOtp.mockResolvedValue({ context: "client" });
    renderLogin();
    const user = userEvent.setup();

    await user.click(screen.getByRole("button", { name: /sign in with an email code/i }));
    await user.type(screen.getByPlaceholderText("you@company.com"), "ada@acme.io");
    await user.click(screen.getByRole("button", { name: /send.*code/i }));

    await waitFor(() => expect(store.requestOtp).toHaveBeenCalledWith("ada@acme.io"));
  });

  it("shows the backend error and stays on the email step for an unregistered address", async () => {
    // The backend 404s (user_not_found) instead of pretending a code was sent,
    // so the visitor is told to sign up rather than waiting for nothing.
    store.requestOtp.mockRejectedValue(
      Object.assign(new Error("No account found for this email"), { status: 404 }),
    );
    renderLogin();
    const user = userEvent.setup();

    await user.click(screen.getByRole("button", { name: /sign in with an email code/i }));
    await user.type(screen.getByPlaceholderText("you@company.com"), "ghost@acme.io");
    await user.click(screen.getByRole("button", { name: /send.*code/i }));

    await waitFor(() =>
      expect(screen.getByText("No account found for this email")).toBeInTheDocument(),
    );
    // Still on the email step — no code field appeared.
    expect(store.signInWithOtp).not.toHaveBeenCalled();
  });
});

describe("form contract", () => {
  it("marks email and password as required so the browser blocks empty submits", () => {
    renderLogin();

    expect(screen.getByPlaceholderText("you@company.com")).toBeRequired();
    expect(screen.getByPlaceholderText("••••••••")).toBeRequired();
  });

  it("uses a real email input so mobile keyboards and validation behave", () => {
    renderLogin();

    expect(screen.getByPlaceholderText("you@company.com")).toHaveAttribute("type", "email");
  });
});
