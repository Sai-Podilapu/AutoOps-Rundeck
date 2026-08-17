import { describe, it, expect } from "vitest";
import { buildThroughput, THROUGHPUT_RANGES } from "./throughput";

const NOW = new Date("2026-08-02T12:00:00Z").getTime();
const HOUR = 3600_000;
const DAY = 24 * HOUR;

const run = (status, ms) => ({
  status,
  createdAt: new Date(NOW - ms).toISOString(),
});

describe("buildThroughput", () => {
  it("returns one bucket per step for the selected range", () => {
    for (const r of THROUGHPUT_RANGES) {
      expect(buildThroughput([], r.key, NOW)).toHaveLength(r.buckets);
    }
  });

  it("counts a run into the bucket its timestamp falls in", () => {
    const buckets = buildThroughput([run("success", 2 * HOUR)], "24h", NOW);
    const hit = buckets.filter((b) => b.total > 0);
    expect(hit).toHaveLength(1);
    expect(hit[0].success).toBe(1);
  });

  it("maps backend statuses onto the three series", () => {
    const rows = [
      run("success", HOUR),
      run("failed", HOUR),
      run("running", HOUR),
      run("queued", HOUR),
      run("cancelled", HOUR),
    ];
    const b = buildThroughput(rows, "24h", NOW).find((x) => x.total > 0);
    expect(b).toMatchObject({ success: 1, failed: 1, running: 3, total: 5 });
  });

  it("shows a run from yesterday on the default 7-day range", () => {
    // The old 12-hour window hid anything older than half a day.
    const rows = [run("success", 36 * HOUR)];
    expect(buildThroughput(rows, "7d", NOW).some((b) => b.total === 1)).toBe(
      true,
    );
    expect(buildThroughput(rows, "1h", NOW).every((b) => b.total === 0)).toBe(
      true,
    );
  });

  it("drops runs outside the window and unparseable timestamps", () => {
    const rows = [
      run("success", 40 * DAY),
      { status: "success", createdAt: null },
      { status: "success", createdAt: "not-a-date" },
      { status: "success", createdAt: new Date(NOW + DAY).toISOString() },
    ];
    expect(
      buildThroughput(rows, "30d", NOW).every((b) => b.total === 0),
    ).toBe(true);
  });

  it("falls back to startedAt when createdAt is absent", () => {
    const rows = [
      { status: "failed", startedAt: new Date(NOW - HOUR).toISOString() },
    ];
    const b = buildThroughput(rows, "24h", NOW).find((x) => x.total > 0);
    expect(b.failed).toBe(1);
  });

  it("tolerates a missing or non-array execution list", () => {
    expect(buildThroughput(undefined, "24h", NOW).every((b) => !b.total)).toBe(
      true,
    );
  });
});
