# Water Level System — Guide for Office / System Managers

For the guard instructions, see [GUARD_GUIDE.md](GUARD_GUIDE.md). Print it and keep a copy at the station.

---

## 1. How the system works

```
Node A (sensor + LoRa) ──radio──► Node B (ESP8266, WiFi "WaterLevel")
                                        │  WiFi, no internet
                                        ▼
                                  Guard phone (app)
                                        │  mobile data
                                        ▼
                         Firebase Realtime Database (cloud)
                                        │
                                        ▼
                    Web dashboard  +  Office page (phones, logs, data check)
```

| Step | What happens | Where the reading is safe |
|---|---|---|
| 1 | Node A measures every *send interval* (now **1 hour**) and radios it to Node B | Node A → Node B radio |
| 2 | Node B keeps readings in a queue until a phone collects them | **Node B queue** |
| 3 | Phone downloads the queue and saves it. **Node B is not told to delete yet** | **Phone database** + still on Node B |
| 4 | Phone uploads to Firebase over mobile data and marks rows "sent" | **Firebase** |
| 5 | Only then the phone tells Node B to delete those rows (`/ack`) — never past an unsent reading | Firebase + Node B freed |
| 6 | Phone deletes its own copy only when it is **sent and older than 30 days** | Firebase |

Each reading has a unique key `boot_seq` (e.g. `21_57892`). Uploading the same reading twice
just overwrites it with the same data, so retries can never create duplicates.

### What runs on the phone

- **Background service** ("Water Level app is running" notification): wakes about every 75 s
  (35 s while readings are waiting), reads the sensor when on its WiFi, and uploads over mobile
  data **without leaving the sensor WiFi**.
- **Backup job** (Android WorkManager): every 15 min, in case the service was stopped.
- **Restart on boot**: the service starts again after the phone restarts.
- **The app screen**: when open, also reads/sends and shows status. Not required to be open.

---

## 2. Office page: phones, logs and data check

**Address:** `https://umiam-waterlevel.web.app/phones.html`
(local test: run `python -m http.server 8080` in `web_dashboard/` and open `http://localhost:8080/phones.html`).
It is not linked from the public dashboard and is hidden from search engines. Anyone with the
address can open it, so share it only with staff.

### Phones
One card per phone. A phone reports about once a minute when it has internet.

| Badge | Meaning | Action |
|---|---|---|
| Reporting / **Not reporting · 3 h ago** | When the phone last reached the cloud | If red: call the guard — phone off, no data, or app stopped |
| All sent / **12 waiting to send** | Readings on the phone not yet in the cloud | Red if the office is >2 h behind: check mobile data/balance |
| On sensor WiFi / Not on sensor WiFi | Phone connected to Node B | If "Not on" for long: guard should tap *Connect to sensor* |
| **Background service stopped** | Android or the phone maker stopped the app | Do the phone setup (section 4) again |
| **Storage low** | Under 300 MB free | Guard must delete photos/videos |
| **Battery restricted / Notifications off / No location permission** | Phone settings that break background work | Guard taps **Fix** in the app, or do section 4 |

### Data check
Reads the readings in Firebase for the chosen period and reports:

- **Missing (sequence gaps)** — Node B numbers each reading. A gap means readings never reached the
  cloud (lost on the radio link, lost in Node B, or still on a phone). Check the phone's
  "waiting to send" first.
- **Suspicious times** — readings whose time does not match the send interval. Usually after Node B
  lost power and its clock reset. The level value is fine; the time may be wrong.
- **Newest reading** — red if nothing arrived for more than two send intervals.
- **Sensor restarts** — sequence numbers restart on a sensor restart; gaps across a restart cannot be detected.

### Logs
Every phone sends its log lines. Filters: phone, level (default: *warnings + errors*), area,
period, free-text search. **Download CSV** exports exactly what the filters show.

Areas: `sensor` (talking to Node B), `cloud` (uploading), `sync` (app cycle), `service`
(background service), `network` (WiFi), `app` (start, crashes, phone settings).

Important messages:

| Message | Meaning |
|---|---|
| `App crashed` / `App crashed (reported by Android)` | The app crashed. Detail has the technical cause. **Report to the developer.** |
| `App froze (not responding)` | The app hung and Android closed it. **Report to the developer.** |
| `Phone closed the app (...)` | Android / phone maker killed the app (battery saver, low memory). Do section 4. |
| `App was force-stopped (Settings or phone cleaner)` | Someone force-stopped it, or a "cleaner" app did. Talk to the guard. |
| `Phone blocked the background service` | Android refused to start the service from the background. It restarts when the app is opened. |
| `Phone storage almost full` / `Could not read saved readings` | Storage problem — readings cannot be saved. Urgent. |
| `No internet — N readings waiting on phone` | No mobile data. Readings are safe on the phone. |
| `Sensor did not answer in time` / `Could not read the sensor` | Phone is on the sensor WiFi but Node B does not answer. Check Node B power. |
| `App opened` | Detail shows phone name, Android, app version, storage, battery. |

Problems that repeat are logged at most once every 30 minutes per phone, so the log stays readable.

---

## 3. Installing or updating the app

The APK is always at `share/Umiam-WaterLevel.apk` (works on Android 7 and newer, all processor types).

**Before updating a phone:** check the office page shows the phone as **All sent**.
Uninstalling deletes readings that were not sent yet.

1. Send the APK file to the phone (WhatsApp or USB).
2. Tap it → **Install**. Allow "install from this source" if asked; on Play Protect choose *Install anyway*.
3. Open the app and allow every permission it asks for.
4. Do the phone setup below.
5. In the app: **Setup → This phone** → type a name (e.g. *Umiam guard phone 1*) → **Save name**.
6. Check the office page: the phone should appear within a few minutes.

### Signing key — IMPORTANT
The APK is signed with the release key in:
- `mobile_app/android/app/umiam-release.jks`
- `mobile_app/android/key.properties` (contains the password)

These files are not in git. **Keep a backup copy in two safe places.** If they are lost, new
versions cannot install over the old app, and every phone would need an uninstall (losing unsent readings).

### "App not installed" — causes
1. Not enough storage (needs about 500 MB free).
2. An old copy signed with a different key is still installed (check Settings → Apps, including
   "Dual apps" / "Second space" / work profile). Only uninstall after the phone shows **All sent**.
3. Broken download — download again.
4. Android older than 7.

---

## 4. Phone setup checklist (do once per phone, and after phone resets)

Android phones kill background apps to save battery. Phone makers add their own extra killers.
Do all of these:

**All phones**
- App → banner **Fix** buttons until no yellow/red boxes remain.
- Settings → Apps → Water Level → **Battery → Unrestricted** (or "Don't optimise").
- Settings → Apps → Water Level → **Notifications → On**.
- Settings → Apps → Water Level → **Permissions → Location → Allow** (needed to see the WiFi name).
- Location (GPS) switched **on** in quick settings.
- WiFi on and mobile data on; turn off "Switch to mobile data when WiFi has no internet" if the
  phone keeps leaving the sensor WiFi.
- Keep the phone on a charger.

**Xiaomi / Redmi / POCO**: Settings → Apps → Water Level → **Autostart ON**; Battery saver → **No restrictions**.
In the recent-apps screen, long-press the app → **lock** icon.

**Samsung**: Settings → Battery → Background usage limits → remove the app from *Sleeping* /
*Deep sleeping*; add to **Never sleeping apps**.

**Oppo / Realme / OnePlus**: Settings → Apps → Water Level → Battery → **Allow background activity**
and **Allow auto launch**.

**Vivo / iQOO**: Settings → Battery → Background power consumption → Water Level → **Allow**;
i Manager → App manager → Autostart → **ON**.

**Tecno / Infinix / itel**: Phone Master → Auto-start → **ON**; disable "Power saving" for the app.

After setup, wait 1–2 hours and check the office page: no `Phone closed the app` lines, and the phone keeps *Reporting*.

---

## 5. Daily check (2 minutes)

1. Open the office page.
2. **Data check → Newest reading** is green (less than two send intervals old).
3. **Missing** is 0. If not, see section 2.
4. Each phone is **Reporting** and **All sent** (or only a few waiting).
5. Logs (warnings + errors, last 24 h): look for `crashed`, `froze`, `closed the app`, `storage`.

---

## 6. Developer tasks

| Task | Command (from repo root unless noted) |
|---|---|
| Build APK | `cd mobile_app; flutter build apk --release`, then copy `build/app/outputs/flutter-apk/app-release.apk` to `share/Umiam-WaterLevel.apk` |
| Tests | `cd mobile_app; flutter analyze; flutter test` |
| Deploy database rules | `firebase deploy --only database` (`firebase login --reauth` if it says credentials expired) |
| Deploy website | `firebase deploy --only hosting` |
| Bump version | `mobile_app/pubspec.yaml` `version:` (increase the `+build` number every release) |

Database paths: `water/readings/{station}/{boot_seq}`, `water/latest/{station}`,
`water/devices/{phoneId}` (phone status), `water/logs/{phoneId}/{time_id}` (logs).

---

## 7. Known limits

- **Node B queue size and power-loss behaviour** are set by the ESP firmware (not in this repo).
  If no phone collects readings for a long time, Node B may run out of space. Confirm the
  capacity with the sensor team and keep the phone collecting at least daily.
- **Radio link Node A → Node B**: a reading lost on the radio never reaches Node B. It shows
  as a sequence gap in the data check.
- **Phone off / dead / uninstalled**: readings wait on Node B. Readings that were on the phone but
  not yet sent are lost if the app is uninstalled or its data cleared.
- **Node B clock**: after Node B loses power its clock resets; the app rebuilds times from the
  send interval. Old app versions (before 1.3.0) could store the phone's download time instead.
- **Sequence number wrap**: the reading key is `boot_seq`; the sequence goes up to 65535 and then
  restarts at 0 (and boot ID restarts after 256 sensor restarts). After one full cycle a new reading
  gets the same key as a very old one and **overwrites it in the cloud**. One cycle is 65,536
  readings: about **7.5 years at 1 hour**, 227 days at 5 minutes, 7.6 days at 10 seconds.
  Below about 40 seconds the cycle is shorter than the phone's 30-day memory, and the phone would
  treat new readings as "already saved" and drop them. Keep the interval at 1 hour (or at least
  15 minutes) in production. The permanent fix is to add the date to the key; it should be done
  before a full cycle can complete.
