// Demo sample — dam RL stored as feet*1000 (legacy "mm" fields).
// Sensor gap is true millimetres; elevation change converts mm→ft.
(() => {
  const now = Math.floor(Date.now() / 1000);
  const calibActualMm = 3201900; // 3201.90 ft AMSL
  const calibDistanceMm = 1500; // 1.50 m gap at calibration
  const calibRawLevelMm = 3750;

  function displayLevelMm(gapMm) {
    const actualFt = calibActualMm / 1000;
    const deltaFt = (calibDistanceMm - gapMm) / 304.8;
    return Math.round((actualFt + deltaFt) * 1000);
  }

  const latestGap = 1250;
  const latestDisplay = displayLevelMm(latestGap);

  window.WATERLEVEL_DEMO = {
    stations: {
      station_001: {
        name: "Umiam Dam",
        calib_actual_mm: calibActualMm,
        calib_raw_level_mm: calibRawLevelMm,
        calib_distance_mm: calibDistanceMm,
        last_updated: now - 120
      }
    },
    latest: {
      station_001: {
        boot_id: 11,
        seq: 42,
        measurement_time: now - 90,
        received_time: now - 60,
        distance_mm: latestGap,
        distance_m: latestGap / 1000,
        sensor_level_mm: 4000,
        sensor_level_m: 4,
        water_level_mm: latestDisplay,
        water_level_m: Number((latestDisplay / 1000).toFixed(2)),
        status: 0,
        valid_samples: 5,
        send_interval_seconds: 30,
        uploaded_at: now - 45
      }
    },
    readings: {
      station_001: (() => {
        const out = {};
        for (let i = 0; i < 48; i++) {
          const seq = 42 - i;
          const boot = seq > 0 ? 11 : 10;
          const s = seq > 0 ? seq : seq + 40;
          const gap =
            Math.max(
              900,
              Math.round(1250 + Math.sin(i / 5.5) * 180 + Math.cos(i / 9.5) * 70 + i * 3)
            );
          const display = displayLevelMm(gap);
          const key = `${boot}_${s}`;
          out[key] = {
            boot_id: boot,
            seq: s,
            measurement_time: now - i * 1800,
            received_time: now - i * 1800 + 20,
            age_seconds: 20,
            distance_mm: gap,
            distance_m: Number((gap / 1000).toFixed(2)),
            sensor_level_mm: Math.round(5000 - gap),
            sensor_level_m: Number(((5000 - gap) / 1000).toFixed(2)),
            water_level_mm: display,
            water_level_m: Number((display / 1000).toFixed(2)),
            status: i === 5 ? 2 : 0,
            valid_samples: i === 5 ? 0 : 5,
            send_interval_seconds: 30,
            uploaded_at: now - i * 1800 + 60
          };
        }
        return out;
      })()
    }
  };
})();
