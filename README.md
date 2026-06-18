# xc_training_app

A cross-platform Flutter app that reads an athlete's health data from
**Health Connect** (Android) and uploads it to a training-analysis backend.
HealthKit (iOS) support is planned.

> Status: Android is working end-to-end (read → display → upload). iOS HealthKit
> is not implemented yet.

## Features

- Requests Health Connect read access for heart rate, HRV, resting HR,
  respiratory rate, steps, distance, active calories, sleep, and workouts.
- Shows the most recent heart rate as a single number.
- Uploads a 30-day window of all of the above to the server as a single gzipped
  `health_sync` payload, then reports the server's batch id and per-metric counts.
- Handles the awkward parts of platform-integrated Health Connect (Android 14+):
  the permission-rationale activity-alias, the `FlutterFragmentActivity`
  requirement, and the hidden permissions that workout reads depend on.

## How it works

```
Health Connect ──read──▶ xc_training_app ──gzip + POST──▶ server (/v1/health-sync)
                                  │
                                  └── displays latest heart rate
```

1. **Auth** — on first upload the app registers a device-scoped account
   (`POST /v1/auth/register`) and persists the returned JWT.
2. **Read** — health data is read in time-chunks (heart rate in 6-hour windows,
   everything else daily) so no single platform-channel call returns an unbounded
   number of samples.
3. **Upload** — the payload is JSON-encoded and gzipped in a background isolate,
   then `POST`ed with `Authorization: Bearer <token>` and
   `Content-Encoding: gzip`.

The payload format (the contract with the backend) is documented in
[docs/SERVER_SCHEMA.md](docs/SERVER_SCHEMA.md).

## Tech stack

- Flutter 3.44 / Dart 3.12
- [`health`](https://pub.dev/packages/health) `^13.3.1` — Health Connect / HealthKit
- [`http`](https://pub.dev/packages/http) — server upload
- [`shared_preferences`](https://pub.dev/packages/shared_preferences) — token storage
- Android `minSdk` 26 (Health Connect requirement)

## Getting started

### Prerequisites

- Flutter SDK 3.44+
- An Android device or emulator running API 26+ with **Health Connect** available
  (built into the platform on Android 14+; a separate app to install on older
  versions — the app will prompt).
- A running backend that implements the [server contract](docs/SERVER_SCHEMA.md).

### Run

```sh
flutter pub get
flutter run
```

### Configure the server URL

The upload endpoint defaults to a LAN dev address. Override it at build time:

```sh
# Physical device on the same Wi-Fi as the server
flutter run --dart-define=HEALTH_SYNC_URL=http://192.168.1.50:3000/v1

# Android emulator reaching a server on the host machine
flutter run --dart-define=HEALTH_SYNC_URL=http://10.0.2.2:3000/v1
```

> If you test from a **physical phone** against a server on your PC, make sure the
> server's port is allowed through the host firewall and the phone is on the same
> network.

## Project structure

```
lib/
  main.dart                  UI: permission flow, heart-rate display, upload button
  health_sync_uploader.dart  Reads Health Connect data, builds + uploads the payload
tool/
  analyze_health_data.dart   Introspects a health_sync payload into an empirical schema
docs/
  SERVER_SCHEMA.md           The upload payload contract for the backend team
android/
  app/src/main/AndroidManifest.xml   Health Connect permissions + rationale activities
  .../MainActivity.kt        FlutterFragmentActivity + Health Connect settings channel
```

## Inspecting a payload

`tool/analyze_health_data.dart` prints an empirical schema (fields, types, value
ranges, timestamp spans, record counts) for any `health_sync` JSON file — handy
for validating what the app sends or what a backend receives:

```sh
dart run tool/analyze_health_data.dart path/to/payload.json
```

## Android / Health Connect notes

A few Android 14+ specifics that are easy to miss (full detail in
[CLAUDE.md](CLAUDE.md)):

- `MainActivity` extends `FlutterFragmentActivity` so the `health` plugin's
  permission launcher registers.
- The manifest declares a `VIEW_PERMISSION_USAGE` / `HEALTH_PERMISSIONS`
  `activity-alias`; without it, reads fail with *"Incorrect health permission
  state."*
- Reading workouts requires `READ_DISTANCE` and `READ_TOTAL_CALORIES_BURNED` —
  the plugin enriches each session with its distance/energy summary.

## Roadmap

- iOS HealthKit support.
- Background sync.
- Real auth (a login endpoint) instead of re-registering when a token is lost.
