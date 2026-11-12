# WaterLevel — Umiam Dam

Offline-first water-level monitoring for a site with **no internet at the sensor**.

```
Node A (STM + sensor + LoRa)
        │ LoRa
        ▼
Node B (ESP + LoRa SoftAP "WaterLevel")
        │ WiFi SoftAP (no internet)
        ▼
Android phone app  ──SQLite──►  (later, on mobile data / WiFi)
        │
        ▼
Firebase Realtime Database
        │
        ▼
Web dashboard (read-only)
```

| Piece | Role |
|-------|------|
| **Node A** | Measures water level; sends over LoRa |
| **Node B** | Receives LoRa, buffers readings, serves them on SoftAP `WaterLevel` / `192.168.4.1` |
| **Phone app** | Near Node B → pulls readings; later online → uploads to Firebase |
| **Web dashboard** | Shows live / historical level from Firebase |

---

## What field users do

1. Install the app and **open it once** (allow notifications / WiFi prompts if asked).
2. Carry the phone **near the dam station** (Node B). The app prefers SSID `WaterLevel` and pulls buffered readings in the background.
3. When the phone later has normal internet, pending readings upload to Firebase automatically.
4. Anyone can open the web dashboard to view Umiam Dam levels.

**Advanced** (gear) is only a fallback: **Connect to WaterLevel WiFi** if auto-join fails.

Do **not** force-stop the app. Some OEM battery savers can delay background sync — allow WaterLevel to run in the background if prompted.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `mobile_app/` | Flutter Android field app |
| `web_dashboard/` | Read-only web UI (ApexCharts) |
| `shared/` | Protocol / API / schema docs |
| `firebase/` | RTDB rules + Hosting config |

---

## One-time setup checklist

### 1. Hardware (field)

- [ ] Node A powered and measuring on its interval  
- [ ] Node B powered, LoRa link from Node A OK  
- [ ] Node B SoftAP visible as **`WaterLevel`**, HTTP at **`http://192.168.4.1`**  
- [ ] Mount height known (default in app DB: **5000 mm** for Umiam)

### 2. Firebase project (`agri-db-fa27f`)

In [Firebase Console](https://console.firebase.google.com/):

1. **Realtime Database** — create/use the Asia Southeast instance  
   `https://agri-db-fa27f-default-rtdb.asia-southeast1.firebasedatabase.app`
2. **Authentication → Sign-in method** → enable **Anonymous**
3. Deploy database rules from this repo:

```bash
cd firebase
firebase login
firebase use agri-db-fa27f
firebase deploy --only database
```

4. **Android app**
   - Add Android app with package name: `com.waterlevel.app`
   - Download **`google-services.json`**
   - Place it at: `mobile_app/android/app/google-services.json`

5. **Fill Flutter Firebase options**  
   Edit `mobile_app/lib/core/constants/firebase_options_stub.dart`:
   - Set `isConfigured = true`
   - Replace `apiKey`, `appId`, `messagingSenderId` (and bucket if needed) with values from the Firebase console / `google-services.json`  
   Or run FlutterFire configure and point the app at the generated options.

6. **Web app**
   - Add a Web app in the same Firebase project  
   - Edit `web_dashboard/js/firebase-config.js`:
     - Put the web config values in `config`
     - Set `useDemo: false`

Without steps 4–6, the phone still stores data locally, and the web UI stays in **labeled demo mode**.

### 3. Build & install the phone app

Requirements: Flutter SDK, Android SDK, a phone with USB debugging (or sideload the APK).

```bash
cd mobile_app
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK:

`mobile_app/build/app/outputs/flutter-apk/app-release.apk`

Install on the field phone, open once, allow:

- Notifications (background sync status)
- Location / Nearby Wi‑Fi (needed on many Androids to see SoftAP SSID)
- Battery unrestricted / “allow background activity” if the OEM asks

### 4. Web dashboard

**Local preview**

```bash
cd web_dashboard
python -m http.server 8080
```

Open `http://localhost:8080/`

**Production (Firebase Hosting)**

```bash
cd firebase
firebase deploy --only hosting
```

Hosting serves `web_dashboard/` (see `firebase/firebase.json`).

---

## Station defaults

| Setting | Value |
|---------|--------|
| Station ID | `station_001` |
| Name | Umiam Dam |
| SoftAP SSID | `WaterLevel` |
| Gateway | `http://192.168.4.1` |
| Mount height | `5000` mm (seeded in SQLite) |

Reading identity (no duplicates): `station_id + boot_id + seq`  
Firebase keys: `water/readings/<station_id>/<boot_id>_<seq>`  
Already-uploaded rows stay marked in SQLite and are **not** pushed again.

---

## Developer / demo notes

- Web with `useDemo: true` (or incomplete Firebase web config) shows a yellow **demo** banner and sample data.
- Phone mock gateway: set SharedPreferences `use_mock_gateway` = true only for UI testing without Node B. Default is **real ESP**.
- Protocol docs: [shared/sensor_protocol.md](shared/sensor_protocol.md), [shared/gateway_api.md](shared/gateway_api.md), [shared/firebase_schema.md](shared/firebase_schema.md)

### Architecture rules

1. SQLite on the phone is primary; Firebase is the cloud mirror.  
2. Never ACK Node B readings before SQLite commit.  
3. Never delete historical readings after upload.  
4. Demo/mock data must never be shown as live field data.  
5. Node A LoRa packet format is fixed — do not change it.

---

## Security (MVP)

- Web reads `/water` publicly (read-only dashboard).  
- Phone writes require Firebase Auth (anonymous).  
- Before a public production rollout, add App Check and tighter auth.

---

## Quick verify

| Check | Expected |
|-------|----------|
| Phone near Node B on `WaterLevel` | App pulls readings; home shows a level |
| Phone back on mobile data / Wi‑Fi | Pending count drops; Firebase `water/readings/station_001` grows |
| Dashboard with `useDemo: false` | Live Umiam level + chart (no demo banner) |
| Advanced → Connect manually | System Wi‑Fi prompt for SoftAP if auto-join failed |
