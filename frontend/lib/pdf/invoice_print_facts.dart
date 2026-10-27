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

/// The payments the server recorded on an invoice: each method's name and
/// amount, in the order paid (`payments`). Lines of nothing are left out.
List<({String method, double amount})> invoicePrintPayments(Map<dynamic, dynamic> invoice) {
  final raw = invoice['payments'];
  if (raw is! List) return const [];
  return [
    for (final p in raw.whereType<Map>())
      if (_number(p['amount']).abs() > 0.005)
        (
          method: '${p['payment_method_name'] ?? p['method'] ?? ''}'.trim(),
          amount: _number(p['amount']),
        ),
  ];
}

/// What a supplier purchase leaves owed to the supplier, as the server keeps
/// it: its gold at the main karat (`total_weight_main_karat`), its wages and
/// VAT, and the cash it can be paid (`cash_obligation`) -- not its total,
/// which also holds the gold's value (models.Invoice.cash_obligation).
({double goldMain, double wages, double tax, double cashDue}) supplierPrintOwed(
  Map<dynamic, dynamic> invoice,
) => (
  goldMain: _number(invoice['total_weight_main_karat']),
  wages: _number(invoice['wage_subtotal']),
  tax: _number(invoice['total_tax']),
  cashDue: _number(invoice['cash_obligation']),
);
