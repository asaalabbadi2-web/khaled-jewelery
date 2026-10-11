import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/reports/admin_dashboard_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The admin dashboard says the server's figures (the owner, 11 Oct 2026).
///
/// Its «صافي الربح» was sales - purchases - every 5-account, computed in the
/// screen: a loss of 21 million for 2026 on the 10 Oct copy, stock counted
/// twice. And when a period read zero -- every morning before the first sale
/// -- the screen summed up to 1,000 invoices of each kind itself, by rules of
/// its own: three more requests on every load. The gram profit beside it is
/// the dashboard's profit; the card says the period's activity.

Map<String, dynamic> _period({double sales = 0, double purchases = 0, double expenses = 0}) => {
      'sales': {'total_value': sales, 'docs': sales > 0 ? 3 : 0, 'by_user': [], 'by_karat': []},
      'purchases': {'total_value': purchases, 'docs': 0, 'by_user': [], 'by_karat': []},
      'expenses': {
        'total_value': expenses,
        'docs': expenses == 0 ? 0 : 41,
        'by_account': expenses == 0
            ? []
            : [
                {'account': 'رواتب الموظفين', 'value': expenses * 0.6},
                {'account': 'إيجار المعرض', 'value': expenses * 0.4},
              ],
      },
      'scrap_purchases': {'total_value': 0.0, 'docs': 0, 'by_user': [], 'by_karat': []},
    };

final _dashboard = <String, dynamic>{
  'success': true,
  'global_snapshot': {'net_financial_position': 1000000.0, 'gold_price_24k': 505.0, 'gold_price_change_pct': 0.0},
  'kpis': {'today_profit_vs_yesterday_pct': 12.5, 'gold_by_karat': {}},
  'liquidity': {'cash_available': 371561.53},
  'valuation': {},
  'series': {},
  'safe_boxes': [],
  'alerts': [],
  'sensitive_operations': [],
  'sales_purchases_summary': {
    'today': _period(),
    'month': _period(sales: 338940.10, purchases: 339579.02, expenses: 62074.22),
    'year': _period(sales: 11602016.09, purchases: 13552408.09, expenses: 776885.09),
  },
};

class _Api extends ApiService {
  int invoiceCalls = 0;

  @override
  Future<Map<String, dynamic>> getAdminDashboard() async =>
      jsonDecode(jsonEncode(_dashboard)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> getGramProfitReport({required DateTime startDate, required DateTime endDate}) async =>
      {};

  @override
  Future<Map<String, dynamic>> getInvoices({int page = 1, int perPage = 50, String sortBy = 'date',
      String sortOrder = 'desc', String search = '', String searchType = 'all', String status = 'all',
      String? invoiceType, List<String>? invoiceTypes, String? invoiceGroup, String? party, String? creator,
      int? employeeId, String? karat, String? goldType, DateTime? dateFrom, DateTime? dateTo}) async {
    invoiceCalls++;
    return {'invoices': []};
  }
}

void main() {
  Future<_Api> open(WidgetTester tester, {double width = 1440, ThemeData? theme}) async {
    final cairo = FontLoader('Cairo');
    for (final f in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
    }
    await cairo.load();
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
    tester.view.physicalSize = Size(width, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final api = _Api();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: theme ?? LightTheme.theme,
        home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: AdminDashboardScreen(api: api))),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    return api;
  }

  testWidgets('a quiet morning asks the server once -- the screen sums no invoices', (tester) async {
    final api = await open(tester);
    expect(api.invoiceCalls, 0, reason: 'three requests of up to 1,000 invoices each, every load');
    expect(find.text('لا توجد عمليات بعد'), findsWidgets);
  });

  testWidgets('the period\'s activity, nothing subtracted: no profit, no loss of millions', (tester) async {
    await open(tester);
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));

    final card = find.byKey(const Key('dashboard-period-movement'));
    expect(card, findsOneWidget);
    for (final word in ['صافي الربح', 'خسارة', 'ربح']) {
      expect(find.descendant(of: card, matching: find.textContaining(word)), findsNothing, reason: word);
    }
    expect(find.descendant(of: card, matching: find.textContaining('حركة السنة')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('776,885.09')), findsOneWidget,
        reason: 'the operating expenses, as the server says them');
    expect(find.descendant(of: card, matching: find.textContaining('20,')), findsNothing,
        reason: 'not 11.6M - 13.6M - expenses');
  });

  // ── DASH-2: the theme's colours, sizes that do not grow with the screen ──

  double fontOf(WidgetTester tester, Finder text) =>
      tester.renderObject<RenderParagraph>(text.first).text.style!.fontSize!;

  testWidgets('the dark theme lays out wide and narrow', (tester) async {
    // The colours' witness is test/theme_raw_color_ratchet_test.dart: this file
    // held 118 fixed colours and is held at none.
    for (final width in [1440.0, 390.0]) {
      await open(tester, width: width, theme: DarkTheme.theme);
      expect(tester.takeException(), isNull, reason: 'no overflow at $width');
      expect(find.byKey(const Key('dashboard-period-movement')), findsOneWidget);
    }
  });

  testWidgets('a wider screen shows more, it does not make the text bigger', (tester) async {
    await open(tester, width: 1440);
    final wide = fontOf(tester, find.text('صافي المركز المالي'));
    await open(tester, width: 390);
    final narrow = fontOf(tester, find.text('صافي المركز المالي'));
    expect(wide, narrow, reason: 'the size grew by up to 1.2 with the width');
  });

  testWidgets('each amount of the period says its currency once', (tester) async {
    // The owner (12 Oct 2026): «هناك تكرار لرمز العملة في حركة اليوم» -- the
    // row added the symbol to an amount _formatCurrency had already given it.
    await open(tester);
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));
    final card = find.byKey(const Key('dashboard-period-movement'));
    final amount = find.descendant(of: card, matching: find.textContaining('776,885.09'));
    final text = tester.renderObject<RenderParagraph>(amount.first).text.toPlainText();
    expect('ر.س'.allMatches(text).length, 1, reason: text);
  });

  testWidgets('the expenses tab shows where they went, and counts entries', (tester) async {
    // The owner (12 Oct 2026): «المصروفات أيضًا في تبويبها ليس هناك تفاصيل لها»
    // -- the server sent no count and the tab read empty.
    await open(tester);
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('المصروفات').first);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('رواتب الموظفين'), findsOneWidget);
    expect(find.text('إيجار المعرض'), findsOneWidget);
    expect(find.text('القيود'), findsOneWidget, reason: 'entries, not invoices');
  });
}
