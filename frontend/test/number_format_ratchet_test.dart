import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// UI-2 (ADR-049): an amount or a weight is written for reading through
/// `formatAmount` / `formatGrams` (`lib/utils/currency_utils.dart`) --
/// thousands separated, a minus sign kept before the number -- not through
/// `toStringAsFixed` («2500.00»).
///
/// A rounding (`double.parse(x.toStringAsFixed(2))`), a field's text and a log
/// line keep their own form and are not counted. The rest may go down in
/// each file and never up; a new file's count is zero
/// (`test/number_format_baseline.json`). After a screen is moved:
///   UPDATE_NUMBER_FORMAT_BASELINE=1 flutter test test/number_format_ratchet_test.dart
final ratchet = SourceRatchet(
  pattern: RegExp(r'\.toStringAsFixed\('),
  baselinePath: 'test/number_format_baseline.json',
  updateEnv: 'UPDATE_NUMBER_FORMAT_BASELINE',
  ignoreLine: RegExp(
    r'double\.(tryParse|parse)\(|num\.(tryParse|parse)\(|\.text\s*=|'
    r'\btext:\s|initialValue:|debugPrint\(|\bprint\(',
  ),
);

void main() {
  test('what counts', () {
    int n(String s) => ratchet.countIn(s);
    expect(n("Text('\${total.toStringAsFixed(2)} ر.س')"), 1);
    expect(n('final r = double.parse(x.toStringAsFixed(2));'), 0);
    expect(n('controller.text = x.toStringAsFixed(3);'), 0);
    expect(n("debugPrint('x=\${x.toStringAsFixed(2)}');"), 0);
    expect(n("Text(formatAmount(total))"), 0);
  });

  test('no file gains a number written with toStringAsFixed', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'رقم يُعرض بـ toStringAsFixed زاد. اعرضه بـ formatAmount(x) '
          'أو formatGrams(x)؛ وإن كان تقريبًا حسابيًّا فاكتبه '
          'double.parse(x.toStringAsFixed(2)) في سطر واحد.',
    );
  });
}
