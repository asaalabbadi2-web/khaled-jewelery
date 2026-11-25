// One paper, one page (settings spec v2, phase 5: B1–B4; the owner, 25 Nov
// 2026 «ابدأ»). A stored paper size was turned into a page in four places,
// each its own way: the invoice's share compared 'thermal' in lower case
// while the sheet stores 'Thermal' -- a thermal invoice shared as A4; its
// print never read the size at all; a voucher's '58 مم' and '80 مم' were
// folded to A4; and «حجم ورق الفواتير والسندات» was saved under a key no
// print read. Now every path reads the one conversion, paperOf / pageFormatFor.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/paper_format.dart';
import 'package:pdf/pdf.dart';

String _src(String path) => File(path).readAsStringSync();

void main() {
  test('every stored spelling reads as its paper', () {
    const table = {
      'A4': PrintPaper.a4, 'a4': PrintPaper.a4, 'A5': PrintPaper.a5, 'Letter': PrintPaper.letter,
      'Thermal': PrintPaper.roll80, 'thermal': PrintPaper.roll80, '80mm': PrintPaper.roll80,
      '80 مم': PrintPaper.roll80, '٨٠ مم': PrintPaper.roll80,
      '58 مم': PrintPaper.roll58, '٥٨ مم': PrintPaper.roll58,
    };
    for (final MapEntry(:key, :value) in table.entries) {
      expect(paperOf(key), value, reason: key);
    }
    for (final unknown in [null, '', 'B5']) {
      expect(paperOf(unknown), PrintPaper.a4, reason: '$unknown: A4, as before');
    }
  });

  test('a paper is its page', () {
    expect(pageFormatFor('A5'), PdfPageFormat.a5);
    expect(pageFormatFor('Letter'), PdfPageFormat.letter);
    expect(pageFormatFor('A4', orientation: 'landscape'), PdfPageFormat.a4.landscape);
    expect(pageFormatFor('Thermal').width, closeTo(80 * PdfPageFormat.mm, 0.01));
    expect(pageFormatFor('58 مم').width, closeTo(58 * PdfPageFormat.mm, 0.01));
    expect(pageFormatFor('80 مم', orientation: 'landscape').width, closeTo(80 * PdfPageFormat.mm, 0.01),
        reason: 'a roll has no landscape');
  });

  test('no paper is turned into a page anywhere else', () {
    final mapping = RegExp(r"case 'Thermal'|== 'thermal'|'80mm'|80 \* PdfPageFormat\.mm|contains\('A5'\) \? 'A5'");
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.endsWith('utils/paper_format.dart')) continue;
      if (mapping.hasMatch(f.readAsStringSync())) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });

  test("the invoice's print and share, and the list's, use the invoice paper", () {
    final direct = _src('lib/utils/invoice_direct_print.dart');
    expect(RegExp(r'layoutPdf\([^;]*format: pageFormatFor\(paperSize\)').hasMatch(direct), isTrue,
        reason: 'the print opens on the paper, not the dialog default');
    final list = _src('lib/screens/invoices_list_screen.dart');
    expect(list.contains('InvoiceUiSettings.load('), isTrue, reason: 'the list reads the invoice paper');
    expect(list.contains('format: PdfPageFormat.a4,'), isFalse, reason: 'the share no longer fixes A4');
  });

  test("the voucher's paper is read as stored, and its print opens on it", () {
    for (final path in ['lib/screens/voucher_details_screen.dart', 'lib/screens/voucher_preview_screen.dart']) {
      expect(_src(path).contains("contains('A5') ? 'A5' : 'A4'"), isFalse, reason: path);
    }
    expect(_src('lib/screens/voucher_details_screen.dart').contains('format: VoucherPdfBuilder.pageFormatFromSettings('),
        isTrue);
  });

  test("the settings' invoice paper is the one the invoices print on", () {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    expect(s.contains("'invoice_paper_size'"), isFalse, reason: 'the key no print reads is not written');
    expect(s.contains('InvoiceUiSettings.setPaperSize('), isTrue);
  });

  test('«إعدادات الطابعة» opens the printing tab', () {
    final s = _src('lib/screens/settings_screen_enhanced.dart');
    final tabs = RegExp(r"Tab\(icon: Icon\(Icons\.\w+\), text: '([^']+)'\)").allMatches(s).map((m) => m.group(1)).toList();
    final index = int.parse(RegExp(r'static const int printingTabIndex = (\d+);').firstMatch(s)!.group(1)!);
    expect(tabs[index], 'الطباعة');
    final home = _src('lib/screens/home_screen_enhanced.dart');
    final entry = home.substring(home.indexOf("'إعدادات الطابعة'"), home.indexOf("'إعدادات الطابعة'") + 600);
    expect(entry.contains('SettingsScreenEnhanced.printingTabIndex'), isTrue);
  });
}
