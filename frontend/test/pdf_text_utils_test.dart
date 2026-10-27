import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/pdf/pdf_text_utils.dart';

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
}
