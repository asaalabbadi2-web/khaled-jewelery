import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';

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
  });

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
  final customersAdded = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getGoldPrice() async => {'price_24k': 480.0};

  @override
  Future<List<Map<String, dynamic>>> getBranches({
    bool activeOnly = false,
  }) async => [
    {'id': 1, 'name': 'الفرع الرئيسي'},
  ];

  @override
  Future<List<dynamic>> getItems({
    bool? inStockOnly,
    int? categoryId,
    int? excludeCategoryId,
  }) async => [];

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
  Future<List<dynamic>> getCategories() async => categories;

  @override
  Future<Map<String, dynamic>> getSettings() async => settings;

  /// What the screens asked the server to reverse in full.
  final reversed = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> reverseInvoice({
    required int invoiceId,
    required String reason,
    required List<Map<String, dynamic>> payments,
  }) async {
    reversed.add({'id': invoiceId, 'reason': reason, 'payments': payments});
    if (hold != null) await hold!.future;
    return {'id': 800 + reversed.length, 'invoice_type': 'مرتجع بيع'};
  }

  @override
  Future<Map<String, dynamic>> getInvoiceById(int invoiceId) async =>
      invoices[invoiceId]!;

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
    };
  }
}
