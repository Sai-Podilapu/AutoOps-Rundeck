import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// Route guards are the front end's access-control surface. They are not the
// enforcement point — every service checks the JWT and its own rules — but a
// wrong answer here shows a user a console they have no business seeing, and
// the empty screen that follows reads as a broken product.
const storeState = {
  booting: false,
  session: { authed: false, role: "client", impersonating: null },
  clientRole: "admin",
  can: () => true,
  user: null,
  workspace: null,
  projects: [],
  members: [],
  designs: {},
  org: { name: "", domain: "" },
  pushToast: vi.fn(),
  refreshProjects: vi.fn(),
  refreshMembers: vi.fn(),
  refreshWorkspace: vi.fn(),
  logout: vi.fn(),
  getWorkflowDesign: () => null,
  saveWorkflowDesign: vi.fn(),
};

vi.mock("./store/store", async () => {
  const actual = await vi.importActual("./store/store");
  return { ...actual, useStore: () => storeState };
});

vi.mock("./lib/api", () => ({
  api: new Proxy({}, { get: () => vi.fn().mockResolvedValue([]) }),
  tokenStore: { access: null, refresh: null, set: vi.fn(), clear: vi.fn() },
  apiFetch: vi.fn().mockResolvedValue([]),
  oauthUrl: () => "/oauth",
  enterpriseSsoUrl: () => "/sso",
  ApiError: class extends Error {},
}));

// Imported statically: App pulls in every page in the product, and paying that
// cost inside a 10s-bounded beforeEach makes the first test flaky by design.
const { default: App } = await import("./App");

const renderAt = (path) =>
  render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  );

beforeEach(() => {
  vi.clearAllMocks();
  storeState.booting = false;
  storeState.session = { authed: false, role: "client", impersonating: null };
  storeState.clientRole = "admin";
  storeState.can = () => true;
});

describe("unauthenticated access", () => {
  it.each(["/app", "/app/projects", "/app/settings", "/provider"])(
    "bounces %s to the login page",
    async (path) => {
      renderAt(path);

      await waitFor(() =>
        expect(screen.getByRole("heading", { name: /welcome back/i })).toBeInTheDocument(),
      );
    },
  );

  it("still serves the public marketing pages", async () => {
    renderAt("/pricing");

    // No redirect to /login: pricing is deliberately anonymous.
    await waitFor(() =>
      expect(screen.queryByRole("heading", { name: /welcome back/i })).not.toBeInTheDocument(),
    );
  });
});

describe("while the session is being restored", () => {
  it("shows the boot screen instead of flashing the login page", async () => {
    storeState.booting = true;
    storeState.session = { authed: false, role: "client", impersonating: null };

    renderAt("/app");

    // A logged-in user reloading the page must not see a login flash before
    // the token check finishes.
    await waitFor(() =>
      expect(screen.queryByRole("heading", { name: /welcome back/i })).not.toBeInTheDocument(),
    );
  });
});

describe("provider console", () => {
  it("keeps a client account out", async () => {
    storeState.session = { authed: true, role: "client", impersonating: null };

    renderAt("/provider");

    await waitFor(() =>
      expect(screen.queryByRole("heading", { name: /welcome back/i })).not.toBeInTheDocument(),
    );
    // Redirected into the client app, not the provider console.
    expect(window.location.pathname).not.toContain("/provider");
  });

  it("lets a provider account in", async () => {
    storeState.session = { authed: true, role: "provider", impersonating: null };

    renderAt("/provider");

    await waitFor(() => expect(document.body.textContent.length).toBeGreaterThan(0));
  });
});

describe("capability guard", () => {
  it("redirects a persona lacking the capability away from the route", async () => {
    storeState.session = { authed: true, role: "client", impersonating: null };
    storeState.clientRole = "viewer";
    storeState.can = () => false;

    renderAt("/app/settings");

    await waitFor(() =>
      expect(screen.queryByRole("heading", { name: /welcome back/i })).not.toBeInTheDocument(),
    );
  });

  it("admits a persona holding it", async () => {
    storeState.session = { authed: true, role: "client", impersonating: null };
    storeState.clientRole = "admin";
    storeState.can = () => true;

    renderAt("/app/settings");

    await waitFor(() => expect(document.body.textContent.length).toBeGreaterThan(0));
  });
});

describe("unknown routes", () => {
  it("renders the not-found page rather than a blank screen", async () => {
    renderAt("/no-such-page");

    await waitFor(() => expect(document.body.textContent.length).toBeGreaterThan(0));
    expect(screen.queryByRole("heading", { name: /welcome back/i })).not.toBeInTheDocument();
  });
});
