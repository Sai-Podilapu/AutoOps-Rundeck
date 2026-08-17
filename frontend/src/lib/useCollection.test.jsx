import { act, renderHook, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

// Every project-scoped list page (jobs, workflows, executions, nodes) runs on
// this hook, so its loading/error/optimistic-update behaviour is the behaviour
// of a dozen screens at once.
vi.mock("./api", () => ({
  api: { list: vi.fn(), create: vi.fn(), remove: vi.fn() },
}));

let useCollection;
let api;

beforeEach(async () => {
  ({ useCollection } = await import("./useCollection"));
  ({ api } = await import("./api"));
});

describe("useCollection", () => {
  it("loads rows for the resource and project", async () => {
    api.list.mockResolvedValue([{ id: 1, name: "Nightly" }]);

    const { result } = renderHook(() => useCollection("jobs", "7"));

    expect(result.current.loading).toBe(true);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(api.list).toHaveBeenCalledWith("jobs", "7");
    expect(result.current.rows).toEqual([{ id: 1, name: "Nightly" }]);
    expect(result.current.error).toBeNull();
  });

  it("surfaces the API message and leaves the table empty on failure", async () => {
    api.list.mockRejectedValue(new Error("Plan limit reached"));

    const { result } = renderHook(() => useCollection("jobs", "7"));

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBe("Plan limit reached");
    expect(result.current.rows).toEqual([]);
  });

  /** A non-array payload used to blank the page with "rows.map is not a function". */
  it("coerces a non-array payload to an empty list", async () => {
    api.list.mockResolvedValue(null);

    const { result } = renderHook(() => useCollection("jobs", "7"));

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.rows).toEqual([]);
  });

  it("prepends a created row without refetching", async () => {
    api.list.mockResolvedValue([{ id: 1, name: "Old" }]);
    api.create.mockResolvedValue({ id: 2, name: "New" });

    const { result } = renderHook(() => useCollection("jobs", "7"));
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await result.current.create({ name: "New" });
    });

    expect(api.create).toHaveBeenCalledWith("jobs", { projectId: "7", name: "New" });
    expect(result.current.rows.map((r) => r.id)).toEqual([2, 1]);
    expect(api.list).toHaveBeenCalledTimes(1);
  });

  it("drops a removed row from the table", async () => {
    api.list.mockResolvedValue([{ id: 1 }, { id: 2 }]);
    api.remove.mockResolvedValue(undefined);

    const { result } = renderHook(() => useCollection("jobs", "7"));
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await result.current.remove(1);
    });

    expect(result.current.rows).toEqual([{ id: 2 }]);
  });

  it("keeps the row when the delete is rejected", async () => {
    api.list.mockResolvedValue([{ id: 1 }]);
    api.remove.mockRejectedValue(new Error("forbidden"));

    const { result } = renderHook(() => useCollection("jobs", "7"));
    await waitFor(() => expect(result.current.loading).toBe(false));

    await act(async () => {
      await expect(result.current.remove(1)).rejects.toThrow("forbidden");
    });

    expect(result.current.rows).toEqual([{ id: 1 }]);
  });

  it("reloads when the project changes", async () => {
    api.list.mockResolvedValue([]);

    const { rerender } = renderHook(({ pid }) => useCollection("jobs", pid), {
      initialProps: { pid: "7" },
    });
    await waitFor(() => expect(api.list).toHaveBeenCalledWith("jobs", "7"));

    rerender({ pid: "8" });

    await waitFor(() => expect(api.list).toHaveBeenCalledWith("jobs", "8"));
  });

  it("passes a server-side filter through and re-fetches when it changes", async () => {
    api.list.mockResolvedValue([]);

    // A plain object literal: the hook keys the filter by VALUE, so an
    // unchanged filter must not re-fetch on every render.
    const { result, rerender } = renderHook(
      ({ jobId }) =>
        useCollection("executions", "7", { targetType: "JOB", targetId: jobId }),
      { initialProps: { jobId: "31" } },
    );

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(api.list).toHaveBeenCalledWith("executions", "7", {
      targetType: "JOB",
      targetId: "31",
    });

    rerender({ jobId: "31" });
    expect(api.list).toHaveBeenCalledTimes(1);

    rerender({ jobId: "32" });
    await waitFor(() =>
      expect(api.list).toHaveBeenCalledWith("executions", "7", {
        targetType: "JOB",
        targetId: "32",
      }),
    );
  });
});
