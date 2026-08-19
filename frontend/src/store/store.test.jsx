import { act, render, renderHook, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ROLE_CAPS, ROLE_LABELS } from "./store";

// The store owns the session and the client-side RBAC matrix. The services
// enforce authorization for real; this decides what a user is even shown, so a
// wrong answer here is a confusing UI at best and a leaked control at worst.
vi.mock("../lib/api", () => ({
  api: {
    login: vi.fn(),
    logout: vi.fn(),
    me: vi.fn(),
    listProjects: vi.fn(),
    getWorkspace: vi.fn(),
    selectTenant: vi.fn(),
    list: vi.fn(),
  },
  tokenStore: {
    access: null,
    refresh: null,
    set: vi.fn(),
    clear: vi.fn(),
  },
}));

let StoreProvider;
let useStore;
let api;
let tokenStore;

const wrapper = ({ children }) => <StoreProvider>{children}</StoreProvider>;

const CLIENT_SESSION = {
  accessToken: "a",
  refreshToken: "r",
  context: "client",
  activeRole: "ADMIN",
  user: { id: 1, name: "Ada", email: "ada@acme.io", isProvider: false },
  workspace: { name: "Acme", plan: "Free" },
};

beforeEach(async () => {
  vi.resetModules();
  localStorage.clear();
  ({ StoreProvider, useStore } = await import("./store"));
  ({ api, tokenStore } = await import("../lib/api"));
  api.listProjects.mockResolvedValue([]);
  api.getWorkspace.mockResolvedValue({ workspace: { name: "Acme", plan: "Team" } });
  api.logout.mockResolvedValue({});
  tokenStore.access = null;
});

describe("role capability matrix", () => {
  /**
   * An admin owns everything about their own workspace — members, billing,
   * governance, jobs, runs — with exactly one exception.
   */
  it("gives an admin every workspace capability", () => {
    const { authorAutomation, ...rest } = ROLE_CAPS.admin;
    expect(Object.values(rest).every(Boolean)).toBe(true);
    expect(authorAutomation).toBe(false);
  });

  /**
   * The exception, asserted on its own because it is the product rule, not a
   * permissions tier: workflows and agents are designed by the PROVIDER and
   * rolled out to customers. No client role authors them — not even admin —
   * and the backend refuses the same thing, so a `true` here would only buy
   * the customer a 403.
   */
  it("lets no client role author workflows or agents", () => {
    for (const [role, caps] of Object.entries(ROLE_CAPS)) {
      expect(caps.authorAutomation, `${role} must not author automations`).toBe(false);
    }
  });

  it("gives a viewer none", () => {
    expect(Object.values(ROLE_CAPS.viewer).some(Boolean)).toBe(false);
  });

  /**
   * Segregation of duties: an operator triggers work but cannot sign off on
   * it. core-service enforces this too — the compliance report treats
   * requester-equals-approver as a control failure.
   */
  it("lets an operator run but never approve", () => {
    expect(ROLE_CAPS.operator.runWorkflow).toBe(true);
    expect(ROLE_CAPS.operator.deploy).toBe(true);
    expect(ROLE_CAPS.operator.approve).toBe(false);
  });

  it("keeps billing, members, keys and governance admin-only", () => {
    for (const capability of ["manageBilling", "manageMembers", "manageKeys", "manageGovernance"]) {
      expect(ROLE_CAPS.admin[capability]).toBe(true);
      expect(ROLE_CAPS.operator[capability]).toBe(false);
      expect(ROLE_CAPS.viewer[capability]).toBe(false);
    }
  });

  it("defines the same capability keys for every role", () => {
    const admin = Object.keys(ROLE_CAPS.admin).sort();
    expect(Object.keys(ROLE_CAPS.operator).sort()).toEqual(admin);
    expect(Object.keys(ROLE_CAPS.viewer).sort()).toEqual(admin);
  });

  it("labels every role", () => {
    expect(Object.keys(ROLE_LABELS).sort()).toEqual(Object.keys(ROLE_CAPS).sort());
  });
});

describe("sign in", () => {
  it("establishes a client session and loads projects", async () => {
    api.login.mockResolvedValue(CLIENT_SESSION);
    const { result } = renderHook(() => useStore(), { wrapper });

    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    expect(tokenStore.set).toHaveBeenCalledWith("a", "r");
    expect(result.current.session.authed).toBe(true);
    expect(result.current.session.role).toBe("client");
    expect(result.current.user.email).toBe("ada@acme.io");
    await waitFor(() => expect(api.listProjects).toHaveBeenCalled());
  });

  it("routes a provider account to the provider context", async () => {
    api.login.mockResolvedValue({
      accessToken: "a",
      refreshToken: "r",
      context: "provider",
      user: { id: 2, name: "Ops", email: "ops@intertec.io", isProvider: true },
    });
    const { result } = renderHook(() => useStore(), { wrapper });

    let outcome;
    await act(async () => {
      outcome = await result.current.signIn("ops@intertec.io", "pw");
    });

    expect(outcome).toEqual({ context: "provider" });
    expect(result.current.session.role).toBe("provider");
    // A provider has no tenant workspace to load.
    expect(api.listProjects).not.toHaveBeenCalled();
  });

  it("merges the live plan into the workspace after sign in", async () => {
    api.login.mockResolvedValue(CLIENT_SESSION);
    const { result } = renderHook(() => useStore(), { wrapper });

    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await waitFor(() => expect(result.current.workspace.plan).toBe("Team"));
  });

  it("applies the account's role to its capabilities", async () => {
    api.login.mockResolvedValue({ ...CLIENT_SESSION, activeRole: "VIEWER" });
    const { result } = renderHook(() => useStore(), { wrapper });

    await act(async () => {
      await result.current.signIn("v@acme.io", "pw");
    });

    expect(result.current.can("runWorkflow")).toBe(false);
    expect(result.current.can("manageBilling")).toBe(false);
  });
});

describe("sign out", () => {
  it("clears tokens and every trace of the session", async () => {
    api.login.mockResolvedValue(CLIENT_SESSION);
    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await act(async () => {
      result.current.logout();
    });

    expect(tokenStore.clear).toHaveBeenCalled();
    expect(result.current.session.authed).toBe(false);
    expect(result.current.user).toBeNull();
    expect(result.current.workspace).toBeNull();
    expect(result.current.projects).toEqual([]);
  });

  it("still clears locally when the server logout call fails", async () => {
    api.login.mockResolvedValue(CLIENT_SESSION);
    api.logout.mockRejectedValue(new Error("network down"));
    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await act(async () => {
      result.current.logout();
    });

    // A user who clicks "sign out" must end up signed out regardless.
    expect(result.current.session.authed).toBe(false);
    expect(tokenStore.clear).toHaveBeenCalled();
  });

  it("resets the role so the next sign-in cannot inherit it", async () => {
    api.login.mockResolvedValue({ ...CLIENT_SESSION, activeRole: "VIEWER" });
    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("v@acme.io", "pw");
    });

    await act(async () => {
      result.current.logout();
    });

    expect(result.current.clientRole).toBe("admin");
  });
});

describe("account-scoped state", () => {
  /**
   * Workflow drafts and the org identity are persisted in localStorage, which
   * every tab and every account on the machine shares. They are keyed PER
   * ACCOUNT so two signed-in accounts cannot overwrite each other — the old
   * design was one shared bucket plus an owner check that wiped it on a
   * mismatch, and with two live sessions that check ping-ponged and destroyed
   * both accounts' prefs on every refresh.
   */
  it("does not hand one account the previous account's org identity", async () => {
    localStorage.setItem(
      "autoops_prefs_v1:someone-else@acme.io",
      JSON.stringify({ org: { name: "Someone Else Ltd", domain: "else.io" } }),
    );
    api.login.mockResolvedValue(CLIENT_SESSION);

    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await waitFor(() => expect(result.current.org.name).toBe("Your workspace"));
  });

  it("leaves the other account's prefs intact rather than wiping them", async () => {
    // The regression: signing in as ada used to reset the shared bucket, so the
    // other account lost its org name and drafts the moment ada refreshed.
    const otherKey = "autoops_prefs_v1:someone-else@acme.io";
    localStorage.setItem(
      otherKey,
      JSON.stringify({ org: { name: "Someone Else Ltd", domain: "else.io" } }),
    );
    api.login.mockResolvedValue(CLIENT_SESSION);

    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });
    await act(async () => {
      result.current.setOrg({ name: "Acme Ltd" });
    });

    await waitFor(() =>
      expect(JSON.parse(localStorage.getItem("autoops_prefs_v1:ada@acme.io")).org.name)
        .toBe("Acme Ltd"),
    );
    expect(JSON.parse(localStorage.getItem(otherKey)).org.name).toBe("Someone Else Ltd");
  });

  it("keeps the org identity when the same user signs back in", async () => {
    localStorage.setItem(
      "autoops_prefs_v1:ada@acme.io",
      JSON.stringify({ org: { name: "Acme Ltd", domain: "acme.io" } }),
    );
    api.login.mockResolvedValue(CLIENT_SESSION);

    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await waitFor(() => expect(result.current.org.name).toBe("Acme Ltd"));
  });

  it("adopts the pre-namespacing bucket, but only for its recorded owner", async () => {
    // Upgrade path: one shared bucket plus the owner key that said whose it was.
    localStorage.setItem("autoops_prefs_owner", "ada@acme.io");
    localStorage.setItem(
      "autoops_prefs_v1",
      JSON.stringify({ org: { name: "Legacy Ltd", domain: "legacy.io" } }),
    );
    api.login.mockResolvedValue(CLIENT_SESSION);

    const { result } = renderHook(() => useStore(), { wrapper });
    await act(async () => {
      await result.current.signIn("ada@acme.io", "pw");
    });

    await waitFor(() => expect(result.current.org.name).toBe("Legacy Ltd"));
    // Moved, not copied — a bucket left behind would be adopted again by
    // whoever the owner key named next.
    expect(localStorage.getItem("autoops_prefs_v1")).toBeNull();
    expect(localStorage.getItem("autoops_prefs_owner")).toBeNull();
  });

  it("survives corrupt persisted preferences", async () => {
    localStorage.setItem("autoops_prefs_v1", "{not json");

    const { result } = renderHook(() => useStore(), { wrapper });

    expect(result.current.session.authed).toBe(false);
    expect(result.current.org).toEqual({ name: "Your workspace", domain: "" });
  });
});

describe("toasts", () => {
  it("renders a pushed toast", async () => {
    function Probe() {
      const { pushToast } = useStore();
      return <button onClick={() => pushToast("Saved")}>fire</button>;
    }
    render(
      <StoreProvider>
        <Probe />
      </StoreProvider>,
    );

    await act(async () => {
      screen.getByText("fire").click();
    });

    expect(screen.getByText("Saved")).toBeInTheDocument();
  });
});

describe("useStore guard", () => {
  it("fails loudly outside the provider", () => {
    // Rendering a consumer without the provider is a wiring bug; it must throw
    // rather than hand back undefined and crash three components later.
    // React logs the boundary-less error itself — muted so the run stays readable.
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});

    expect(() => renderHook(() => useStore())).toThrow(/within StoreProvider/);

    consoleError.mockRestore();
  });
});
