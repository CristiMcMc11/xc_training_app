import 'package:flutter/material.dart';
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

class _HeartRateScreenState extends State<HeartRateScreen> {
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

  String _status = 'Tap below to grant permissions';
  int? _heartRate;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _health.configure();
  }

  Future<void> _requestAndFetch() async {
    setState(() {
      _loading = true;
      _status = 'Checking Health Connect…';
    });

    final available = await _health.isHealthConnectAvailable();
    if (!available) {
      setState(() {
        _status = 'Health Connect not available — redirecting to install…';
        _loading = false;
      });
      await _health.installHealthConnect();
      return;
    }

    setState(() => _status = 'Requesting permissions…');

    final granted = await _health.requestAuthorization(_types, permissions: _permissions);
    if (!granted) {
      setState(() {
        _status = 'Permissions denied';
        _loading = false;
      });
      return;
    }

    setState(() => _status = 'Fetching heart rate…');

    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(hours: 24));
    final points = await _health.getHealthDataFromTypes(
      startTime: yesterday,
      endTime: now,
      types: [HealthDataType.HEART_RATE],
    );

    if (points.isEmpty) {
      setState(() {
        _status = 'No heart rate data in the last 24 hours';
        _loading = false;
      });
      return;
    }

    points.sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
    final latest = points.first.value as NumericHealthValue;
    setState(() {
      _heartRate = latest.numericValue.round();
      _status = 'Most recent heart rate';
      _loading = false;
    });
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
            Text(_status, style: theme.textTheme.titleMedium),
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
