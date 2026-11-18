// «القطع الراكدة» and «ما يُطلب من المورد» on the reports' shell (ADR-093;
// the owner, 18 Nov 2026): each asks the server on a day, its days the
// report's choice -- 90 by default for what sits, 30 for the pace -- and
// asks again when another is chosen; both are in the reports' centre.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/report_catalog.dart';
import 'package:frontend/screens/reports/model_reorder_report_screen.dart';
import 'package:frontend/screens/reports/slow_pieces_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

Map<String, dynamic> _report(String id, List<Map<String, dynamic>> columns, List<Map<String, dynamic>> rows) => {
      'id': id, 'title': id, 'basis': 'posted_entries', 'period': {'start': null, 'end': '2026-11-18'},
      'columns': columns, 'rows': rows, 'totals': <String, dynamic>{}, 'checks': [], 'read_at': '2026-11-18T10:00:00',
    };

class _Server extends ApiService {
  final asked = <String>[];

  @override
  Future<Map<String, dynamic>> getSlowPieces({required String asOf, int minDays = 90, String by = 'piece'}) async {
    asked.add('slow $asOf $minDays $by');
    return _report('slow_pieces', [
      {'key': 'item_code', 'label': 'رقم القطعة', 'kind': 'text'},
      {'key': 'days', 'label': 'الأيام', 'kind': 'count'},
    ], [
      {'item_code': 'KJ-000241', 'days': 120},
    ]);
  }

  @override
  Future<Map<String, dynamic>> getModelReorder({required String asOf, int days = 30}) async {
    asked.add('reorder $asOf $days');
    return _report('model_reorder', [
      {'key': 'state', 'label': 'الحال', 'kind': 'text'},
      {'key': 'model', 'label': 'الموديل', 'kind': 'text'},
      {'key': 'size', 'label': 'المقاس', 'kind': 'text'},
    ], [
      {'state': 'نفد', 'model': 'بنجرة الشمس', 'size': '17'},
    ]);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Server> _open(WidgetTester tester, Widget Function(_Server) screen) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: Directionality(textDirection: TextDirection.rtl, child: screen(server)),
  ));
  await _settle(tester);
  return server;
}

void main() {
  testWidgets('what sits: today, past 90 days by piece; another number of days asks again', (tester) async {
    final server = await _open(tester, (s) => SlowPiecesReportScreen(api: s, now: () => DateTime(2026, 11, 18)));
    expect(server.asked.single, 'slow 2026-11-18 90 piece');
    expect(find.text('KJ-000241'), findsOneWidget);
    await tester.tap(find.text('30 يومًا').first);
    await _settle(tester);
    expect(server.asked.last, 'slow 2026-11-18 30 piece');
    await tester.tap(find.text('الموديل').first);
    await _settle(tester);
    expect(server.asked.last, 'slow 2026-11-18 30 model');
  });

  testWidgets('what to reorder: today at the pace of 30 days; 60 asks again', (tester) async {
    final server = await _open(tester, (s) => ModelReorderReportScreen(api: s, now: () => DateTime(2026, 11, 18)));
    expect(server.asked.single, 'reorder 2026-11-18 30');
    expect(find.text('نفد'), findsOneWidget);
    await tester.tap(find.text('60 يومًا').first);
    await _settle(tester);
    expect(server.asked.last, 'reorder 2026-11-18 60');
  });

  test('the reports\' centre lists both', () {
    final routes = {for (final c in ReportCatalog.buildDefaultCatalog()) for (final r in c.reports) r.route};
    expect(routes, containsAll(['slow_pieces', 'model_reorder']));
  });
}
