# Firebase Realtime Database Schema

Project database URL:

`https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app`
(Use the exact URL shown in Firebase Console → Realtime Database if your region differs.)

## Tree

```
water/
  stations/
    station_001/
      name: "Water Monitoring Station 1"
      mount_height_mm: 5000
      last_updated: 1790000030
  readings/
    station_001/
      123_456/
        boot_id: 123
        seq: 456
        measurement_time: 1790000000
        received_time: 1790000030
        age_seconds: 30
        distance_mm: 1250
        water_level_mm: 3750
        status: 0
        valid_samples: 3
        send_interval_seconds: 30
        uploaded_at: 1790000100
  latest/
    station_001/
      boot_id: 123
      seq: 456
      measurement_time: 1790000000
      received_time: 1790000030
      distance_mm: 1250
      water_level_mm: 3750
      status: 0
      valid_samples: 3
      send_interval_seconds: 30
```

## Keys

- Station path includes station ID.
- Reading key: `<boot_id>_<seq>` (deterministic → no duplicate history).
- Local identity: `station_id + boot_id + seq`.

## Latest update rule

Update `latest/<station_id>` only when the incoming reading is **newer**:

1. Higher `measurement_time`, else
2. Higher `boot_id`, else
3. Higher `seq`

Never overwrite latest with an older queued reading.

## Auth / rules (MVP)

- Web dashboard: **read-only**, may be unauthenticated.
- Mobile writers: **Firebase Authentication** (anonymous for MVP).
- No public write access.
- Anonymous auth is convenient for field devices but is not strong production protection; tighten before public deployment (device tokens, App Check, etc.).

Timestamps:

- `measurement_time` / `received_time` from the sensor path
- `uploaded_at` set when the phone writes to Firebase
