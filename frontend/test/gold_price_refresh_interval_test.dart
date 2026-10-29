// PRICE-LIVE-1 (the owner, 29 Oct 2026): the price is fetched every 15
// seconds, and the screens ask for it as often -- the interval is the
// server's, in seconds.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsProvider> withSettings(Map<String, dynamic> settings) async {
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode(settings)});
    final provider = SettingsProvider();
    await provider.loadSettings(fetchRemote: false);
    return provider;
  }

  test('the screens ask every 15 seconds when the server fetches every 15', () async {
    final s = await withSettings({
      'main_karat': 21,
      'gold_price_auto_update_enabled': true,
      'gold_price_auto_update_mode': 'interval',
      'gold_price_auto_update_interval_seconds': 15,
    });
    expect(s.goldPriceTickerRefreshInterval, const Duration(seconds: 15));
  });

  test('settings from before say minutes: the same interval', () async {
    final s = await withSettings({
      'main_karat': 21,
      'gold_price_auto_update_enabled': true,
      'gold_price_auto_update_mode': 'interval',
      'gold_price_auto_update_interval_minutes': 2,
    });
    expect(s.goldPriceTickerRefreshInterval, const Duration(minutes: 2));
  });
}
