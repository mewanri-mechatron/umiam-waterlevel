import {
  initFirebase,
  isDemoMode,
  listenStations,
  listenLatest,
  loadReadings,
  listenConnection
} from "./firebase.js";

const SENSOR_STATUS = {
  0: "OK",
  1: "Too close",
  2: "No echo",
  3: "No response"
};

const STATION_ID = "station_001";

const state = {
  stationId: STATION_ID,
  latest: null,
  readings: [],
  range: "24h",
  page: 1,
  pageSize: 8,
  sortKey: "measurement_time",
  sortDir: "desc",
  chart: null
};

function $(id) {
  return document.getElementById(id);
}

function fmtTs(sec) {
  if (sec == null || Number.isNaN(Number(sec))) return "—";
  return new Date(Number(sec) * 1000).toLocaleString();
}

function fmtLevel(mm) {
  if (mm == null || mm === 65535) return "Unavailable";
  return (mm / 1000).toFixed(2);
}

function fmtDistance(mm) {
  if (mm == null || mm === 65535) return "Unavailable";
  return `${mm} mm`;
}

function parseReadingMap(map) {
  return Object.entries(map || {}).map(([key, v]) => ({ key, ...v }));
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

function updateHeaderStatus(conn) {
  const el = $("firebaseStatus");
  if (conn === "demo" || isDemoMode) {
    el.textContent = "Demo";
    return;
  }
  el.textContent = conn === "connected" ? "Live" : "Offline";
}

function renderOverview() {
  const latest = state.latest;
  const levelEl = $("cardLevel");
  const next = latest ? `${fmtLevel(latest.water_level_mm)}` : "—";
  if (levelEl.textContent !== next) {
    levelEl.style.animation = "none";
    // restart CSS rise animation
    void levelEl.offsetWidth;
    levelEl.style.animation = "";
  }
  levelEl.textContent = next;

  $("cardDistance").textContent = latest ? fmtDistance(latest.distance_mm) : "—";
  $("cardMeasured").textContent = latest
    ? `Updated ${fmtTs(latest.measurement_time)}`
    : "Waiting for first reading";
  $("cardSensor").textContent = latest
    ? SENSOR_STATUS[latest.status] || `Code ${latest.status}`
    : "—";
  $("cardUpload").textContent = latest
    ? new Date(Number(latest.uploaded_at || latest.received_time) * 1000).toLocaleTimeString()
    : "—";

  const interval = latest?.send_interval_seconds || 30;
  const age = latest ? Date.now() / 1000 - Number(latest.measurement_time) : null;
  const threshold = interval * 4;
  if (age == null) {
    $("cardFreshness").textContent = "No data";
    $("dataStatusShort").textContent = "Waiting";
  } else if (latest.status !== 0) {
    $("cardFreshness").textContent = `${Math.round(age)}s ago`;
    $("dataStatusShort").textContent = SENSOR_STATUS[latest.status] || "Error";
  } else if (age <= threshold) {
    $("cardFreshness").textContent = `${Math.round(age)}s ago`;
    $("dataStatusShort").textContent = "Normal";
  } else {
    $("cardFreshness").textContent = `${Math.round(age / 60)}m ago`;
    $("dataStatusShort").textContent = "Delayed";
  }
}

function chartSeries() {
  return filteredReadings()
    .slice()
    .sort((a, b) => a.measurement_time - b.measurement_time)
    .filter((r) => r.water_level_mm != null && r.water_level_mm !== 65535)
    .map((r) => ({
      x: Number(r.measurement_time) * 1000,
      y: Number((r.water_level_mm / 1000).toFixed(3))
    }));
}

function chartHeight() {
  const host = document.querySelector(".chart-host");
  const h = Math.floor(host?.getBoundingClientRect().height || 0);
  // Measure the host, never the ApexCharts canvas (avoids resize feedback loops).
  if (h >= 80) return Math.min(h, 900);
  return 220;
}

function renderChart() {
  const el = $("levelChart");
  const series = chartSeries();
  const height = chartHeight();

  const options = {
    chart: {
      type: "area",
      height,
      width: "100%",
      fontFamily: "Outfit, sans-serif",
      background: "transparent",
      toolbar: { show: false },
      zoom: { enabled: false },
      parentHeightOffset: 0,
      animations: {
        enabled: true,
        easing: "easeinout",
        speed: 1100,
        animateGradually: { enabled: true, delay: 45 },
        dynamicAnimation: { enabled: true, speed: 480 }
      },
      dropShadow: {
        enabled: true,
        top: 8,
        left: 0,
        blur: 14,
        color: "#067a63",
        opacity: 0.28
      }
    },
    series: [{ name: "Water level", data: series }],
    dataLabels: { enabled: false },
    stroke: {
      curve: "smooth",
      width: 3.4,
      colors: ["#067a63"]
    },
    fill: {
      type: "gradient",
      gradient: {
        shadeIntensity: 1,
        type: "vertical",
        opacityFrom: 0.55,
        opacityTo: 0.02,
        colorStops: [
          { offset: 0, color: "#12b894", opacity: 0.55 },
          { offset: 55, color: "#067a63", opacity: 0.18 },
          { offset: 100, color: "#034d42", opacity: 0.02 }
        ]
      }
    },
    markers: {
      size: 0,
      strokeWidth: 0,
      hover: { size: 6, sizeOffset: 2 }
    },
    grid: {
      borderColor: "rgba(12,31,26,0.08)",
      strokeDashArray: 3,
      padding: { left: 4, right: 8, top: 6, bottom: 0 }
    },
    xaxis: {
      type: "datetime",
      labels: {
        style: { colors: "#4f6a60", fontSize: "11px", fontWeight: 600 },
        datetimeUTC: false
      },
      axisBorder: { show: false },
      axisTicks: { show: false },
      tooltip: { enabled: false }
    },
    yaxis: {
      decimalsInFloat: 2,
      labels: {
        style: { colors: "#4f6a60", fontSize: "11px", fontWeight: 600 },
        formatter: (v) => `${Number(v).toFixed(2)} m`
      }
    },
    tooltip: {
      theme: "light",
      x: { format: "dd MMM HH:mm" },
      y: { formatter: (v) => `${Number(v).toFixed(3)} m` }
    },
    colors: ["#067a63"]
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
          const h = chartHeight();
          state.chart.updateOptions({ chart: { height: h } }, false, false);
        });
      });
      ro.observe(host);
    });
  } else {
    state.chart.updateOptions(
      {
        chart: { height },
        series: [{ name: "Water level", data: series }]
      },
      true,
      true
    );
  }
}

function renderTable() {
  const rows = filteredReadings();
  const pages = Math.max(1, Math.ceil(rows.length / state.pageSize));
  if (state.page > pages) state.page = pages;
  const start = (state.page - 1) * state.pageSize;
  const pageRows = rows.slice(start, start + state.pageSize);
  $("readingsTable").querySelector("tbody").innerHTML = pageRows
    .map(
      (r) => `<tr>
      <td>${fmtTs(r.measurement_time)}</td>
      <td>${fmtLevel(r.water_level_mm)} m</td>
      <td>${SENSOR_STATUS[r.status] || r.status}</td>
    </tr>`
    )
    .join("");
  $("pageInfo").textContent = `${rows.length}`;
}

function refreshViews() {
  renderOverview();
  renderTable();
  // Wait a frame so .chart-host has a real laid-out height.
  requestAnimationFrame(() => renderChart());
}

async function loadStationData() {
  const map = await loadReadings(state.stationId);
  state.readings = parseReadingMap(map);
  refreshViews();
}

function bindUi() {
  document.querySelectorAll(".range-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".range-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      state.range = btn.dataset.range;
      state.page = 1;
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
      if (state.sortKey === key) state.sortDir = state.sortDir === "asc" ? "desc" : "asc";
      else {
        state.sortKey = key;
        state.sortDir = "desc";
      }
      renderTable();
    });
  });

  $("exportCsv").addEventListener("click", () => {
    const rows = filteredReadings();
    const lines = ["measurement_time,water_level_mm,distance_mm,status"];
    for (const r of rows) {
      lines.push([r.measurement_time, r.water_level_mm, r.distance_mm, r.status].join(","));
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
  listenConnection(updateHeaderStatus);
  // Single-station system: still listen so live Firebase updates work.
  listenStations(() => {});
  listenLatest(state.stationId, (latest) => {
    state.latest = latest;
    refreshViews();
  });
  await loadStationData();
}

boot();

export { SENSOR_STATUS, parseReadingMap, rangeBounds, fmtLevel };
