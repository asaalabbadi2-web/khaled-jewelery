import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/currency_utils.dart';

/// UI-2 (ADR-049): an amount and a weight are written for reading one way.
void main() {
  const lrm = '‎';

  test('thousands separated, two places, Western digits', () {
    expect(formatAmount(2500), '2,500.00');
    expect(formatAmount(1234567.891), '1,234,567.89');
    expect(formatAmount(0), '0.00');
    expect(formatAmount(12.5), '12.50');
  });

  test('a weight has three places', () {
    expect(formatGrams(12.5), '12.500');
    expect(formatGrams(1250.1234), '1,250.123');
  });

  test('a negative is a minus sign, kept before the number in Arabic text', () {
    expect(formatAmount(-1500.5), '$lrm-1,500.50');
    expect(formatAmount(-1500.5).replaceAll(lrm, ''), '-1,500.50');
  });

  test('zero has no sign', () {
    expect(formatAmount(-0.001), '0.00');
    expect(formatGrams(-0.0001), '0.000');
  });

  test('other places when asked', () {
    expect(formatAmount(1500, decimals: 0), '1,500');
    expect(formatAmount(0.12345, decimals: 4), '0.1235');
  });
}
