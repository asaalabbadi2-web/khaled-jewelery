import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_state_views.dart';

import 'support/shots.dart';

/// UI-4 (ADR-049): loading, a failed load and nothing-there each look like
/// what they are.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<void> pump(WidgetTester tester, ThemeData theme, Widget child) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('a failed load says so, in words, and tries again ($name)', (
      tester,
    ) async {
      var retried = 0;
      await pump(
        tester,
        theme,
        AppErrorView(
          title: 'تعذّر تحميل السندات',
          error: Exception('انقطع الاتصال'),
          onRetry: () => retried++,
        ),
      );
      expect(find.text('تعذّر تحميل السندات'), findsOneWidget);
      expect(find.text('انقطع الاتصال'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      await shot(tester, 'state_error_$name');
      await tester.tap(find.text('إعادة المحاولة'));
      expect(retried, 1);
    });

    testWidgets('nothing there says why and what to do ($name)', (
      tester,
    ) async {
      var acted = 0;
      await pump(
        tester,
        theme,
        AppEmptyView(
          title: 'لا توجد سندات مطابقة',
          hint: 'عدّل البحث أو أنشئ سندًا.',
          actionLabel: 'إنشاء سند',
          onAction: () => acted++,
        ),
      );
      expect(find.text('لا توجد سندات مطابقة'), findsOneWidget);
      await shot(tester, 'state_empty_$name');
      await tester.tap(find.text('إنشاء سند'));
      expect(acted, 1);
    });

    testWidgets('loading shows the page\'s shape ($name)', (tester) async {
      await pump(tester, theme, const AppLoadingView(key: Key('skeleton')));
      expect(find.byKey(const Key('skeleton')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await shot(tester, 'state_loading_$name');
    });
  }

  // ADR-057 ر٢: on a phone, under a toolbar, the space is short -- the
  // suppliers' skeleton overflowed by 157 px there.
  testWidgets('the skeleton fits a short space, cut, not overflowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              height: 220,
              child: AppLoadingView(summaryBlocks: 3, rows: 6),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('جارٍ التحميل'), findsOneWidget);
  });
}

