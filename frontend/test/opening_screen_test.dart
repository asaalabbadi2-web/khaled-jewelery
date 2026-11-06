// TR-2 (ADR-044; the owner, 6 Nov 2026): the opening screen -- the books' rows
// by their group, each figure empty until entered («فارغة حتى تُؤكَّد») with
// its source; «مطابق للدفاتر» copies the books into it, still to be saved; a
// party's cash asks gold at the closing price or cash waiting («الاثنين
// معا»); what equity takes said on top. The manager enters, the owner
// approves («المدير يُدخل، والمالك يعتمد»): the approval only once every row
// has its figure; approved, nothing opens to edit.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/opening_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/shots.dart';

class _Auth extends AuthProvider {
  _Auth(this.grants);
  final Set<String> grants;
  @override
  bool hasPermission(String key) => grants.contains(key);
}

Map<String, dynamic> _row(int id, String name, String section, Map<String, num> books,
        {bool party = false, Map<String, num>? actual, String? source, String? treatment}) =>
    {
      'account_id': id, 'number': '$id', 'name': name, 'section': section, 'party': party,
      'books': {'cash': 0, '18': 0, '21': 0, '22': 0, '24': 0, ...books},
      'actual': actual == null ? null : {'cash': 0, '18': 0, '21': 0, '22': 0, '24': 0, ...actual},
      'difference': null, 'source': source, 'treatment': treatment, 'note': null,
      'entered_by': actual == null ? null : 'masad', 'entered_at': null,
    };

Map<String, dynamic> _opening({bool approved = false, bool all = false}) => {
      'year': 2027,
      'rows': [
        _row(1, 'حساب بنكي مؤقت', 'النقدية والبنوك', {'cash': 4137},
            actual: {'cash': 4137}, source: 'statement'),
        _row(2, 'مكتب ديوان الذهب', 'موردو الذهب المشغول', {'cash': -126648.25}, party: true,
            actual: all ? {'cash': -126648.25} : null, source: all ? 'reconciliation' : null,
            treatment: all ? 'waiting' : null),
        _row(3, 'فنون الالماس', 'موردو الذهب المشغول', {'24': 290.3}, party: true,
            actual: all ? {'24': 290.3} : null, source: all ? 'reconciliation' : null),
      ],
      'sources': {'count': 'عدّ', 'statement': 'كشف', 'reconciliation': 'مطابقة', 'acknowledgment': 'إقرار',
                  'other': 'أخرى'},
      'treatments': {'gold': 'ذهب على الطرف بسعر التسكير يوم الجرد', 'waiting': 'نقد ينتظر التسكير'},
      'entered': all ? 3 : 1, 'total': 3,
      'difference': {'cash': -37.0, 'grams': 0.0},
      'approved': approved ? {'by': 'saleh', 'at': '2027-01-01T08:00:00'} : null,
    };

final sent = <String>[];

Future<void> _open(WidgetTester tester, Map<String, dynamic> answer,
    {Set<String> grants = const {'opening.enter'}, double width = 1440, ThemeData? theme}) async {
  final cairo = FontLoader('Cairo');
  for (final f in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  sent.clear();
  await http.runWithClient(() async {
    await tester.pumpWidget(const SizedBox()); // a fresh screen and grants each time
    await tester.pumpWidget(ChangeNotifierProvider<AuthProvider>(
      create: (_) => _Auth(grants),
      child: MaterialApp(theme: theme ?? LightTheme.theme, home: const Directionality(
          textDirection: TextDirection.rtl, child: OpeningScreen(year: 2027))),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }, () => MockClient((r) async {
    if (r.method != 'GET') sent.add('${r.method} ${r.url.path} ${r.body}');
    return http.Response(jsonEncode(answer), 200, headers: {'content-type': 'application/json; charset=utf-8'});
  }));
}

void main() {
  testWidgets('the rows by their group, each figure empty until entered', (tester) async {
    await _open(tester, _opening());
    expect(find.text('النقدية والبنوك'), findsOneWidget);
    expect(find.text('موردو الذهب المشغول'), findsOneWidget);
    expect(find.text('لم يُدخل'), findsNWidgets(2));
    expect(find.textContaining('مُدخَل 1 من 3'), findsOneWidget);
    expect(find.textContaining('37.00'), findsWidgets, reason: 'what equity takes');
  });

  testWidgets("a party's cash asks gold or waiting; «مطابق للدفاتر» fills it", (tester) async {
    await _open(tester, _opening());
    await tester.tap(find.text('مكتب ديوان الذهب'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('نقد ينتظر التسكير'), findsOneWidget);
    expect(find.text('ذهب على الطرف بسعر التسكير يوم الجرد'), findsOneWidget);
    await tester.tap(find.text('مطابق للدفاتر'));
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '-126648.25'), findsOneWidget);
  });

  testWidgets('the manager enters; the owner approves once every row has its figure', (tester) async {
    await _open(tester, _opening());
    expect(find.text('اعتماد الافتتاح'), findsNothing, reason: 'the manager does not approve');
    await _open(tester, _opening(), grants: {'opening.enter', 'opening.approve'});
    final approve = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'اعتماد الافتتاح'));
    expect(approve.onPressed, isNull, reason: 'two rows have no figure');
    await _open(tester, _opening(all: true), grants: {'opening.enter', 'opening.approve'});
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'اعتماد الافتتاح')).onPressed,
        isNotNull);
  });

  testWidgets('approved, it says who and nothing opens to edit', (tester) async {
    await _open(tester, _opening(approved: true, all: true));
    expect(find.textContaining('saleh'), findsOneWidget);
    await tester.tap(find.text('مكتب ديوان الذهب'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('مطابق للدفاتر'), findsNothing);
  });

  for (final (name, width, theme) in [
    ('light_desktop', 1440.0, LightTheme.theme),
    ('light_phone', 390.0, LightTheme.theme),
    ('dark_phone', 390.0, DarkTheme.theme),
  ]) {
    testWidgets('it lays out $name', (tester) async {
      await _open(tester, _opening(), width: width, theme: theme);
      expect(tester.takeException(), isNull);
      await shot(tester, 'opening_$name');
    });
  }
}
