import 'package:flutter/material.dart';

import 'app_semantic_colors.dart';
import 'app_tokens.dart';

/// UI-3 (ADR-049): a screen is calm when one action is strong and the rest
/// are soft (the owner, 17 Oct 2026: the buttons were loud).
///
/// - the one primary action (a document's save): `FilledButton`, flat, in the
///   theme's color -- or [primary] in its document's tone;
/// - secondary actions: `FilledButton.tonal` -- a light fill, dark text -- or
///   [tonal] in a tone (add a line, a new customer, a quick action);
/// - an act that cannot be taken back (delete, cancel, reverse): [danger],
///   and only in the dialog that confirms it;
/// - the rest: `OutlinedButton` / `TextButton`.
///
/// Every pair here is a tested 4.5:1 one (theme_contrast_test): a tone's
/// container with its own text, and in light mode its color with white.
abstract final class AppButtonStyles {
  /// A secondary action in [tone]: its light container, its dark text.
  static ButtonStyle tonal(SemanticTone tone) => FilledButton.styleFrom(
    backgroundColor: tone.container,
    foregroundColor: tone.onContainer,
    elevation: 0,
  );

  /// An action of a kind -- a way to pay, a voucher type to create: the
  /// kind's light container framed in its own strong color, its dark text,
  /// its icon in the strong color. Set apart from the plain soft buttons
  /// (the owner, 17 Oct 2026) without the weight of a filled one.
  static ButtonStyle kind(SemanticTone tone) => FilledButton.styleFrom(
    backgroundColor: tone.container,
    foregroundColor: tone.onContainer,
    iconColor: tone.fg,
    side: BorderSide(color: tone.fg, width: 1.5),
    elevation: 0,
  );

  /// The one primary action in [tone]: its color with white text in light
  /// mode; its container with its light text in dark mode, where the color
  /// itself is too light to carry white.
  static ButtonStyle primary(BuildContext context, SemanticTone tone) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return FilledButton.styleFrom(
      backgroundColor: dark ? tone.container : tone.fg,
      foregroundColor: dark ? tone.onContainer : Colors.white,
      elevation: 0,
      minimumSize: const Size(160, 48),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
    );
  }

  /// The confirm button of an act that cannot be taken back: the theme's
  /// error color with its own text (tested 4.5:1 in both modes).
  static ButtonStyle danger(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.styleFrom(
      backgroundColor: scheme.error,
      foregroundColor: scheme.onError,
      elevation: 0,
    );
  }
}
