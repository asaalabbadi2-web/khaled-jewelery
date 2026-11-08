// The app runs on the web, where an int is a JavaScript number and a shift is
// 32-bit: `1 << 32` is not 4294967296 there. The receiving screen made its
// request key with Random.secure().nextInt(1 << 32) -- on the VM, where the
// tests run, a key; in the browser it threw before the receipt was sent (8 Nov
// 2026, the owner: «الاستلام لا يحفظ»). No shift of 32 bits or more in lib/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no shift of 32 bits or more in lib/', () {
    final shift = RegExp(r'<<\s*(3[2-9]|[4-9]\d|\d{3,})\b');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (shift.hasMatch(code)) found.add('${file.path}:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'a 32-bit shift breaks on the web only');
  });
}
