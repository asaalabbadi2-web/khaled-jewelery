import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/spread_amount.dart';

double sum(List<double> v) => v.fold(0.0, (s, x) => s + x);

void main() {
  test('the lines come to the amount, each in whole riyals', () {
    final totals = spreadAmount(
      target: 10000,
      vatRate: 0.15,
      lines: const [
        SpreadLine(cost: 2000, weight: 3.333),
        SpreadLine(cost: 3000, weight: 5.111),
        SpreadLine(cost: 1500, weight: 2.017),
      ],
    )!;
    expect(sum(totals), closeTo(10000, 0.001));
    for (final t in totals) {
      expect(t, t.roundToDouble(), reason: 'no fraction: $totals');
    }
  });

  test('as before: the cost each line, the profit by its weight', () {
    // 2 lines of 1 g and 3 g, costs 100 and 300, no VAT, asked 600: the
    // profit 200 by weight -- 50 and 150.
    expect(
      spreadAmount(
        target: 600,
        lines: const [SpreadLine(cost: 100, weight: 1), SpreadLine(cost: 300, weight: 3)],
      ),
      [150.0, 450.0],
    );
  });

  test('the rounding\'s rest, and the amount\'s own fraction, on the heaviest line', () {
    final totals = spreadAmount(
      target: 1000.5,
      lines: const [
        SpreadLine(cost: 0, weight: 1),
        SpreadLine(cost: 0, weight: 1),
        SpreadLine(cost: 0, weight: 1.5),
      ],
    )!;
    expect(sum(totals), closeTo(1000.5, 0.001));
    expect(totals[0], totals[0].roundToDouble());
    expect(totals[1], totals[1].roundToDouble());
    expect(totals[2] % 1, closeTo(0.5, 0.001), reason: 'the heaviest carries the fraction');
  });

  test('a sale\'s stones are carried at their value, outside the profit', () {
    expect(
      spreadAmount(
        target: 700,
        lines: const [SpreadLine(cost: 100, extra: 100, weight: 1), SpreadLine(cost: 300, weight: 3)],
      ),
      [250.0, 450.0],
    );
  });

  test('nothing to spread by: null', () {
    expect(spreadAmount(target: 500, lines: const [SpreadLine(cost: 10, weight: 0)]), isNull);
    expect(spreadAmount(target: 500, lines: const []), isNull);
    expect(spreadAmount(target: 0, lines: const [SpreadLine(cost: 10, weight: 1)]), isNull);
  });
}
