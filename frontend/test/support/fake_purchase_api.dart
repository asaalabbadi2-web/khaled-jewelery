import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';

/// The server, as the purchase invoice screen sees it: one branch, one
/// supplier, a gold price, a bank transfer method, a bank and a 21k gold safe,
/// and the invoices it was asked to save. [hold] keeps a save in flight.
/// Values are fixed as the server would return them; no accounting is faked.
class FakePurchaseApi extends ApiService {
  FakePurchaseApi({this.settings = const {}, this.statement = const {}})
    : super(baseUrl: 'http://fake.test');

  final Map<String, dynamic> settings;

  /// The supplier's statement as the server reports it: debit minus credit.
  final Map<String, dynamic> statement;
  final added = <Map<String, dynamic>>[];
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
  Future<List<dynamic>> getCategories() async => [];

  @override
  Future<Map<String, dynamic>> getGoldPrice() async => {
    'price_24k': 420.0,
    'price_usd_per_oz': 2650.0,
  };

  @override
  Future<List<dynamic>> getActivePaymentMethods() async => [
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
    }),
  ];

  @override
  Future<Map<String, dynamic>> getSettings() async => {
    'main_karat': 21,
    'manufacturing_wage_mode': 'expense',
    ...settings,
  };

  @override
  Future<Map<String, dynamic>> getSupplierStatement(int supplierId) async => {
    'closing_balance_cash': 0,
    'closing_balance_gold_normalized': 0,
    ...statement,
  };

  @override
  Future<Map<String, dynamic>> addInvoice(Map<String, dynamic> invoice) async {
    added.add(invoice);
    if (hold != null) await hold!.future;
    return {'id': 900 + added.length, 'total': invoice['total'], 'items': []};
  }
}
