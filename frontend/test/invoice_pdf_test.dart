import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/pdf/invoice_pdf_builder.dart';
import 'package:frontend/pdf/invoice_print_facts.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/pdf.dart';

/// The printed invoice (PRINT-1, the owner 27 Oct 2026: «تضرب العدد في الوزن
/// في طباعة الفواتير»). Measured on the 27 Oct copy: a line's weight was
/// printed times its count (612 lines), the 80 mm roll printed «تعذر إنشاء
/// الفاتورة للطباعة» for every invoice, and A5 failed on its QR code (the
/// header's sides took the whole width).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
  });

  // SELL-2026-1689 on the 27 Oct copy: 39.4 g in four lines, one of two pieces.
  final sale = <String, dynamic>{
    'id': 3406,
    'invoice_number': 'SELL-2026-1689',
    'invoice_type': 'بيع',
    'date': '2026-10-18T17:42:00',
    'customer_name': 'عميل نقدي',
    'employee_name': 'يوسف الشعبي',
    'total': 18692.81,
    'total_tax': 0.0,
    'total_weight': 39.4,
    'items': [
      {'name': 'طقم ذهب21', 'karat': 21.0, 'quantity': 1, 'weight': 19.5, 'net': 9385.74},
      {'name': 'بنجرة ذهب21', 'karat': 21.0, 'quantity': 2, 'weight': 11.3, 'net': 5167.72},
      {'name': 'خاتم ذهب21', 'karat': 21.0, 'quantity': 1, 'weight': 1.7, 'net': 818.24},
      {'name': 'تعليقة ذهب21', 'karat': 21.0, 'quantity': 1, 'weight': 6.9, 'net': 3321.11},
    ],
  };

  // SUPP-2026-203: a long title («فاتورة شراء جديد») and no line prices.
  final supplierPurchase = <String, dynamic>{
    'id': 3502,
    'invoice_number': 'SUPP-2026-203',
    'invoice_type': 'شراء',
    'date': '2026-10-26T17:56:00',
    'supplier_name': 'فورناين',
    'total': 47161.11,
    'total_tax': 542.04,
    'total_weight': 101.33,
    'items': [
      {'name': 'اطارات السبايك', 'karat': 21.0, 'quantity': 1, 'weight': 50.87, 'wage': 32.0},
      {'name': 'دبل', 'karat': 21.0, 'quantity': 1, 'weight': 47.49, 'wage': 39.35},
      {'name': 'دبل', 'karat': 21.0, 'quantity': 1, 'weight': 2.97, 'wage': 39.35},
    ],
  };

  group('a line weighs what it weighs', () {
    test('its count does not multiply it', () {
      expect(invoiceLineWeight(sale['items'][1] as Map), 11.3);
    });

    test('the karats add up to the invoice\'s weight', () {
      final byKarat = invoiceWeightByKarat((sale['items'] as List).cast<Map>());
      expect(byKarat.keys, ['21']);
      expect(byKarat['21'], closeTo(39.4, 1e-9));
    });

    test('a line without its weight falls back to its total weight', () {
      expect(invoiceLineWeight({'quantity': 3, 'total_weight': 4.2}), 4.2);
    });

    test('a karat reads 21, not 21.0', () {
      expect(invoiceKaratText(21.0), '21');
      expect(invoiceKaratText('18'), '18');
    });

    test('a supplier\'s invoice is told by its type', () {
      expect(isSupplierInvoiceType('شراء'), isTrue);
      expect(isSupplierInvoiceType('مرتجع شراء (مورد)'), isTrue);
      expect(isSupplierInvoiceType('شراء من عميل'), isFalse);
      expect(isSupplierInvoiceType('بيع'), isFalse);
    });
  });

  group('every paper prints the invoice', () {
    final papers = <String, PdfPageFormat>{
      'A4': PdfPageFormat.a4,
      'A5': PdfPageFormat.a5,
      // As invoice_direct_print and the printing center ask for the roll.
      '80 mm roll': const PdfPageFormat(
        80 * PdfPageFormat.mm,
        double.infinity,
        marginAll: 4 * PdfPageFormat.mm,
      ),
    };
    for (final paper in papers.entries) {
      for (final bw in [false, true]) {
        for (final (name, invoice) in [('sale', sale), ('supplier purchase', supplierPurchase)]) {
          test('${paper.key}, ${bw ? 'black and white' : 'color'}: a $name', () async {
            final bytes = await InvoicePdfBuilder.buildDocument(
              invoice: invoice,
              format: paper.value,
              options: InvoicePdfOptions(blackAndWhite: bw),
            );
            expect(bytes.length, greaterThan(1000));
          });
        }
      }
    }
  });
}
