import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_model.dart';
import 'package:frontend/screens/payroll_screen.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-1 (the owner, 1 Nov 2026): the form offered «مدفوع» among its
/// statuses -- fifteen salaries were «paid» so, with no accrual and no voucher
/// -- and let a posted entry's amounts be edited. Paid is the «صرف» button's;
/// an approved entry keeps its amounts, its employee and its month; the year
/// is four digits («202» was saved).
class _Api extends ApiService {
  @override
  Future<Map<String, dynamic>> getEmployees({int page = 1, int perPage = 20, String? search, String? department,
          bool? isActive = true, bool showAll = false}) async =>
      {'employees': <dynamic>[], 'pages': 1};
}

PayrollModel _entry(String status) => PayrollModel.fromJson({
      'id': 7, 'employee_id': 3, 'month': 9, 'year': 2026, 'basic_salary': 7000.0, 'allowances': 0.0,
      'deductions': 0.0, 'net_salary': 7000.0, 'status': status,
    });

Future<void> _open(WidgetTester tester, PayrollModel? entry) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: Scaffold(body: PayrollFormDialog(api: _Api(), isArabic: true, entry: entry)),
  ));
  await tester.pump();
}

bool _enabled(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.descendant(of: find.widgetWithText(TextFormField, label), matching: find.byType(TextField))).enabled ?? true;

List<String?> _statuses(WidgetTester tester) => tester
    .widget<DropdownButton<String>>(find.descendant(
        of: find.byKey(const Key('payroll-status')), matching: find.byType(DropdownButton<String>)))
    .items!
    .map((i) => i.value)
    .toList();

void main() {
  testWidgets('a new entry: its amounts open, and «paid» is not offered', (tester) async {
    await _open(tester, null);
    expect(_enabled(tester, 'الراتب الأساسي'), isTrue);
    expect(_statuses(tester), isNot(contains('paid')));
  });

  testWidgets('an approved entry keeps its amounts and is cancelled, not set back', (tester) async {
    await _open(tester, _entry('approved'));
    for (final label in ['الراتب الأساسي', 'البدلات', 'الخصومات', 'الشهر', 'السنة']) {
      expect(_enabled(tester, label), isFalse, reason: label);
    }
    expect(_statuses(tester), unorderedEquals(['approved', 'cancelled']));
  });

  testWidgets('a paid entry says paid, and its status is not changed', (tester) async {
    await _open(tester, _entry('paid'));
    expect(_statuses(tester), ['paid']);
  });
}
