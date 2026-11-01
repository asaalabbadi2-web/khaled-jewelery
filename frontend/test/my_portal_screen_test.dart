import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/my_portal_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// EMP-PORTAL-1 (the owner, 1 Nov 2026): «بوابتي» -- his payslips, his leave
/// and its request (the manager approves), his advance, his bonuses and goals.
/// The screen names nobody: the server reads him from his session.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  Map<String, dynamic>? asked;
  int? cancelled;

  @override
  Future<Map<String, dynamic>> myPortal() async => {
    'employee': {'name': 'مسعد المهري'},
    'payslips': [
      {
        'id': 7,
        'month': 9,
        'year': 2026,
        'net_salary': 7000.0,
        'status': 'paid',
      },
    ],
    'leave': {
      'balances': [
        {'type': 'السنوية', 'balance': 12.5},
        {'type': 'المرضية', 'balance': null},
      ],
      'mine': [
        {
          'id': 4,
          'type': 'السنوية',
          'start_date': '2026-11-10',
          'end_date': '2026-11-12',
          'status': 'requested',
        },
      ],
      'kinds': [
        {'id': 1, 'name': 'السنوية', 'paid': true},
      ],
    },
    'advance': {
      'balance': 12880.0,
      'plans': [
        {'installment': 1000.0, 'remaining': 11880.0},
      ],
    },
    'bonuses': <dynamic>[],
    'goals': <dynamic>[],
  };

  @override
  Future<void> requestMyLeave(Map<String, dynamic> row) async => asked = row;

  @override
  Future<void> cancelMyLeave(int leaveId) async => cancelled = leaveId;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('his payslips, his leave and its request, his advance', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: MyPortalScreen(api: ApiService(), service: server),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull, reason: 'a phone\'s width');
    expect(find.textContaining('مسعد المهري'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-payslip-print-7')), findsOneWidget);
    expect(find.textContaining('12.50'), findsOneWidget);
    expect(find.textContaining('لا رصيد مضبوط'), findsOneWidget);
    expect(find.textContaining('12,880.00'), findsOneWidget);
    expect(find.textContaining('ينتظر الاعتماد'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('my-leave-cancel-4')));
    await _settle(tester);
    expect(server.cancelled, 4);

    await tester.tap(find.byKey(const ValueKey('my-leave-request')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('my-leave-type')));
    await _settle(tester);
    await tester.tap(find.text('السنوية').last);
    await _settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('my-leave-start')),
        matching: find.byType(TextField),
      ),
      '2026-12-01',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('my-leave-end')),
        matching: find.byType(TextField),
      ),
      '2026-12-03',
    );
    await tester.tap(find.byKey(const ValueKey('my-leave-send')));
    await _settle(tester);
    expect(server.asked, {
      'type_id': 1,
      'start_date': '2026-12-01',
      'end_date': '2026-12-03',
    });
  });
}
