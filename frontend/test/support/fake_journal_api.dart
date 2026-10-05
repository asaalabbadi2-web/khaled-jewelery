import 'dart:async';

import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';

/// The server, as the journal entry screen sees it: a chart of accounts, and
/// the entries it was asked to save. [hold] keeps a save in flight.
class FakeJournalApi extends ApiService {
  FakeJournalApi({this.accounts = sampleAccounts})
    : super(baseUrl: 'http://fake.test');

  final List<Map<String, dynamic>> accounts;
  final added = <Map<String, dynamic>>[];
  final updated = <Map<String, dynamic>>[];
  Completer<void>? hold;

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async =>
      List<dynamic>.from(accounts); // as decoded JSON: untyped

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [];

  @override
  Future<Map<String, dynamic>> addJournalEntry(
    Map<String, dynamic> entryData,
  ) async {
    added.add(entryData);
    if (hold != null) await hold!.future;
    return {'id': added.length};
  }

  @override
  Future<void> updateJournalEntry(
    int id,
    Map<String, dynamic> entryData,
  ) async {
    updated.add(entryData);
    if (hold != null) await hold!.future;
  }

  static const sampleAccounts = <Map<String, dynamic>>[
    {
      'id': 1,
      'account_number': '1',
      'name': 'الأصول',
      'transaction_type': 'cash',
    },
    {
      'id': 11,
      'account_number': '1110',
      'name': 'الصندوق الرئيسي',
      'parent_id': 1,
      'transaction_type': 'cash',
      'balances': {'cash': 12400.0},
    },
    {
      'id': 12,
      'account_number': '2211',
      'name': 'مؤسسة النور',
      'parent_id': 1,
      'transaction_type': 'cash',
      'balances': {'cash': -3000.0},
    },
    {
      'id': 13,
      'account_number': '1310',
      'name': 'مخزون الذهب',
      'parent_id': 1,
      'transaction_type': 'gold',
      'tracks_weight': true,
      'balances': {
        'cash': 0.0,
        'weight': {'total': 10.5},
      },
    },
  ];
}
