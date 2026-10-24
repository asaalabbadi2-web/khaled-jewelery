import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/race_honours_badges.dart';

/// Beside an employee in the race: a crown with the months they led, a target
/// with the periods they reached their goal (bonus study م3هـ). None, no badge.
Future<void> _pump(WidgetTester tester, Map row, {ThemeData? theme}) => tester.pumpWidget(MaterialApp(
      theme: theme ?? LightTheme.theme,
      home: Scaffold(body: Center(child: RaceHonoursBadges.of(row))),
    ));

void main() {
  testWidgets('a crown with the months led and a target with the goals reached, said aloud', (tester) async {
    await _pump(tester, {'crowns': 3, 'goals_reached': 5});
    expect(find.descendant(of: find.byKey(const Key('race-crowns')), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('race-goals')), matching: find.text('5')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('race-goals')), matching: find.byType(CustomPaint)),
        findsWidgets);
    expect(find.bySemanticsLabel('تصدّر السباق 3 أشهر'), findsOneWidget);
    expect(find.bySemanticsLabel('بلغ هدفه 5 مرات'), findsOneWidget);
  });

  testWidgets('none, no badge; one kind alone shows alone', (tester) async {
    await _pump(tester, {'crowns': 0, 'goals_reached': 0});
    expect(find.byType(Tooltip), findsNothing);
    await _pump(tester, {'crowns': 1});
    expect(find.byKey(const Key('race-crowns')), findsOneWidget);
    expect(find.byKey(const Key('race-goals')), findsNothing);
    expect(find.bySemanticsLabel('تصدّر السباق شهرًا'), findsOneWidget);
  });

  for (final (name, theme) in [('light', LightTheme.theme), ('dark', DarkTheme.theme)]) {
    testWidgets('a crown and a target, plain, in one quiet colour with their numbers, in the $name theme',
        (tester) async {
      await _pump(tester, {'crowns': 2, 'goals_reached': 4}, theme: theme);
      final quiet = theme.colorScheme.onSurfaceVariant;
      expect(tester.widget<Text>(find.text('2')).style?.color, quiet);
      expect(tester.widget<Text>(find.text('4')).style?.color, quiet);
      final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((p) => p.painter);
      expect(painters.whereType<RaceCrownPainter>().single.gold, quiet);
      final target = painters.whereType<RaceTargetPainter>().single;
      expect((target.rings, target.arrow), (quiet, quiet));
      expect(find.byType(DecoratedBox), findsNothing, reason: 'no fill behind them');
    });
  }
}
