import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/screens/customize_quick_actions_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// The quick access customization (ADR-057). Its settings are this device's
/// (SharedPreferences) -- a convenience of the one who uses it.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<QuickActionsProvider> open(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(1200, 1600),
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = QuickActionsProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: const CustomizeQuickActionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  testWidgets('it lists the group\'s actions, each with its switch', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('تخصيص الوصول السريع'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets);
  });

  // ر٢ (ADR-057): the screen reads in the dark theme.
  for (final (name, size) in [
    ('desktop', const Size(1200, 1600)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await open(tester, theme: DarkTheme.theme, size: size);
      expect(tester.takeException(), isNull);
      await shot(tester, 'quick_actions_dark_$name');
      expectNoTextVanishesOnDark(tester);
      expectNoLightSurfaceOnDark(tester);
    });
  }

  // ر٣ (ADR-057): the add sheet's search, as people write.
  testWidgets('the add sheet finds a button as people write its name', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('إضافة زر'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'فاتوره مرتجع');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('فاتورة مرتجع'),
      ),
      findsOneWidget,
    );
  });
}

