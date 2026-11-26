import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/payroll_policy_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-5 (the owner, 1 Nov 2026: «ابنِ هيكله ولا تضع أي أرقام»): the
/// payroll's figures are his to enter. A figure not set says so; an empty
/// field is not sent -- it stays unset, never a zero; a percentage is sent as
/// its ratio, the server checking each. D15 (the owner, 26 Nov 2026): a change
/// is a financial setting's -- each figure it moves said before and after, a
/// reason required, sent with it; whoever lacks the permission is told, the
/// save not offered.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  Map<String, dynamic> held = {'housing_ratio': 0.25, 'day_divisor': 30};
  Map<String, dynamic>? sent;
  String? reason;

  @override
  Future<Map<String, dynamic>> policy() async => held;

  @override
  Future<Map<String, dynamic>> savePolicy(Map<String, dynamic> changes, {String? reason}) async {
    sent = changes;
    this.reason = reason;
    held = {...held, ...changes};
    return held;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'the end of service is entered by the owner, an empty figure left unset',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server();
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollPolicyScreen(api: ApiService(), service: server, financialAllowed: true),
        ),
      );
      await _settle(tester);

      expect(
        find.textContaining('غير مضبوط'),
        findsWidgets,
        reason: 'none of the end of service is seeded',
      );
      final housing = tester.widget<TextField>(
        find.byKey(const ValueKey('policy-housing_ratio')),
      );
      expect(
        housing.controller!.text,
        '25',
        reason: 'a ratio shown as its percentage',
      );

      await tester.enterText(
        find.byKey(const ValueKey('policy-eos_first_years')),
        '٥',
      );
      await tester.enterText(
        find.byKey(const ValueKey('policy-eos_first_years_months')),
        '0.5',
      );
      await tester.tap(find.byKey(const ValueKey('policy-unset-day_divisor')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('policy-save')));
      await _settle(tester);
      expect(server.sent, isNull, reason: 'not sent before its confirmation');
      expect(find.text('30 ← غير مضبوط'), findsOneWidget, reason: 'each figure moved, before and after');
      expect(find.text('غير مضبوط ← 5'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('confirm-action'))).onPressed, isNull,
          reason: 'no reason, no save');
      await tester.enterText(find.byKey(const Key('confirm-reason')), 'نظام العمل');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await _settle(tester);
      expect(server.reason, 'نظام العمل');

      expect(
        server.sent,
        {
          'housing_ratio': 0.25,
          'day_divisor': null,
          'eos_first_years': 5.0,
          'eos_first_years_months': 0.5,
        },
        reason:
            'the empty ones are not sent; the one unset is sent null, not 0',
      );
    },
  );

  Future<_Server> open(WidgetTester tester, {required bool allowed}) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: PayrollPolicyScreen(api: ApiService(), service: server, financialAllowed: allowed),
    ));
    await _settle(tester);
    return server;
  }

  testWidgets('without the financial permission it is read, said, and not saved', (tester) async {
    await open(tester, allowed: false);
    expect(find.byKey(const ValueKey('policy-needs-permission')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('policy-save'))).onPressed, isNull);
  });

  testWidgets('nothing changed is nothing to confirm, nothing sent', (tester) async {
    final server = await open(tester, allowed: true);
    await tester.tap(find.byKey(const ValueKey('policy-save')));
    await _settle(tester);
    expect(find.byKey(const Key('confirm-reason')), findsNothing);
    expect(server.sent, isNull);
  });
}
