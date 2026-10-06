import 'package:flutter/material.dart';

/// لون ذو معنى: لون النص على البطاقة، وحاوية خفيفة، ونص الحاوية.
@immutable
class SemanticTone {
  const SemanticTone(this.fg, this.container, this.onContainer);

  final Color fg;
  final Color container;
  final Color onContainer;

  static SemanticTone lerp(SemanticTone a, SemanticTone b, double t) =>
      SemanticTone(
        Color.lerp(a.fg, b.fg, t)!,
        Color.lerp(a.container, b.container, t)!,
        Color.lerp(a.onContainer, b.onContainer, t)!,
      );
}

/// الألوان ذات المعنى في التطبيق (ثيم-٠): حالة الجاهزية، ومدين/دائن،
/// وذهب/نقد، والعيارات. لكل وضع نسخته، وتباين كل لون مع البطاقة
/// والخلفية ونص حاويته لا يقل عن ٤٫٥:١.
///
/// الشاشات تقرؤها بـ `AppSemanticColors.of(context)` ولا تكتب لونًا بقيمته.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.ready,
    required this.blocked,
    required this.warning,
    required this.info,
    required this.debit,
    required this.credit,
    required this.gold,
    required this.cash,
    required this.karat18,
    required this.karat21,
    required this.karat22,
    required this.karat24,
  });

  final SemanticTone ready;
  final SemanticTone blocked;
  final SemanticTone warning;
  final SemanticTone info;
  final SemanticTone debit;
  final SemanticTone credit;
  final SemanticTone gold;
  final SemanticTone cash;
  final SemanticTone karat18;
  final SemanticTone karat21;
  final SemanticTone karat22;
  final SemanticTone karat24;

  static AppSemanticColors of(BuildContext context) =>
      Theme.of(context).extension<AppSemanticColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  /// لون العيار؛ أي عيار غير معروف يأخذ لون الذهب.
  SemanticTone karat(int karat) => switch (karat) {
    18 => karat18,
    21 => karat21,
    22 => karat22,
    24 => karat24,
    _ => gold,
  };

  Map<String, SemanticTone> get tones => {
    'ready': ready,
    'blocked': blocked,
    'warning': warning,
    'info': info,
    'debit': debit,
    'credit': credit,
    'gold': gold,
    'cash': cash,
    'karat18': karat18,
    'karat21': karat21,
    'karat22': karat22,
    'karat24': karat24,
  };

  static const light = AppSemanticColors(
    ready: SemanticTone(
      Color(0xFF1E6B2C),
      Color(0xFFDDF1DF),
      Color(0xFF0B3D14),
    ),
    blocked: SemanticTone(
      Color(0xFFBA1A1A),
      Color(0xFFFFDAD6),
      Color(0xFF410002),
    ),
    warning: SemanticTone(
      Color(0xFF8A5300),
      Color(0xFFFFE8C7),
      Color(0xFF3D2400),
    ),
    info: SemanticTone(Color(0xFF1E5BB0), Color(0xFFDCE8FA), Color(0xFF0B2A57)),
    debit: SemanticTone(
      Color(0xFF0F6E56),
      Color(0xFFE1F5EE),
      Color(0xFF04342A),
    ),
    credit: SemanticTone(
      Color(0xFFA32D2D),
      Color(0xFFFCEBEB),
      Color(0xFF4A0E0E),
    ),
    gold: SemanticTone(Color(0xFF87600A), Color(0xFFF4E4C1), Color(0xFF3A2C00)),
    cash: SemanticTone(Color(0xFF2F5576), Color(0xFFE2EBF3), Color(0xFF0E2539)),
    karat18: SemanticTone(
      Color(0xFFB71C1C),
      Color(0xFFFFF0F0),
      Color(0xFFB71C1C),
    ),
    karat21: SemanticTone(
      Color(0xFF795500),
      Color(0xFFFAF4E5),
      Color(0xFF795500),
    ),
    karat22: SemanticTone(
      Color(0xFF004D40),
      Color(0xFFEAF9F9),
      Color(0xFF004D40),
    ),
    karat24: SemanticTone(
      Color(0xFF4A148C),
      Color(0xFFF3EEF8),
      Color(0xFF4A148C),
    ),
  );

  static const dark = AppSemanticColors(
    ready: SemanticTone(
      Color(0xFF7FD08A),
      Color(0xFF1F3A24),
      Color(0xFFCDEFD2),
    ),
    blocked: SemanticTone(
      Color(0xFFFFB4AB),
      Color(0xFF93000A),
      Color(0xFFFFDAD6),
    ),
    warning: SemanticTone(
      Color(0xFFFFB95C),
      Color(0xFF4A3000),
      Color(0xFFFFE1B8),
    ),
    info: SemanticTone(Color(0xFF9DC2FF), Color(0xFF17345E), Color(0xFFDCE8FA)),
    debit: SemanticTone(
      Color(0xFF6FD3B4),
      Color(0xFF0D3B30),
      Color(0xFFC9F2E5),
    ),
    credit: SemanticTone(
      Color(0xFFFF9E9E),
      Color(0xFF4D1A1A),
      Color(0xFFFFDADA),
    ),
    gold: SemanticTone(Color(0xFFE6C24F), Color(0xFF4A3C0E), Color(0xFFFFE08B)),
    cash: SemanticTone(Color(0xFFA9C7E6), Color(0xFF1F3347), Color(0xFFDDEBF8)),
    karat18: SemanticTone(
      Color(0xFFFF9E9E),
      Color(0xFF3D1A1A),
      Color(0xFFFF9E9E),
    ),
    karat21: SemanticTone(
      Color(0xFFE6C24F),
      Color(0xFF3A3112),
      Color(0xFFE6C24F),
    ),
    karat22: SemanticTone(
      Color(0xFF6FD8CB),
      Color(0xFF123733),
      Color(0xFF6FD8CB),
    ),
    karat24: SemanticTone(
      Color(0xFFD1A8F0),
      Color(0xFF2E1D3D),
      Color(0xFFD1A8F0),
    ),
  );

  @override
  AppSemanticColors copyWith() => this;

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      ready: SemanticTone.lerp(ready, other.ready, t),
      blocked: SemanticTone.lerp(blocked, other.blocked, t),
      warning: SemanticTone.lerp(warning, other.warning, t),
      info: SemanticTone.lerp(info, other.info, t),
      debit: SemanticTone.lerp(debit, other.debit, t),
      credit: SemanticTone.lerp(credit, other.credit, t),
      gold: SemanticTone.lerp(gold, other.gold, t),
      cash: SemanticTone.lerp(cash, other.cash, t),
      karat18: SemanticTone.lerp(karat18, other.karat18, t),
      karat21: SemanticTone.lerp(karat21, other.karat21, t),
      karat22: SemanticTone.lerp(karat22, other.karat22, t),
      karat24: SemanticTone.lerp(karat24, other.karat24, t),
    );
  }
}
