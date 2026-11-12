# Sensor Protocol (Node A → Node B)

Node A firmware is **already working**. Do not change its LoRa packet format.

The Android app receives **already-decoded** readings from Node B (ESP8266).
A Dart `WaterLevelPayloadDecoder` is provided for validation and testing only.

## Payload

| Field | Value |
|-------|-------|
| Version | `0xB4` (180) |
| Length | 18 bytes |
| UART | 9600 8N1 (E32 transparent mode) |

### Byte layout

| Bytes | Field | Notes |
|-------|-------|-------|
| 0 | Version | Must be `0xB4` |
| 1 | Boot ID | Increments on transmitter restart |
| 2–3 | Sequence | Big endian, wraps |
| 4–7 | Age seconds | Big endian; age at transmit |
| 8–9 | Distance mm | Big endian; `0xFFFF` = unavailable |
| 10–11 | Water level mm | Big endian; `0xFFFF` = unavailable |
| 12 | Sensor status | See below |
| 13 | Valid samples | Count used in measurement |
| 14–15 | Send interval s | Big endian |
| 16–17 | CRC16 Modbus | Low byte first |

### CRC16 Modbus

- Calculate over bytes `0–15`.
- Transmitted low byte first (little-endian wire order).

### Sensor status

| Code | Meaning |
|------|---------|
| 0 | OK |
| 1 | Too close / blind zone |
| 2 | No echo / out of range |
| 3 | Sensor not responding |

### Special values

- `0xFFFF` = unavailable for distance / water level fields.

### Measurement time

```
measurement_time = receive_time - age_seconds
```

Store both `measurement_time` and `receive_time`. Do not confuse these with phone download time or Firebase upload time.

### Water level (phone-side)

If mounting height is configured:

```
water_level_mm = mount_height_mm - distance_mm
```

- Do not calculate water level when mount height is unavailable.
- Do not accept negative water-level values as valid.
