import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of a successful upload: the server's batch id and per-metric counts.
class HealthSyncResult {
  HealthSyncResult(this.batchId, this.counts, this.recordCount);

  final int batchId;
  final Map<String, dynamic> counts;

  /// Total records sent (for the UI).
  final int recordCount;
}

/// Builds a `health_sync` payload from Health Connect / HealthKit and uploads it
/// to the server (see docs/SERVER_SCHEMA.md for the contract).
///
/// Auth: registers a device-scoped account on first use and persists the JWT.
/// If the token is missing or rejected (401), it re-registers transparently.
class HealthSyncUploader {
  HealthSyncUploader(this._health);

  final Health _health;

  /// Server base URL. Override at build time with
  /// `--dart-define=HEALTH_SYNC_URL=http://host:3000/v1`.
  /// Default targets the LAN dev server; the Android emulator reaches the host
  /// via 10.0.2.2.
  static const _baseUrl = String.fromEnvironment(
    'HEALTH_SYNC_URL',
    defaultValue: 'http://192.168.86.182:3000/v1',
  );

  // Keep in sync with pubspec `version`.
  static const _clientVersion = '1.0.0+1';

  /// How far back to sync.
  static const _windowDays = 30;

  // Reads are chunked so a single platform-channel transaction never carries a
  // huge sample count (which ANRs the app). Heart rate is high-frequency, so it
  // gets the smallest window.
  static const _hrChunk = Duration(hours: 6);
  static const _spanChunk = Duration(days: 1);

  static const _tokenKey = 'health_sync_token';
  static const _athleteIdKey = 'health_sync_athlete_id';

  /// Reads health data and uploads it. [onProgress] reports human-readable
  /// status for the UI.
  Future<HealthSyncResult> upload({
    required void Function(String) onProgress,
  }) async {
    onProgress('Reading health data…');
    final now = DateTime.now();
    final windowStart = now.subtract(const Duration(days: _windowDays));

    final heartRate =
        await _readChunked(HealthDataType.HEART_RATE, windowStart, now, _hrChunk);
    final steps =
        await _readChunked(HealthDataType.STEPS, windowStart, now, _spanChunk);
    final distance = await _readChunked(
        HealthDataType.DISTANCE_DELTA, windowStart, now, _spanChunk);
    final calories = await _readChunked(
        HealthDataType.TOTAL_CALORIES_BURNED, windowStart, now, _spanChunk);
    final workouts =
        await _readChunked(HealthDataType.WORKOUT, windowStart, now, _spanChunk);

    final payload = _buildPayload(
      athleteId: 0, // filled in after auth, below
      windowStart: windowStart,
      windowEnd: now,
      heartRate: heartRate,
      steps: steps,
      distance: distance,
      calories: calories,
      workouts: workouts,
    );
    final recordCount = heartRate.length +
        steps.length +
        distance.length +
        calories.length +
        workouts.length;

    onProgress('Authenticating…');
    var auth = await _loadAuth();
    auth ??= await _register();

    // Server validates athlete_id against the token principal.
    payload['athlete_id'] = auth.athleteId;

    onProgress('Compressing $recordCount records…');
    final gzipped = await compute(_encodeGzip, payload);

    onProgress('Uploading ${_mb(gzipped.length)}…');
    var response = await _post(gzipped, auth.token);

    // Token expired / invalid → re-register once and retry.
    if (response.statusCode == 401) {
      onProgress('Re-authenticating…');
      auth = await _register();
      payload['athlete_id'] = auth.athleteId;
      final retry = await compute(_encodeGzip, payload);
      response = await _post(retry, auth.token);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HealthSyncException(
        'Server returned ${response.statusCode}: ${response.body}',
      );
    }

    final body = json.decode(response.body) as Map<String, dynamic>;
    return HealthSyncResult(
      body['batch_id'] as int,
      (body['counts'] as Map?)?.cast<String, dynamic>() ?? const {},
      recordCount,
    );
  }

  Future<http.Response> _post(List<int> gzipped, String token) {
    return http.post(
      Uri.parse('$_baseUrl/health-sync'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
      },
      body: gzipped,
    );
  }

  /// Reads [type] over [start, end] in [chunk]-sized windows so no single read
  /// returns an unbounded number of samples, then de-duplicates boundary overlaps.
  Future<List<HealthDataPoint>> _readChunked(
    HealthDataType type,
    DateTime start,
    DateTime end,
    Duration chunk,
  ) async {
    final out = <HealthDataPoint>[];
    var s = start;
    while (s.isBefore(end)) {
      var e = s.add(chunk);
      if (e.isAfter(end)) e = end;
      out.addAll(await _health.getHealthDataFromTypes(
        startTime: s,
        endTime: e,
        types: [type],
      ));
      s = e;
    }
    return _health.removeDuplicates(out);
  }

  Map<String, dynamic> _buildPayload({
    required int athleteId,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<HealthDataPoint> heartRate,
    required List<HealthDataPoint> steps,
    required List<HealthDataPoint> distance,
    required List<HealthDataPoint> calories,
    required List<HealthDataPoint> workouts,
  }) {
    String iso(DateTime t) => t.toUtc().toIso8601String();
    num value(HealthDataPoint p) => (p.value as NumericHealthValue).numericValue;

    // Shape B: interval sample with a measured value. [asInt] for counts (steps),
    // false for continuous quantities (meters, kilocalories).
    List<Map<String, dynamic>> spans(List<HealthDataPoint> pts,
            {required bool asInt}) =>
        [
          for (final p in pts)
            {
              'start': iso(p.dateFrom),
              'end': iso(p.dateTo),
              'value': asInt ? value(p).round() : value(p),
              'recording_method': p.recordingMethod.name,
            },
        ];

    return {
      'type': 'health_sync',
      'athlete_id': athleteId,
      'client_version': _clientVersion,
      'source_platform':
          Platform.isIOS ? 'appleHealth' : 'googleHealthConnect',
      'uploaded_at': iso(DateTime.now()),
      'window_start': iso(windowStart),
      'window_end': iso(windowEnd),
      'heart_rate_samples': [
        for (final p in heartRate)
          {
            'time': iso(p.dateFrom),
            'value': value(p).round(),
            'recording_method': p.recordingMethod.name,
          },
      ],
      'step_samples': spans(steps, asInt: true),
      'distance_samples': spans(distance, asInt: false),
      'total_calorie_samples': spans(calories, asInt: false),
      'workouts': [
        for (final p in workouts)
          {
            'start_time': iso(p.dateFrom),
            'end_time': iso(p.dateTo),
            'activity_type':
                (p.value as WorkoutHealthValue).workoutActivityType.name,
            'recording_method': p.recordingMethod.name,
          },
      ],
    };
  }

  // ---- auth ----------------------------------------------------------------

  Future<_Auth?> _loadAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final athleteId = prefs.getInt(_athleteIdKey);
    if (token == null || athleteId == null) return null;
    return _Auth(token, athleteId);
  }

  /// Registers a fresh device-scoped account. There is no login endpoint, so a
  /// lost/expired token means a new account; we persist the new one.
  Future<_Auth> _register() async {
    final suffix = '${DateTime.now().millisecondsSinceEpoch}'
        '${Random().nextInt(1 << 20)}';
    final username = 'xc_$suffix';
    final response = await http.post(
      Uri.parse('$_baseUrl/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'username': username,
        'email': '$username@xctraining.local',
        'password': _randomPassword(),
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HealthSyncException(
        'Registration failed (${response.statusCode}): ${response.body}',
      );
    }
    final body = json.decode(response.body) as Map<String, dynamic>;
    final auth = _Auth(body['token'] as String, body['athlete_id'] as int);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, auth.token);
    await prefs.setInt(_athleteIdKey, auth.athleteId);
    return auth;
  }

  String _randomPassword() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(24, (_) => chars[rnd.nextInt(chars.length)]).join();
  }
}

/// Runs in a background isolate (via [compute]) to keep JSON encoding and gzip
/// off the UI thread — the payload can be tens of MB.
List<int> _encodeGzip(Map<String, dynamic> payload) =>
    gzip.encode(utf8.encode(json.encode(payload)));

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class _Auth {
  _Auth(this.token, this.athleteId);
  final String token;
  final int athleteId;
}

class HealthSyncException implements Exception {
  HealthSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}
