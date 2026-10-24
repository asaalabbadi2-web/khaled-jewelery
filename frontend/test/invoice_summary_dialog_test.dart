import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/adaptive_invoice_summary_dialog.dart';

import 'support/shots.dart';

/// ADR-060 ف٠: the old summary dialog opened at its top, its notices above.
/// No screen uses it since ف٢ (invoice_saved_dialog.dart); it is kept until
/// its deletion can pass the CI quality guard (ADR-060 Known follow-ups), and
/// this test with it.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  group('the summary dialog', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showAdaptiveInvoiceSummaryDialog<bool>(
                      context: context,
                      title: 'مراجعة فاتورة بيع',
                      icon: Icons.receipt_long_rounded,
                      accentColor: Colors.green,
                      statusTitle: 'حالة السداد',
                      statusMessage: 'آجل على «محمد»: 1,250.00 ر.س',
                      statusTone: InvoiceSummaryStatusTone.due,
                      metrics: [
                        for (var i = 0; i < 8; i++)
                          InvoiceSummaryMetric(
                            label: 'بند $i',
                            value: '$i',
                            fullWidth: true,
                          ),
                      ],
                      notices: const ['سعر «خاتم» أقل من تكلفته'],
                      actions: const [
                        InvoiceSummaryAction.primary(
                          label: 'حفظ الفاتورة',
                          icon: Icons.save_rounded,
                          value: true,
                        ),
                      ],
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Past the 320 ms after which it scrolled itself to the end.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('opens at its top, though it has a notice', (tester) async {
      await open(tester);
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
      expect(position.pixels, 0);
      expect(tester.getRect(find.text('مراجعة فاتورة بيع')).top, greaterThan(0));
      await shot(tester, 'invoice_summary_top_phone');
    });

    testWidgets('its notices are above the summary, not under it', (
      tester,
    ) async {
      await open(tester);
      expect(
        tester.getRect(find.byKey(const Key('invoice-summary-notices'))).top,
        lessThan(tester.getRect(find.text('ملخص الفاتورة')).top),
      );
    });
  });
}
