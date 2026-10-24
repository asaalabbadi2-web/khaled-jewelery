import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/goal_ring_tile.dart';
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
    {ThemeData? theme, Size size = const Size(900, 900), bool framed = true, Widget? alongside,
    Set<String>? periods}) async {
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
      home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: MyGoalCard(api: api, framed: framed, alongside: alongside, periods: periods))),
    ),
  ));
  await tester.pumpAndSettle();
}

const team = {'period': 'monthly', 'period_label': 'الشهري', 'unit': 'نقطة', 'value': 4200, 'target': 5000,
              'progress': 0.84, 'reached': false, 'employees': 5};

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

  testWidgets('a goal alone is a line, not a ring', (tester) async {
    await _pump(tester, _Api(() async => [_goal(value: 800, reached: false, toNext: 200, amount: 0)]));
    expect(find.byKey(const Key('goal-line')), findsOneWidget);
    expect(find.byKey(const Key('goal-ring')), findsNothing);
    expect(find.text('80%'), findsOneWidget);
  });

  testWidgets('beside another, each is a ring on its own plain ground', (tester) async {
    await _pump(tester, _Api(() async => [_goal(value: 800, reached: false, toNext: 200, amount: 0)]),
        framed: false, alongside: TeamGoalTile(goal: team, format: (v) => '$v'));
    expect(find.byKey(const Key('goal-ring')), findsNWidgets(2));
    expect(find.byKey(const Key('goal-ground')), findsNWidgets(2));
    final ring = find.byKey(const Key('goal-ring')).first;
    expect(find.descendant(of: ring, matching: find.text('80%')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('inside the race card it is a strip, no card of its own', (tester) async {
    await _pump(tester, _Api(() async => [_goal()]), framed: false);
    expect(find.text('هدفي الشهري'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });


  for (final (name, size) in [('desktop', const Size(900, 900)), ('phone', const Size(360, 800))]) {
    testWidgets('mine and the team\'s side by side in one row, on a $name', (tester) async {
      await _pump(tester, _Api(() async => [_goal()]), framed: false, size: size,
          alongside: TeamGoalTile(goal: team, format: (v) => '$v'));
      expect(tester.takeException(), isNull);
      final mine = tester.getTopLeft(find.byKey(const Key('my-goal-monthly')));
      final ours = tester.getTopLeft(find.byKey(const Key('team-goal')));
      expect((mine.dy - ours.dy).abs(), lessThan(1), reason: 'one row, not a column');
      expect(find.text('ينقص الفريق 800 نقطة'), findsOneWidget);
    });
  }

  testWidgets('no goal of mine, the team\'s alone', (tester) async {
    await _pump(tester, _Api(() async => []), framed: false, alongside: TeamGoalTile(goal: team, format: (v) => '$v'));
    expect(find.byKey(const Key('team-goal')), findsOneWidget);
  });

  testWidgets('it lives with the card: a new load reloads it, an ended session empties it', (tester) async {
    var calls = 0;
    var ended = false;
    final api = _Api(() async {
      calls++;
      if (ended) throw ApiAuthException('انتهت الجلسة');
      return [_goal()];
    });
    Future<void> show(Object refreshedAt) async {
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: SettingsProvider(),
        child: MaterialApp(
          theme: LightTheme.theme,
          home: Scaffold(body: MyGoalCard(api: api, framed: false, refreshedAt: refreshedAt)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    SharedPreferences.setMockInitialValues({});
    await show(1);
    expect(find.text('هدفي الشهري'), findsOneWidget);
    ended = true;
    await show(2);
    expect(calls, 2, reason: 'reloaded with the card');
    expect(find.text('هدفي الشهري'), findsNothing, reason: 'the session ended, its figures go');
    expect(find.textContaining('تعذّر'), findsNothing);
  });

  testWidgets('it comes in on opening: faded in, filling, its percent counting up', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(body: MyGoalCard(api: _Api(() async => [_goal(value: 800, reached: false)]), framed: false)),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.byKey(const Key('goal-line')), matching: find.byType(Opacity)).first);
    expect(opacity.opacity, lessThan(1), reason: 'it fades in');
    expect(find.text('80%'), findsNothing, reason: 'the percent counts up');
    await tester.pumpAndSettle();
    expect(find.text('80%'), findsOneWidget);
  });

  testWidgets('the card\'s period picks the goals: the week\'s in its week', (tester) async {
    final weekly = _goal()..['period'] = 'weekly'..['period_label'] = 'الأسبوعي';
    await _pump(tester, _Api(() async => [_goal(), weekly]), framed: false, periods: {'weekly'});
    expect(find.text('هدفي الأسبوعي'), findsOneWidget);
    expect(find.text('هدفي الشهري'), findsNothing);
  });

  const week = {'period_label': 'الأسبوعي', 'unit': 'نقطة', 'value': 800, 'target': 1129, 'progress': 0.71,
                'reached': false, 'employees': 5, 'share_of': 'monthly'};

  testWidgets('the week\'s team goal says it is the week\'s share of the month\'s, as a ring', (tester) async {
    final weekly = _goal()..['period'] = 'weekly'..['period_label'] = 'الأسبوعي';
    await _pump(tester, _Api(() async => [weekly]), framed: false, periods: {'weekly'},
        alongside: TeamGoalTile(goal: week, format: (v) => '$v'));
    expect(find.text('هدف الفريق الأسبوعي'), findsOneWidget);
    expect(find.text('حصة الأسبوع من أهداف 5 موظفين'), findsOneWidget);
  });

  testWidgets('alone, as a line, it says how far the team is and drops the share line', (tester) async {
    await _pump(tester, _Api(() async => []), framed: false, alongside: TeamGoalTile(goal: week, format: (v) => '$v'));
    expect(find.byKey(const Key('goal-line')), findsOneWidget);
    expect(find.text('ينقص الفريق 329 نقطة'), findsOneWidget);
    expect(find.text('حصة الأسبوع من أهداف 5 موظفين'), findsNothing);
  });

  testWidgets('a goal alone, as a line, is no taller than a ring', (tester) async {
    await _pump(tester, _Api(() async => [_goal()]), framed: false, size: const Size(900, 900));
    final line = tester.getSize(find.byKey(const Key('goal-line'))).height;
    expect(line, lessThanOrEqualTo(58), reason: 'the ring is 58 high');
    expect(find.textContaining('المكافأة حتى الآن'), findsOneWidget);
    expect(find.textContaining('ينقصك'), findsOneWidget, reason: 'beside it, on the same line');
  });
}
