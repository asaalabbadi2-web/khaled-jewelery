import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/employee_file_view.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// EMP-2 (the owner, 1 Nov 2026): an employee's file in one place -- what is
/// missing said first, then each part as the server says it: here مسعد on
/// the 1 Nov copy, his bonus approved while the books owe nothing, his gold
/// in custody.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  @override
  Future<Map<String, dynamic>> employeeFile(int employeeId) async => {
    'missing': ['الهوية الوطنية / الإقامة', 'تاريخ التعيين'],
    'users': [
      {'username': 'masad', 'role': 'employee', 'is_active': true},
    ],
    'salary': {'structure': null, 'scheme': null, 'payment_method': null},
    'payroll': [
      {'month': 9, 'year': 2026, 'net_salary': 7000.0, 'status': 'paid'},
    ],
    'advances': {'account_balance': 12880.0, 'plans': <dynamic>[]},
    'bonuses': {'approved_unpaid': 2512.5, 'owed_in_books': 0.0},
    'custody': {
      'gold': {
        'safe': 'عهدة ذهب مسعد المهري',
        'balances': {'21k': 11.8},
      },
    },
    'accounts': [
      {'role': 'personal', 'name': 'ح/حساب الموظف', 'cash': 12880.0},
    ],
  };
}

void main() {
  testWidgets('his file says what is missing, then each part', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: EmployeeFileView(
            api: ApiService(),
            employeeId: 16,
            service: _Server(),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('employee-file-missing')), findsOneWidget);
    expect(find.textContaining('تاريخ التعيين'), findsOneWidget);
    expect(find.textContaining('لا هيكل راتب'), findsOneWidget);
    expect(find.textContaining('عهدة ذهب مسعد المهري'), findsOneWidget);
    expect(find.textContaining('11.800'), findsOneWidget);
    expect(find.textContaining('2,512.50'), findsOneWidget);
    expect(find.text('masad'), findsOneWidget);
  });
}
