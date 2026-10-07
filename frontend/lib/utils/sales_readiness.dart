/// Whether a sale can be saved, and if not, the first reason and where it is.
///
/// «Ready» means the server will take it (backend/routes/invoices.py
/// add_invoice): a branch, lines at a weight and a karat the shop sells, what
/// is paid no more than the total (cash and barter together), what remains
/// only when partial payments are on (the settings) -- and then only on a
/// named customer, never the walk-in one (`credit_needs_customer`, SALES-UX-2).
enum SalesReadinessKind { empty, notReady, ready }

enum SalesReadinessTarget { none, branch, customer, items, payment, goldPrice }

class SalesLineFacts {
  final double weight;
  final double karat;
  const SalesLineFacts({required this.weight, required this.karat});
}

class SalesReadinessFacts {
  final bool branchChosen;
  final List<SalesLineFacts> lines;
  final double total;

  /// What the payments add up to, in cash.
  final double paid;

  /// The barter's value, which settles part of the total.
  final double barter;
  final bool partialAllowed;

  /// A customer was chosen who is not the walk-in customer.
  final bool namedCustomer;
  final bool goldPriceKnown;

  const SalesReadinessFacts({
    required this.branchChosen,
    required this.lines,
    required this.total,
    required this.paid,
    this.barter = 0,
    this.partialAllowed = false,
    this.namedCustomer = false,
    this.goldPriceKnown = true,
  });
}

class SalesReadiness {
  final SalesReadinessKind kind;
  final String message;
  final SalesReadinessTarget target;
  final int? index;

  const SalesReadiness._(
    this.kind, {
    this.message = '',
    this.target = SalesReadinessTarget.none,
    this.index,
  });

  bool get isReady => kind == SalesReadinessKind.ready;
}

/// The server's tolerance for cash (backend `0.01`).
const double kSalesCashTolerance = 0.01;

const _sellableKarats = [18.0, 21.0, 22.0, 24.0];

SalesReadiness salesReadiness(
  SalesReadinessFacts facts, {
  required String Function(double) formatCash,
}) {
  SalesReadiness notReady(
    String message,
    SalesReadinessTarget target, [
    int? index,
  ]) => SalesReadiness._(
    SalesReadinessKind.notReady,
    message: message,
    target: target,
    index: index,
  );

  if (facts.lines.isEmpty) {
    return const SalesReadiness._(
      SalesReadinessKind.empty,
      message: 'أضف أصناف الفاتورة',
      target: SalesReadinessTarget.items,
    );
  }
  if (!facts.branchChosen) {
    return notReady('اختر الفرع', SalesReadinessTarget.branch);
  }

  for (var i = 0; i < facts.lines.length; i++) {
    final line = facts.lines[i];
    if (line.weight <= 0) {
      return notReady('أدخل وزن السطر ${i + 1}', SalesReadinessTarget.items, i);
    }
    if (!_sellableKarats.contains(line.karat)) {
      return notReady(
        'عيار السطر ${i + 1} يجب أن يكون 18 أو 21 أو 22 أو 24',
        SalesReadinessTarget.items,
        i,
      );
    }
  }

  if (!facts.goldPriceKnown) {
    return notReady(
      'سعر الذهب لم يُحمَّل؛ حدّثه قبل الحفظ',
      SalesReadinessTarget.goldPrice,
    );
  }

  if (facts.total <= kSalesCashTolerance) {
    return notReady(
      'إجمالي الفاتورة صفر؛ حدّد سعر السطر',
      SalesReadinessTarget.items,
    );
  }

  if (facts.barter - facts.total > kSalesCashTolerance) {
    return notReady(
      'قيمة المقايضة أكبر من إجمالي الفاتورة',
      SalesReadinessTarget.payment,
    );
  }
  final remaining = facts.total - facts.paid - facts.barter;
  if (remaining < -kSalesCashTolerance) {
    return notReady(
      'مجموع الدفعات أكبر من إجمالي الفاتورة',
      SalesReadinessTarget.payment,
    );
  }
  if (remaining > kSalesCashTolerance) {
    if (!facts.partialAllowed) {
      return notReady(
        'أكمل الدفع: يتبقى ${formatCash(remaining)}',
        SalesReadinessTarget.payment,
      );
    }
    if (!facts.namedCustomer) {
      return notReady(
        'البيع الآجل يحتاج عميلًا مسمّى، يتبقى ${formatCash(remaining)}',
        SalesReadinessTarget.customer,
      );
    }
  }

  return const SalesReadiness._(SalesReadinessKind.ready);
}

/// What the seller should see before saving, from what the seller can see --
/// the market price, never the cost (ADR-036): a sale below the gold's value
/// at market is a sale under cost, and one far above is a mistyped amount.
///
/// [net] is the sale without VAT. Wages (and a shop's margin) make a sale
/// worth more than the metal, so only a price a half above the market is
/// flagged high, and one under 97 % of the metal low.
List<String> salesPriceWarnings({
  required List<SalesLineFacts> lines,
  required double net,
  required double goldPrice24k,
  required String Function(double) formatCash,
}) {
  if (goldPrice24k <= 0 || net <= 0) return const [];
  var weight = 0.0;
  var market = 0.0;
  for (final l in lines) {
    weight += l.weight;
    market += l.weight * goldPrice24k * l.karat / 24.0;
  }
  if (weight <= 0 || market <= 0) return const [];

  final perGram = net / weight;
  final marketPerGram = market / weight;
  if (net < market * 0.97) {
    return [
      'سعر البيع ${formatCash(net)} أقل من قيمة الذهب بسعر السوق '
          '(${formatCash(market)}): بيع تحت التكلفة، وقد يُحجز لاعتماد المدير.',
    ];
  }
  if (perGram > marketPerGram * 1.5) {
    return [
      'سعر الجرام ${formatCash(perGram)} أعلى بكثير من سعر السوق '
          '(${formatCash(marketPerGram)}). تأكد من المبلغ والوزن.',
    ];
  }
  return const [];
}
