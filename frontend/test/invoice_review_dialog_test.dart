import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/invoice_review_dialog.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// ADR-060 ف١: the review read as a receipt; a long invoice scrolls its lines
/// alone, a line's notice marks it and goes to it, Enter saves, Esc goes back.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  InvoiceReview review(
    BuildContext context, {
    int lines = 3,
    List<InvoiceReviewNotice> notices = const [],
    InvoiceReviewAmount? due,
  }) => InvoiceReview(
    title: 'مراجعة فاتورة بيع',
    subtitle: 'محمد العتيبي · الفرع الرئيسي',
    icon: Icons.point_of_sale_rounded,
    tone: AppSemanticColors.of(context).ready,
    currency: 'ر.س',
    notices: notices,
    lines: [
      for (var i = 0; i < lines; i++)
        InvoiceReviewLine(
          name: 'صنف ${i + 1}',
          karat: i.isEven ? 21 : 18,
          weight: 10,
          amount: 4000,
        ),
    ],
    tax: 1800,
    total: 13800,
    payments: const [
      InvoiceReviewAmount('نقدي', 10000),
      InvoiceReviewAmount('مدى', 2550),
    ],
    due: due,
  );

  Future<List<bool?>> open(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    ThemeData? theme,
    int lines = 3,
    List<InvoiceReviewNotice> notices = const [],
    InvoiceReviewAmount? due,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final answers = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async => answers.add(
                    await showInvoiceReview(
                      context,
                      review(context, lines: lines, notices: notices, due: due),
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
    return answers;
  }

  bool onScreen(WidgetTester tester, Finder f) {
    final r = tester.getRect(f);
    final view = tester.view.physicalSize;
    return r.top >= 0 && r.bottom <= view.height;
  }

  testWidgets('a short invoice lists every line, with its number', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(Key('invoice-review-line-$i')), findsOneWidget);
    }
    expect(find.text('مرّر لرؤية الكل'), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('invoice-review-count'))).data,
      '3',
    );
    await shot(tester, 'invoice_review_short_desktop');
  });

  for (final (name, size) in [
    ('desktop', const Size(1280, 900)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('a long invoice scrolls its lines alone: the total and save '
        'stay in view on a $name', (tester) async {
      await open(tester, size: size, lines: 24);
      expect(tester.takeException(), isNull);
      expect(find.text('مرّر لرؤية الكل'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('invoice-review-count'))).data,
        '24',
      );
      expect(onScreen(tester, find.text('الإجمالي')), isTrue);
      expect(onScreen(tester, find.byKey(const Key('invoice-review-save'))), isTrue);
      // The table holds the lines; its own list scrolls them.
      expect(
        find.descendant(
          of: find.byKey(const Key('invoice-review-lines')),
          matching: find.byType(ListView),
        ),
        findsOneWidget,
      );
      await shot(tester, 'invoice_review_long_$name');
    });
  }

  testWidgets('a notice on a line marks it, and «اذهب إليه» brings the table '
      'to it', (tester) async {
    await open(
      tester,
      lines: 24,
      notices: const [
        InvoiceReviewNotice('السطر 18: أعلى من السعر المباشر', line: 17),
      ],
    );
    final table = find.byKey(const Key('invoice-review-lines'));
    bool inTable(Finder f) {
      if (f.evaluate().isEmpty) return false;
      final r = tester.getRect(f);
      final t = tester.getRect(table);
      return r.top >= t.top && r.bottom <= t.bottom;
    }

    final line = find.byKey(const Key('invoice-review-line-17'));
    expect(inTable(line), isFalse, reason: 'below the table\'s fold');
    await tester.tap(find.byKey(const Key('invoice-review-go-17')));
    await tester.pumpAndSettle();
    expect(inTable(line), isTrue);
    final warn = AppSemanticColors.of(tester.element(line)).warning;
    expect((tester.widget<Container>(line).color), warn.container);
  });

  testWidgets('it reads in the screen\'s direction: a line\'s name on the '
      'right, its amount on the left', (tester) async {
    await open(tester);
    final line = find.byKey(const Key('invoice-review-line-0'));
    final name = tester.getRect(
      find.descendant(of: line, matching: find.text('صنف 1')),
    );
    final amount = tester.getRect(
      find.descendant(of: line, matching: find.text('4,000.00')),
    );
    expect(name.left, greaterThan(amount.right));
  });

  testWidgets('the weight is said for each karat', (tester) async {
    await open(tester, lines: 3); // 21, 18, 21 -- 10 g each
    expect(find.text('20.000'), findsOneWidget);
    expect(find.text('10.000'), findsWidgets);
  });

  testWidgets('what remains is said once', (tester) async {
    await open(
      tester,
      due: const InvoiceReviewAmount('آجل على «محمد العتيبي»', 1250),
    );
    expect(find.textContaining('آجل'), findsOneWidget);
    expect(find.byKey(const Key('invoice-review-due')), findsOneWidget);
  });

  testWidgets('Enter saves', (tester) async {
    final answers = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('Esc goes back to the invoice', (tester) async {
    final answers = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  for (final (name, size) in [
    ('desktop', const Size(1280, 900)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await open(
        tester,
        size: size,
        theme: DarkTheme.theme,
        lines: 12,
        notices: const [InvoiceReviewNotice('تنبيه على سطر', line: 2)],
        due: const InvoiceReviewAmount('آجل على «محمد»', 1250),
      );
      expect(tester.takeException(), isNull);
      await shot(tester, 'invoice_review_dark_$name');
      expectNoTextVanishesOnDark(
        tester,
        within: find.byKey(const Key('invoice-review')),
      );
    });
  }
}
