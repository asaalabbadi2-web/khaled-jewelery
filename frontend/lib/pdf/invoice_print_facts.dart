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
