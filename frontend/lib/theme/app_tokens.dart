/// UI-3 (ADR-049): one scale for space and corners. A screen says
/// `AppSpace.md`, `AppRadius.card` -- not 12 or 16 -- so the app keeps one
/// rhythm. The values are the ones the app already used most (policy; they
/// may change by a design decision, the names stay).
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadius {
  /// Chips, badges, small tags.
  static const double chip = 8;

  /// Buttons and fields.
  static const double control = 12;

  /// Cards, dialogs, sheets.
  static const double card = 16;

  /// A pill.
  static const double pill = 999;
}

/// The smallest height of anything pressed: a finger on a tablet as well as
/// a mouse (the owner, 16 Oct 2026: more than one kind of device).
const double kMinTapHeight = 44;
