import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';

/// The server, as the clearing settlement screen sees it. The Mada box holds
/// the three payments of 5 Oct 2026 (production backup of 6 Oct): 3,050 for
/// SELL-2026-1593, then 330 and 90 for SELL-2026-1596.
class FakeClearingApi extends ApiService {
  FakeClearingApi() : super(baseUrl: 'http://fake.test');

  /// Every createClearingSettlement call: the ids sent, and the gross.
  final settlements = <({List<int>? ids, double gross})>[];

  static const pending = <Map<String, dynamic>>[
    {
      'tx_id': 3520,
      'invoice_payment_id': 3520,
      'invoice_id': 3242,
      'invoice_number': 'SELL-2026-1593',
      'amount': 3050.0,
      'date': '2026-10-05T14:45:46',
      'type': 'invoice_payment',
    },
    {
      'tx_id': 3526,
      'invoice_payment_id': 3526,
      'invoice_id': 3247,
      'invoice_number': 'SELL-2026-1596',
      'amount': 330.0,
      'date': '2026-10-05T15:52:33',
      'type': 'invoice_payment',
    },
    {
      'tx_id': 3527,
      'invoice_payment_id': 3527,
      'invoice_id': 3247,
      'invoice_number': 'SELL-2026-1596',
      'amount': 90.0,
      'date': '2026-10-05T15:52:33',
      'type': 'invoice_payment',
    },
  ];

  @override
  Future<List<SafeBoxModel>> getPaymentSafeBoxes() async => [
    SafeBoxModel(id: 32, name: 'مدى', safeType: 'clearing', accountId: 777),
    SafeBoxModel(
      id: 37,
      name: 'خزينة بنك الرياض',
      safeType: 'bank',
      accountId: 790,
    ),
  ];

  @override
  Future<List<dynamic>> getActivePaymentMethods({String? invoiceType}) async =>
      [
        {
          'id': 10,
          'name': 'مدى',
          'default_safe_box_id': 32,
          'settlement_bank_safe_box_id': 37,
          'commission_timing': 'invoice',
        },
      ];

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [];

  @override
  Future<Map<String, dynamic>> getSettings() async => {
    'tax_enabled': true,
    'tax_rate': 0.15,
  };

  @override
  Future<Map<String, dynamic>> getPendingSettlementTransactions({
    required int clearingSafeBoxId,
  }) async => {
    'due_amount': 3470.0,
    'tx_count_for_fee': 3,
    'transactions': List<Map<String, dynamic>>.from(pending),
  };

  @override
  Future<Map<String, dynamic>> getVouchers({
    int page = 1,
    int perPage = 20,
    String? type,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    String? searchType,
    String? creator,
    String? party,
    String? sortBy,
    String? sortOrder,
    String? referenceType,
    int? referenceId,
  }) async => {'vouchers': []};

  @override
  Future<Map<String, dynamic>> createClearingSettlement({
    required int clearingSafeBoxId,
    required int bankSafeBoxId,
    required double grossAmount,
    double feeAmount = 0.0,
    int? feeAccountId,
    DateTime? settlementDate,
    String? referenceNumber,
    String? notes,
    String? description,
    String? createdBy,
    List<int>? invoicePaymentIds,
  }) async {
    settlements.add((ids: invoicePaymentIds, gross: grossAmount));
    return {
      'voucher': {'voucher_number': 'AV-TEST'},
    };
  }
}
