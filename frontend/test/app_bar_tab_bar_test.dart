// Tabs under an app bar take the bar's text colour (AppBarTabBar). A plain
// TabBar there painted its chosen tab in the scheme's primary -- gold on the
// gold bar, the name gone («إعدادات النظام», «مركز التدقيق», 14 Oct 2026).
// No screen is excepted: the four that painted their own bar were the
// theme's bar or a fixed colour in both themes -- «التجديد والتكسير» lost its
// chosen tab on the light theme's gold (the owner, 23 Oct 2026; ADR-057 ر٥).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_bar_tab_bar.dart';

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
      if (!path.endsWith('.dart') || path.contains('/_archived/')) {
        continue;
      }
      if (RegExp(r'bottom:\s*(const\s+)?TabBar\(').hasMatch(file.readAsStringSync())) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty, reason: 'use AppBarTabBar under an app bar');
  });

  // AppBarTabBar takes the theme's bar text: a bar painting its own
  // background (darkGold in both themes) would put it on a colour it was not
  // chosen for.
  test('a bar with tabs is the theme\'s bar', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/_archived/')) continue;
      final source = file.readAsStringSync();
      for (final bar in RegExp(r'\bAppBar\(').allMatches(source)) {
        final args = _argumentsAt(source, bar.end);
        final bottom = args.indexOf('AppBarTabBar(');
        if (bottom < 0) continue;
        if (RegExp(r'\b(backgroundColor|foregroundColor|flexibleSpace)\s*:')
            .hasMatch(args.substring(0, bottom))) {
          offenders.add(path);
        }
      }
    }
    expect(offenders, isEmpty, reason: 'leave the bar\'s colours to the theme');
  });

  test('what the bar check reads', () {
    const own = "AppBar(title: Text('x'), backgroundColor: c, bottom: AppBarTabBar(tabs: t))";
    const theirs = "AppBar(title: Text('x'), bottom: AppBarTabBar(tabs: t))";
    expect(_argumentsAt(own, 'AppBar('.length), contains('backgroundColor'));
    expect(_argumentsAt(theirs, 'AppBar('.length), isNot(contains('backgroundColor')));
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

/// The source of a call's arguments, from just after its `(` to its `)`.
String _argumentsAt(String source, int start) {
  var depth = 1;
  var i = start;
  while (i < source.length && depth > 0) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') depth--;
    i++;
  }
  return source.substring(start, i - 1);
}
