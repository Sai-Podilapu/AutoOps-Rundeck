import { useCallback, useEffect, useState } from "react";
import { api } from "./api";

// Loads and mutates a project-scoped collection (jobs, nodes, workflows,
// executions) from the backend. Returns rows plus create/remove/reload helpers.
//
// `filter` is an optional server-side narrowing passed straight to api.list —
// e.g. {targetType: "JOB", targetId} to load one job's runs. It is keyed by
// VALUE, not identity, so callers can pass a plain object literal without
// re-fetching on every render.
export function useCollection(resource, projectId, filter) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const filterKey = filter ? JSON.stringify(filter) : "";

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      // Unfiltered callers keep the original two-argument call exactly.
      const data = filterKey
        ? await api.list(resource, projectId, JSON.parse(filterKey))
        : await api.list(resource, projectId);
      const next = Array.isArray(data) ? data : [];
      setRows(next);
      // Returned as well as stored: a caller polling for a change cannot read
      // the state it just set, and re-fetching to see it would double the load.
      return next;
    } catch (e) {
      setError(e.message || "Failed to load");
      return null;
    } finally {
      setLoading(false);
    }
  }, [resource, projectId, filterKey]);

  useEffect(() => {
    reload();
  }, [reload]);

  const create = useCallback(
    async (body) => {
      const created = await api.create(resource, { projectId, ...body });
      setRows((r) => [created, ...r]);
      return created;
    },
    [resource, projectId],
  );

  const remove = useCallback(
    async (id) => {
      await api.remove(resource, id);
      setRows((r) => r.filter((x) => x.id !== id));
    },
    [resource],
  );

  return { rows, loading, error, reload, create, remove, setRows };
}
