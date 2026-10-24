import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/invoice_saved_facts.dart';
import 'package:frontend/widgets/adaptive_invoice_summary_dialog.dart';

import 'support/shots.dart';

/// ADR-060 ف٠: the invoice's review and its summary after the save say what
/// is true, once, and open where it is read.
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

  group('what the server says of a saved invoice', () {
    test('its number is the invoice\'s, not the row\'s', () {
      expect(
        InvoiceSavedFacts.of({'id': 4187, 'invoice_number': 'SELL-2026-412'})
            .number,
        'SELL-2026-412',
      );
      expect(InvoiceSavedFacts.of({'id': 4187}).number, '#4187');
    });

    test('a supplier purchase owes its cash obligation, not its total', () {
      // The total holds the gold's value; the cash owed is the wage + VAT.
      final f = InvoiceSavedFacts.of({
        'total': 23525.0,
        'cash_obligation': 3075.0,
        'amount_paid': 3075.0,
        'status': 'partially_paid',
      });
      expect(f.cashDue, 0);
      expect(f.owes, isTrue, reason: 'its gold is still owed');
      expect(f.statusLine((v) => '$v'), 'مسدَّدة جزئيًا');
    });

    test('what is owed in cash is said once, with the state', () {
      final f = InvoiceSavedFacts.of({
        'total': 18450.0,
        'amount_paid': 17200.0,
        'status': 'partially_paid',
      });
      expect(f.cashDue, 1250.0);
      expect(
        f.statusLine((v) => v.toStringAsFixed(2)),
        'مسدَّدة جزئيًا · متبقي 1250.00 نقدًا',
      );
    });

    test('settled is the server\'s word', () {
      final f = InvoiceSavedFacts.of({
        'total': 100.0,
        'amount_paid': 100.0,
        'status': 'paid',
      });
      expect(f.owes, isFalse);
      expect(f.statusLine((v) => '$v'), 'مسدَّدة بالكامل');
    });
  });
}
