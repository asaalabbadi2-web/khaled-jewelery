import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/contribution_schemes_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-2 (the owner, 1 Nov 2026: «هل هي قابلة للتصفير؟»): the schemes'
/// rates are his, from a screen -- a new rate from its day beside the old one,
/// a typo corrected, a scheme stopped; a zero is typed, never an empty taken
/// for it (the server refuses an empty rate).
class _Server extends PayrollService {
  _Server() : super(ApiService());

  final held = <Map<String, dynamic>>[
    {
      'id': 1,
      'name': 'مشترك سعودي',
      'is_active': true,
      'components': [
        {
          'id': 11,
          'code': 'annuities',
          'name': 'المعاشات',
          'base': 'basic_housing',
          'employee_rate': 9.0,
          'employer_rate': 9.0,
          'base_cap': 45000.0,
          'effective_from': '2026-01-01',
        },
      ],
    },
  ];
  Map<String, dynamic>? added;
  Map<String, dynamic>? corrected;
  bool? active;

  @override
  Future<List<Map<String, dynamic>>> allSchemes() async => held;

  @override
  Future<void> addComponent(int schemeId, Map<String, dynamic> row) async =>
      added = row;

  @override
  Future<void> updateComponent(
    int componentId,
    Map<String, dynamic> row,
  ) async => corrected = row;

  @override
  Future<void> setSchemeActive(int schemeId, bool value) async {
    active = value;
    held.first['is_active'] = value;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('a rate from a day, a typo corrected, a scheme stopped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: ContributionSchemesScreen(api: ApiService(), service: server),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('المعاشات'), findsOneWidget);

    // a new rate from its day: a new row, the old one kept
    await tester.tap(find.byKey(const ValueKey('scheme-add-rate-1')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('component-code')),
      'annuities',
    );
    await tester.enterText(
      find.byKey(const ValueKey('component-name')),
      'المعاشات',
    );
    await tester.tap(find.byKey(const ValueKey('component-base')));
    await _settle(tester);
    await tester.tap(find.text('الأساسي والسكن').last);
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('component-employee')),
      '١٠',
    );
    await tester.enterText(
      find.byKey(const ValueKey('component-employer')),
      '0',
    );
    await tester.enterText(
      find.byKey(const ValueKey('component-from')),
      '2027-07-01',
    );
    await tester.tap(find.byKey(const ValueKey('component-save')));
    await _settle(tester);
    expect(server.added, {
      'code': 'annuities',
      'name': 'المعاشات',
      'base': 'basic_housing',
      'employee_rate': '10',
      'employer_rate': '0',
      'base_cap': null,
      'effective_from': '2027-07-01',
    }, reason: 'a zero is typed 0 and sent as it is');

    // a typo corrected in place
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('component-11')),
        matching: find.byIcon(Icons.edit_outlined),
      ),
    );
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('component-employer')),
      '',
    );
    await tester.tap(find.byKey(const ValueKey('component-save')));
    await _settle(tester);
    expect(
      server.corrected?['employer_rate'],
      isNull,
      reason: 'an empty one is sent empty, the server refuses it',
    );

    // stopped
    await tester.tap(find.byKey(const ValueKey('scheme-active-1')));
    await _settle(tester);
    expect(server.active, isFalse);
    expect(find.textContaining('موقوفة'), findsOneWidget);
  });
}
