import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// What the workspace HAS. The rule that shapes this page is the same one that
// shapes the library: a customer owns and adapts SCRIPTS, while workflows and
// agents are designed by the provider and delivered by a rollout. RolloutService
// builds those in workflow-service and agent-service rather than writing a
// tenant-owned library row, so those two filters are permanently empty — and
// have to say why instead of showing a bare empty grid.

const storeState = { can: () => true, pushToast: vi.fn() };

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual("react-router-dom");
  return { ...actual, useNavigate: () => navigate };
});

const apiMock = { listLibrary: vi.fn(), cloneLibraryItem: vi.fn() };
vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: Inventory } = await import("./Inventory");

const renderPage = () =>
  render(
    <MemoryRouter>
      <Inventory />
    </MemoryRouter>,
  );

const item = (over = {}) => ({
  id: 1,
  title: "Nightly backup",
  description: "Backs the database up.",
  type: "script",
  category: "Ops",
  premium: false,
  managed: false,
  owned: true,
  locked: false,
  installs: 0,
  definition: '{"steps":[]}',
  ...over,
});

beforeEach(() => {
  storeState.pushToast.mockClear();
  storeState.can = () => true;
  navigate.mockClear();
  apiMock.listLibrary.mockReset();
});

describe("my inventory", () => {
  it("lists what the workspace owns and opens one in the editor", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([item({ id: 7 })]);
    renderPage();
    await screen.findByText("Nightly backup");

    fireEvent.click(screen.getByText("Edit script"));
    expect(navigate).toHaveBeenCalledWith("/app/library/script/7");
  });

  it("leaves the catalog on the library page", async () => {
    // A managed row is a template on offer, not something this workspace has.
    // Listing it here would make the page unable to answer its one question.
    apiMock.listLibrary.mockResolvedValueOnce([
      item({ id: 9, title: "Mine", owned: true }),
      item({ id: 10, title: "On offer", managed: true, owned: false }),
    ]);
    renderPage();
    await screen.findByText("Mine");

    expect(screen.queryByText("On offer")).not.toBeInTheDocument();
    expect(screen.getByText("All types (1)")).toBeInTheDocument();
  });

  it("says where workflows live rather than showing an empty grid", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([item()]);
    renderPage();
    await screen.findByText("Nightly backup");

    fireEvent.click(screen.getByText("Workflows (0)"));
    expect(screen.queryByText("Nightly backup")).not.toBeInTheDocument();
    expect(
      screen.getByText(/delivered to a project, not held here/),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByText("Go to Projects"));
    expect(navigate).toHaveBeenCalledWith("/app/projects");
  });

  it("offers editing only to roles that may write scripts", async () => {
    storeState.can = (cap) => cap !== "authorScript";
    apiMock.listLibrary.mockResolvedValueOnce([item()]);
    renderPage();
    await screen.findByText("Nightly backup");

    expect(screen.queryByText("Edit script")).not.toBeInTheDocument();
    expect(screen.queryByText("New script")).not.toBeInTheDocument();
    expect(
      screen.getByText("Ask an admin or operator to change this"),
    ).toBeInTheDocument();
  });

  it("points an empty workspace back at the library", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([]);
    renderPage();
    await screen.findByText("Nothing here yet.");

    fireEvent.click(screen.getByText("Browse the library"));
    expect(navigate).toHaveBeenCalledWith("/app/library");
  });
});
