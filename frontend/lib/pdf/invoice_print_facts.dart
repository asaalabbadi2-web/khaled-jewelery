/// What a printed invoice says of its lines, read as the server keeps them.
///
/// A line's `weight` is the line's own -- all its pieces together: the
/// server adds the lines' weights to the invoice's (add_invoice), never a
/// weight times a count. The print multiplied it by `quantity`: a line of two
/// pieces weighing 11.3 g was printed 22.6 g, and its price per gram halved
/// (612 lines on the 27 Oct 2026 copy).
library;

double _number(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

/// A line's weight: its own, whatever its count.
double invoiceLineWeight(Map<dynamic, dynamic> item) {
  final weight = _number(item['weight']);
  return weight > 0 ? weight : _number(item['total_weight']);
}

/// A karat as a person reads it: 21, not 21.0.
String invoiceKaratText(Object? karat) {
  final k = _number(karat);
  if (k <= 0) return (karat ?? '').toString().trim();
  return k == k.roundToDouble() ? '${k.round()}' : '$k';
}

/// The lines' weights by karat, in the order the karats first appear.
Map<String, double> invoiceWeightByKarat(Iterable<Map<dynamic, dynamic>> items) {
  final out = <String, double>{};
  for (final item in items) {
    final weight = invoiceLineWeight(item);
    final karat = invoiceKaratText(item['karat']);
    if (weight <= 0 || karat.isEmpty) continue;
    out[karat] = (out[karat] ?? 0) + weight;
  }
  return out;
}

/// A supplier's invoice -- its party is the supplier, not a customer.
bool isSupplierInvoiceType(Object? type) {
  final kind = (type ?? '').toString().trim();
  return kind == 'شراء' || kind == 'مرتجع شراء (مورد)';
}

/// The payments the server recorded on an invoice (`payments`), one line a
/// method -- its payments added, in the order the methods were first used.
/// SELL-2026-1735 was paid in five payments, two of them «مدى»; printed one
/// to a line, the payment box ran long (the owner, 28 Oct 2026). Lines of
/// nothing are left out.
List<({String method, double amount})> invoicePrintPayments(Map<dynamic, dynamic> invoice) {
  final raw = invoice['payments'];
  if (raw is! List) return const [];
  final byMethod = <String, double>{};
  for (final p in raw.whereType<Map>()) {
    final amount = _number(p['amount']);
    if (amount.abs() <= 0.005) continue;
    final method = '${p['payment_method_name'] ?? p['method'] ?? ''}'.trim();
    byMethod[method] = (byMethod[method] ?? 0) + amount;
  }
  return [for (final e in byMethod.entries) (method: e.key, amount: e.value)];
}

/// What a supplier purchase leaves owed to the supplier, as the server keeps
/// it: its gold at the main karat (`total_weight_main_karat`), its wages and
/// VAT, and the cash it can be paid (`cash_obligation`) -- not its total,
/// which also holds the gold's value (models.Invoice.cash_obligation).
///
/// What matters is the gold's weight, the wages and the VAT when there is
/// any; the gold's cash value (`gold_subtotal`) is said only to explain
/// (the owner, 28 Oct 2026).
({double goldMain, double wages, double tax, double cashDue, double goldValue}) supplierPrintOwed(
  Map<dynamic, dynamic> invoice,
) => (
  goldMain: _number(invoice['total_weight_main_karat']),
  wages: _number(invoice['wage_subtotal']),
  tax: _number(invoice['total_tax']),
  cashDue: _number(invoice['cash_obligation']),
  goldValue: _number(invoice['gold_subtotal']),
);
