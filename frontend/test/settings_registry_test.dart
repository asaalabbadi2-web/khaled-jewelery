// The settings registry is the one map of every setting (settings spec v2 §5;
// the owner, 25 Nov 2026 «انتقل»). Its guard: every key a settings screen
// saves -- to the server or on this device -- is in it; its levels are the
// server's (backend/services/settings_policy.py); a level-3 setting says what
// it does and how far it can be undone; every screen it names opens. And its
// search finds a setting the way the shop says it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/settings/device_section_editor.dart';
import 'package:frontend/settings/settings_editors.dart';
import 'package:frontend/settings/settings_opener.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/settings/settings_search.dart';
import 'package:frontend/utils/arabic_search.dart';

String _src(String p) => File(p).readAsStringSync();

Set<String> _pySet(String src, String name) {
  final m = RegExp('$name = frozenset\\(\\{(.*?)\\}\\)', dotAll: true).firstMatch(src)!;
  return RegExp(r"'([a-z_0-9]+)'").allMatches(m.group(1)!).map((x) => x.group(1)!).toSet();
}

void main() {
  final byKey = {for (final e in settingsRegistry) if (e.key != null) e.key!: e};

  // What the old screen still saves: the keys held back, and nothing else --
  // a moved key sent from it would write a stale value over the center's.
  Set<String> oldScreenSends() {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    return {
      for (final m in RegExp(r'updateSettings\(\{(.*?)\}\)', dotAll: true).allMatches(s))
        ...RegExp(r"'([a-z_0-9]+)':").allMatches(m.group(1)!).map((x) => x.group(1)!),
    };
  }

  test('the old screen saves the held-back settings, and only them', () {
    expect(oldScreenSends(), heldBack.keys.toSet());
  });

  test('a moved key is edited in the center', () {
    for (final section in movedSections) {
      for (final e in entriesOf(section).where((e) => e.kind == SettingKind.setting)) {
        expect(editors.containsKey(e.key), isTrue, reason: '${e.key}: moved without its editor');
        if (!heldBack.containsKey(e.key)) expect(e.screen, isNull, reason: '${e.key}: set elsewhere too');
      }
    }
  });

  // A setting held back until a decision (D2) is only shown in the center: it
  // is set where it was, on the old screen's page.
  test('a held-back setting is set on its page, and only there', () {
    expect(heldBack.keys, ['voucher_auto_post'], reason: 'a new held-back setting is a decision: name it here');
    for (final key in heldBack.keys) {
      final e = byKey[key]!;
      expect(movedSections, contains(e.section), reason: key);
      expect(e.screen, 'held_settings', reason: '$key: no place left to set it');
      expect(settingsScreens.containsKey(e.screen), isTrue);
    }
  });

  test("every key saved on this device is in the registry, as this device's, edited in the center alone", () {
    final old = _src('lib/screens/settings_screen_enhanced.dart');
    for (final k in deviceSettings.keys) {
      expect(byKey[k], isNotNull, reason: k);
      expect(byKey[k]!.scope, SettingScope.device, reason: k);
      expect(byKey[k]!.section, SettingsSection.thisDevice, reason: k);
      expect(old.contains("'$k'"), isFalse, reason: '$k: the old screen still holds it');
    }
    for (final e in settingsRegistry.where((e) => e.kind == SettingKind.setting && e.scope == SettingScope.device)) {
      expect(deviceSettings.containsKey(e.key), isTrue, reason: '${e.key}: a device setting with no editor');
    }
    expect(old.contains('SharedPreferences'), isFalse, reason: 'the old screen keeps nothing on the device');
  });

  // The owner, 26 Nov 2026: what nothing reads is not shown.
  test('the printer settings no print read are gone', () {
    for (final k in ['printer_auto_connect_v1', 'printer_show_preview_v1', 'printer_auto_cut_v1', 'printer_preferred_name_v1']) {
      expect(byKey[k], isNull, reason: k);
    }
  });

  test("a company setting's level is the server's", () {
    final py = _src('../backend/services/settings_policy.py');
    final l3 = _pySet(py, 'LEVEL_3'), l2 = _pySet(py, 'LEVEL_2');
    for (final e in settingsRegistry.where((e) => e.key != null && e.scope == SettingScope.company)) {
      final server = l3.contains(e.key) ? 3 : l2.contains(e.key) ? 2 : 1;
      expect(e.level, server, reason: e.key);
    }
  });

  test('a level-3 setting says what it does and how far it is undone', () {
    for (final e in settingsRegistry.where((e) => e.level == 3)) {
      expect(e.effect, isNotNull, reason: e.id);
      expect(e.revertRule, isNotNull, reason: e.id);
    }
  });

  test('every entry has a place, ids are one each, every section has its entries, every screen opens', () {
    final ids = settingsRegistry.map((e) => e.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final s in SettingsSection.values) {
      expect(entriesOf(s), isNotEmpty, reason: s.name);
    }
    for (final e in settingsRegistry) {
      final edited = movedSections.contains(e.section) || (e.scope == SettingScope.device && deviceSettings.containsKey(e.key));
      expect(e.screen != null || edited, isTrue, reason: e.id);
      if (e.kind == SettingKind.setting) expect(e.key, isNotNull, reason: e.id);
      if (e.screen != null) expect(settingsScreens.containsKey(e.screen), isTrue, reason: e.screen);
    }
  });

  group('search', () {
    List<String> ids(String q) => searchSettings(q).map((h) => h.entry.id).toList();

    test('Arabic as typed: hamza, ta marbuta, Arabic-Indic digits', () {
      expect(normalizeForSearch('آجِل'), 'اجل');
      expect(normalizeForSearch('الضريبة'), 'الضريبه');
      expect(normalizeForSearch('٨٠'), '80');
      expect(ids('اجل').first, 'allow_partial_invoice_payments');
    });

    test('the shop\'s words find the setting', () {
      expect(ids('حراري'), containsAll(['invoice_paper', 'voucher_paper']));
      expect(ids('80'), containsAll(['invoice_paper', 'voucher_paper']));
      expect(ids('A4'), containsAll(['invoice_paper', 'voucher_paper']));
      expect(ids('آجل').first, 'allow_partial_invoice_payments');
      expect(ids('VAT'), containsAll(['tax_enabled', 'sales_vat_enabled', 'tax_rate']));
      expect(ids('الديوان'), containsAll(['office_main_fees_usd', 'office_custom_fees_usd']));
      expect(ids('المكافئ').first, 'main_karat');
    });

    test('the name first, settings before screens, alike settings apart', () {
      expect(ids('العيار الرئيسي').first, 'main_karat');
      final hits = searchSettings('ورق');
      expect(hits.map((h) => h.entry.id).take(2).toSet(), {'invoice_paper', 'voucher_paper'});
      final kinds = searchSettings('الضريبة').map((h) => h.entry.kind).toList();
      expect(kinds, orderedEquals([...kinds]..sort((a, b) => a.index.compareTo(b.index))));
      expect(searchSettings('حراري').firstWhere((h) => h.entry.id == 'invoice_paper').matchedBy, 'حراري');
    });

    test('nothing is nothing', () {
      expect(searchSettings('  '), isEmpty);
      expect(searchSettings('زززز'), isEmpty);
    });
  });
}
