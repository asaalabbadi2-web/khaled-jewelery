import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils.dart';

/// PURCHASE-UX-3: an Arabic keyboard types the decimal separator «٫»
/// (U+066B). normalizeNumber turned the digits into Western ones but left the
/// separator, and the fields' [0-9.] filter then dropped it: «٢٫٥» became 25.
void main() {
  test('the Arabic decimal separator is a decimal point', () {
    expect(normalizeNumber('٢٫٥'), '2.5');
    expect(normalizeNumber('١٢٫٧٥٠'), '12.750');
  });

  test('the Arabic thousands separator is dropped', () {
    expect(normalizeNumber('١٬٢٥٠٫٥'), '1250.5');
  });

  test('Western and Persian digits as before', () {
    expect(normalizeNumber('12.5'), '12.5');
    expect(normalizeNumber('۱۲'), '12');
  });
}
