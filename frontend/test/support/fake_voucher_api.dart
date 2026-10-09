import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/employee_model.dart';
import 'package:frontend/models/safe_box_model.dart';

/// The server as the voucher screen sees it, in memory: a supplier with its
/// account, a cash safe and a gold safe; what it is sent is kept to be read
/// back; [hold] keeps a save in flight.
class FakeVoucherApi extends ApiService {
  FakeVoucherApi({
    this.suppliers = const [
      {'id': 5, 'name': 'مورد الذهب', 'account_id': 50},
    ],
    this.similar = const [],
    this.openCash = const [],
    this.openGold = const [],
    this.plan,
  });

  /// The supplier's invoices still owing cash, and gold.
  final List<Map<String, dynamic>> openCash;
  final List<Map<String, dynamic>> openGold;

  /// What the server answers for a payment over the chosen invoices; none
  /// puts it all on account.
  final Map<String, dynamic>? plan;
  final planAsked = <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> suppliers;

  /// What the server says looks like the voucher about to be saved.
  final List<Map<String, dynamic>> similar;

  final created = <Map<String, dynamic>>[];
  final similarAsked = <Map<String, dynamic>>[];
  Completer<void>? hold;

  @override
  Future<List<dynamic>> getCustomers() async => [];

  @override
  Future<List<dynamic>> getSuppliers() async => suppliers;

  @override
  Future<Map<String, dynamic>> getEmployees({
    int page = 1,
    int perPage = 20,
    String? search,
    String? department,
    bool? isActive = true,
    bool showAll = false,
  }) async => {'employees': <EmployeeModel>[]};

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [
    {'id': 50, 'account_number': '2200001', 'name': 'مورد الذهب'},
    {'id': 70, 'account_number': '1100001', 'name': 'الصندوق'},
    {'id': 80, 'account_number': '1310001', 'name': 'خزينة الذهب'},
  ];

  @override
  Future<Map<String, dynamic>> getAppConfig() async => {};

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [
    SafeBoxModel(
      id: 7,
      name: 'الصندوق',
      safeType: 'cash',
      accountId: 70,
      isDefault: true,
    ),
    SafeBoxModel(
      id: 8,
      name: 'خزينة الذهب',
      safeType: 'gold',
      accountId: 80,
      karat: 21,
      isDefault: true,
    ),
  ];

  @override
  Future<Map<String, dynamic>> getSafeBoxLedgerBalance(
    int safeBoxId, {
    String? from,
    String? to,
  }) async => {'cash_balance': 100000.0};

  @override
  Future<List<Map<String, dynamic>>> getSupplierOpenCashObligations(
    int supplierId,
  ) async => openCash;

  @override
  Future<List<Map<String, dynamic>>> getSupplierOpenGoldObligations(
    int supplierId,
  ) async => openGold;

  @override
  Future<Map<String, dynamic>> getSupplierPaymentPlan({
    required int supplierId,
    required List<int> invoiceIds,
    required double cash,
    required List<Map<String, dynamic>> gold,
  }) async {
    planAsked.add({'supplier_id': supplierId, 'invoice_ids': invoiceIds,
                   'cash': cash, 'gold': gold});
    return plan ??
        {'cash': [], 'gold': [], 'cash_on_account': cash,
         'gold_on_account_main_karat': 0.0, 'invoices': []};
  }

  @override
  Future<List<Map<String, dynamic>>> similarVouchers(
    Map<String, dynamic> voucherData,
  ) async {
    similarAsked.add(voucherData);
    return similar;
  }

  @override
  Future<Map<String, dynamic>> createVoucher(
    Map<String, dynamic> voucherData,
  ) async {
    created.add(voucherData);
    if (hold != null) await hold!.future;
    return {'id': 900 + created.length, ...voucherData};
  }
}
