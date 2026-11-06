// ADR-044 phase 2: a closed year's archive says so on every screen, signed in
// or not -- the year from check-setup (archive_year); a working year's says
// nothing (the owner, 7 Nov 2026: every user, port 8080).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/archive_banner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _open(WidgetTester tester, Object? year) async {
  SharedPreferences.setMockInitialValues({});
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      builder: (context, child) => ArchiveBanner(child: child!),
      home: const Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: Text('الشاشة'))),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }, () => MockClient((r) async => http.Response(
      jsonEncode({'success': true, 'needs_setup': false, 'archive_year': year}), 200,
      headers: {'content-type': 'application/json; charset=utf-8'})));
}

void main() {
  testWidgets('the archive says so above every screen', (tester) async {
    await _open(tester, 2026);
    expect(find.text('أرشيف 2026 — للقراءة فقط'), findsOneWidget);
    expect(find.text('الشاشة'), findsOneWidget);
  });

  testWidgets("a working year's says nothing", (tester) async {
    await _open(tester, null);
    expect(find.textContaining('أرشيف'), findsNothing);
    expect(find.text('الشاشة'), findsOneWidget);
  });
}
