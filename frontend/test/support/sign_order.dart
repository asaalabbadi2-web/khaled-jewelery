import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether, in the text [found] draws, [sign] falls left of its number on the
/// screen -- read right to left, after it: a sum said as the invoices say it
/// (the owner, 13 Nov 2026: «انت تضع رمز العمله قبل القيمة»). Measured from
/// the drawn line, not the string's order, which the direction turns about.
bool signFollowsTheNumber(WidgetTester tester, Finder found, String sign) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: found, matching: find.byType(RichText), matchRoot: true).first,
  );
  final text = paragraph.text.toPlainText();
  final at = text.indexOf(sign);
  final digit = text.indexOf(RegExp('[0-9]'));
  expect(at, isNonNegative, reason: '«$sign» in «$text»');
  expect(digit, isNonNegative, reason: 'a number in «$text»');
  final signBox = paragraph.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + sign.length)).first;
  final numberBox = paragraph.getBoxesForSelection(TextSelection(baseOffset: digit, extentOffset: digit + 1)).first;
  return signBox.left < numberBox.left;
}
