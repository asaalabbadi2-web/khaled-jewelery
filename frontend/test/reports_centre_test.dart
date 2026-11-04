// REPORTS-HUB (the owner, 5 Nov 2026): the reports centre is ordered by the
// question the owner asks -- «حسب السؤال» -- each report a compact card of
// one line -- «بطاقة مضغوطة». What took the screen and said nothing goes:
// the card «كل تقاريرك في مكان واحد» («اخذت حيز كبير في الشاشه دون فائده
// تذكر»), the type chips that sorted the same reports a second way, the
// «فلترة مطلوبة» tag on every card, and a refresh with nothing to refresh.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/report_catalog.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/reports/reports_main_screen.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/shots.dart';

class _Manager extends AuthProvider {
  @override
  bool hasPermission(String key) => true;
}

class _Seller extends AuthProvider {
  @override
  bool hasPermission(String key) => false;
}

Future<void> _open(
  WidgetTester tester, {
  double width = 1440,
  ThemeData? theme,
  AuthProvider? auth,
}) async {
  final cairo = FontLoader('Cairo');
  for (final f in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
  }
  await cairo.load();
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>(
      create: (_) => auth ?? _Manager(),
      child: MaterialApp(
        theme: theme ?? LightTheme.theme,
        home: ReportsMainScreen(api: ApiService()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  test('the reports are ordered by the question the owner asks', () {
    final sections = {
      for (final c in ReportCatalog.buildDefaultCatalog())
        c.nameAr: [for (final r in c.reports) r.id],
    };
    expect(sections, {
      'أين نقف اليوم؟': ['balance_sheet', 'gold_by_place', 'weight_position'],
      'كيف كان أداؤنا؟': [
        'income_statement',
        'cash_flow',
        'sales_analysis',
        'purchases_analysis',
        'gold_price_history',
      ],
      'من لنا ومن علينا؟': [
        'customer_balances',
        'supplier_aging',
        'payroll_monthly',
        'bonus_payables',
      ],
      'هل الدفاتر سليمة؟': [
        'trial_balance',
        'safe_gold_reconciliation',
        'category_weight_audit',
        'reconciliation_findings',
      ],
      'الدفاتر': [
        'general_ledger',
        'account_statement',
        'gold_safe_boxes_inventory',
      ],
      'اللوحات والضريبة': [
        'admin_dashboard',
        'analytics_dashboard',
        'vat_returns',
      ],
    });
  });

  testWidgets('what said nothing is gone; each card is one line', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('كل تقاريرك في مكان واحد'), findsNothing);
    expect(find.text('فلترة مطلوبة'), findsNothing);
    expect(find.text('بدون فلترة'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing, reason: 'one order, not two');
    expect(find.byIcon(Icons.refresh), findsNothing);
    final balance = ReportCatalog.buildDefaultCatalog()
        .expand((c) => c.reports)
        .firstWhere((r) => r.id == 'balance_sheet');
    final description = tester.widget<Text>(find.text(balance.descriptionAr));
    expect(description.maxLines, 1);
    expect(find.text('أين نقف اليوم؟'), findsOneWidget);
  });

  testWidgets('the search finds by the words people use, and clears back', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'أصول');
    await tester.pump();
    expect(find.text('الميزانية العمومية'), findsOneWidget);
    expect(find.text('تحليل المبيعات'), findsNothing);

    await tester.enterText(find.byType(TextField), 'لا شيء بهذا الاسم');
    await tester.pump();
    expect(find.text('لا توجد تقارير مطابقة'), findsOneWidget);
    await tester.tap(find.text('مسح البحث'));
    await tester.pump();
    expect(
      find.text('الميزانية العمومية'),
      findsOneWidget,
      reason: 'no dead end (FC-4)',
    );
  });

  testWidgets("the manager's dashboard is the manager's alone", (tester) async {
    await _open(tester, auth: _Seller());
    expect(find.text('لوحة تحكم المدير'), findsNothing);
    expect(find.text('الميزانية العمومية'), findsOneWidget);
  });

  for (final (name, width, theme) in [
    ('light_desktop', 1440.0, LightTheme.theme),
    ('light_tablet', 820.0, LightTheme.theme),
    ('light_phone', 390.0, LightTheme.theme),
    ('dark_desktop', 1440.0, DarkTheme.theme),
    ('dark_phone', 390.0, DarkTheme.theme),
  ]) {
    testWidgets('it lays out $name', (tester) async {
      await _open(tester, width: width, theme: theme);
      expect(tester.takeException(), isNull);
      await shot(tester, 'reports_centre_$name');
    });
  }
}
