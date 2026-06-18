# xc_training_app

Cross-platform Flutter app that reads health data and uploads it to a server.

## Project goal

Read health data (heart rate, steps, workouts) from Health Connect on Android and HealthKit on iOS, then upload it to a backend server. The iOS HealthKit integration is planned but not yet implemented.

## Tech stack

- Flutter 3.44.2, Dart 3.12.2
- `health: ^13.3.1` — wraps Health Connect (Android) and HealthKit (iOS)
- `http` — server upload; `shared_preferences` — persists the auth token
- Android minimum SDK: 26 (Health Connect requirement)
- Package ID: `com.xctraining.xc_training_app`

## Current state

Single-screen app (`lib/main.dart`) that:
1. Checks if Health Connect is installed, offers to install it if not
2. Requests READ permissions for heart rate, steps, workouts, distance, calories,
   HRV, resting HR, respiratory rate, and sleep
3. Displays the most recent heart rate reading as a single number in bpm
4. **Uploads the full schema** to the server — heart rate, HRV, resting HR,
   respiratory rate, steps, distance, calories, sleep (sessions + stages), and
   workouts (see `lib/health_sync_uploader.dart` and `docs/SERVER_SCHEMA.md`)

## Server upload (`lib/health_sync_uploader.dart`)

- Base URL via `--dart-define=HEALTH_SYNC_URL=...` (default targets the LAN dev
  server `http://192.168.86.182:3000/v1`; the Android emulator reaches a host
  server via `10.0.2.2`).
- Auth: `POST /v1/auth/register` `{username,email,password}` → `{athlete_id, token}`.
  Token persisted in shared_preferences; re-registers on 401. (No login endpoint
  yet, so a lost/expired token means a new account.)
- Sync: `POST /v1/health-sync` with `Authorization: Bearer <token>`,
  `Content-Encoding: gzip` → `{batch_id, counts:{...}}`. Server validates
  `athlete_id` against the token principal.
- Reads are **chunked** (heart rate in 6h windows, others in 1-day) so a single
  platform-channel transaction never carries an unbounded sample count (that ANRs
  the app). JSON encode + gzip run in a background isolate via `compute`.

## Android Health Connect setup

Permissions declared in `android/app/src/main/AndroidManifest.xml`:
- `READ_HEART_RATE`, `READ_STEPS`, `READ_EXERCISE`
- `READ_DISTANCE`, `READ_TOTAL_CALORIES_BURNED` — **required to read WORKOUT**: the
  plugin enriches each exercise session with its distance/energy summary and fails
  hard (`SecurityException`, swallowed → 0 workouts) without them.

Two permission-rationale declarations are required:
- `<activity>` intent filter `androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE`
  (Android 13 and below).
- `<activity-alias>` `ViewPermissionUsageActivity` handling
  `android.intent.action.VIEW_PERMISSION_USAGE` + category
  `android.intent.category.HEALTH_PERMISSIONS` (Android 14+, where Health Connect
  is part of the platform). Without it, **reads fail** with "Incorrect health
  permission state."

`MainActivity` extends `FlutterFragmentActivity` (not `FlutterActivity`) so the
health plugin's permission launcher registers. The `<queries>` block includes the
Health Connect package so the app can detect and launch it.

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

- iOS HealthKit support
- Background sync
- Real auth (login endpoint) instead of re-register on token loss
