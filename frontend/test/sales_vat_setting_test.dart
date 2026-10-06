import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SALES-VAT-1 (the owner, 7 Oct 2026): sales carry no VAT since 1 May 2026,
/// on purpose -- but it rested on «فاتورة بدون ضريبة», a switch kept on each
/// device (`invoice_ui_settings_v1.<ctx>.disable_vat`). A new device or cleared
/// storage would have charged 15 % again. VAT on sales is now the company's
/// setting, read from the server.
void main() {
  test('the provider reads VAT on sales from the settings', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'sales_vat_enabled': false}),
    });
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    expect(settings.salesVatEnabled, isFalse);
  });

  test('VAT on sales is on until the company says otherwise', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    expect(settings.salesVatEnabled, isTrue);
  });

  // The sales screens neither read nor offer the device switch: a gate on the
  // source, as the raw-color ratchet is.
  for (final path in [
    'lib/screens/sales_invoice_screen_v2.dart',
    'lib/screens/scrap_sales_invoice_screen.dart',
  ]) {
    test('$path takes VAT from the company setting, not the device', () {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('.disableVat')));
      expect(source, isNot(contains("'ui_disable_vat'")));
      expect(source, isNot(contains('supportsVatToggle: true')));
      expect(source, contains('salesVatEnabled'));
    });
  }
}
