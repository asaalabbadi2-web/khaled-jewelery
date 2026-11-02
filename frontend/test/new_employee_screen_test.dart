import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/employee_model.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/employee_page.dart';
import 'package:frontend/screens/new_employee_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// HR-UX ط3 (the owner, 2 Nov 2026, «اعتمد»): a new employee in three steps
/// -- his data (he is saved), his salary from his hire date, how he is paid
/// -- then his page; beside them what his file says he still lacks.
class _Api extends ApiService {
  Map<String, dynamic>? created;

  @override
  Future<EmployeeModel> createEmployee(Map<String, dynamic> payload) async {
    created = payload;
    return EmployeeModel.fromJson({'id': 21, 'name': payload['name']});
  }
}

class _Server extends PayrollService {
  _Server() : super(ApiService());

  Map<String, Object>? structure;
  String? method;

  @override
  Future<Map<String, dynamic>> employeeFile(int employeeId) async => {
    'employee': {
      'id': 21,
      'name': 'سالم',
      'hire_date': '2026-10-20',
      'is_active': true,
    },
    'missing': <dynamic>[],
    'completeness': {'done': 3, 'of': 6},
    'salary': {
      'structure': structure == null ? null : {'gross': 6000.0},
      'payment_method': method,
    },
    'users': <dynamic>[],
  };

  @override
  Future<SalaryStructures> structures(int employeeId) async =>
      SalaryStructures.fromJson({
        'structures': <dynamic>[],
        'suggested_from': '2026-10-20',
      });

  @override
  Future<Map<String, double>> suggest(double gross) async => {
    'basic': 4444.44,
    'housing': 1111.11,
    'transport': 444.45,
    'other_allowances': 0.0,
  };

  @override
  Future<void> addStructure(
    int employeeId, {
    required String effectiveFrom,
    required double basic,
    required double housing,
    required double transport,
    required double otherAllowances,
  }) async => structure = {'from': effectiveFrom, 'basic': basic};

  @override
  Future<Map<String, dynamic>> payment(int employeeId) async => {
    'payment_method': method,
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
  }) async => this.method = method;

  @override
  Future<List<Map<String, dynamic>>> schemes() async => const [];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('his data, his salary from his hire date, his payment, then '
      'his page', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: NewEmployeeScreen(api: api, service: server),
      ),
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('new-employee-create')));
    await _settle(tester);
    expect(find.text('الاسم مطلوب'), findsOneWidget);
    expect(api.created, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('new-employee-name')),
      'سالم',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('new-employee-hire-date')),
        matching: find.byType(TextField),
      ),
      '2026-10-20',
    );
    await tester.tap(find.byKey(const ValueKey('new-employee-own-cash-safe')));
    await tester.tap(find.byKey(const ValueKey('new-employee-create')));
    await _settle(tester);
    expect(api.created, {
      'name': 'سالم',
      'hire_date': '2026-10-20',
      'auto_create_cash_safe_box': true,
      'auto_create_gold_safe_box': false,
    }, reason: 'no salary, no leaving date: ADR-078');

    // his salary: the change form open, from his hire date
    expect(find.byKey(const ValueKey('salary-change-form')), findsOneWidget);
    final from = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('structure-from')),
        matching: find.byType(TextField),
      ),
    );
    expect(from.controller!.text, '2026-10-20');
    await tester.enterText(
      find.byKey(const ValueKey('structure-gross')),
      '6000',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('structure-save')));
    await _settle(tester);
    expect(server.structure, {'from': '2026-10-20', 'basic': 4444.44});

    // his payment, then his page
    expect(find.byKey(const ValueKey('salary-payment')), findsOneWidget);
    await tester.tap(find.text('نقد'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('employee-payment-save')));
    await _settle(tester);
    expect(server.method, 'cash');
    expect(
      find.byIcon(Icons.check_circle),
      findsNWidgets(4),
      reason: 'ready for the run',
    );
    await tester.tap(find.byKey(const ValueKey('new-employee-next')));
    await _settle(tester);
    expect(find.byType(EmployeePage), findsOneWidget);
  });

  testWidgets('at a phone\'s width nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: NewEmployeeScreen(api: _Api(), service: _Server()),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });
}
