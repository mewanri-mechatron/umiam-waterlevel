import { initializeApp } from "https://www.gstatic.com/firebasejs/11.6.0/firebase-app.js";
import {
  getDatabase,
  ref,
  query,
  orderByChild,
  startAt,
  limitToLast,
  onValue,
  get,
} from "https://www.gstatic.com/firebasejs/11.6.0/firebase-database.js";

const STATION_ID = "station_001";
/** Lines fetched per phone for the selected period. */
const LOGS_PER_PHONE = 3000;
/** Rows drawn in the table (the CSV contains every filtered row). */
const MAX_ROWS_SHOWN = 1500;
/** A phone that has not reported for this long is shown as offline. */
const OFFLINE_AFTER_MS = 30 * 60 * 1000;
const SEQ_MOD = 65536;

const $ = (id) => document.getElementById(id);
const phonesEl = $("phones");
const phoneCountEl = $("phoneCount");
const logsEl = $("logs");
const countsEl = $("logCounts");
const dataCheckEl = $("dataCheck");
const f = {
  phone: $("fPhone"),
  level: $("fLevel"),
  category: $("fCategory"),
  range: $("fRange"),
  text: $("fText"),
};

function showTab(name) {
  for (const tab of document.querySelectorAll(".phones-tab")) {
    const on = tab.dataset.tab === name;
    tab.classList.toggle("active", on);
    tab.setAttribute("aria-selected", on ? "true" : "false");
  }
  for (const panel of document.querySelectorAll(".phones-panel")) {
    panel.classList.toggle("hidden", panel.id !== `panel-${name}`);
  }
}

document.querySelectorAll(".phones-tab").forEach((tab) => {
  tab.addEventListener("click", () => showTab(tab.dataset.tab));
});

const cfg = window.WATERLEVEL_FIREBASE || {};
const db = getDatabase(initializeApp(cfg.config));

let devices = {};
/** deviceId → array of log rows */
const logsByPhone = new Map();
/** deviceId → unsubscribe */
const logSubs = new Map();
let subscribedRangeHours = null;

const esc = (v) =>
  String(v ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[c]);

function ago(ms) {
  if (!ms) return "—";
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h} h ${m % 60} min ago`;
  return `${Math.floor(h / 24)} d ${h % 24} h ago`;
}

function clock(ms) {
  if (!ms) return "—";
  return new Date(ms).toLocaleString("en-IN", {
    day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

function span(seconds) {
  const m = Math.round(seconds / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} h ${m % 60} min`;
  return `${Math.floor(h / 24)} d ${h % 24} h`;
}

const badge = (text, kind) => `<span class="ph-badge ${kind}">${esc(text)}</span>`;
const phoneName = (id) => devices[id]?.name || devices[id]?.model || id;
const lastSeenMs = (d) =>
  typeof d.last_seen === "number" ? d.last_seen : d.last_seen_phone || 0;

// ---------------------------------------------------------------- phones

function renderPhones() {
  const list = Object.values(devices)
    .filter((d) => d && d.device_id)
    .sort((a, b) => lastSeenMs(b) - lastSeenMs(a));
  if (phoneCountEl) {
    phoneCountEl.textContent = list.length
      ? `${list.length} phone${list.length === 1 ? "" : "s"}`
      : "None yet";
  }
  if (!list.length) {
    phonesEl.innerHTML =
      '<p class="ph-empty">No phones have reported yet. A phone reports after the new app version is installed and it has internet.</p>';
    return;
  }
  phonesEl.innerHTML = list.map((d) => {
    const seen = lastSeenMs(d);
    const offline = !seen || Date.now() - seen > OFFLINE_AFTER_MS;
    const waiting = Number(d.readings_waiting || 0);
    const phoneNewest = d.newest_reading_on_phone ? d.newest_reading_on_phone * 1000 : 0;
    const cloudNewest = d.newest_reading_in_cloud ? d.newest_reading_in_cloud * 1000 : 0;
    const lagMin = phoneNewest && cloudNewest
      ? Math.max(0, Math.round((phoneNewest - cloudNewest) / 60000)) : 0;
    const storageLow = typeof d.free_storage_mb === "number" &&
      d.free_storage_mb >= 0 && d.free_storage_mb < 300;
    const badges = [
      offline ? badge(`Not reporting · ${ago(seen)}`, "bad") : badge("Reporting", "ok"),
      waiting > 0
        ? badge(`${waiting} waiting to send`, lagMin > 120 ? "bad" : "warn")
        : badge("All sent", "ok"),
      d.on_sensor_wifi ? badge("On sensor WiFi", "ok") : badge("Not on sensor WiFi", "warn"),
      d.service_running === false ? badge("Background service stopped", "bad") : "",
      storageLow ? badge(`Storage low · ${d.free_storage_mb} MB`, "bad") : "",
      d.battery_unrestricted === false ? badge("Battery restricted", "warn") : "",
      d.notifications_on === false ? badge("Notifications off", "warn") : "",
      d.location_permission === false ? badge("No location permission", "bad") : "",
      d.wifi_on === false ? badge("WiFi off", "warn") : "",
    ].join("");
    return `
      <article class="ph-card ${d.device_id === f.phone.value ? "selected" : ""}" data-id="${esc(d.device_id)}">
        <h3>${esc(phoneName(d.device_id))}</h3>
        <p class="ph-sub">ID ${esc(d.device_id)} · ${esc(d.model)} · Android ${esc(d.android)} · app ${esc(d.app_version)}</p>
        <div>${badges}</div>
        <div class="ph-stats">
          <div><span>Last report</span><strong>${esc(ago(seen))}</strong></div>
          <div><span>Battery</span><strong>${d.battery_pct >= 0 ? esc(d.battery_pct) + "%" : "—"}${d.charging ? " · charging" : ""}</strong></div>
          <div><span>Newest reading on phone</span><strong>${esc(clock(phoneNewest))}</strong></div>
          <div><span>Newest reading at office</span><strong>${esc(clock(cloudNewest))}</strong></div>
          <div><span>Office behind by</span><strong>${waiting > 0 && lagMin > 0 ? esc(span(lagMin * 60)) : "—"}</strong></div>
          <div><span>Free storage</span><strong>${d.free_storage_mb >= 0 ? esc(d.free_storage_mb) + " MB" : "—"}</strong></div>
        </div>
      </article>`;
  }).join("");
}

function refreshPhoneFilter() {
  const current = f.phone.value;
  const ids = Object.keys(devices).sort((a, b) => phoneName(a).localeCompare(phoneName(b)));
  f.phone.innerHTML = '<option value="">All phones</option>' +
    ids.map((id) => `<option value="${esc(id)}">${esc(phoneName(id))} (${esc(id)})</option>`).join("");
  f.phone.value = ids.includes(current) ? current : "";
}

// ------------------------------------------------------------------ logs

function subscribeLogs() {
  const hours = Number(f.range.value);
  const since = Date.now() - hours * 3600 * 1000;
  const ids = Object.keys(devices);
  if (hours !== subscribedRangeHours) {
    for (const stop of logSubs.values()) stop();
    logSubs.clear();
    logsByPhone.clear();
    subscribedRangeHours = hours;
  }
  for (const id of ids) {
    if (logSubs.has(id)) continue;
    const q = query(
      ref(db, `water/logs/${id}`),
      orderByChild("created_at"),
      startAt(since),
      limitToLast(LOGS_PER_PHONE),
    );
    logSubs.set(id, onValue(q, (snap) => {
      const rows = Object.values(snap.val() || {}).map((r) => ({ ...r, device_id: id }));
      logsByPhone.set(id, rows);
      refreshCategoryFilter();
      renderLogs();
    }, (err) => {
      logsEl.innerHTML = `<p class="ph-empty">Could not load logs: ${esc(err.message)}</p>`;
    }));
  }
  if (!ids.length) renderLogs();
}

function allRows() {
  return [...logsByPhone.values()].flat();
}

function refreshCategoryFilter() {
  const current = f.category.value;
  const cats = [...new Set(allRows().map((r) => r.category).filter(Boolean))].sort();
  f.category.innerHTML = '<option value="">All areas</option>' +
    cats.map((c) => `<option value="${esc(c)}">${esc(c)}</option>`).join("");
  f.category.value = cats.includes(current) ? current : "";
}

function filteredRows() {
  const phone = f.phone.value;
  const level = f.level.value;
  const cat = f.category.value;
  const text = f.text.value.trim().toLowerCase();
  const since = Date.now() - Number(f.range.value) * 3600 * 1000;
  return allRows()
    .filter((r) => r.created_at >= since)
    .filter((r) => !phone || r.device_id === phone)
    .filter((r) => !level ||
      (level === "error" ? r.level === "error"
        : level === "info" ? r.level === "info"
        : r.level === "warn" || r.level === "error"))
    .filter((r) => !cat || r.category === cat)
    .filter((r) => !text ||
      `${r.message} ${r.detail || ""} ${phoneName(r.device_id)}`.toLowerCase().includes(text))
    .sort((a, b) => b.created_at - a.created_at);
}

function renderLogs() {
  const rows = filteredRows();
  const errors = rows.filter((r) => r.level === "error").length;
  const warns = rows.filter((r) => r.level === "warn").length;
  countsEl.innerHTML = `<b>${rows.length}</b> lines · <b>${errors}</b> errors · <b>${warns}</b> warnings` +
    (rows.length > MAX_ROWS_SHOWN ? ` · showing newest ${MAX_ROWS_SHOWN} (CSV has all)` : "");
  if (!rows.length) {
    logsEl.innerHTML = '<p class="ph-empty">No log lines match these filters.</p>';
    return;
  }
  const showPhone = !f.phone.value;
  logsEl.innerHTML = `
    <div class="ph-table-wrap"><table class="ph-table">
      <thead><tr><th>Time</th>${showPhone ? "<th>Phone</th>" : ""}<th>Level</th><th>Area</th><th>What happened</th><th>Detail</th></tr></thead>
      <tbody>${rows.slice(0, MAX_ROWS_SHOWN).map((r) => `
        <tr>
          <td class="nowrap">${esc(clock(r.created_at))}</td>
          ${showPhone ? `<td class="nowrap">${esc(phoneName(r.device_id))}</td>` : ""}
          <td>${badge(r.level, r.level === "error" ? "bad" : r.level === "warn" ? "warn" : "info")}</td>
          <td>${esc(r.category)}</td>
          <td>${esc(r.message)}</td>
          <td class="detail">${esc(r.detail)}</td>
        </tr>`).join("")}
      </tbody>
    </table></div>`;
}

function downloadCsv() {
  const rows = filteredRows();
  const cell = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const lines = [
    ["time", "phone", "phone_id", "level", "area", "message", "detail"].join(","),
    ...rows.map((r) => [
      new Date(r.created_at).toISOString(), phoneName(r.device_id), r.device_id,
      r.level, r.category, r.message, r.detail,
    ].map(cell).join(",")),
  ];
  const blob = new Blob([lines.join("\n")], { type: "text/csv" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `waterlevel-logs-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}

// ------------------------------------------------------------ data check

async function runDataCheck() {
  const days = Number($("dcRange").value);
  const sinceSec = Math.floor(Date.now() / 1000) - days * 86400;
  dataCheckEl.innerHTML = '<p class="ph-empty">Checking…</p>';
  try {
    const node = ref(db, `water/readings/${STATION_ID}`);
    let snap;
    try {
      snap = await get(query(node, orderByChild("measurement_time"), startAt(sinceSec)));
    } catch (err) {
      // Until the database index rule is deployed, load everything and filter here.
      if (!String(err.message).includes("Index not defined")) throw err;
      snap = await get(node);
    }
    const rows = Object.values(snap.val() || {})
      .filter((r) => typeof r.seq === "number" && typeof r.boot_id === "number")
      .filter((r) => r.measurement_time >= sinceSec);
    dataCheckEl.innerHTML = renderDataCheck(rows, days);
  } catch (err) {
    dataCheckEl.innerHTML = `<p class="ph-empty">Could not run the check: ${esc(err.message)}</p>`;
  }
}

function renderDataCheck(rows, days) {
  if (!rows.length) {
    return `<p class="ph-empty">No readings reached the office in the last ${days} day(s).</p>`;
  }
  rows.sort((a, b) => a.boot_id - b.boot_id || a.seq - b.seq);
  const gaps = [];
  const badTimes = [];
  for (let i = 1; i < rows.length; i++) {
    const prev = rows[i - 1];
    const cur = rows[i];
    if (cur.boot_id !== prev.boot_id) continue;
    const step = (cur.seq - prev.seq + SEQ_MOD) % SEQ_MOD;
    if (step > 1) {
      gaps.push({ from: prev, to: cur, missing: step - 1 });
    }
    const interval = Math.max(10, Number(cur.send_interval_seconds || prev.send_interval_seconds || 0));
    const dt = cur.measurement_time - prev.measurement_time;
    const expected = interval * step;
    if (dt <= 0 || Math.abs(dt - expected) > Math.max(300, expected * 0.5)) {
      badTimes.push({ prev, cur, dt, expected });
    }
  }
  const newest = Math.max(...rows.map((r) => r.measurement_time));
  const silence = Math.floor(Date.now() / 1000) - newest;
  const interval = Number(rows[rows.length - 1].send_interval_seconds || 3600);
  const late = silence > interval * 2 + 600;
  const missingTotal = gaps.reduce((n, g) => n + g.missing, 0);
  const reboots = new Set(rows.map((r) => r.boot_id)).size - 1;

  const summary = `
    <div class="ph-summary">
      <div><span>Readings at office</span><strong>${rows.length}</strong></div>
      <div class="${missingTotal ? "bad" : "ok"}"><span>Missing (sequence gaps)</span><strong>${missingTotal}</strong></div>
      <div class="${badTimes.length ? "bad" : "ok"}"><span>Suspicious times</span><strong>${badTimes.length}</strong></div>
      <div class="${late ? "bad" : "ok"}"><span>Newest reading</span><strong>${esc(ago(newest * 1000))}</strong></div>
      <div><span>Sensor restarts seen</span><strong>${reboots}</strong></div>
      <div><span>Send interval</span><strong>${esc(span(interval))}</strong></div>
    </div>`;

  const notes = [];
  if (late) {
    notes.push(`<p class="ph-note bad"><b>No new reading for ${esc(span(silence))}.</b> Check that the guard phone is on and connected (Phones tab). Readings wait on the sensor box until a phone collects them.</p>`);
  }
  if (reboots > 0) {
    notes.push('<p class="ph-empty">Sequence numbers restart when the sensor restarts, so a gap across a restart cannot be detected.</p>');
  }

  const gapTable = gaps.length ? `
    <h3 class="ph-subhead">Missing readings</h3>
    <div class="ph-table-wrap"><table class="ph-table">
      <thead><tr><th>After reading</th><th>Before reading</th><th>Missing</th><th>Between</th></tr></thead>
      <tbody>${gaps.map((g) => `
        <tr>
          <td>${esc(g.from.boot_id)}_${esc(g.from.seq)}</td>
          <td>${esc(g.to.boot_id)}_${esc(g.to.seq)}</td>
          <td>${esc(g.missing)}</td>
          <td class="nowrap">${esc(clock(g.from.measurement_time * 1000))} → ${esc(clock(g.to.measurement_time * 1000))}</td>
        </tr>`).join("")}
      </tbody></table></div>` : "";

  const timeTable = badTimes.length ? `
    <h3 class="ph-subhead">Readings with suspicious times</h3>
    <p class="ph-empty" style="padding:0 0 8px">Usually after the sensor box lost power and its clock reset. The level is correct; the time may be off.</p>
    <div class="ph-table-wrap" style="max-height:320px"><table class="ph-table">
      <thead><tr><th>Reading</th><th>Recorded time</th><th>Time since previous</th><th>Expected</th></tr></thead>
      <tbody>${badTimes.map((b) => `
        <tr>
          <td>${esc(b.cur.boot_id)}_${esc(b.cur.seq)}</td>
          <td class="nowrap">${esc(clock(b.cur.measurement_time * 1000))}</td>
          <td>${b.dt <= 0 ? "same or earlier" : esc(span(b.dt))}</td>
          <td>${esc(span(b.expected))}</td>
        </tr>`).join("")}
      </tbody></table></div>` : "";

  return summary + notes.join("") + gapTable + timeTable;
}

// --------------------------------------------------------------- wiring

phonesEl.addEventListener("click", (e) => {
  const card = e.target.closest(".ph-card");
  if (!card) return;
  f.phone.value = card.dataset.id;
  renderPhones();
  renderLogs();
  showTab("logs");
});
f.phone.addEventListener("change", () => { renderPhones(); renderLogs(); });
f.level.addEventListener("change", renderLogs);
f.category.addEventListener("change", renderLogs);
f.text.addEventListener("input", renderLogs);
f.range.addEventListener("change", subscribeLogs);
$("fCsv").addEventListener("click", downloadCsv);
$("dcRun").addEventListener("click", runDataCheck);
$("dcRange").addEventListener("change", runDataCheck);

onValue(ref(db, "water/devices"), (snap) => {
  devices = snap.val() || {};
  refreshPhoneFilter();
  renderPhones();
  subscribeLogs();
}, (err) => {
  phonesEl.innerHTML = `<p class="ph-empty">Could not load phones: ${esc(err.message)}</p>`;
});

runDataCheck();
// Keep "x min ago" labels current.
setInterval(renderPhones, 30000);
