import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/reports/admin_dashboard_screen.dart';
import 'package:frontend/screens/reports/income_statement_report_screen.dart';
import 'package:frontend/screens/reports/weight_position_screen.dart';
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

Map<String, dynamic> _period({double sales = 0, double purchases = 0, double expenses = 0,
        double scrap = 0, double settlements = 0}) => {
      'sales': {'total_value': sales, 'total_weight': sales > 0 ? 1234.5 : 0, 'docs': sales > 0 ? 3 : 0,
                'by_user': [], 'by_karat': []},
      'purchases': {'total_value': purchases, 'docs': 0, 'by_user': [], 'by_karat': []},
      'scrap_customers': {'total_value': scrap, 'total_weight': scrap > 0 ? 987.6 : 0, 'docs': scrap > 0 ? 9 : 0,
                          'by_user': [], 'by_karat': []},
      'office_settlements': {'total_value': settlements, 'total_weight': settlements > 0 ? 456.7 : 0,
                             'docs': settlements > 0 ? 2 : 0, 'by_user': [], 'by_karat': []},
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
    };

final _dashboard = <String, dynamic>{
  'success': true,
  'global_snapshot': {'net_financial_position': 1000000.0, 'gold_price_24k': 505.0, 'gold_price_change_pct': 0.0},
  'kpis': {'today_profit_vs_yesterday_pct': 12.5, 'gold_by_karat': {}},
  'liquidity': {'cash_available': 371561.53},
  'valuation': {},
  'series': {},
  'safe_boxes': [],
  // DASH-4: the production copy's, 27 Oct 2026.
  'positions': {
    'customers': {'owe_us_cash': 0.0, 'we_owe_cash': 0.0, 'owe_us_gold': 0.0, 'we_owe_gold': 0.0},
    'suppliers': {'owe_us_cash': 474.05, 'we_owe_cash': 84471.39, 'owe_us_gold': 356.368, 'we_owe_gold': 505.874},
    'offices_gold': 396.404,
    'offices': [],
  },
  // DASH-5: the production copy's, 27 Oct 2026.
  'clearing': {
    'total': 7112.0,
    'overdue': 1,
    'safes': [
      {'safe': 'مدى', 'amount': 3650.0, 'payments': 3, 'next_deposit': '2026-10-28', 'overdue': false},
      {'safe': 'تمارا', 'amount': 2762.0, 'payments': 3, 'next_deposit': '2026-10-21', 'overdue': true},
    ],
  },
  // DASH-6: one held invoice and one voucher.
  'approvals': {
    'invoices': {'count': 1, 'amount': 1500.0, 'oldest': '2026-10-29'},
    'vouchers': {'count': 2, 'amount': 400.0, 'oldest': '2026-10-28'},
    'bonuses': {'count': 0, 'amount': 0.0, 'oldest': null},
    'reservations': {'count': 0, 'amount': 0.0, 'oldest': null},
    'total': 3,
  },
  // DASH-7: the production copy's, 27 Oct 2026.
  'wrong_now': {
    'findings': [
      {'kind': 'SAFEBOX_GOLD_DRIFT', 'count': 1, 'since': '2026-10-27', 'title': 'ذهب الخزينة في حركاتها يخالف دفترها'},
    ],
    'negative_safes': [
      {'safe': 'خزينة ذهب الكسر مؤقتة', 'cash': null, 'grams': -446.672},
    ],
    'total': 2,
  },
  // DASH-8: the production copy's, 30 Oct 2026 -- sales not charged from 2 May.
  'vat': {
    'quarter': {'start': '2026-10-01', 'end': '2026-10-30', 'output_vat': 0.0, 'input_vat': 2054.07, 'net': -2054.07},
    'last_quarter': {'start': '2026-07-01', 'end': '2026-09-30', 'output_vat': 0.0, 'input_vat': 8283.69,
        'net': -8283.69, 'filed': false},
    'owed': 0.0,
    'policy': {'sales_vat_charged': false, 'input_vat_recoverable': true},
  },
  // DASH-9: the month's losing invoices, by employee.
  'deficits': {
    'start': '2026-10-01', 'count': 2, 'loss_cash': -150.0,
    'employees': [
      {'id': 7, 'name': 'سارة', 'count': 2, 'loss_cash': -150.0},
    ],
  },
  'sensitive_operations': [],
  'sales_purchases_summary': {
    'today': _period(),
    'month': _period(sales: 338940.10, purchases: 339579.02, expenses: 62074.22),
    'year': _period(sales: 11602016.09, purchases: 13552408.09, expenses: 776885.09,
        scrap: 7100000.0, settlements: 2400000.0),
  },
};

class _Api extends ApiService {
  _Api({this.gramProfit = const {}});

  final Map<String, dynamic> gramProfit;
  int invoiceCalls = 0;

  // «التسكير الآن» has its own test (weight_position_summary_card_test.dart).
  @override
  Future<Map<String, dynamic>?> getWeightPositionSummary() async => null;

  @override
  Future<Map<String, dynamic>> getAdminDashboard() async =>
      jsonDecode(jsonEncode(_dashboard)) as Map<String, dynamic>;

  // DASH-9: the race's own reading.
  @override
  Future<Map<String, dynamic>> getHomeLeaderboard({String period = 'today', String metric = 'weight'}) async => {
        'ranking': [
          {'id': 3, 'name': 'خالد', 'score': 420},
          {'id': 7, 'name': 'سارة', 'score': 310},
          {'id': 9, 'name': 'منى', 'score': 150},
          {'id': 11, 'name': 'فهد', 'score': 90},
        ],
      };

  @override
  Future<Map<String, dynamic>> getGramProfitReport({required DateTime startDate, required DateTime endDate}) async =>
      gramProfit;

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
  Future<_Api> open(WidgetTester tester,
      {double width = 1440, ThemeData? theme, Map<String, dynamic> gramProfit = const {}}) async {
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
    final api = _Api(gramProfit: gramProfit);
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

  testWidgets('each account in the summary reads as one row: its name and amount in one band', (tester) async {
    // The owner (12 Oct 2026): «في ملخص العمليات يصعب تحديد المبلغ لكل حساب
    // لعدم وجود تمييز بين كل صف وآخر» -- the name sat at one edge, the amount
    // at the other, nothing between them.
    await open(tester);
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('المصروفات').first);
    await tester.pump(const Duration(seconds: 1));

    Color? bandOf(int i) {
      final band = find.byKey(ValueKey('summary-row-$i'));
      expect(band, findsOneWidget, reason: 'row $i has its band');
      final box = tester.widget<Container>(band).decoration as BoxDecoration?;
      return box?.color;
    }

    for (final (i, name) in [(0, 'رواتب الموظفين'), (1, 'إيجار المعرض')]) {
      final band = find.byKey(ValueKey('summary-row-$i'));
      bandOf(i);
      expect(find.descendant(of: band, matching: find.text(name)), findsOneWidget);
      final amount = find.descendant(
        of: band,
        matching: find.byWidgetPredicate((w) => w is RichText && RegExp(r'\d').hasMatch(w.text.toPlainText())),
      );
      expect(amount, findsWidgets, reason: '$name and its amount share the band');
    }
    expect(bandOf(0), isNot(bandOf(1)), reason: 'neighbouring rows are told apart');
  });

  // DASH-3 (the owner, 30 Oct 2026): the period's card says the three purchases
  // apart -- a supplier's new gold, a customer's scrap, an office's settlement --
  // and each line its weight beside its amount.
  testWidgets('the period says each purchase, and the weight beside the amount', (tester) async {
    await open(tester);
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));
    final card = find.byKey(const Key('dashboard-period-movement'));
    for (final name in ['شراء جديد (موردون)', 'شراء كسر (عملاء)', 'تسكيرات (مكاتب)']) {
      expect(find.descendant(of: card, matching: find.text(name)), findsOneWidget, reason: name);
    }
    expect(find.descendant(of: card, matching: find.textContaining('7,100,000.00')), findsOneWidget);
    for (final grams in ['1,234.5', '987.6', '456.7']) {
      expect(find.descendant(of: card, matching: find.textContaining(grams)), findsOneWidget, reason: grams);
    }
  });

  // DASH-4 (the owner, 30 Oct 2026): what is ours and what we owe, in riyals and
  // grams -- the suppliers', the customers' and our gold at the offices.
  testWidgets('the dashboard says what is ours and what we owe', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-positions'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('للموردين')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('84,471.39')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('505.874')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('ذهبنا لدى المكاتب')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('396.404')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('على العملاء')), findsNothing,
        reason: 'a line with nothing in it is not said');
  });

  // DASH-5: what the banks and the instalment companies still owe us, and the late one.
  testWidgets('the dashboard says what waits for its deposit, and the late one', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-clearing'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('7,112.00')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('تمارا')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('متأخر')), findsOneWidget, reason: 'Tamara only');
  });

  // DASH-6: what waits for the manager, and only the queues that wait.
  testWidgets('the dashboard says what waits for the manager', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-approvals'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('فواتير')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('سندات')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('مكافآت')), findsNothing, reason: 'none waits');
  });

  // The owner, 30 Oct 2026: the gram profit card opened the weight close -- it
  // has its own card. Its details are the income statement's gram profit, on
  // the period the card says.
  testWidgets('the gram profit card opens its details on its own period', (tester) async {
    await open(tester, gramProfit: {
      'net_profit': 1200.0, 'net_profit_weight': 3.2, 'weight_sold': 50.0,
      'avg_sell_per_gram': 400.0, 'avg_buy_per_gram': 375.0, 'margin_per_gram': 25.0,
    });
    await tester.ensureVisible(find.byKey(const ValueKey('gram-profit-card')));
    await tester.tap(find.byKey(const ValueKey('gram-profit-card')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final report = tester.widget<IncomeStatementReportScreen>(find.byType(IncomeStatementReportScreen));
    final now = DateTime.now();
    expect(report.initialRange?.start, DateTime(now.year, now.month, now.day), reason: 'today, as the card says');
    expect(find.byType(WeightPositionScreen), findsNothing);
  });

  // DASH-7: what is wrong now, named, and the safe below zero in its grams.
  testWidgets('the dashboard says what is wrong now', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-wrong-now'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('ذهب الخزينة في حركاتها يخالف دفترها')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('خزينة ذهب الكسر مؤقتة تحت الصفر')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('-446.672 جم')), findsOneWidget);
  });

  // DASH-8: the VAT by its direction, the unfiled quarter, and why no output.
  testWidgets('the dashboard says the VAT, and the quarter not filed', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-vat'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('8,283.69')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('لكم')), findsNWidgets(2), reason: 'due back, both quarters');
    expect(find.descendant(of: card, matching: find.text('لم يُقدَّم إقراره')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('المبيعات لا تُحمَّل ضريبة حسب السياسة السارية')),
        findsOneWidget);
  });

  // DASH-9: the month's three leaders, and its losses by employee.
  testWidgets('the dashboard says who leads the month, and its losses', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-employees'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('1. خالد')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('فهد')), findsNothing, reason: 'three lead');
    expect(find.descendant(of: card, matching: find.text('2 فاتورة')), findsOneWidget);
  });
}
