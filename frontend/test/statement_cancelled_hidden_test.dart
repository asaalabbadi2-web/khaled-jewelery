import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/account_statement_model.dart';

/// A statement says what it leaves out (the owner, 9 Oct 2026): cancelled
/// vouchers and their reversals are hidden by default, and the screen offers
/// to show them -- from the server's count, not one it works out.
void main() {
  Map<String, dynamic> body(Map<String, dynamic>? cancelled) => {
        'lines': <dynamic>[],
        if (cancelled != null) 'cancelled_hidden': cancelled,
      };

  test('the hidden vouchers are read as the server sent them', () {
    final s = AccountStatement.fromJson(body({
      'count': 2,
      'vouchers': ['RV-2026-00010', 'PV-2026-00004'],
      'corrections': 1,
      'correction_vouchers': ['AV-2026-00481'],
      'hidden': true,
    }));
    expect(s.correctionCount, 1);
    expect(s.cancelledCount, 2);
    expect(s.cancelledVoucherNumbers, ['RV-2026-00010', 'PV-2026-00004']);
    expect(s.cancelledHidden, isTrue);
  });

  test('an older server sends nothing: nothing is hidden', () {
    final s = AccountStatement.fromJson(body(null));
    expect(s.cancelledCount, 0);
    expect(s.cancelledHidden, isFalse);
  });
}
