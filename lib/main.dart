import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

import 'health_sync_uploader.dart';

void main() {
  runApp(const XcTrainingApp());
}

class XcTrainingApp extends StatelessWidget {
  const XcTrainingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XC Training',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const HeartRateScreen(),
    );
  }
}

class HeartRateScreen extends StatefulWidget {
  const HeartRateScreen({super.key});

  @override
  State<HeartRateScreen> createState() => _HeartRateScreenState();
}

class _HeartRateScreenState extends State<HeartRateScreen>
    with WidgetsBindingObserver {
  final _health = Health();
  late final _uploader = HealthSyncUploader(_health);

  // Every metric the app reads/uploads. All READ-only, so requestAuthorization
  // defaults (no explicit permissions list needed).
  //
  // DISTANCE and TOTAL_CALORIES are also required to read WORKOUT: the health
  // plugin enriches each exercise session with its distance/energy summary, which
  // fails hard without those read permissions. SLEEP_SESSION's READ_SLEEP grant
  // also covers the individual sleep stages.
  static const _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.WORKOUT,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.SLEEP_SESSION,
  ];

  static const _settingsChannel =
      MethodChannel('com.xctraining/health_perms');

  String _status = 'Tap below to grant permissions';
  int? _heartRate;
  bool _loading = false;
  bool _needsSettingsFallback = false;

  bool _uploading = false;
  String? _uploadStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _health.configure();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check after user returns from Health Connect settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _needsSettingsFallback) {
      _needsSettingsFallback = false;
      _fetchData();
    }
  }

  Future<void> _requestAndFetch() async {
    setState(() {
      _loading = true;
      _status = 'Checking Health Connect…';
    });

    final available = await _health.isHealthConnectAvailable();
    if (!mounted) return;
    if (!available) {
      setState(() {
        _status = 'Health Connect not available — redirecting to install…';
        _loading = false;
      });
      await _health.installHealthConnect();
      return;
    }

    setState(() => _status = 'Requesting permissions…');
    final granted = await _health.requestAuthorization(_types);
    if (!mounted) return;

    if (!granted) {
      // Launcher returned empty — open Health Connect settings as fallback.
      setState(() {
        _status = 'Open Health Connect to grant permissions, then come back.';
        _loading = false;
        _needsSettingsFallback = true;
      });
      try {
        final opened = await _settingsChannel
            .invokeMethod<bool>('openHealthConnectPermissions');
        if (!mounted) return;
        if (opened != true) {
          setState(() => _status =
              'Could not open Health Connect. Grant permissions in Settings.');
        }
      } on PlatformException {
        if (mounted) setState(() => _status = 'Permissions denied');
      } on MissingPluginException {
        if (mounted) setState(() => _status = 'Permissions denied');
      }
      return;
    }

    await _fetchData();
  }

  // To show only the *most recent* heart rate we must avoid pulling a huge
  // span at once — 30 days of samples can be hundreds of thousands of points,
  // which overruns the platform channel and ANRs the app. Instead we scan
  // backward from now in small windows and stop at the first one with data.
  static const _windowHours = 6;
  static const _maxLookbackDays = 30;

  Future<void> _fetchData() async {
    setState(() {
      _loading = true;
      _status = 'Fetching heart rate…';
    });

    try {
      final now = DateTime.now();
      final window = const Duration(hours: _windowHours);
      final maxLookback = now.subtract(const Duration(days: _maxLookbackDays));

      List<HealthDataPoint> points = const [];
      var end = now;
      while (end.isAfter(maxLookback)) {
        var start = end.subtract(window);
        if (start.isBefore(maxLookback)) start = maxLookback;
        points = await _health.getHealthDataFromTypes(
          startTime: start,
          endTime: end,
          types: [HealthDataType.HEART_RATE],
        );
        if (points.isNotEmpty) break;
        end = start;
      }
      if (!mounted) return;

      if (points.isEmpty) {
        setState(() {
          _status = 'No heart rate data in the last $_maxLookbackDays days';
          _loading = false;
        });
        return;
      }

      // Single pass for the newest point — cheaper than sorting the window.
      final latest = points.reduce(
        (a, b) => a.dateFrom.isAfter(b.dateFrom) ? a : b,
      );
      final bpm = (latest.value as NumericHealthValue).numericValue.round();
      setState(() {
        _heartRate = bpm;
        _status = 'Most recent heart rate';
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'Error reading heart rate: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _upload() async {
    setState(() {
      _uploading = true;
      _uploadStatus = 'Starting upload…';
    });
    try {
      final result = await _uploader.upload(
        onProgress: (msg) {
          if (mounted) setState(() => _uploadStatus = msg);
        },
      );
      if (!mounted) return;
      // Summarize every non-zero metric the server counted (drops warnings).
      final counts = Map<String, dynamic>.from(result.counts)
        ..remove('warnings');
      final summary = counts.entries
          .where((e) => e.value is num && (e.value as num) > 0)
          .map((e) => '${e.value} ${e.key}')
          .join(', ');
      setState(() {
        _uploadStatus = 'Uploaded batch #${result.batchId} — '
            '${summary.isEmpty ? 'no records' : summary}';
        _uploading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploadStatus = 'Upload failed: $e';
          _uploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('XC Training'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _status,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (_loading)
              const CircularProgressIndicator()
            else if (_heartRate != null) ...[
              Text(
                '$_heartRate',
                style: theme.textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text('bpm', style: theme.textTheme.titleLarge),
            ],
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: _loading ? null : _requestAndFetch,
              icon: const Icon(Icons.favorite),
              label: Text(_heartRate == null ? 'Grant Permissions & Fetch' : 'Refresh'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: (_loading || _uploading) ? null : _upload,
              icon: _uploading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload),
              label: const Text('Upload to Server'),
            ),
            if (_uploadStatus != null) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _uploadStatus!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
