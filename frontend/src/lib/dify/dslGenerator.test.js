import { describe, it, expect } from "vitest";
import { load, dump } from "js-yaml";
import { generateDsl, toDsl, fromDsl, validateGraph, DSL_VERSION } from "./dslGenerator";
import { defaultDataFor } from "./nodeCatalog";

const node = (id, type, extra = {}) => ({
  id,
  type,
  position: { x: 0, y: 0 },
  data: { ...defaultDataFor(type), ...(extra.data || {}) },
  ...(extra.parentId ? { parentId: extra.parentId } : {}),
});

const edge = (source, target, sourceHandle = "source") => ({
  source,
  target,
  sourceHandle,
  targetHandle: "target",
});

/** A minimal valid workflow: start → llm → end. */
const validGraph = () => ({
  nodes: [
    // The prompt below references `topic`, so the form has to declare it —
    // that pairing is exactly what the dangling-ref check enforces.
    node("start", "start", {
      data: { variables: [{ variable: "topic", label: "Topic", type: "text-input", required: true }] },
    }),
    node("llm", "llm", {
      data: {
        model: { provider: "openai", name: "gpt-4o", mode: "chat", completion_params: {} },
        prompt_template: [{ role: "system", text: "Summarise {{#start.topic#}}" }],
      },
    }),
    node("end", "end"),
  ],
  edges: [edge("start", "llm"), edge("llm", "end")],
});

describe("validation", () => {
  it("accepts a well-formed workflow", () => {
    const { valid, errors } = validateGraph(validGraph());
    expect(errors).toEqual([]);
    expect(valid).toBe(true);
  });

  it("requires a start node", () => {
    const g = validGraph();
    g.nodes = g.nodes.filter((n) => n.id !== "start");
    expect(validateGraph(g).errors.map((e) => e.code)).toContain("no_start");
  });

  it("rejects two start nodes", () => {
    const g = validGraph();
    g.nodes.push(node("start2", "start"));
    expect(validateGraph(g).errors.map((e) => e.code)).toContain("multiple_start");
  });

  it("flags a required field left empty", () => {
    const g = validGraph();
    g.nodes[1].data.model = { provider: "", name: "", completion_params: {} };
    const err = validateGraph(g).errors.find((e) => e.code === "missing_required");
    expect(err.message).toMatch(/Model/);
  });

  it("respects a field's `when` guard when checking required", () => {
    // knowledge-retrieval's rerank model is required only once rerank is on.
    const g = {
      nodes: [
        node("start", "start"),
        node("kr", "knowledge-retrieval", {
          data: { query_variable_selector: ["start", "q"], dataset_ids: ["ds-1"] },
        }),
      ],
      edges: [edge("start", "kr")],
    };
    expect(validateGraph(g).errors.filter((e) => e.code === "missing_required")).toEqual([]);
  });

  it("flags a reference to a deleted node", () => {
    const g = validGraph();
    g.nodes[1].data.prompt_template = [{ role: "system", text: "{{#ghost.text#}}" }];
    const err = validateGraph(g).errors.find((e) => e.code === "dangling_ref");
    expect(err.message).toMatch(/\{\{#ghost.text#\}\}/);
  });

  it("warns rather than errors on an unwired branch", () => {
    const g = {
      nodes: [node("start", "start"), node("cond", "if-else"), node("a", "code")],
      edges: [edge("start", "cond"), edge("cond", "a", "true")],
    };
    const { errors, warnings } = validateGraph(g);
    expect(errors.filter((e) => e.code === "unwired_branch")).toEqual([]);
    expect(warnings.find((w) => w.code === "unwired_branch").message).toMatch(/ELSE/);
  });

  it("warns about an unreachable node but not about container children", () => {
    const g = {
      nodes: [
        node("start", "start"),
        node("orphan", "code"),
        node("iter", "iteration"),
        node("child", "llm", { parentId: "iter" }),
      ],
      edges: [edge("start", "iter")],
    };
    const unreachable = validateGraph(g).warnings.filter((w) => w.code === "unreachable");
    expect(unreachable.map((w) => w.nodeId)).toContain("orphan");
    expect(unreachable.map((w) => w.nodeId)).not.toContain("child");
  });

  it("rejects a chat-only node in a workflow app", () => {
    const g = validGraph();
    g.nodes.push(node("ans", "answer"));
    expect(validateGraph(g, { appMode: "workflow" }).errors.map((e) => e.code)).toContain("chat_only");
    expect(validateGraph(g, { appMode: "chat" }).errors.map((e) => e.code)).not.toContain("chat_only");
  });

  it("warns about an empty container", () => {
    const g = {
      nodes: [node("start", "start"), node("iter", "iteration")],
      edges: [edge("start", "iter")],
    };
    expect(validateGraph(g).warnings.map((w) => w.code)).toContain("empty_container");
  });
});

describe("DSL emission", () => {
  const dsl = () => toDsl({ app: { name: "Onboarding", mode: "workflow" }, graph: validGraph() });

  it("stamps the app envelope Dify's importer expects", () => {
    const d = dsl();
    expect(d.kind).toBe("app");
    expect(d.version).toBe(DSL_VERSION);
    expect(d.app.mode).toBe("workflow");
    expect(d.app.name).toBe("Onboarding");
  });

  it("wraps each node as `custom` with the real type inside data", () => {
    const llm = dsl().workflow.graph.nodes.find((n) => n.id === "llm");
    expect(llm.type).toBe("custom");
    expect(llm.data.type).toBe("llm");
    expect(llm.sourcePosition).toBe("right");
    expect(llm.targetPosition).toBe("left");
  });

  it("writes edges with both endpoint types and a deterministic id", () => {
    const e = dsl().workflow.graph.edges.find((x) => x.source === "start");
    expect(e.id).toBe("start-source-llm-target");
    expect(e.type).toBe("custom");
    expect(e.data).toMatchObject({ sourceType: "start", targetType: "llm", isInIteration: false });
  });

  it("preserves a branch handle as the edge's sourceHandle", () => {
    const d = toDsl({
      app: { mode: "workflow" },
      graph: {
        nodes: [node("start", "start"), node("cond", "if-else"), node("a", "code")],
        edges: [edge("start", "cond"), edge("cond", "a", "false")],
      },
    });
    expect(d.workflow.graph.edges.find((e) => e.source === "cond").sourceHandle).toBe("false");
  });

  it("strips canvas-only decoration", () => {
    const g = validGraph();
    g.nodes[1].data.__runState = "running";
    const llm = toDsl({ graph: g }).workflow.graph.nodes.find((n) => n.id === "llm");
    expect(llm.data).not.toHaveProperty("__runState");
  });

  describe("containers", () => {
    const containerGraph = () => ({
      nodes: [
        node("start", "start"),
        { ...node("iter", "iteration"), position: { x: 400, y: 100 } },
        { ...node("child", "llm", { parentId: "iter" }), position: { x: 50, y: 80 } },
      ],
      edges: [edge("start", "iter")],
    });

    it("marks a child with parentId, extent and the container's id", () => {
      const child = toDsl({ graph: containerGraph() }).workflow.graph.nodes.find(
        (n) => n.id === "child",
      );
      expect(child.parentId).toBe("iter");
      expect(child.extent).toBe("parent");
      expect(child.data.isInIteration).toBe(true);
      expect(child.data.iteration_id).toBe("iter");
    });

    it("resolves a child's absolute position against its parent", () => {
      const child = toDsl({ graph: containerGraph() }).workflow.graph.nodes.find(
        (n) => n.id === "child",
      );
      expect(child.positionAbsolute).toEqual({ x: 450, y: 180 });
    });

    it("appends the synthetic start marker the container declares", () => {
      const nodes = toDsl({ graph: containerGraph() }).workflow.graph.nodes;
      const container = nodes.find((n) => n.id === "iter");
      const marker = nodes.find((n) => n.id === "iterstart");

      expect(container.data.start_node_id).toBe("iterstart");
      expect(marker).toBeDefined();
      expect(marker.type).toBe("custom-iteration-start");
      expect(marker.parentId).toBe("iter");
      expect(marker.draggable).toBe(false);
    });

    it("uses the loop marker for a loop container", () => {
      const g = {
        nodes: [node("start", "start"), node("lp", "loop"), node("c", "code", { parentId: "lp" })],
        edges: [edge("start", "lp")],
      };
      const nodes = toDsl({ graph: g }).workflow.graph.nodes;
      expect(nodes.find((n) => n.id === "lpstart").type).toBe("custom-loop-start");
      expect(nodes.find((n) => n.id === "c").data.isInLoop).toBe(true);
    });
  });
});

describe("YAML output", () => {
  it("round-trips through a YAML parser", () => {
    const { yaml } = generateDsl({ app: { name: "Onboarding", mode: "workflow" }, graph: validGraph() });
    const parsed = load(yaml);
    expect(parsed.kind).toBe("app");
    expect(parsed.workflow.graph.nodes).toHaveLength(3);
  });

  it("preserves multi-line code verbatim", () => {
    const code = 'def main(x: str) -> dict:\n    return {"result": x}\n';
    const g = {
      nodes: [node("start", "start"), node("c", "code", { data: { code } })],
      edges: [edge("start", "c")],
    };
    const { yaml } = generateDsl({ graph: g }, { strict: false });
    const parsed = load(yaml);
    expect(parsed.workflow.graph.nodes.find((n) => n.id === "c").data.code).toBe(code);
  });

  it("keeps a prompt containing YAML metacharacters intact", () => {
    const text = 'Answer with: {"a": 1} — and do not wrap #this\nSecond line: ok';
    const g = validGraph();
    g.nodes[1].data.prompt_template = [{ role: "system", text }];
    const { yaml } = generateDsl({ graph: g });
    expect(load(yaml).workflow.graph.nodes.find((n) => n.id === "llm").data.prompt_template[0].text).toBe(
      text,
    );
  });

  it("emits no YAML anchors even when a value is shared", () => {
    const shared = { provider: "openai", name: "gpt-4o", mode: "chat", completion_params: {} };
    const g = validGraph();
    g.nodes.push(node("llm2", "llm", { data: { model: shared, prompt_template: [] } }));
    g.nodes[1].data.model = shared;
    g.edges.push(edge("llm", "llm2"));
    const { yaml } = generateDsl({ graph: g }, { strict: false });
    expect(yaml).not.toMatch(/&ref_|\*ref_/);
  });

  it("refuses to emit an invalid graph in strict mode", () => {
    const g = validGraph();
    g.nodes = g.nodes.filter((n) => n.id !== "start");
    const { yaml, errors } = generateDsl({ graph: g });
    expect(yaml).toBeNull();
    expect(errors.length).toBeGreaterThan(0);
  });

  it("emits anyway when strict is off", () => {
    const g = validGraph();
    g.nodes = g.nodes.filter((n) => n.id !== "start");
    const { yaml, errors } = generateDsl({ graph: g }, { strict: false });
    expect(yaml).toContain("kind: app");
    expect(errors.length).toBeGreaterThan(0);
  });
});

describe("import", () => {
  const yamlFor = (graph, app = { name: "Onboarding", mode: "workflow" }) =>
    generateDsl({ app, graph }, { strict: false }).yaml;

  it("recovers the app envelope", () => {
    const out = fromDsl(yamlFor(validGraph()));
    expect(out.app).toMatchObject({ name: "Onboarding", mode: "workflow" });
    expect(out.errors).toEqual([]);
  });

  it("unwraps nodes back to their real type", () => {
    const { graph } = fromDsl(yamlFor(validGraph()));
    expect(graph.nodes.map((n) => n.type).sort()).toEqual(["end", "llm", "start"]);
    expect(graph.nodes.every((n) => n.type !== "custom")).toBe(true);
  });

  it("round-trips a workflow without losing node config", () => {
    const before = validGraph();
    const { graph } = fromDsl(yamlFor(before));

    const llmBefore = before.nodes.find((n) => n.id === "llm").data;
    const llmAfter = graph.nodes.find((n) => n.id === "llm").data;
    expect(llmAfter.model).toEqual(llmBefore.model);
    expect(llmAfter.prompt_template).toEqual(llmBefore.prompt_template);
  });

  it("round-trips edges including branch handles", () => {
    const g = {
      nodes: [node("start", "start"), node("cond", "if-else"), node("a", "code")],
      edges: [edge("start", "cond"), edge("cond", "a", "false")],
    };
    const { graph } = fromDsl(yamlFor(g));
    const branch = graph.edges.find((e) => e.source === "cond");
    expect(branch.sourceHandle).toBe("false");
    expect(graph.edges).toHaveLength(2);
  });

  it("survives a full generate -> import -> generate cycle unchanged", () => {
    const first = yamlFor(validGraph());
    const imported = fromDsl(first);
    const second = generateDsl(
      { app: imported.app, graph: imported.graph, environmentVariables: imported.environmentVariables },
      { strict: false },
    ).yaml;
    expect(second).toBe(first);
  });

  describe("container markers", () => {
    const containerGraph = () => ({
      nodes: [
        node("start", "start"),
        { ...node("iter", "iteration"), position: { x: 400, y: 100 } },
        { ...node("kid", "llm", { parentId: "iter" }), position: { x: 50, y: 80 } },
      ],
      edges: [edge("start", "iter")],
    });

    it("drops the synthetic start marker rather than importing it as a node", () => {
      const { graph } = fromDsl(yamlFor(containerGraph()));
      expect(graph.nodes.map((n) => n.id)).not.toContain("iterstart");
      expect(graph.nodes.map((n) => n.id).sort()).toEqual(["iter", "kid", "start"]);
    });

    it("keeps the child inside its container with its relative position", () => {
      const { graph } = fromDsl(yamlFor(containerGraph()));
      const kid = graph.nodes.find((n) => n.id === "kid");
      expect(kid.parentId).toBe("iter");
      expect(kid.position).toEqual({ x: 50, y: 80 });
    });

    it("orders the container ahead of its child", () => {
      const { graph } = fromDsl(yamlFor(containerGraph()));
      const ids = graph.nodes.map((n) => n.id);
      expect(ids.indexOf("iter")).toBeLessThan(ids.indexOf("kid"));
    });

    it("drops edges attached to a marker", () => {
      const doc = load(yamlFor(containerGraph()));
      doc.workflow.graph.edges.push({
        id: "m",
        source: "iterstart",
        target: "kid",
        sourceHandle: "source",
        targetHandle: "target",
      });
      const { graph } = fromDsl(dump(doc));
      expect(graph.edges.some((e) => e.source === "iterstart")).toBe(false);
    });
  });

  describe("bad input", () => {
    it("reports unparseable YAML instead of throwing", () => {
      const out = fromDsl("app: [unclosed\n  bad: :");
      expect(out.graph).toBeNull();
      expect(out.errors[0].code).toBe("unparseable");
    });

    it("rejects an empty file", () => {
      expect(fromDsl("").errors[0].code).toBe("empty");
    });

    it("rejects a non-app document", () => {
      expect(fromDsl(dump({ kind: "dataset", version: "0.6.0" })).errors[0].code).toBe("wrong_kind");
    });

    it("rejects a file with no graph", () => {
      expect(fromDsl(dump({ kind: "app", app: { name: "x" } })).errors[0].code).toBe("no_graph");
    });

    it("warns on a different DSL version but still imports", () => {
      const doc = load(yamlFor(validGraph()));
      doc.version = "0.1.0";
      const out = fromDsl(dump(doc));
      expect(out.graph.nodes).toHaveLength(3);
      expect(out.warnings.map((w) => w.code)).toContain("version_mismatch");
    });

    it("keeps a node type it cannot edit, and says so", () => {
      const doc = load(yamlFor(validGraph()));
      doc.workflow.graph.nodes.push({
        id: "exotic",
        type: "custom",
        position: { x: 0, y: 0 },
        data: { type: "future-node", title: "Something New" },
      });
      const out = fromDsl(dump(doc));
      expect(out.graph.nodes.find((n) => n.id === "exotic").data.type).toBe("future-node");
      expect(out.warnings.map((w) => w.code)).toContain("unsupported_node");
    });

    it("drops an edge pointing at a node that is not in the file", () => {
      const doc = load(yamlFor(validGraph()));
      doc.workflow.graph.edges.push({ id: "x", source: "llm", target: "ghost" });
      const out = fromDsl(dump(doc));
      expect(out.graph.edges.some((e) => e.target === "ghost")).toBe(false);
      expect(out.warnings.map((w) => w.code)).toContain("orphan_edge");
    });

    it("rescues a child whose container is missing", () => {
      const doc = load(yamlFor(validGraph()));
      doc.workflow.graph.nodes.push({
        id: "lost",
        type: "custom",
        parentId: "gone",
        position: { x: 0, y: 0 },
        data: { type: "code", title: "Lost" },
      });
      const out = fromDsl(dump(doc));
      expect(out.graph.nodes.find((n) => n.id === "lost").parentId).toBeUndefined();
      expect(out.warnings.map((w) => w.code)).toContain("orphan_child");
    });

    it("warns when the file has no Start node", () => {
      const doc = load(yamlFor(validGraph()));
      doc.workflow.graph.nodes = doc.workflow.graph.nodes.filter((n) => n.data.type !== "start");
      expect(fromDsl(dump(doc)).warnings.map((w) => w.code)).toContain("no_start");
    });
  });
});
