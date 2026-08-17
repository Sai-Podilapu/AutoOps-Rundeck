// IANA timezone helpers for job schedules.
//
// The backend (CronSupport.zone) accepts ONLY full Region/City IDs plus bare
// "UTC". Abbreviations ("CST", "MST") and fixed offsets ("-06:00") are
// rejected on purpose: they carry no DST rules, so a job pinned to one would
// silently drift an hour at the next transition. Everything here therefore
// produces Region/City IDs and never an abbreviation.

/** The viewer's own zone, e.g. "Asia/Kolkata". Falls back to UTC. */
export function browserTimezone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

// Used only where Intl.supportedValuesOf is unavailable (older Safari).
const FALLBACK_ZONES = [
  "America/Anchorage",
  "America/Chicago",
  "America/Denver",
  "America/Los_Angeles",
  "America/Mexico_City",
  "America/New_York",
  "America/Phoenix",
  "America/Sao_Paulo",
  "America/Toronto",
  "Asia/Dubai",
  "Asia/Kolkata",
  "Asia/Manila",
  "Asia/Shanghai",
  "Asia/Singapore",
  "Asia/Tokyo",
  "Australia/Sydney",
  "Europe/Amsterdam",
  "Europe/Berlin",
  "Europe/Dublin",
  "Europe/London",
  "Europe/Madrid",
  "Europe/Paris",
  "Europe/Warsaw",
  "Pacific/Auckland",
];

/** Current UTC offset for a zone, e.g. "GMT-6". Empty string if unknown. */
export function offsetLabel(zone, at = new Date()) {
  try {
    return (
      new Intl.DateTimeFormat("en-US", {
        timeZone: zone,
        timeZoneName: "shortOffset",
      })
        .formatToParts(at)
        .find((p) => p.type === "timeZoneName")?.value || ""
    );
  } catch {
    return "";
  }
}

/**
 * Options for a timezone <select>, as [{value,label}]. UTC first (it is the
 * backend default), then every Region/City zone the runtime knows.
 */
export function timezoneOptions() {
  let zones = null;
  try {
    if (typeof Intl.supportedValuesOf === "function") {
      zones = Intl.supportedValuesOf("timeZone");
    }
  } catch {
    zones = null;
  }
  if (!zones || !zones.length) zones = FALLBACK_ZONES;

  // Only Region/City IDs survive the backend guard; drop anything else.
  const usable = zones.filter((z) => z.includes("/")).sort();
  return ["UTC", ...usable].map((z) => {
    const offset = offsetLabel(z);
    return { value: z, label: offset ? `${z} (${offset})` : z };
  });
}

/** Formats an absolute instant as wall-clock time in `zone`. */
export function fmtInZone(instant, zone) {
  if (!instant) return "—";
  try {
    return new Intl.DateTimeFormat(undefined, {
      timeZone: zone,
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date(instant));
  } catch {
    return "—";
  }
}
