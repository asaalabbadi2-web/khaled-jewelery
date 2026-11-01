import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/employee_page.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// HR-UX ر2 (the owner, 1 Nov 2026: «اعتمد»): his page is the whole screen --
/// its head says who he is, his state, his user and how complete his file is;
/// its parts show his file's own sections, one part at a time.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  @override
  Future<Map<String, dynamic>> employeeFile(int employeeId) async => {
    'employee': {
      'id': 16,
      'name': 'مسعد المهري',
      'employee_code': 'EMP-2026-0002',
      'job_title': 'بائع',
      'is_active': true,
    },
    'missing': ['الهوية الوطنية / الإقامة', 'تاريخ التعيين'],
    'completeness': {'done': 4, 'of': 6},
    'users': [
      {'username': 'masad', 'is_active': true},
    ],
    'salary': {'structure': null},
    'payroll': <dynamic>[],
    'advances': {'account_balance': 12880.0, 'plans': <dynamic>[]},
    'bonuses': {'approved_unpaid': 0.0, 'owed_in_books': 0.0},
    'custody': <String, dynamic>{},
    'accounts': <dynamic>[],
    'contract': null,
    'documents': <dynamic>[],
    'leave': {'balances': <dynamic>[], 'recent': <dynamic>[]},
    'termination': null,
  };
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: LightTheme.theme,
      home: EmployeePage(api: ApiService(), employeeId: 16, service: _Server()),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets(
    'its head says who he is and how complete; its parts one at a time',
    (tester) async {
      await _open(tester, const Size(1280, 1100));
      final head = find.byKey(const ValueKey('employee-page-head'));
      expect(
        find.descendant(of: head, matching: find.textContaining('مسعد المهري')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: head, matching: find.textContaining('4/6')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: head, matching: find.textContaining('masad')),
        findsOneWidget,
      );
      expect(
        find.textContaining('12,880.00'),
        findsOneWidget,
        reason: 'overview: his advances',
      );
      expect(find.textContaining('لا عقد مسجّل'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('employee-part-contract')));
      await _settle(tester);
      expect(find.textContaining('لا عقد مسجّل'), findsOneWidget);
      expect(
        find.textContaining('12,880.00'),
        findsNothing,
        reason: 'one part at a time',
      );
    },
  );

  testWidgets('at a phone\'s width its parts are chips and nothing overflows', (
    tester,
  ) async {
    await _open(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.byType(ChoiceChip), findsWidgets);
  });
}
