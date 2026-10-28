// OFFICE-PRICE-1: a screen reads each karat's price as the server makes it --
// the closing office's, not 24k times its fineness.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/gold_prices.dart';

void main() {
  // Dewan Al Dahab's figures, 28 Oct 2026: 21k is not 495.59 x 21/24 (433.64).
  final answer = {
    'price_24k': 495.59,
    'price_usd_per_oz': 4066.0,
    'prices_per_gram': {
      '24': {'sell': 495.59, 'buy': 490.63},
      '22': {'sell': 453.45, 'buy': 448.92},
      '21': {'sell': 432.84, 'buy': 428.51},
      '18': {'sell': 370.79, 'buy': 367.08},
    },
  };

  test('each karat is the server\'s own price', () {
    final prices = GoldPrices.fromResponse(answer);
    expect(prices.of(21), 432.84);
    expect(prices.of(18), 370.79);
    expect(prices.k24, 495.59);
    expect(prices.ounceUsd, 4066.0);
  });

  test('the day\'s opening is the server\'s, each karat its own', () {
    final opening = GoldPrices.openingFromResponse({
      'opening_price_usd_per_oz': 4050.0,
      'opening_prices_per_gram': {'21': {'sell': 431.10, 'buy': 426.79}},
    });
    expect(opening.of(21), 431.10);
    expect(opening.ounceUsd, 4050.0);
  });

  test('the buy price is the server\'s too', () {
    expect(GoldPrices.fromResponse(answer, buy: true).of(21), 428.51);
  });

  test('no answer, no price', () {
    expect(GoldPrices.fromResponse(null).known, isFalse);
    expect(GoldPrices.none.of(21), 0.0);
  });
}
