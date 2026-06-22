import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One GPS sample along a recorded route.
class RoutePoint {
  RoutePoint({
    required this.time,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
  });

  final DateTime time;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed;

  Map<String, dynamic> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        if (altitude != null) 'altitude': altitude,
        if (accuracy != null) 'accuracy': accuracy,
        if (speed != null) 'speed': speed,
      };

  factory RoutePoint.fromJson(Map<String, dynamic> j) => RoutePoint(
        time: DateTime.parse(j['time'] as String),
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        altitude: (j['altitude'] as num?)?.toDouble(),
        accuracy: (j['accuracy'] as num?)?.toDouble(),
        speed: (j['speed'] as num?)?.toDouble(),
      );
}

/// A workout recorded in-app from GPS — distinct from Health Connect `workouts`.
class RecordedWorkout {
  RecordedWorkout({
    required this.startTime,
    required this.endTime,
    required this.route,
  });

  final DateTime startTime;
  final DateTime endTime;
  final List<RoutePoint> route;

  Map<String, dynamic> toJson() => {
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
        'source': 'app_gps',
        'route': [for (final p in route) p.toJson()],
      };

  factory RecordedWorkout.fromJson(Map<String, dynamic> j) => RecordedWorkout(
        startTime: DateTime.parse(j['start_time'] as String),
        endTime: DateTime.parse(j['end_time'] as String),
        route: [
          for (final p in (j['route'] as List))
            RoutePoint.fromJson(p as Map<String, dynamic>)
        ],
      );
}

/// Records a workout's GPS route between start/stop, persists finished routes
/// until they're uploaded, and notifies listeners as points come in.
class WorkoutRecorder extends ChangeNotifier {
  static const _storageKey = 'recorded_workouts';

  bool _recording = false;
  bool get isRecording => _recording;

  DateTime? _startTime;
  DateTime? get startedAt => _startTime;

  final List<RoutePoint> _current = [];
  int get currentPointCount => _current.length;

  /// The route being recorded right now (empty when not recording).
  List<RoutePoint> get currentRoute => List.unmodifiable(_current);

  StreamSubscription<Position>? _sub;

  final List<RecordedWorkout> _pending = [];

  /// Finished routes not yet uploaded.
  List<RecordedWorkout> get pending => List.unmodifiable(_pending);

  /// Loads persisted (not-yet-uploaded) routes from disk.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? const [];
    _pending
      ..clear()
      ..addAll(raw.map(
          (s) => RecordedWorkout.fromJson(json.decode(s) as Map<String, dynamic>)));
    notifyListeners();
  }

  /// Begins recording. Throws [LocationException] if location is unavailable.
  Future<void> start() async {
    if (_recording) return;
    await _ensureLocationAccess();
    _current.clear();
    _startTime = DateTime.now();
    _recording = true;
    notifyListeners();

    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5, // metres; avoid logging while stationary
      ),
    ).listen((pos) {
      _current.add(RoutePoint(
        time: pos.timestamp,
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: pos.altitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
      ));
      notifyListeners();
    });
  }

  /// Stops recording and stores the route. Returns it, or null if no points.
  Future<RecordedWorkout?> stop() async {
    if (!_recording) return null;
    await _sub?.cancel();
    _sub = null;
    _recording = false;

    RecordedWorkout? workout;
    if (_current.isNotEmpty) {
      workout = RecordedWorkout(
        startTime: _startTime ?? _current.first.time,
        endTime: DateTime.now(),
        route: List.of(_current),
      );
      _pending.add(workout);
      await _persist();
    }
    _current.clear();
    _startTime = null;
    notifyListeners();
    return workout;
  }

  /// Drops [uploaded] routes after a successful upload.
  Future<void> markUploaded(List<RecordedWorkout> uploaded) async {
    _pending.removeWhere(uploaded.contains);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _storageKey, [for (final w in _pending) json.encode(w.toJson())]);
  }

  Future<void> _ensureLocationAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationException('Location services are turned off.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw LocationException('Location permission denied.');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class LocationException implements Exception {
  LocationException(this.message);
  final String message;
  @override
  String toString() => message;
}
