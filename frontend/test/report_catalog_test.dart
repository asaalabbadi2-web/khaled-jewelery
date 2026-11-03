// REPORTS ت0-1 (the owner, 4 Nov 2026): the reports centre lists only what
// opens. On the 2 Nov tree four of its 27 entries were titles with no report
// behind them (the balance sheet, the cash flow, the attendance summary, the
// customer statement) -- a tap said «غير متوفر حالياً», a dead end (FC-4).
// Every entry opens its screen; a report not built is not listed.

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/report_catalog.dart';
import 'package:frontend/screens/reports/reports_main_screen.dart';

void main() {
  test('every report the centre lists opens its screen', () {
    final api = ApiService();
    final dead = [
      for (final category in ReportCatalog.buildDefaultCatalog())
        for (final r in category.reports)
          if (reportDestination(r.route, api, true) == null) r.id,
    ];
    expect(dead, isEmpty, reason: 'listed, with nothing behind it');
  });

  test('each report is listed once', () {
    final ids = [
      for (final category in ReportCatalog.buildDefaultCatalog())
        for (final r in category.reports) r.id,
    ];
    expect(ids.toSet().length, ids.length);
  });
}
