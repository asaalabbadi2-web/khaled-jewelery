import 'dart:async';
import 'dart:convert';

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
    this.customers = const [
      {'id': 3, 'name': 'عميل الصاغة', 'account_id': 30},
    ],
    this.similar = const [],
    this.openCash = const [],
    this.openGold = const [],
    this.plan,
    this.failLoads = 0,
    this.appConfig = const {},
  });

  /// What /app-config says: the account groups a screen filters by.
  final Map<String, dynamic> appConfig;

  /// The supplier's invoices still owing cash, and gold.
  final List<Map<String, dynamic>> openCash;
  final List<Map<String, dynamic>> openGold;

  /// What the server answers for a payment over the chosen invoices; none
  /// puts it all on account.
  final Map<String, dynamic>? plan;
  final planAsked = <Map<String, dynamic>>[];

  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> customers;

  /// What the server says looks like the voucher about to be saved.
  final List<Map<String, dynamic>> similar;

  final created = <Map<String, dynamic>>[];
  final similarAsked = <Map<String, dynamic>>[];
  Completer<void>? hold;

  @override
  Future<List<dynamic>> getCustomers() async => customers;

  /// How many of the next loads of the screen's data fail (ADR-050 ر٠).
  int failLoads;

  @override
  Future<List<dynamic>> getSuppliers() async {
    if (failLoads > 0) {
      failLoads--;
      throw ApiException.text('تعذّر الوصول إلى الخادم');
    }
    return suppliers;
  }

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
    {'id': 30, 'account_number': '1200001', 'name': 'عميل الصاغة'},
    {'id': 50, 'account_number': '2200001', 'name': 'مورد الذهب'},
    // The supplier's weight twin: where its gold line is stored.
    {'id': 51, 'account_number': '72200001', 'name': 'مورد الذهب وزني'},
    {
      'id': 70,
      'account_number': '1100001',
      'name': 'الصندوق',
      'balances': {'cash': 100000.0},
    },
    {'id': 80, 'account_number': '1310001', 'name': 'خزينة الذهب'},
    // Expenses: a purchase under cost of sales, the first operating one in
    // the tree, and the one meant.
    {'id': 93, 'account_number': '511', 'name': 'مشتريات ذهب جديد من العملاء'},
    {'id': 91, 'account_number': '5220', 'name': 'خسارة الوزن (الفقد)'},
    {'id': 92, 'account_number': '5420', 'name': 'كهرباء'},
  ];

  @override
  Future<Map<String, dynamic>> getAppConfig() async => appConfig;

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
      // Its weight on the safe itself, as the app reads it: the accounts
      // come without balances.
      balance: BalanceInfo(
        cash: 0,
        weight: WeightBalance(
          karat18: 0,
          karat21: 410.6,
          karat22: 0,
          karat24: 0,
          total: 410.6,
        ),
      ),
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
    planAsked.add({
      'supplier_id': supplierId,
      'invoice_ids': invoiceIds,
      'cash': cash,
      'gold': gold,
    });
    return plan ?? _spread(invoiceIds, cash, gold);
  }

  /// The cash spread as the server spreads it (services/supplier_payment_plan):
  /// over the chosen invoices oldest first, each taking what it owes; the
  /// rest on account; a chosen one it does not reach, unreached.
  Map<String, dynamic> _spread(
    List<int> ids,
    double cash,
    List<Map<String, dynamic>> gold,
  ) {
    final byId = <int, Map<String, dynamic>>{};
    for (final r in [...openCash, ...openGold]) {
      byId.putIfAbsent((r['invoice_id'] as num).toInt(), () => {}).addAll(r);
    }
    final chosen = byId.values
        .where((r) => ids.contains((r['invoice_id'] as num).toInt()))
        .toList()
      ..sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    var left = cash;
    final splits = <Map<String, dynamic>>[];
    for (final r in chosen) {
      final take = left < (r['open_cash'] as num) ? left : (r['open_cash'] as num).toDouble();
      if (take > 0.004) {
        splits.add({'invoice_id': r['invoice_id'], 'amount': take});
        left -= take;
      }
    }
    // Gold by its main-karat (21) worth, over what each still owes in gold.
    var goldLeft = gold.fold<double>(
      0,
      (t, g) => t + (g['weight'] as num) * (g['karat'] as num) / 21,
    );
    final goldSplits = <Map<String, dynamic>>[];
    for (final r in chosen) {
      final room = ((r['open_main_karat'] as num?) ?? 0).toDouble();
      final take = goldLeft < room ? goldLeft : room;
      if (take > 0.0004) {
        goldSplits.add({'invoice_id': r['invoice_id'], 'karat': 21, 'weight': take});
        goldLeft -= take;
      }
    }
    final reached = {
      for (final s in [...splits, ...goldSplits]) s['invoice_id'],
    };
    return {
      'cash': splits,
      'gold': goldSplits,
      'cash_on_account': left,
      'gold_on_account_main_karat': goldLeft,
      'unreached': [
        for (final r in chosen)
          if (!reached.contains(r['invoice_id'])) r['invoice_id'],
      ],
      'invoices': [
        for (final r in chosen)
          {'invoice_id': r['invoice_id'], 'invoice_number': r['invoice_number'], 'date': r['date']},
      ],
    };
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
    // What was sent, as it was sent: the screen goes on using its map.
    created.add(jsonDecode(jsonEncode(voucherData)) as Map<String, dynamic>);
    if (hold != null) await hold!.future;
    return {
      'id': 900 + created.length,
      'voucher_number': 'PV-2026-${(900 + created.length).toString().padLeft(5, '0')}',
      'status': 'approved',
      ...voucherData,
    };
  }

  /// Edits of a saved voucher, as they were sent.
  final updated = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> updateVoucher(
    int id,
    Map<String, dynamic> voucherData,
  ) async {
    updated.add(jsonDecode(jsonEncode(voucherData)) as Map<String, dynamic>);
    return {'id': id, 'voucher_number': 'PV-2026-00077', 'status': 'pending'};
  }

  /// Vouchers cancelled, with the reason given (ADR-049: one is asked).
  final cancelled = <(int, String)>[];

  @override
  Future<Map<String, dynamic>> cancelVoucher(
    int voucherId,
    String reason,
  ) async {
    cancelled.add((voucherId, reason));
    return {'id': voucherId, 'status': 'cancelled'};
  }
}
