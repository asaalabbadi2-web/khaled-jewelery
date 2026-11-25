/// What a payment method deducts from a payment: its rate and its fixed amount
/// a transaction (COMMISSION-3, the owner 29 Oct 2026 -- the screens took the
/// rate alone). The server's computation (backend/accounting/
/// payment_commission.py), shown while the payment is typed; the invoice keeps
/// the server's. Its VAT is the commission's.
///
/// ADR-100 (the owner, 24 Nov 2026), for any method of the kind, by its
/// settings: plans (a payment takes its plan's rate), the rounding (half up
/// or half to even), and a part of the rate refunded on a return, rounded
/// apart with each part's VAT. In whole halalas: 2,850 at 6.99 % and 1.50 is
/// 200.715, half up 200.72.
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

  /// *installments*: the plan the payment names, when its method has plans;
  /// none named, the method's own rate (what the server refuses on a sale).
  factory PaymentFee.of(
    Map<String, dynamic> method,
    double amount, {
    required double vatRate,
    int? installments,
  }) {
    final plans = plansOf(method);
    final rate = installments != null && plans.containsKey(installments)
        ? plans[installments]!
        : _asDouble(method['commission_rate']);
    final fixed = _asDouble(method['commission_fixed_amount']);
    final even = '${method['commission_rounding'] ?? 'half_up'}' == 'half_even';
    final amountCents = (amount * 100).round();
    final rateMilli = (rate * 1000).round(); // thousandths of a percent
    final fixedCents = (fixed * 100).round();
    final vatBasis = (vatRate.abs() * 10000).round(); // ten-thousandths
    var refundMilli = (_asDouble(method['commission_refundable_rate']) * 1000).round();
    if (refundMilli > rateMilli) refundMilli = rateMilli;
    int share(int milli) => _divide(amountCents * milli, 100000, even);
    int vatOf(int cents) => cents > 0 ? _divide(cents * vatBasis, 10000, even) : 0;
    var commissionCents = 0;
    var vatCents = 0;
    if (amountCents > 0 && (rateMilli > 0 || fixedCents > 0)) {
      if (refundMilli <= 0) {
        commissionCents = share(rateMilli) + fixedCents;
        vatCents = vatOf(commissionCents);
      } else {
        final parts = [share(refundMilli), share(rateMilli - refundMilli), fixedCents];
        commissionCents = parts.fold(0, (a, b) => a + b);
        vatCents = parts.fold(0, (a, p) => a + vatOf(p));
      }
    }
    return PaymentFee(
      rate: rate,
      fixed: fixed,
      commission: commissionCents / 100,
      vat: vatCents / 100,
      net: (amountCents - commissionCents - vatCents) / 100,
    );
  }

  /// {installments: rate} of the method's plans; empty for a method without.
  static Map<int, double> plansOf(Map<String, dynamic> method) {
    final raw = method['plans'];
    if (raw is! List) return const {};
    final plans = <int, double>{};
    for (final p in raw) {
      if (p is! Map) continue;
      final n = int.tryParse('${p['installments']}');
      if (n == null || n <= 0) continue;
      plans[n] = _asDouble(p['commission_rate']);
    }
    return Map.fromEntries(plans.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  /// A plan said as Arabic counts it (the owner, 24 Nov 2026: «12 دفعة وليس
  /// 12 دفعات»): دفعة واحدة، دفعتان، 3–10 دفعات، 11 فأكثر دفعة.
  static String installmentsLabel(int n) {
    if (n == 1) return 'دفعة واحدة';
    if (n == 2) return 'دفعتان';
    if (n >= 3 && n <= 10) return '$n دفعات';
    return '$n دفعة';
  }

  /// The plans by their rate, each said as Arabic counts its last number:
  /// «2، 3، 4 دفعات: 6.99%»، «6، 12 دفعة: 5.99%» -- highest rate first.
  static List<String> planGroups(Map<String, dynamic> method) {
    final byRate = <double, List<int>>{};
    for (final MapEntry(key: n, value: r) in plansOf(method).entries) {
      (byRate[r] ??= []).add(n);
    }
    String pct(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    final rates = byRate.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final r in rates)
        () {
          final ns = byRate[r]!..sort();
          final head = ns.sublist(0, ns.length - 1).map((n) => '$n، ').join();
          final last = ns.length == 1 ? installmentsLabel(ns.last) : '${ns.last} ${installmentsLabel(ns.last).split(' ').last}';
          return '$head$last: ${pct(r)}%';
        }(),
    ];
  }

  /// «0.8%», «6.99% + 1.5», «1.5» -- what the method deducts, said once.
  static String label(double rate, double fixed) {
    String n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    if (rate > 0 && fixed > 0) return '${n(rate)}% + ${n(fixed)}';
    if (rate > 0) return '${n(rate)}%';
    return fixed > 0 ? n(fixed) : '';
  }

  /// A method's label: with plans, their rates' range -- «5.99–6.99% + 1.5».
  static String methodLabel(Map<String, dynamic> method) {
    final plans = plansOf(method);
    final fixed = _asDouble(method['commission_fixed_amount']);
    if (plans.isEmpty) return label(_asDouble(method['commission_rate']), fixed);
    final rates = plans.values.toSet().toList()..sort();
    String n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    final span = rates.length == 1 ? n(rates.first) : '${n(rates.first)}–${n(rates.last)}';
    return fixed > 0 ? '$span% + ${n(fixed)}' : '$span%';
  }

  /// numerator / denominator to a whole, half up or half to even.
  static int _divide(int numerator, int denominator, bool even) {
    final q = numerator ~/ denominator;
    final twice = 2 * (numerator % denominator);
    if (twice > denominator) return q + 1;
    if (twice == denominator) return even ? (q.isOdd ? q + 1 : q) : q + 1;
    return q;
  }

  static double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0.0;
  }
}
