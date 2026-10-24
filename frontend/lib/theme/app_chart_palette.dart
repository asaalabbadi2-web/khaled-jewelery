import 'package:flutter/material.dart';

/// The colours of a chart's marks (bonus study م3و), by the job they do --
/// the text beside them keeps the text colours.
///
/// [categorical]: identities (a rule, a department), gold first, in a fixed
/// order never cycled; a fifth folds into «أخرى» in [other]. Validated with
/// the dataviz palette checks against the card in each mode -- lightness
/// band, chroma, colour-blind and normal-vision separation, contrast. In
/// light the aqua sits under 3:1 on white, so each slice carries its name
/// and figure beside it.
///
/// [single]: one series of magnitude (a total by month, by employee).
abstract final class AppChartPalette {
  static const _light = [Color(0xFFC98500), Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A)];
  static const _dark = [Color(0xFFC98500), Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70)];

  static bool _isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  static List<Color> categorical(BuildContext context) => _isDark(context) ? _dark : _light;

  static Color single(BuildContext context) => categorical(context).first;

  static Color other(BuildContext context) => Theme.of(context).colorScheme.outline;
}
