// ADR-087 R3.4: «محطة ترميز القطع». The list is the server's lines left to
// code; a line opened, each piece typed and sent with its attempt's key --
// the server's number shown to write on its tag, the counter moved, the
// wage «بانتظار الفاتورة» until the invoice. Refused, the server's words are
// said and the next attempt is a new key; a lost answer keeps the key. A
// batch of the stock on hand takes no wage: each of its pieces is sent with
// its own, per gram or whole (ADR-096 §4; the owner, 19 Nov 2026).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/screens/piece_station_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/piece_label_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _batch({int pieces = 0, double coded = 0, bool fromPool = false}) => {
  'kind': 'stock', 'line_id': null, 'coding_id': 5, 'invoice_number': 'ترميز مخزون #5',
  'safe_name': 'المعرض', 'category_name': 'بنجرة ذهب 21', 'karat': 21, 'weight': 50.0,
  'wage_per_gram': null, 'wage_by_piece': !fromPool, 'wage_from_pool': fromPool,
  'pool_wage_per_gram': fromPool ? 20.0 : null, 'pieces': pieces, 'pieces_weight': coded,
  'rest': double.parse((50.0 - coded).toStringAsFixed(3)),
};

/// A batch with no weight declared, coded piece by piece from the unclassified (the owner, 27 Nov 2026).
Map<String, dynamic> _openBatch({int pieces = 0, double coded = 0, double settled = 0, String? ended}) => {
  'kind': 'stock', 'line_id': null, 'coding_id': 6, 'invoice_number': 'ترميز مخزون #6',
  'safe_name': 'المعرض', 'category_name': 'بنجرة ذهب 21', 'karat': 21, 'weight': coded,
  'open_batch': true, 'settled_grams': settled > 0 ? settled : null, 'ended_at': ended,
  'wage_per_gram': null, 'wage_by_piece': true, 'wage_from_pool': false, 'pool_wage_per_gram': null,
  'pieces': pieces, 'pieces_weight': coded, 'rest': double.parse((14490.0 - coded).toStringAsFixed(3)),
  'rest_closable': false,
};

Map<String, dynamic> _line({int pieces = 0, double coded = 0}) => {
  'line_id': 7, 'invoice_id': 900, 'invoice_number': 'PUR-2027-00001', 'stage': 'received',
  'supplier_name': 'مفيد الحبيشي', 'category_id': 28, 'category_name': 'بنجرة ذهب 21',
  'karat': 21, 'weight': 30.0, 'pieces': pieces, 'pieces_weight': coded,
  'rest': double.parse((30.0 - coded).toStringAsFixed(3)),
};

class _Api extends ApiService {
  final sent = <Map<String, dynamic>>[];
  final opened = <Map<String, dynamic>>[];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [
    SafeBoxModel.fromJson({'id': 3, 'account_id': 30, 'name': 'المعرض', 'safe_type': 'gold', 'stock_location': 'showroom'}),
    SafeBoxModel.fromJson({'id': 4, 'account_id': 40, 'name': 'وديعة المكتب', 'safe_type': 'gold', 'stock_location': 'deposit'}),
  ];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
    {'id': 28, 'name': 'بنجرة ذهب 21', 'karat': '21', 'is_active': true, 'tracking': 'piece'},
    {'id': 30, 'name': 'خواتم 21', 'karat': '21', 'is_active': true},
  ];

  /// From 2027's opening: the pool's average, not a wage written (ADR-096 ت3).
  bool fromPool = false;

  /// The category's balance in the place: below nothing, its sales since the allocation began.
  double categoryNet = 0;
  final ended = <int>[];

  @override
  Future<Map<String, dynamic>> stockCodingRoom(int safeBoxId, int categoryId) async =>
      {'free': 120.0, 'reserved': 0.0, 'room': 120.0, 'karat': 21, 'wage_from_pool': fromPool,
       'pool_wage_per_gram': fromPool ? 20.0 : null, 'unclassified': 14490.0, 'category_net': categoryNet};

  @override
  Future<Map<String, dynamic>> openStockCoding(Map<String, dynamic> body) async {
    opened.add(body);
    if (!body.containsKey('weight')) {
      return {'line': _openBatch(settled: categoryNet < 0 ? -categoryNet : 0), 'pieces': []};
    }
    return {'line': _batch(fromPool: fromPool), 'pieces': []};
  }

  @override
  Future<Map<String, dynamic>> endStockCoding(int codingId) async {
    ended.add(codingId);
    return {'line': _openBatch(ended: '2026-11-27T12:00:00')};
  }

  ApiException? refuseNext;
  bool loseNext = false;
  int _n = 0;

  // Its label (ADR-097): the printer, the jobs, each request recorded.
  bool printerReady = true;
  String printOutcome = 'completed';
  final printed = <Map<String, dynamic>>[];
  final runs = <int>[];
  final resolved = <Map<String, dynamic>>[];
  Map<String, dynamic> counts = {'pending': 0, 'failed': 0, 'needs_attention': 0};
  List<Map<String, dynamic>> openJobs = [];
  int _job = 0;

  Map<String, dynamic> _jobOf(int pieceId, String status, {String kind = 'first', int generation = 1}) => {
    'id': ++_job, 'item_id': pieceId, 'item_code': 'KJ-00012${pieceId - 100}', 'kind': kind, 'status': status,
    'last_attempt': status == 'pending' ? null : {
      'id': 500 + _job, 'generation': generation, 'printed': status == 'completed',
      'written': status == 'completed', 'verified': status == 'completed',
      'message': status == 'failed'
          ? 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'
          : status == 'needs_attention'
              ? 'انقطع الاتصال بالطابعة أثناء الطباعة'
              : null,
    },
  };

  @override
  Future<Map<String, dynamic>> labelPreview(int pieceId) async => {
    'faces': {'code': 'KJ-000121', 'number': 'KJ-000121', 'weight': '14.37g', 'karat': '21K', 'name': 'بنجرة ذهب 21',
              'marks': null},
  };

  @override
  Future<Map<String, dynamic>> labelPrinters() async => {
    'printers': [{'id': 1, 'name': 'طابعة المعرض', 'is_active': true}],
  };

  int statusAsked = 0;

  @override
  Future<Map<String, dynamic>> labelPrinterStatus(int printerId) async {
    statusAsked++;
    return {
    'status': printerReady
        ? {'ready': true, 'stops': [], 'message': null}
        : {'ready': false, 'stops': ['paper_out'], 'message': 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'},
    };
  }

  @override
  Future<Map<String, dynamic>> printJobsOpen() async => {'jobs': openJobs, 'counts': counts};

  @override
  Future<Map<String, dynamic>> printPieceLabel(int pieceId, Map<String, dynamic> body) async {
    printed.add({...body, 'piece_id': pieceId});
    if (busyFor > 0) {
      busyFor--;
      return {'job': _jobOf(pieceId, 'pending'), 'printer': {'ready': true, 'busy': true, 'message': 'الطابعة مشغولة ببطاقة أخرى: تُطبع بعدها'}};
    }
    if (printOutcome == 'not_ready') {
      // asked first, not ready: the job waits, nothing spent (ADR-097, ط6)
      return {
        'job': _jobOf(pieceId, 'pending', kind: '${body['kind']}'),
        'printer': {'ready': false, 'stops': ['unreachable'],
                    'message': 'الطابعة لا تردّ: تأكد أنها مشغّلة وعلى الشبكة ثم أعد المحاولة'},
      };
    }
    final status = body['run'] == false ? 'pending' : printOutcome;
    return {'job': _jobOf(pieceId, status, kind: '${body['kind']}', generation: printed.length)};
  }

  /// Answers «busy» this many times first (another label printing).
  int busyFor = 0;

  @override
  Future<Map<String, dynamic>> runPrintJob(int jobId) async {
    runs.add(jobId);
    if (busyFor > 0) {
      busyFor--;
      return {'job': _jobOf(101, 'pending'), 'printer': {'ready': true, 'busy': true, 'message': 'مشغولة'}};
    }
    return {'job': _jobOf(101, 'completed', generation: 2)};
  }

  @override
  Future<Map<String, dynamic>> resolvePrintAttempt(int attemptId, Map<String, dynamic> body) async {
    resolved.add({...body, 'attempt_id': attemptId});
    return {'job': _jobOf(101, body['no_label'] == true || body['destroyed'] == true ? 'failed' : 'completed')};
  }

  @override
  Future<List<Map<String, dynamic>>> piecesPending() async => [_line()];

  /// The line's stones priced by the carat: out of its gold (ت4).
  bool pricedStones = false;

  /// Its rest the scale's drift: closable (the owner, 25 Nov 2026: «إقفال الباقي»).
  bool restClosable = false;
  final restsClosed = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> pieceLine(int lineId) async => {
        'line': {
          ..._line(),
          if (pricedStones) 'stones_kind': 'priced',
          if (restClosable) ...{'pieces': 3, 'pieces_weight': 29.97, 'rest': 0.03, 'rest_closable': true},
        },
        'pieces': [],
      };

  @override
  Future<Map<String, dynamic>> closeCodingRest({int? lineId, int? codingId, required String reason}) async {
    restsClosed.add({'line_id': lineId, 'coding_id': codingId, 'reason': reason});
    return {'closed': {'grams': 0.03}, 'line': {..._line(pieces: 3, coded: 29.97), 'rest': 0.0, 'rest_closable': false}};
  }

  /// The server's reading of a weight typed, each question recorded.
  final weighs = <Map<String, dynamic>>[];
  Map<String, dynamic>? weighAnswer;

  @override
  Future<Map<String, dynamic>> weighPiece({int? lineId, int? codingId, required double weight, double stonesWeight = 0}) async {
    weighs.add({'line_id': lineId, 'weight': weight, 'stones_weight': stonesWeight});
    return weighAnswer ??
        {'weighed': {'standing_weight': weight, 'stones_weight': stonesWeight, 'stones_kind': 'as_gold',
                     'grams': weight, 'net_weight': weight, 'rest': 30.0, 'rest_after': 30.0 - weight},
         'refused': null};
  }

  @override
  Future<Map<String, dynamic>> registerPiece(Map<String, dynamic> body) async {
    sent.add(body);
    if (refuseNext != null) {
      final e = refuseNext!;
      refuseNext = null;
      throw e;
    }
    if (loseNext) {
      loseNext = false;
      throw Exception('connection lost');
    }
    _n++;
    final w = (body['weight'] as num).toDouble();
    final stones = (body['stones_weight'] as num? ?? 0).toDouble();
    return {
      'piece': {'id': 100 + _n, 'item_code': 'KJ-00012$_n', 'weight': w, 'stones_weight': stones,
                // the server's: its stones counted as gold, its net its gold alone
                if (stones > 0) ...{'stones_kind': 'as_gold', 'standing_weight': w, 'net_weight': w - stones},
                'wage': null, 'wage_known': false},
      'line': body.containsKey('coding_id')
          ? _batch(pieces: _n, coded: w, fromPool: fromPool)
          : _line(pieces: _n, coded: w),
    };
  }
}

Future<void> _open(WidgetTester tester, _Api api, {Size size = const Size(1400, 1800)}) async {
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('station-line-7')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a piece typed is sent with its key; its number shown, the counter moved', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.textContaining('الباقي 30.00 جم'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['line_id'], 7);
    expect(api.sent.single['weight'], 14.37);
    expect(api.sent.single['request_key'], isNotEmpty);
    expect(tester.widget<Text>(find.byKey(const Key('station-last-code'))).data, 'KJ-000121');
    expect(find.textContaining('الباقي 15.63 جم'), findsOneWidget);
    expect(find.textContaining('بانتظار الفاتورة'), findsOneWidget);
    expect(find.byKey(const Key('piece-wage')), findsNothing, reason: 'a receipt\'s piece takes its invoice\'s wage');
    expect(api.sent.single.containsKey('wage'), isFalse);
  });

  testWidgets('the scale\'s drift left after the pieces: closed with its reason, the line done', (tester) async {
    final api = _Api()..restClosable = true;
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('station-close-rest')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('station-close-rest-reason')), 'فرق الميزان');
    await tester.tap(find.byKey(const Key('station-close-rest-sure')));
    await tester.pumpAndSettle();
    expect(api.restsClosed.single, {'line_id': 7, 'coding_id': null, 'reason': 'فرق الميزان'});
    expect(find.byKey(const Key('station-close-rest')), findsNothing, reason: 'nothing left to close');
  });

  testWidgets('a rest beyond the tolerance offers no closing: a count\'s', (tester) async {
    await _open(tester, _Api());
    expect(find.byKey(const Key('station-close-rest')), findsNothing);
  });

  testWidgets('refused, the words said and the next attempt a new key', (tester) async {
    final api = _Api()
      ..refuseNext = const ApiException(statusCode: 400, code: 'piece_heavier_than_rest',
          message: 'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)');
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '31');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(find.textContaining('أثقل من باقي السطر'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], isNot(api.sent[0]['request_key']));
  });

  testWidgets('a lost answer keeps the key: sent again, the same piece', (tester) async {
    final api = _Api()..loseNext = true;
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], api.sent[0]['request_key']);
  });

  testWidgets('no weight, nothing sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);
  });

  testWidgets('from the stock a location holds: a batch opened with no wage, each piece its own', (tester) async {
    final api = _Api();
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    expect(find.text('وديعة المكتب'), findsNothing, reason: 'an office deposit is not coded');
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    expect(find.text('خواتم 21'), findsNothing, reason: 'only categories tracked by the piece');
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('المتاح للترميز: 120.00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coding-weight')), '50');
    expect(find.byKey(const Key('coding-wage')), findsNothing, reason: 'a batch takes no wage');
    expect(find.byKey(const Key('coding-wage-by-piece')), findsOneWidget);
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(api.opened.single, {'safe_box_id': 3, 'category_id': 28, 'weight': 50.0});

    // no wage, nothing sent
    await tester.enterText(find.byKey(const Key('piece-weight')), '12.4');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);

    // per gram
    await tester.enterText(find.byKey(const Key('piece-wage')), '20');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['coding_id'], 5);
    expect(api.sent.single.containsKey('line_id'), isFalse);
    expect((api.sent.single['wage'], api.sent.single['wage_whole']), (20.0, false));
    expect(find.byKey(const Key('piece-wage')), findsOneWidget, reason: 'the next piece writes its own');

    // the piece's whole
    await tester.tap(find.text('أجرة القطعة كلها'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-weight')), '10');
    await tester.enterText(find.byKey(const Key('piece-wage')), '300');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect((api.sent.last['wage'], api.sent.last['wage_whole']), (300.0, true));
  });

  // Coding from the unclassified, piece by piece (the owner, 27 Nov 2026: «اعتمده»): no weight declared --
  // the category's sales since the allocation began settled on opening, said; the batch ended at the end.
  testWidgets('a batch with no weight: what is unclassified, the settling said, coded, then ended', (tester) async {
    final api = _Api()..categoryNet = -85.4;
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('coding-unclassified'))).data,
        'في الموقع عيار 21 بلا تصنيف: 14,490.00 جم');
    expect(tester.widget<Text>(find.byKey(const Key('coding-settle'))).data,
        'بلا وزن: يُنقل 85.40 جم من «بلا تصنيف» إلى التصنيف عند الفتح — مبيعاته منذ بدء التوزيع');
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(api.opened.single, {'safe_box_id': 3, 'category_id': 28}, reason: 'no weight sent');
    expect(find.textContaining('نُقل 85.40 جم من «بلا تصنيف» إلى «بنجرة ذهب 21»'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('station-counter'))).data,
        'قطعة قطعة · رُمّز 0.00 جم · 0 قطعة · المتاح في الموقع 14,490.00 جم');
    expect(find.byKey(const Key('station-progress')), findsNothing, reason: 'no weight declared: nothing to reach');
    expect(find.byKey(const Key('station-close-rest')), findsNothing);
    await tester.tap(find.byKey(const Key('station-end-batch')));
    await tester.pumpAndSettle();
    expect(api.ended, [6]);
  });

  testWidgets('from 2027 a batch\'s piece takes its pool\'s average: shown, not asked', (tester) async {
    final api = _Api()..fromPool = true;
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.text('لا أجرة للدفعة: كل قطعة تأخذ متوسط أجور تصنيفها.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coding-weight')), '50');
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('piece-wage')), findsNothing, reason: 'no wage written');
    expect(find.byKey(const Key('piece-wage-kind')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('piece-wage-from-pool')), matching: find.text('20.00 للجرام')),
        findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '10');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['coding_id'], 5);
    expect(api.sent.single.containsKey('wage'), isFalse, reason: 'the server takes it from the pool');
  });

  Future<void> register(WidgetTester tester, [String weight = '14.37']) async {
    await tester.enterText(find.byKey(const Key('piece-weight')), weight);
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
  }

  testWidgets('registered, its label printed at once: printed, its tag read back', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('الطابعة جاهزة'), findsOneWidget);
    await register(tester);
    expect(api.sent, hasLength(1), reason: 'the piece saved first');
    expect((api.printed.single['piece_id'], api.printed.single['run'], api.printed.single['kind']), (101, true, 'first'));
    expect(api.printed.single['request_key'], isNotEmpty);
    expect(find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('مكتملة · الجيل 1')),
        findsOneWidget);
    expect(find.byKey(const Key('station-tag-101')), findsNothing, reason: 'no tag mounted by a button');
  });

  testWidgets('the last piece shows its label as it prints, both faces', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    expect(find.byKey(const Key('label-preview-first')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('label-preview-first')), matching: find.text('14.37')),
        findsOneWidget);
  });

  testWidgets('«تسجيل فقط»: the piece saved, its label waiting', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.text('تسجيل فقط'));
    await tester.pumpAndSettle();
    await register(tester);
    expect(api.printed.single['run'], isFalse);
    expect(find.byKey(const Key('label-run-101')), findsWidgets, reason: 'waiting: printed when asked');
    expect(find.textContaining('تعذّرت طباعة البطاقة'), findsNothing, reason: 'nothing failed');
  });

  testWidgets('a printer that fails stops no one: said, then tried again', (tester) async {
    final api = _Api()..printOutcome = 'failed';
    await _open(tester, api);
    await register(tester);
    expect(find.text('تم تسجيل القطعة بنجاح، لكن تعذّرت طباعة البطاقة. أُضيفت إلى قائمة انتظار الطباعة.'),
        findsOneWidget);
    expect(find.textContaining('انتهت الملصقات'), findsWidgets);
    await tester.tap(find.byKey(const Key('label-retry-101')).first);
    await tester.pumpAndSettle();
    expect(api.runs, hasLength(1));
    expect(find.text('مكتملة · الجيل 2'), findsWidgets);
    await register(tester, '10');
    expect(api.sent, hasLength(2), reason: 'the next piece coded as before');
  });

  testWidgets('an unknown end settled by the reader: its own value adopted', (tester) async {
    final api = _Api()..printOutcome = 'needs_attention';
    await _open(tester, api);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-resolve-101')).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('في تطبيق الملاحظات على القارئ'), findsOneWidget,
        reason: 'the reader types on its own screen: said where its code is read');
    await tester.enterText(find.byKey(const Key('resolve-read')), '4B4A00010000000000000121');
    await tester.pump();                          // the button waits for 24 characters
    await tester.tap(find.byKey(const Key('resolve-adopt')));
    await tester.pumpAndSettle();
    expect(api.resolved.single['read_value'], '4B4A00010000000000000121');
    expect(find.text('مكتملة · الجيل 1'), findsWidgets);
  });

  testWidgets('an unknown end where no label came out: failed, tried again with a new label', (tester) async {
    final other = _Api()..printOutcome = 'needs_attention';
    await _open(tester, other);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-resolve-101')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('resolve-no-label')));
    await tester.pumpAndSettle();
    expect(other.resolved.single['no_label'], isTrue);
    expect(find.byKey(const Key('label-retry-101')), findsWidgets, reason: 'failed: tried again with a new label');
  });

  testWidgets('a reprint asks its reason', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    expect(find.byKey(const Key('label-reprint-101')), findsNothing,
        reason: 'a label done: its reprint in a small menu, not the next thing to do');
    await tester.tap(find.byKey(const Key('label-menu-101')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('label-reprint-101')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-action')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('confirm-reason')), 'تلفت البطاقة');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect((api.printed.last['kind'], api.printed.last['reason']), ('reprint', 'تلفت البطاقة'));
  });

  testWidgets('the printer stopped and the labels waiting are said; the failures handled from the bar',
      (tester) async {
    final api = _Api()
      ..printerReady = false
      ..counts = {'pending': 2, 'failed': 1, 'needs_attention': 0}
      ..openJobs = [
        {'id': 9, 'item_id': 101, 'item_code': 'KJ-000121', 'status': 'failed',
         'last_attempt': {'id': 509, 'message': 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'}},
      ];
    await _open(tester, api);
    expect(find.text('انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'), findsOneWidget);
    expect(find.text('بانتظار البطاقة 2 · فاشلة 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('station-failures')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('station-failures-sheet')),
        matching: find.text('إعادة المحاولة')));
    await tester.pumpAndSettle();
    expect(api.runs, [9]);
  });

  testWidgets('the printer\'s bar reads it again by itself: back from a cut cable, «جاهزة» with no press',
      (tester) async {
    final api = _Api()..printerReady = false;
    await _open(tester, api);
    expect(find.byKey(const Key('station-printer')), findsOneWidget);
    expect(find.text('الطابعة جاهزة'), findsNothing);
    final asked = api.statusAsked;
    api.printerReady = true;                       // the cable back
    await tester.pump(const Duration(seconds: 16));          // the station asks every 15 seconds
    await tester.pumpAndSettle();
    expect(api.statusAsked, greaterThan(asked));
    expect(find.text('الطابعة جاهزة'), findsOneWidget);
  });

  testWidgets('the printer not ready: its words said, the piece\'s label waiting', (tester) async {
    final api = _Api()..printOutcome = 'not_ready';
    await _open(tester, api);
    await register(tester);
    expect(find.textContaining('تعذّرت طباعة البطاقة: الطابعة لا تردّ'), findsOneWidget);
    expect(find.byKey(const Key('label-run-101')), findsWidgets, reason: 'waiting: printed when it answers');
  });

  testWidgets('another label printing: its turn asked again by itself, then printed -- nothing pressed',
      (tester) async {
    PieceLabelActions.busyPause = Duration.zero;
    addTearDown(() => PieceLabelActions.busyPause = const Duration(milliseconds: 1500));
    final api = _Api()..busyFor = 3;
    await _open(tester, api);
    await register(tester);
    expect(api.runs, hasLength(3), reason: 'busy at its request and twice more, then its turn came');
    expect(find.textContaining('مكتملة'), findsWidgets);
    expect(find.textContaining('تعذّرت'), findsNothing, reason: 'busy is not a failure');
  });

  // ── ر1: the mistakes the station stops before they are pieces ──

  testWidgets('a weight ten times the line\'s pieces is asked: corrected, nothing sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '5.2');
    expect(api.sent, hasLength(2));
    await register(tester, '51');
    expect(find.byKey(const Key('weight-unusual')), findsOneWidget);
    expect(find.textContaining('5.10 جم؟'), findsOneWidget, reason: 'the tenth offered: 51 typed for 5.1');
    await tester.tap(find.byKey(const Key('weight-fix')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2), reason: 'a piece is never deleted: the doubt asked before it is one');
    await register(tester, '5.1');
    expect(find.byKey(const Key('weight-unusual')), findsNothing);
    expect(api.sent, hasLength(3));
    expect(api.sent.last['weight'], 5.1);
  });

  testWidgets('a weight unusual but true is sent when said so', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '5.2');
    await register(tester, '1.2');
    expect(find.byKey(const Key('weight-unusual')), findsOneWidget);
    await tester.tap(find.byKey(const Key('weight-confirm')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(3));
    expect(api.sent.last['weight'], 1.2);
  });

  testWidgets('one piece is no average: the second weight is not asked', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '15');
    expect(find.byKey(const Key('weight-unusual')), findsNothing);
    expect(api.sent, hasLength(2));
  });

  testWidgets('the choices kept for the next piece are said where its weight is typed', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('بلا موديل · طباعة تلقائية'), findsOneWidget);
    await tester.tap(find.text('تسجيل فقط'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-current')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('station-current'))).data, 'بلا موديل · تسجيل فقط');
  });

  // The owner, 22 Nov 2026 (the screens by a designer's eye): on the reader the weight -- the field most
  // used -- began half way down, under the line's card and a three-line model card. On a phone the model
  // is one line; the weight rises.
  testWidgets('on a phone the model is one line, and the weight rises', (tester) async {
    await _open(tester, _Api(), size: const Size(360, 760));
    expect(tester.getSize(find.byKey(const Key('station-model'))).height, lessThanOrEqualTo(48),
        reason: 'one line: its name and its change');
    expect(find.descendant(of: find.byKey(const Key('station-model')), matching: find.textContaining('بلا موديل')),
        findsOneWidget);
    final model = tester.getRect(find.byKey(const Key('station-model')));
    expect(tester.getTopLeft(find.byKey(const Key('piece-weight'))).dy - model.bottom, lessThan(120),
        reason: 'after the model\'s one line, only the current settings\' line before the weight');
  });

  testWidgets('on a phone nothing is squeezed: the bar\'s words, the weight, the button, each piece', (tester) async {
    final api = _Api();
    await _open(tester, api, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('station-printer'))).width, greaterThan(250),
        reason: 'the printer\'s words on a line of their own, not one letter a line');
    expect(tester.getSize(find.byKey(const Key('piece-weight'))).width, greaterThan(300));
    expect(tester.getSize(find.byKey(const Key('piece-register'))).width, greaterThan(300));
    await register(tester, '5');
    expect(tester.takeException(), isNull);
    final row = find.byKey(const Key('station-piece-101'));
    await tester.dragUntilVisible(row, find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    final code = find.descendant(of: row, matching: find.text('KJ-000121'));
    expect(tester.getSize(code).width, greaterThan(250), reason: 'its number readable, its actions under it');
    expect(tester.getSize(find.byKey(const Key('station-last-code'))).width, greaterThan(150));
  });

  // ── ر2: four zones -- the bar, the line, the work beside its piece, the log ──

  testWidgets('the line says how far it is coded, from the server\'s figures', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    expect(tester.widget<Text>(find.byKey(const Key('station-counter'))).data,
        'رُمّز 14.37 من 30.00 جم · 1 قطعة · الباقي 15.63 جم');
    final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('station-progress')));
    expect(bar.value, closeTo(14.37 / 30.0, 0.0001));
  });

  testWidgets('a printer ready is a calm bar: no counts of nothing; how labels print is set there', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.byKey(const Key('station-queue')), findsNothing, reason: 'nothing waiting, nothing failed: not said');
    expect(find.descendant(of: find.byKey(const Key('station-bar')), matching: find.byKey(const Key('station-print-mode'))),
        findsOneWidget);
    final material = tester.widget<Material>(find.byKey(const Key('station-bar')));
    final context = tester.element(find.byKey(const Key('station-bar')));
    expect(material.color, isNot(Theme.of(context).colorScheme.errorContainer));
  });

  testWidgets('the stones behind «+ فصوص»: opened once, kept open for the line', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.byKey(const Key('piece-stones')), findsNothing);
    await tester.tap(find.byKey(const Key('piece-stones-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-stones')), '0.35');
    await register(tester, '5');
    expect(api.sent.single['stones_weight'], 0.35);
    expect(find.byKey(const Key('piece-stones')), findsOneWidget, reason: 'the next piece likely has its stones too');
  });

  testWidgets('the current piece: said before one, then its label\'s state in full', (tester) async {
    final api = _Api()..printOutcome = 'failed';
    await _open(tester, api);
    expect(find.byKey(const Key('station-current-empty')), findsOneWidget);
    await register(tester);
    final card = find.byKey(const Key('station-last'));
    expect(find.descendant(of: card, matching: find.text('فاشلة')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.byIcon(Icons.error_outline)), findsOneWidget,
        reason: 'never a colour alone: its icon and its word');
    expect(find.descendant(of: card, matching: find.text('انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة')),
        findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('طُبعت')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.byIcon(Icons.cancel)), findsNWidgets(3),
        reason: 'its three steps, none done');
    expect(find.descendant(of: card, matching: find.byKey(const Key('label-retry-101'))), findsOneWidget);
  });

  testWidgets('on a wide screen the current piece is beside the work, and the station keeps a width the eye follows',
      (tester) async {
    final api = _Api();
    await _open(tester, api, size: const Size(1800, 1400));
    await register(tester);
    final weight = tester.getRect(find.byKey(const Key('piece-weight')));
    final card = tester.getRect(find.byKey(const Key('station-last')));
    expect(card.right, lessThan(weight.left), reason: 'beside it, on its left in Arabic');
    expect(card.top, lessThan(weight.bottom));
    final line = tester.getRect(find.byKey(const Key('station-progress')));
    expect(line.width, lessThanOrEqualTo(1200));
  });

  testWidgets('a piece\'s details: its facts and its label\'s -- which print, which generation, its steps',
      (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    await tester.tap(find.descendant(of: find.byKey(const Key('station-piece-101')), matching: find.text('KJ-000121')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('piece-details-101'));
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('الطباعة الأولى')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('قُرئت وطابقت')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.byIcon(Icons.check_circle)), findsNWidgets(3));
  });

  testWidgets('five states, each its icon and its word -- the server\'s statuses, none added', (tester) async {
    final looks = {
      'pending': ('منتظرة', Icons.schedule),
      'printing': ('تُطبع الآن', Icons.print),
      'verifying': ('تُطبع الآن', Icons.print),
      'completed': ('مكتملة · الجيل 2', Icons.verified_outlined),
      'failed': ('فاشلة', Icons.error_outline),
      'needs_attention': ('مجهولة', Icons.help_outline),
    };
    for (final e in looks.entries) {
      await tester.pumpWidget(MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(body: LabelBadge(piece: {'id': 1, 'label': {'status': e.key, 'generation': 2}})),
      ));
      expect(find.text(e.value.$1), findsOneWidget, reason: e.key);
      expect(find.byIcon(e.value.$2), findsOneWidget, reason: e.key);
    }
  });

  // ── the net from the server (the owner, 20 Nov 2026) ──

  testWidgets('the weight typed is read by the server: its net, its stones, the rest after it', (tester) async {
    final api = _Api()
      ..pricedStones = true
      ..weighAnswer = {
        'weighed': {'standing_weight': 12.40, 'stones_weight': 0.35, 'stones_kind': 'priced', 'grams': 12.05,
                    'net_weight': 12.05, 'rest': 30.0, 'rest_after': 17.95},
        'refused': null,
      };
    await _open(tester, api);
    expect(find.byKey(const Key('station-stones-priced')), findsOneWidget, reason: 'the line says its stones are out of its gold');
    await tester.tap(find.byKey(const Key('piece-stones-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-weight')), '12.4');
    await tester.enterText(find.byKey(const Key('piece-weight')), '12.40');
    await tester.enterText(find.byKey(const Key('piece-stones')), '0.35');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(api.weighs, hasLength(1), reason: 'asked once the typing stops, not at each key');
    expect(api.weighs.single, {'line_id': 7, 'weight': 12.40, 'stones_weight': 0.35});
    expect(tester.widget<Text>(find.byKey(const Key('station-weighed'))).data,
        'الوزن 12.05 جم · + فصوص 0.35 جم · يبقى 17.95 جم', reason: 'priced apart: its gold, the stones added');
    expect(api.sent, isEmpty, reason: 'asked, not registered');
  });

  // The owner, 25 Nov 2026: «ماذا ان كان الفرق سالب؟» -- «ابنه».
  testWidgets('heavier than the rest by the scale\'s drift: registered with its reason, the excess the surplus',
      (tester) async {
    final api = _Api()
      ..weighAnswer = {
        'weighed': null,
        'refused': {'code': 'piece_heavier_than_rest', 'over_rest': 0.02, 'over_rest_closable': true,
                    'message': 'القطعة (30.02 جم) أثقل من باقي السطر (30.00 جم) بـ 0.02 جم'},
      };
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '30.02');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-over-rest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-close-rest-sure')));
    await tester.pumpAndSettle();
    expect(api.sent.single['weight'], 30.02);
    expect(api.sent.single['over_rest_reason'], contains('فرق الميزان'));
  });

  testWidgets('heavier beyond the drift: no offer, the refusal alone', (tester) async {
    final api = _Api()
      ..weighAnswer = {
        'weighed': null,
        'refused': {'code': 'piece_heavier_than_rest', 'over_rest': 1.0, 'over_rest_closable': false,
                    'message': 'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)'},
      };
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '31');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-over-rest')), findsNothing);
  });

  testWidgets('the refusal the press would meet is said before it', (tester) async {
    final api = _Api()
      ..weighAnswer = {
        'weighed': null,
        'refused': {'code': 'piece_heavier_than_rest', 'message': 'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)'},
      };
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '31');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('station-weighed'))).data,
        'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)');
  });

  testWidgets('a piece is said by what is sold as gold: its stones counted as gold within its weight', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('piece-stones-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-stones')), '0.35');
    await register(tester, '12.40');
    expect(find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('12.40 جم · فصوص 0.35 جم ضمن الوزن')),
        findsOneWidget, reason: 'sold at 12.40, never at its net 12.05');
  });

  // ── an unknown end: three statements, each its own (the owner, 20 Nov 2026) ──

  Future<void> openResolve(WidgetTester tester, _Api api) async {
    api.printOutcome = 'needs_attention';
    await _open(tester, api);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-resolve-101')).first);
    await tester.pumpAndSettle();
  }

  testWidgets('a reading is taken at 24 characters: the button waits for them; no code on the screen to copy',
      (tester) async {
    final api = _Api();
    await openResolve(tester, api);
    expect(find.textContaining('4B4A'), findsNothing, reason: 'the value expected is the server\'s, not shown');
    final adopt = find.byKey(const Key('resolve-adopt'));
    expect(tester.widget<FilledButton>(adopt).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('resolve-read')), '4B4A000100000000000001');
    await tester.pump();
    expect(tester.widget<FilledButton>(adopt).onPressed, isNull, reason: '22 characters: not a reading');
    expect(find.text('22 من 24 خانة'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('resolve-read')), '4b4a 0001 0000 0000 0000 0121');
    await tester.pump();
    await tester.tap(adopt);
    await tester.pumpAndSettle();
    expect(api.resolved.single['read_value'], '4B4A00010000000000000121', reason: 'its spaces and case are the typing');
  });

  testWidgets('«خرج ملصق وأتلفته» is its own statement, asked once more', (tester) async {
    final api = _Api();
    await openResolve(tester, api);
    await tester.tap(find.byKey(const Key('resolve-destroyed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resolve-destroyed-confirm')), findsOneWidget);
    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();
    expect(api.resolved, isEmpty);
    await tester.tap(find.byKey(const Key('resolve-destroyed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('resolve-destroyed-sure')));
    await tester.pumpAndSettle();
    expect(api.resolved.single, {'destroyed': true, 'attempt_id': api.resolved.single['attempt_id']});
    expect(api.resolved.single.containsKey('no_label'), isFalse, reason: 'not «لم يخرج ملصق»');
    expect(find.byKey(const Key('label-retry-101')), findsWidgets, reason: 'failed: a new label, a new generation');
  });
}
