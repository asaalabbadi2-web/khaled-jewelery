import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/pdf/pdf_text_utils.dart';
import 'package:frontend/pdf/statement_print_facts.dart';

/// The printed account statement (the owner, 28 Oct 2026): a balance says
/// whose it is -- «له» or «عليه» -- not a minus sign; and the balance row at
/// the top of the lines is the closing one when they run newest first.
void main() {
  group('a balance says whose it is', () {
    test('a debit balance: the account owes -- «عليه»', () {
      expect(statementBalance(12815.08, decimals: 2), '12,815.08 عليه');
    });

    test('a credit balance: it is owed -- «له», with no minus sign', () {
      expect(statementBalance(-4277.95, decimals: 2), '4,277.95 له');
      expect(statementBalance(-101.359, decimals: 3), '101.359 له');
    });

    test('nothing has no word', () {
      expect(statementBalance(0, decimals: 2), '0.00');
      expect(statementBalance(-0.0001, decimals: 3), '0.000');
    });

    test('its size and whose it is, apart, for the currency between them', () {
      expect(statementBalanceParts(-4277.95, decimals: 2), (size: '4,277.95', whose: 'له'));
      expect(statementBalanceParts(0, decimals: 2), (size: '0.00', whose: ''));
    });

    test('whose it is reads back', () {
      expect(statementBalanceIsCredit(statementBalance(-5, decimals: 2)), isTrue);
      expect(statementBalanceIsCredit(statementBalance(5, decimals: 2)), isFalse);
    });
  });

  group('the balance rows open and close the lines, as they run', () {
    final from = DateTime(2026, 6, 1), to = DateTime(2026, 10, 28);
    ({StatementBalanceRow first, StatementBalanceRow last}) edges(bool newestFirst) => statementEdgeRows(
      newestFirst: newestFirst,
      openingGold: 0,
      openingCash: 0,
      closingGold: -101.359,
      closingCash: -4277.95,
      from: from,
      to: to,
    );

    test('newest first: the closing balance on top, the opening one at the foot', () {
      final rows = edges(true);
      expect((rows.first.label, rows.first.gold, rows.first.cash, rows.first.date),
          ('رصيد ختامي', -101.359, -4277.95, to));
      expect((rows.last.label, rows.last.gold, rows.last.cash, rows.last.date),
          ('رصيد افتتاحي', 0.0, 0.0, from));
    });

    test('oldest first: the opening balance on top, the closing one at the foot', () {
      final rows = edges(false);
      expect((rows.first.label, rows.last.label), ('رصيد افتتاحي', 'رصيد ختامي'));
      expect((rows.last.gold, rows.last.cash, rows.last.date), (-101.359, -4277.95, to));
    });
  });

  group('the period, as printed', () {
    test('from the older day to the newer', () {
      expect(statementPeriodText(DateTime(2026, 6, 1), DateTime(2026, 10, 28)),
          'من 2026-06-01 إلى 2026-10-28');
      expect(statementPeriodText(null, null), isNull);
    });

    test('on paper, read right to left, the older day comes first', () {
      final v = pdfVisualArabic;
      expect(v(statementPeriodText(DateTime(2026, 6, 1), DateTime(2026, 10, 28))!),
          '2026-10-28 ${v('إلى')} 2026-06-01 ${v('من')}');
    });
  });
}
