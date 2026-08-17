import { render, screen, waitFor, fireEvent, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";

// The Dify designer is the white-label replacement for Dify's own editor. The
// contract worth pinning: every node type reaches the palette from the catalog,
// adding one opens its generated config panel, and a node's config is driven by
// the catalog rather than hand-written per type.

const storeState = { can: () => true, pushToast: vi.fn() };

vi.mock("../../store/store", async () => {
  const actual = await vi.importActual("../../store/store");
  return { ...actual, useStore: () => storeState };
});

const difyApiMock = {
  getApp: vi.fn(),
  getDraft: vi.fn(),
  saveDraft: vi.fn(),
  publish: vi.fn(),
  listAvailableModels: vi.fn(),
  listToolProviders: vi.fn(),
  listDatasets: vi.fn(),
};

const emptyDraftFixture = () => ({
  graph: {
    nodes: [
      { id: "start", type: "start", position: { x: 0, y: 0 }, data: { title: "Start", type: "start", variables: [] } },
    ],
    edges: [],
  },
  environment_variables: [],
  conversation_variables: [],
});

vi.mock("../../lib/dify/difyApi", () => ({
  difyApi: difyApiMock,
  streamRun: vi.fn().mockResolvedValue(undefined),
  emptyDraft: emptyDraftFixture,
}));

// jsdom has no layout engine, which reactflow needs to measure the pane.
class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}
global.ResizeObserver = ResizeObserverStub;
global.DOMMatrixReadOnly = class {
  constructor() {
    this.m22 = 1;
  }
};
Object.defineProperties(window.HTMLElement.prototype, {
  offsetHeight: { get: () => 800 },
  offsetWidth: { get: () => 1200 },
});
window.SVGElement.prototype.getBBox = () => ({ x: 0, y: 0, width: 0, height: 0 });

const { generateDsl } = await import("../../lib/dify/dslGenerator");
const { default: DifyDesigner } = await import("./DifyDesigner");

const renderDesigner = () =>
  render(
    <MemoryRouter initialEntries={["/app/projects/7/dify/app-1"]}>
      <Routes>
        <Route path="/app/projects/:pid/dify/:appId" element={<DifyDesigner />} />
      </Routes>
    </MemoryRouter>,
  );

// The suite runs with restoreMocks, so implementations belong here rather than
// at declaration — otherwise they're stripped before the first test.
beforeEach(() => {
  difyApiMock.getApp.mockResolvedValue({ id: "app-1", name: "User-Onboarding", mode: "workflow" });
  difyApiMock.getDraft.mockResolvedValue(emptyDraftFixture());
  difyApiMock.saveDraft.mockResolvedValue({});
  difyApiMock.publish.mockResolvedValue({});
  difyApiMock.listAvailableModels.mockResolvedValue([
    { provider: "p/openai/openai", provider_label: "OpenAI", model: "gpt-4o", label: "GPT-4o", model_type: "llm" },
  ]);
  difyApiMock.listToolProviders.mockResolvedValue([]);
  difyApiMock.listDatasets.mockResolvedValue([]);
});

describe("Dify designer", () => {
  it("loads the app and shows its name and mode", async () => {
    renderDesigner();
    expect(await screen.findByText("User-Onboarding")).toBeInTheDocument();
    expect(screen.getByText(/Dify workflow/)).toBeInTheDocument();
  });

  it("builds the palette from the node catalog", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    const palette = screen.getByText("Nodes").closest("aside");

    // A representative node from each catalog category must be offered.
    for (const label of ["LLM", "IF / ELSE", "Code", "HTTP Request", "Iteration", "Knowledge Retrieval"]) {
      expect(within(palette).getByText(label)).toBeInTheDocument();
    }
  });

  it("omits chat-only nodes from a workflow-mode app", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    const palette = screen.getByText("Nodes").closest("aside");
    expect(within(palette).queryByText("Answer")).not.toBeInTheDocument();
  });

  it("offers chat-only nodes for a chatflow app", async () => {
    difyApiMock.getApp.mockResolvedValueOnce({ id: "app-1", name: "Support Bot", mode: "chat" });
    renderDesigner();
    await screen.findByText("Support Bot");
    const palette = screen.getByText("Nodes").closest("aside");
    expect(within(palette).getByText("Answer")).toBeInTheDocument();
  });

  it("adds a node from the palette and opens its generated config panel", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("LLM"));

    // The panel renders the LLM catalog entry's fields — none of which are
    // hand-written in the panel itself.
    await waitFor(() => expect(screen.getByText("Prompt")).toBeInTheDocument());
    expect(screen.getByText("Model")).toBeInTheDocument();
    expect(screen.getByText("Structured output")).toBeInTheDocument();
    expect(screen.getByText("Error handling")).toBeInTheDocument();
  });

  it("lists configured models in the model picker", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("LLM"));

    await waitFor(() => expect(screen.getByText("Model")).toBeInTheDocument());
    expect(screen.getByRole("option", { name: /OpenAI · GPT-4o/ })).toBeInTheDocument();
  });

  it("shows a node's output variables so they can be referenced downstream", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("LLM"));

    await waitFor(() => expect(screen.getByText("Output variables")).toBeInTheDocument());
    // The reference form is what a downstream prompt would embed.
    expect(screen.getByText(/\{\{#n_.*\.text#\}\}/)).toBeInTheDocument();
  });

  it("reveals the branch handles an IF/ELSE node exposes", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("IF / ELSE"));

    await waitFor(() => expect(screen.getByText("Branches")).toBeInTheDocument());
    const branches = screen.getByText("Branches").closest("section");
    expect(within(branches).getByText("IF")).toBeInTheDocument();
    expect(within(branches).getByText("ELSE")).toBeInTheDocument();
  });

  it("marks the draft dirty on edit and saves it", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("Code"));

    await waitFor(() => expect(screen.getByText(/unsaved changes/)).toBeInTheDocument());

    fireEvent.click(screen.getByText("Save draft"));
    await waitFor(() => expect(difyApiMock.saveDraft).toHaveBeenCalled());

    // The persisted graph carries the catalog's node type, not the canvas's
    // single renderer type — that distinction is what the DSL generator needs.
    const [, payload] = difyApiMock.saveDraft.mock.calls[0];
    expect(payload.graph.nodes.map((n) => n.type)).toEqual(["start", "code"]);
  });

  it("does not persist canvas-only run decoration", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("LLM"));
    fireEvent.click(screen.getByText("Save draft"));

    await waitFor(() => expect(difyApiMock.saveDraft).toHaveBeenCalled());
    const [, payload] = difyApiMock.saveDraft.mock.calls[0];
    for (const node of payload.graph.nodes) {
      expect(node.data).not.toHaveProperty("__runState");
    }
  });

  it("publishes after saving the draft", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    fireEvent.click(screen.getByText("Publish"));
    await waitFor(() => expect(difyApiMock.publish).toHaveBeenCalledWith("app-1"));
    expect(difyApiMock.saveDraft).toHaveBeenCalled();
  });

  it("blocks publish on a validation error and names the offending node", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    // An LLM node with no model chosen fails the catalog's required check.
    fireEvent.click(within(screen.getByText("Nodes").closest("aside")).getByText("LLM"));
    fireEvent.click(screen.getByText("Publish"));

    expect(await screen.findByText(/1 error/)).toBeInTheDocument();
    expect(screen.getByText(/“Model” is required/)).toBeInTheDocument();
    expect(difyApiMock.publish).not.toHaveBeenCalled();
  });

  it("round-trips a nested draft with the child still inside its container", async () => {
    difyApiMock.getDraft.mockResolvedValue({
      graph: {
        // Declared child-first on purpose: reactflow needs the parent ordered
        // ahead of it, and the loader is what has to fix that.
        nodes: [
          { id: "kid", type: "llm", position: { x: 40, y: 90 }, parentId: "iter", data: { type: "llm", title: "Summarise" } },
          { id: "start", type: "start", position: { x: 0, y: 0 }, data: { type: "start", title: "Start", variables: [] } },
          { id: "iter", type: "iteration", position: { x: 400, y: 100 }, data: { type: "iteration", title: "Each item" } },
        ],
        edges: [],
      },
      environment_variables: [],
      conversation_variables: [],
    });

    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(screen.getByText("Save draft"));
    await waitFor(() => expect(difyApiMock.saveDraft).toHaveBeenCalled());

    const [, payload] = difyApiMock.saveDraft.mock.calls[0];
    const kid = payload.graph.nodes.find((n) => n.id === "kid");
    expect(kid.parentId).toBe("iter");
    expect(kid.position).toEqual({ x: 40, y: 90 });

    // Parent must be persisted ahead of its child.
    const order = payload.graph.nodes.map((n) => n.id);
    expect(order.indexOf("iter")).toBeLessThan(order.indexOf("kid"));
  });

  it("does not persist the derived container-empty flag", async () => {
    difyApiMock.getDraft.mockResolvedValue({
      graph: {
        nodes: [
          { id: "start", type: "start", position: { x: 0, y: 0 }, data: { type: "start", variables: [] } },
          { id: "iter", type: "iteration", position: { x: 400, y: 100 }, data: { type: "iteration" } },
        ],
        edges: [],
      },
      environment_variables: [],
    });

    renderDesigner();
    await screen.findByText("User-Onboarding");
    fireEvent.click(screen.getByText("Save draft"));
    await waitFor(() => expect(difyApiMock.saveDraft).toHaveBeenCalled());

    const [, payload] = difyApiMock.saveDraft.mock.calls[0];
    for (const n of payload.graph.nodes) {
      expect(n.data).not.toHaveProperty("__hasChildren");
    }
  });

  it("carries the generated DSL along with the published draft", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    fireEvent.click(screen.getByText("Publish"));
    await waitFor(() => expect(difyApiMock.publish).toHaveBeenCalled());

    const [, payload] = difyApiMock.saveDraft.mock.calls.at(-1);
    expect(payload.dsl).toContain("kind: app");
    expect(payload.dsl).toContain("version: 0.6.0");
  });
});

describe("DSL import", () => {
  const yamlWith = (nodes, edges = []) =>
    generateDsl(
      { app: { name: "Imported Flow", mode: "workflow" }, graph: { nodes, edges } },
      { strict: false },
    ).yaml;

  const pick = (yaml, name = "flow.yml") => {
    const input = screen.getByTestId("dsl-file-input");
    const file = new File([yaml], name, { type: "application/x-yaml" });
    // jsdom's File has no text(); the importer only needs that one method.
    file.text = () => Promise.resolve(yaml);
    fireEvent.change(input, { target: { files: [file] } });
    return file;
  };

  it("confirms before discarding the canvas, and says how much is coming in", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    pick(
      yamlWith([
        { id: "s", type: "start", position: { x: 0, y: 0 }, data: { type: "start", variables: [] } },
        { id: "c", type: "code", position: { x: 200, y: 0 }, data: { type: "code" } },
      ]),
    );

    expect(await screen.findByText("Replace this workflow?")).toBeInTheDocument();
    expect(screen.getByText(/contains 2 nodes/)).toBeInTheDocument();
    expect(screen.getByText(/cannot be undone/)).toBeInTheDocument();
  });

  it("leaves the canvas alone when the import is cancelled", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    pick(yamlWith([{ id: "s", type: "start", position: { x: 0, y: 0 }, data: { type: "start" } }]));
    await screen.findByText("Replace this workflow?");
    fireEvent.click(screen.getByText("Cancel"));

    await waitFor(() =>
      expect(screen.queryByText("Replace this workflow?")).not.toBeInTheDocument(),
    );
    expect(screen.getByText("User-Onboarding")).toBeInTheDocument();
  });

  it("applies the graph and the app name on confirm", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    pick(
      yamlWith([
        { id: "s", type: "start", position: { x: 0, y: 0 }, data: { type: "start", variables: [] } },
        { id: "c", type: "code", position: { x: 200, y: 0 }, data: { type: "code", title: "Transform" } },
      ]),
    );
    await screen.findByText("Replace this workflow?");
    fireEvent.click(screen.getByText("Import"));

    expect(await screen.findByText("Imported Flow")).toBeInTheDocument();

    fireEvent.click(screen.getByText("Save draft"));
    await waitFor(() => expect(difyApiMock.saveDraft).toHaveBeenCalled());
    const [, payload] = difyApiMock.saveDraft.mock.calls.at(-1);
    expect(payload.graph.nodes.map((n) => n.id).sort()).toEqual(["c", "s"]);
  });

  it("rejects a non-Dify file without touching the canvas", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    pick("just: some yaml\nnothing: to do with dify\n");

    expect(await screen.findByText(/No workflow graph in this file/)).toBeInTheDocument();
    expect(screen.queryByText("Replace this workflow?")).not.toBeInTheDocument();
    expect(screen.getByText("User-Onboarding")).toBeInTheDocument();
  });

  it("reports unreadable YAML as an error, not a crash", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    pick("app: [unclosed\n  bad: :");
    expect(await screen.findByText(/Not valid YAML/)).toBeInTheDocument();
  });

  it("keeps import warnings on screen after applying", async () => {
    renderDesigner();
    await screen.findByText("User-Onboarding");

    // No Start node — importable, but worth saying out loud.
    pick(yamlWith([{ id: "c", type: "code", position: { x: 0, y: 0 }, data: { type: "code" } }]));
    await screen.findByText("Replace this workflow?");
    fireEvent.click(screen.getByText("Import"));

    expect(await screen.findByText(/has no Start node/)).toBeInTheDocument();
  });
});
