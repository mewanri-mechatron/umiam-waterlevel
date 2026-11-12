# ESP8266 Gateway API Contract (Node B)

Base URL: `http://192.168.4.1`

WiFi AP: SSID `WaterLevel`, IP `192.168.4.1`

Node B firmware is developed separately. The mobile app uses a **gateway adapter**
so endpoints/JSON can change without rewriting repositories or UI.

## Assumptions (MVP)

1. Gateway exposes HTTP over its SoftAP.
2. Phone may have **no internet** while connected to the AP.
3. Sequence numbers are **not** globally unique across reboots — identity is `boot_id + seq` (plus `station_id` on the phone).
4. ACK must name the exact records stored; never ACK before SQLite commit.
5. A future cursor-based incremental API may replace or extend `since=<seq>`.

## Endpoints

### GET /status

```json
{
  "device": "WaterLevel",
  "status": "online",
  "queue_count": 12,
  "last_sequence": 456,
  "last_boot_id": 123
}
```

### GET /data?since=&lt;sequence&gt;

MVP query uses sequence for convenience. Clients **must** dedupe by `boot_id + seq`.

When the transmitter restarts, `boot_id` changes and sequences may restart.
Preferred future form:

```
GET /data?cursor=<boot_id>_<seq>
```

Response:

```json
{
  "readings": [
    {
      "version": 180,
      "boot_id": 123,
      "seq": 456,
      "age_seconds": 30,
      "distance_mm": 1250,
      "water_level_mm": 3750,
      "status": 0,
      "valid_samples": 3,
      "send_interval_seconds": 30
    }
  ]
}
```

### POST /ack

Confirms the phone has committed records to SQLite.

```json
{
  "station_id": "station_001",
  "records": [
    { "boot_id": 123, "seq": 456 },
    { "boot_id": 123, "seq": 457 }
  ]
}
```

Response:

```json
{ "acked": 2, "status": "ok" }
```

If a reading already exists locally, it is safe to ACK again.

### POST /time

Body:

```json
{ "unix_timestamp": 1790000030 }
```

Response:

```json
{ "status": "ok", "applied": true }
```

## Download workflow (phone)

1. Connect to WaterLevel WiFi
2. `GET /status`
3. `POST /time`
4. `GET /data?...`
5. Validate each reading
6. Insert in a SQLite transaction (ignore duplicates)
7. Commit
8. `POST /ack` for successfully stored records
9. Update UI / sync_state

Crash before ACK → re-download is safe (unique constraint prevents duplicates).

## Adapter note

Implement `GatewayClient` with:

- `HttpGatewayService` — real hardware
- `MockGatewayService` — development without Node B

Keep mock records clearly labeled and separate from field data.
