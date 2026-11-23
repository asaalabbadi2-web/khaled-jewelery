import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'gold_price_answer.dart';

/// The server as the sales screen sees it, in memory: what it was sent is
/// kept to be read back; [hold] keeps a save in flight.
class FakeSalesApi extends ApiService {
  FakeSalesApi({
    this.categories = const [],
    this.methods = const [
      {'id': 1, 'name': 'نقداً', 'payment_type': 'cash', 'commission_rate': 0},
    ],
    this.safes = const [],
    this.settings = const {},
    this.scrapSafe,
    this.goldSafe,
    this.invoices = const {},
    this.returnLines = const {},
  });

  /// What remains of an original, by its id, where a test says it (a return
  /// before); else read from [invoices]: every line whole, what was paid refundable.
  final Map<int, Map<String, dynamic>> returnLines;

  /// Invoices by id, for the screens that open one (a return's original).
  final Map<int, Map<String, dynamic>> invoices;

  final Map<String, dynamic> settings;

  /// The «خزينة الكسر الرئيسية» the settings name, and the gold safe a
  /// sale falls back to when they name none.
  final SafeBoxModel? scrapSafe;
  final SafeBoxModel? goldSafe;
  final updated = <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> methods;
  final List<SafeBoxModel> safes;
  Completer<void>? hold;
  final added = <Map<String, dynamic>>[];

  /// What the server says besides (its number, its payment state), merged
  /// into the answer to a save (ADR-060).
  Map<String, dynamic> saveAnswer = const {};
  final customersAdded = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getGoldPrice() async => goldPriceAnswer(480.0);

  @override
  Future<List<Map<String, dynamic>>> getBranches({
    bool activeOnly = false,
  }) async => [
    {'id': 1, 'name': 'الفرع الرئيسي'},
  ];

  /// The pools' cost a gram by category (ADR-096 ت2), and what was asked.
  Map<int, double> poolCosts = const {};
  final poolAsked = <int?>[];

  @override
  Future<Map<String, dynamic>> wagePoolCost({required int karat, int? categoryId}) async {
    poolAsked.add(categoryId);
    return {'per_gram': poolCosts[categoryId], 'karat': karat, 'category_id': categoryId, 'active': true};
  }

  /// What the server holds in the stock, as it answers the sales screen.
  List<Map<String, dynamic>> stockItems = const [];
  final itemsAskedInStock = <bool?>[];

  @override
  Future<List<dynamic>> getItems({
    bool? inStockOnly,
    int? categoryId,
    int? excludeCategoryId,
  }) async {
    itemsAskedInStock.add(inStockOnly);
    return stockItems;
  }

  /// The server's answer to a piece number typed: each test says what the
  /// server reads its text as (services/pieces.piece_code is the server's).
  Map<String, Map<String, dynamic>> piecesByTyped = const {};
  final piecesAsked = <String>[];

  @override
  Future<Map<String, dynamic>> lookupPiece(String code) async {
    piecesAsked.add(code);
    final piece = piecesByTyped[code];
    if (piece == null) {
      throw ApiException(statusCode: 404, code: 'piece_unknown', message: 'لا قطعة بالرقم $code');
    }
    return {'piece': piece, 'location': {'id': 30, 'name': 'الذهب المعروض'}};
  }

  /// The tags the server knows: value -> its piece's number (an active tag).
  Map<String, String> activeTags = const {};

  @override
  Future<Map<String, dynamic>> pieceByTag(String value) async {
    final code = activeTags[value.toUpperCase()];
    if (code == null) {
      throw ApiException(statusCode: 404, code: 'tag_unknown', message: 'رقاقة غير معروفة $value — لا تُحتسب');
    }
    return {'piece': {'item_code': code, 'weight': 12.4, 'model': {'name': 'بنجرة الشمس'}}, 'tag': {'state': 'active'}};
  }

  /// The labels asked to print: (piece id, the request's body).
  final printsAsked = <(int, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> printPieceLabel(int pieceId, Map<String, dynamic> body) async {
    printsAsked.add((pieceId, body));
    return {'job': {'id': printsAsked.length, 'kind': body['kind'], 'status': body['run'] == true ? 'completed' : 'pending'}};
  }

  /// A split (ADR-099): the check answers each part's share; the split made
  /// answers [splitAnswer] and the stock becomes [stockAfterSplit].
  Map<String, dynamic> splitAnswer = const {};
  List<Map<String, dynamic>>? stockAfterSplit;
  final splitsMade = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> checkPieceSplit(int pieceId, List<Map<String, dynamic>> parts) async => {
        'split': {
          'grams': parts.fold<double>(0, (s, p) => s + (p['weight'] as num)), 'difference': 0.0, 'tolerance': 0.05,
          'total': parts.fold<double>(0, (s, p) => s + (p['weight'] as num)),
          'parts': [for (final p in parts) {...p, 'wage': 300.0}],
        },
      };

  @override
  Future<Map<String, dynamic>> splitPiece(int pieceId,
      {required List<Map<String, dynamic>> parts, required String reason, required String requestKey}) async {
    splitsMade.add({'piece_id': pieceId, 'parts': parts, 'reason': reason});
    if (stockAfterSplit != null) stockItems = stockAfterSplit!;
    return {'split': splitAnswer};
  }

  @override
  Future<List<dynamic>> getActivePaymentMethods({String? invoiceType}) async {
    // As the server filters: a method with no list is set for every type.
    activeAskedFor.add(invoiceType);
    if (invoiceType == null) return methods;
    return [
      for (final m in methods)
        if ((m['applicable_invoice_types'] as List?)?.isEmpty ?? true)
          m
        else if ((m['applicable_invoice_types'] as List).contains(invoiceType))
          m,
    ];
  }

  /// The invoice types the screens asked their methods for.
  final activeAskedFor = <String?>[];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => safes;

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => categories;

  @override
  Future<Map<String, dynamic>> getSettings() async => settings;

  /// What the screens asked the server to reverse in full.
  final reversed = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> reverseInvoice({
    required int invoiceId,
    required String reason,
    required List<Map<String, dynamic>> payments,
    Map<String, Map<String, dynamic>> tags = const {},
  }) async {
    reversed.add({'id': invoiceId, 'reason': reason, 'payments': payments, 'tags': tags});
    if (hold != null) await hold!.future;
    return {'id': 800 + reversed.length, 'invoice_type': 'مرتجع بيع'};
  }

  @override
  Future<Map<String, dynamic>> getInvoiceById(int invoiceId) async =>
      invoices[invoiceId]!;

  @override
  Future<Map<String, dynamic>> getReturnLines(int invoiceId) async {
    if (returnLines.containsKey(invoiceId)) return returnLines[invoiceId]!;
    final invoice = invoices[invoiceId]!;
    double num0(Object? v) => v is num ? v.toDouble() : 0.0;
    return {
      'invoice_id': invoiceId,
      'returned_before': false,
      'refundable': num0(invoice['amount_paid'] ?? invoice['total']),
      'lines': [
        for (final item in (invoice['items'] as List? ?? const []).cast<Map>())
          {
            'id': item['id'], 'name': item['name'], 'karat': item['karat'],
            'sold_grams': num0(item['weight']), 'remaining_grams': num0(item['weight']),
            'sold_pieces': item['quantity'] ?? 1, 'remaining_pieces': item['quantity'] ?? 1,
            'sold_amount': num0(item['price']), 'remaining_amount': num0(item['price']),
          },
      ],
    };
  }

  @override
  Future<List<dynamic>> getPaymentMethods() async => methods;

  @override
  Future<List<dynamic>> getPurchaseItems() async => [];

  @override
  Future<double?> getSuggestedPurchasePrice() async => null;

  @override
  Future<SafeBoxModel> getSafeBox(int id, {bool includeBalance = true}) async =>
      scrapSafe!;

  @override
  Future<SafeBoxModel> getDefaultSafeBox(String safeType) async {
    if (goldSafe == null) throw Exception('no gold safe');
    return goldSafe!;
  }

  @override
  Future<Map<String, dynamic>> updateUnpostedInvoice(
    int invoiceId,
    Map<String, dynamic> invoiceData,
  ) async {
    updated.add(invoiceData);
    if (hold != null) await hold!.future;
    return {'id': invoiceId, 'total': invoiceData['total'], 'items': []};
  }

  @override
  Future<Map<String, dynamic>> addCustomer(
    Map<String, dynamic> customerData,
  ) async {
    customersAdded.add(customerData);
    return {'id': 500, ...customerData};
  }

  @override
  Future<Map<String, dynamic>> addInvoice(Map<String, dynamic> invoice) async {
    added.add(invoice);
    if (hold != null) await hold!.future;
    return {
      'id': 700 + added.length,
      'total': invoice['total'],
      'amount_paid': invoice['amount_paid'],
      'items': invoice['items'],
      ...saveAnswer,
    };
  }
}
