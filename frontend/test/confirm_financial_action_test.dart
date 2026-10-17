import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/confirm_financial_action.dart';

import 'support/shots.dart';

/// UI-4 (ADR-049): an act on the books that cannot be taken back is confirmed
/// knowing which document, what happens, and why.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Opens the dialog for cancelling a voucher; [answer] holds what it returns.
  Future<List<String?>> open(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final answer = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () async => answer.add(
                    await confirmFinancialAction(
                      context,
                      title: 'إلغاء السند',
                      facts: const [
                        ('السند', 'PV-2026-00011'),
                        ('المبلغ', '1,500.00 ر.س'),
                      ],
                      effect: 'يُعكس قيده وحركة خزينته بقيد عكسي.',
                      confirmLabel: 'إلغاء السند',
                      reasonLabel: 'سبب الإلغاء',
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
    return answer;
  }

  FilledButton confirm(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('confirm-action')));

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('it names the document and what happens ($name)', (
      tester,
    ) async {
      await open(tester, theme);
      expect(find.text('PV-2026-00011'), findsOneWidget);
      expect(find.text('1,500.00 ر.س'), findsOneWidget);
      expect(find.text('يُعكس قيده وحركة خزينته بقيد عكسي.'), findsOneWidget);
      await shot(tester, 'confirm_cancel_$name');
    });
  }

  testWidgets('the way back is «تراجع», not a second «إلغاء»', (tester) async {
    final answer = await open(tester, LightTheme.theme);
    expect(find.widgetWithText(TextButton, 'إلغاء'), findsNothing);
    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(answer, [null]);
  });

  testWidgets('without a reason it cannot be confirmed; with one it returns '
      'it', (tester) async {
    final answer = await open(tester, LightTheme.theme);
    expect(confirm(tester).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('confirm-reason')), '   ');
    await tester.pump();
    expect(confirm(tester).onPressed, isNull, reason: 'spaces are no reason');

    await tester.enterText(
      find.byKey(const Key('confirm-reason')),
      ' دُفع مرتين ',
    );
    await tester.pump();
    expect(confirm(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(answer, ['دُفع مرتين']);
  });
}
