import { beforeEach, describe, expect, it, vi } from "vitest";

const ACCESS_KEY = "autoops_access_token";
const REFRESH_KEY = "autoops_refresh_token";

/**
 * Where the session lives, and why it is not localStorage.
 *
 * The bug this pins: two tabs signed into two accounts both showed the same
 * account after a refresh. localStorage is ONE bucket per origin, so the second
 * sign-in overwrote the first and both tabs then read the same JWT — and the
 * role travels inside that JWT, so the whole console followed it. It looked
 * like broken RBAC; the backend was never involved.
 *
 * A separate tab cannot be simulated in jsdom (one window, one sessionStorage),
 * so what is checked here is the property that makes tabs independent: the
 * session is written to sessionStorage, which browsers scope per tab, and never
 * to localStorage, which they do not.
 */
describe("token storage", () => {
  let tokenStore;

  beforeEach(async () => {
    localStorage.clear();
    sessionStorage.clear();
    // Fresh module each time: the legacy-token adoption runs at import, so a
    // cached module would only ever exercise it once. A query-string cache-bust
    // is not an option here - Vite rejects a non-literal import specifier.
    vi.resetModules();
    tokenStore = (await import("./api")).tokenStore;
  });

  it("keeps the session out of the bucket every tab shares", () => {
    tokenStore.set("access-1", "refresh-1");

    expect(sessionStorage.getItem(ACCESS_KEY)).toBe("access-1");
    expect(sessionStorage.getItem(REFRESH_KEY)).toBe("refresh-1");
    // The whole fix in one assertion: anything here is visible to every other
    // tab on the origin, so a second account would overwrite this one.
    expect(localStorage.getItem(ACCESS_KEY)).toBeNull();
    expect(localStorage.getItem(REFRESH_KEY)).toBeNull();
  });

  it("reads back what it wrote", () => {
    tokenStore.set("access-2", "refresh-2");
    expect(tokenStore.access).toBe("access-2");
    expect(tokenStore.refresh).toBe("refresh-2");
  });

  it("ignores a token another tab left in shared storage", () => {
    // Written directly, as the pre-fix build did. This tab has its own session
    // and must not adopt someone else's mid-flight.
    tokenStore.set("mine", "mine-refresh");
    localStorage.setItem(ACCESS_KEY, "someone-elses");

    expect(tokenStore.access).toBe("mine");
  });

  it("clears both stores on sign-out", () => {
    tokenStore.set("access-3", "refresh-3");
    localStorage.setItem(REFRESH_KEY, "stale-but-still-valid");

    tokenStore.clear();

    expect(tokenStore.access).toBeNull();
    expect(tokenStore.refresh).toBeNull();
    // A refresh token left behind by the old build still works, so signing out
    // without removing it would let the account come back.
    expect(localStorage.getItem(REFRESH_KEY)).toBeNull();
  });
});

describe("upgrading from the shared-storage build", () => {
  beforeEach(() => {
    localStorage.clear();
    sessionStorage.clear();
  });

  it("adopts a pre-upgrade session into this tab and removes the shared copy", async () => {
    localStorage.setItem(ACCESS_KEY, "legacy-access");
    localStorage.setItem(REFRESH_KEY, "legacy-refresh");

    vi.resetModules();
    const { tokenStore } = await import("./api");

    // Signed in before the upgrade, still signed in after — not bounced to login.
    expect(tokenStore.access).toBe("legacy-access");
    // And removed, or the next tab to open would adopt the same pair and the
    // two accounts would bleed together again.
    expect(localStorage.getItem(ACCESS_KEY)).toBeNull();
    expect(localStorage.getItem(REFRESH_KEY)).toBeNull();
  });

  it("does not let a legacy token displace a session this tab already has", async () => {
    sessionStorage.setItem(ACCESS_KEY, "current-tab");
    localStorage.setItem(ACCESS_KEY, "legacy-access");

    vi.resetModules();
    const { tokenStore } = await import("./api");

    expect(tokenStore.access).toBe("current-tab");
    expect(localStorage.getItem(ACCESS_KEY)).toBeNull();
  });
});
