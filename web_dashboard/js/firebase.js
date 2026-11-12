import { initializeApp } from "https://www.gstatic.com/firebasejs/11.6.0/firebase-app.js";
import { getDatabase, ref, onValue, get } from "https://www.gstatic.com/firebasejs/11.6.0/firebase-database.js";

const cfg = window.WATERLEVEL_FIREBASE || {};
const incomplete =
  !cfg.config ||
  !cfg.config.apiKey ||
  cfg.config.apiKey.startsWith("YOUR_") ||
  cfg.useDemo === true;

export const isDemoMode = incomplete;
export let db = null;
export let connectionState = incomplete ? "demo" : "connecting";

export function initFirebase() {
  if (incomplete) {
    connectionState = "demo";
    return { demo: true };
  }
  const app = initializeApp(cfg.config);
  db = getDatabase(app);
  connectionState = "connected";
  return { demo: false, db };
}

export function listenStations(callback) {
  if (isDemoMode) {
    callback(window.WATERLEVEL_DEMO.stations);
    return () => {};
  }
  const r = ref(db, "water/stations");
  return onValue(
    r,
    (snap) => callback(snap.val() || {}),
    () => {
      connectionState = "disconnected";
      callback({});
    }
  );
}

export function listenLatest(stationId, callback) {
  if (isDemoMode) {
    callback(window.WATERLEVEL_DEMO.latest[stationId] || null);
    return () => {};
  }
  const r = ref(db, `water/latest/${stationId}`);
  return onValue(r, (snap) => callback(snap.val()));
}

export async function loadReadings(stationId) {
  if (isDemoMode) {
    return window.WATERLEVEL_DEMO.readings[stationId] || {};
  }
  const snap = await get(ref(db, `water/readings/${stationId}`));
  return snap.val() || {};
}

export function listenConnection(callback) {
  if (isDemoMode) {
    callback("demo");
    return () => {};
  }
  const r = ref(db, ".info/connected");
  return onValue(r, (snap) => {
    connectionState = snap.val() ? "connected" : "disconnected";
    callback(connectionState);
  });
}
