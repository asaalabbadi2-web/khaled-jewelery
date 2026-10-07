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
  });

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
  Future<List<dynamic>> getActivePaymentMethods() async => methods;

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
