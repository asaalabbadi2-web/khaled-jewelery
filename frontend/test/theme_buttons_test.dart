import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';

/// UI-3 (ADR-049): every kind of button has the theme's one shape and one
/// height -- none falls back to Flutter's pill, none is smaller than a finger,
/// and none casts a shadow (the owner, 17 Oct 2026: the buttons were loud).
void main() {
  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    final kinds = <String, ButtonStyle?>{
      'elevated': theme.elevatedButtonTheme.style,
      'filled': theme.filledButtonTheme.style,
      'outlined': theme.outlinedButtonTheme.style,
      'text': theme.textButtonTheme.style,
    };
    for (final MapEntry(key: kind, value: style) in kinds.entries) {
      test('$name: a $kind button has the one shape and height', () {
        expect(style, isNotNull, reason: 'no $kind button theme');
        final shape = style!.shape?.resolve({});
        expect(shape, isA<RoundedRectangleBorder>());
        expect(
          (shape as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(AppRadius.control),
        );
        expect(
          style.minimumSize?.resolve({})?.height,
          greaterThanOrEqualTo(kMinTapHeight),
        );
        expect(style.elevation?.resolve({}) ?? 0, 0, reason: 'flat');
      });
    }
  }
}
