# ESP8266 Gateway API Contract (Node B)

Base URL: `http://192.168.4.1` (plain HTTP, all GET, JSON, CORS allowed)

WiFi AP: SSID `WaterLevel`, password `12345678`, IP `192.168.4.1`

Android: allow cleartext HTTP to `192.168.4.1` and bind requests to the SoftAP network.

## Units

Node B sends `dist` and `level` in **millimetres**.  
UI + Firebase display/upload them in **metres** (`mm / 1000`, 2 decimals).  
`null` stays null (show `—`).

## Unique key

`boot_seq` (e.g. `74_31722`) — avoid duplicates across reboots.

## Status codes

| Code | Meaning |
|------|---------|
| 0 | OK |
| 1 | Too close (&lt;0.28 m) |
| 2 | No echo |
| 3 | Sensor not responding |

## Endpoints

### GET /time?epoch=&lt;unix seconds&gt;

Call first on every connect (sets Node B clock).

### GET /status

```json
{
  "records": 12,
  "packets": 40,
  "time_set": true,
  "pending_interval": 0,
  "latest": {
    "id": 100,
    "seq": 456,
    "ts": 1790000030,
    "dist": 1250,
    "level": 3750,
    "status": 0,
    "interval": 30
  }
}
```

### GET /data?since=&lt;id&gt;&limit=200

```json
{
  "records": [
    {
      "id": 101,
      "boot": 123,
      "seq": 456,
      "ts": 1790000030,
      "dist": 1250,
      "level": 3750,
      "status": 0,
      "samples": 3,
      "interval": 30
    }
  ],
  "last_id": 101,
  "more": false
}
```

Repeat with `since=last_id` while `more=true`.

### GET /ack?upto=&lt;id&gt;

Call **only** after records are saved locally. Node B then deletes them.

### GET /config?interval=&lt;10..3600&gt;

Sets Node A send interval; applied after Node A’s next send. While waiting, `/status` may show `pending_interval > 0`.

## Sync flow (phone)

1. Join `WaterLevel` WiFi  
2. `GET /time?epoch=…`  
3. `GET /data` loop (`since` / `last_id` / `more`)  
4. Save locally (dedupe `boot`+`seq`)  
5. `GET /ack?upto=last_id`  
6. When internet is available, upload to Firebase and mark uploaded

## Firebase

Path used by this app: `/water/readings/<station_id>/<boot>_<seq>`  
Also updates `/water/latest/<station_id>` and `/water/stations/<station_id>`.

Fields include mm and metres (`distance_m`, `water_level_m`).
