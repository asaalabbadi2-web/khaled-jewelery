// The models' movement on the reports' shell (ADR-093; the owner, 18 Nov 2026):
// it opens on this month by model and size; each row what was, came in,
// went out, and is left; the server's check that it adds up is said; «حسب»
// reads it again by model alone; the report is in the reports' centre.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/report_catalog.dart';
import 'package:frontend/screens/reports/model_movement_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <({String start, String end, String by})>[];

  @override
  Future<Map<String, dynamic>> getModelMovement({
    required String startDate,
    required String endDate,
    String by = 'model_size',
    int? categoryId,
  }) async {
    asked.add((start: startDate, end: endDate, by: by));
    final sized = by == 'model_size';
    return {
      'id': 'model_movement',
      'title': 'حركة الموديلات',
      'basis': 'posted_entries',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {'key': 'model', 'label': 'الموديل', 'kind': 'text'},
        if (sized) {'key': 'size', 'label': 'المقاس', 'kind': 'text'},
        {'key': 'opening', 'label': 'أول الفترة', 'kind': 'count'},
        {'key': 'received', 'label': 'استُلم', 'kind': 'count'},
        {'key': 'sold', 'label': 'بيع', 'kind': 'count'},
        {'key': 'closing', 'label': 'آخر الفترة', 'kind': 'count'},
        {'key': 'closing_weight', 'label': 'وزنه', 'kind': 'grams'},
      ],
      'rows': [
        {'model': 'بنجرة الشمس', if (sized) 'size': '18', 'opening': 0, 'received': 2, 'sold': 1, 'closing': 1,
         'closing_weight': 10.0},
      ],
      'totals': {'opening': 0, 'received': 2, 'sold': 1, 'closing': 1, 'closing_weight': 10.0},
      'checks': [
        {'key': 'balance', 'label': 'أول الفترة + ما دخل − ما خرج = آخر الفترة', 'ok': true},
      ],
      'read_at': '2026-11-18T10:00:00',
    };
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('this month by model and size; its rows; the check said; by model again', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ModelMovementReportScreen(api: server, now: () => DateTime(2026, 11, 18)),
      ),
    ));
    await _settle(tester);
    expect(server.asked.single, (start: '2026-11-01', end: '2026-11-18', by: 'model_size'));
    expect(find.text('بنجرة الشمس'), findsWidgets);
    expect(find.byKey(const ValueKey('report-check-balance')), findsOneWidget);
    await tester.tap(find.text('الموديل').first);
    await _settle(tester);
    expect(server.asked.last.by, 'model');
  });

  test('the reports\' centre lists it', () {
    final all = [for (final c in ReportCatalog.buildDefaultCatalog()) ...c.reports];
    final movement = all.where((r) => r.id == 'model_movement').single;
    expect(movement.route, 'model_movement');
  });
}
