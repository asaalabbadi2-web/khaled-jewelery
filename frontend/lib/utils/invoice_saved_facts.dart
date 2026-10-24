/// What the server says of an invoice it has just saved (ADR-060 ف٠): the
/// dialog after the save reads these, not the screen's own sums.
///
/// - [number] is the invoice's number (`invoice_number`, «SELL-2026-412») --
///   the one printed and told to the customer; the row's id said «#4187».
/// - [cashDue] is measured against `cash_obligation`, the server's ceiling of
///   cash owed: for a supplier purchase it is the wage and its VAT, not the
///   total, which also holds the gold's value (models.Invoice.cash_obligation).
///   `amount_paid` already counts a barter (invoice_payment_state_service).
/// - [status] is the server's payment state: a purchase is `paid` only when
///   its cash and its gold are both settled.
class InvoiceSavedFacts {
  const InvoiceSavedFacts._({
    required this.number,
    required this.total,
    required this.paid,
    required this.cashDue,
    required this.status,
    required this.posted,
  });

  factory InvoiceSavedFacts.of(Map<String, dynamic> invoice) {
    double asDouble(Object? v) =>
        v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;
    final total = asDouble(invoice['total']);
    final paid = asDouble(invoice['amount_paid']);
    final obligation = invoice.containsKey('cash_obligation')
        ? asDouble(invoice['cash_obligation'])
        : total;
    final number = '${invoice['invoice_number'] ?? ''}'.trim();
    final due = obligation - paid;
    return InvoiceSavedFacts._(
      number: number.isNotEmpty ? number : '#${invoice['id'] ?? ''}',
      total: total,
      paid: paid,
      cashDue: due > 0.005 ? due : 0.0,
      status: '${invoice['status'] ?? ''}'.trim(),
      posted: invoice['is_posted'] == true,
    );
  }

  final String number;
  final double total;
  final double paid;
  final double cashDue;
  final String status;
  final bool posted;

  bool get settled => status == 'paid';

  /// Something is still owed: cash, or (a purchase) gold the server counts.
  bool get owes => cashDue > 0 || (status.isNotEmpty && !settled);

  /// The dialog's one line on payment: the server's state, and the cash
  /// still owed -- said once (it was said three times).
  String statusLine(String Function(double) formatCash) {
    final label = statusLabel;
    if (cashDue <= 0) return label.isEmpty ? 'لا متبقي نقدًا' : label;
    final due = 'متبقي ${formatCash(cashDue)} نقدًا';
    return label.isEmpty ? due : '$label · $due';
  }

  /// The server's payment state in words; '' when it said none.
  String get statusLabel => switch (status) {
    'paid' => 'مسدَّدة بالكامل',
    'partially_paid' => 'مسدَّدة جزئيًا',
    'unpaid' => 'غير مسدَّدة',
    _ => status,
  };
}
