import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/inventory_models.dart';
import 'package:frontend/screens/inventory_count_screen.dart';
import 'package:frontend/services/inventory_service.dart';
import 'package:http/http.dart' as http;

/// The count on the one reader (ADR-045 C2, 13 Oct 2026). A count is of a
/// location -- a stock safe -- or of every one, not of a branch; a line
/// without a category («بلا تصنيف», all of 2026's stock) is counted like any
/// other -- the screen refused to save one; the approval is an entry in the
/// books, not an adjustment of the retired inventory ledger.

class _FakeApi extends ApiService {
  final calls = <(String, String, Map<String, dynamic>?)>[];
  Map<String, dynamic> reply = const {};

  http.Response _ok(String method, String path, Object? body) {
    calls.add((
      method,
      path,
      body == null ? null : jsonDecode(body as String) as Map<String, dynamic>,
    ));
    // The server escapes non-ASCII (Flask's ensure_ascii); a declared UTF-8 body reads the same.
    return http.Response.bytes(
      utf8.encode(jsonEncode(reply)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  Future<http.Response> authedPost(String path, {Object? body}) async =>
      _ok('POST', path, body);

  @override
  Future<http.Response> authedPut(String path, {Object? body}) async =>
      _ok('PUT', path, body);

  /// GET answers [getReply] -- the full session, its lines included.
  Map<String, dynamic> getReply = const {};

  @override
  Future<http.Response> authedGet(
    String path, {
    Map<String, String>? queryParams,
  }) async {
    calls.add(('GET', path, null));
    return http.Response.bytes(
      utf8.encode(jsonEncode(getReply)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Map<String, dynamic> _session({int? safeBoxId}) => {
  'id': 7,
  'branch_id': null,
  'safe_box_id': safeBoxId,
  'entry_id': null,
  'status': 'open',
  'session_type': 'periodic',
  'blind_count': true,
};

Map<String, dynamic> _line({int? categoryId, String? categoryName}) => {
  'id': 70,
  'session_id': 7,
  'branch_id': null,
  'safe_box_id': 30,
  'safe_box_name': 'خزينة الذهب المعروض للبيع',
  'category_id': categoryId,
  'category_name': categoryName,
  'karat': 21.0,
  'counted_weight': 12.5,
};

void main() {
  test(
    'a count is opened for a location, or for every one -- never a branch',
    () async {
      final api = _FakeApi()..reply = _session(safeBoxId: 30);
      final svc = InventoryService(api);
      await svc.openSession(safeBoxId: 30);
      api.reply = _session();
      await svc.openSession();
      expect(api.calls[0].$3!['safe_box_id'], 30);
      expect(
        api.calls[1].$3!.containsKey('safe_box_id'),
        isFalse,
        reason: 'every location',
      );
      expect(api.calls.every((c) => !c.$3!.containsKey('branch_id')), isTrue);
    },
  );

  test('a line «بلا تصنيف» is recorded, with its location', () async {
    final api = _FakeApi()..reply = _line();
    final line = await InventoryService(api).recordEntry(
      sessionId: 7,
      categoryId: null,
      karat: 21,
      countedWeight: 12.5,
      safeBoxId: 30,
    );
    final body = api.calls.single.$3!;
    expect(body.containsKey('category_id'), isTrue);
    expect(body['category_id'], isNull);
    expect(body['safe_box_id'], 30);
    expect(line.safeBoxName, 'خزينة الذهب المعروض للبيع');
  });

  test('the approval answers with its entry in the books', () async {
    final api = _FakeApi()
      ..reply = {
        'session': {
          ..._session(safeBoxId: 30),
          'status': 'approved',
          'entry_id': 9,
        },
        'entry': {'id': 9, 'entry_number': 'JE-2026-06479'},
        'adjustment': null,
      }
      ..getReply = {
        ..._session(safeBoxId: 30),
        'status': 'approved',
        'entry_id': 9,
      };
    final result = await InventoryService(
      api,
    ).approveSession(7, reasonCode: 'COUNT_ERROR');
    expect(result.entryNumber, 'JE-2026-06479');
    expect(result.session.entryId, 9);
  });

  test(
    'a line is named by its category -- «بلا تصنيف» without one -- and its location',
    () {
      expect(
        countLineLabel(CountLine.fromJson(_line())),
        'بلا تصنيف — خزينة الذهب المعروض للبيع',
      );
      expect(
        countLineLabel(
          CountLine.fromJson(
            _line(categoryId: 28, categoryName: 'بنجرة ذهب ٢١'),
          ),
        ),
        'بنجرة ذهب ٢١ — خزينة الذهب المعروض للبيع',
      );
    },
  );

  test(
    'the stock is per location: its karats, its last count, its open session',
    () {
      final stock = StockLocations.fromJson({
        'grand_total_main': 22782.9,
        'violations': 0,
        'all_locations_session': null,
        'generated_at': '2026-11-06T12:00:00',
        'sections': [
          {
            'key': 'stock',
            'label': 'المخزون',
            'counted': true,
            'total_main': 22782.9,
            'locations': [
              {
                'safe_box_id': 30,
                'name': 'المعروض',
                'stock_location': 'showroom',
                'karats': [
                  {'karat': 21, 'grams': 12738.5},
                ],
                'total_main': 22782.9,
                'negative': false,
                'last_count': {
                  'session_id': 4,
                  'approved_at': '2026-12-31T22:00:00',
                  'approved_by': 'المدير',
                  'entry_number': 'JE-1',
                },
                'open_session': {'id': 9, 'status': 'open'},
                'categories_are_balances': true,
                'categories': [
                  {
                    'category_id': 28,
                    'name': 'بنجرة ذهب 21',
                    'karat': 21,
                    'grams': 60.0,
                  },
                ],
              },
            ],
          },
        ],
      });
      final loc = stock.sections.single.locations.single;
      expect(
        (loc.safeBoxId, loc.stockLocation, loc.karats.single.grams),
        (30, 'showroom', 12738.5),
      );
      expect((loc.lastCount!.entryNumber, loc.openSession!.id), ('JE-1', 9));
      expect(loc.categories.single.name, 'بنجرة ذهب 21');
    },
  );

  test('finishing and approving keep the lines on the screen', () async {
    // The close and approve routes answer a session summary, without its lines:
    // the review showed «لا توجد أصناف مسجّلة» before approval, and the approval
    // counted 0 items (found walking the screens on the 12 Oct copy).
    final full = {
      ..._session(safeBoxId: 30),
      'status': 'closed',
      'lines': [_line()],
    };
    final api = _FakeApi()
      ..reply = {..._session(safeBoxId: 30), 'status': 'closed'}
      ..getReply = full;
    final svc = InventoryService(api);
    final closed = await svc.closeSession(7);
    expect(closed.session.lines, hasLength(1));

    api
      ..reply = {
        'session': {..._session(safeBoxId: 30), 'status': 'approved'},
        'entry': null,
      }
      ..getReply = {...full, 'status': 'approved'};
    final approved = await svc.approveSession(7, reasonCode: 'COUNT_ERROR');
    expect(approved.session.lines, hasLength(1));
    expect(approved.session.status, 'approved');
  });
}
