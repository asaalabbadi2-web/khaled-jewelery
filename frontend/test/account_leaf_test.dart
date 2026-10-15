// ACCT-LEAF-1: a detail account is one no account is under, whatever its
// number's length. The voucher screen judged it by length: on the production
// copy (15 Oct 2026) it offered 48 group accounts (1100 النقدية, 1200, 2400…)
// and hid 27 detail ones (310 رأس المال, 510, 360…).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/account_picker_sheet.dart';

void main() {
  final accounts = <Map<String, dynamic>>[
    {'id': 1, 'account_number': '1100', 'name': 'النقدية', 'parent_id': null},
    {'id': 2, 'account_number': '1100000', 'name': 'صندوق النقدية الرئيسي', 'parent_id': 1},
    {'id': 3, 'account_number': '310', 'name': 'رأس المال', 'parent_id': 4},
    {'id': 4, 'account_number': '31', 'name': 'رأس المال (مجموعة)', 'parent_id': null},
  ];
  final parents = parentAccountIdsOf(accounts);

  test('a group with accounts under it is not a detail account, however long its number', () {
    expect(isLeafAccount(accounts[0], parents), isFalse);
    expect(isLeafAccount(accounts[3], parents), isFalse);
  });

  test('an account nothing is under is a detail account, however short its number', () {
    expect(isLeafAccount(accounts[1], parents), isTrue);
    expect(isLeafAccount(accounts[2], parents), isTrue);
  });
}
