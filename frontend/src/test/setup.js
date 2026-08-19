import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach, vi } from "vitest";

// jsdom ships neither observer. The scroll-reveal animations on the marketing
// pages construct an IntersectionObserver at mount, so without this every test
// that renders them dies on an environment gap rather than a real defect.
class NoopObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
  takeRecords() {
    return [];
  }
}
global.IntersectionObserver = global.IntersectionObserver || NoopObserver;
global.ResizeObserver = global.ResizeObserver || NoopObserver;
window.scrollTo = window.scrollTo || (() => {});

// A test that forgets to stub fetch must fail loudly rather than reach out to
// a real network. Individual tests replace this with their own stub.
beforeEach(() => {
  localStorage.clear();
  // Tokens live in sessionStorage (one session per TAB). Without clearing it a
  // signed-in session leaks from one test into the next.
  sessionStorage.clear();
  global.fetch = vi.fn(() => {
    throw new Error("unstubbed fetch — the suite is hermetic, stub it in the test");
  });
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

/** A fetch Response double: `json()`/`text()` behave like the real thing. */
export function response(status, body) {
  const text = body === undefined ? "" : JSON.stringify(body);
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => text,
    json: async () => JSON.parse(text),
  };
}

/** Queues one response per call, in order; extra calls fail the test. */
export function fetchSequence(...responses) {
  const queue = [...responses];
  const spy = vi.fn(async () => {
    if (!queue.length) {
      throw new Error("fetch called more times than the test queued responses for");
    }
    return queue.shift();
  });
  global.fetch = spy;
  return spy;
}
