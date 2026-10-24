import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/invoice_saved_facts.dart';
import 'package:frontend/widgets/invoice_saved_dialog.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// ADR-060: what is said once an invoice is saved -- all of it the server's
/// (ف٠), short, with what to do next (ف٢).
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
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

  group('the summary after the save (ف٢)', () {
    Future<List<InvoiceSavedAction>> open(
      WidgetTester tester, {
      required Map<String, dynamic> invoice,
      List<String> held = const [],
      Size size = const Size(1280, 900),
      ThemeData? theme,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <InvoiceSavedAction>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async => actions.add(
                      await showInvoiceSaved(
                        context,
                        InvoiceSaved(
                          title: 'حُفظت فاتورة بيع',
                          facts: InvoiceSavedFacts.of(invoice),
                          currency: 'ر.س',
                          party: 'محمد العتيبي',
                          held: held,
                        ),
                      ),
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
      await tester.pumpAndSettle();
      return actions;
    }

    const owing = {
      'id': 4187,
      'invoice_number': 'SELL-2026-412',
      'total': 18450.0,
      'amount_paid': 17200.0,
      'status': 'partially_paid',
      'is_posted': false,
    };

    String stand(WidgetTester tester) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('invoice-saved-stand')),
            matching: find.byType(Text),
          ),
        )
        .single
        .data!;

    testWidgets('says the number, what was paid, and what remains, once', (
      tester,
    ) async {
      await open(tester, invoice: owing);
      expect(find.text('SELL-2026-412'), findsOneWidget);
      expect(find.text('محمد العتيبي'), findsOneWidget);
      expect(find.textContaining('متبقي'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('invoice-saved-payment')),
          matching: find.textContaining('مسدَّدة جزئيًا'),
        ),
        findsOneWidget,
      );
      await shot(tester, 'invoice_saved_desktop');
    });

    testWidgets('where it stands is the server\'s', (tester) async {
      await open(tester, invoice: {...owing, 'is_posted': true});
      expect(stand(tester), 'مرحَّلة');
    });

    testWidgets('not posted, it awaits posting', (tester) async {
      await open(tester, invoice: owing);
      expect(stand(tester), 'محفوظة، تنتظر الترحيل');
    });

    testWidgets('held, it says so and why', (tester) async {
      await open(
        tester,
        invoice: owing,
        held: const ['بيع تحت التكلفة — يحتاج اعتماد المدير'],
      );
      expect(stand(tester), 'تنتظر اعتماد المدير');
      expect(find.text('بيع تحت التكلفة — يحتاج اعتماد المدير'), findsOneWidget);
    });

    testWidgets('the number is copied', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, invoice: owing);
      await tester.tap(find.byKey(const Key('invoice-saved-copy')));
      await tester.pumpAndSettle();
      expect(copied, 'SELL-2026-412');
      expect(find.byTooltip('نُسخ الرقم'), findsOneWidget);
    });

    for (final (key, action) in [
      (LogicalKeyboardKey.keyP, InvoiceSavedAction.print),
      (LogicalKeyboardKey.keyN, InvoiceSavedAction.newInvoice),
      (LogicalKeyboardKey.enter, InvoiceSavedAction.done),
      (LogicalKeyboardKey.escape, InvoiceSavedAction.done),
    ]) {
      testWidgets('${key.keyLabel} is ${action.name}', (tester) async {
        final actions = await open(tester, invoice: owing);
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(actions, [action]);
      });
    }

    for (final (name, size) in [
      ('desktop', const Size(1280, 900)),
      ('phone', const Size(390, 844)),
    ]) {
      testWidgets('it reads in the dark theme on a $name', (tester) async {
        await open(
          tester,
          invoice: owing,
          size: size,
          theme: DarkTheme.theme,
          held: const ['بيع تحت التكلفة'],
        );
        expect(tester.takeException(), isNull);
        await shot(tester, 'invoice_saved_dark_$name');
        expectNoTextVanishesOnDark(
          tester,
          within: find.byKey(const Key('invoice-saved')),
        );
      });
    }
  });
}
