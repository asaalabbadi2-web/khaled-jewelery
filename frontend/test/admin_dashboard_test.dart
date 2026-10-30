import 'dart:async';
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
import 'package:frontend/screens/reports/widgets/dashboard_kit.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/shots.dart';

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
  'sales_purchases_summary': {
    'today': _period(),
    'month': _period(sales: 338940.10, purchases: 339579.02, expenses: 62074.22),
    'year': _period(sales: 11602016.09, purchases: 13552408.09, expenses: 776885.09,
        scrap: 7100000.0, settlements: 2400000.0),
  },
};

// DASH-10: where the business stands -- its own request, beside the dashboard's.
final _standing = <String, dynamic>{
  // DASH-4: the production copy's, 27 Oct 2026.
  'positions': {
    'customers': {'owe_us_cash': 0.0, 'we_owe_cash': 0.0, 'owe_us_gold': 0.0, 'we_owe_gold': 0.0},
    'suppliers': {'owe_us_cash': 474.05, 'we_owe_cash': 84471.39, 'owe_us_gold': 356.368, 'we_owe_gold': 505.874},
    'offices_gold': 396.404,
    'offices': [],
  },
  // DASH-5: the production copy's, 31 Oct 2026 -- by the scheduler's reading.
  'clearing': {
    'total': 75312.0,
    'overdue': 1,
    'safes': [
      {'safe': 'مدى', 'amount': 12000.0, 'payments': 5, 'next_deposit': '2026-10-31', 'below_minimum': false,
       'overdue': true, 'overdue_since': '2026-10-31'},
      {'safe': 'تابي', 'amount': 35000.0, 'payments': 2, 'next_deposit': '2026-11-02', 'below_minimum': false,
       'overdue': false, 'overdue_since': null},
      {'safe': 'تمارا', 'amount': 28312.0, 'payments': 7, 'next_deposit': '2026-11-04', 'below_minimum': false,
       'overdue': false, 'overdue_since': null},
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
};

class _Api extends ApiService {
  _Api({this.gramProfit = const {}, this.standingGate});

  final Map<String, dynamic> gramProfit;
  // Holds where the business stands until the test lets it come.
  final Future<void>? standingGate;
  int invoiceCalls = 0;

  // «التسكير الآن» has its own test (weight_position_summary_card_test.dart).
  @override
  Future<Map<String, dynamic>?> getWeightPositionSummary() async => null;

  @override
  Future<Map<String, dynamic>> getAdminDashboard() async =>
      jsonDecode(jsonEncode(_dashboard)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> getAdminDashboardStanding() async {
    await standingGate;
    return jsonDecode(jsonEncode(_standing)) as Map<String, dynamic>;
  }

  // DASH-11: the live price, as /gold_price answers -- the main karat the settings'.
  @override
  Future<Map<String, dynamic>> getGoldPrice() async => {
        'main_karat': 21,
        'date': '2026-10-30T11:32:05Z',
        'price_usd_per_oz': 4012.5,
        'prices_per_gram': {
          '24': {'sell': 452.10, 'buy': 434.02},
          '22': {'sell': 414.40, 'buy': 397.82},
          '21': {'sell': 395.12, 'buy': 380.10},
          '18': {'sell': 339.08, 'buy': 325.52},
        },
        'opening_prices_per_gram': {
          '21': {'sell': 393.47, 'buy': 378.51},
        },
      };

  // DASH-11: the day's move, as /gold_price/24h?day=today answers.
  @override
  Future<Map<String, dynamic>> getGoldPriceToday() async => {
        'main_karat': 21,
        'high_main_karat': 396.20,
        'low_main_karat': 392.10,
        'points': [
          {'price_main_karat': 393.47},
          {'price_main_karat': 392.10},
          {'price_main_karat': 396.20},
          {'price_main_karat': 395.12},
        ],
        'count': 4,
      };

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
  Future<_Api> mount(WidgetTester tester, _Api api, {double width = 1440, ThemeData? theme}) async {
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

  Future<_Api> open(WidgetTester tester,
          {double width = 1440, ThemeData? theme, Map<String, dynamic> gramProfit = const {}}) =>
      mount(tester, _Api(gramProfit: gramProfit), width: width, theme: theme);

  testWidgets('a quiet morning asks the server once -- the screen sums no invoices', (tester) async {
    final api = await open(tester);
    expect(api.invoiceCalls, 0, reason: 'three requests of up to 1,000 invoices each, every load');
    expect(find.text('لا توجد عمليات بعد'), findsWidgets);
  });

  testWidgets('the period\'s activity, nothing subtracted: no profit, no loss of millions', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('هذه السنة'));
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
    await tester.ensureVisible(find.text('هذه السنة'));
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
    await tester.ensureVisible(find.text('هذه السنة'));
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
    await tester.ensureVisible(find.text('هذه السنة'));
    await tester.tap(find.text('هذه السنة'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('المصروفات').first);
    await tester.pump(const Duration(seconds: 1));

    // The accounts are one table (DASH-12): each row its band, its name on its amount's line.
    final table = tester.widget<Table>(
        find.descendant(of: find.byKey(const Key('summary-accounts')), matching: find.byType(Table)));
    Color? bandOf(int i) => (table.children[i].decoration as BoxDecoration?)?.color;
    for (final (i, name, amount) in [(0, 'رواتب الموظفين', '466,131.05'), (1, 'إيجار المعرض', '310,754.04')]) {
      expect(bandOf(i), isNotNull, reason: 'row $i has its band');
      final nameY = tester.getCenter(find.text(name)).dy;
      final amountY = tester.getCenter(find.textContaining(amount, findRichText: true).first).dy;
      expect((nameY - amountY).abs(), lessThan(2), reason: '$name and its amount share the band');
    }
    expect(bandOf(0), isNot(bandOf(1)), reason: 'neighbouring rows are told apart');
  });

  // DASH-3 (the owner, 30 Oct 2026): the period's card says the three purchases
  // apart -- a supplier's new gold, a customer's scrap, an office's settlement --
  // and each line its weight beside its amount.
  testWidgets('the period says each purchase, and the weight beside the amount', (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text('هذه السنة'));
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
    // The owner, 30-31 Oct 2026: «فاصل بين الوزن والمبلغ ... الأوزان بعدت عن
    // المبالغ ... المسافة بين كلمة "جرام" وأكبر مبلغ إلى الفاصل بنفس المسافة».
    final dividers = find.descendant(of: card, matching: find.byKey(const Key('weight-amount-divider')));
    expect(dividers, findsNWidgets(3), reason: 'one hairline for each weight');
    final xs = [for (final d in dividers.evaluate()) tester.getCenter(find.byWidget(d.widget)).dx];
    expect(xs.every((x) => (x - xs.first).abs() < 0.5), isTrue, reason: 'the hairlines in one column: $xs');
    // The widest amount (the sales) and its weight, either side of its hairline, right to left.
    final word = tester.getRect(find.descendant(of: card, matching: find.textContaining('1,234.5')));
    final line = tester.getRect(dividers.first);
    final widest = tester.getRect(
        find.descendant(of: card, matching: find.textContaining('11,602,016.09', findRichText: true)).first);
    final toWord = word.left - line.right;
    final toAmount = line.left - widest.right;
    expect(toWord, moreOrLessEquals(toAmount, epsilon: 1), reason: 'word $toWord, amount $toAmount');
    expect(toAmount, lessThan(24), reason: 'the weight near its amount');
  });

  // DASH-4 (the owner, 30 Oct 2026): what is ours and what we owe, in riyals and
  // grams -- the suppliers', the customers' and our gold at the offices.
  testWidgets('the dashboard says what is ours and what we owe', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-positions'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('الموردون')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('84,471.39')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('505.874')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('ذهبنا لدى المكاتب')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('396.404')), findsOneWidget);
  });

  // DASH-5: what the banks and the instalment companies still owe us, and the late one.
  testWidgets('the dashboard says what waits for its deposit, and the late one', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-clearing'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('75,312.00')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('تمارا')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('متأخر', findRichText: true)), findsOneWidget,
        reason: 'Mada only, as the alarm says');
    expect(find.descendant(of: card, matching: find.textContaining('الإيداع 2026-11-04', findRichText: true)),
        findsOneWidget, reason: "Tamara's next deposit, by its schedule");
  });

  // The 31 Oct copy: what waits below its method's minimum is not late -- it waits.
  testWidgets('what waits below its minimum is said so, not late', (tester) async {
    final saved = jsonDecode(jsonEncode(_standing)) as Map<String, dynamic>;
    addTearDown(() => _standing..clear()..addAll(saved));
    ((_standing['clearing'] as Map)['safes'] as List)[2] = {
      'safe': 'تمارا', 'amount': 2392.0, 'payments': 2, 'next_deposit': null, 'below_minimum': true,
      'overdue': false, 'overdue_since': null,
    };
    await open(tester);
    final card = find.byKey(const Key('dashboard-clearing'));
    expect(find.descendant(of: card, matching: find.textContaining('دون الحد الأدنى للإيداع', findRichText: true)),
        findsOneWidget);
  });

  // DASH-6/10: what waits for the manager -- a pill; its rows when opened, only the queues that wait.
  testWidgets('the dashboard says what waits for the manager', (tester) async {
    await open(tester);
    final pill = find.byKey(const Key('dashboard-approvals'));
    expect(pill, findsOneWidget);
    expect(find.descendant(of: pill, matching: find.text('3')), findsOneWidget);
    expect(find.byKey(const Key('dashboard-attention-detail')), findsNothing, reason: 'closed until asked');
    await tester.tap(pill);
    await tester.pump(const Duration(milliseconds: 300));
    final detail = find.byKey(const Key('dashboard-attention-detail'));
    expect(find.descendant(of: detail, matching: find.text('1 فواتير')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('2 سندات')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.textContaining('مكافآت')), findsNothing, reason: 'none waits');
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

  // DASH-7/10: what is wrong now -- a pill, not a block; named, and the safe below zero in its grams.
  testWidgets('the dashboard says what is wrong now', (tester) async {
    await open(tester, theme: DarkTheme.theme);
    final pill = find.byKey(const Key('dashboard-wrong-now'));
    expect(pill, findsOneWidget);
    expect(tester.getSize(pill).height, lessThan(48), reason: 'a line, not a card (the owner)');
    await tester.tap(pill);
    await tester.pump(const Duration(milliseconds: 300));
    final detail = find.byKey(const Key('dashboard-attention-detail'));
    expect(find.descendant(of: detail, matching: find.text('ذهب الخزينة في حركاتها يخالف دفترها')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('خزينة ذهب الكسر مؤقتة تحت الصفر')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('-446.672 جم')), findsOneWidget);
  });

  testWidgets('nothing needing the manager is one quiet pill', (tester) async {
    final saved = jsonDecode(jsonEncode(_standing)) as Map<String, dynamic>;
    addTearDown(() => _standing..clear()..addAll(saved));
    _standing['wrong_now'] = {'findings': [], 'negative_safes': [], 'total': 0};
    _standing['approvals'] = {'total': 0};
    await open(tester);
    expect(find.byKey(const Key('dashboard-all-clear')), findsOneWidget);
    expect(find.byKey(const Key('dashboard-wrong-now')), findsNothing);
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
    expect(find.descendant(of: card, matching: find.text('خالد')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.textContaining('فهد')), findsNothing, reason: 'three lead');
    expect(find.descendant(of: card, matching: find.text('2 فاتورة')), findsOneWidget);
  });

  // DASH-10 (the owner, 30 Oct 2026): «تعتمد حلقة الانتظار بدل الشكل الذي اعتمدناه
  // في الثيم» -- the first load is the page's shape in grey, not a spinner; and
  // the screen does not wait for where the business stands.
  testWidgets('the first load is the page\'s shape, and the standing does not hold it', (tester) async {
    final gate = Completer<void>();
    await mount(tester, _Api(standingGate: gate.future));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('dashboard-period-movement')), findsOneWidget,
        reason: 'the dashboard is drawn while the standing is on its way');
    expect(find.byType(DashboardPanelSkeleton), findsWidgets, reason: 'its panels wait in grey');
    gate.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('dashboard-positions')), findsOneWidget);
  });

  // The owner, 30 Oct 2026: «الآن ثم بعده مباشرة الأداء ثم البقية، والخزائن تكون
  // أسفل الصفحة».
  testWidgets('now, the performance straight after it, the month and quarter, the safes at the foot', (tester) async {
    final saved = jsonDecode(jsonEncode(_dashboard)) as Map<String, dynamic>;
    addTearDown(() => _dashboard..clear()..addAll(saved));
    _dashboard['safe_boxes'] = [
      {'id': 1, 'name': 'الصندوق الرئيسي', 'safe_type': 'cash', 'balance_cash': 1200.0,
       'weight_balance': {}, 'total_weight_main_karat': 0.0, 'main_karat': 21},
    ];
    await open(tester);
    final now = tester.getTopLeft(find.text('الآن')).dy;
    final performance = tester.getTopLeft(find.text('الأداء')).dy;
    final period = tester.getTopLeft(find.byKey(const Key('dashboard-period'))).dy;
    final month = tester.getTopLeft(find.text('هذا الشهر وهذا الربع')).dy;
    final safes = tester.getTopLeft(find.text('توزيع العهد والخزائن')).dy;
    expect(now, lessThan(performance));
    expect((period - performance).abs(), lessThan(60), reason: 'the period sits on its section');
    expect(performance, lessThan(month));
    expect(month, lessThan(safes), reason: 'the safes at the foot');
  });

  // The owner, 30 Oct 2026: «أزرار الفترات ليست في مركز الشاشة بل مسحوبة على اليسار».
  testWidgets('the period\'s buttons sit in the screen\'s middle, wide and narrow', (tester) async {
    for (final width in [1440.0, 390.0]) {
      await open(tester, width: width);
      final selector = tester.getCenter(find.byKey(const Key('dashboard-period'))).dx;
      expect((selector - width / 2).abs(), lessThan(4), reason: 'at $width');
    }
  });

  // DASH-10: the screen drawn, for looking at (SHOT_DIR; nothing without it).
  testWidgets('the dashboard drawn, light and dark, wide and narrow', (tester) async {
    for (final (name, theme) in [('light', LightTheme.theme), ('dark', DarkTheme.theme)]) {
      await open(tester, theme: theme);
      await shot(tester, 'dashboard_${name}_desktop');
      await tester.tap(find.byKey(const Key('dashboard-wrong-now')));
      await tester.pump(const Duration(milliseconds: 300));
      await shot(tester, 'dashboard_${name}_alerts_open');
      await tester.ensureVisible(find.text('هذه السنة').first);
      await tester.tap(find.text('هذه السنة').first);
      await tester.pump(const Duration(seconds: 1));
      await shot(tester, 'dashboard_${name}_year');
      await open(tester, theme: theme, width: 390);
      await shot(tester, 'dashboard_${name}_phone');
    }
  });

  // DASH-11 (the owner, 30 Oct 2026): «بطاقة سعر الذهب ارتفاعها أكبر من بطاقة المركز
  // المالي ... ما الذي ينقصها لنكتفي به من سعر الذهب» -- the main karat selling
  // and buying, live with its time, the day's move, the ounce; one height.
  testWidgets('the gold price card says enough, at the financial position\'s height', (tester) async {
    await open(tester);
    final card = find.byKey(const Key('dashboard-gold-price'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('عيار 21')), findsOneWidget, reason: 'the main karat');
    expect(find.descendant(of: card, matching: find.textContaining('395.12')), findsOneWidget, reason: 'selling');
    expect(find.descendant(of: card, matching: find.textContaining('380.10')), findsOneWidget, reason: 'buying');
    expect(find.descendant(of: card, matching: find.byKey(const Key('dashboard-gold-price-at'))), findsOneWidget);
    final move = find.descendant(of: card, matching: find.byKey(const Key('dashboard-gold-price-move')));
    expect(find.descendant(of: move, matching: find.textContaining('0.42%')), findsOneWidget,
        reason: '395.12 against the opening 393.47');
    expect(find.descendant(of: card, matching: find.textContaining('396.20')), findsOneWidget, reason: 'the high');
    expect(find.descendant(of: card, matching: find.textContaining('4,012.50')), findsOneWidget, reason: 'the ounce');
    expect(tester.getSize(card).height,
        moreOrLessEquals(tester.getSize(find.byKey(const Key('dashboard-net-position'))).height, epsilon: 0.5));
  });
}
