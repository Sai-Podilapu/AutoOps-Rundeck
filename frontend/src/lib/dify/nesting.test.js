import { describe, it, expect } from "vitest";
import {
  absolutePosition,
  sortParentFirst,
  containerAt,
  nestingTargetFor,
  reparent,
  descendantsOf,
  removeWithDescendants,
  canNest,
  CONTAINER_SIZE,
} from "./nesting";

const n = (id, type, x, y, extra = {}) => ({
  id,
  position: { x, y },
  data: { type },
  ...extra,
});

/** iteration box at (400,100), 640×320. */
const graph = () => [
  n("start", "start", 0, 200),
  n("iter", "iteration", 400, 100),
  n("free", "llm", 900, 400),
];

describe("what may nest", () => {
  it("allows an ordinary node", () => {
    expect(canNest(n("a", "llm", 0, 0))).toBe(true);
  });

  it("refuses containers, since Dify has no nested iteration", () => {
    expect(canNest(n("a", "iteration", 0, 0))).toBe(false);
    expect(canNest(n("a", "loop", 0, 0))).toBe(false);
  });

  it("refuses the outer-flow nodes", () => {
    expect(canNest(n("a", "start", 0, 0))).toBe(false);
    expect(canNest(n("a", "end", 0, 0))).toBe(false);
  });
});

describe("coordinates", () => {
  it("resolves a child against its parent", () => {
    const nodes = [n("iter", "iteration", 400, 100), n("kid", "llm", 50, 80, { parentId: "iter" })];
    const byId = new Map(nodes.map((x) => [x.id, x]));
    expect(absolutePosition(byId.get("kid"), byId)).toEqual({ x: 450, y: 180 });
  });

  it("leaves a top-level node alone", () => {
    const nodes = graph();
    const byId = new Map(nodes.map((x) => [x.id, x]));
    expect(absolutePosition(byId.get("free"), byId)).toEqual({ x: 900, y: 400 });
  });

  it("does not hang on a corrupted parent cycle", () => {
    const nodes = [
      n("a", "llm", 10, 10, { parentId: "b" }),
      n("b", "iteration", 20, 20, { parentId: "a" }),
    ];
    const byId = new Map(nodes.map((x) => [x.id, x]));
    expect(absolutePosition(byId.get("a"), byId)).toEqual({ x: 30, y: 30 });
  });
});

describe("ordering for reactflow", () => {
  it("puts a parent before its child even when declared after", () => {
    const nodes = [n("kid", "llm", 0, 0, { parentId: "iter" }), n("iter", "iteration", 0, 0)];
    expect(sortParentFirst(nodes).map((x) => x.id)).toEqual(["iter", "kid"]);
  });

  it("keeps unrelated order stable", () => {
    expect(sortParentFirst(graph()).map((x) => x.id)).toEqual(["start", "iter", "free"]);
  });

  it("survives a cyclic parent chain without dropping nodes", () => {
    const nodes = [
      n("a", "llm", 0, 0, { parentId: "b" }),
      n("b", "iteration", 0, 0, { parentId: "a" }),
    ];
    expect(sortParentFirst(nodes)).toHaveLength(2);
  });
});

describe("hit testing", () => {
  it("finds the container under a point", () => {
    expect(containerAt({ x: 500, y: 200 }, graph())?.id).toBe("iter");
  });

  it("returns null outside every container", () => {
    expect(containerAt({ x: 50, y: 50 }, graph())).toBeNull();
  });

  it("treats the box edges as inside", () => {
    const nodes = graph();
    expect(containerAt({ x: 400, y: 100 }, nodes)?.id).toBe("iter");
    expect(
      containerAt({ x: 400 + CONTAINER_SIZE.width, y: 100 + CONTAINER_SIZE.height }, nodes)?.id,
    ).toBe("iter");
    expect(containerAt({ x: 400 + CONTAINER_SIZE.width + 1, y: 200 }, nodes)).toBeNull();
  });

  it("ignores the node being dragged", () => {
    expect(containerAt({ x: 500, y: 200 }, graph(), "iter")).toBeNull();
  });

  it("targets a container by the dragged node's centre, not its corner", () => {
    // Top-left sits outside the box; the centre lands inside it.
    const nodes = [...graph(), n("drag", "llm", 300, 80)];
    expect(nestingTargetFor(nodes[3], nodes)?.id).toBe("iter");
  });

  it("never targets a container for a node that cannot nest", () => {
    const nodes = [...graph(), n("drag", "end", 500, 200)];
    expect(nestingTargetFor(nodes[3], nodes)).toBeNull();
  });
});

describe("reparenting", () => {
  it("attaches with a position relative to the container", () => {
    const nodes = [...graph(), n("drag", "llm", 500, 220)];
    const kid = reparent(nodes, "drag", "iter").find((x) => x.id === "drag");

    expect(kid.parentId).toBe("iter");
    expect(kid.extent).toBe("parent");
    expect(kid.position).toEqual({ x: 100, y: 120 });
  });

  it("detaches back to absolute coordinates without visibly moving", () => {
    const nodes = [n("iter", "iteration", 400, 100), n("kid", "llm", 100, 120, { parentId: "iter" })];
    const freed = reparent(nodes, "kid", null).find((x) => x.id === "kid");

    expect(freed.parentId).toBeUndefined();
    expect(freed.extent).toBeUndefined();
    expect(freed.position).toEqual({ x: 500, y: 220 });
  });

  it("clamps a node dropped on the container's edge so it stays visible", () => {
    const nodes = [...graph(), n("drag", "llm", 400, 100)];
    const kid = reparent(nodes, "drag", "iter").find((x) => x.id === "drag");
    expect(kid.position.x).toBeGreaterThanOrEqual(8);
    expect(kid.position.y).toBeGreaterThanOrEqual(48);
  });

  it("returns the same array when nothing changes", () => {
    const nodes = graph();
    expect(reparent(nodes, "free", null)).toBe(nodes);
  });

  it("refuses to nest a container", () => {
    const nodes = [...graph(), n("inner", "iteration", 500, 200)];
    expect(reparent(nodes, "inner", "iter")).toBe(nodes);
  });

  it("refuses an unknown container", () => {
    const nodes = graph();
    expect(reparent(nodes, "free", "ghost")).toBe(nodes);
  });

  it("re-sorts so the parent leads its new child", () => {
    const nodes = [n("drag", "llm", 500, 220), n("iter", "iteration", 400, 100)];
    expect(reparent(nodes, "drag", "iter").map((x) => x.id)).toEqual(["iter", "drag"]);
  });
});

describe("deletion", () => {
  const nested = () => [
    n("iter", "iteration", 400, 100),
    n("kid", "llm", 20, 60, { parentId: "iter" }),
    n("other", "code", 900, 100),
  ];

  it("lists a container's children", () => {
    expect(descendantsOf("iter", nested())).toEqual(["kid"]);
  });

  it("takes the children with the container, leaving no orphan parentId", () => {
    const left = removeWithDescendants(nested(), "iter");
    expect(left.map((x) => x.id)).toEqual(["other"]);
    expect(left.some((x) => x.parentId)).toBe(false);
  });

  it("removes a plain node without touching anything else", () => {
    expect(removeWithDescendants(nested(), "other").map((x) => x.id)).toEqual(["iter", "kid"]);
  });
});
