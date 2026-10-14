import 'package:flutter/material.dart';

/// Tabs under an app bar, in the bar's own text colour (ADR-038).
///
/// A plain TabBar paints its selected tab in the scheme's primary -- gold on
/// the gold bar of the light theme, so the chosen tab's name vanished
/// («إعدادات النظام», «مركز التدقيق», 14 Oct 2026). Tabs in a screen's body keep
/// the plain TabBar; under an app bar, this one (test/app_bar_tab_bar_test.dart
/// refuses a plain TabBar as an app bar's bottom).
class AppBarTabBar extends StatelessWidget implements PreferredSizeWidget {
  const AppBarTabBar({
    super.key,
    required this.tabs,
    this.controller,
    this.isScrollable = false,
  });

  final List<Widget> tabs;
  final TabController? controller;
  final bool isScrollable;

  @override
  Size get preferredSize => TabBar(tabs: tabs, isScrollable: isScrollable).preferredSize;

  @override
  Widget build(BuildContext context) {
    final onBar = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface;
    return TabBar(
      controller: controller,
      isScrollable: isScrollable,
      tabs: tabs,
      labelColor: onBar,
      unselectedLabelColor: onBar.withValues(alpha: 0.7),
      indicatorColor: onBar,
    );
  }
}
