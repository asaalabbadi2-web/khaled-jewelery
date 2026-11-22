// «سجلّ الجرد بالمسح» (ADR-085 ت2 ج3): every count by scan, the newest first --
// its place, kind, scope, who and when, how it ended, its counts by verdict,
// all the server's; a scan opened shows its result as frozen at its finish.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_scans_log_screen.dart';
import 'package:frontend/utils/bidi.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:intl/date_symbol_data_local.dart';

Map<String, dynamic> _scan(int id, {String status = 'finished', bool? complete = true, String? early, int missing = 1}) => {
  'id': id, 'safe_name': 'الذهب المعروض', 'kind_words': 'جرد إغلاق', 'scope_words': 'قسم بناجر',
  'status': status, 'complete': status == 'finished' ? complete : null, 'early_reason': early,
  'started_by': 'saleh', 'started_by_name': 'صالح العبادي', 'started_at': '2027-01-04T21:05:00',
  'finished_by': status == 'open' ? null : 'saleh', 'finished_by_name': status == 'open' ? null : 'صالح العبادي',
  'finished_at': status == 'open' ? null : '2027-01-04T21:12:00',
  'expected': 40, 'found': 38, 'alerts': 2,
  if (status == 'finished') 'expected_counts': {'found': 38, 'missing': missing, 'untagged': 1},
};

class _Api extends ApiService {
  _Api(this.scans);
  final List<Map<String, dynamic>> scans;
  final opened = <int>[];
  final asked = <({int? safeBoxId, String? period})>[];

  @override
  Future<Map<String, dynamic>> pieceScans({int? safeBoxId, String? period}) async {
    asked.add((safeBoxId: safeBoxId, period: period));
    return {'scans': scans};
  }

  @override
  Future<Map<String, dynamic>> pieceScanLocations() async => {
    'locations': [{'id': 30, 'name': 'الذهب المعروض'}, {'id': 31, 'name': 'العرض الخارجي'}],
  };

  @override
  Future<Map<String, dynamic>> pieceScan(int scanId) async {
    opened.add(scanId);
    final s = scans.firstWhere((x) => x['id'] == scanId);
    return {
      'scan': {
        ...s,
        'reads': [
          {'value': '4B4A00000000000000000202', 'verdict': 'elsewhere', 'verdict_words': 'في غير موقعها',
           'words': 'KJ-000202 — مكانها في الدفاتر «عهدة»', 'moved': null},
        ],
        if (s['status'] == 'finished')
          'expected_pieces': [
            {'item_id': 1, 'item_code': 'KJ-000101', 'weight': 10.0, 'verdict': 'found', 'verdict_words': 'موجودة'},
            {'item_id': 3, 'item_code': 'KJ-000103', 'weight': 12.5, 'verdict': 'missing', 'verdict_words': 'ناقصة'},
          ],
      },
    };
  }
}

Future<void> _open(WidgetTester tester, _Api api, {Size size = const Size(1400, 1000)}) async {
  await initializeDateFormatting('ar');
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceScansLogScreen(api: api)));
  await tester.pumpAndSettle();
}

String _said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('a computer: the table, each scan its state and its counts, the server\'s', (tester) async {
    final api = _Api([_scan(3), _scan(2, complete: false, early: 'انقطع'), _scan(1, status: 'abandoned'),
                      _scan(4, status: 'open')]);
    await _open(tester, api);
    expect(find.byKey(const Key('scans-table')), findsOneWidget);
    expect((_said(tester, 'scans-state-3'), _said(tester, 'scans-state-2'), _said(tester, 'scans-state-1'),
            _said(tester, 'scans-state-4')), ('مكتمل', 'أُنهي مبكرًا', 'متروكة', 'مفتوحة'));
    expect(find.text(isolateLatin('38 من 40')), findsNWidgets(4), reason: 'each run isolated: «38 من 40», not «من 40 38»');
    expect(find.text('صالح العبادي'), findsNWidgets(4), reason: 'who, by his name -- not his login');
  });

  // The owner, 22 Nov 2026 (the screens by a designer's eye): daily counts pile up -- the log by its
  // location and its period, asked of the server; a scan that found pieces missing marked, and alone if asked.
  testWidgets('by location and period, the server asked; one with missing pieces marked and shown alone', (tester) async {
    final api = _Api([_scan(3), _scan(2, missing: 0)]);
    await _open(tester, api);
    expect(api.asked.last, (safeBoxId: null, period: null), reason: 'all, at first');
    await tester.tap(find.byKey(const Key('scans-period-week')));
    await tester.pumpAndSettle();
    expect(api.asked.last, (safeBoxId: null, period: 'week'));
    await tester.tap(find.byKey(const Key('scans-location')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('العرض الخارجي').last);
    await tester.pumpAndSettle();
    expect(api.asked.last, (safeBoxId: 31, period: 'week'));
    expect(find.descendant(of: find.byKey(const Key('scans-missing-3')), matching: find.byIcon(Icons.report_outlined)),
        findsOneWidget, reason: 'its missing marked by an icon, not a colour alone');
    expect(find.descendant(of: find.byKey(const Key('scans-missing-2')), matching: find.byIcon(Icons.report_outlined)),
        findsNothing);
    await tester.tap(find.byKey(const Key('scans-only-missing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scans-state-3')), findsOneWidget);
    expect(find.byKey(const Key('scans-state-2')), findsNothing, reason: 'only the scans that found pieces missing');
  });

  testWidgets('a phone: cards', (tester) async {
    await _open(tester, _Api([_scan(3)]), size: const Size(390, 900));
    expect(find.byKey(const ValueKey('scans-card-3')), findsOneWidget);
    expect(find.byKey(const Key('scans-table')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a scan opened: its result frozen -- who, how it ended, the piece missing, the alert', (tester) async {
    final api = _Api([_scan(3)]);
    await _open(tester, api);
    await tester.tap(find.text('مكتمل'));
    await tester.pumpAndSettle();
    expect(api.opened, [3]);
    expect(_said(tester, 'scan-result-state'), 'انتهى الجرد ومسحه مكتمل');
    expect(_said(tester, 'scan-result-who'), contains('أنهاه صالح العبادي'));
    expect(_said(tester, 'scan-result-who'), contains(ltrIsolate('2027-01-04 21:12')), reason: 'its date isolated, never reversed');
    expect(find.textContaining('KJ-000103'), findsOneWidget);
    expect(find.textContaining('KJ-000101'), findsNothing, reason: 'the found counted, not listed');
    expect(find.text('في غير موقعها'), findsOneWidget);
    // The owner, 22 Nov 2026 (the screens by a designer's eye): the result was a line of plain text. Its
    // figures as the scanning screen's tiles, coloured; the missing -- what a count is for -- first, in
    // the warning's colour, each with its icon; the rest after them.
    expect((_said(tester, 'scan-count-found'), _said(tester, 'scan-count-missing')), (isolateLatin('38'), isolateLatin('1')));
    final missingTile = tester.widget<Container>(find.ancestor(
        of: find.byKey(const Key('scan-count-missing')), matching: find.byType(Container)).first);
    expect((missingTile.decoration as BoxDecoration).color, AppSemanticColors.of(tester.element(
        find.byKey(const Key('scan-count-missing')))).warning.container, reason: 'a missing piece is a warning');
    expect(_said(tester, 'scan-missing-title'), 'الناقصة (1)');
    expect(find.descendant(of: find.byKey(const Key('scan-piece-3')), matching: find.byIcon(Icons.report_outlined)),
        findsOneWidget, reason: 'each missing piece with its icon, not a colour alone');
    expect(tester.getTopLeft(find.byKey(const Key('scan-missing-title'))).dy,
        lessThan(tester.getTopLeft(find.text('في غير موقعها')).dy), reason: 'the missing before the alerts');
  });

  testWidgets('an open scan from the log says it is open, no verdicts yet', (tester) async {
    await _open(tester, _Api([_scan(4, status: 'open')]));
    await tester.tap(find.text('مفتوحة'));
    await tester.pumpAndSettle();
    expect(_said(tester, 'scan-result-state'), 'الجرد مفتوح: موجودة 38 من 40 حتى الآن، ويُكمَل من القارئ');
    expect(find.byKey(const Key('scan-count-missing')), findsNothing, reason: 'nothing missing before its finish');
  });

  testWidgets('no scan yet: where a scan is made', (tester) async {
    await _open(tester, _Api([]));
    expect(find.text('لا جرد بالمسح بعد'), findsOneWidget);
  });
}
