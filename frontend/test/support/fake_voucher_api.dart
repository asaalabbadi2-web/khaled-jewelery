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
  });

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
  ) async => [];

  @override
  Future<List<Map<String, dynamic>>> getSupplierOpenGoldObligations(
    int supplierId,
  ) async => [];

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
