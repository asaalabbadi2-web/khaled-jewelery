// INV-2 (ADR-086, the owner 6 Nov 2026): the closing count, a session per
// location («جلسة لكل موقع»), blind («عدّ أعمى»). The open sheet offers the
// stock locations to count -- not «كل المواقع», not a deposit (ADR-052) --
// and opens nothing until one is chosen. A weight is at two places (the
// scale's, ADR-085). In a location's own session a line is its category,
// not «category — location» over and over. The review says each karat's
// books, counted and difference -- the entry is per (location, karat); it
// said one «صافي الفرق» adding 18k and 21k grams together. The stock screen
// says each open count's progress.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/inventory_models.dart';
import 'package:frontend/screens/inventory_balance_screen.dart';
import 'package:frontend/screens/inventory_count_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/two_places.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _line(
  int id, {
  int? categoryId,
  String? name,
  double karat = 21,
  double? counted,
}) => {
  'id': id,
  'session_id': 7,
  'branch_id': null,
  'safe_box_id': 30,
  'safe_box_name': 'الذهب المعروض',
  'category_id': categoryId,
  'category_name': name,
  'karat': karat,
  'expected_weight': null,
  'expected_ledger_id': null,
  'counted_weight': counted,
  'variance': null,
  'counted_by': null,
  'counted_at': null,
  'notes': null,
};

Map<String, dynamic> _session({
  String status = 'counting',
  List<Map<String, dynamic>>? byKarat,
}) => {
  'id': 7,
  'branch_id': null,
  'safe_box_id': 30,
  'safe_box_name': 'الذهب المعروض',
  'entry_id': null,
  'status': status,
  'lines_total': 2,
  'lines_counted': status == 'counting' ? 1 : 2,
  'session_type': 'opening',
  'blind_count': true,
  'snapshot_ledger_id': null,
  'opened_by': 't',
  'opened_at': '2026-12-31T18:00:00',
  'closed_at': null,
  'approved_by': null,
  'approved_at': null,
  'notes': null,
  'lines': [
    _line(1, categoryId: 28, name: 'بنجرة ذهب 21', counted: 98.5),
    _line(
      2,
      categoryId: 31,
      name: 'طقم ذهب 21',
      counted: status == 'counting' ? null : 0,
    ),
  ],
  'by_karat': byKarat,
};

final _safes = [
  {
    'id': 30,
    'account_id': 1300,
    'name': 'الذهب المعروض',
    'safe_type': 'gold',
    'stock_location': 'showroom',
    'is_active': true,
  },
  {
    'id': 62,
    'account_id': 1331,
    'name': 'ذهب مودع لدى مكتب الديوان',
    'safe_type': 'gold',
    'stock_location': 'deposit',
    'is_active': true,
  },
];

Future<void> _pump(
  WidgetTester tester,
  Widget screen,
  Object Function(http.Request) answer, {
  double width = 1440,
}) async {
  final cairo = FontLoader('Cairo');
  for (final f in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await http.runWithClient(
    () async {
      await tester.pumpWidget(
        MaterialApp(theme: LightTheme.theme, home: screen),
      );
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
    () => MockClient(
      (r) async => http.Response(
        jsonEncode(answer(r)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );
}

void main() {
  test('a weight is at two places', () {
    TextEditingValue type(String text) => twoPlaceGrams.formatEditUpdate(
      const TextEditingValue(text: '4.55'),
      TextEditingValue(text: text),
    );
    expect(type('4.555').text, '4.55');
    expect(type('12.5').text, '12.5');
    expect(type('4.5a').text, '4.55');
  });

  test("in a location's own session a line is its category", () {
    final line = CountLine.fromJson(
      _line(1, categoryId: 28, name: 'بنجرة ذهب 21'),
    );
    expect(countLineLabel(line, withLocation: false), 'بنجرة ذهب 21');
    expect(countLineLabel(line), 'بنجرة ذهب 21 — الذهب المعروض');
  });

  testWidgets(
    'the open sheet: a location to choose, never every one nor a deposit',
    (tester) async {
      await _pump(
        tester,
        const InventoryCountScreen(),
        (r) => r.url.path.endsWith('/safe-boxes') ? _safes : {},
      );
      expect(find.text('جرد كامل'), findsOneWidget);
      final start = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'بدء الجرد'),
      );
      expect(start.onPressed, isNull, reason: 'no location chosen yet');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('كل المواقع'), findsNothing);
      expect(find.text('ذهب مودع لدى مكتب الديوان'), findsNothing);
      expect(find.text('الذهب المعروض'), findsWidgets);
    },
  );

  testWidgets('a closed full count: its review is per karat', (tester) async {
    await _pump(
      tester,
      const InventoryCountScreen(sessionId: 7),
      (r) => _session(
        status: 'closed',
        byKarat: [
          {'karat': 18.0, 'books': 20.0, 'counted': 20.0, 'difference': 0.0},
          {'karat': 21.0, 'books': 100.0, 'counted': 98.5, 'difference': -1.5},
        ],
      ),
    );
    expect(find.text('عيار 21'), findsWidgets);
    expect(find.textContaining('100.000'), findsWidgets);
    expect(find.textContaining('98.500'), findsWidgets);
    expect(find.textContaining('1.500'), findsWidgets);
    expect(
      find.text('الذهب المعروض'),
      findsNothing,
      reason: 'the title says it; the lines do not repeat it',
    );
  });

  testWidgets('the count lays out on a phone', (tester) async {
    await _pump(
      tester,
      const InventoryCountScreen(sessionId: 7),
      (r) => _session(),
      width: 390,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets("the stock screen says an open count's progress", (tester) async {
    await _pump(
      tester,
      const InventoryBalanceScreen(),
      (r) => {
        'grand_total_main': 10.0,
        'violations': 0,
        'all_locations_session': null,
        'generated_at': '2026-12-31T18:00:00',
        'sections': [
          {
            'key': 'stock',
            'label': 'المخزون',
            'counted': true,
            'total_main': 10.0,
            'locations': [
              {
                'safe_box_id': 30,
                'name': 'الذهب المعروض',
                'stock_location': 'showroom',
                'karats': [
                  {'karat': 21, 'grams': 10.0},
                ],
                'total_main': 10.0,
                'negative': false,
                'last_count': null,
                'open_session': {
                  'id': 7,
                  'status': 'counting',
                  'lines_counted': 12,
                  'lines_total': 41,
                  'session_type': 'opening',
                },
                'categories_are_balances': false,
                'categories': [],
              },
            ],
          },
        ],
      },
    );
    expect(find.textContaining('12 / 41'), findsOneWidget);
  });
}
