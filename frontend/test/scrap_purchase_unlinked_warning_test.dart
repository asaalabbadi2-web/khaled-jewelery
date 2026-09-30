// The «حساب غير مرتبط بموظف» warning on the scrap-purchase screen (EDIT-001).
//
// It tells an account with no employee that the gold will go to the main scrap
// safe. On an edit the server keeps the invoice's holder and the safe box the
// gold went to, so for an invoice whose holder has a custody safe the warning
// was untrue: the owner, editing invoice 3170, was told Abdullah's gold would
// leave his custody (30 Sep 2026).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/scrap_purchase_invoice_screen.dart';

void main() {
  test('a new purchase by an account with no employee is warned', () {
    expect(warnsGoldGoesToMainScrapSafe(signedInEmployeeId: null), isTrue);
  });

  test('an account linked to an employee is never warned', () {
    expect(warnsGoldGoesToMainScrapSafe(signedInEmployeeId: 19), isFalse);
  });

  test('editing an invoice whose holder has a custody safe is not warned', () {
    expect(
      warnsGoldGoesToMainScrapSafe(
        signedInEmployeeId: null,
        editInvoiceData: {'scrap_holder_employee_id': 19, 'scrap_holder_gold_safe_box_id': 46},
      ),
      isFalse,
    );
  });

  test('editing an invoice whose holder has no custody safe is still warned', () {
    expect(
      warnsGoldGoesToMainScrapSafe(
        signedInEmployeeId: null,
        editInvoiceData: {'scrap_holder_employee_id': 19, 'scrap_holder_gold_safe_box_id': null},
      ),
      isTrue,
    );
  });
}
