import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/account_statement_model.dart';
import 'package:frontend/models/statement_period.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A statement's balance is the server's (10 Oct 2026).
///
/// The screen recomputed each line's balance from the lines left after a
/// filter: searching for «مدى» or showing debits only put numbers in the
/// balance column that were not the account's balance. Its PDF kept a copy of
/// the same arithmetic. The server now sends each line's balance, as it
/// computes the closing; the screen and the PDF read it, and a filter only
/// hides lines.

Map<String, dynamic> _line(int id, String day, String description,
        {double debit = 0, double credit = 0, required double running}) =>
    {
      'id': id,
      'date': '${day}T10:00:00',
      'description': description,
      'journal_entry_id': id,
      'entry_number': 'JE-$id',
      'cash_debit': debit,
      'cash_credit': credit,
      'gold_debit': 0.0,
      'gold_credit': 0.0,
      'running_cash_balance': running,
      'running_gold_balance': 0.0,
    };

final _statementJson = <String, dynamic>{
  'opening_balance_cash': 0.0,
  'opening_balance_gold_normalized': 0.0,
  'closing_balance_cash': 2500.0,
  'closing_balance_gold_normalized': 0.0,
  'main_karat': 21,
  'totals': {'cash_debit': 3000.0, 'cash_credit': 500.0, 'gold_debit_normalized': 0.0,
             'gold_credit_normalized': 0.0},
  'lines': [
    _line(1, '2026-09-01', 'بيع نقدي', debit: 1000, running: 1000),
    _line(2, '2026-09-15', 'بيع نقدي', debit: 2000, running: 3000),
    _line(3, '2026-10-02', 'تسديد عميل', credit: 500, running: 2500),
  ],
};

/// Sixty sales of 100.00 a day apart: a statement long enough to scroll.
final _longStatementJson = <String, dynamic>{
  ..._statementJson,
  'closing_balance_cash': 6000.0,
  'lines': [
    for (var i = 0; i < 60; i++)
      _line(100 + i, DateTime(2026, 8, 1).add(Duration(days: i)).toIso8601String().substring(0, 10),
          'بيع رقم $i', debit: 100, running: 100.0 * (i + 1)),
  ],
};

class _FakeApi extends ApiService {
  _FakeApi({this.fail = false, this.long = false, this.hold});

  /// The server cannot be reached.
  final bool fail;
  final bool long;

  /// Completed when the statement may arrive -- a slow server.
  final Completer<void>? hold;

  @override
  Future<Map<String, dynamic>> getAccountStatement(int accountId, {bool includeCancelled = false}) async {
    if (hold != null) await hold!.future;
    if (fail) throw Exception('تعذّر الاتصال بالخادم');
    return long ? _longStatementJson : _statementJson;
  }

  @override
  Future<Map<String, dynamic>> getCustomerStatement(int customerId, {bool includeCancelled = false}) async =>
      _statementJson;

  @override
  Future<Map<String, dynamic>> getAccountById(int accountId) async =>
      {'id': accountId, 'name': 'عميل نقدي', 'transaction_type': 'cash', 'tracks_weight': false};
}

void main() {
  test('each line keeps the balance the server gave it -- the model sums nothing', () {
    final json = jsonDecode(jsonEncode(_statementJson)) as Map<String, dynamic>;
    (json['lines'] as List)[2]['running_cash_balance'] = 7777.0;   // not the sum: still taken
    final statement = AccountStatement.fromJson(json);
    expect(statement.lines.map((l) => l.runningCashBalance), [1000.0, 3000.0, 7777.0]);
  });

  test('a period opens and closes on the server\'s balances', () {
    final statement = AccountStatement.fromJson(_statementJson);
    final october = statementPeriod(
        statement, DateTimeRange(start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 31)));
    expect(october.openingCash, 3000.0);
    expect(october.closingCash, 2500.0);
    expect(october.movementCash, -500.0);
    final all = statementPeriod(statement, null);
    expect((all.openingCash, all.closingCash), (0.0, 2500.0));
    expect(statementBalanceBefore(statement, DateTime(2026, 9, 2)).cash, 1000.0);
  });

  Future<void> open(WidgetTester tester, {_FakeApi? api, String entityType = 'account',
      Map<String, Object> prefs = const {}, bool settle = true}) async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21}), ...prefs});
    tester.view.physicalSize = const Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AccountStatementScreen(
              accountId: 925, accountName: 'عميل نقدي', entityType: entityType, apiService: api ?? _FakeApi()),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A skeleton animates: frames are moved, not awaited.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

  testWidgets('a search hides lines; the line it leaves shows the account\'s balance', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, 'تسديد');
    await tester.pumpAndSettle();

    expect(find.textContaining('تسديد عميل'), findsWidgets);
    expect(find.textContaining('بيع نقدي'), findsNothing);
    expect(find.text('2500.00 مدين'), findsWidgets, reason: 'the balance after the payment');
    expect(find.text('500.00 دائن'), findsNothing,
        reason: 'recomputed from the filtered lines, the payment read as a balance of -500.00');
    expect(find.text('فلاتر (1)'), findsOneWidget,
        reason: 'the search; the cash view chosen for a cash account is not a filter');
  });

  testWidgets('newest first: the closing on top, the opening at the bottom', (tester) async {
    await open(tester);
    final closing = find.byKey(const Key('statement-closing-row'));
    final opening = find.byKey(const Key('statement-opening-row'));
    expect(top(tester, closing), lessThan(top(tester, find.textContaining('تسديد عميل'))));
    expect(top(tester, find.textContaining('تسديد عميل')), lessThan(top(tester, find.text('2026-09-01'))));
    expect(top(tester, find.text('2026-09-01')), lessThan(top(tester, opening)));
    expect(find.textContaining('الرصيد الختامي'), findsWidgets);
  });

  testWidgets('oldest first, chosen once, is kept for the next statement', (tester) async {
    await open(tester);
    await tester.tap(find.text('الأقدم أولًا'));
    await tester.pumpAndSettle();

    final opening = find.byKey(const Key('statement-opening-row'));
    final closing = find.byKey(const Key('statement-closing-row'));
    expect(top(tester, opening), lessThan(top(tester, find.text('2026-09-01'))));
    expect(top(tester, find.textContaining('تسديد عميل')), lessThan(top(tester, closing)));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('account_statement_oldest_first'), isTrue);
  });

  testWidgets('a statement opens in the order last chosen', (tester) async {
    await open(tester, prefs: {'account_statement_oldest_first': true});
    expect(top(tester, find.byKey(const Key('statement-opening-row'))),
        lessThan(top(tester, find.byKey(const Key('statement-closing-row')))));
  });

  testWidgets('a customer\'s balance reads «عليه», an account\'s «مدين»', (tester) async {
    await open(tester, entityType: 'customer');
    expect(find.text('2500.00 عليه'), findsWidgets);
    expect(find.text('2500.00 مدين'), findsNothing);
  });

  testWidgets('a failed load says so and offers to try again -- not «no records»', (tester) async {
    await open(tester, api: _FakeApi(fail: true));
    expect(find.byKey(const Key('statement-load-error')), findsOneWidget);
    expect(find.textContaining('تعذّر الاتصال بالخادم'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.textContaining('لا توجد'), findsNothing);
  });

  testWidgets('a ready period sets the range in one tap', (tester) async {
    await open(tester);
    expect(find.text('نطاق التاريخ'), findsOneWidget);
    await tester.tap(find.byKey(const Key('statement-periods')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('هذا الشهر').last);
    await tester.pumpAndSettle();
    expect(find.text('نطاق التاريخ'), findsNothing);
    expect(find.textContaining('رصيد آخر الفترة'), findsWidgets);
  });

  testWidgets('one scroll: dragging the lines first takes the summary away', (tester) async {
    await open(tester, api: _FakeApi(long: true));
    final summary = find.textContaining('رصيد افتتاحي');
    final before = top(tester, summary);

    await tester.drag(find.text('بيع رقم 50'), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(summary.hitTestable(), findsNothing,
        reason: 'the lines used to scroll inside a box, the summary staying put above them (was at $before)');
  });

  testWidgets('the lines take the page, not a box 55 % of it', (tester) async {
    await open(tester, api: _FakeApi(long: true));
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final table = tester.getRect(find.byKey(const Key('statement-table')));
    expect(table.bottom, greaterThan(screen - 40), reason: 'to the bottom of the screen');
  });

  testWidgets('the less-used filters wait behind «فلاتر»; one at work stays in sight', (tester) async {
    await open(tester);
    expect(find.text('حركات فقط'), findsNothing);

    await tester.tap(find.byKey(const Key('statement-filters-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('حركات فقط'), findsOneWidget);

    await tester.tap(find.text('حركات فقط'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('statement-filters-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('حركات فقط'), findsOneWidget, reason: 'a filter hiding lines is never out of sight');
  });

  testWidgets('while it loads, the page shows its shape -- not a lone spinner', (tester) async {
    final hold = Completer<void>();
    await open(tester, api: _FakeApi(hold: hold), settle: false);
    expect(find.byKey(const Key('statement-skeleton')), findsOneWidget);
    hold.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('statement-skeleton')), findsNothing);
    expect(find.textContaining('تسديد عميل'), findsWidgets);
  });
}
