import 'package:pdf/pdf.dart';

import '../utils.dart' show normalizeNumber;

/// A printed paper -- the one conversion of a stored paper size into a page
/// (settings spec v2, B2–B4). Four places did it each its own way: a thermal
/// invoice shared as A4 for 'Thermal' against 'thermal', a voucher's '80 مم'
/// folded to A4. Every print path reads [paperOf] and [pageFormatFor].
enum PrintPaper { a4, a5, letter, roll80, roll58 }

/// The paper a stored value names, whatever its spelling: 'Thermal',
/// 'thermal', '80mm', '80 مم' and '٨٠ مم' are the 80 mm roll; '58 مم' the
/// 58 mm one. Anything else, or nothing, is A4 -- as every path read it before.
PrintPaper paperOf(String? stored) {
  final v = normalizeNumber(stored ?? '').trim().toLowerCase().replaceAll(' ', '');
  if (v == 'a5') return PrintPaper.a5;
  if (v == 'letter') return PrintPaper.letter;
  if (const {'thermal', '80mm', '80مم', '80'}.contains(v)) return PrintPaper.roll80;
  if (const {'58mm', '58مم', '58'}.contains(v)) return PrintPaper.roll58;
  return PrintPaper.a4;
}

/// Its page: a sheet in the orientation asked, a roll its width and as long
/// as the content (a roll has no landscape).
PdfPageFormat pageFormatOf(PrintPaper paper, {String orientation = 'portrait'}) {
  const margin = 4 * PdfPageFormat.mm;
  final PdfPageFormat sheet;
  switch (paper) {
    case PrintPaper.roll80:
      return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: margin);
    case PrintPaper.roll58:
      return const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: margin);
    case PrintPaper.a5:
      sheet = PdfPageFormat.a5;
    case PrintPaper.letter:
      sheet = PdfPageFormat.letter;
    case PrintPaper.a4:
      sheet = PdfPageFormat.a4;
  }
  return orientation == 'landscape' ? sheet.landscape : sheet;
}

/// [pageFormatOf] of a stored value.
PdfPageFormat pageFormatFor(String? stored, {String orientation = 'portrait'}) =>
    pageFormatOf(paperOf(stored), orientation: orientation);

/// A stored value said as the screens say it.
String paperLabel(String stored) => switch (paperOf(stored)) {
      PrintPaper.roll80 => 'حراري 80 مم',
      PrintPaper.roll58 => 'حراري 58 مم',
      PrintPaper.a5 => 'A5',
      PrintPaper.letter => 'Letter',
      PrintPaper.a4 => 'A4',
    };
