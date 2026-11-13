// Shift closing on a phone (the owner, 13 Nov 2026: «في الشاشات الصغيره اجعل
// العرض كبطاقات وليس جداول»): each payment method is a card -- its expected
// amount and its difference, its count under them -- not a table slid
// sideways. An iPad keeps the table. Nothing overflows. Made-up figures.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/shift_closing_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/record_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiService {
  @override
  Future<Map<String, dynamic>> getShiftClosingSummary({String? from, String? to}) async => {
        'from': '2026-11-13T08:00:00',
        'to': '2026-11-13T22:00:00',
        'rows': [
          {'payment_method_id': 1, 'payment_method_name': 'نقداً', 'category': 'cash', 'is_cash': true,
           'expected_amount': 18450.75},
          {'payment_method_id': 2, 'payment_method_name': 'مدى', 'category': 'card', 'is_cash': false,
           'expected_amount': 32100.0},
          {'payment_method_id': 3, 'payment_method_name': 'تحويل بنكي باسم طويل للتحقق', 'category': 'bank',
           'is_cash': false, 'expected_amount': 120000.5},
        ],
      };

  @override
  Future<Map<String, dynamic>> getShiftClosingGoldSummary({String? from, String? to}) async => {'totals': {}};
}

Future<List<String>> _open(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final errors = <String>[];
  final before = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
  try {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ShiftClosingScreen(api: _Api(), isArabic: true),
        ),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  } finally {
    FlutterError.onError = before;
  }
  return errors;
}

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  for (final (device, size) in [('iPhone SE', const Size(375, 667)), ('iPhone', const Size(390, 844))]) {
    testWidgets('on an $device each payment method is a card with its count, and nothing overflows', (tester) async {
      final errors = await _open(tester, size);
      expect(errors, isEmpty);
      expect(find.byType(DataTable), findsNothing);
      final mada = find.byKey(const ValueKey('shift-method-2'));
      expect(mada, findsOneWidget);
      expect(find.descendant(of: mada, matching: find.byType(TextField)), findsOneWidget,
          reason: 'its count is asked on its card');
      expect(find.descendant(of: mada, matching: find.text('المبلغ المتوقع')), findsOneWidget);
      expect(find.byType(RecordCard), findsWidgets);
      // the last, below the fold on a small phone, scrolled to
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump();
      expect(find.byKey(const ValueKey('shift-method-3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an iPad keeps the table', (tester) async {
    final errors = await _open(tester, const Size(744, 1133));
    expect(errors, isEmpty);
    expect(find.byType(DataTable), findsOneWidget);
  });
}
