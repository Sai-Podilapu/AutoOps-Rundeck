import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import Signup from "./Signup";

// Registration is deliberately two-step: the backend emails a code and issues
// no tokens until it is confirmed. The page must never imply an account exists
// before that, and must survive the plan-subscribe call failing — the workspace
// is already real at that point.
const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual("react-router-dom");
  return { ...actual, useNavigate: () => navigate, useLocation: () => location };
});

let location = { state: null };

const store = {
  signUp: vi.fn(),
  verifySignup: vi.fn(),
  resendSignupCode: vi.fn(),
  refreshWorkspace: vi.fn(),
  pushToast: vi.fn(),
};
vi.mock("../store/store", () => ({ useStore: () => store }));

const api = { subscribePlan: vi.fn() };
vi.mock("../lib/api", () => ({
  api: { subscribePlan: (...args) => api.subscribePlan(...args) },
  oauthUrl: () => "/oauth/google",
}));

const renderSignup = () =>
  render(
    <MemoryRouter>
      <Signup />
    </MemoryRouter>,
  );

const fillForm = async (password = "long-enough-password") => {
  const user = userEvent.setup();
  await user.type(screen.getByPlaceholderText("Your Name"), "Ada Lovelace");
  await user.type(screen.getByPlaceholderText("you@company.com"), "ada@acme.io");
  await user.type(screen.getByPlaceholderText("At least 8 characters"), password);
  return user;
};

beforeEach(() => {
  vi.clearAllMocks();
  location = { state: null };
  api.subscribePlan.mockResolvedValue({});
  // The page calls .catch() on this directly — a bare vi.fn() returning
  // undefined would fail on the mock, not on the code under test.
  store.resendSignupCode.mockResolvedValue({});
});

describe("registration", () => {
  it("registers and moves to the verification step", async () => {
    store.signUp.mockResolvedValue({});
    renderSignup();
    const user = await fillForm();

    await user.click(screen.getByRole("button", { name: /^create workspace$/i }));

    await waitFor(() =>
      expect(store.signUp).toHaveBeenCalledWith({
        name: "Ada Lovelace",
        email: "ada@acme.io",
        password: "long-enough-password",
      }),
    );
    expect(await screen.findByPlaceholderText("123456")).toBeInTheDocument();
  });

  it("includes the workspace name only when one was typed", async () => {
    store.signUp.mockResolvedValue({});
    renderSignup();
    const user = await fillForm();
    await user.type(screen.getByPlaceholderText("Company Name"), "  Acme Corp  ");

    await user.click(screen.getByRole("button", { name: /^create workspace$/i }));

    await waitFor(() =>
      expect(store.signUp).toHaveBeenCalledWith(
        expect.objectContaining({ workspaceName: "Acme Corp" }),
      ),
    );
  });

  it("rejects a short password before calling the backend", async () => {
    renderSignup();
    const user = await fillForm("short");

    await user.click(screen.getByRole("button", { name: /^create workspace$/i }));

    expect(await screen.findByText(/at least 8 characters/i)).toBeInTheDocument();
    expect(store.signUp).not.toHaveBeenCalled();
  });

  it("stays on the form and shows the reason when registration fails", async () => {
    store.signUp.mockRejectedValue(new Error("Email already registered"));
    renderSignup();
    const user = await fillForm();

    await user.click(screen.getByRole("button", { name: /^create workspace$/i }));

    expect(await screen.findByText("Email already registered")).toBeInTheDocument();
    expect(screen.queryByPlaceholderText("123456")).not.toBeInTheDocument();
  });
});

describe("verification", () => {
  const reachVerifyStep = async () => {
    store.signUp.mockResolvedValue({});
    renderSignup();
    const user = await fillForm();
    await user.click(screen.getByRole("button", { name: /^create workspace$/i }));
    await screen.findByPlaceholderText("123456");
    return user;
  };

  it("confirms the code, starts the trial and moves on to onboarding", async () => {
    store.verifySignup.mockResolvedValue({ context: "client" });
    const user = await reachVerifyStep();

    await user.type(screen.getByPlaceholderText("123456"), "123456");
    await user.click(screen.getByRole("button", { name: /verify & continue/i }));

    await waitFor(() => expect(store.verifySignup).toHaveBeenCalledWith("ada@acme.io", "123456"));
    expect(api.subscribePlan).toHaveBeenCalled();
    expect(navigate).toHaveBeenCalledWith("/onboarding");
  });

  /** The workspace exists by now; a failed subscribe must not strand the user. */
  it("still completes sign-up when starting the plan trial fails", async () => {
    store.verifySignup.mockResolvedValue({ context: "client" });
    api.subscribePlan.mockRejectedValue(new Error("billing down"));
    const user = await reachVerifyStep();

    await user.type(screen.getByPlaceholderText("123456"), "123456");
    await user.click(screen.getByRole("button", { name: /verify & continue/i }));

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/onboarding"));
  });

  it("reports a wrong code without leaving the step", async () => {
    store.verifySignup.mockRejectedValue(new Error("Invalid or expired code"));
    const user = await reachVerifyStep();

    await user.type(screen.getByPlaceholderText("123456"), "000000");
    await user.click(screen.getByRole("button", { name: /verify & continue/i }));

    expect(await screen.findByText("Invalid or expired code")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("can request a fresh code", async () => {
    const user = await reachVerifyStep();

    await user.click(screen.getByRole("button", { name: /^resend code$/i }));

    await waitFor(() => expect(store.resendSignupCode).toHaveBeenCalledWith("ada@acme.io"));
  });
});

describe("arriving from an unverified sign-in", () => {
  it("opens straight on the verification step and re-sends the code", async () => {
    location = { state: { verify: "pending@acme.io" } };

    renderSignup();

    expect(await screen.findByPlaceholderText("123456")).toBeInTheDocument();
    await waitFor(() => expect(store.resendSignupCode).toHaveBeenCalledWith("pending@acme.io"));
  });
});
