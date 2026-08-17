// Resolves the current project's route base from the URL, e.g. /app/projects/p1
// Lets project-scoped pages build links without threading the project id everywhere.
export function base() {
  const path = typeof window !== "undefined" ? window.location.pathname : "";
  const m = path.match(/\/app\/projects\/([^/]+)/);
  return m ? `/app/projects/${m[1]}` : "/app/projects";
}
