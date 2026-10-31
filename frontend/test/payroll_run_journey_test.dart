import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/payroll_runs_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-2 (the owner, 1 Nov 2026, «اودع وابدأ»): a month's payroll is one
/// document -- the draft says who is left out and why, a line takes its
/// additions and deductions with their reasons, the run is approved whole,
/// then paid in a batch by how each employee is paid; nothing is paid while
/// one line has no account to leave from.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  String status = 'draft';
  List<Map<String, dynamic>> deductions = [];
  Map<int, int>? paidWith;

  Map<String, dynamic> _line(
    int id,
    String name,
    String? method,
    double net,
  ) => {
    'id': id,
    'employee_id': id * 10,
    'basic_salary': net,
    'allowances': 0.0,
    'deductions': 0.0,
    'net_salary': net,
    'status': switch (status) {
      'draft' => 'pending',
      'approved' => 'approved',
      _ => 'paid',
    },
    'employee': {'name': name, 'payment_method': method},
    if (status == 'paid') 'voucher': {'voucher_number': 'PAY-2041-04-000$id'},
    'breakdown': {
      'days': 30,
      'whole_month': true,
      'earned': {'basic': net},
      'additions': <dynamic>[],
      'deductions': id == 1 ? deductions : <dynamic>[],
    },
  };

  PayrollRun get _run {
    final cut = deductions.fold<double>(0, (s, d) => s + (d['amount'] as num));
    return PayrollRun.fromJson({
      'id': 9,
      'month': 4,
      'year': 2041,
      'status': status,
      'entries': [
        _line(1, 'مسعد', 'bank', 7000 - cut),
        _line(2, 'مبارك', null, 7500),
      ],
      'left_out': [
        {'employee_id': 30, 'name': 'يوسف', 'reason': 'no_structure'},
      ],
      'totals': {'net_salary': 14500 - cut},
    });
  }

  @override
  Future<PayrollRun> getRun(int id) async => _run;

  @override
  Future<PayrollRun> editLine(
    int runId,
    int lineId, {
    required List<PayrollLabelledAmount> additions,
    required List<PayrollLabelledAmount> deductions,
    String? notes,
  }) async {
    this.deductions = deductions.map((d) => d.toJson()).toList();
    return _run;
  }

  @override
  Future<PayrollRun> approve(int runId) async {
    status = 'approved';
    return _run;
  }

  @override
  Future<List<Map<String, dynamic>>> paymentAccounts() async => [
    {'id': 1, 'name': 'بنك الرياض'},
    {'id': 2, 'name': 'الصندوق'},
  ];

  @override
  Future<PayrollRun> pay(
    int runId, {
    required Map<int, int> accountByLine,
    required String paidDate,
  }) async {
    paidWith = accountByLine;
    status = 'paid';
    return _run;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _choose(WidgetTester tester, String key, String item) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  await tester.tap(find.text(item).last);
  await _settle(tester);
}

void main() {
  testWidgets(
    'a run is reviewed, approved whole, then paid by how each is paid',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server();
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(api: ApiService(), runId: 9, service: server),
        ),
      );
      await _settle(tester);

      // the draft: its lines, and who is left out, with why
      expect(find.byKey(const ValueKey('payroll-line-10')), findsOneWidget);
      expect(find.textContaining('لا هيكل راتب له'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payroll-run-pay')),
        findsNothing,
        reason: 'a draft is approved first',
      );

      // a deduction, with its reason
      await tester.tap(find.byKey(const ValueKey('payroll-line-edit-10')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('deduction-add')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('deduction-label-0')),
        'غياب يوم',
      );
      await tester.enterText(
        find.byKey(const ValueKey('deduction-amount-0')),
        '٢٠٠',
      );
      await tester.tap(find.byKey(const ValueKey('payroll-line-save')));
      await _settle(tester);
      expect(server.deductions, [
        {'label': 'غياب يوم', 'amount': 200.0},
      ]);
      expect(find.textContaining('غياب يوم'), findsOneWidget);

      // approved whole
      await tester.tap(find.byKey(const ValueKey('payroll-run-approve')));
      await _settle(tester);
      expect(find.textContaining('قيد استحقاق واحد'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('payroll-run-confirm')));
      await _settle(tester);
      expect(server.status, 'approved');
      expect(
        find.byKey(const ValueKey('payroll-line-edit-10')),
        findsNothing,
        reason: 'approved is kept',
      );

      // paid: not while مبارك has no way to be paid
      await tester.tap(find.byKey(const ValueKey('payroll-run-pay')));
      await _settle(tester);
      await _choose(tester, 'payroll-pay-bank', 'بنك الرياض');
      FilledButton confirm() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('payroll-pay-confirm')),
      );
      expect(confirm().onPressed, isNull, reason: 'none, not some');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('payroll-pay-method-2')),
          matching: find.text('نقد'),
        ),
      );
      await _settle(tester);
      expect(confirm().onPressed, isNull, reason: 'cash, but from which safe');
      await _choose(tester, 'payroll-pay-cash', 'الصندوق');
      await tester.tap(find.byKey(const ValueKey('payroll-pay-confirm')));
      await _settle(tester);
      expect(server.paidWith, {1: 1, 2: 2});
      expect(find.textContaining('PAY-2041-04-0001'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payroll-run-cancel')),
        findsNothing,
        reason: 'a paid run is not cancelled',
      );
    },
  );
}
