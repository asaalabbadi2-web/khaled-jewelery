// The dashboard's sizes are the theme's (the owner, 15 Nov 2026: «لوحة التحكم ... ما هي مشاكلها»):
// 34 font sizes were written as numbers on the dashboard's screen and kit, outside the type scale
// the tokens rule asks for. None comes back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no font size on the dashboard is a number', () {
    final files = [
      'lib/screens/reports/admin_dashboard_screen.dart',
      'lib/screens/reports/widgets/dashboard_kit.dart',
      'lib/screens/reports/widgets/dashboard_standing_panels.dart',
      'lib/screens/reports/widgets/dashboard_period_panels.dart',
    ];
    final numbered = RegExp(r'fontSize:\s*\d');
    final found = <String>[
      for (final f in files)
        for (final (i, line) in File(f).readAsLinesSync().indexed)
          if (numbered.hasMatch(line)) '$f:${i + 1}: ${line.trim()}',
    ];
    expect(found, isEmpty);
  });
}
