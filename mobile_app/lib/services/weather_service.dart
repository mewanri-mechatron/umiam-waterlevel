import 'dart:convert';

import 'package:dio/dio.dart';

/// Open-Meteo — free, no API key. Coords near Umiam Dam / Barapani.
class WeatherService {
  WeatherService({Dio? dio}) : _dio = dio ?? Dio();

  static const lat = 25.653;
  static const lon = 91.889;

  final Dio _dio;

  Future<UmiamWeather> fetchUmiam() async {
    final res = await _dio.get<Map<String, dynamic>>(
      'https://api.open-meteo.com/v1/forecast',
      queryParameters: {
        'latitude': lat,
        'longitude': lon,
        'current':
            'temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m',
        'hourly': 'precipitation',
        'daily': 'precipitation_sum',
        'past_days': 7,
        'forecast_days': 2,
        'timezone': 'Asia/Kolkata',
        'wind_speed_unit': 'kmh',
      },
    );
    final data = res.data;
    if (data == null) throw StateError('Empty weather response');

    final dailyTimes = (data['daily']?['time'] as List?) ?? const [];
    final dailySums =
        (data['daily']?['precipitation_sum'] as List?) ?? const [];
    final daily = <DailyRain>[];
    for (var i = 0; i < dailyTimes.length; i++) {
      final day = dailyTimes[i].toString();
      final mm = i < dailySums.length
          ? (dailySums[i] as num?)?.toDouble()
          : 0.0;
      daily.add(DailyRain(day: DateTime.parse('${day}T12:00:00'), mm: mm ?? 0));
    }

    final cur = data['current'] as Map<String, dynamic>? ?? const {};
    return UmiamWeather(
      tempC: (cur['temperature_2m'] as num?)?.toDouble(),
      humidity: (cur['relative_humidity_2m'] as num?)?.toDouble(),
      windKmh: (cur['wind_speed_10m'] as num?)?.toDouble(),
      code: (cur['weather_code'] as num?)?.toInt(),
      daily: daily,
      fetchedAt: DateTime.now(),
      raw: jsonEncode({'ok': true}),
    );
  }
}

class DailyRain {
  const DailyRain({required this.day, required this.mm});
  final DateTime day;
  final double mm;
}

class UmiamWeather {
  const UmiamWeather({
    this.tempC,
    this.humidity,
    this.windKmh,
    this.code,
    required this.daily,
    required this.fetchedAt,
    this.raw,
  });

  final double? tempC;
  final double? humidity;
  final double? windKmh;
  final int? code;
  final List<DailyRain> daily;
  final DateTime fetchedAt;
  final String? raw;
}
