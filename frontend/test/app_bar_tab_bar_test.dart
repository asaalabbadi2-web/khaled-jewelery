// Tabs under an app bar take the bar's text colour (AppBarTabBar). A plain
// TabBar there painted its chosen tab in the scheme's primary -- gold on the
// gold bar, the name gone («إعدادات النظام», «مركز التدقيق», 14 Oct 2026).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_bar_tab_bar.dart';

// Screens whose app bar paints its own background: their tabs follow that
// background, each to be walked in both themes before it moves to AppBarTabBar
// (recovery roadmap, APPBAR-TABS). A new plain `bottom: TabBar(` fails here.
const _customBars = {
  'lib/screens/accounting_mapping_screen_enhanced.dart',
  'lib/screens/melting_renewal_screen.dart',
  'lib/screens/posting_management_screen.dart',
  'lib/screens/sales_race_management_screen.dart',
  'lib/screens/user_profile_screen.dart',
};

void main() {
  for (final entry in {'light': LightTheme.theme, 'dark': DarkTheme.theme}.entries) {
    testWidgets('the chosen tab is in the bar\'s colour (${entry.key})', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: entry.value,
          home: const DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBarTabBarHost(),
            ),
          ),
        ),
      );
      final label = tester.widget<TabBar>(find.byType(TabBar)).labelColor;
      expect(label, entry.value.appBarTheme.foregroundColor);
      expect(label, isNot(entry.value.appBarTheme.backgroundColor));
    });
  }

  test('no plain TabBar under an app bar', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/_archived/') || _customBars.contains(path)) {
        continue;
      }
      if (RegExp(r'bottom:\s*(const\s+)?TabBar\(').hasMatch(file.readAsStringSync())) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty, reason: 'use AppBarTabBar under an app bar');
    for (final path in _customBars) {
      expect(RegExp(r'bottom:\s*(const\s+)?TabBar\(').hasMatch(File(path).readAsStringSync()), isTrue,
          reason: '$path moved to AppBarTabBar -- remove it from _customBars');
    }
  });
}

class AppBarTabBarHost extends StatelessWidget implements PreferredSizeWidget {
  const AppBarTabBarHost({super.key});

  static const _bar = AppBarTabBar(tabs: [Tab(text: 'أ'), Tab(text: 'ب')]);

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 48);

  @override
  Widget build(BuildContext context) => AppBar(title: const Text('ت'), bottom: _bar);
}
