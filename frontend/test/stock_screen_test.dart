// INV-1 (ADR-086, the owner 6 Nov 2026): the stock screen by «الموقع
// والعيار», the audit «داخل شاشة الأرصدة». Each location a card -- its karats
// and its total from the books, three places at most; its last count, or
// «لم يُجرد بعد»; a session open on it, to resume. Before a location is counted
// its categories are their movement («خرج»), not a negative balance. The
// deposits are a section «لا تُجرد»; a location below zero says so; the
// allocations against their lines (the nightly check) are said on top.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/inventory_balance_screen.dart';
import 'package:frontend/screens/inventory_count_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/shots.dart';

Map<String, dynamic> _location(
  int id,
  String name, {
  String type = 'showroom',
  List<List<num>> karats = const [],
  double total = 0,
  bool negative = false,
  Map<String, dynamic>? lastCount,
  Map<String, dynamic>? openSession,
  bool balances = false,
  List<Map<String, dynamic>> categories = const [],
}) => {
  'safe_box_id': id,
  'name': name,
  'stock_location': type,
  'karats': [
    for (final k in karats) {'karat': k[0], 'grams': k[1]},
  ],
  'total_main': total,
  'negative': negative,
  'last_count': lastCount,
  'open_session': openSession,
  'categories_are_balances': balances,
  'categories': categories,
};

final _answer = {
  'grand_total_main': 23006.401,
  'violations': 2,
  'all_locations_session': null,
  'generated_at': '2026-11-06T12:00:00',
  'sections': [
    {
      'key': 'stock',
      'label': 'المخزون',
      'counted': true,
      'total_main': 21627.806,
      'locations': [
        _location(
          30,
          'الذهب المعروض',
          karats: [
            [18, 11428.99],
            [21, 11725.176],
          ],
          total: 21919.847,
          openSession: {'id': 9, 'status': 'open'},
          categories: [
            {
              'category_id': 28,
              'name': 'بنجرة ذهب 21',
              'karat': 21,
              'grams': -480.59,
            },
          ],
        ),
        _location(
          53,
          'ذهب الكسر مؤقتة',
          type: 'scrap',
          karats: [
            [21, -870.49],
          ],
          total: -446.672,
          negative: true,
        ),
        _location(
          31,
          'ذهب الكسر الرئيسي',
          type: 'scrap',
          karats: [
            [21, 101.909],
          ],
          total: 101.909,
          balances: true,
          lastCount: {
            'session_id': 4,
            'approved_at': '2026-12-31T22:10:00',
            'approved_by': 'المدير',
            'entry_number': 'JE-2026-07001',
          },
          categories: [
            {
              'category_id': 70,
              'name': 'كسر 21',
              'karat': 21,
              'grams': 101.909,
            },
          ],
        ),
      ],
    },
    {
      'key': 'deposit',
      'label': 'ودائع لدى المكاتب — لا تُجرد',
      'counted': false,
      'total_main': 1367.834,
      'locations': [
        _location(
          62,
          'ذهب مودع لدى مكتب الديوان',
          type: 'deposit',
          karats: [
            [24, 849.82],
          ],
          total: 971.223,
        ),
      ],
    },
  ],
};

Future<void> _open(
  WidgetTester tester, {
  double width = 1440,
  ThemeData? theme,
}) async {
  final cairo = FontLoader('Cairo');
  for (final f in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await http.runWithClient(
    () async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: const InventoryBalanceScreen(),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    },
    () => MockClient((request) async {
      final body = request.url.path.endsWith('/inventory/locations')
          ? _answer
          : <String, dynamic>{};
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

void main() {
  testWidgets('each location: its karats and its total, three places', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('المخزون'), findsWidgets);
    expect(find.text('الذهب المعروض'), findsOneWidget);
    expect(find.textContaining('21,919.847'), findsOneWidget);
    expect(find.textContaining('11,428.990'), findsOneWidget);
    expect(
      find.textContaining('23,006.401'),
      findsOneWidget,
      reason: 'the total',
    );
    expect(
      find.textContaining('.4016'),
      findsNothing,
      reason: 'never four places',
    );
  });

  testWidgets('before its count a category is its movement, not a negative '
      'balance', (tester) async {
    await _open(tester);
    await tester.tap(find.text('التصنيفات (1)').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('خرج 480.590'), findsOneWidget);
    expect(find.textContaining('-480.59'), findsNothing);
    expect(find.text('لم يُجرد بعد'), findsWidgets);
  });

  testWidgets('a counted location: its categories are balances, its count '
      'says when, who and its entry', (tester) async {
    await _open(tester);
    expect(find.textContaining('JE-2026-07001'), findsOneWidget);
    expect(find.textContaining('المدير'), findsOneWidget);
  });

  testWidgets('a location below zero says so; the nightly check is said on '
      'top; the deposits are not counted', (tester) async {
    await _open(tester);
    expect(find.text('رصيد سالب في الدفاتر'), findsOneWidget);
    expect(find.textContaining('2 توزيع مخزون يخالف سطره'), findsOneWidget);
    expect(find.text('ودائع لدى المكاتب — لا تُجرد'), findsOneWidget);
  });

  testWidgets('a session open on a location resumes it', (tester) async {
    await _open(tester);
    await tester.tap(find.text('متابعة الجرد'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final screen = tester.widget<InventoryCountScreen>(
      find.byType(InventoryCountScreen),
    );
    expect(screen.sessionId, 9);
  });

  for (final (name, width, theme) in [
    ('light_desktop', 1440.0, LightTheme.theme),
    ('light_phone', 390.0, LightTheme.theme),
    ('dark_desktop', 1440.0, DarkTheme.theme),
  ]) {
    testWidgets('it lays out $name', (tester) async {
      await _open(tester, width: width, theme: theme);
      expect(tester.takeException(), isNull);
      await shot(tester, 'stock_$name');
    });
  }
}
