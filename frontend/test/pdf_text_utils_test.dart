import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/pdf/pdf_text_utils.dart';
// ignore: implementation_imports
import 'package:pdf/src/pdf/font/ttf_parser.dart';

/// PRINT-4: Arabic is laid out for the PDF in visual order (pdfVisualArabic).
/// A neutral -- a space, a colon -- between an Arabic word and a number took
/// the number's side, so on paper it stood on the far side of the number:
/// «بنجرة ذهب 21» printed «21» touching «ذهب», «تاريخ الطباعة: 2026-10-28»
/// printed «: 2026-10-28تاريخ الطباعة». In Arabic text a neutral takes the
/// paragraph's direction (right to left) unless both its sides are left to
/// right -- as the Unicode bidi algorithm has it (N1, N2).
void main() {
  String v(String s) => pdfVisualArabic(s);

  group('a neutral between an Arabic word and a number stays between them', () {
    test('a space', () {
      expect(v('بنجرة ذهب 21'), '21 ${v('بنجرة ذهب')}');
      expect(v('دفعة فاتورة 202'), '202 ${v('دفعة فاتورة')}');
    });

    test('a colon and a space', () {
      expect(v('تاريخ الطباعة: 2026-10-28'), '2026-10-28 :${v('تاريخ الطباعة')}');
    });

    test('a number first', () {
      expect(v('21 جم'), '${v('جم')} 21');
    });

    test('brackets after a number belong together', () {
      // As a browser lays it out: the sentence reads right to left, the
      // bracketed reference last -- not a closing bracket alone at the far end.
      expect(
        v('دفعات فاتورة SELL-2026-546 (RV-2026-00566)'),
        '(RV-2026-00566) SELL-2026-546 ${v('دفعات فاتورة')}',
      );
    });

    test('a date after a word', () {
      expect(v('التاريخ 2026-10-28'), '2026-10-28 ${v('التاريخ')}');
    });
  });

  group('what was right stays right', () {
    test('Latin words in Arabic keep their order and spaces', () {
      expect(v('سداد PAYMENT - PV-2026-00564'), contains('PAYMENT - PV-2026-00564'));
    });

    test('brackets wrap the Arabic they hold', () {
      final out = v('ذهب (وزن)');
      expect(out.contains(')') && out.contains('('), isTrue);
      expect(out.indexOf('('), lessThan(out.indexOf(')')), reason: 'not «ذهب) وزن(»');
    });

    test('text with no Arabic is left as it is', () {
      expect(v('SELL-2026-1689'), 'SELL-2026-1689');
    });
  });

  // PRINT-5 (the owner, 28 Oct 2026): «مدى» printed with its alef maksura
  // joined to the dal, and the statement's arrow printed as an unknown
  // sign. The font (Cairo) draws its isolated alef maksura form (U+FEEF) as
  // two dots alone, and has no isolated yeh (U+FEF1) and no arrow (U+2192,
  // 505 descriptions on the 27 Oct copy).
  group('every sign printed is one the font draws', () {
    final cairo = TtfParser(ByteData.view(
      Uint8List.fromList(File('assets/fonts/Cairo-Regular.ttf').readAsBytesSync()).buffer,
    )).charToGlyphIndexMap;
    // Mapped in the font, drawn wrong: never to be printed.
    const drawnWrong = {0xFEEF};

    test('every Arabic letter, in each of its positions', () {
      const beh = 'ب';
      final bad = <String>[];
      // The Arabic alphabet: hamza to ghain, feh to yeh (U+063B..U+063F
      // are letters of other languages; U+0640 is the tatweel).
      final alphabet = [for (var c = 0x621; c <= 0x63A; c++) c, for (var c = 0x641; c <= 0x64A; c++) c];
      for (final letter in alphabet) {
        final l = String.fromCharCode(letter);
        for (final word in [l, '$l$beh', '$beh$l$beh', '$beh$l']) {
          for (final r in pdfShapeArabic(word).runes) {
            if (!cairo.containsKey(r) || drawnWrong.contains(r)) {
              bad.add('${letter.toRadixString(16)} in «$word»: ${r.toRadixString(16)}');
            }
          }
        }
      }
      expect(bad, isEmpty);
    });

    test('«مدى»: the alef maksura stands apart from the dal', () {
      expect(pdfShapeArabic('مدى').runes.last, 0x649);
      expect(pdfShapeArabic('على').runes.last, 0xFEF0, reason: 'joined after a joining letter');
    });

    test('an arrow is written in signs the font has', () {
      final out = v('تسوية: مدى → خزينة بنك الرياض');
      expect(out.runes.where((r) => !cairo.containsKey(r) && r != 0x20), isEmpty);
      expect(out.contains('\u2192'), isFalse);
    });

    test('the arrow points the way the Arabic reads: from «مدى» to «خزينة»', () {
      // Read right to left, the arrow points left, on to the next word.
      expect(v('مدى → خزينة'), '${v('خزينة')} <- ${v('مدى')}');
    });
  });
}
