// One source for what the reader sends (the owner, 26 Nov 2026: «مصدر واحد لسلوك القارئ، ومصدر واحد
// لاستخراج القيمة الكاملة»). Four scan fields built beside «استقبال القارئ» each wrote its own pattern
// for a whole value -- and each its own focus and keyboard -- and the screens lagged on the reader.
// What a tag is, what a printed number is, and where a value ends live in widgets/reader_capture.dart;
// a field the reader types into beside a screen's own is widgets/scan_field.dart or
// widgets/reader_receiver.dart, no other («فحص القارئ» shows the reader's raw typing on purpose).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files under lib/, their lines matching [pattern], comment lines skipped.
List<String> _found(RegExp pattern, {required Set<String> allowed}) {
  final found = <String>[];
  final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    if (allowed.contains(path)) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('//')) continue;
      if (pattern.hasMatch(lines[i])) found.add('$path:${i + 1}: ${lines[i].trim()}');
    }
  }
  return found..sort();
}

void main() {
  test('what a tag or a printed number is, and where a value ends, is said in reader_capture alone', () {
    final found = _found(
      // a pattern for a tag (24 characters) or a printed number (KJ-…), or a value told by its prefix
      RegExp(r"""RegExp\(r?'[^']*(\{24\}|KJ-|\[Kk\]\[Jj\])|startsWith\('(KJ-|4B4A)'\)"""),
      allowed: {'lib/widgets/reader_capture.dart'},
    );
    expect(found, isEmpty, reason: 'use ReaderCapture (value, isTag, pieceCodesIn):\n${found.join('\n')}');
  });

  test('a field with no on-screen keyboard is a reader door, and a reader door is one of two widgets', () {
    final found = _found(
      RegExp(r'TextInputType\.none'),
      allowed: {'lib/widgets/scan_field.dart', 'lib/widgets/reader_receiver.dart'},
    );
    expect(found, isEmpty, reason: 'use ScanField or ReaderReceiver:\n${found.join('\n')}');
  });
}
