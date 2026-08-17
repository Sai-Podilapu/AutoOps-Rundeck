import { afterEach, describe, expect, it, vi } from "vitest";
import { fmtDate, fmtDuration, badgeStatus } from "./format";
import { toCsv } from "./csv";
import { planAllows, requiredPlan, PLAN_RANK, FEATURE_MIN } from "./entitlements";
import { base } from "./base";

describe("fmtDuration", () => {
  it.each([
    [0, "0ms"],
    [999, "999ms"],
    [1000, "1.0s"],
    [59_400, "59.4s"],
    [60_000, "1m 0s"],
    [3_723_000, "62m 3s"],
  ])("formats %ims as %s", (ms, expected) => {
    expect(fmtDuration(ms)).toBe(expected);
  });

  it.each([null, undefined, "", "abc", NaN])("renders %s as an em dash", (value) => {
    expect(fmtDuration(value)).toBe("—");
  });

  it("accepts a numeric string, because JSON sometimes sends one", () => {
    expect(fmtDuration("1500")).toBe("1.5s");
  });
});

describe("fmtDate", () => {
  it("formats a valid ISO timestamp", () => {
    expect(fmtDate("2026-07-28T10:30:00Z")).toMatch(/Jul/);
  });

  it.each([null, undefined, "", "not-a-date"])("renders %s as an em dash", (value) => {
    expect(fmtDate(value)).toBe("—");
  });
});

describe("badgeStatus", () => {
  it("lowercases backend enums", () => {
    expect(badgeStatus("SUCCEEDED")).toBe("succeeded");
  });

  it("never returns null — the badge does a string lookup", () => {
    expect(badgeStatus(null)).toBe("");
    expect(badgeStatus(undefined)).toBe("");
  });
});

describe("toCsv", () => {
  const columns = [
    { label: "Name", value: "name" },
    { label: "Status", value: (row) => row.status.toUpperCase() },
  ];

  it("writes a header and one line per row", () => {
    const csv = toCsv([{ name: "Deploy", status: "ok" }], columns);

    expect(csv).toBe("Name,Status\nDeploy,OK");
  });

  it("quotes values containing a comma, quote or newline", () => {
    const csv = toCsv(
      [{ name: 'Deploy, "prod"', status: "ok" }, { name: "Two\nlines", status: "ok" }],
      columns,
    );

    // Embedded quotes double, per RFC 4180 — otherwise Excel eats the row.
    expect(csv).toContain('"Deploy, ""prod"""');
    expect(csv).toContain('"Two\nlines"');
  });

  it("renders null and undefined as empty cells, not the word 'null'", () => {
    const csv = toCsv([{ name: null, status: "ok" }], [{ label: "Name", value: "name" }]);

    expect(csv).toBe("Name\n");
  });

  it("handles an empty or missing row set", () => {
    expect(toCsv([], columns)).toBe("Name,Status\n");
    expect(toCsv(null, columns)).toBe("Name,Status\n");
  });
});

describe("plan entitlements", () => {
  it("allows a feature at its minimum plan and above", () => {
    expect(planAllows("Business", "compliance")).toBe(true);
    expect(planAllows("Enterprise", "compliance")).toBe(true);
  });

  it("blocks a feature below its minimum plan", () => {
    expect(planAllows("Team", "compliance")).toBe(false);
    expect(planAllows("Starter", "plugins")).toBe(false);
  });

  it("treats an unknown or absent plan as no access", () => {
    expect(planAllows(undefined, "plugins")).toBe(false);
    expect(planAllows("Free", "plugins")).toBe(false);
  });

  it("lets an ungated feature through on every plan", () => {
    expect(planAllows("Starter", "somethingUngated")).toBe(true);
    expect(requiredPlan("somethingUngated")).toBe("Starter");
  });

  it("names a real plan for every gated feature", () => {
    for (const [feature, plan] of Object.entries(FEATURE_MIN)) {
      expect(PLAN_RANK[plan], `${feature} requires unknown plan ${plan}`).toBeGreaterThan(0);
    }
  });

  /**
   * The UI gate is a convenience; the services decide. This pins the two
   * catalogues together so a plan rename cannot quietly open a feature.
   */
  it("keeps the UI ranking consistent with the seeded plan tiers", () => {
    expect(PLAN_RANK).toEqual({ Starter: 1, Team: 2, Business: 3, Enterprise: 4 });
  });
});

describe("route base", () => {
  const setPath = (pathname) => {
    delete window.location;
    window.location = { pathname };
  };
  const original = window.location;
  afterEach(() => {
    window.location = original;
  });

  it("extracts the project scope from the URL", () => {
    setPath("/app/projects/42/jobs");
    expect(base()).toBe("/app/projects/42");
  });

  it("falls back to the projects list outside a project", () => {
    setPath("/app/settings");
    expect(base()).toBe("/app/projects");
  });
});
