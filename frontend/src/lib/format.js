// Small display helpers for API values.
export function fmtDate(value) {
  if (!value) return "—";
  const d = new Date(value);
  if (isNaN(d.getTime())) return "—";
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function fmtDuration(ms) {
  if (ms === null || ms === undefined || ms === "") return "—";
  const n = Number(ms);
  if (isNaN(n)) return "—";
  if (n < 1000) return n + "ms";
  const s = n / 1000;
  if (s < 60) return s.toFixed(1) + "s";
  const m = Math.floor(s / 60);
  const rem = Math.round(s % 60);
  return m + "m " + rem + "s";
}

// Normalize backend status strings (e.g. RunStatus "SUCCESS") to the lowercase
// keys understood by <StatusBadge />.
export function badgeStatus(status) {
  return String(status || "").toLowerCase();
}
