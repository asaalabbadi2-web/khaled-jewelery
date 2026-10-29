import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/pay_box.dart';

import 'support/shots.dart';

/// UI-5 (ADR-049): the ways to pay are set apart from the screen's other
/// soft buttons (the owner, 17 Oct 2026: they looked like «عميل جديد») --
/// they wear the cash tone, the two used most filled with it.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  const methods = [
    {'id': 1, 'name': 'نقداً', 'payment_type': 'cash', 'commission_rate': 0},
    {'id': 2, 'name': 'مدى', 'payment_type': 'mada', 'commission_rate': 0.8},
    {'id': 3, 'name': 'فيزا', 'payment_type': 'visa', 'commission_rate': 2},
  ];

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('payment methods wear the cash tone ($name)', (tester) async {
      tester.view.physicalSize = const Size(700, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final paid = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    PayBox(
                      amount: TextEditingController(),
                      remaining: 2500,
                      currency: 'ر.س',
                      methods: methods,
                      onPay: paid.add,
                      remainingText: const Text('المتبقي: 2,500.00 ر.س'),
                    ),
                    const SizedBox(height: 16),
                    // The screen's other soft button, for the eye.
                    FilledButton.tonalIcon(
                      onPressed: () {},
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('عميل جديد'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(PayBox));
      final cash = AppSemanticColors.of(context).cash;
      final soft = Theme.of(context).colorScheme.secondaryContainer;
      Color? fill(int id) => tester
          .widget<ButtonStyleButton>(find.byKey(Key('quick-pay-$id')))
          .style
          ?.backgroundColor
          ?.resolve({});

      expect(fill(1), cash.container);
      expect(fill(2), cash.container);
      expect(fill(1), isNot(soft), reason: 'not the other soft buttons');
      expect(
        tester
            .widget<ButtonStyleButton>(find.byKey(const Key('quick-pay-3')))
            .style
            ?.foregroundColor
            ?.resolve({}),
        cash.fg,
      );
      await shot(tester, 'pay_box_$name');

      await tester.tap(find.byKey(const Key('quick-pay-1')));
      expect(paid, [1]);
    });
  }

  // COMMISSION-3 (the owner, 29 Oct 2026): a method says all it deducts --
  // its rate and its fixed amount a transaction.
  testWidgets('a method says its rate and its fixed amount', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PayBox(
            amount: TextEditingController(),
            remaining: 1000,
            currency: 'ر.س',
            methods: const [
              {'id': 4, 'name': 'تابي', 'payment_type': 'tabby', 'commission_rate': 6.99,
               'commission_fixed_amount': 1.5},
            ],
            onPay: (_) {},
            remainingText: const Text('المتبقي'),
          ),
        ),
      ),
    );
    expect(find.textContaining('6.99% + 1.5'), findsOneWidget);
  });
}
