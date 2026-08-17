/**
 * Container nesting geometry.
 *
 * Iteration and loop nodes hold a sub-flow, which reactflow models with
 * `parentId` + a position that is *relative to the parent*. Three rules make
 * this fiddly enough to be worth isolating from the component:
 *
 *  1. A parent must appear before its children in the nodes array or reactflow
 *     throws on render.
 *  2. Attaching or detaching has to rewrite the node's position, because the
 *     same on-screen spot is a different coordinate pair once the frame of
 *     reference changes.
 *  3. Not everything may nest — Dify has no nested iteration, and the unique
 *     Start/End nodes belong to the outer flow.
 *
 * Keeping it here means the rules are unit-testable without simulating a drag.
 */

import { NODE_TYPES } from "./nodeCatalog";

/** Default on-canvas footprint, mirrored in the DSL generator. */
export const NODE_SIZE = { width: 240, height: 76 };
export const CONTAINER_SIZE = { width: 640, height: 320 };

/** Node types that always belong to the outer flow. */
export const NESTING_EXEMPT = new Set(["start", "end", "answer"]);

export const typeOf = (node) => node?.data?.type || node?.type;
export const isContainer = (node) => !!NODE_TYPES[typeOf(node)]?.container;

/** Containers do not nest inside each other, and Start/End never move in. */
export function canNest(node) {
  return !!node && !isContainer(node) && !NESTING_EXEMPT.has(typeOf(node));
}

const sizeOf = (node) => ({
  width: node?.style?.width ?? (isContainer(node) ? CONTAINER_SIZE.width : NODE_SIZE.width),
  height: node?.style?.height ?? (isContainer(node) ? CONTAINER_SIZE.height : NODE_SIZE.height),
});

/**
 * Canvas coordinates of a node, walking up the parent chain.
 *
 * `seen` guards a corrupted graph where a parent chain loops — the canvas must
 * still render rather than hang.
 */
export function absolutePosition(node, byId) {
  let x = node?.position?.x || 0;
  let y = node?.position?.y || 0;
  const seen = new Set([node?.id]);
  let parent = node?.parentId ? byId.get(node.parentId) : null;
  while (parent && !seen.has(parent.id)) {
    seen.add(parent.id);
    x += parent.position?.x || 0;
    y += parent.position?.y || 0;
    parent = parent.parentId ? byId.get(parent.parentId) : null;
  }
  return { x, y };
}

/**
 * Orders parents ahead of their children, preserving relative order otherwise.
 * reactflow requires this; violating it is a render-time crash, not a warning.
 */
export function sortParentFirst(nodes) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const out = [];
  const placed = new Set();
  const visiting = new Set();

  const visit = (node) => {
    if (!node || placed.has(node.id) || visiting.has(node.id)) return;
    visiting.add(node.id);
    if (node.parentId) visit(byId.get(node.parentId));
    visiting.delete(node.id);
    placed.add(node.id);
    out.push(node);
  };

  nodes.forEach(visit);
  return out;
}

/** The container whose box contains `point`, innermost first. */
export function containerAt(point, nodes, excludeId) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const hits = nodes.filter((n) => {
    if (!isContainer(n) || n.id === excludeId) return false;
    const pos = absolutePosition(n, byId);
    const { width, height } = sizeOf(n);
    return (
      point.x >= pos.x && point.x <= pos.x + width && point.y >= pos.y && point.y <= pos.y + height
    );
  });
  // Deepest container wins, so an inner box beats the one it sits in.
  return hits.sort((a, b) => depthOf(b, byId) - depthOf(a, byId))[0] || null;
}

function depthOf(node, byId) {
  let depth = 0;
  const seen = new Set([node.id]);
  let parent = node.parentId ? byId.get(node.parentId) : null;
  while (parent && !seen.has(parent.id)) {
    seen.add(parent.id);
    depth += 1;
    parent = parent.parentId ? byId.get(parent.parentId) : null;
  }
  return depth;
}

/** The container a node currently sits over, or null. */
export function nestingTargetFor(node, nodes) {
  if (!canNest(node)) return null;
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const pos = absolutePosition(node, byId);
  const { width, height } = sizeOf(node);
  const centre = { x: pos.x + width / 2, y: pos.y + height / 2 };
  return containerAt(centre, nodes, node.id);
}

/**
 * Moves `nodeId` into `containerId` (or out, when it is null), rewriting the
 * position so the node does not visibly jump, and re-sorting so parents lead.
 *
 * Returns the original array when nothing would change, letting callers skip a
 * needless re-render.
 */
export function reparent(nodes, nodeId, containerId) {
  const byId = new Map(nodes.map((n) => [n.id, n]));
  const node = byId.get(nodeId);
  if (!node) return nodes;

  const current = node.parentId || null;
  const next = containerId || null;
  if (current === next) return nodes;
  if (next && !canNest(node)) return nodes;

  const container = next ? byId.get(next) : null;
  if (next && !container) return nodes;

  const absolute = absolutePosition(node, byId);
  const updated = { ...node };

  if (container) {
    const containerPos = absolutePosition(container, byId);
    updated.parentId = container.id;
    updated.extent = "parent";
    // Keep the node inside the frame even if it was dropped on the very edge.
    updated.position = {
      x: Math.max(8, absolute.x - containerPos.x),
      y: Math.max(48, absolute.y - containerPos.y),
    };
    updated.zIndex = 1;
  } else {
    delete updated.parentId;
    delete updated.extent;
    updated.position = absolute;
    updated.zIndex = 0;
  }

  return sortParentFirst(nodes.map((n) => (n.id === nodeId ? updated : n)));
}

/** Ids of every node inside `containerId`, at any depth. */
export function descendantsOf(containerId, nodes) {
  const direct = nodes.filter((n) => n.parentId === containerId);
  return direct.flatMap((n) => [n.id, ...descendantsOf(n.id, nodes)]);
}

/**
 * Removing a container must not orphan its children — reactflow would crash on
 * a `parentId` pointing at nothing. Deletes the whole subtree.
 */
export function removeWithDescendants(nodes, nodeId) {
  const doomed = new Set([nodeId, ...descendantsOf(nodeId, nodes)]);
  return nodes.filter((n) => !doomed.has(n.id));
}
