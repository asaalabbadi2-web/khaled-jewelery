import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/my_goal_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

/// «هدفي» (bonus study م3): the signed-in employee's goal as the server says
/// it -- the value so far, the rule's target, what the rule pays so far, how
/// far the next tier is -- one number, the one that will be paid. The card
/// computes none of it.
class _Api extends ApiService {
  _Api(this.answer) : super(baseUrl: 'http://test');
  final Future<List<Map<String, dynamic>>> Function() answer;

  @override
  Future<List<Map<String, dynamic>>> getMyGoalProgress() => answer();
}

Map<String, dynamic> _goal({int value = 1200, Map<String, dynamic>? tier, Map<String, dynamic>? next,
    double? toNext = 300, bool reached = true, double amount = 3000}) => {
  'period': 'monthly', 'period_label': 'الشهري', 'metric': 'points', 'unit': 'نقطة', 'value': value,
  'target': 1000.0, 'progress': value / 1000, 'reached': reached, 'amount_so_far': amount,
  'rule': {'id': 1, 'name': 'الهدف الشهري'},
  'tier': tier ?? (reached ? {'from': 1000, 'per_unit': 2.5} : null),
  'next_tier': next ?? {'from': 1500, 'per_unit': 3.0}, 'to_next': toNext,
};

Future<void> _pump(WidgetTester tester, ApiService api,
    {ThemeData? theme, Size size = const Size(900, 900), bool framed = true}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(
      theme: theme ?? LightTheme.theme,
      home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: MyGoalCard(api: api, framed: framed))),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('it says the value, the target, what is paid so far and the next tier', (tester) async {
    await _pump(tester, _Api(() async => [_goal()]));
    expect(find.text('هدفي الشهري'), findsOneWidget);
    expect(find.textContaining('1,200'), findsWidgets);
    expect(find.textContaining('1,000'), findsWidgets);
    expect(find.textContaining('3,000.00'), findsOneWidget);
    expect(find.text('ينقصك 300 نقطة لشريحة 1,500 (3 لكل نقطة)'), findsOneWidget);
  });

  testWidgets('below the first tier it says how far the goal is', (tester) async {
    await _pump(tester, _Api(() async => [
      _goal(value: 700, reached: false, amount: 0, next: {'from': 1000, 'per_unit': 2.5}),
    ]));
    expect(find.text('ينقصك 300 نقطة لبلوغ هدفك'), findsOneWidget);
  });

  testWidgets('no goal, no card', (tester) async {
    await _pump(tester, _Api(() async => []));
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('a failure says so and can be retried', (tester) async {
    var calls = 0;
    await _pump(tester, _Api(() async {
      calls++;
      if (calls == 1) throw ApiException.text('الخادم مشغول');
      return [_goal()];
    }));
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('هدفي الشهري'), findsOneWidget);
  });

  for (final (name, size) in [('desktop', const Size(900, 900)), ('phone', const Size(380, 800))]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await _pump(tester, _Api(() async => [_goal()]), theme: DarkTheme.theme, size: size);
      expect(tester.takeException(), isNull);
      expectNoTextVanishesOnDark(tester);
    });
  }

  testWidgets('each goal is a ring with its percent, not another linear bar', (tester) async {
    await _pump(tester, _Api(() async => [_goal(value: 800, reached: false, toNext: 200, amount: 0)]));
    final ring = find.byKey(const Key('my-goal-ring'));
    expect(ring, findsOneWidget);
    expect(find.descendant(of: ring, matching: find.text('80%')), findsOneWidget);
    expect(find.descendant(of: ring, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('inside the race card it is a strip, no card of its own', (tester) async {
    await _pump(tester, _Api(() async => [_goal()]), framed: false);
    expect(find.text('هدفي الشهري'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });
}
