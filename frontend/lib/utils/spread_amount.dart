/// The asked amount spread over an invoice's lines (the owner, 10 Nov 2026).
///
/// As before: each line its cost (and what it carries at no cost, a sale's
/// stones' value), the rest -- the profit -- by its share of the weight. Then
/// each line's total in whole riyals, and what the rounding left -- with any
/// fraction of the amount itself -- on the heaviest line: the lines come to
/// the amount to the halala, and no other line carries a fraction.
library;

class SpreadLine {
  /// What the line costs, before VAT.
  final double cost;

  /// What the line carries at its value, outside the profit (a sale's stones).
  final double extra;

  final double weight;

  const SpreadLine({required this.cost, this.extra = 0, required this.weight});
}

/// Each line's total with VAT, summing to [target]; null when the lines weigh
/// nothing (no share to spread by).
List<double>? spreadAmount({
  required double target,
  required List<SpreadLine> lines,
  double vatRate = 0,
}) {
  final weight = lines.fold<double>(0, (s, l) => s + l.weight);
  if (lines.isEmpty || weight <= 0 || target <= 0) return null;
  final factor = 1 + (vatRate > 0 ? vatRate : 0);
  final costs = lines.fold<double>(0, (s, l) => s + l.cost + l.extra);
  final profit = target / factor - costs;
  final totals = [
    for (final l in lines) ((l.cost + l.extra + profit * l.weight / weight) * factor).roundToDouble(),
  ];
  var heaviest = 0;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].weight > lines[heaviest].weight) heaviest = i;
  }
  final left = target - totals.fold<double>(0, (s, t) => s + t);
  totals[heaviest] = ((totals[heaviest] + left) * 100).roundToDouble() / 100;
  return totals;
}
