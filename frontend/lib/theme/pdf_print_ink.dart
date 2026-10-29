/// Black and white prints black and white (PRINT-2, the owner 27 Oct 2026:
/// «الألوان في طباعة الأبيض والأسود ليست قوية»).
///
/// The black-and-white print was the color one in light grays: a header on
/// #F0F0F0, rules in #888 a third of a point wide, signature lines and
/// dividers in #DDD, labels in #444 -- faint or gone on a shop printer. A
/// color is now read by what it does:
///   ink  -- text, rules, borders, marks: black; white stays white (the text
///           on a dark band);
///   fill -- backgrounds: white; a dark band stays black.
/// A color print is unchanged.
library;

import 'package:pdf/pdf.dart';

class PdfInk {
  const PdfInk({required this.blackAndWhite});

  final bool blackAndWhite;

  /// Text, a rule, a border, a mark.
  PdfColor ink(PdfColor color) {
    if (!blackAndWhite) return color;
    return color.luminance > 0.95 ? PdfColors.white : PdfColors.black;
  }

  /// A background.
  PdfColor fill(PdfColor color) {
    if (!blackAndWhite) return color;
    return color.luminance < 0.3 ? PdfColors.black : PdfColors.white;
  }

  /// A rule's width: no hairline in black and white, where it vanishes.
  double rule(double width) => blackAndWhite && width < 0.8 ? 0.8 : width;

  /// The SAR symbol's tints: [gold] for amounts (ink in black and white),
  /// [dark] for body text, [onBand] for a table's head -- white on its black
  /// band in black and white, dark on its light band in color.
  ({PdfColor gold, PdfColor dark, PdfColor onBand}) get sarTints {
    const dark = PdfColor.fromInt(0xFF1A1A1A);
    return (
      gold: blackAndWhite ? dark : const PdfColor.fromInt(0xFF8B6914),
      dark: dark,
      onBand: blackAndWhite ? PdfColors.white : dark,
    );
  }
}
