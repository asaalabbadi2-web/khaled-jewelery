// The category weight audit on a phone (the owner, 13 Nov 2026: «في الشاشات
// الصغيره اجعل العرض كبطاقات»): each category's balance is a card -- its
// name, its place, its weights; zero or below in the error tone, as the note
// under them says -- not a table slid sideways. An iPad keeps the table.
// Nothing overflows. Made-up figures.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/screens/reports/category_weight_audit_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Api extends ApiService {
  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [];

  @override
  Future<List<Map<String, dynamic>>> getCategoryWeightBalances({
    int? safeBoxId,
    int? categoryId,
    int? karat,
    bool groupByKarat = false,
    String? goldType,
  }) async => [
        {'safe_box_name': 'خزينة العرض', 'category_name': 'خواتم ذهب عيار 21', 'weight_main_karat': 1234.567,
         'weight_grams_signed': 1234.567},
        {'safe_box_name': 'خزينة الكسر بأسم طويل للتحقق', 'category_name': 'كسر 18', 'weight_main_karat': -12.5,
         'weight_grams_signed': -14.583},
      ];

  @override
  Future<List<Map<String, dynamic>>> getCategoryWeightMovements({
    int? safeBoxId,
    int? categoryId,
    int? invoiceId,
    int? karat,
    String? goldType,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 200,
  }) async => [];
}

Future<List<String>> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final errors = <String>[];
  final before = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
  try {
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: CategoryWeightAuditReportScreen(api: _Api(), isArabic: true),
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

  for (final (device, size) in [('iPhone SE', const Size(375, 2000)), ('iPhone', const Size(390, 2000))]) {
    testWidgets('on an $device each balance is a card, and nothing overflows', (tester) async {
      final errors = await _open(tester, size);
      expect(errors, isEmpty);
      expect(find.byType(DataTable), findsNothing);
      final scrap = find.byKey(const ValueKey('cwa-row-1'));
      expect(scrap, findsOneWidget);
      expect(find.descendant(of: scrap, matching: find.text('خزينة الكسر بأسم طويل للتحقق')), findsOneWidget);
      final below = tester.widget<Text>(find.descendant(of: scrap, matching: find.textContaining('-12.5')));
      expect(below.style?.color, Theme.of(tester.element(scrap)).colorScheme.error, reason: 'below zero');
    });
  }

  testWidgets('an iPad keeps the table', (tester) async {
    final errors = await _open(tester, const Size(744, 1500));
    expect(errors, isEmpty);
    expect(find.byType(DataTable), findsOneWidget);
  });
}
