/** Open-Meteo — free, no API key. Coords near Umiam Dam / Barapani. */
export const UMIAM_COORDS = { lat: 25.653, lon: 91.889 };

const WMO = {
  0: { label: "Clear", icon: "sunny" },
  1: { label: "Mainly clear", icon: "partly_cloudy_day" },
  2: { label: "Partly cloudy", icon: "partly_cloudy_day" },
  3: { label: "Overcast", icon: "cloud" },
  45: { label: "Fog", icon: "foggy" },
  48: { label: "Rime fog", icon: "foggy" },
  51: { label: "Light drizzle", icon: "rainy_light" },
  53: { label: "Drizzle", icon: "rainy" },
  55: { label: "Heavy drizzle", icon: "rainy" },
  61: { label: "Light rain", icon: "rainy_light" },
  63: { label: "Rain", icon: "rainy" },
  65: { label: "Heavy rain", icon: "rainy_heavy" },
  66: { label: "Freezing rain", icon: "weather_snowy" },
  67: { label: "Heavy freezing rain", icon: "weather_snowy" },
  71: { label: "Light snow", icon: "weather_snowy" },
  73: { label: "Snow", icon: "weather_snowy" },
  75: { label: "Heavy snow", icon: "weather_snowy" },
  77: { label: "Snow grains", icon: "weather_snowy" },
  80: { label: "Light showers", icon: "rainy_light" },
  81: { label: "Showers", icon: "rainy" },
  82: { label: "Heavy showers", icon: "rainy_heavy" },
  85: { label: "Snow showers", icon: "weather_snowy" },
  86: { label: "Heavy snow showers", icon: "weather_snowy" },
  95: { label: "Thunderstorm", icon: "thunderstorm" },
  96: { label: "Thunderstorm + hail", icon: "thunderstorm" },
  99: { label: "Thunderstorm + heavy hail", icon: "thunderstorm" }
};

function sumSlice(arr, from, to) {
  if (!Array.isArray(arr)) return null;
  let s = 0;
  let n = 0;
  for (let i = from; i < to && i < arr.length; i++) {
    const v = Number(arr[i]);
    if (Number.isFinite(v)) {
      s += v;
      n += 1;
    }
  }
  return n ? s : null;
}

export function weatherLabel(code) {
  return WMO[code]?.label || `Code ${code}`;
}

export function weatherIcon(code) {
  return WMO[code]?.icon || "cloud";
}

/**
 * Fetch current + precip totals for Umiam.
 * @returns {Promise<{
 *   tempC: number,
 *   humidity: number,
 *   windKmh: number,
 *   code: number,
 *   rain24h: number,
 *   rainNext24h: number,
 *   rain7d: number,
 *   daily: { t: number, mm: number }[],
 *   fetchedAt: number
 * }>}
 */
export async function fetchUmiamWeather() {
  const url = new URL("https://api.open-meteo.com/v1/forecast");
  url.searchParams.set("latitude", String(UMIAM_COORDS.lat));
  url.searchParams.set("longitude", String(UMIAM_COORDS.lon));
  url.searchParams.set(
    "current",
    "temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m"
  );
  url.searchParams.set("hourly", "precipitation");
  url.searchParams.set("daily", "precipitation_sum");
  url.searchParams.set("past_days", "7");
  url.searchParams.set("forecast_days", "2");
  url.searchParams.set("timezone", "Asia/Kolkata");
  url.searchParams.set("wind_speed_unit", "kmh");

  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`Weather HTTP ${res.status}`);
  const data = await res.json();

  const times = data.hourly?.time || [];
  const precip = data.hourly?.precipitation || [];
  const now = Date.now();

  // Find index of current (or latest past) hourly slot.
  let idx = times.findIndex((t) => new Date(t).getTime() > now) - 1;
  if (idx < 0) idx = times.length - 1;

  const rain24h = sumSlice(precip, Math.max(0, idx - 23), idx + 1);
  const rainNext24h = sumSlice(precip, idx + 1, idx + 25);
  const dailySums = data.daily?.precipitation_sum || [];
  const dailyTimes = data.daily?.time || [];
  const rain7d = sumSlice(dailySums, 0, Math.min(7, dailySums.length));
  const daily = dailyTimes.map((day, i) => ({
    t: new Date(`${day}T12:00:00`).getTime(),
    mm: Number(dailySums[i]) || 0
  }));

  const cur = data.current || {};
  return {
    tempC: Number(cur.temperature_2m),
    humidity: Number(cur.relative_humidity_2m),
    windKmh: Number(cur.wind_speed_10m),
    code: Number(cur.weather_code),
    rain24h,
    rainNext24h,
    rain7d,
    daily,
    fetchedAt: now
  };
}
