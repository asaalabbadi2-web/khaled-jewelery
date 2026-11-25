// The settings registry is the one map of every setting (settings spec v2 §5;
// the owner, 25 Nov 2026 «انتقل»). Its guard: every key a settings screen
// saves -- to the server or on this device -- is in it; its levels are the
// server's (backend/services/settings_policy.py); a level-3 setting says what
// it does and how far it can be undone; every screen it names opens. And its
// search finds a setting the way the shop says it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  test('every key the settings screen saves to the server is in the registry', () {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    final save = s.substring(s.indexOf('Future<void> _saveSettings()'), s.indexOf('updateSettings(payload)'));
    final keys = RegExp(r"'([a-z_0-9]+)':").allMatches(save).map((m) => m.group(1)!).toSet();
    for (final m in RegExp(r'updateSettings\(\{(.*?)\}\)', dotAll: true).allMatches(s)) {
      keys.addAll(RegExp(r"'([a-z_0-9]+)':").allMatches(m.group(1)!).map((x) => x.group(1)!));
    }
    // Sent with the auto-update switch, always 'interval': not a setting of its own.
    keys.remove('gold_price_auto_update_mode');
    expect(keys, isNotEmpty);
    expect(keys.where((k) => !byKey.containsKey(k)).toList(), isEmpty, reason: 'a saved key no one can find');
  });

  // A key moved into the center is the center's alone: the old screen neither
  // holds nor sends it -- its stale value would write over the center's save.
  test('a moved key is edited in the center and no longer sent by the old screen', () {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    final save = s.substring(s.indexOf('Future<void> _saveSettings()'), s.indexOf('updateSettings(payload)'));
    for (final section in movedSections) {
      for (final e in entriesOf(section).where((e) => e.kind == SettingKind.setting)) {
        expect(editors.containsKey(e.key), isTrue, reason: '${e.key}: moved without its editor');
        expect(save.contains("'${e.key}'"), isFalse, reason: '${e.key}: the old screen still sends it');
        expect(e.legacyTab, isNull, reason: '${e.key}: still pointed at the old tab');
      }
    }
  });

  test("every key saved on this device is in the registry, as this device's", () {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    final device = RegExp(r"static const String _\w+Key = '([^']+)';").allMatches(s).map((m) => m.group(1)!).toSet()
      ..add('ui_show_gold_price_ticker_on_login_v1')
      ..add('invoice_ui_settings_v1.global.paper_size');
    for (final k in device) {
      expect(byKey[k], isNotNull, reason: k);
      expect(byKey[k]!.scope, SettingScope.device, reason: k);
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
      expect(e.legacyTab != null || e.screen != null || movedSections.contains(e.section), isTrue, reason: e.id);
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
