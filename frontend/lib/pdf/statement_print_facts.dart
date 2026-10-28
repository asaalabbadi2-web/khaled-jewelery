/// What a printed account statement says of a balance (the owner, 28 Oct
/// 2026, on the statement's print).
library;

import 'package:intl/intl.dart';

/// A balance as a statement writes it: its size and whose it is -- «عليه»
/// when the account owes (a debit balance, above nothing), «له» when it is
/// owed (a credit balance, below it), and no word for nothing. A minus sign
/// said it before («بدلا من سالب يتم استبداله بله وعليه»). [decimals] is 3
/// for grams, 2 for riyals.
String statementBalance(double value, {required int decimals}) {
  final format = NumberFormat(decimals == 3 ? '#,##0.000' : '#,##0.00', 'en');
  final size = format.format(value.abs());
  if (size == format.format(0)) return size;
  return value > 0 ? '$size عليه' : '$size له';
}

/// Whether a balance [statementBalance] wrote is owed to the account.
bool statementBalanceIsCredit(String written) => written.endsWith(' له');

/// The balance rows around the statement's lines: the opening balance
/// before the oldest line and the closing balance after the newest -- at the
/// top and the foot as the lines run («لو كان من الأحدث إلى الأقدم يكون
/// السطر هو الرصيد الختامي والعكس صحيح»; «يكون آخر سطر الرصيد الختامي
/// والعكس صحيح»).
typedef StatementBalanceRow = ({String label, double gold, double cash, DateTime? date});

({StatementBalanceRow first, StatementBalanceRow last}) statementEdgeRows({
  required bool newestFirst,
  required double openingGold,
  required double openingCash,
  required double closingGold,
  required double closingCash,
  DateTime? from,
  DateTime? to,
}) {
  final StatementBalanceRow opening = (label: 'رصيد افتتاحي', gold: openingGold, cash: openingCash, date: from);
  final StatementBalanceRow closing = (label: 'رصيد ختامي', gold: closingGold, cash: closingCash, date: to);
  return newestFirst ? (first: closing, last: opening) : (first: opening, last: closing);
}
