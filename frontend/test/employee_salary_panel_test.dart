import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/payroll_runs_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/employee_salary_panel.dart';

/// HR-UX ط1, ط2 (the owner, 2 Nov 2026, «اعتمد»): his salary in one place --
/// the one in force, «تغيير الراتب» from the server's day, split by the
/// policy as the gross is typed and its parts summed against it, the history
/// with what approved salaries read kept, how he is paid saved at once; what
/// was typed and not saved is said before the dialog holding it closes.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  int? deleted;
  Map<String, Object>? added;
  String? savedIban;
  (String?, double?)? savedSplit;
  double owed = 0;
  double advanceFree = 0;
  (double, int?)? paidOwed;
  (double, bool)? tookAdvance;

  @override
  Future<({double owed, double advanceFree, double advanceCap})> salaryOwed(
    int employeeId,
  ) async => (owed: owed, advanceFree: advanceFree, advanceCap: 750.0);

  @override
  Future<String> payOwed(
    int employeeId, {
    required double amount,
    required int? paymentAccountId,
    double advance = 0,
    bool consent = false,
  }) async {
    paidOwed = (amount, paymentAccountId);
    tookAdvance = (advance, consent);
    owed -= amount + advance;
    return 'PAYK-2026-0001';
  }

  @override
  Future<List<Map<String, dynamic>>> paymentAccounts() async => [
    {'id': 2, 'name': 'الصندوق'},
  ];

  @override
  Future<SalaryStructures> structures(int employeeId) async =>
      SalaryStructures.fromJson({
        'structures': [
          {
            'id': 5,
            'effective_from': '2026-09-01',
            'basic': 5185.19,
            'housing': 1296.30,
            'transport': 518.51,
            'other_allowances': 0.0,
            'gross': 7000.0,
            'locked': false,
          },
          {
            'id': 4,
            'effective_from': '2026-04-01',
            'basic': 7407.41,
            'housing': 1851.85,
            'transport': 740.74,
            'other_allowances': 0.0,
            'gross': 10000.0,
            'locked': true,
          },
        ],
        'current_id': 5,
        'suggested_from': '2026-10-01',
      });

  @override
  Future<Map<String, double>> suggest(double gross) async => {
    'basic': 5555.56,
    'housing': 1388.89,
    'transport': 555.55,
    'other_allowances': 0.0,
    'gross': gross,
  };

  @override
  Future<void> addStructure(
    int employeeId, {
    required String effectiveFrom,
    required double basic,
    required double housing,
    required double transport,
    required double otherAllowances,
  }) async => added = {
    'from': effectiveFrom,
    'basic': basic,
    'housing': housing,
    'transport': transport,
    'other': otherAllowances,
  };

  @override
  Future<Map<String, dynamic>> payment(int employeeId) async => {
    'payment_method': 'bank',
    'iban': null,
    'bank_name': null,
    'contribution_scheme_id': null,
    'contribution_wage': null,
  };

  @override
  Future<void> savePayment(
    int employeeId, {
    required String? method,
    required String? iban,
    required String? bankName,
    required int? schemeId,
    required double? contributionWage,
    String? splitMethod,
    double? splitAmount,
  }) async {
    savedIban = iban;
    savedSplit = (splitMethod, splitAmount);
  }

  @override
  Future<List<Map<String, dynamic>>> schemes() async => const [];

  @override
  Future<(List<AdvancePlanModel>, double, double)> advancePlans(
    int employeeId,
  ) async => (<AdvancePlanModel>[], 0.0, 0.0);

  @override
  Future<void> deleteStructure(int structureId) async => deleted = structureId;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _wide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1100, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String _text(WidgetTester tester, String key) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

void main() {
  testWidgets('the salary in force, changed from the server\'s day, its parts '
      'summed against the gross; the history keeps what was approved', (
    tester,
  ) async {
    await _wide(tester);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeSalaryPanel(
              service: server,
              employeeId: 7,
              isAr: true,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('7,000.00'), findsWidgets);
    expect(find.text('الساري الآن'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('structure-delete-4')),
      findsNothing,
      reason: 'approved salaries read it',
    );
    expect(find.textContaining('فلا يُحذف'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salary-change')));
    await _settle(tester);
    expect(
      _text(tester, 'structure-from'),
      '2026-10-01',
      reason: 'the server\'s day',
    );

    await tester.enterText(
      find.byKey(const ValueKey('structure-gross')),
      '7500',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('structure-basic')))
          .controller!
          .text,
      '5555.56',
    );
    expect(find.textContaining('يساوي الإجمالي'), findsOneWidget);

    // by hand: a part changed, the difference said, the save held
    await tester.tap(find.text('يدويًا'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('structure-housing')),
      '1288.89',
    );
    await _settle(tester);
    expect(find.textContaining('ينقص'), findsOneWidget);
    FilledButton save() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('structure-save')),
    );
    expect(
      save().onPressed,
      isNull,
      reason: 'not saved until the parts sum to the gross',
    );
    await tester.enterText(
      find.byKey(const ValueKey('structure-other')),
      '100',
    );
    await _settle(tester);
    expect(save().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('structure-save')));
    await _settle(tester);
    expect(server.added, {
      'from': '2026-10-01',
      'basic': 5555.56,
      'housing': 1288.89,
      'transport': 555.55,
      'other': 100.0,
    });
    expect(
      find.byKey(const ValueKey('salary-change-form')),
      findsNothing,
      reason: 'saved, closed',
    );

    await tester.tap(find.byKey(const ValueKey('structure-delete-5')));
    await _settle(tester);
    expect(server.deleted, isNull, reason: 'not before it is confirmed');
    await tester.tap(find.byKey(const Key('confirm-action')));
    await _settle(tester);
    expect(server.deleted, 5);
  });

  testWidgets('in a run\'s dialog: the unsaved said, the close asked', (
    tester,
  ) async {
    await _wide(tester);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EmployeePayrollDialog(
                  service: server,
                  employeeId: 7,
                  name: 'مسعد',
                  isAr: true,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('employee-advances')),
      findsOneWidget,
      reason: 'its advances beside',
    );

    await tester.enterText(
      find.byKey(const ValueKey('employee-iban')),
      'SA0380000000608010167519',
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('salary-payment-unsaved')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('employee-payroll-close')));
    await _settle(tester);
    expect(find.text('الخروج دون حفظ؟'), findsOneWidget);
    await tester.tap(find.text('البقاء'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('employee-iban')),
      findsOneWidget,
      reason: 'stayed: the IBAN is there',
    );

    await tester.ensureVisible(
      find.byKey(const ValueKey('employee-payment-save')),
    );
    await tester.tap(find.byKey(const ValueKey('employee-payment-save')));
    await _settle(tester);
    expect(server.savedIban, 'SA0380000000608010167519');
    expect(find.byKey(const ValueKey('salary-payment-unsaved')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('employee-payroll-close')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('employee-iban')),
      findsNothing,
      reason: 'saved: closed at once',
    );
  });

  testWidgets('at a phone\'s width, the change form open, nothing overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: EmployeeSalaryPanel(
              service: _Server(),
              employeeId: 7,
              isAr: true,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('salary-change')));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('salary-change-form')), findsOneWidget);
  });

  testWidgets('PAY-SPLIT: a fixed amount by one way, the rest by the other, '
      'kept in his file', (tester) async {
    await _wide(tester);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeSalaryPanel(
              service: server,
              employeeId: 7,
              isAr: true,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey('employee-pay-split')),
    );
    await tester.tap(find.byKey(const ValueKey('employee-pay-split')));
    await _settle(tester);
    await tester.tap(find.text('تحويل ثابت'));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('employee-pay-split-amount')),
      '5000',
    );
    await _settle(tester);
    expect(find.textContaining('والباقي من صافي الشهر نقدًا'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('employee-payment-save')),
    );
    await tester.tap(find.byKey(const ValueKey('employee-payment-save')));
    await _settle(tester);
    expect(server.savedSplit, ('bank', 5000.0));
  });

  testWidgets('PAY-SPLIT: what he left with the shop is said and paid from, '
      'all or part', (tester) async {
    await _wide(tester);
    final server = _Server()..owed = 2700;
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeSalaryPanel(
              service: server,
              employeeId: 7,
              isAr: true,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('salary-owed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salary-owed-pay')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('salary-owed-amount')),
      '1000',
    );
    await tester.tap(find.byKey(const ValueKey('salary-owed-account')));
    await _settle(tester);
    await tester.tap(find.text('الصندوق').last);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('salary-owed-confirm')));
    await _settle(tester);
    expect(server.paidOwed, (1000.0, 2));
    expect(
      find.byKey(const ValueKey('salary-owed')),
      findsOneWidget,
      reason: '1,700 still owed',
    );
  });

  testWidgets('what he left is taken against his advance, no account, his '
      'consent above the cap', (tester) async {
    await _wide(tester);
    final server = _Server()
      ..owed = 2700
      ..advanceFree = 800;
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeSalaryPanel(
              service: server,
              employeeId: 7,
              isAr: true,
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('salary-owed-pay')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('salary-owed-amount')),
      '0',
    );
    await tester.enterText(
      find.byKey(const ValueKey('salary-owed-advance')),
      '900',
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('salary-owed-over')),
      findsOneWidget,
      reason: 'over the 800 unplanned',
    );
    FilledButton confirm() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('salary-owed-confirm')),
    );
    expect(confirm().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('salary-owed-advance')),
      '800',
    );
    await _settle(tester);
    expect(
      confirm().onPressed,
      isNull,
      reason: 'over the 750 cap: his consent',
    );
    await tester.tap(find.byKey(const ValueKey('salary-owed-consent')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('salary-owed-confirm')));
    await _settle(tester);
    expect(server.paidOwed, (0.0, null), reason: 'no money leaves');
    expect(server.tookAdvance, (800.0, true));
  });
}
