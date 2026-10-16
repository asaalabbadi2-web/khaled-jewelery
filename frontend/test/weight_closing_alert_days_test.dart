// «تنبيه التسكير» في إعدادات التسكير (ADR-048): الأيام التي تنبّه بعدها بطاقة
// «التسكير الآن» سياسةٌ يضعها المالك -- تُقرأ من الخادم وتُرسل إليه، وما ليس
// عددًا صحيحًا من 1 إلى 365 لا يُحفظ.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/weight_closing_settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsProvider {
  final List<Map<String, dynamic>> saved = [];
  Map<String, dynamic> server = {'enabled': true, 'position_oldest_alert_days': 10};

  @override
  Future<Map<String, dynamic>> fetchWeightClosingSettings() async => Map.of(server);

  @override
  Future<Map<String, dynamic>> updateWeightClosingSettingsPayload(Map<String, dynamic> payload) async {
    saved.add(payload);
    server = {...server, ...payload};
    return Map.of(server);
  }
}

Future<_Settings> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = _Settings();
  await tester.pumpWidget(ChangeNotifierProvider<SettingsProvider>.value(
    value: settings,
    child: const MaterialApp(home: WeightClosingSettingsScreen()),
  ));
  await tester.pumpAndSettle();
  return settings;
}

String _days(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('wc-alert-days'))).controller!.text;

void main() {
  testWidgets('the days come from the server and go back to it', (tester) async {
    final settings = await _pump(tester);
    expect(_days(tester), '10');
    await tester.enterText(find.byKey(const ValueKey('wc-alert-days')), '5');
    await tester.tap(find.text('حفظ الإعدادات'));
    await tester.pumpAndSettle();
    expect(settings.saved.single['position_oldest_alert_days'], 5);
  });

  testWidgets('not a whole number of days from 1 to 365: nothing is saved, and it says why', (tester) async {
    final settings = await _pump(tester);
    for (final bad in ['0', 'سبعة', '400']) {
      await tester.enterText(find.byKey(const ValueKey('wc-alert-days')), bad);
      await tester.tap(find.text('حفظ الإعدادات'));
      await tester.pumpAndSettle();
      expect(find.text('أيام تنبيه التسكير عدد صحيح من 1 إلى 365'), findsWidgets, reason: bad);
    }
    expect(settings.saved, isEmpty);
  });
}
