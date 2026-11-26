// «الأصناف والقطع» in the center (settings spec v2, phase 7, batch 6): the
// coding of the stock on hand is one switch the server keeps as its day
// (coding_on is coding_from, routes/system.py _VERSION_COLUMN) -- on while a
// day is set, said since when, saved from the bar at the day's version; the
// section's screens are linked; nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/display_date.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  _Api({String? codingFrom}) : settings = {'coding_from': codingFrom};

  final saved = <(Map<String, dynamic>, Map<String, int>, String?)>[];
  Object? fail;
  final Map<String, dynamic> settings;

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'coding_from': 11};

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    final f = fail;
    if (f != null) {
      fail = null;
      throw f;
    }
    settings['coding_from'] = changes['coding_on'] == true ? '2026-11-26' : null;
    return {'settings': Map.of(settings), 'versions': {'coding_from': 12}, 'written': ['coding_on']};
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

  Future<_Api> open(WidgetTester tester, _Api api, {Size size = const Size(1000, 1400), bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(section: SettingsSection.itemsPieces, api: api, opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  bool on(WidgetTester tester) => tester.widget<Switch>(find.byKey(const Key('settings-field-coding_on'))).value;

  String explained(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('settings-explain-coding_on'))).data!;

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section fits and reads', (tester) async {
        await open(tester, _Api(codingFrom: '2026-11-19'), size: size, dark: dark);
        await tester.tap(find.byKey(const Key('settings-field-coding_on')));
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

  testWidgets('a day set is on, said since when', (tester) async {
    await open(tester, _Api(codingFrom: '2026-11-19'));
    expect(on(tester), isTrue);
    expect(explained(tester), startsWith('مفتوح منذ ${displayDate('2026-11-19')}:'));
  });

  testWidgets('no day is off; turned on, saved at the day\'s version, said since today', (tester) async {
    final api = await open(tester, _Api());
    expect(on(tester), isFalse);
    expect(explained(tester), startsWith('عند التفعيل يُفتح'));
    await tester.tap(find.byKey(const Key('settings-field-coding_on')));
    await tester.pumpAndSettle();
    expect(explained(tester), startsWith('عند التفعيل يُفتح'), reason: 'not open until saved');
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    final (changes, versions, reason) = api.saved.single;
    expect(changes, {'coding_on': true});
    expect(versions, {'coding_on': 11}, reason: "coding_on's version is coding_from's");
    expect(reason, isNull, reason: 'level 2');
    expect(explained(tester), startsWith('مفتوح منذ ${displayDate('2026-11-26')}:'));
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
  });

  testWidgets('another user opening it since is a conflict read as on', (tester) async {
    final api = await open(tester, _Api());
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض', details: {
      'conflicts': [
        {'key': 'coding_on', 'current': '2026-11-25', 'yours': true, 'current_version': 14, 'changed_by': 'saleh'},
      ],
    });
    await tester.tap(find.byKey(const Key('settings-field-coding_on')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-take-theirs-coding_on')));
    await tester.pumpAndSettle();
    expect(on(tester), isTrue, reason: 'a day is on');
    expect(find.byKey(const Key('settings-save-bar')), findsNothing, reason: 'theirs is what was wanted');
  });

  testWidgets("the section's screens are linked", (tester) async {
    await open(tester, _Api());
    for (final id in ['categories', 'item_sections', 'size_systems', 'label_printers']) {
      expect(find.byKey(Key('settings-entry-$id')), findsOneWidget, reason: id);
    }
  });
}
