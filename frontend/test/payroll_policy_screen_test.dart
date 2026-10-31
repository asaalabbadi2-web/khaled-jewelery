import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/payroll_policy_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-5 (the owner, 1 Nov 2026: «ابنِ هيكله ولا تضع أي أرقام»): the
/// payroll's figures are his to enter. A figure not set says so; an empty
/// field is not sent -- it stays unset, never a zero; a percentage is sent as
/// its ratio, the server checking each.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  Map<String, dynamic> held = {'housing_ratio': 0.25, 'day_divisor': 30};
  Map<String, dynamic>? sent;

  @override
  Future<Map<String, dynamic>> policy() async => held;

  @override
  Future<Map<String, dynamic>> savePolicy(Map<String, dynamic> changes) async {
    sent = changes;
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
          home: PayrollPolicyScreen(api: ApiService(), service: server),
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
}
