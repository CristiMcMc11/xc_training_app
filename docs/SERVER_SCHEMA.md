# Health Sync — Server Ingest Schema

**Audience:** server / backend team building the ingest + analysis service
**Status:** draft contract, derived empirically from a representative upload payload
**Last updated:** 2026-06-15

---

## 1. Purpose

The `xc_training_app` mobile client reads an athlete's health data from **Health
Connect (Android)** and, later, **HealthKit (iOS)**, then uploads it to the
server as a single JSON document we call a **health-sync payload**. This document
specifies that payload so the server team can build ingest, storage, and
analysis.

This schema was reverse-engineered from a real payload
(`source_platform: googleHealthConnect`, `client_version: 1.0.0+1`) covering a
30-day window (2026-05-12 → 2026-06-11) with **~281,000 records**. The numeric
ranges quoted below are *observed* values from that sample, not hard limits —
treat them as sanity-check guidance, not validation bounds.

A tool to regenerate this analysis from any payload lives at
[tool/analyze_health_data.dart](../tool/analyze_health_data.dart):

```sh
dart run tool/analyze_health_data.dart path/to/payload.json
```

---

## 2. Transport (proposed — open for discussion)

| Aspect | Proposal |
|---|---|
| Method / path | `POST /v1/health-sync` |
| Content-Type | `application/json` |
| Encoding | UTF-8 |
| Compression | `Content-Encoding: gzip` strongly recommended — payloads are large (the sample is 21 MB uncompressed, dominated by heart rate) |
| Auth | Bearer token identifying the device/athlete (TBD with app team) |
| Idempotency | Client should send an `Idempotency-Key` header; see **§7 Deduplication** |
| Response | `202 Accepted` with a server-assigned `batch_id`; ingest may be async |
| Max body size | Must accommodate **>25 MB** uncompressed; prefer gzip + streaming parse |

> ⚠️ **Volume warning:** heart rate alone was **274,241 of 281,361 records (97%)**
> in the sample. Do not load the whole body into memory and `JSON.parse` naively
> under load — use a streaming parser and batch inserts.

---

## 3. Payload envelope

Top-level object. All timestamps are **ISO-8601, UTC (`Z` suffix)**.

| Field | Type | Example | Notes |
|---|---|---|---|
| `type` | string (const) | `"health_sync"` | Discriminator; always `health_sync`. Reject otherwise. |
| `athlete_id` | integer | `1` | The subject. Maps to your athlete/user. |
| `client_version` | string | `"1.0.0+1"` | App `version+build`. Use for schema-evolution handling. |
| `source_platform` | enum string | `"googleHealthConnect"` | Origin of the data. See **§6**. |
| `uploaded_at` | timestamp | `2026-06-11T02:52:22.696038Z` | When the client generated the payload. |
| `window_start` | timestamp | `2026-05-12T02:52:22.696038Z` | Inclusive start of the sync coverage window. |
| `window_end` | timestamp | `2026-06-11T02:52:22.696038Z` | Inclusive end of the sync coverage window. |
| *(sample arrays)* | array | — | Zero or more of the arrays in **§4**. May be empty or absent. |

The `window_start`/`window_end` define the period the client *attempted* to
cover. Absence of samples in that window means "no data recorded," not "not
synced."

---

## 4. Sample arrays

Every record carries a `recording_method` (data provenance — see **§6**). Beyond
that, records fall into **five structural shapes**. The array name is the only
indicator of the metric — the metric is **not** repeated inside each record.

### Shape A — Instantaneous point: `{ time, value, recording_method }`

| Array | Records (sample) | `value` type | Unit | Observed range |
|---|---|---|---|---|
| `heart_rate_samples` | 274,241 | integer | bpm | 56 – 182 |
| `hrv_rmssd_samples` | 589 | double | milliseconds (RMSSD) | 5.7 – 28.7 |
| `resting_heart_rate_samples` | 8 | integer | bpm | 77 – 88 |
| `respiratory_rate_samples` | 8 | double | breaths/min | 13.6 – 15.4 |

```json
{ "time": "2026-06-02T22:29:12.000Z", "value": 160, "recording_method": "automatic" }
```

### Shape B — Interval with a measured value: `{ start, end, value, recording_method }`

| Array | Records (sample) | `value` type | Unit | Observed range |
|---|---|---|---|---|
| `step_samples` | 3,104 | integer | count | 1 – 1,050 |
| `distance_samples` | 1,618 | double | meters | 0.2 – 3,519.6 |
| `total_calorie_samples` | 789 | double | kilocalories | 1.14 – 421.0 |

`value` is the total accumulated **over the `[start, end]` interval** (steps
taken, meters covered, kcal burned in that span), not a rate.

```json
{ "start": "2026-06-02T23:43:00.000Z", "end": "2026-06-02T23:44:00.000Z", "value": 22.1, "recording_method": "automatic" }
```

### Shape C — Sleep session: `{ uuid, start, end, recording_method }`

| Array | Records (sample) | Notes |
|---|---|---|
| `sleep_sessions` | 8 | `uuid` is the **session identifier**. Stages (Shape D) reference it. |

```json
{ "uuid": "81694f2a-705b-320d-a44a-52fb91a999e9", "start": "2026-06-03T05:46:00.000Z", "end": "2026-06-03T11:08:00.000Z", "recording_method": "automatic" }
```

### Shape D — Sleep stage interval: `{ uuid, start, end, recording_method }`

| Array | Records (sample) | Stage |
|---|---|---|
| `sleep_light_samples` | 168 | light |
| `sleep_awake_samples` | 131 | awake |
| `sleep_rem_samples` | 41 | REM |
| `sleep_deep_samples` | 34 | deep |

The stage type is encoded by the **array name**. Each stage's `uuid` is a
**foreign key to `sleep_sessions.uuid`**; multiple stage rows belong to one
session and tile its `[start, end]`. Structurally identical to Shape C, but
semantically a child.

### Shape E — Workout / exercise session: `{ start_time, end_time, activity_type, recording_method }`

| Array | Records (sample) | Notes |
|---|---|---|
| `workouts` | 5 | ⚠️ Uses `start_time` / `end_time`, **not** `start` / `end` (see §7). No `value`. |

```json
{ "start_time": "2026-06-06T15:53:49.000Z", "end_time": "2026-06-06T16:02:36.000Z", "activity_type": "RUNNING", "recording_method": "unknown" }
```

---

## 5. Full array reference (quick index)

| Array | Shape | Time field(s) | Value | Unit | Links |
|---|---|---|---|---|---|
| `heart_rate_samples` | A | `time` | int | bpm | — |
| `hrv_rmssd_samples` | A | `time` | double | ms | — |
| `resting_heart_rate_samples` | A | `time` | int | bpm | — |
| `respiratory_rate_samples` | A | `time` | double | breaths/min | — |
| `step_samples` | B | `start`,`end` | int | count | — |
| `distance_samples` | B | `start`,`end` | double | meters | — |
| `total_calorie_samples` | B | `start`,`end` | double | kcal | — |
| `sleep_sessions` | C | `start`,`end` | — | — | `uuid` (PK) |
| `sleep_light_samples` | D | `start`,`end` | — | — | `uuid` → session |
| `sleep_awake_samples` | D | `start`,`end` | — | — | `uuid` → session |
| `sleep_rem_samples` | D | `start`,`end` | — | — | `uuid` → session |
| `sleep_deep_samples` | D | `start`,`end` | — | — | `uuid` → session |
| `workouts` | E | `start_time`,`end_time` | — | — | — |

---

## 6. Enumerations

### `source_platform`
| Value | Meaning |
|---|---|
| `googleHealthConnect` | Android / Health Connect (only value seen so far) |
| `appleHealth` | iOS / HealthKit (planned; confirm exact string with app team) |

### `recording_method` (data provenance / quality)
Observed values: **`automatic`**, **`manual`**, **`active`**, **`unknown`**.
Mirrors Health Connect's recording-method metadata. Not every value appears for
every metric (e.g. heart rate was all `automatic`; distance showed all four).
**Treat as an open set** — store the raw string, don't hard-enum it in a way that
rejects unknown future values.

### `activity_type` (workouts only)
Observed: **`RUNNING`**, **`WALKING`**. This is a **much larger open set** — the
client maps from a long list of exercise types (cycling, swimming, hiking, yoga,
strength training, etc.). Store as a string; map to your own taxonomy
downstream. Do not reject unrecognized values.

### Sleep stages
Encoded by array name: `light`, `awake`, `rem`, `deep`. (Health Connect also
defines `sleeping`, `out_of_bed`, `unknown` stages — not present in the sample
but possible in future payloads.)

---

## 7. Data-quality notes & gotchas

1. **Inconsistent time-field naming.** `workouts` uses `start_time`/`end_time`;
   every other interval array uses `start`/`end`; instantaneous arrays use
   `time`. Your parser must special-case workouts. *(Flagged to the app team as a
   candidate to normalize in a future `client_version`; until then, handle both.)*

2. **Metric identity is positional**, carried by the array name, not a field
   inside the record. When you flatten records, inject the metric/stage from the
   array key.

3. **Heart rate dominates volume.** Size your ingest, indexes, and batch sizes
   for it. Expect bursts of high-frequency samples (≈1 Hz during workouts).

4. **Timestamps are UTC**, sub-second precision varies (`.000Z` vs `.696038Z`).
   Parse as full ISO-8601; don't assume millisecond precision.

5. **Intervals can be very short** (e.g. a 2-second step span) or hours long
   (sleep). `start == end` is possible in edge cases; the client guarantees
   `end >= start`.

6. **Deduplication.** Uploads are **not** guaranteed unique — re-syncs and
   overlapping windows can resend the same sample. There is no per-sample id
   (except sleep `uuid`). Recommended natural keys for idempotent upsert:
   - Shape A: `(athlete_id, metric, time, recording_method)`
   - Shape B: `(athlete_id, metric, start, end, recording_method)`
   - Shape C/D: `(athlete_id, uuid, stage, start)` — `uuid` identifies the session
   - Shape E: `(athlete_id, start_time, end_time, activity_type)`

   Also consider a payload-level `Idempotency-Key` to drop whole duplicate
   uploads cheaply.

7. **`athlete_id` is client-supplied.** Validate it against the authenticated
   principal server-side; don't trust it blindly.

---

## 8. Suggested storage model

A normalized relational sketch (PostgreSQL flavor; **TimescaleDB or native
partitioning recommended** for the time-series tables given HR volume).

```sql
-- One row per accepted upload.
CREATE TABLE sync_batch (
  batch_id        BIGSERIAL PRIMARY KEY,
  athlete_id      BIGINT      NOT NULL,
  source_platform TEXT        NOT NULL,
  client_version  TEXT        NOT NULL,
  window_start    TIMESTAMPTZ NOT NULL,
  window_end      TIMESTAMPTZ NOT NULL,
  uploaded_at     TIMESTAMPTZ NOT NULL,
  received_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Shapes A: instantaneous point metrics (heart_rate, hrv_rmssd, resting_hr, respiratory_rate).
CREATE TABLE instantaneous_sample (
  athlete_id      BIGINT      NOT NULL,
  metric          TEXT        NOT NULL,          -- 'heart_rate' | 'hrv_rmssd' | ...
  ts              TIMESTAMPTZ NOT NULL,
  value           DOUBLE PRECISION NOT NULL,
  recording_method TEXT       NOT NULL,
  batch_id        BIGINT      NOT NULL REFERENCES sync_batch,
  PRIMARY KEY (athlete_id, metric, ts, recording_method)
);  -- hypertable on ts

-- Shape B: interval metrics with a value (steps, distance, total_calories).
CREATE TABLE interval_sample (
  athlete_id      BIGINT      NOT NULL,
  metric          TEXT        NOT NULL,          -- 'steps' | 'distance' | 'total_calories'
  start_ts        TIMESTAMPTZ NOT NULL,
  end_ts          TIMESTAMPTZ NOT NULL,
  value           DOUBLE PRECISION NOT NULL,
  recording_method TEXT       NOT NULL,
  batch_id        BIGINT      NOT NULL REFERENCES sync_batch,
  PRIMARY KEY (athlete_id, metric, start_ts, end_ts, recording_method)
);  -- hypertable on start_ts

-- Shape C: sleep sessions.
CREATE TABLE sleep_session (
  athlete_id      BIGINT      NOT NULL,
  session_uuid    UUID        NOT NULL,
  start_ts        TIMESTAMPTZ NOT NULL,
  end_ts          TIMESTAMPTZ NOT NULL,
  recording_method TEXT       NOT NULL,
  batch_id        BIGINT      NOT NULL REFERENCES sync_batch,
  PRIMARY KEY (athlete_id, session_uuid)
);

-- Shape D: sleep stages (child of sleep_session via session_uuid).
CREATE TABLE sleep_stage (
  athlete_id      BIGINT      NOT NULL,
  session_uuid    UUID        NOT NULL,
  stage           TEXT        NOT NULL,          -- 'light' | 'awake' | 'rem' | 'deep'
  start_ts        TIMESTAMPTZ NOT NULL,
  end_ts          TIMESTAMPTZ NOT NULL,
  recording_method TEXT       NOT NULL,
  batch_id        BIGINT      NOT NULL REFERENCES sync_batch,
  PRIMARY KEY (athlete_id, session_uuid, stage, start_ts)
);

-- Shape E: workouts.
CREATE TABLE workout (
  athlete_id      BIGINT      NOT NULL,
  start_ts        TIMESTAMPTZ NOT NULL,
  end_ts          TIMESTAMPTZ NOT NULL,
  activity_type   TEXT        NOT NULL,
  recording_method TEXT       NOT NULL,
  batch_id        BIGINT      NOT NULL REFERENCES sync_batch,
  PRIMARY KEY (athlete_id, start_ts, end_ts, activity_type)
);
```

All `PRIMARY KEY`s double as the dedup natural keys from §7, so ingest can be a
plain `INSERT ... ON CONFLICT DO NOTHING` (or `DO UPDATE` to let the newest batch
win).

---

## 9. Analysis the model enables (for product context)

- **Training load / intensity:** heart-rate time-in-zone per workout, from
  `heart_rate_samples` joined to `workouts` by time overlap.
- **Recovery:** overnight HRV (`hrv_rmssd_samples`) and resting HR trends vs.
  training load.
- **Sleep quality:** stage durations per night (`sleep_stage` grouped by
  `session_uuid`), sleep efficiency = asleep / time-in-bed.
- **Volume:** daily/weekly steps, distance, active calories from `interval_sample`.
- **Workout summaries:** pace and distance per `RUNNING`/`WALKING` session.

---

## 10. Validation rules (recommended)

Reject (4xx) the whole payload if:
- `type != "health_sync"`
- `athlete_id` missing or doesn't match the authenticated principal
- `window_start > window_end`
- any timestamp unparseable as ISO-8601

Accept-but-flag (ingest, log a warning) if:
- a record's `end < start`
- a sleep stage `uuid` has no matching `sleep_sessions` entry in the same payload
  (sessions may arrive in a later/earlier batch — resolve asynchronously)
- an unrecognized `recording_method`, `activity_type`, `source_platform`, or a
  new array name (forward-compat: store, don't crash)

---

## 11. Versioning

`client_version` (`major.minor.patch+build`) identifies the producing app build.
The payload shape may evolve (e.g. the `start_time`/`start` normalization in §7,
new metric arrays). Server should:
- key parsing behavior off `client_version` where shapes differ,
- treat **unknown top-level arrays as additive** (store raw or ignore, never
  reject), and
- never assume the set of arrays in §4 is exhaustive in future payloads.

---

## 12. Trimmed example payload

```json
{
  "type": "health_sync",
  "athlete_id": 1,
  "client_version": "1.0.0+1",
  "source_platform": "googleHealthConnect",
  "uploaded_at": "2026-06-11T02:52:22.696038Z",
  "window_start": "2026-05-12T02:52:22.696038Z",
  "window_end": "2026-06-11T02:52:22.696038Z",
  "heart_rate_samples": [
    { "time": "2026-06-02T22:29:12.000Z", "value": 160, "recording_method": "automatic" }
  ],
  "step_samples": [
    { "start": "2026-05-28T02:27:11.164Z", "end": "2026-05-28T02:27:13.164Z", "value": 1, "recording_method": "automatic" }
  ],
  "distance_samples": [
    { "start": "2026-06-02T23:43:00.000Z", "end": "2026-06-02T23:44:00.000Z", "value": 22.1, "recording_method": "automatic" }
  ],
  "total_calorie_samples": [
    { "start": "2026-06-02T21:45:00.000Z", "end": "2026-06-02T22:00:00.000Z", "value": 13.62, "recording_method": "unknown" }
  ],
  "hrv_rmssd_samples": [
    { "time": "2026-06-03T05:45:00.000Z", "value": 18.4, "recording_method": "unknown" }
  ],
  "resting_heart_rate_samples": [
    { "time": "2026-06-03T11:08:00.000Z", "value": 88, "recording_method": "unknown" }
  ],
  "respiratory_rate_samples": [
    { "time": "2026-06-03T11:08:00.000Z", "value": 15.4, "recording_method": "unknown" }
  ],
  "sleep_sessions": [
    { "uuid": "81694f2a-705b-320d-a44a-52fb91a999e9", "start": "2026-06-03T05:46:00.000Z", "end": "2026-06-03T11:08:00.000Z", "recording_method": "automatic" }
  ],
  "sleep_deep_samples": [
    { "uuid": "81694f2a-705b-320d-a44a-52fb91a999e9", "start": "2026-06-03T06:00:30.000Z", "end": "2026-06-03T06:39:00.000Z", "recording_method": "unknown" }
  ],
  "workouts": [
    { "start_time": "2026-06-06T15:53:49.000Z", "end_time": "2026-06-06T16:02:36.000Z", "activity_type": "RUNNING", "recording_method": "unknown" }
  ]
}
```

---

## 13. Open questions for the app & server teams

1. Confirm the iOS `source_platform` string (`appleHealth`?) and whether HealthKit
   introduces new arrays/units.
2. Should `workouts` be normalized to `start`/`end` in a future `client_version`?
3. Auth model and how `athlete_id` binds to an authenticated device/user.
4. Expected upload cadence and window size (daily? on-demand?) — drives dedup and
   partitioning strategy.
5. Does the client need a per-record id added at the source to make dedup exact,
   rather than relying on natural keys?
