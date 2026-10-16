import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where `--dart-define=SHOT_DIR=<dir>` asks the screens to be drawn. The
/// pictures are for looking at -- before and after a screen is reworked
/// (ADR-038, ADR-049) -- not kept in the repository and not compared in CI.
const shotDir = String.fromEnvironment('SHOT_DIR');

/// Draws the app as it is now to `<SHOT_DIR>/<name>.png`, run with
/// `--update-goldens`. Without SHOT_DIR it draws nothing and checks nothing.
Future<void> shot(WidgetTester tester, String name) async {
  if (shotDir.isEmpty) return;
  await expectLater(
    find.byType(MaterialApp).first,
    matchesGoldenFile('$shotDir/$name.png'),
  );
}

/// A tablet held upright: the narrowest of the shop's screens (the owner,
/// 16 Oct 2026: «more than one kind of device»).
const tabletSize = Size(820, 1180);

/// Draws the screen as opened, as `<name>_desktop`, then again at
/// [tabletSize] as `<name>_tablet`. What does not fit on the tablet is said
/// on the console (`SHOT <name> tablet: ...`) and is not a failure: the
/// pictures are a survey of the screen as it is.
Future<void> shotWidths(WidgetTester tester, String name) async {
  if (shotDir.isEmpty) return;
  await shot(tester, '${name}_desktop');
  tester.view.physicalSize = tabletSize;
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (
    Object? e = tester.takeException();
    e != null;
    e = tester.takeException()
  ) {
    debugPrint('SHOT $name tablet: ${e.toString().split('\n').first}');
  }
  await shot(tester, '${name}_tablet');
}
