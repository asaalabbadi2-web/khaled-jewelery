import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/bonus_rules_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The live rule «الهدف الشهري», moved to tiers (bonus study م2; the owner:
/// «تُنقل كما هي»), opens in its form as tiers and is saved as it is -- the
/// form had no tiers, and would have sent a bonus type and a value it no
/// longer has.
class _Api extends ApiService {
  _Api() : super(baseUrl: 'http://test');
  Map<String, dynamic>? updated;

  @override
  Future<List<dynamic>> getBonusRules({bool? isActive}) async => [
    {
      'id': 1, 'name': 'الهدف الشهري', 'rule_type': 'tiered', 'bonus_type': 'tiers', 'bonus_value': 2.5,
      'min_bonus': 1000.0, 'max_bonus': null, 'measure': 'points', 'period': 'monthly',
      'tiers': [{'from': 1000.0, 'per_unit': 2.5}], 'target_employee_ids': [16], 'is_active': true,
    },
  ];

  @override
  Future<Map<String, dynamic>> getEmployees({int page = 1, int perPage = 20, String? search,
      String? department, bool? isActive = true, bool showAll = false}) async => {'employees': []};

  @override
  Future<List<dynamic>> getInvoiceTypes() async => [];

  @override
  Future<void> updateBonusRule(int id, Map<String, dynamic> data) async => updated = data;
}

void main() {
  testWidgets('the tiered rule opens as tiers and is saved as it is', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(theme: LightTheme.theme, home: BonusRulesScreen(api: api)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('شرائح · النقاط · شهري · من 1000: 2.5 لكل وحدة'), findsOneWidget);
    await tester.tap(find.text('الهدف الشهري'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tier-measure')), findsOneWidget);
    expect(find.text('نوع المكافأة'), findsNothing, reason: 'a tiered rule has no bonus type');
    await tester.tap(find.byKey(const Key('rule-save')));
    await tester.pumpAndSettle();
    final sent = api.updated!;
    expect(sent['rule_type'], 'tiered');
    expect((sent['measure'], sent['period']), ('points', 'monthly'));
    expect(sent['tiers'], [{'from': 1000.0, 'per_unit': 2.5}]);
    expect(sent.containsKey('bonus_type'), isFalse);
  });
}
