import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

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

  static const _types = [
    HealthDataType.HEART_RATE,
    HealthDataType.STEPS,
    HealthDataType.WORKOUT,
  ];

  static const _permissions = [
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
  ];

  static const _settingsChannel =
      MethodChannel('com.xctraining/health_perms');

  String _status = 'Tap below to grant permissions';
  int? _heartRate;
  bool _loading = false;
  bool _needsSettingsFallback = false;

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
    final granted = await _health.requestAuthorization(
      _types,
      permissions: _permissions,
    );
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
          ],
        ),
      ),
    );
  }
}
