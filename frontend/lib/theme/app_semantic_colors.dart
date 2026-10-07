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

/// نوع الفاتورة: لكل نوع لونه وهو في كل شاشاته وفي نافذة مراجعته، ليُعرف
/// النوع من النظرة الأولى فلا يقع خطأ إدخال بنوع الفاتورة.
enum InvoiceKind {
  sale('بيع'),
  saleScrap('بيع كسر'),
  purchase('شراء'),
  purchaseScrap('شراء كسر'),
  returned('مرتجع');

  const InvoiceKind(this.label);
  final String label;
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
    required this.invoiceSale,
    required this.invoiceSaleScrap,
    required this.invoicePurchase,
    required this.invoicePurchaseScrap,
    required this.invoiceReturn,
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
  final SemanticTone invoiceSale;
  final SemanticTone invoiceSaleScrap;
  final SemanticTone invoicePurchase;
  final SemanticTone invoicePurchaseScrap;
  final SemanticTone invoiceReturn;

  /// لون نوع الفاتورة.
  SemanticTone invoice(InvoiceKind kind) => switch (kind) {
    InvoiceKind.sale => invoiceSale,
    InvoiceKind.saleScrap => invoiceSaleScrap,
    InvoiceKind.purchase => invoicePurchase,
    InvoiceKind.purchaseScrap => invoicePurchaseScrap,
    InvoiceKind.returned => invoiceReturn,
  };

  /// شريط شاشة الفاتورة: في الفاتح لون النوع بنص أبيض، وفي الداكن حاوية
  /// النوع بنصه الفاتح -- قراءته ٤٫٥:١ في الوضعين (اختبار التباين).
  static ({Color background, Color foreground}) invoiceBar(
    BuildContext context,
    InvoiceKind kind,
  ) {
    final tone = of(context).invoice(kind);
    return Theme.of(context).brightness == Brightness.dark
        ? (background: tone.container, foreground: tone.onContainer)
        : (background: tone.fg, foreground: const Color(0xFFFFFFFF));
  }

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
    'invoiceSale': invoiceSale,
    'invoiceSaleScrap': invoiceSaleScrap,
    'invoicePurchase': invoicePurchase,
    'invoicePurchaseScrap': invoicePurchaseScrap,
    'invoiceReturn': invoiceReturn,
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
    // أخضر زيتوني / تركواز / بنفسجي / برتقالي محمر / أحمر: كما كانت، وغُمِّقت
    // لتُقرأ على البطاقة وعلى السطح وبنص أبيض (٤٫٥:١).
    invoiceSale: SemanticTone(
      Color(0xFF25702E),
      Color(0xFFDDF1DF),
      Color(0xFF0B3D14),
    ),
    invoiceSaleScrap: SemanticTone(
      Color(0xFF00695C),
      Color(0xFFD7F0EC),
      Color(0xFF00332D),
    ),
    invoicePurchase: SemanticTone(
      Color(0xFF5E35B1),
      Color(0xFFE8E0F7),
      Color(0xFF241047),
    ),
    invoicePurchaseScrap: SemanticTone(
      Color(0xFFA9300A),
      Color(0xFFFFE3D8),
      Color(0xFF4A1403),
    ),
    invoiceReturn: SemanticTone(
      Color(0xFFB71C1C),
      Color(0xFFFFDAD6),
      Color(0xFF410002),
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
    invoiceSale: SemanticTone(
      Color(0xFF81C995),
      Color(0xFF1B4D2B),
      Color(0xFFD6F2DD),
    ),
    invoiceSaleScrap: SemanticTone(
      Color(0xFF6FD8CB),
      Color(0xFF0F4A44),
      Color(0xFFCDF4EF),
    ),
    invoicePurchase: SemanticTone(
      Color(0xFFB9A5E8),
      Color(0xFF3A2A66),
      Color(0xFFE6DDFA),
    ),
    invoicePurchaseScrap: SemanticTone(
      Color(0xFFFFAB91),
      Color(0xFF6B2A12),
      Color(0xFFFFE0D4),
    ),
    invoiceReturn: SemanticTone(
      Color(0xFFEF9A9A),
      Color(0xFF7A1F1F),
      Color(0xFFFFDAD6),
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
      invoiceSale: SemanticTone.lerp(invoiceSale, other.invoiceSale, t),
      invoiceSaleScrap: SemanticTone.lerp(
        invoiceSaleScrap,
        other.invoiceSaleScrap,
        t,
      ),
      invoicePurchase: SemanticTone.lerp(
        invoicePurchase,
        other.invoicePurchase,
        t,
      ),
      invoicePurchaseScrap: SemanticTone.lerp(
        invoicePurchaseScrap,
        other.invoicePurchaseScrap,
        t,
      ),
      invoiceReturn: SemanticTone.lerp(invoiceReturn, other.invoiceReturn, t),
    );
  }
}
