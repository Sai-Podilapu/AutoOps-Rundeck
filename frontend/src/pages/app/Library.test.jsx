import { render, screen, waitFor, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// The template catalog as a TENANT sees it. The rule that shapes this page is
// the provider-authored model: a customer owns and adapts SCRIPTS, while
// workflows and agents are designed by the provider and delivered sealed by a
// rollout. core-service enforces it (403 rollout_only on a clone), so the page
// must not offer an action that can only ever produce a red toast.

const storeState = { can: () => true, pushToast: vi.fn() };

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

// Navigation is the observable outcome of "Edit script" — the editor itself
// has its own tests.
const navigate = vi.fn();
vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual("react-router-dom");
  return { ...actual, useNavigate: () => navigate };
});

const apiMock = {
  listLibrary: vi.fn(),
  cloneLibraryItem: vi.fn(),
};

vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: Library } = await import("./Library");

const renderPage = () =>
  render(
    <MemoryRouter>
      <Library />
    </MemoryRouter>,
  );

const item = (over = {}) => ({
  id: 1,
  title: "Disk & memory health check",
  description: "Checks disk and memory headroom.",
  type: "script",
  category: "Ops",
  premium: false,
  managed: true,
  owned: false,
  locked: false,
  installs: 12,
  definition: '{"steps":[]}',
  ...over,
});

beforeEach(() => {
  storeState.pushToast.mockClear();
  storeState.can = () => true;
  navigate.mockClear();
  apiMock.cloneLibraryItem.mockReset();
  apiMock.cloneLibraryItem.mockResolvedValue({ id: 99 });
  apiMock.listLibrary.mockResolvedValue([
    item(),
    item({ id: 2, title: "Card Fraud Alert Triage", type: "workflow" }),
    item({ id: 3, title: "Banking Ops Copilot", type: "agent" }),
  ]);
});

describe("template library", () => {
  it("offers Import only for the scripts a customer may own", async () => {
    renderPage();
    await screen.findByText("Disk & memory health check");

    // One Import button — the script's. The workflow and the agent get a
    // statement of where they come from instead of a button that 403s.
    expect(screen.getAllByText("Import")).toHaveLength(1);
    expect(screen.getAllByText("Delivered by your provider")).toHaveLength(2);
  });

  it("imports a script into the workspace", async () => {
    renderPage();
    await screen.findByText("Disk & memory health check");

    fireEvent.click(screen.getByText("Import"));

    await waitFor(() => expect(apiMock.cloneLibraryItem).toHaveBeenCalledWith(1));
  });

  it("never bulk-imports a provider-delivered template", async () => {
    // The checkbox is the other route to the same forbidden call: selecting a
    // workflow and hitting "Import selected" would fail item by item.
    renderPage();
    await screen.findByText("Card Fraud Alert Triage");

    expect(
      screen.queryByLabelText("Select Card Fraud Alert Triage"),
    ).not.toBeInTheDocument();
    expect(
      screen.queryByLabelText("Select Banking Ops Copilot"),
    ).not.toBeInTheDocument();
    // ...but the script the customer may own is still selectable.
    expect(
      screen.getByLabelText("Select Disk & memory health check"),
    ).toBeInTheDocument();
  });

  it("still marks a premium script as locked rather than importable", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([
      item({ id: 4, title: "Nightly database backup", premium: true, locked: true }),
    ]);
    renderPage();
    await screen.findByText("Nightly database backup");

    expect(screen.getByText("Upgrade to unlock")).toBeInTheDocument();
    expect(screen.queryByText("Import")).not.toBeInTheDocument();
  });

  it("marks what the workspace already has, but does not list the copy", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([
      item(),
      item({ id: 5, title: "Disk & memory health check", managed: false, owned: true }),
    ]);
    renderPage();
    await screen.findByText("Disk & memory health check");

    // The catalog marks the template as already held and withdraws Import...
    expect(screen.getByText("In your workspace")).toBeInTheDocument();
    expect(screen.queryByText("Import")).not.toBeInTheDocument();

    // ...and that is all this page does. The editable copy lives on the
    // inventory page: this one is the marketplace, nothing else.
    expect(screen.queryByText("Edit script")).not.toBeInTheDocument();
  });

  it("sends an author to the inventory page rather than listing it here", async () => {
    apiMock.listLibrary.mockResolvedValueOnce([
      item({ id: 7, title: "Nightly backup", managed: false, owned: true }),
    ]);
    renderPage();
    // The (1) is the load barrier: the button renders before the fetch
    // resolves, and its count is the only proof the list arrived.
    fireEvent.click(
      await screen.findByRole("button", { name: /My inventory \(1\)/ }),
    );

    expect(navigate).toHaveBeenCalledWith("/app/library/inventory");
  });

  it("offers authoring only to roles that may write scripts", async () => {
    // A viewer can run what the workspace has but not write it - the backend
    // refuses either way, so the button must not be there to press.
    storeState.can = (cap) => cap !== "authorScript";
    apiMock.listLibrary.mockResolvedValueOnce([
      item({ id: 8, title: "Nightly backup", managed: false, owned: true }),
    ]);
    renderPage();
    await screen.findByRole("button", { name: /My inventory \(1\)/ });

    expect(screen.queryByText("New script")).not.toBeInTheDocument();
  });
});
