import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/period_expenses_screen.dart';
import 'package:frontend/screens/period_lock_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sign_order.dart';

/// «مصروفات الفترات» and «إقفال الفترات» (ADR-090): the server's figures, said
/// as the invoices say a sum (the number, then the settings' sign); the
/// month-end action previewed before it writes; a month closed only after what
/// waits in it is shown, and accepted by name; reading the lock open to all,
/// moving it the owner's.

class _FakeApi extends ApiService {
  final accrued = <(String, bool)>[];
  final moves = <(String?, String, bool)>[];
  final pendingAsked = <String>[];
  Map<String, dynamic> waiting = {'total': 0};

  static const _rent = {
    'id': 7, 'description': 'إيجار المعرض 2026', 'expense_account_id': 92, 'status': 'active',
    'period_start': '2026-01-01', 'period_end': '2026-12-31', 'amount': 144900.0,
    'accrued': 120750.0, 'paid': 72450.0, 'balance': -48300.0, 'standing': 'accrued',
    'remaining_to_pay': 72450.0, 'posted_accrued': 120750.0, 'as_of': '2026-11-14',
  };
  static const _licence = {
    'id': 8, 'description': 'رخصة عمل يوسف', 'expense_account_id': 93, 'status': 'active',
    'period_start': '2026-07-17', 'period_end': '2027-07-16', 'amount': 9150.0,
    'accrued': 3050.0, 'paid': 9150.0, 'balance': 6100.0, 'standing': 'prepaid',
    'remaining_to_pay': 0.0, 'posted_accrued': 3050.0, 'as_of': '2026-11-14',
  };

  @override
  Future<List<Map<String, dynamic>>> getPeriodExpenses({String? asOf}) async => [_rent, _licence];

  @override
  Future<Map<String, dynamic>> getPeriodExpense(int id) async => {
        ...(id == 7 ? _rent : _licence),
        'schedule': [for (var m = 1; m <= 12; m++) {'month': '2026-${'$m'.padLeft(2, '0')}', 'amount': 12075.0}],
        'revisions': [
          {'reason': 'العقد الجديد', 'before': {'amount': '140000.0'}, 'after': {'amount': '144900.0'},
           'changed_by': 'owner', 'changed_at': '2026-11-01T10:00:00'},
        ],
      };

  final edits = <(int, String, String?, String?)>[];

  @override
  Future<Map<String, dynamic>> editPeriodExpense(int id,
      {required String reason, num? amount, String? periodStart, String? periodEnd}) async {
    edits.add((id, reason, periodStart, periodEnd));
    return getPeriodExpense(id);
  }

  @override
  Future<Map<String, dynamic>> accruePeriodExpenses(String through, {bool apply = false}) async {
    accrued.add((through, apply));
    return {
      'through': through,
      'entries': [
        {'period_expense_id': 7, 'month': '2026-10', 'amount': 12075.0, 'scheduled': 12075.0},
        {'period_expense_id': 8, 'month': '2026-10', 'amount': 762.5, 'scheduled': 762.5},
      ],
      'reclass': [],
      'drift': [],
    };
  }

  @override
  Future<Map<String, dynamic>> getPeriodLock() async => {
        'closed_through': moves.isEmpty ? '2026-09-30' : moves.last.$1,
        'history': [
          {'closed_through': '2026-09-30', 'reason': 'إقفال سبتمبر', 'changed_by': 'owner',
           'changed_at': '2026-10-05T09:00:00', 'accepted_pending': null},
        ],
      };

  @override
  Future<Map<String, dynamic>> getPeriodLockPending(String through) async {
    pendingAsked.add(through);
    return waiting;
  }

  @override
  Future<Map<String, dynamic>> movePeriodLock(
      {required String? closedThrough, required String reason, bool acceptPending = false}) async {
    moves.add((closedThrough, reason, acceptPending));
    return {'closed_through': closedThrough};
  }
}

Future<_FakeApi> _open(WidgetTester tester, Widget Function(_FakeApi) screen, {Size size = const Size(1280, 1600)}) async {
  SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final api = _FakeApi();
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(theme: LightTheme.theme, home: screen(api)),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('each expense says the server\'s three values, the sign after the number', (tester) async {
    await _open(tester, (api) => PeriodExpensesScreen(api: api));
    final rent = find.byKey(const ValueKey('period-expense-7'));
    expect(find.descendant(of: rent, matching: find.text('مستحق')), findsOneWidget);
    expect(find.descendant(of: rent, matching: find.textContaining('120,750.00')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('period-expense-8')), matching: find.text('مقدَّم')),
        findsOneWidget);
    final prepaid = find.byKey(const Key('period-expenses-prepaid'));
    expect(find.descendant(of: prepaid, matching: find.textContaining('6,100.00')), findsOneWidget);
    expect(signFollowsTheNumber(tester, find.descendant(of: prepaid, matching: find.textContaining('6,100.00')), 'ر.س'),
        isTrue);
  });

  testWidgets('one expense: its months and its edits', (tester) async {
    await _open(tester, (api) => PeriodExpensesScreen(api: api));
    await tester.tap(find.byKey(const ValueKey('period-expense-7')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('period-expense-values')), findsOneWidget);
    expect(find.text('2026-03'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('العقد الجديد'), findsOneWidget);
  });

  testWidgets('the month-end action is previewed, then written on confirmation', (tester) async {
    final api = await _open(tester, (api) => PeriodExpensesScreen(api: api));
    await tester.tap(find.byKey(const Key('period-expenses-accrue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accrue-preview')), findsOneWidget);
    expect(api.accrued.single.$2, isFalse);                       // a preview: nothing written yet
    expect(api.accrued.single.$1, matches(RegExp(r'-(28|29|30|31)$')));   // a month's last day
    await tester.tap(find.byKey(const Key('accrue-apply')));
    await tester.pumpAndSettle();
    expect(api.accrued.last.$2, isTrue);
  });

  testWidgets('on a phone nothing overflows', (tester) async {
    await _open(tester, (api) => PeriodExpensesScreen(api: api), size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('period-expense-7')), findsOneWidget);
  });

  // ── the lock ────────────────────────────────────────────────────────────────

  testWidgets('the lock on a phone: nothing overflows, its close dialog neither', (tester) async {
    await _open(tester, (api) => PeriodLockScreen(api: api, canMove: true), size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('period-lock-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the lock is read by anyone; moving it is the owner\'s', (tester) async {
    await _open(tester, (api) => PeriodLockScreen(api: api));
    expect(find.text('الدفاتر مقفلة حتى 2026-09-30'), findsOneWidget);
    expect(find.text('إقفال سبتمبر\nowner · 2026-10-05T09:00'), findsOneWidget);
    expect(find.byKey(const Key('period-lock-close')), findsNothing);
  });

  testWidgets('a month with nothing waiting closes with its reason', (tester) async {
    final api = await _open(tester, (api) => PeriodLockScreen(api: api, canMove: true));
    await tester.tap(find.byKey(const Key('period-lock-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('period-lock-nothing-waits')), findsOneWidget);
    expect(api.pendingAsked, hasLength(1));                     // asked once, not on every frame
    expect(tester.widget<FilledButton>(find.byKey(const Key('period-lock-confirm'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('period-lock-reason')), 'إقفال الشهر');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-confirm')));
    await tester.pumpAndSettle();
    expect(api.moves.single.$2, 'إقفال الشهر');
    expect(api.moves.single.$3, isFalse);
  });

  testWidgets('what waits is shown, and the close waits for it to be accepted by name', (tester) async {
    final api = await _open(tester, (api) {
      api.waiting = {
        'total': 1,
        'vouchers': {'count': 0, 'items': []},
        'entries': {'count': 1, 'items': [{'id': 5978, 'number': 'JE-2026-05978', 'date': '2026-09-26', 'draft': true}]},
        'invoices': {'count': 0, 'items': []},
        'period_expenses': {'count': 0, 'items': []},
      };
      return PeriodLockScreen(api: api, canMove: true);
    });
    await tester.tap(find.byKey(const Key('period-lock-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('period-lock-waiting')), findsOneWidget);
    expect(find.textContaining('JE-2026-05978 — 2026-09-26 (مسودة)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('period-lock-reason')), 'إقفال الشهر');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('period-lock-confirm'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('period-lock-accept')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-confirm')));
    await tester.pumpAndSettle();
    expect(api.moves.single.$3, isTrue);
  });

  testWidgets('the last closed month reopens for a correction, with its reason', (tester) async {
    final api = await _open(tester, (api) => PeriodLockScreen(api: api, canMove: true));
    await tester.tap(find.byKey(const Key('period-lock-reopen')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('period-lock-reopen-reason')), 'تصحيح قيد');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-reopen-confirm')));
    await tester.pumpAndSettle();
    expect(api.moves.single.$1, '2026-08-31');
  });

  testWidgets('one expense: its period changed, with its reason', (tester) async {
    final api = await _open(tester, (api) => PeriodExpensesScreen(api: api));
    await tester.tap(find.byKey(const ValueKey('period-expense-7')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('period-expense-edit-period')));
    await tester.tap(find.byKey(const Key('period-expense-edit-period')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));                     // the range picker, as it opened: the period kept
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('period-expense-reason')), 'العقد قُصّر');
    await tester.tap(find.byKey(const Key('period-expense-reason-ok')));
    await tester.pumpAndSettle();
    expect(api.edits.single, (7, 'العقد قُصّر', '2026-01-01', '2026-12-31'));
  });

  testWidgets('the lock reopens as far back as the correction needs, or wholly', (tester) async {
    final api = await _open(tester, (api) => PeriodLockScreen(api: api, canMove: true));
    await tester.tap(find.byKey(const Key('period-lock-reopen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-reopen-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025-12-31').last);                       // the opening's year, for its correction
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('period-lock-reopen-reason')), 'تصحيح الافتتاح');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-reopen-confirm')));
    await tester.pumpAndSettle();
    expect(api.moves.single.$1, '2025-12-31');

    await tester.tap(find.byKey(const Key('period-lock-reopen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-reopen-to')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('لا شيء مقفل (يُفتح كله)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('period-lock-reopen-reason')), 'فتح كامل');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lock-reopen-confirm')));
    await tester.pumpAndSettle();
    expect(api.moves.last.$1, isNull);
  });

  test('the months a close may choose: after the lock, up to the last one over', () {
    expect(monthEndsToClose(DateTime(2026, 9, 30), DateTime(2026, 11, 14)), [DateTime(2026, 10, 31)]);
    expect(monthEndsToClose(DateTime(2026, 10, 31), DateTime(2026, 11, 14)), isEmpty);
    expect(lastMonthEnd(DateTime(2026, 3, 5)), DateTime(2026, 2, 28));
  });
}
