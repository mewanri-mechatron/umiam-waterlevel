# WaterLevel — Umiam Dam

Offline-first water-level monitoring (no internet at the sensor).

```
Node A (STM + LoRa) → Node B (ESP SoftAP) → Phone app → Firebase → Web dashboard
```

**Firebase project:** `umiam-waterlevel`  
**ESP WiFi:** SSID `WaterLevel` · password `12345678` · IP `192.168.4.1`

---

## Exact setup (do in order)

You only need to do this **once**.

### Step 1 — Open your Firebase project

1. Go to [https://console.firebase.google.com/](https://console.firebase.google.com/)
2. Open project **`umiam-waterlevel`**
3. If the project does not exist yet: **Add project** → name it `umiam-waterlevel` → continue through the wizard (Google Analytics optional)

---

### Step 2 — Create Realtime Database

1. Left menu → **Build** → **Realtime Database**
2. Click **Create Database**
3. Prefer region **`asia-southeast1`** (Singapore) if offered
4. Start in **locked mode** (OK — we deploy our rules next)
5. After it is created, copy the database URL at the top.  
   It usually looks like:  
   `https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app`  
   If your URL is different, use **your** URL everywhere below.

---

### Step 3 — Turn on Anonymous sign-in

1. Left menu → **Build** → **Authentication**
2. Click **Get started** (if first time)
3. Open **Sign-in method**
4. Click **Anonymous** → enable → **Save**

The phone app signs in anonymously so it can **write** readings.

---

### Step 4 — Deploy database rules from this repo

On your PC (in a terminal):

```bash
npm install -g firebase-tools
cd d:\Projects\UmiamProject\firebase
firebase login
firebase use umiam-waterlevel
firebase deploy --only database
```

If `firebase use` says the project is unknown:

```bash
firebase projects:list
firebase use umiam-waterlevel
```

Rules file used: `firebase/database.rules.json`  
(Web can **read** `/water`; only signed-in phones can **write**.)

---

### Step 5 — Register the Android app

1. Firebase Console → project overview (gear) → **Project settings**
2. Under **Your apps** → **Add app** → **Android**
3. Android package name (must match exactly):

   ```
   com.waterlevel.app
   ```

4. App nickname: `WaterLevel` (optional)
5. Click **Register app**
6. Download **`google-services.json`**
7. Put that file here (exact path):

   ```
   d:\Projects\UmiamProject\mobile_app\android\app\google-services.json
   ```

8. Still in **Project settings** → your Android app → copy:
   - `apiKey`
   - `appId` (looks like `1:123456:android:...`)
   - `messagingSenderId` (numbers)
   - `projectId` → should be `umiam-waterlevel`
   - Realtime Database URL from Step 2

9. Open:

   `mobile_app/lib/core/constants/firebase_options_stub.dart`

10. Paste those values, then set:

    ```dart
    static const bool isConfigured = true;
    ```

    Example shape (use **your** real values):

    ```dart
    static const bool isConfigured = true;

    static FirebaseOptions get currentPlatform => const FirebaseOptions(
          apiKey: 'AIza...',
          appId: '1:....:android:....',
          messagingSenderId: '123456789',
          projectId: 'umiam-waterlevel',
          databaseURL: 'https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app',
          storageBucket: 'umiam-waterlevel.appspot.com',
        );
    ```

---

### Step 6 — Register the Web app (dashboard)

1. Firebase Console → **Project settings** → **Add app** → **Web** (`</>`)
2. Nickname: `WaterLevel Dashboard`
3. You can skip Hosting for now (or enable it — optional)
4. Copy the `firebaseConfig` object Firebase shows you
5. Open:

   `web_dashboard/js/firebase-config.js`

6. Paste the values into `config`
7. Set:

   ```js
   useDemo: false
   ```

---

### Step 7 — Build and install the phone app

1. Connect your Android phone with USB debugging **or** plan to copy the APK
2. In a terminal:

```bash
cd d:\Projects\UmiamProject\mobile_app
flutter pub get
flutter build apk --debug
```

3. APK path:

   `mobile_app\build\app\outputs\flutter-apk\app-debug.apk`

4. Install it on the phone, open the app **once**, and allow:
   - Notifications
   - Location / Nearby devices (needed to see WiFi name)
   - Background / battery unrestricted if asked

---

### Step 8 — Test near the ESP

1. Phone Wi‑Fi → join **`WaterLevel`** / password **`12345678`**  
   (or app → gear → **Connect to WaterLevel WiFi**)
2. Stay near Node B; app should pull readings onto the phone
3. Switch phone back to normal mobile data / home Wi‑Fi
4. Wait for upload (or reopen the app)
5. In Firebase Console → **Realtime Database**, you should see:

   ```
   water/
     readings/station_001/...
     latest/station_001/...
   ```

---

### Step 9 — Open the web dashboard

**On your PC:**

```bash
cd d:\Projects\UmiamProject\web_dashboard
python -m http.server 8080
```

Open [http://localhost:8080/](http://localhost:8080/)

- Yellow “Demo…” banner → `useDemo` is still true or web config incomplete  
- No banner + real numbers → live Firebase data

**Optional — publish online:**

```bash
cd d:\Projects\UmiamProject\firebase
firebase deploy --only hosting
```

---

## Station defaults

| Setting | Value |
|---------|--------|
| Station ID | `station_001` |
| Name | Umiam Dam |
| SoftAP SSID | `WaterLevel` |
| SoftAP password | `12345678` |
| Gateway | `http://192.168.4.1` |
| Mount height | `5000` mm |

---

## What is done vs what you do next

| Item | Status |
|------|--------|
| App + web code | Done in this repo |
| ESP SoftAP name/password known | Done |
| Firebase project `umiam-waterlevel` | **You create / configure (Steps 1–6)** |
| `google-services.json` + options filled | **You** |
| Web `useDemo: false` + web config | **You** |
| Install APK + first open | **You** |
| Field test with Node B | **You** |

---

## Repo layout

| Path | Purpose |
|------|---------|
| `mobile_app/` | Flutter Android field app |
| `web_dashboard/` | Read-only web UI |
| `shared/` | Protocol docs |
| `firebase/` | Database rules + Hosting |

---

## Notes

- Phone stores data in SQLite first; Firebase is the cloud copy. Already-uploaded readings are not sent again.
- Do not force-stop the app if you want background sync.
- `google-services.json` is gitignored (keep it on your machine only).
