import 'package:flutter/material.dart' show DateTimeRange;

import 'account_statement_model.dart';

/// A statement's figures for a period, read from the server's running balances.
///
/// The screen and its PDF each kept their own copy of this, and both summed
/// the lines themselves (10 Oct 2026). Now each line carries the balance after
/// it, as the server computes the closing ([StatementLine.runningCashBalance]):
/// a period opens on the balance after its last earlier line and closes on the
/// balance after its own last line. Nothing here is recomputed from a filtered
/// list -- a filter hides lines, it never moves a balance.

typedef StatementBalance = ({double gold, double cash});

typedef StatementPeriod = ({
  double openingGold,
  double openingCash,
  double movementGold,
  double movementCash,
  double closingGold,
  double closingCash,
});

typedef StatementTotals = ({
  double goldDebit,
  double goldCredit,
  double cashDebit,
  double cashCredit,
});

/// The days of [range], the last one whole.
({DateTime startInclusive, DateTime endExclusive}) statementRangeBounds(DateTimeRange range) {
  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final endExclusive = DateTime(range.end.year, range.end.month, range.end.day)
      .add(const Duration(days: 1));
  return (startInclusive: start, endExclusive: endExclusive);
}

/// The balance before [instant]: the server's balance after the last line
/// dated earlier (the lines come oldest first), or the statement's opening.
StatementBalance statementBalanceBefore(AccountStatement statement, DateTime? instant) {
  var gold = statement.openingBalanceGold;
  var cash = statement.openingBalanceCash;
  if (instant == null) return (gold: gold, cash: cash);
  for (final line in statement.lines) {
    if (!line.date.isBefore(instant)) break;
    gold = line.runningGoldBalance ?? gold;
    cash = line.runningCashBalance ?? cash;
  }
  return (gold: gold, cash: cash);
}

/// Opening, movement and closing of [range]; the whole statement when null.
StatementPeriod statementPeriod(AccountStatement statement, DateTimeRange? range) {
  if (range == null) {
    return (
      openingGold: statement.openingBalanceGold,
      openingCash: statement.openingBalanceCash,
      movementGold: statement.totalDebitGold - statement.totalCreditGold,
      movementCash: statement.totalDebitCash - statement.totalCreditCash,
      closingGold: statement.closingBalanceGoldNormalized,
      closingCash: statement.closingBalanceCash,
    );
  }
  final bounds = statementRangeBounds(range);
  final opening = statementBalanceBefore(statement, bounds.startInclusive);
  final closing = statementBalanceBefore(statement, bounds.endExclusive);
  return (
    openingGold: opening.gold,
    openingCash: opening.cash,
    movementGold: closing.gold - opening.gold,
    movementCash: closing.cash - opening.cash,
    closingGold: closing.gold,
    closingCash: closing.cash,
  );
}

/// Debits and credits of the lines in [range]; the statement's totals when null.
StatementTotals statementTotals(AccountStatement statement, DateTimeRange? range) {
  if (range == null) {
    return (
      goldDebit: statement.totalDebitGold,
      goldCredit: statement.totalCreditGold,
      cashDebit: statement.totalDebitCash,
      cashCredit: statement.totalCreditCash,
    );
  }
  final bounds = statementRangeBounds(range);
  var goldDebit = 0.0, goldCredit = 0.0, cashDebit = 0.0, cashCredit = 0.0;
  for (final line in statement.lines) {
    if (line.date.isBefore(bounds.startInclusive) || !line.date.isBefore(bounds.endExclusive)) continue;
    goldDebit += line.goldDebit;
    goldCredit += line.goldCredit;
    cashDebit += line.cashDebit;
    cashCredit += line.cashCredit;
  }
  return (goldDebit: goldDebit, goldCredit: goldCredit, cashDebit: cashDebit, cashCredit: cashCredit);
}
