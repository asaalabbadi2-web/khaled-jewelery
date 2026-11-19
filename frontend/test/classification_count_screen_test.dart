// «تصنيف المخزون» (the owner, 19 Nov 2026): «هل يجب في الجرد الفعلي ان نزن
// التصنيف كاملا ام نزن جزء» -- then «ابنه». A count type of its own: a
// category weighed whole, its grams taken from «بلا تصنيف» by the server; the
// open sheet offers it, «بلا تصنيف» is not typed there, and its approval says
// it moves grams between categories, no surplus, no shortage, no reason asked.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/inventory_count_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _line(int id, {int? categoryId, String? name, double? counted}) => {
      'id': id, 'session_id': 7, 'branch_id': null, 'safe_box_id': 30, 'safe_box_name': 'الذهب المعروض',
      'category_id': categoryId, 'category_name': name, 'karat': 21.0, 'expected_weight': null,
      'expected_ledger_id': null, 'counted_weight': counted, 'variance': null, 'counted_by': null,
      'counted_at': null, 'notes': null,
    };

Map<String, dynamic> _session({String status = 'counting'}) => {
      'id': 7, 'branch_id': null, 'safe_box_id': 30, 'safe_box_name': 'الذهب المعروض', 'entry_id': null,
      'status': status, 'lines_total': 2, 'lines_counted': 2, 'session_type': 'classify', 'blind_count': true,
      'snapshot_ledger_id': null, 'opened_by': 't', 'opened_at': '2026-11-20T10:00:00', 'closed_at': null,
      'approved_by': null, 'approved_at': null, 'notes': null,
      'lines': [
        _line(1, categoryId: 28, name: 'بنجرة ذهب 21', counted: 2400.0),
        _line(2, counted: 12090.3),
      ],
      'by_karat': [
        {'karat': 21.0, 'books': 14363.29, 'counted': 14363.29, 'difference': 0.0},
      ],
    };

final _safes = [
  {'id': 30, 'account_id': 1300, 'name': 'الذهب المعروض', 'safe_type': 'gold', 'stock_location': 'showroom',
   'is_active': true},
];

final _sent = <String>[];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

MockClient _server(Object Function(http.Request) answer) => MockClient((r) async {
      if (r.method != 'GET') _sent.add('${r.method} ${r.url.path} ${r.body}');
      return http.Response(jsonEncode(answer(r)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

Future<void> _pump(WidgetTester tester, Widget screen, Object Function(http.Request) answer) async {
  final cairo = FontLoader('Cairo');
  for (final f in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = const Size(1440, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _sent.clear();
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: screen));
    await _settle(tester);
  }, () => _server(answer));
}

void main() {
  testWidgets('the open sheet offers a classification, and opens one', (tester) async {
    Object answer(http.Request r) => r.url.path.endsWith('/safe-boxes')
        ? _safes
        : r.method == 'POST'
            ? _session()
            : _session();
    await _pump(tester, const InventoryCountScreen(), answer);
    await http.runWithClient(() async {
      await tester.tap(find.text('تصنيف المخزون'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Text>(find.byKey(const Key('count-type-help'))).data,
          contains('يُؤخذ وزنه من «بلا تصنيف» تلقائيًا'));
      expect(find.text('جرد أعمى'), findsNothing, reason: 'a periodic count\'s alone');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('الذهب المعروض').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('بدء الجرد'));
      await _settle(tester);
    }, () => _server(answer));
    final opened = _sent.firstWhere((s) => s.startsWith('POST') && s.contains('/inventory/count'));
    expect(jsonDecode(opened.substring(opened.indexOf('{')))['session_type'], 'classify');
  });

  testWidgets('a closed classification is approved saying what it moves, no reason asked', (tester) async {
    await _pump(tester, const InventoryCountScreen(sessionId: 7), (r) => _session(status: 'closed'));
    expect(find.textContaining('تصنيف المخزون — الذهب المعروض'), findsOneWidget);
    await http.runWithClient(() async {
      await tester.tap(find.text('اعتماد الجرد').first);
      await tester.pump(const Duration(milliseconds: 300));
    }, () => _server((r) => _session(status: 'closed')));
    expect(find.byKey(const Key('classify-approve')), findsOneWidget);
    expect(find.text('لا زيادة ولا نقص: وزن كل عيار في الخزينة كما هو'), findsOneWidget);
    expect(find.text('اعتماد جلسة الجرد'), findsNothing, reason: 'not the periodic dialog with its reasons');
  });
}
