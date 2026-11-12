/**
 * Lightweight Node assertions for web dashboard helpers.
 * Run: node web_dashboard/js/web-tests.mjs
 */

function assert(cond, msg) {
  if (!cond) throw new Error(msg || "assertion failed");
}

const SENSOR_STATUS = {
  0: "OK",
  1: "Too close / blind zone",
  2: "No echo / out of range",
  3: "Sensor not responding"
};

function parseReadingMap(map) {
  return Object.entries(map || {}).map(([key, v]) => ({ key, ...v }));
}

function fmtLevel(mm) {
  if (mm == null || mm === 65535) return "Unavailable";
  const m = mm / 1000;
  return `${m.toFixed(2)} m (${mm} mm)`;
}

function rangeBounds(range, now = Date.now() / 1000) {
  if (range === "24h") return { from: now - 86400, to: now };
  if (range === "7d") return { from: now - 7 * 86400, to: now };
  if (range === "30d") return { from: now - 30 * 86400, to: now };
  return { from: 0, to: now };
}

function filterByRange(readings, range, now = Date.now() / 1000) {
  const { from, to } = rangeBounds(range, now);
  return readings.filter((r) => {
    const t = Number(r.measurement_time) || 0;
    return t >= from && t <= to;
  });
}

// Missing values / invalid statuses
assert(fmtLevel(null) === "Unavailable", "null level");
assert(fmtLevel(65535) === "Unavailable", "unavailable sentinel");
assert(SENSOR_STATUS[2].includes("No echo"), "status label");
assert(SENSOR_STATUS[99] === undefined, "unknown status");

const map = {
  "11_1": { measurement_time: 100, water_level_mm: 3000, status: 0 },
  "11_2": { measurement_time: 200, water_level_mm: 65535, status: 2 }
};
const parsed = parseReadingMap(map);
assert(parsed.length === 2, "parse count");
assert(parsed[0].key === "11_1" || parsed[1].key === "11_1", "keys preserved");

const now = 1_000_000;
const rows = [
  { measurement_time: now - 100, water_level_mm: 1 },
  { measurement_time: now - 3600, water_level_mm: 2 },
  { measurement_time: now - 2_000_000, water_level_mm: 3 }
];
assert(filterByRange(rows, "24h", now).length === 2, "24h filter");
assert(filterByRange([], "7d", now).length === 0, "empty data");

console.log("web-tests: all passed");
