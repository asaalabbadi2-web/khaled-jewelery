// REPORTS ت3-1 (ADR-083 law 2, one report per question): a party's or an
// account's movements are one screen, AccountStatementScreen -- for an
// account, a customer, a supplier, an office. On the 4 Nov tree there were
// three: the statement, AccountLedgerScreen «دفتر الأستاذ» (the accounts'
// menu and panel) and SupplierLedgerScreen «حركات المورد» (a supplier's card,
// an office's page), each its own reading. A new statement or ledger screen
// is named here with the question it answers, or it fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each statement or ledger screen, and the one question it answers.
const answers = {
  'AccountStatementScreen': 'a party\'s or an account\'s movements',
  'IncomeStatementReportScreen': 'the income statement of a period',
  'EmployeeScrapLedgerReportScreen':
      'the scrap gold in each employee\'s custody',
};

void main() {
  test('one screen for a party\'s movements; every statement screen named', () {
    final found = <String>{};
    final pattern = RegExp(r'class (\w*(?:Ledger|Statement)\w*Screen)\b');
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final m in pattern.allMatches(file.readAsStringSync())) {
        found.add(m.group(1)!);
      }
    }
    expect(
      found.difference(answers.keys.toSet()),
      isEmpty,
      reason: 'a second screen for a question one already answers',
    );
  });
}
