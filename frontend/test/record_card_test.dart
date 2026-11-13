// A record card says a sum as the invoices say it (the owner, 13 Nov 2026:
// «انت تضع رمز العمله قبل القيمة»): read the number, then its sign -- its
// figures were drawn left to right, the sign coming first. A bare figure, a
// negative among them, still reads left to right.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/record_card.dart';

import 'support/sign_order.dart';

void main() {
  testWidgets('a sum\'s sign follows its number; a bare figure reads left to right', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: RecordCard(title: 'بيع', fields: [
            RecordField('الكاش الداخل', '520,000.00 ر.س'),
            RecordField('الوزن', '1,234.500 جم'),
            RecordField('الرصيد', '\u200e-426,580.59', negative: true),
          ]),
        ),
      ),
    ));
    expect(signFollowsTheNumber(tester, find.text('520,000.00 ر.س'), 'ر.س'), isTrue);
    expect(signFollowsTheNumber(tester, find.text('1,234.500 جم'), 'جم'), isTrue);
    final bare = tester.widget<Text>(find.text('\u200e-426,580.59'));
    expect(bare.textDirection, TextDirection.ltr);
  });
}
