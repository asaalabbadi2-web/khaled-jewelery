import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../utils/currency_utils.dart';
import 'confirm_financial_action.dart';

/// UI-4 (ADR-049): cancelling and deleting a voucher are asked the same way
/// from the vouchers list and from a voucher's details -- one place, where the
/// two screens each had their own copy.
///
/// What each does is the server's (routes/vouchers.py): a cancel reverses the
/// voucher's entry and safe movements, if it has an entry, and keeps the
/// voucher, cancelled, with its reason; a delete is allowed only for a voucher
/// without an entry, and leaves its trace in the audit log.

List<(String, String)> _facts(BuildContext context, Map<String, dynamic> v) {
  String currency;
  try {
    currency = context.read<SettingsProvider>().currencySymbolText;
  } catch (_) {
    currency = 'ر.س';
  }
  final cash = double.tryParse('${v['amount_cash'] ?? ''}') ?? 0;
  final gold = double.tryParse('${v['amount_gold'] ?? ''}') ?? 0;
  final party = '${v['party_name'] ?? v['receiver_name'] ?? ''}'.trim();
  return [
    if ('${v['voucher_number'] ?? ''}'.isNotEmpty)
      ('السند', '${v['voucher_number']}'),
    if (cash != 0) ('النقد', '${formatAmount(cash)} $currency'),
    if (gold != 0) ('الذهب', '${formatGrams(gold)} جم'),
    if (party.isNotEmpty) ('الطرف', party),
  ];
}

/// The reason to cancel [voucher] with, or null when the user went back.
Future<String?> confirmCancelVoucher(
  BuildContext context,
  Map<String, dynamic> voucher,
) => confirmFinancialAction(
  context,
  title: 'إلغاء السند',
  facts: _facts(context, voucher),
  effect:
      'إن كان مرحّلًا يُعكس قيده وحركة خزينته بقيد عكسي، ويبقى السند في '
      'السجل ملغًى مع سببه.',
  confirmLabel: 'إلغاء السند',
  reasonLabel: 'سبب الإلغاء',
);

/// Whether to delete [voucher].
Future<bool> confirmDeleteVoucher(
  BuildContext context,
  Map<String, dynamic> voucher,
) async =>
    await confirmFinancialAction(
      context,
      title: 'حذف السند',
      facts: _facts(context, voucher),
      effect:
          'يُحذف السند نهائيًّا، ويبقى أثره في سجل التدقيق. لا يُحذف إلا سند '
          'لم يُرحَّل؛ السند المرحّل يُلغى.',
      confirmLabel: 'حذف السند',
    ) !=
    null;
