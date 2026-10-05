import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/journal_balance.dart';
import 'package:frontend/widgets/journal_balance_row.dart';

/// JE-UX-1: what the entry screen tells the accountant about the balance.
///
/// The server settles a gold difference only under 0.01 g (routes/journals.py);
/// the screen used to promise «the server will balance it» for any difference,
/// and the save then failed. The row's «difference» was read back from the
/// formatted text, so from 1,000 up («1,500.00» -> null -> 0) it showed 0.
void main() {
  group('goldBalanceVerdict follows the server', () {
    test('equal, or within a thousandth of a gram, is balanced', () {
      expect(goldBalanceVerdict(10, 10), GoldBalanceVerdict.balanced);
      expect(goldBalanceVerdict(10.0009, 10), GoldBalanceVerdict.balanced);
    });

    test('under 0.01 g the server settles it, either side', () {
      expect(
        goldBalanceVerdict(10.0075, 10),
        GoldBalanceVerdict.serverWillSettle,
      );
      expect(
        goldBalanceVerdict(10, 10.0075),
        GoldBalanceVerdict.serverWillSettle,
      );
    });

    test(
      '0.01 g and more is refused by the server, so the screen stops it',
      () {
        expect(goldBalanceVerdict(10.0125, 10), GoldBalanceVerdict.mustFix);
        expect(goldBalanceVerdict(10, 10.5), GoldBalanceVerdict.mustFix);
      },
    );
  });

  group('JournalBalanceRow shows the difference as a number', () {
    Widget host(double debit, double credit) => MaterialApp(
      home: Scaffold(
        body: JournalBalanceRow(
          label: 'نقد',
          debit: debit,
          credit: credit,
          format: (v) => v
              .toStringAsFixed(2)
              .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ','),
          suffix: 'ر.س',
        ),
      ),
    );

    testWidgets('a difference of 1,500.00 is not shown as 0.00', (
      tester,
    ) async {
      await tester.pumpWidget(host(2500, 1000));
      expect(
        find.textContaining('1,500.00', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('the sides are shown as given', (tester) async {
      await tester.pumpWidget(host(2500, 1000));
      expect(
        find.textContaining('2,500.00', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('1,000.00', findRichText: true),
        findsOneWidget,
      );
    });
  });
}
