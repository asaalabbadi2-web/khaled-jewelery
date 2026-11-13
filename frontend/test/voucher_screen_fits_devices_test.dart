// The voucher screen fits the shop's devices (the owner, 13 Nov 2026: «في
// الشاشات الصغيره ... وتأكد من سلامة العرض»): a receipt and a payment opened
// at an iPhone SE, an iPhone and an iPad mini, the whole form scrolled through:
// nothing overflows, nothing fails to draw.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/voucher_screen_harness.dart';

const _devices = <String, Size>{
  'iPhone SE': Size(375, 667),
  'iPhone': Size(390, 844),
  'iPad mini': Size(744, 1133),
};

void main() {
  setUpAll(loadCairo);

  for (final type in ['receipt', 'payment']) {
    for (final MapEntry(key: device, value: size) in _devices.entries) {
      testWidgets('a $type voucher fits an $device, all the way down', (tester) async {
        final errors = <String>[];
        final before = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
        try {
          await openVoucher(tester, voucherType: type, size: size);
          // every section scrolled into sight
          final page = find.byType(Scrollable).first;
          for (var i = 0; i < 12; i++) {
            await tester.drag(page, const Offset(0, -400), warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 100));
          }
        } finally {
          FlutterError.onError = before;
        }
        expect(errors, isEmpty, reason: '$type on $device');
      });
    }
  }
}
