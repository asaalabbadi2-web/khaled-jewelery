// COMMISSION-1 (the owner, 15 Oct 2026): a payment method's commission is taken
// at its settlement, never at the invoice -- so there is no timing to set, show
// or send. The payment methods screen offered «ضمن الفاتورة / عند التسوية», the
// settlement screen a switch «العمولة محسوبة في الفاتورة» that zeroed the fee,
// and both clearing screens a timing chip.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no screen sets, shows or sends a commission timing', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/_archived/')) continue;
      final text = file.readAsStringSync();
      for (final mark in ['commission_timing', 'commissionTiming', 'محسوبة في الفاتورة']) {
        if (text.contains(mark)) offenders.add('$path: $mark');
      }
    }
    expect(offenders, isEmpty);
  });
}
