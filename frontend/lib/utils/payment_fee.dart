/// What a payment method deducts from a payment: its rate and its fixed amount
/// a transaction (COMMISSION-3, the owner 29 Oct 2026 -- the screens took the
/// rate alone). The server's computation (backend/accounting/
/// payment_commission.py), shown while the payment is typed; the invoice keeps
/// the server's. Its VAT is the commission's.
class PaymentFee {
  const PaymentFee({
    required this.rate,
    required this.fixed,
    required this.commission,
    required this.vat,
    required this.net,
  });

  final double rate;
  final double fixed;
  final double commission;
  final double vat;
  final double net;

  factory PaymentFee.of(
    Map<String, dynamic> method,
    double amount, {
    required double vatRate,
  }) {
    final rate = _asDouble(method['commission_rate']);
    final fixed = _asDouble(method['commission_fixed_amount']);
    final commission = amount <= 0 || (rate <= 0 && fixed <= 0)
        ? 0.0
        : _round2(amount * rate / 100 + fixed);
    final vat = commission > 0 ? _round2(commission * vatRate.abs()) : 0.0;
    return PaymentFee(
      rate: rate,
      fixed: fixed,
      commission: commission,
      vat: vat,
      net: _round2(amount - commission - vat),
    );
  }

  /// «0.8%», «6.99% + 1.5», «1.5» -- what the method deducts, said once.
  static String label(double rate, double fixed) {
    String n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    if (rate > 0 && fixed > 0) return '${n(rate)}% + ${n(fixed)}';
    if (rate > 0) return '${n(rate)}%';
    return fixed > 0 ? n(fixed) : '';
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  static double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0.0;
  }
}
