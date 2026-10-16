import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UI-2 (ADR-049): what a screen sends when it saves is kept, whole, in
/// `test/payloads/<name>.json`, and compared on every run. A screen's numbers
/// may change how they are shown; what reaches the server may not.
///
/// A date (a string starting `yyyy-mm-dd`) is today's and is compared as
/// `<date>`. To write a witness the first time, or after a change the server
/// is meant to see:
/// `UPDATE_PAYLOADS=1 flutter test test/<file>_test.dart`
void expectPayload(String name, Map<String, dynamic> sent) {
  final file = File('test/payloads/$name.json');
  final now = '${const JsonEncoder.withIndent('  ').convert(_stable(sent))}\n';
  if (Platform.environment['UPDATE_PAYLOADS'] == '1') {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(now);
    return;
  }
  expect(
    file.existsSync(),
    isTrue,
    reason: 'no witness for $name: run once with UPDATE_PAYLOADS=1',
  );
  expect(
    now,
    file.readAsStringSync(),
    reason: 'what $name sends to the server changed',
  );
}

final _date = RegExp(r'^\d{4}-\d{2}-\d{2}');

Object? _stable(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _stable(value[k])};
  }
  if (value is List) return [for (final v in value) _stable(v)];
  if (value is String && _date.hasMatch(value)) return '<date>';
  return value;
}
