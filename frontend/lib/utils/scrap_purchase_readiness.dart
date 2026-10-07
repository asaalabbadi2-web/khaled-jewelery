/// Whether a scrap purchase from a customer can be saved, and if not, the
/// first reason and where it is (SALES-UX-9).
///
/// «Ready» means the screen would take it and the server hold nothing against
/// it: a branch; lines with a weight (a standing weight, stones no heavier
/// than it, a net above zero) or, failing that, an amount; a karat the shop
/// buys; a customer who is not the walk-in one has their identity on file;
/// and the purchase is paid in full -- 3 of 776 on the 6 Oct copy were not.
enum ScrapPurchaseReadinessKind { empty, notReady, ready }

enum ScrapPurchaseTarget { none, branch, customer, items, payment, goldPrice }

class ScrapLineFacts {
  final double standing;
  final double stones;

  /// The net weight (standing - stones), as the line computes it.
  final double weight;
  final double karat;

  /// What the line is paid, with or without a weight.
  final double total;
  const ScrapLineFacts({
    required this.standing,
    required this.stones,
    required this.weight,
    required this.karat,
    required this.total,
  });

  bool get hasWeight => weight > 0;
}

class ScrapPurchaseFacts {
  final bool branchChosen;
  final List<ScrapLineFacts> lines;
  final double total;
  final double paid;

  /// The name of the chosen customer when they are not the walk-in one and
  /// their id number, its version or their birth date is missing.
  final String? customerMissingIdentity;
  final bool goldPriceKnown;

  const ScrapPurchaseFacts({
    required this.branchChosen,
    required this.lines,
    required this.total,
    required this.paid,
    this.customerMissingIdentity,
    this.goldPriceKnown = true,
  });
}

class ScrapPurchaseReadiness {
  final ScrapPurchaseReadinessKind kind;
  final String message;
  final ScrapPurchaseTarget target;
  final int? index;

  const ScrapPurchaseReadiness._(
    this.kind, {
    this.message = '',
    this.target = ScrapPurchaseTarget.none,
    this.index,
  });

  bool get isReady => kind == ScrapPurchaseReadinessKind.ready;
}

const double kScrapCashTolerance = 0.01;
const _buyableKarats = [18.0, 21.0, 22.0, 24.0];

ScrapPurchaseReadiness scrapPurchaseReadiness(
  ScrapPurchaseFacts facts, {
  required String Function(double) formatCash,
}) {
  ScrapPurchaseReadiness notReady(
    String message,
    ScrapPurchaseTarget target, [
    int? index,
  ]) => ScrapPurchaseReadiness._(
    ScrapPurchaseReadinessKind.notReady,
    message: message,
    target: target,
    index: index,
  );

  if (facts.lines.isEmpty) {
    return const ScrapPurchaseReadiness._(
      ScrapPurchaseReadinessKind.empty,
      message: 'أضف أصناف الفاتورة',
      target: ScrapPurchaseTarget.items,
    );
  }
  if (!facts.branchChosen) {
    return notReady('اختر الفرع', ScrapPurchaseTarget.branch);
  }

  for (var i = 0; i < facts.lines.length; i++) {
    final l = facts.lines[i];
    final n = i + 1;
    if (!l.hasWeight && l.total <= 0) {
      return notReady(
        'أدخل وزن السطر $n أو مبلغه',
        ScrapPurchaseTarget.items,
        i,
      );
    }
    if (!_buyableKarats.contains(l.karat)) {
      return notReady(
        'عيار السطر $n يجب أن يكون 18 أو 21 أو 22 أو 24',
        ScrapPurchaseTarget.items,
        i,
      );
    }
    // An amount-only line weighs nothing and is taken as it is.
    if (l.hasWeight || l.standing > 0) {
      if (l.standing <= 0) {
        return notReady(
          'أدخل الوزن القائم للسطر $n',
          ScrapPurchaseTarget.items,
          i,
        );
      }
      if (l.stones > l.standing + 0.0001) {
        return notReady(
          'وزن أحجار السطر $n أكبر من وزنه القائم',
          ScrapPurchaseTarget.items,
          i,
        );
      }
    }
  }

  if (facts.total <= kScrapCashTolerance) {
    return notReady(
      'إجمالي الفاتورة صفر؛ حدّد المبلغ أو الوزن',
      ScrapPurchaseTarget.items,
    );
  }

  final who = facts.customerMissingIdentity;
  if (who != null) {
    return notReady(
      'العميل «$who» بلا رقم هوية أو نسختها أو تاريخ ميلاد',
      ScrapPurchaseTarget.customer,
    );
  }

  if (!facts.goldPriceKnown) {
    return notReady(
      'سعر الذهب لم يُحمَّل؛ حدّثه قبل الحفظ',
      ScrapPurchaseTarget.goldPrice,
    );
  }

  final remaining = facts.total - facts.paid;
  if (remaining < -kScrapCashTolerance) {
    return notReady(
      'مجموع الدفعات أكبر من إجمالي الفاتورة',
      ScrapPurchaseTarget.payment,
    );
  }
  if (remaining > kScrapCashTolerance) {
    return notReady(
      'أكمل الدفع: يتبقى ${formatCash(remaining)}',
      ScrapPurchaseTarget.payment,
    );
  }

  return const ScrapPurchaseReadiness._(ScrapPurchaseReadinessKind.ready);
}

/// What the buyer should see before saving, from what the buyer can see --
/// the live gold price: paying above it holds the invoice for the manager
/// (above_live_price, 0.5 % over), and far under it is a mistyped amount.
List<String> scrapPurchasePriceWarnings({
  required List<ScrapLineFacts> lines,
  required double goldPrice24k,
  required String Function(double) formatCash,
}) {
  if (goldPrice24k <= 0) return const [];
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (!l.hasWeight || l.total <= 0) continue;
    final live = goldPrice24k * l.karat / 24.0;
    final perGram = l.total / l.weight;
    if (perGram > live * 1.005) {
      out.add(
        'السطر ${i + 1}: تدفع ${formatCash(perGram)} للجرام، أعلى من السعر '
        'المباشر (${formatCash(live)}): تُحفظ الفاتورة ويُحجز '
        'لاعتماد المدير.',
      );
    } else if (perGram < live * 0.5) {
      out.add(
        'السطر ${i + 1}: ${formatCash(perGram)} للجرام أقل بكثير من السعر '
        'المباشر (${formatCash(live)}). تأكد من المبلغ والوزن.',
      );
    }
  }
  return out;
}
