window.WATERLEVEL_DEMO = {
  stations: {
    station_001: {
      name: "Umiam Dam",
      mount_height_mm: 5000,
      last_updated: Math.floor(Date.now() / 1000) - 120
    }
  },
  latest: {
    station_001: {
      boot_id: 11,
      seq: 42,
      measurement_time: Math.floor(Date.now() / 1000) - 90,
      received_time: Math.floor(Date.now() / 1000) - 60,
      distance_mm: 1250,
      water_level_mm: 3750,
      status: 0,
      valid_samples: 5,
      send_interval_seconds: 30,
      uploaded_at: Math.floor(Date.now() / 1000) - 45
    }
  },
  readings: {
    station_001: (() => {
      const now = Math.floor(Date.now() / 1000);
      const out = {};
      for (let i = 0; i < 48; i++) {
        const seq = 42 - i;
        const boot = seq > 0 ? 11 : 10;
        const s = seq > 0 ? seq : seq + 40;
        // Gentle reservoir curve so the chart reads clearly in demo mode.
        const level =
          3750 +
          Math.sin(i / 5.5) * 220 +
          Math.cos(i / 9.5) * 90 -
          i * 4;
        const distance = Math.max(800, Math.round(5000 - level));
        const key = `${boot}_${s}`;
        out[key] = {
          boot_id: boot,
          seq: s,
          measurement_time: now - i * 1800,
          received_time: now - i * 1800 + 20,
          age_seconds: 20,
          distance_mm: distance,
          water_level_mm: Math.round(level),
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
