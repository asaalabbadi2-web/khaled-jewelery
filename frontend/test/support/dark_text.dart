import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// UI-5 (ADR-049): in the dark theme no text is painted near-black -- it
/// vanishes on the dark background -- except in one of the theme's own
/// «on…» colors (onPrimary on the bright gold, and the like): those are
/// pairs the theme sets with their background, tested in
/// theme_contrast_test.
void expectNoTextVanishesOnDark(WidgetTester tester) {
  final scheme = Theme.of(
    tester.element(find.byType(Scaffold).first),
  ).colorScheme;
  final paired = {
    scheme.onPrimary,
    scheme.onSecondary,
    scheme.onTertiary,
    scheme.onError,
    scheme.onInverseSurface,
  };
  final dark = <String>[];
  for (final p in tester.renderObjectList<RenderParagraph>(
    find.byType(RichText),
  )) {
    final color = p.text.style?.color;
    if (color != null &&
        color.a > 0.5 &&
        color.computeLuminance() < 0.05 &&
        !paired.contains(color)) {
      dark.add(p.text.toPlainText());
    }
  }
  expect(dark, isEmpty, reason: 'text that vanishes on dark');
}
