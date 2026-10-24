import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/bonus_rule_model.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/tiered_rule_editor.dart';

/// A bonus rule is data (bonus study م2): what it measures, over which period,
/// at which tiers -- all the measure at the tier it reached (the owner, 24 Oct
/// 2026: «كل النقاط بسعر شريحتها») -- and before it is saved, what it would
/// have paid in the months gone beside what was paid.
class _Api extends ApiService {
  _Api() : super(baseUrl: 'http://test');
  Map<String, dynamic>? asked;

  @override
  Future<Map<String, dynamic>> previewBonusRule(Map<String, dynamic> rule, {int periods = 6}) async {
    asked = rule;
    return {
      'rows': [
        {'period_start': '2026-08-01', 'employee_id': 16, 'employee': 'مسعد', 'value': 1005, 'tier_from': 1000,
         'amount': 2512.5, 'paid': 2512.5},
        {'period_start': '2026-09-01', 'employee_id': 16, 'employee': 'مسعد', 'value': 800, 'tier_from': null,
         'amount': 0.0, 'paid': 0.0},
      ],
      'total': 2512.5, 'total_paid': 2512.5,
    };
  }
}

Future<TieredTerms?> _pump(WidgetTester tester, {TieredTerms? initial, ApiService? api}) async {
  TieredTerms? last;
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SingleChildScrollView(
          child: TieredRuleEditor(
            initial: initial ?? TieredTerms.blank(),
            api: api ?? _Api(),
            scope: () => const {'target_employee_ids': [16]},
            onChanged: (t) => last = t,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return last;
}

void main() {
  test('a rule\'s terms come from and go to the server\'s shape', () {
    final rule = BonusRuleModel.fromJson({
      'id': 1, 'name': 'الهدف الشهري', 'rule_type': 'tiered', 'bonus_type': 'tiers', 'bonus_value': 2.5,
      'measure': 'points', 'period': 'monthly',
      'tiers': [{'from': 1000.0, 'per_unit': 2.5}],
    });
    final terms = TieredTerms.of(rule);
    expect((terms.measure, terms.period), ('points', 'monthly'));
    expect(terms.toJson()['tiers'], [{'from': 1000.0, 'per_unit': 2.5}]);
  });

  testWidgets('tiers are added, each per unit or a fixed amount', (tester) async {
    TieredTerms? got;
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: TieredRuleEditor(
            initial: TieredTerms.blank(),
            api: _Api(),
            scope: () => const {},
            onChanged: (t) => got = t,
          ),
        ),
      ),
    ));
    await tester.enterText(find.byKey(const Key('tier-from-0')), '1000');
    await tester.enterText(find.byKey(const Key('tier-value-0')), '2.5');
    await tester.tap(find.byKey(const Key('tier-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tier-from-1')), '1500');
    await tester.tap(find.text('مبلغ ثابت').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tier-value-1')), '500');
    await tester.pumpAndSettle();
    expect(got!.toJson()['tiers'], [
      {'from': 1000.0, 'per_unit': 2.5},
      {'from': 1500.0, 'amount': 500.0},
    ]);
    expect(got!.error, isNull);
  });

  testWidgets('a tier that does not start after the one before it is said', (tester) async {
    await _pump(tester, initial: TieredTerms('points', 'monthly', [
      TierDraft(1500, 3.0, perUnit: true),
      TierDraft(1000, 2.5, perUnit: true),
    ]));
    expect(find.text('الشريحة 2 تبدأ بعد التي قبلها'), findsOneWidget);
  });

  testWidgets('the preview says what it would have paid, beside what was paid', (tester) async {
    final api = _Api();
    await _pump(tester, api: api, initial: TieredTerms('points', 'monthly', [TierDraft(1000, 2.5, perUnit: true)]));
    await tester.tap(find.byKey(const Key('tier-preview')));
    await tester.pumpAndSettle();
    expect(api.asked!['tiers'], [{'from': 1000.0, 'per_unit': 2.5}]);
    expect(api.asked!['target_employee_ids'], [16]);
    expect(find.textContaining('2,512.50'), findsWidgets);
    expect(find.text('لم يبلغ شريحة'), findsOneWidget);
  });
}
