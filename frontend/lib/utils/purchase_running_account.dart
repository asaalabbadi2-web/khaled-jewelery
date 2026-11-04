/// A supplier purchase's state on its running account (REPORTS ت3-2ج,
/// ADR-083; the owner 4 Nov 2026: it replaces the shown status).
///
/// The shop and its suppliers keep a running account: a voucher pays the
/// account, not an invoice, so `status` -- explicit payments only -- read
/// «غير مدفوعة» for purchases the account had paid. The server reads the
/// supplier's ledger and sends, for each posted supplier purchase,
/// `running_account`: {state, basis, shown, cash_original, cash_remaining,
/// gold_remaining}. A purchase shows `shown`; every other invoice its
/// `status`.
library;

/// The status word the invoice shows.
String shownInvoiceStatus(Map invoice) {
  final account = invoice['running_account'];
  if (account is Map && account['shown'] != null) {
    return account['shown'].toString();
  }
  return (invoice['status'] ?? '').toString();
}

/// Why a purchase's state is what it is, or null for any other invoice.
String? runningAccountReason(Map invoice) {
  final account = invoice['running_account'];
  if (account is! Map) return null;
  return switch (account['basis']) {
    'evidence' => 'سُدّدت بسند يسمّيها',
    'running_account' => 'سُدّدت على الحساب الجاري، الأقدم أولًا',
    'at_once' => 'سُدّدت في قيد شرائها',
    'reversal' => 'عُكس قيدها',
    _ =>
      account['state'] == 'not_on_account'
          ? 'لا سطر لها على حساب المورد'
          : null,
  };
}

/// Its cash debt as the running account closed it: (paid, remaining) --
/// none for one the supplier's ledger does not hold -- or null when the
/// invoice is not read on a running account.
(double, double)? runningAccountCash(Map invoice) {
  final account = invoice['running_account'];
  if (account is! Map) return null;
  if (account['state'] == 'not_on_account') return (0.0, 0.0);
  final original = (account['cash_original'] as num?)?.toDouble() ?? 0.0;
  final remaining = (account['cash_remaining'] as num?)?.toDouble() ?? 0.0;
  final left = remaining < 0 ? 0.0 : remaining;
  final paid = original - left;
  return (paid < 0 ? 0.0 : paid, left);
}
