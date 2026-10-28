import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'gold_price_answer.dart';

/// The server, as the purchase invoice screen sees it: one branch, one
/// supplier, a gold price, a bank transfer method, a bank and a 21k gold safe,
/// and the invoices it was asked to save. [hold] keeps a save in flight.
/// Values are fixed as the server would return them; no accounting is faked.
class FakePurchaseApi extends ApiService {
  FakePurchaseApi({this.settings = const {}, this.statement = const {}})
    : super(baseUrl: 'http://fake.test');

  final Map<String, dynamic> settings;

  /// What the 21k gold safe holds, as the server sends it to a user who may
  /// see it (ADR-036) -- the safe then one of our stock safes (ADR-045).
  /// Null: no balance sent, as to a seller.
  double? goldSafeHolds;

  /// The supplier's statement as the server reports it: debit minus credit.
  final Map<String, dynamic> statement;
  final added = <Map<String, dynamic>>[];

  /// What the server says besides (its number, its payment state), merged
  /// into the answer to a save (ADR-060).
  Map<String, dynamic> saveAnswer = const {};
  Completer<void>? hold;

  @override
  Future<List<Map<String, dynamic>>> getBranches({
    bool activeOnly = false,
  }) async => [
    {'id': 1, 'name': 'الفرع الرئيسي'},
  ];

  @override
  Future<List<dynamic>> getSuppliers() async => [
    {
      'id': 1,
      'name': 'مصنع الريّان للذهب',
      'default_wage_type': 'cash',
      'tax_number': '300000000000003',
    },
    {'id': 2, 'name': 'مؤسسة النور', 'default_wage_type': 'cash'},
  ];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [];

  @override
  Future<Map<String, dynamic>> getGoldPrice() async =>
      goldPriceAnswer(420.0, ounceUsd: 2650.0);

  @override
  Future<List<dynamic>> getActivePaymentMethods({String? invoiceType}) async =>
      [
        {'id': 1, 'name': 'تحويل بنكي', 'payment_type': 'bank_transfer'},
      ];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [
    SafeBoxModel.fromJson({
      'id': 4,
      'name': 'البنك الأهلي',
      'safe_type': 'bank',
      'account_id': 40,
      'is_default': true,
    }),
    SafeBoxModel.fromJson({
      'id': 5,
      'name': 'خزينة ذهب ٢١',
      'safe_type': 'gold',
      'account_id': 50,
      'karat': 21,
      'is_default': true,
      if (goldSafeHolds != null) ...{
        'stock_location': 'scrap',
        'balance': {
          'cash': 0.0,
          'weight': {'18k': 0.0, '21k': goldSafeHolds, '22k': 0.0, '24k': 0.0},
        },
      },
    }),
  ];

  @override
  Future<Map<String, dynamic>> getSettings() async => {
    'main_karat': 21,
    'manufacturing_wage_mode': 'expense',
    ...settings,
  };

  /// The server's preview of the purchase (ADR-060 ف٣): what the save would
  /// do to what we owe the supplier -- fixed, as the server would say it
  /// (debit minus credit, negative is owed). [previewRefusal], when set, is
  /// thrown instead; [previewed] are the requests the screen asked about.
  Map<String, dynamic> preview = const {
    'now': {'cash': 0.0, 'gold_main': 0.0},
    'after': {'cash': -500.0, 'gold_main': -10.0},
  };
  Object? previewRefusal;
  final previewed = <Map<String, dynamic>>[];

  /// Answers in turn, each after its delay -- an earlier request answered
  /// after a later one (the screen keeps the latest). When none is left, the
  /// [preview] at once.
  final previewScript = <(Duration, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> previewSupplierPurchase(
    Map<String, dynamic> invoice,
  ) async {
    previewed.add(invoice);
    final refusal = previewRefusal;
    if (refusal != null) throw refusal;
    if (previewScript.isNotEmpty) {
      final (delay, answer) = previewScript.removeAt(0);
      await Future<void>.delayed(delay);
      return answer;
    }
    return preview;
  }

  @override
  Future<Map<String, dynamic>> getSupplierStatement(
    int supplierId, {
    bool includeCancelled = false,
  }) async => {
    'closing_balance_cash': 0,
    'closing_balance_gold_normalized': 0,
    ...statement,
  };

  @override
  Future<Map<String, dynamic>> addInvoice(Map<String, dynamic> invoice) async {
    added.add(invoice);
    if (hold != null) await hold!.future;
    return {
      'id': 900 + added.length,
      'total': invoice['total'],
      'items': [],
      ...saveAnswer,
    };
  }

  final updated = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> updateUnpostedInvoice(
    int invoiceId,
    Map<String, dynamic> invoice,
  ) async {
    updated.add(invoice);
    return {'id': invoiceId, 'total': invoice['total'], 'items': []};
  }
}
