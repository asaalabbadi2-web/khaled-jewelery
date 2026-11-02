import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/hr_hub_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// HR-UX ر1 (the owner, 1 Nov 2026: «اعتمد»): «الموارد البشرية» is one screen,
/// four tabs. Its indicators, employees and follow-up are the server's -- here
/// the 1 Nov copy's: five active and two stopped, September's 42,000, five
/// with data missing, October's run not drafted.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  @override
  Future<Map<String, dynamic>> hrOverview() async => {
    'kpis': {
      'active': 5,
      'stopped': 2,
      'month_cost': {'month': 9, 'year': 2026, 'net': 42000.0, 'paid': true},
      'expiring': 0,
      'incomplete': 5,
    },
    'employees': [
      {
        'id': 16,
        'name': 'مسعد المهري',
        'employee_code': 'EMP-2026-0002',
        'job_title': 'بائع',
        'is_active': true,
        'gross': null,
        'last_payroll': {
          'month': 9,
          'year': 2026,
          'status': 'paid',
          'net_salary': 7000.0,
        },
        'advance': 12880.0,
        'custody': {
          'gold': {
            'safe': 'عهدة ذهب مسعد المهري',
            'balances': {'21k': 11.8},
          },
        },
        'missing': ['الهوية', 'تاريخ التعيين', 'هيكل الراتب', 'طريقة الصرف'],
        'salary_owed': 0.0,
        'bonuses_owed': 0.0,
      },
      {
        'id': 20,
        'name': 'ابو بشار',
        'employee_code': 'EMP-2026-0006',
        'is_active': false,
        'gross': null,
        'last_payroll': null,
        'advance': 0.0,
        'custody': <String, dynamic>{},
        'missing': <dynamic>[],
        'salary_owed': 0.0,
        'bonuses_owed': 0.0,
      },
    ],
    'followup': [
      {'kind': 'run_missing', 'tone': 'blocked', 'month': 10, 'year': 2026},
      {
        'kind': 'policy_unset',
        'tone': 'warning',
        'keys': ['eos_wage_base'],
      },
      {
        'kind': 'custody',
        'tone': 'info',
        'employees': [
          {'id': 16, 'name': 'مسعد المهري'},
        ],
      },
    ],
  };

  @override
  Future<List<PayrollRunSummary>> listRuns() async => [];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'one screen, four tabs: its employees, payroll, follow-up and settings',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: HrHubScreen(api: ApiService(), service: _Server()),
        ),
      );
      await _settle(tester);

      // الموظفون: the indicators and the active employees
      expect(find.textContaining('42,000.00'), findsOneWidget);
      expect(find.byKey(const ValueKey('hr-employee-16')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hr-employee-20')),
        findsNothing,
        reason: 'the active first',
      );
      expect(find.textContaining('بيانات ناقصة'), findsWidgets);
      expect(find.textContaining('11.800'), findsOneWidget);
      await tester.tap(find.text('الموقوفون'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('hr-employee-20')), findsOneWidget);

      // المتابعة: what needs doing, the urgent first; its count on the tab
      await tester.tap(find.byKey(const ValueKey('hr-tab-followup')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('hr-followup-run_missing')),
        findsOneWidget,
      );
      expect(find.textContaining('أرقام لم تُضبط'), findsOneWidget);

      // from it to الرواتب: the month's run waiting, and the earlier records
      await tester.tap(find.text('إلى الرواتب'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('hr-payroll-month')), findsOneWidget);
      expect(find.textContaining('لم يُنشأ'), findsOneWidget);
      expect(find.byKey(const ValueKey('hr-payroll-legacy')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hr-payroll-new-run')),
        findsOneWidget,
        reason: 'a new run from the tab, not through the runs before',
      );

      // الإعدادات: every setting in one place; the earlier screen gone (HR-UX
      // ط5, the owner, 2 Nov 2026: «اعتمد» -- its repair made safes unasked)
      await tester.tap(find.byKey(const ValueKey('hr-tab-settings')));
      await _settle(tester);
      for (final key in [
        'hr-settings-policy',
        'hr-settings-schemes',
        'hr-settings-leave',
        'hr-settings-documents',
        'hr-settings-attendance',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('hr-settings-legacy')), findsNothing);
    },
  );

  testWidgets('at a phone\'s width it overflows nowhere', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: HrHubScreen(api: ApiService(), service: _Server()),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('hr-employee-16')), findsOneWidget);
  });
}
