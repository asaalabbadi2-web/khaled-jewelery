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

/// خ٣ (ADR-050): in the dark theme no surface is painted near-white -- the
/// theme's light text vanishes on it. The other half of
/// [expectNoTextVanishesOnDark]: the clearing monitor painted its background
/// F5F5F5 and its cards white, and every text on them read white on white.
void expectNoLightSurfaceOnDark(WidgetTester tester) {
  final light = <String>[];
  void check(Color? color, String what) {
    if (color != null && color.a > 0.5 && color.computeLuminance() > 0.7) {
      light.add('$what ${color.toARGB32().toRadixString(16)}');
    }
  }

  for (final s in tester.widgetList<Scaffold>(find.byType(Scaffold))) {
    check(s.backgroundColor, 'Scaffold');
  }
  for (final b in tester.widgetList<AppBar>(find.byType(AppBar))) {
    check(b.backgroundColor, 'AppBar');
  }
  for (final c in tester.widgetList<Card>(find.byType(Card))) {
    check(c.color, 'Card');
  }
  for (final element in find.byType(Container).evaluate()) {
    // An accent line or a dot (the 3-px bar beside a heading) holds no text:
    // a surface is one a word can sit on.
    final box = element.renderObject;
    if (box is RenderBox &&
        box.hasSize &&
        (box.size.width < 24 || box.size.height < 24)) {
      continue;
    }
    final c = element.widget as Container;
    check(c.color, 'Container');
    final d = c.decoration;
    if (d is BoxDecoration) check(d.color, 'Container');
  }
  for (final m in tester.widgetList<Material>(find.byType(Material))) {
    if (m.type != MaterialType.transparency) check(m.color, 'Material');
  }
  expect(light, isEmpty, reason: 'surfaces near-white in the dark theme');
}
