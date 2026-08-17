import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// A bare "—" on the compliance card reads as a broken calculation. It is not:
// the score averages the newest report per active project, so with no reports
// there is nothing to average. The card has to say that.

const storeState = {
  workspace: { plan: "Enterprise" },
  can: () => true,
  pushToast: vi.fn(),
};

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

vi.mock("../../lib/entitlements", () => ({
  planAllows: () => true,
  requiredPlan: () => "Enterprise",
}));

const apiMock = { getGovernanceSummary: vi.fn(), setGovernancePolicy: vi.fn() };
vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: Governance } = await import("./Governance");

// Must carry every collection the render maps over — `automations` included,
// or the page throws the moment this lands and the container comes back empty.
const summary = (complianceScore) => ({
  complianceScore,
  policiesEnforced: 2,
  openViolations: 0,
  quotaUsage: 40,
  automations: [],
  policies: [],
});

const renderPage = () =>
  render(
    <MemoryRouter initialEntries={["/app/projects/7/governance"]}>
      <Routes>
        <Route path="/app/projects/:pid/governance" element={<Governance />} />
      </Routes>
    </MemoryRouter>,
  );

beforeEach(() => {
  apiMock.getGovernanceSummary.mockResolvedValue(summary(null));
});

describe("compliance score card", () => {
  it("explains an absent score instead of showing a bare dash", async () => {
    renderPage();
    expect(await screen.findByText(/No compliance reports yet/)).toBeInTheDocument();
  });

  it("points at the page that creates the missing data", async () => {
    renderPage();
    const link = await screen.findByRole("link", { name: "Generate one" });
    expect(link).toHaveAttribute("href", "/app/projects/7/compliance");
  });

  it("shows the percentage and drops the hint once a score exists", async () => {
    apiMock.getGovernanceSummary.mockResolvedValue(summary(90));
    renderPage();

    expect(await screen.findByText("90%")).toBeInTheDocument();
    expect(screen.queryByText(/No compliance reports yet/)).not.toBeInTheDocument();
  });

  it("treats a real zero as a score, not as missing data", async () => {
    apiMock.getGovernanceSummary.mockResolvedValue(summary(0));
    renderPage();

    expect(await screen.findByText("0%")).toBeInTheDocument();
    expect(screen.queryByText(/No compliance reports yet/)).not.toBeInTheDocument();
  });
});
