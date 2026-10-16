import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Saudi Riyal symbol identifier
// ─────────────────────────────────────────────────────────────────────────────

/// Internal key used when the user selects the new 2020 Saudi Riyal graphic.
const String kSarNewSymbol = '__SAR_NEW__';

/// Returns true when [symbol] refers to the new SAR graphic symbol.
bool isNewSarSymbol(String? symbol) {
  if (symbol == null) return false;

  final normalized = symbol
    .replaceAll('"', '')
    .replaceAll("'", '')
    .trim()
    .toUpperCase();

  // Keep backward compatibility with legacy/variant placeholders.
  return normalized == kSarNewSymbol ||
    normalized == '__SAR_NEW' ||
    normalized == 'SAR_NEW' ||
    normalized == '_SAR_NEW_' ||
    normalized == 'SAR_NEW__';
}

// ─────────────────────────────────────────────────────────────────────────────
// Currency options shown in Settings
// ─────────────────────────────────────────────────────────────────────────────

/// All supported currency options.
/// Each record: (display label used in chips, stored value).
const List<(String label, String value)> kCurrencyOptions = [
  ('رمز الريال الجديد', kSarNewSymbol),
  ('ر.س', 'ر.س'),
  ('ريال', 'ريال'),
  ('﷼', '\uFDFC'),
  ('SAR', 'SAR'),
  ('USD', 'USD'),
  ('\$', '\$'),
  ('€', '€'),
];

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// An amount written for reading (ADR-049): thousands separated, [decimals]
/// places, Western digits, a minus sign before a negative -- «1,500.00»,
/// «-1,500.00». The one way a screen writes an amount; what is sent to the
/// server keeps its own form and never goes through here.
///
/// A negative carries an invisible left-to-right mark (U+200E) before its
/// sign, as Arabic number formatting does, so that inside Arabic text the
/// sign stays before the number and does not jump to its end.
String formatAmount(num value, {int decimals = 2}) {
  final pattern = decimals > 0 ? '#,##0.${'0' * decimals}' : '#,##0';
  final text = NumberFormat(pattern, 'en_US').format(value);
  if (!text.startsWith('-')) return text;
  // -0.001 rounds to «-0.00»: zero has no sign.
  if (RegExp(r'^-[0.,]+$').hasMatch(text)) return text.substring(1);
  return '‎$text';
}

/// A weight in grams written for reading: as [formatAmount], three places.
String formatGrams(num value, {int decimals = 3}) =>
    formatAmount(value, decimals: decimals);

/// Format a number using the given locale and decimal places.
String _fmtNum(double amount, {int decimalPlaces = 2, bool isArabic = true}) =>
    formatAmount(amount, decimals: decimalPlaces);

/// Plain-text format for contexts that cannot render widgets (PDF, clipboard…).
/// For the new SAR graphic symbol, falls back to 'ر.س'.
String formatCashText(
  double amount, {
  required String currencySymbol,
  int decimalPlaces = 2,
  bool isArabic = true,
}) {
  final sym = isNewSarSymbol(currencySymbol) ? 'ر.س' : currencySymbol;
  final num = _fmtNum(amount, decimalPlaces: decimalPlaces, isArabic: isArabic);
  return isArabic ? '$sym $num' : '$num $sym';
}

// ─────────────────────────────────────────────────────────────────────────────
// SarSymbolSpan — the core WidgetSpan glyph
// ─────────────────────────────────────────────────────────────────────────────

/// An inline [WidgetSpan] that renders the official 2020 Saudi Riyal symbol
/// image at the same visual size as surrounding text.
///
/// Usage inside a [RichText]:
/// ```dart
/// RichText(text: TextSpan(children: [
///   SarSymbolSpan(fontSize: 18, color: Colors.black),
///   TextSpan(text: ' 44.00'),
/// ]))
/// ```
class SarSymbolSpan extends WidgetSpan {
  SarSymbolSpan({
    required double fontSize,
    Color color = Colors.black,
    super.alignment = PlaceholderAlignment.middle,
  }) : super(
         child: SarSymbolImage(size: fontSize * 1.1, color: color),
       );
}

/// Standalone image widget for the new Saudi Riyal symbol.
/// Tintable via [color]; scales uniformly to [size].
class SarSymbolImage extends StatelessWidget {
  final double size;
  final Color color;

  const SarSymbolImage({
    super.key,
    required this.size,
    this.color = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final cacheW = (size * 0.85 * dpr).round().clamp(12, 512);
    final cacheH = (size * dpr).round().clamp(12, 512);

    return SizedBox(
      width: size * 0.85,
      height: size,
      child: Image.asset(
        'assets/sar_new_symbol.png',
        width: size * 0.85,
        height: size,
        cacheWidth: cacheW,
        cacheHeight: cacheH,
        color: color,
        colorBlendMode: BlendMode.srcIn,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CurrencyText — drop-in replacement for Text() with currency amount
// ─────────────────────────────────────────────────────────────────────────────

/// Renders an amount with its currency symbol inline — exactly like plain text.
///
/// • For text symbols (ر.س, $, SAR…) → renders as a single [Text] widget.
/// • For the new SAR graphic (kSarNewSymbol) → renders as [RichText] with a
///   [WidgetSpan] so the image sits inline with the number, just like a glyph.
///
/// ```dart
/// CurrencyText(
///   amount: 44.0,
///   symbol: settings.currencySymbol,
///   style: TextStyle(fontSize: 22, color: Colors.black),
/// )
/// ```
class CurrencyText extends StatelessWidget {
  final double amount;
  final String symbol;
  final TextStyle? style;
  final int decimalPlaces;
  final bool isArabic;
  final TextAlign textAlign;

  const CurrencyText({
    super.key,
    required this.amount,
    required this.symbol,
    this.style,
    this.decimalPlaces = 2,
    this.isArabic = true,
    this.textAlign = TextAlign.start,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle =
        style ?? DefaultTextStyle.of(context).style.copyWith(inherit: true);
    final fontSize = effectiveStyle.fontSize ?? 14.0;
    final color = effectiveStyle.color ?? Colors.black;
    final numStr = _fmtNum(
      amount,
      decimalPlaces: decimalPlaces,
      isArabic: isArabic,
    );

    // ── Plain text symbol ──────────────────────────────────────
    if (!isNewSarSymbol(symbol)) {
      final text = isArabic ? '$symbol $numStr' : '$numStr $symbol';
      return Text(text, style: effectiveStyle, textAlign: textAlign);
    }

    // ── New SAR graphic — inline WidgetSpan ───────────────────
    final symSpan = SarSymbolSpan(fontSize: fontSize, color: color);
    final numSpan = TextSpan(text: ' $numStr', style: effectiveStyle);
    final spacer = const TextSpan(text: ' ');

    final spans = isArabic
        ? [symSpan, spacer, numSpan] // symbol LEFT of number
        : [numSpan, spacer, symSpan]; // symbol RIGHT of number

    return RichText(
      text: TextSpan(children: spans),
      textAlign: textAlign,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// sarAwareSpans — reusable span-builder behind SarAwareText
// ─────────────────────────────────────────────────────────────────────────────

/// Splits [text] on every occurrence of `'ر.س'` and returns the equivalent
/// [InlineSpan] list, swapping in a [SarSymbolSpan] image for each occurrence
/// when [isNewSar] is true. Use this (instead of [SarAwareText]) when [text]
/// needs to be just one piece of a larger [RichText]/[TextSpan] tree (e.g.
/// alongside an icon or another label) rather than a whole [Text] widget.
List<InlineSpan> sarAwareSpans(
  String text, {
  required bool isNewSar,
  required TextStyle style,
}) {
  if (!isNewSar || !text.contains('ر.س')) {
    return [TextSpan(text: text, style: style)];
  }

  final fontSize = style.fontSize ?? 14.0;
  final color = style.color ?? Colors.black;

  final parts = text.split('ر.س');
  final spans = <InlineSpan>[];
  for (int i = 0; i < parts.length; i++) {
    if (parts[i].isNotEmpty) {
      spans.add(TextSpan(text: parts[i], style: style));
    }
    if (i < parts.length - 1) {
      spans.add(SarSymbolSpan(fontSize: fontSize, color: color));
    }
  }
  return spans;
}

// ─────────────────────────────────────────────────────────────────────────────
// SarAwareText — drop-in Text replacement that renders the new SAR graphic
// ─────────────────────────────────────────────────────────────────────────────

/// A drop-in replacement for [Text] that, when [isNewSar] is true, finds every
/// occurrence of `'ر.س'` in [text] and replaces it with an inline
/// [SarSymbolSpan] image (same visual size as the surrounding text).
///
/// When [isNewSar] is false it behaves exactly like `Text(text, ...)`.
///
/// Usage:
/// ```dart
/// // instead of: Text('الإجمالي: $amount ${settings.currencySymbolText}')
/// SarAwareText(
///   'الإجمالي: $amount ${settings.currencySymbolText}',
///   isNewSar: settings.currencyIsNewSar,
///   style: TextStyle(fontSize: 16),
/// )
/// ```
class SarAwareText extends StatelessWidget {
  final String text;
  final bool isNewSar;
  final TextStyle? style;
  final TextAlign textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  const SarAwareText(
    this.text, {
    super.key,
    required this.isNewSar,
    this.style,
    this.textAlign = TextAlign.start,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    // Plain text mode — behave exactly like Text()
    if (!isNewSar || !text.contains('ر.س')) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final effectiveStyle =
        style ?? DefaultTextStyle.of(context).style.copyWith(inherit: true);

    return RichText(
      text: TextSpan(
        children: sarAwareSpans(text, isNewSar: isNewSar, style: effectiveStyle),
      ),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CurrencyChipLabel — used in the Settings screen chip for SAR
// ─────────────────────────────────────────────────────────────────────────────

/// Widget for rendering a currency option label inside a chip.
/// For the new SAR symbol it shows the image preview; for others plain text.
class CurrencyChipLabel extends StatelessWidget {
  final String value;
  final String label;
  final bool isSelected;
  final Color selectedFg;
  final Color normalFg;

  const CurrencyChipLabel({
    super.key,
    required this.value,
    required this.label,
    required this.isSelected,
    required this.selectedFg,
    required this.normalFg,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? selectedFg : normalFg;
    if (isNewSarSymbol(value)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SarSymbolImage(size: 18, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ],
      );
    }
    return Text(
      label,
      style: TextStyle(color: color, fontWeight: FontWeight.bold),
    );
  }
}
