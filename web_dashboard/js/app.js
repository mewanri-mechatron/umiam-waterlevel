import {
  initFirebase,
  isDemoMode,
  listenStations,
  listenLatest,
  listenReadings,
  listenConnection
} from "./firebase.js";
import {
  fetchUmiamWeather,
  weatherIcon,
  weatherLabel
} from "./weather.js";

const SENSOR_STATUS = {
  0: "OK",
  1: "Too close",
  2: "No echo",
  3: "No response"
};

const UNAVAILABLE_MM = 65535;
const STATION_ID = "station_001";
const UNIT_STORAGE_KEY = "umiam_display_unit_v2";
const FT_PER_M = 3.28084;

/**
 * Dam RL values in Firebase (`water_level_m`, calib) are feet AMSL.
 * Sensor raw gap (`distance_mm`) is true millimetres.
 */
const UNITS = {
  ft: {
    label: "ft",
    digits: 2,
    fromFeet: (ft) => ft,
    fromMetres: (m) => m * FT_PER_M
  },
  m: {
    label: "m",
    digits: 2,
    fromFeet: (ft) => ft / FT_PER_M,
    fromMetres: (m) => m
  },
  cm: {
    label: "cm",
    digits: 1,
    fromFeet: (ft) => (ft / FT_PER_M) * 100,
    fromMetres: (m) => m * 100
  },
  mm: {
    label: "mm",
    digits: 0,
    fromFeet: (ft) => (ft / FT_PER_M) * 1000,
    fromMetres: (m) => m * 1000
  }
};

function loadSavedUnit() {
  try {
    const saved = localStorage.getItem(UNIT_STORAGE_KEY);
    if (saved && UNITS[saved]) return saved;
  } catch (_) {}
  return "ft";
}

const state = {
  stationId: STATION_ID,
  station: null,
  latest: null,
  readings: [],
  range: "30d",
  page: 1,
  pageSize: 8,
  sortKey: "measurement_time",
  sortDir: "desc",
  unit: loadSavedUnit(),
  chart: null,
  rainChart: null,
  rawChart: null,
  forecastChart: null,
  chartResizeBound: false,
  weather: null
};

/** Operating bands in feet AMSL. */
const ZONES = {
  safeMax: 3200,
  warnMax: 3210,
  critMax: 3220,
  gaugeMin: 3180
};

function $(id) {
  return document.getElementById(id);
}

function validMm(mm) {
  return (
    mm != null &&
    mm !== "" &&
    Number(mm) !== UNAVAILABLE_MM &&
    Number.isFinite(Number(mm))
  );
}

function currentUnit() {
  return UNITS[state.unit] || UNITS.ft;
}

function formatNumber(value, digits) {
  if (value == null || !Number.isFinite(value)) return "—";
  return value.toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits
  });
}

function formatFeetValue(feet, { withUnit = true } = {}) {
  if (feet == null || !Number.isFinite(feet)) return "—";
  const u = currentUnit();
  const text = formatNumber(u.fromFeet(feet), u.digits);
  return withUnit ? `${text} ${u.label}` : text;
}

function formatMetresValue(metres, { withUnit = true } = {}) {
  if (metres == null || !Number.isFinite(metres)) return "—";
  const u = currentUnit();
  const text = formatNumber(u.fromMetres(metres), u.digits);
  return withUnit ? `${text} ${u.label}` : text;
}

function signedFormatFeet(deltaFeet) {
  if (deltaFeet == null || !Number.isFinite(deltaFeet)) return "—";
  const u = currentUnit();
  const v = u.fromFeet(deltaFeet);
  const sign = v > 0 ? "+" : "";
  return `${sign}${formatNumber(v, u.digits)} ${u.label}`;
}

/** Elevation in feet AMSL from a reading / latest row. */
function elevationFeet(row, station = state.station) {
  if (row == null) return null;

  if (row.water_level_m != null && row.water_level_m !== "") {
    const ft = Number(row.water_level_m);
    if (Number.isFinite(ft)) return ft;
  }
  if (validMm(row.water_level_mm) && row.sensor_level_mm != null) {
    return Number(row.water_level_mm) / 1000;
  }

  const actualMm = station?.calib_actual_mm;
  const gapAtCal = station?.calib_distance_mm;
  const gapNow = rawDistanceMm(row);
  if (validMm(actualMm) && validMm(gapAtCal) && validMm(gapNow)) {
    // Stored calib is feet*1000; gap delta is true mm → convert mm→feet.
    const actualFt = Number(actualMm) / 1000;
    const deltaFt = (Number(gapAtCal) - Number(gapNow)) / 304.8;
    return actualFt + deltaFt;
  }
  return null;
}

function rawDistanceMm(row) {
  if (row == null) return null;
  if (validMm(row.distance_mm)) return Number(row.distance_mm);
  if (row.distance_m != null) return Math.round(Number(row.distance_m) * 1000);
  return null;
}

function rawMetres(row) {
  const mm = rawDistanceMm(row);
  return mm == null ? null : mm / 1000;
}

function calibFeet(station = state.station) {
  if (!station || !validMm(station.calib_actual_mm)) return null;
  return Number(station.calib_actual_mm) / 1000;
}

function fmtTs(sec, { timeOnly = false, dateOnly = false } = {}) {
  if (sec == null || Number.isNaN(Number(sec))) return "—";
  const d = new Date(Number(sec) * 1000);
  if (dateOnly) {
    return d.toLocaleDateString(undefined, {
      day: "2-digit",
      month: "short",
      year: "numeric"
    });
  }
  if (timeOnly) {
    return d.toLocaleString(undefined, {
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
      hour12: true
    });
  }
  return d.toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    hour12: true
  });
}

function fmtAgeCounter(ageSec) {
  if (ageSec == null || !Number.isFinite(ageSec) || ageSec < 0) return "—";
  const s = Math.floor(ageSec);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

function parseReadingMap(map) {
  return Object.entries(map || {}).map(([key, v]) => {
    const row = { key, ...v };
    const ft = elevationFeet(row, state.station);
    row.display_level_ft = ft;
    return row;
  });
}

function rangeBounds(range) {
  const now = Date.now() / 1000;
  if (range === "24h") return { from: now - 86400, to: now };
  if (range === "7d") return { from: now - 7 * 86400, to: now };
  if (range === "30d") return { from: now - 30 * 86400, to: now };
  return { from: 0, to: now };
}

function filteredReadings() {
  const { from, to } = rangeBounds(state.range);
  let rows = state.readings.filter((r) => {
    const t = Number(r.measurement_time) || 0;
    return t >= from && t <= to;
  });
  rows.sort((a, b) => {
    const av = a[state.sortKey] ?? 0;
    const bv = b[state.sortKey] ?? 0;
    return state.sortDir === "asc" ? av - bv : bv - av;
  });
  return rows;
}

function readingsChrono() {
  return filteredReadings()
    .slice()
    .sort((a, b) => a.measurement_time - b.measurement_time);
}

function computeAnalytics() {
  const rows = readingsChrono()
    .map((r) => ({
      t: Number(r.measurement_time),
      ft: elevationFeet(r)
    }))
    .filter((r) => r.ft != null && Number.isFinite(r.t));

  if (!rows.length) {
    return {
      high: null,
      low: null,
      mean: null,
      swing: null,
      ratePerDay: null,
      count: 0,
      delta24h: null,
      highAt: null,
      lowAt: null
    };
  }

  let high = rows[0];
  let low = rows[0];
  let sum = 0;
  for (const r of rows) {
    sum += r.ft;
    if (r.ft > high.ft) high = r;
    if (r.ft < low.ft) low = r;
  }
  const mean = sum / rows.length;
  const swing = high.ft - low.ft;
  const spanSec = Math.max(1, rows[rows.length - 1].t - rows[0].t);
  const ratePerDay =
    ((rows[rows.length - 1].ft - rows[0].ft) / spanSec) * 86400;

  const now = Date.now() / 1000;
  const dayAgo = now - 86400;
  const recent = rows.filter((r) => r.t >= dayAgo);
  let delta24h = null;
  if (recent.length >= 2) {
    delta24h = recent[recent.length - 1].ft - recent[0].ft;
  } else if (rows.length >= 2) {
    delta24h = rows[rows.length - 1].ft - rows[0].ft;
  }

  return {
    high: high.ft,
    low: low.ft,
    mean,
    swing,
    ratePerDay,
    count: rows.length,
    delta24h,
    highAt: high.t,
    lowAt: low.t
  };
}

function syncUnitButtons() {
  document.querySelectorAll(".unit-btn").forEach((btn) => {
    const on = btn.dataset.unit === state.unit;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", String(on));
  });
  const unitEl = $("cardUnit");
  if (unitEl) unitEl.textContent = currentUnit().label;
}

function syncRangeButtons() {
  document.querySelectorAll(".range-btn").forEach((btn) => {
    const on = btn.dataset.range === state.range;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", String(on));
  });
}

function updateHeaderStatus(conn) {
  const el = $("firebaseStatus");
  const badge = $("badgeLive");
  if (!el) return;
  if (conn === "demo" || isDemoMode) {
    el.innerHTML = `<span class="status-dot" style="background:#b45309"></span> Demo`;
    if (badge) {
      badge.className = "badge badge-warn";
      badge.innerHTML = `<span class="dot"></span> Demo`;
    }
    return;
  }
  const live = conn === "connected";
  el.innerHTML = live
    ? `<span class="status-dot" style="background:#15803d"></span> Live`
    : `<span class="status-dot" style="background:#b45309"></span> Offline`;
  if (badge) {
    badge.className = live ? "badge badge-success" : "badge badge-warn";
    badge.innerHTML = live
      ? `<span class="dot"></span> Live`
      : `<span class="dot"></span> Offline`;
  }
}

function renderFreshnessCounter() {
  const latest = state.latest;
  const el = $("cardFreshness");
  if (!el) return;
  if (!latest) {
    el.textContent = "No data";
    return;
  }
  const ts = Number(latest.uploaded_at || latest.measurement_time);
  if (!Number.isFinite(ts) || ts <= 0) {
    el.textContent = "—";
    return;
  }
  el.textContent = fmtAgeCounter(Date.now() / 1000 - ts);
}

function trendLabel(delta24h) {
  if (delta24h == null || !Number.isFinite(delta24h)) return "—";
  if (Math.abs(delta24h) < 0.01) return "Steady";
  return delta24h > 0 ? "Rising" : "Falling";
}

function nextReadingLabel(latest) {
  if (!latest) return "—";
  const interval = Number(latest.send_interval_seconds) || 0;
  const measured = Number(latest.measurement_time);
  if (!interval || !Number.isFinite(measured) || measured <= 0) return "—";
  const due = measured + interval;
  const remain = Math.ceil(due - Date.now() / 1000);
  if (remain <= 0) return "Due now";
  const h = Math.floor(remain / 3600);
  const m = Math.floor((remain % 3600) / 60);
  const s = remain % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  return `${m}:${String(s).padStart(2, "0")}`;
}

function renderNextReadingCounter() {
  const heroNext = $("heroNext");
  if (heroNext) heroNext.textContent = nextReadingLabel(state.latest);
}

function renderChartSummary() {
  const a = computeAnalytics();
  const rangeLabel =
    state.range === "24h" ? "24h" : state.range === "7d" ? "7d" : "30d";

  const high = $("chartHigh");
  const low = $("chartLow");
  const delta = $("chartDelta");
  if (high) high.textContent = formatFeetValue(a.high);
  if (low) low.textContent = formatFeetValue(a.low);
  if (delta) delta.textContent = signedFormatFeet(a.delta24h);

  const deltaEl = $("heroDelta");
  if (deltaEl) deltaEl.textContent = signedFormatFeet(a.delta24h);

  const heroTrend = $("heroTrend");
  const heroHigh = $("heroHigh");
  const heroLow = $("heroLow");
  const heroNext = $("heroNext");
  if (heroTrend) heroTrend.textContent = trendLabel(a.delta24h);
  if (heroHigh) heroHigh.textContent = formatFeetValue(a.high);
  if (heroLow) heroLow.textContent = formatFeetValue(a.low);
  if (heroNext) heroNext.textContent = nextReadingLabel(state.latest);

  const sub = $("chartSubtitle");
  if (sub) {
    sub.textContent =
      rangeLabel === "24h"
        ? "24-hour reservoir elevation profile"
        : rangeLabel === "7d"
          ? "7-day reservoir elevation profile"
          : "30-day reservoir elevation profile";
  }
  const rawSub = $("rawChartSubtitle");
  if (rawSub) {
    rawSub.textContent = `Sensor gap · ${rangeLabel} window`;
  }
}

function setHeroClock(sec) {
  const dateEl = $("heroClockDate");
  const timeEl = $("heroClockTime");
  if (!dateEl || !timeEl) return;
  if (sec == null || Number.isNaN(Number(sec))) {
    dateEl.textContent = "Waiting for reading";
    timeEl.textContent = "—";
    return;
  }
  const d = new Date(Number(sec) * 1000);
  dateEl.textContent = d.toLocaleDateString(undefined, {
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric"
  });
  timeEl.textContent = d.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    hour12: true
  });
}

function formatRainMm(mm) {
  if (mm == null || !Number.isFinite(mm)) return "—";
  return `${mm.toFixed(mm >= 10 ? 0 : 1)} mm`;
}

function renderWeather(w) {
  if (!w) return;
  const icon = $("weatherIcon");
  if (icon) icon.textContent = weatherIcon(w.code);
  $("weatherTemp").textContent = Number.isFinite(w.tempC)
    ? `${Math.round(w.tempC)}°C`
    : "—";
  $("weatherDesc").textContent = weatherLabel(w.code);
  $("weatherHumidity").textContent = Number.isFinite(w.humidity)
    ? `${Math.round(w.humidity)}%`
    : "—";
  $("weatherWind").textContent = Number.isFinite(w.windKmh)
    ? `${Math.round(w.windKmh)} km/h`
    : "—";
  $("weatherRain24").textContent = formatRainMm(w.rain24h);
  $("weatherRainNext").textContent = formatRainMm(w.rainNext24h);
  $("weatherRain7").textContent = formatRainMm(w.rain7d);
  $("weatherUpdated").textContent = `Updated ${fmtAgeCounter(
    (Date.now() - w.fetchedAt) / 1000
  )}`;
}

async function loadWeather() {
  try {
    const w = await fetchUmiamWeather();
    state.weather = w;
    renderWeather(w);
    requestAnimationFrame(() => renderRainChart());
  } catch (e) {
    $("weatherDesc").textContent = "Weather unavailable";
    $("weatherUpdated").textContent = "Retry later";
    console.warn("Open-Meteo fetch failed", e);
  }
}

function renderOverview() {
  const latest = state.latest;
  const levelFt = elevationFeet(latest);
  const levelEl = $("cardLevel");
  const next = formatFeetValue(levelFt, { withUnit: false });
  if (levelEl && levelEl.textContent !== next) {
    levelEl.style.animation = "none";
    void levelEl.offsetWidth;
    levelEl.style.animation = "";
  }
  if (levelEl) levelEl.textContent = next;
  syncUnitButtons();
  syncRangeButtons();

  $("cardDistance").textContent = latest
    ? formatMetresValue(rawMetres(latest))
    : "—";
  $("cardCalib").textContent = formatFeetValue(calibFeet());
  setHeroClock(latest?.measurement_time);

  const sensor = latest
    ? SENSOR_STATUS[latest.status] || `Code ${latest.status}`
    : "—";
  const sensorOk = latest && latest.status === 0;
  $("cardSensor").innerHTML =
    latest == null
      ? "—"
      : `<span class="status-dot" style="background:${sensorOk ? "#15803d" : "#b45309"}"></span> ${sensor}`;

  const interval = latest?.send_interval_seconds || 0;
  $("intervalLabel").textContent = interval
    ? interval >= 3600
      ? `${(interval / 3600).toFixed(interval % 3600 === 0 ? 0 : 1)}h interval`
      : interval >= 60
        ? `${Math.round(interval / 60)}m interval`
        : `${interval}s interval`
    : "—";

  const age = latest
    ? Date.now() / 1000 - Number(latest.measurement_time)
    : null;
  const threshold = Math.max(120, (interval || 30) * 4);
  const zone = zoneForFeet(levelFt);
  let condition = "Waiting";
  let badgeClass = "badge badge-muted";
  if (age == null) {
    condition = "Waiting";
  } else if (latest.status !== 0) {
    condition = SENSOR_STATUS[latest.status] || "Error";
    badgeClass = "badge badge-warn";
  } else if (levelFt == null) {
    condition = "No level";
    badgeClass = "badge badge-warn";
  } else if (zone.key === "crit") {
    condition = "Critical";
    badgeClass = "badge badge-danger";
  } else if (zone.key === "warn") {
    condition = "Warning";
    badgeClass = "badge badge-warn";
  } else if (age > threshold) {
    condition = "Delayed";
    badgeClass = "badge badge-warn";
  } else {
    condition = "Safe";
    badgeClass = "badge badge-success";
  }
  $("dataStatusShort").textContent = condition;
  const badge = $("badgeCondition");
  if (badge) {
    badge.className = badgeClass;
    badge.textContent = condition;
  }

  renderFreshnessCounter();
  renderChartSummary();
}

function zoneForFeet(feet) {
  if (feet == null || !Number.isFinite(feet)) {
    return { key: "unknown", label: "—" };
  }
  if (feet < ZONES.safeMax) {
    return { key: "safe", label: "Safe" };
  }
  if (feet < ZONES.warnMax) {
    return { key: "warn", label: "Warning" };
  }
  return { key: "crit", label: "Critical" };
}

function chartSeries() {
  const u = currentUnit();
  return readingsChrono()
    .map((r) => {
      const ft = elevationFeet(r);
      if (ft == null) return null;
      const y = u.fromFeet(ft);
      return {
        x: Number(r.measurement_time) * 1000,
        y: Number(y.toFixed(Math.max(u.digits, 3)))
      };
    })
    .filter(Boolean);
}

function chartHeight() {
  const host = document.querySelector(".data-row .chart-host");
  const h = Math.floor(host?.getBoundingClientRect().height || 0);
  if (h >= 120) return Math.min(h, 520);
  return 280;
}

function smallChartHeight() {
  const hosts = document.querySelectorAll(".chart-host-sm");
  let h = 220;
  hosts.forEach((el) => {
    const measured = Math.floor(el.getBoundingClientRect().height || 0);
    if (measured > h) h = measured;
  });
  return Math.min(Math.max(h, 200), 360);
}

function renderChart() {
  const el = $("levelChart");
  if (!el || typeof ApexCharts === "undefined") return;
  const series = chartSeries();
  const height = chartHeight();
  const u = currentUnit();

  const options = {
    chart: {
      type: "area",
      height,
      width: "100%",
      fontFamily: "Poppins, sans-serif",
      background: "transparent",
      toolbar: { show: false },
      zoom: { enabled: false },
      parentHeightOffset: 0,
      animations: {
        enabled: true,
        easing: "easeinout",
        speed: 700,
        dynamicAnimation: { enabled: true, speed: 350 }
      }
    },
    series: [{ name: "Water level", data: series }],
    dataLabels: { enabled: false },
    stroke: { curve: "smooth", width: 2.5, colors: ["#004237"] },
    fill: {
      type: "gradient",
      gradient: {
        shadeIntensity: 1,
        type: "vertical",
        opacityFrom: 0.28,
        opacityTo: 0.02,
        colorStops: [
          { offset: 0, color: "#185a4d", opacity: 0.28 },
          { offset: 100, color: "#004237", opacity: 0.02 }
        ]
      }
    },
    markers: { size: 0, hover: { size: 5 } },
    grid: {
      borderColor: "rgba(191,201,196,0.7)",
      strokeDashArray: 3,
      padding: { left: 8, right: 8, top: 8, bottom: 0 }
    },
    xaxis: {
      type: "datetime",
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        datetimeUTC: false
      },
      axisBorder: { show: false },
      axisTicks: { show: false },
      tooltip: { enabled: false }
    },
    yaxis: {
      decimalsInFloat: u.digits,
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        formatter: (v) => `${formatNumber(v, u.digits)} ${u.label}`
      }
    },
    tooltip: {
      theme: "light",
      x: { format: "dd MMM hh:mm TT" },
      y: {
        formatter: (v) =>
          `${formatNumber(v, Math.max(u.digits, 3))} ${u.label}`
      }
    },
    colors: ["#004237"]
  };

  if (!state.chart) {
    state.chart = new ApexCharts(el, options);
    state.chart.render().then(() => {
      const host = document.querySelector(".chart-host");
      if (!host || state.chartResizeBound) return;
      state.chartResizeBound = true;
      let frame = 0;
      const ro = new ResizeObserver(() => {
        cancelAnimationFrame(frame);
        frame = requestAnimationFrame(() => {
          state.chart.updateOptions(
            { chart: { height: chartHeight() } },
            false,
            false
          );
        });
      });
      ro.observe(host);
    });
  } else {
    state.chart.updateOptions(
      {
        chart: { height },
        series: [{ name: "Water level", data: series }],
        yaxis: options.yaxis,
        tooltip: options.tooltip
      },
      true,
      true
    );
  }
}

function renderRainChart() {
  const el = $("rainChart");
  if (!el || typeof ApexCharts === "undefined") return;
  const daily = state.weather?.daily || [];
  const series = daily.map((d) => ({ x: d.t, y: Number(d.mm.toFixed(2)) }));
  const height = smallChartHeight();
  const options = {
    chart: {
      type: "bar",
      height,
      fontFamily: "Poppins, sans-serif",
      toolbar: { show: false },
      parentHeightOffset: 0
    },
    series: [{ name: "Rain", data: series }],
    plotOptions: {
      bar: { borderRadius: 4, columnWidth: "55%" }
    },
    dataLabels: { enabled: false },
    colors: ["#185a4d"],
    grid: {
      borderColor: "rgba(191,201,196,0.7)",
      strokeDashArray: 3,
      padding: { left: 4, right: 8, top: 6, bottom: 0 }
    },
    xaxis: {
      type: "datetime",
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        datetimeUTC: false,
        format: "dd MMM"
      },
      axisBorder: { show: false },
      axisTicks: { show: false }
    },
    yaxis: {
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        formatter: (v) => `${Number(v).toFixed(v >= 10 ? 0 : 1)} mm`
      }
    },
    tooltip: {
      theme: "light",
      x: { format: "dd MMM yyyy" },
      y: { formatter: (v) => `${Number(v).toFixed(1)} mm` }
    }
  };

  if (!state.rainChart) {
    state.rainChart = new ApexCharts(el, options);
    state.rainChart.render();
  } else {
    state.rainChart.updateOptions(
      { chart: { height }, series: [{ name: "Rain", data: series }] },
      true,
      true
    );
  }
}

function rawSeries() {
  const u = currentUnit();
  return readingsChrono()
    .map((r) => {
      const m = rawMetres(r);
      if (m == null) return null;
      return {
        x: Number(r.measurement_time) * 1000,
        y: Number(u.fromMetres(m).toFixed(Math.max(u.digits, 3)))
      };
    })
    .filter(Boolean);
}

function renderRawChart() {
  const el = $("rawChart");
  if (!el || typeof ApexCharts === "undefined") return;
  const series = rawSeries();
  const height = smallChartHeight();
  const u = currentUnit();
  const options = {
    chart: {
      type: "area",
      height,
      fontFamily: "Poppins, sans-serif",
      toolbar: { show: false },
      parentHeightOffset: 0,
      animations: { enabled: true, speed: 500 }
    },
    series: [{ name: "Raw level", data: series }],
    dataLabels: { enabled: false },
    stroke: { curve: "smooth", width: 2.2, colors: ["#4c635c"] },
    fill: {
      type: "gradient",
      gradient: {
        shadeIntensity: 1,
        type: "vertical",
        opacityFrom: 0.22,
        opacityTo: 0.02,
        colorStops: [
          { offset: 0, color: "#4c635c", opacity: 0.22 },
          { offset: 100, color: "#4c635c", opacity: 0.02 }
        ]
      }
    },
    markers: { size: 0, hover: { size: 4 } },
    grid: {
      borderColor: "rgba(191,201,196,0.7)",
      strokeDashArray: 3,
      padding: { left: 4, right: 8, top: 6, bottom: 0 }
    },
    xaxis: {
      type: "datetime",
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        datetimeUTC: false
      },
      axisBorder: { show: false },
      axisTicks: { show: false }
    },
    yaxis: {
      decimalsInFloat: u.digits,
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        formatter: (v) => `${formatNumber(v, u.digits)} ${u.label}`
      }
    },
    tooltip: {
      theme: "light",
      x: { format: "dd MMM hh:mm TT" },
      y: {
        formatter: (v) =>
          `${formatNumber(v, Math.max(u.digits, 3))} ${u.label}`
      }
    },
    colors: ["#4c635c"]
  };

  if (!state.rawChart) {
    state.rawChart = new ApexCharts(el, options);
    state.rawChart.render();
  } else {
    state.rawChart.updateOptions(
      {
        chart: { height },
        series: [{ name: "Raw level", data: series }],
        yaxis: options.yaxis,
        tooltip: options.tooltip
      },
      true,
      true
    );
  }
}

function statusPill(status) {
  const label = SENSOR_STATUS[status] || status;
  const cls =
    status === 0 ? "status-pill" : status === 1 ? "status-pill warn" : "status-pill err";
  return `<span class="${cls}">${label}</span>`;
}

function renderTable() {
  const rows = filteredReadings();
  const pages = Math.max(1, Math.ceil(rows.length / state.pageSize));
  if (state.page > pages) state.page = pages;
  const start = (state.page - 1) * state.pageSize;
  const pageRows = rows.slice(start, start + state.pageSize);

  $("readingsTable").querySelector("tbody").innerHTML = pageRows
    .map((r) => {
      const ft = elevationFeet(r);
      return `<tr>
        <td>${fmtTs(r.measurement_time, { dateOnly: true })}</td>
        <td>${fmtTs(r.measurement_time, { timeOnly: true })}</td>
        <td class="num mono">${formatFeetValue(ft)}</td>
        <td class="num mono muted">${formatMetresValue(rawMetres(r))}</td>
        <td class="num">${statusPill(r.status)}</td>
      </tr>`;
    })
    .join("");

  $("pageInfo").textContent = `${rows.length}`;
  const from = rows.length === 0 ? 0 : start + 1;
  const to = start + pageRows.length;
  $("paginationInfo").textContent =
    rows.length === 0
      ? "No readings in range"
      : `Showing ${from}–${to} of ${rows.length}`;

  const latest = rows[0];
  $("tableDay").textContent = latest
    ? new Date(Number(latest.measurement_time) * 1000).toLocaleDateString(
        undefined,
        { day: "numeric", month: "short", year: "numeric" }
      )
    : "—";

  $("prevPage").disabled = state.page <= 1;
  $("nextPage").disabled = state.page >= pages;
}

function forecastSeries() {
  const u = currentUnit();
  const chrono = readingsChrono().filter((r) => elevationFeet(r) != null);
  if (chrono.length < 2) {
    return { observed: [], forecast: [], note: "Need more readings for forecast" };
  }
  const observed = chrono.map((r) => {
    const ft = elevationFeet(r);
    return {
      x: Number(r.measurement_time) * 1000,
      y: Number(u.fromFeet(ft).toFixed(Math.max(u.digits, 3)))
    };
  });
  const windowPts = chrono.slice(-Math.min(12, chrono.length));
  const first = windowPts[0];
  const last = windowPts[windowPts.length - 1];
  const dtH =
    (Number(last.measurement_time) - Number(first.measurement_time)) / 3600;
  const dFt = elevationFeet(last) - elevationFeet(first);
  const rateFtPerH = dtH > 0.05 ? dFt / dtH : 0;
  const lastFt = elevationFeet(last);
  const lastT = Number(last.measurement_time) * 1000;
  const horizonH = 24;
  const steps = 8;
  const forecast = [{ x: lastT, y: Number(u.fromFeet(lastFt).toFixed(u.digits + 1)) }];
  for (let i = 1; i <= steps; i++) {
    const h = (horizonH * i) / steps;
    const ft = lastFt + rateFtPerH * h;
    forecast.push({
      x: lastT + h * 3600 * 1000,
      y: Number(u.fromFeet(ft).toFixed(Math.max(u.digits, 3)))
    });
  }
  const sign = rateFtPerH >= 0 ? "+" : "";
  const note = `Trend ${sign}${formatFeetValue(rateFtPerH, { withUnit: true })}/h · 24h outlook`;
  return { observed, forecast, note };
}

function renderForecastChart() {
  const el = $("forecastChart");
  if (!el || typeof ApexCharts === "undefined") return;
  const u = currentUnit();
  const { observed, forecast, note } = forecastSeries();
  const noteEl = $("forecastNote");
  if (noteEl) noteEl.textContent = note;
  const height = Math.min(
    Math.max(
      Math.floor(
        document.querySelector(".chart-host-md")?.getBoundingClientRect()
          .height || 300
      ),
      260
    ),
    420
  );
  const annotations = {
    yaxis: [
      {
        y: u.fromFeet(ZONES.safeMax),
        borderColor: "#16a34a",
        strokeDashArray: 4,
        label: {
          text: "Safe max",
          style: { color: "#14532d", background: "#dcfce7", fontSize: "11px" }
        }
      },
      {
        y: u.fromFeet(ZONES.warnMax),
        borderColor: "#d97706",
        strokeDashArray: 4,
        label: {
          text: "Warning max",
          style: { color: "#78350f", background: "#fef3c7", fontSize: "11px" }
        }
      },
      {
        y: u.fromFeet(ZONES.critMax),
        borderColor: "#b91c1c",
        strokeDashArray: 4,
        label: {
          text: "Critical max",
          style: { color: "#7f1d1d", background: "#fee2e2", fontSize: "11px" }
        }
      }
    ]
  };
  const options = {
    chart: {
      type: "line",
      height,
      fontFamily: "Poppins, sans-serif",
      toolbar: { show: false },
      zoom: { enabled: false },
      parentHeightOffset: 0,
      animations: { enabled: true, speed: 600 }
    },
    series: [
      { name: "Observed", data: observed },
      { name: "Forecast (24h)", data: forecast }
    ],
    stroke: {
      curve: "smooth",
      width: [2.5, 2],
      dashArray: [0, 6]
    },
    colors: ["#004237", "#b45309"],
    dataLabels: { enabled: false },
    markers: { size: 0, hover: { size: 4 } },
    grid: {
      borderColor: "rgba(191,201,196,0.7)",
      strokeDashArray: 3,
      padding: { left: 8, right: 8, top: 12, bottom: 0 }
    },
    legend: {
      position: "top",
      horizontalAlign: "right",
      fontSize: "12px",
      fontWeight: 500
    },
    xaxis: {
      type: "datetime",
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        datetimeUTC: false
      },
      axisBorder: { show: false },
      axisTicks: { show: false }
    },
    yaxis: {
      decimalsInFloat: u.digits,
      labels: {
        style: { colors: "#707975", fontSize: "11px", fontWeight: 500 },
        formatter: (v) => `${formatNumber(v, u.digits)} ${u.label}`
      }
    },
    tooltip: {
      theme: "light",
      x: { format: "dd MMM hh:mm TT" },
      y: {
        formatter: (v) =>
          `${formatNumber(v, Math.max(u.digits, 3))} ${u.label}`
      }
    },
    annotations
  };

  if (!state.forecastChart) {
    state.forecastChart = new ApexCharts(el, options);
    state.forecastChart.render();
  } else {
    state.forecastChart.updateOptions(
      {
        chart: { height },
        series: options.series,
        yaxis: options.yaxis,
        tooltip: options.tooltip,
        annotations
      },
      true,
      true
    );
  }
}

function refreshViews() {
  state.readings = state.readings.map((row) => {
    const ft = elevationFeet(row, state.station);
    return { ...row, display_level_ft: ft };
  });
  renderOverview();
  renderTable();
  requestAnimationFrame(() => {
    renderChart();
    renderRawChart();
    renderRainChart();
    renderForecastChart();
  });
}

function bindUi() {
  document.querySelectorAll(".range-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.range = btn.dataset.range;
      state.page = 1;
      refreshViews();
    });
  });

  document.querySelectorAll(".unit-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const next = btn.dataset.unit;
      if (!UNITS[next]) return;
      state.unit = next;
      try {
        localStorage.setItem(UNIT_STORAGE_KEY, next);
      } catch (_) {}
      refreshViews();
    });
  });

  $("prevPage").addEventListener("click", () => {
    if (state.page > 1) {
      state.page -= 1;
      renderTable();
    }
  });
  $("nextPage").addEventListener("click", () => {
    state.page += 1;
    renderTable();
  });

  $("readingsTable").querySelectorAll("th[data-sort]").forEach((th) => {
    th.addEventListener("click", () => {
      const key = th.dataset.sort;
      if (state.sortKey === key) {
        state.sortDir = state.sortDir === "asc" ? "desc" : "asc";
      } else {
        state.sortKey = key;
        state.sortDir = "desc";
      }
      renderTable();
    });
  });

  $("exportCsv").addEventListener("click", () => {
    const rows = filteredReadings();
    const u = currentUnit();
    const lines = [
      `measurement_time,time_12h,water_level_${u.label},raw_level_${u.label},status,boot_id,seq`
    ];
    for (const r of rows) {
      const ft = elevationFeet(r);
      const rawM = rawMetres(r);
      const level =
        ft == null ? "" : currentUnit().fromFeet(ft).toFixed(Math.max(u.digits, 3));
      const raw =
        rawM == null
          ? ""
          : currentUnit().fromMetres(rawM).toFixed(Math.max(u.digits, 3));
      lines.push(
        [
          r.measurement_time,
          `"${fmtTs(r.measurement_time)}"`,
          level,
          raw,
          r.status,
          r.boot_id ?? "",
          r.seq ?? ""
        ].join(",")
      );
    }
    const blob = new Blob([lines.join("\n")], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "umiam_dam_readings.csv";
    a.click();
    URL.revokeObjectURL(url);
  });
}

async function boot() {
  initFirebase();
  if (isDemoMode) {
    $("demoBanner").classList.remove("hidden");
    updateHeaderStatus("demo");
  }
  bindUi();
  syncUnitButtons();
  syncRangeButtons();
  listenConnection(updateHeaderStatus);

  listenStations((stations) => {
    state.station = stations?.[state.stationId] || null;
    refreshViews();
  });

  listenLatest(state.stationId, (latest) => {
    state.latest = latest;
    refreshViews();
  });

  listenReadings(state.stationId, (map) => {
    state.readings = parseReadingMap(map);
    refreshViews();
  });

  void loadWeather();
  setInterval(() => {
    renderFreshnessCounter();
    renderNextReadingCounter();
    if (state.weather) renderWeather(state.weather);
  }, 1000);
  // Refresh forecast periodically (Open-Meteo is free / no key).
  setInterval(() => void loadWeather(), 15 * 60 * 1000);
}

boot();

export {
  SENSOR_STATUS,
  parseReadingMap,
  rangeBounds,
  elevationFeet,
  formatFeetValue
};
