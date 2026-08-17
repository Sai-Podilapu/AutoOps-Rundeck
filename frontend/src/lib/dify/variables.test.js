import { describe, it, expect } from "vitest";
import {
  toRef,
  fromRef,
  parseRefs,
  renderRefs,
  upstreamOf,
  availableVariables,
  danglingRefs,
  collectSelectors,
  typeCompatible,
} from "./variables";
import { handlesFor, outputsFor, defaultDataFor, setPath, getPath } from "./nodeCatalog";

// start → llm → ifelse ─true→ code
//                       └else→ http
const nodes = [
  { id: "start", type: "start", data: defaultDataFor("start") },
  { id: "llm", type: "llm", data: defaultDataFor("llm", "Draft") },
  { id: "ifelse", type: "if-else", data: defaultDataFor("if-else") },
  { id: "code", type: "code", data: defaultDataFor("code") },
  { id: "http", type: "http-request", data: defaultDataFor("http-request") },
];
const edges = [
  { source: "start", target: "llm" },
  { source: "llm", target: "ifelse" },
  { source: "ifelse", target: "code", sourceHandle: "true" },
  { source: "ifelse", target: "http", sourceHandle: "false" },
];

describe("reference format", () => {
  it("round-trips a selector", () => {
    expect(toRef(["llm", "text"])).toBe("{{#llm.text#}}");
    expect(fromRef("{{#llm.text#}}")).toEqual(["llm", "text"]);
  });

  it("returns null for non-references", () => {
    expect(fromRef("plain text")).toBeNull();
    expect(fromRef("")).toBeNull();
  });

  it("extracts every reference in a template", () => {
    expect(parseRefs("A {{#llm.text#}} B {{#sys.user_id#}}")).toEqual([
      ["llm", "text"],
      ["sys", "user_id"],
    ]);
  });

  it("renders references and leaves unresolved ones intact", () => {
    const out = renderRefs("Hi {{#llm.text#}} / {{#gone.x#}}", (sel) =>
      sel[0] === "llm" ? "there" : undefined,
    );
    expect(out).toBe("Hi there / {{#gone.x#}}");
  });
});

describe("graph walking", () => {
  it("returns ancestors nearest-first and excludes descendants", () => {
    const ids = upstreamOf("code", nodes, edges).map((n) => n.id);
    expect(ids).toEqual(["ifelse", "llm", "start"]);
    expect(ids).not.toContain("http");
  });

  it("terminates on a cycle", () => {
    const cyclic = [
      { source: "a", target: "b" },
      { source: "b", target: "a" },
    ];
    const two = [
      { id: "a", type: "llm", data: defaultDataFor("llm") },
      { id: "b", type: "llm", data: defaultDataFor("llm") },
    ];
    // b is a's only ancestor; following b→a must not revisit a and loop forever.
    expect(upstreamOf("a", two, cyclic).map((n) => n.id)).toEqual(["b"]);
  });

  it("offers only upstream variables", () => {
    const groups = availableVariables("code", nodes, edges);
    const nodeGroups = groups.filter((g) => g.scope === "node").map((g) => g.id);
    expect(nodeGroups).toContain("llm");
    expect(nodeGroups).not.toContain("http");
  });

  it("always exposes the system scope", () => {
    const sys = availableVariables("llm", nodes, edges).find((g) => g.scope === "sys");
    expect(sys.variables.map((v) => v.name)).toContain("sys.user_id");
  });

  it("adds chat-only system variables in chat mode", () => {
    const names = (mode) =>
      availableVariables("llm", nodes, edges, { appMode: mode })
        .find((g) => g.scope === "sys")
        .variables.map((v) => v.name);
    expect(names("chat")).toContain("sys.query");
    expect(names("workflow")).not.toContain("sys.query");
  });

  it("exposes iteration item/index to nested children", () => {
    const withIter = [
      ...nodes,
      { id: "iter", type: "iteration", data: defaultDataFor("iteration") },
      { id: "child", type: "llm", data: defaultDataFor("llm"), parentId: "iter" },
    ];
    const g = availableVariables("child", withIter, edges).find((x) => x.scope === "container");
    expect(g.variables.map((v) => v.name)).toEqual(["item", "index"]);
  });
});

describe("dangling references", () => {
  it("flags a reference whose node is gone", () => {
    const code = {
      id: "code",
      type: "code",
      data: { ...defaultDataFor("code"), code: "# {{#deleted.text#}}" },
    };
    const bad = danglingRefs(code, [...nodes.filter((n) => n.id !== "code"), code], edges);
    expect(bad.map((b) => b.ref)).toContain("{{#deleted.text#}}");
  });

  it("accepts a live upstream reference", () => {
    const code = {
      id: "code",
      type: "code",
      data: { ...defaultDataFor("code"), code: "# {{#llm.text#}}" },
    };
    const bad = danglingRefs(code, [...nodes.filter((n) => n.id !== "code"), code], edges);
    expect(bad).toHaveLength(0);
  });

  it("collects selector arrays from config fields, not just templates", () => {
    const found = collectSelectors({ query_variable_selector: ["llm", "text"] });
    expect(found).toEqual([["llm", "text"]]);
  });

  it("does not mistake an ordinary string array for a selector", () => {
    expect(collectSelectors({ dataset_ids: ["abc", "def"] })).toEqual([]);
  });
});

describe("node catalog", () => {
  it("derives one handle per if-else case plus ELSE", () => {
    const n = { type: "if-else", data: defaultDataFor("if-else") };
    const { outputs } = handlesFor(n);
    expect(outputs.map((o) => o.id)).toEqual(["true", "false"]);
  });

  it("derives one handle per classifier class", () => {
    const n = {
      type: "question-classifier",
      data: { ...defaultDataFor("question-classifier"), classes: [{ id: "a", name: "Billing" }, { id: "b", name: "Tech" }] },
    };
    expect(handlesFor(n).outputs.map((o) => o.label)).toEqual(["Billing", "Tech"]);
  });

  it("adds a fail handle when the node continues on the fail branch", () => {
    const n = { type: "llm", data: { ...defaultDataFor("llm"), error_strategy: "fail-branch" } };
    expect(handlesFor(n).outputs.map((o) => o.id)).toContain("fail-branch");
  });

  it("gives start no input handle and end no output handle", () => {
    expect(handlesFor({ type: "start", data: {} }).inputs).toHaveLength(0);
    expect(handlesFor({ type: "end", data: {} }).outputs).toHaveLength(0);
  });

  it("derives code-node outputs from the declared schema", () => {
    const n = { type: "code", data: { outputs: { total: { type: "number" } } } };
    expect(outputsFor(n)).toEqual([{ name: "total", type: "number" }]);
  });

  it("survives a half-configured node", () => {
    expect(outputsFor({ type: "parameter-extractor", data: {} })).toHaveLength(2);
  });
});

describe("dotted paths", () => {
  it("reads and writes nested keys without mutating the source", () => {
    const before = { memory: { window: { size: 10 } } };
    const after = setPath(before, "memory.window.size", 25);
    expect(getPath(after, "memory.window.size")).toBe(25);
    expect(before.memory.window.size).toBe(10);
  });

  it("creates missing intermediate objects", () => {
    expect(getPath(setPath({}, "a.b.c", 1), "a.b.c")).toBe(1);
  });
});

describe("type compatibility", () => {
  it("coerces number and boolean into string", () => {
    expect(typeCompatible("number", "string")).toBe(true);
    expect(typeCompatible("object", "string")).toBe(false);
  });

  it("matches any array against the array wildcard", () => {
    expect(typeCompatible("array[object]", "array")).toBe(true);
  });
});
