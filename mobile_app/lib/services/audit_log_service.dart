import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/app_constants.dart';
import '../database/app_database.dart';
import 'network_service.dart';

class AuditEntry {
  const AuditEntry({
    this.id,
    required this.createdAt,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
  });

  final int? id;
  final DateTime createdAt;
  final String level;
  final String category;
  final String message;
  final String? detail;

  factory AuditEntry.fromMap(Map<String, Object?> map) => AuditEntry(
    id: map['id'] as int?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (map['created_at'] as num).toInt(),
    ),
    level: (map['level'] ?? 'info').toString(),
    category: (map['category'] ?? 'app').toString(),
    message: (map['message'] ?? '').toString(),
    detail: map['detail']?.toString(),
  );
}

/// Persisted debug trail in local SQLite. The native CloudReporter uploads
/// every line (tagged with this phone's ID) to `water/logs/{deviceId}`.
class AuditLogService extends ChangeNotifier {
  AuditLogService(
    this._db, {
    this.network,
    this.stationId = AppConstants.defaultStationId,
  });

  final AppDatabase _db;
  final String stationId;
  final NetworkService? network;
  final List<AuditEntry> _cache = [];
  bool _loaded = false;

  static const _uiLimit = 2000;

  List<AuditEntry> get entries => List.unmodifiable(_cache);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await refresh();
  }

  Future<void> refresh() async {
    final rows = await _db.getAuditLogs(limit: _uiLimit);
    _cache
      ..clear()
      ..addAll(rows.map(AuditEntry.fromMap));
    _loaded = true;
    notifyListeners();
  }

  Future<void> log(
    String message, {
    String level = 'info',
    String category = 'sync',
    String? detail,
  }) async {
    final createdAtMs = DateTime.now().millisecondsSinceEpoch;
    try {
      await _db.insertAuditLog(
        level: level,
        category: category,
        message: message,
        detail: detail,
      );
      _cache.insert(
        0,
        AuditEntry(
          createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
          level: level,
          category: category,
          message: message,
          detail: detail,
        ),
      );
      if (_cache.length > _uiLimit) {
        _cache.removeRange(_uiLimit, _cache.length);
      }
      notifyListeners();
    } catch (e) {
      // Logging must never break sync.
      debugPrint('audit log failed: $e');
    }

    // Problems reach the office sooner; the reporter throttles itself.
    if (level != 'info') unawaited(network?.requestCloudReport());
  }

  Future<void> info(
    String message, {
    String category = 'sync',
    String? detail,
  }) => log(message, level: 'info', category: category, detail: detail);

  Future<void> warn(
    String message, {
    String category = 'sync',
    String? detail,
  }) => log(message, level: 'warn', category: category, detail: detail);

  Future<void> error(
    String message, {
    String category = 'sync',
    String? detail,
  }) => log(message, level: 'error', category: category, detail: detail);

  Future<void> clear() async {
    await _db.clearAuditLogs();
    _cache.clear();
    notifyListeners();
  }
}
