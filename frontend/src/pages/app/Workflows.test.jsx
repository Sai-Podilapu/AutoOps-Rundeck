import { render, screen, fireEvent, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// Running a provider-authored workflow is a two-step conversation: the console
// asks the workflow what it needs, then asks the person. The workflow declares
// its own form (Dify's start-node variables), so the console cannot know
// whether to show a dialog until it has asked.

const storeState = { can: () => true, pushToast: vi.fn() };
vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual("react-router-dom");
  return { ...actual, useParams: () => ({ pid: "1" }) };
});

const reload = vi.fn();
let rows = [];
vi.mock("../../lib/useCollection", () => ({
  useCollection: () => ({ rows, loading: false, error: null, reload }),
}));

const apiMock = { workflowInputs: vi.fn(), runWorkflow: vi.fn(), setWorkflowEnabled: vi.fn() };
vi.mock("../../lib/api", () => ({ api: apiMock }));

const { default: Workflows } = await import("./Workflows");

const renderPage = () =>
  render(
    <MemoryRouter>
      <Workflows />
    </MemoryRouter>,
  );

const workflow = (over = {}) => ({
  id: 42,
  name: "Patch Tuesday",
  active: true,
  state: "ACTIVE",
  validation: "valid",
  successRate: 100,
  lastRunAt: null,
  category: "Ops",
  steps: 4,
  ...over,
});

beforeEach(() => {
  storeState.pushToast.mockClear();
  storeState.can = () => true;
  reload.mockClear();
  apiMock.workflowInputs.mockReset();
  apiMock.runWorkflow.mockReset().mockResolvedValue({ id: 7 });
  rows = [workflow()];
});

describe("running a rolled-out workflow", () => {
  it("runs straight away when the workflow asks for nothing", async () => {
    apiMock.workflowInputs.mockResolvedValueOnce([]);
    renderPage();

    fireEvent.click(screen.getByText("Run"));

    await waitFor(() => expect(apiMock.runWorkflow).toHaveBeenCalledWith(42, undefined));
    // No dialog for a workflow with no declared inputs — a form with no fields
    // is a click the person did not need to make.
    expect(screen.queryByText(/asks for/)).not.toBeInTheDocument();
  });

  it("asks for declared inputs before starting the run", async () => {
    apiMock.workflowInputs.mockResolvedValueOnce([
      { variable: "host", label: "Hostname", type: "text", required: true, options: [] },
      { variable: "env", label: "Environment", type: "select", required: false,
        defaultValue: "prod", options: ["dev", "prod"] },
    ]);
    renderPage();

    fireEvent.click(screen.getByText("Run"));
    await screen.findByText("Run “Patch Tuesday”");
    // Nothing has started yet — the dialog is a gate, not a notification.
    expect(apiMock.runWorkflow).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText(/Hostname/), {
      target: { value: "db01" },
    });
    // Scoped to the dialog: the table row behind it also has a "Run"
    // button, and clicking that one would restart the whole flow.
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", { name: /^Run$/ }),
    );

    await waitFor(() =>
      // The select's declared default rides along without being touched.
      expect(apiMock.runWorkflow).toHaveBeenCalledWith(42, { host: "db01", env: "prod" }),
    );
  });

  it("refuses to submit while a required field is empty", async () => {
    apiMock.workflowInputs.mockResolvedValueOnce([
      { variable: "host", label: "Hostname", type: "text", required: true, options: [] },
    ]);
    renderPage();

    fireEvent.click(screen.getByText("Run"));
    await screen.findByText("Run “Patch Tuesday”");
    // Scoped to the dialog: the table row behind it also has a "Run"
    // button, and clicking that one would restart the whole flow.
    fireEvent.click(
      within(screen.getByRole("dialog")).getByRole("button", { name: /^Run$/ }),
    );

    expect(await screen.findByText("Fill in: Hostname")).toBeInTheDocument();
    expect(apiMock.runWorkflow).not.toHaveBeenCalled();
  });

  it("reports an approval instead of pretending the run started", async () => {
    apiMock.workflowInputs.mockResolvedValueOnce([]);
    apiMock.runWorkflow.mockResolvedValueOnce({ approvalRequired: true, approval: {} });
    renderPage();

    fireEvent.click(screen.getByText("Run"));

    await waitFor(() =>
      expect(storeState.pushToast).toHaveBeenCalledWith(
        expect.stringContaining("approve"),
        "amber",
      ),
    );
  });

  it("surfaces a failure to read the input schema", async () => {
    apiMock.workflowInputs.mockRejectedValueOnce(new Error("Dify is unreachable"));
    renderPage();

    fireEvent.click(screen.getByText("Run"));

    await waitFor(() =>
      expect(storeState.pushToast).toHaveBeenCalledWith("Dify is unreachable", "red"),
    );
    expect(apiMock.runWorkflow).not.toHaveBeenCalled();
  });

  // A workflow that has never run has no success record. Defaulting the bar to
  // 100% told the customer it had a perfect history, on the very column they
  // judge trust from; 0% would have been the same lie inverted.
  describe("success rate for a workflow that has never run", () => {
    it("says so instead of showing a perfect score", () => {
      rows = [workflow({ successRate: null, lastRunAt: null })];
      renderPage();

      expect(screen.getByText("No runs yet")).toBeInTheDocument();
      expect(screen.queryByText("100%")).not.toBeInTheDocument();
      expect(screen.queryByText("0%")).not.toBeInTheDocument();
    });

    it("still shows a real score once there is one", () => {
      rows = [workflow({ successRate: 60, lastRunAt: "2026-08-17T10:00:00Z" })];
      renderPage();

      expect(screen.getByText("60%")).toBeInTheDocument();
      expect(screen.queryByText("No runs yet")).not.toBeInTheDocument();
    });

    it("treats a genuine zero as a score, not as absent", () => {
      // 0% means it has run and always failed — that must not read as "no runs".
      rows = [workflow({ successRate: 0, lastRunAt: "2026-08-17T10:00:00Z" })];
      renderPage();

      expect(screen.getByText("0%")).toBeInTheDocument();
      expect(screen.queryByText("No runs yet")).not.toBeInTheDocument();
    });
  });
});
