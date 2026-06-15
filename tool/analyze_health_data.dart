// Health data payload analyzer.
//
// Introspects a health-sync JSON payload (the same shape the app uploads to the
// server, and what the Health Connect Seeder writes) and prints an empirical
// schema: every top-level field, every sample array, the fields inside each
// record, their value types, numeric ranges, timestamp ranges, and the
// distribution of low-cardinality strings (recording_method, activity_type).
//
// Usage:
//   dart run tool/analyze_health_data.dart [path/to/seed.json]
//
// Defaults to the Health Connect Seeder's bundled dataset if no path is given.

import 'dart:convert';
import 'dart:io';

const _defaultPath =
    r'C:\src\code\xc_data_injector\app\src\main\assets\seed.json';

// Strings with more distinct values than this are treated as free-form/high
// cardinality (e.g. uuids) and we only report the count, not every value.
const _maxDistinct = 25;

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : _defaultPath;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('File not found: $path');
    exitCode = 1;
    return;
  }

  stdout.writeln('Analyzing: $path');
  stdout.writeln('Size: ${(file.lengthSync() / (1024 * 1024)).toStringAsFixed(2)} MB\n');

  final root = json.decode(file.readAsStringSync());
  if (root is! Map<String, dynamic>) {
    stderr.writeln('Expected a top-level JSON object, got ${root.runtimeType}');
    exitCode = 1;
    return;
  }

  final scalars = <String, dynamic>{};
  final arrays = <String, List<dynamic>>{};
  root.forEach((key, value) {
    if (value is List) {
      arrays[key] = value;
    } else {
      scalars[key] = value;
    }
  });

  _printEnvelope(scalars);
  _printArraySummary(arrays);

  for (final entry in arrays.entries) {
    _printArrayDetail(entry.key, entry.value);
  }
}

void _printEnvelope(Map<String, dynamic> scalars) {
  stdout.writeln('=' * 72);
  stdout.writeln('ENVELOPE (top-level scalar fields)');
  stdout.writeln('=' * 72);
  if (scalars.isEmpty) {
    stdout.writeln('  (none)');
  }
  scalars.forEach((key, value) {
    stdout.writeln('  $key: ${_short(value)}  (${_typeName(value)})');
  });
  stdout.writeln('');
}

void _printArraySummary(Map<String, List<dynamic>> arrays) {
  stdout.writeln('=' * 72);
  stdout.writeln('SAMPLE ARRAYS (${arrays.length})');
  stdout.writeln('=' * 72);
  final names = arrays.keys.toList()
    ..sort((a, b) => arrays[b]!.length.compareTo(arrays[a]!.length));
  for (final name in names) {
    stdout.writeln('  ${arrays[name]!.length.toString().padLeft(8)}  $name');
  }
  stdout.writeln('');
}

void _printArrayDetail(String name, List<dynamic> items) {
  stdout.writeln('-' * 72);
  stdout.writeln('$name  —  ${items.length} records');
  stdout.writeln('-' * 72);

  if (items.isEmpty) {
    stdout.writeln('  (empty)\n');
    return;
  }

  final fields = <String, _FieldStat>{};
  var nonObject = 0;
  for (final item in items) {
    if (item is! Map<String, dynamic>) {
      nonObject++;
      continue;
    }
    item.forEach((field, value) {
      (fields[field] ??= _FieldStat()).observe(value);
    });
  }

  if (nonObject > 0) {
    stdout.writeln('  WARNING: $nonObject non-object element(s)');
  }

  stdout.writeln('  example: ${_short(items.first, max: 200)}\n');

  final fieldNames = fields.keys.toList()..sort();
  for (final field in fieldNames) {
    final stat = fields[field]!;
    final presence = stat.count == items.length
        ? 'always'
        : '${stat.count}/${items.length}';
    stdout.writeln('  • $field  [$presence, ${stat.typeSummary()}]');
    final detail = stat.detail();
    if (detail != null) stdout.writeln('      $detail');
  }
  stdout.writeln('');
}

/// Accumulates type/value statistics for one field across all records.
class _FieldStat {
  int count = 0;
  final Set<String> types = {};

  num? min;
  num? max;

  DateTime? minTime;
  DateTime? maxTime;
  bool _looksTemporal = false;

  final Set<String> _distinct = {};
  bool _distinctOverflow = false;

  void observe(dynamic value) {
    count++;
    types.add(_typeName(value));

    if (value is num) {
      if (min == null || value < min!) min = value;
      if (max == null || value > max!) max = value;
    } else if (value is String) {
      final dt = DateTime.tryParse(value);
      if (dt != null && _isIsoTimestamp(value)) {
        _looksTemporal = true;
        if (minTime == null || dt.isBefore(minTime!)) minTime = dt;
        if (maxTime == null || dt.isAfter(maxTime!)) maxTime = dt;
      } else if (!_distinctOverflow) {
        _distinct.add(value);
        if (_distinct.length > _maxDistinct) _distinctOverflow = true;
      }
    }
  }

  String typeSummary() => types.join('|');

  String? detail() {
    if (_looksTemporal && minTime != null) {
      return 'range: ${minTime!.toIso8601String()} → ${maxTime!.toIso8601String()}';
    }
    if (min != null) {
      return 'numeric range: $min … $max';
    }
    if (_distinct.isNotEmpty) {
      if (_distinctOverflow) {
        return 'high-cardinality string (> $_maxDistinct distinct, e.g. ${_distinct.take(2).join(", ")})';
      }
      final values = _distinct.toList()..sort();
      return 'values: ${values.join(", ")}';
    }
    return null;
  }
}

bool _isIsoTimestamp(String s) =>
    // Cheap guard so plain words aren't misread as dates: require a digit start
    // and a 'T' or '-' in the first 11 chars (YYYY-MM-DD...).
    s.length >= 10 &&
    RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s);

String _typeName(dynamic value) {
  if (value == null) return 'null';
  if (value is bool) return 'bool';
  if (value is int) return 'int';
  if (value is double) return 'double';
  if (value is String) {
    return DateTime.tryParse(value) != null && _isIsoTimestamp(value)
        ? 'timestamp'
        : 'string';
  }
  if (value is List) return 'array';
  if (value is Map) return 'object';
  return value.runtimeType.toString();
}

String _short(dynamic value, {int max = 80}) {
  final s = value is String ? value : json.encode(value);
  return s.length <= max ? s : '${s.substring(0, max)}…';
}
