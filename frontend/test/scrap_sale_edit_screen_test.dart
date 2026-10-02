import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/invoices_list_screen.dart';

/// A scrap sale is edited on the screen that made it (the owner, 2 Oct 2026):
/// opened in the ordinary sale screen, sale #1540 came back a sale of new gold.
void main() {
  test('a sale of scrap gold is a scrap sale', () {
    expect(isScrapSale({'invoice_type': 'بيع', 'gold_type': 'scrap'}), isTrue);
    expect(isScrapSale({'invoice_type': 'بيع', 'gold_type': 'Scrap '}), isTrue);
  });

  test('a sale of new gold, or a scrap purchase, is not', () {
    expect(isScrapSale({'invoice_type': 'بيع', 'gold_type': 'new'}), isFalse);
    expect(isScrapSale({'invoice_type': 'بيع'}), isFalse);
    expect(isScrapSale({'invoice_type': 'شراء من عميل', 'gold_type': 'scrap'}), isFalse);
  });
}
