# xc_training_app

Cross-platform Flutter app that reads health data and uploads it to a server.

## Project goal

Read health data (heart rate, steps, workouts) from Health Connect on Android and HealthKit on iOS, then upload it to a backend server. The iOS HealthKit integration is planned but not yet implemented.

## Tech stack

- Flutter 3.44.2, Dart 3.12.2
- `health: ^13.3.1` — wraps Health Connect (Android) and HealthKit (iOS)
- Android minimum SDK: 26 (Health Connect requirement)
- Package ID: `com.xctraining.xc_training_app`

## Current state

Single-screen app (`lib/main.dart`) that:
1. Checks if Health Connect is installed, offers to install it if not
2. Requests READ permissions for heart rate, steps, and workouts
3. Displays the most recent heart rate reading as a single number in bpm

## Android Health Connect setup

Permissions declared in `android/app/src/main/AndroidManifest.xml`:
- `android.permission.health.READ_HEART_RATE`
- `android.permission.health.READ_STEPS`
- `android.permission.health.READ_EXERCISE`

The `<activity>` includes an `androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE` intent filter, required by Health Connect policy. The `<queries>` block includes the Health Connect package so the app can detect and launch it.

## health package API notes (v13)

```dart
final health = Health();
await health.configure();                          // call once on init
await health.isHealthConnectAvailable();           // check before any call
await health.installHealthConnect();               // redirect to Play Store
await health.requestAuthorization(types, permissions: perms);
await health.getHealthDataFromTypes(startTime: ..., endTime: ..., types: [...]);
// value is NumericHealthValue with .numericValue (num)
```

## Planned next steps

- Upload health data to backend server (endpoint TBD)
- iOS HealthKit support
- Background sync
- Additional data types (HRV, sleep, blood oxygen)
