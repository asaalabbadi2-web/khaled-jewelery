// «المستخدمون والأمان» in the center (settings spec v2, phase 7, batch 7):
// the idle sign-out and its minutes saved from the bar -- the minutes whole,
// from one to a week (10,080), as the old tab bounded them and the server
// clamps them, set only while the sign-out is on; the section's screens are
// linked; nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  final saved = <(Map<String, dynamic>, Map<String, int>, String?)>[];
  final settings = <String, dynamic>{'idle_timeout_enabled': true, 'idle_timeout_minutes': 60};

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'idle_timeout_minutes': 5};

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    settings.addAll(changes);
    return {'settings': Map.of(settings), 'versions': {for (final k in changes.keys) k: 99}};
  }
}

const _sizes = {'wide': Size(1400, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Api> open(WidgetTester tester, {Size size = const Size(1000, 1400), bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(section: SettingsSection.usersSecurity, api: api, opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  const minutes = Key('settings-field-idle_timeout_minutes');

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section fits and reads', (tester) async {
        await open(tester, size: size, dark: dark);
        await tester.enterText(find.byKey(minutes), '45');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings-save-bar')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('the minutes are whole, one to a week, and saved from the bar', (tester) async {
    final api = await open(tester);
    expect(find.text('60'), findsOneWidget);
    for (final (typed, said) in [('0', 'بين 1 و10,080'), ('20000', 'بين 1 و10,080'), ('2.5', 'رقم صحيح')]) {
      await tester.enterText(find.byKey(minutes), typed);
      await tester.pumpAndSettle();
      expect(find.text(said), findsOneWidget, reason: typed);
      expect(tester.widget<FilledButton>(find.byKey(const Key('settings-save'))).onPressed, isNull, reason: typed);
    }
    await tester.enterText(find.byKey(minutes), '45');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'idle_timeout_minutes': 45});
    expect(api.saved.single.$2, {'idle_timeout_minutes': 5});
  });

  testWidgets('the sign-out off: no minutes to set', (tester) async {
    final api = await open(tester);
    await tester.tap(find.byKey(const Key('settings-field-idle_timeout_enabled')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(minutes)).enabled, isFalse);
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'idle_timeout_enabled': false});
  });

  testWidgets("the section's screens are linked", (tester) async {
    await open(tester);
    for (final id in ['users', 'sessions', 'audit_log']) {
      expect(find.byKey(Key('settings-entry-$id')), findsOneWidget, reason: id);
    }
  });
}
