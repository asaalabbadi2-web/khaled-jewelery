/// What stands in the way of saving a voucher (VOUCHER-UX-1): the first reason
/// only, in the order the employee fills the screen -- the party, then each
/// line's account and amount, then the invoice a payment is declared for.
/// The save keeps its own checks; this is what the footer says before it.
library;

/// One weight of a gold line.
class VoucherGoldFacts {
  final double weight;
  final bool hasKarat;

  /// The standing weight and the stones, when typed.
  final double? gross;
  final double? stones;

  const VoucherGoldFacts({
    required this.weight,
    required this.hasKarat,
    this.gross,
    this.stones,
  });
}

class VoucherLineFacts {
  final bool hasAccount;
  final bool isGold;
  final double amount;
  final List<VoucherGoldFacts> gold;

  const VoucherLineFacts({
    required this.hasAccount,
    required this.isGold,
    required this.amount,
    this.gold = const [],
  });
}

class VoucherFacts {
  /// 'customer' | 'supplier' | 'employee' | 'other'
  final String partyType;
  final bool partyChosen;
  final List<VoucherLineFacts> lines;

  /// A supplier payment declared for an invoice that names none, or pays more
  /// than is open on it.
  final bool cashInvoiceMissing;
  final bool cashExceedsInvoice;

  /// The lines entered by hand do not balance (debit against credit).
  final bool unbalanced;

  const VoucherFacts({
    required this.partyType,
    required this.partyChosen,
    required this.lines,
    this.cashInvoiceMissing = false,
    this.cashExceedsInvoice = false,
    this.unbalanced = false,
  });
}

const _partyAsked = {
  'customer': 'اختر العميل',
  'supplier': 'اختر المورد',
  'employee': 'اختر الموظف',
  'other': 'اختر الحساب',
};

/// The first reason the voucher is not ready, or null when it is.
String? voucherReadiness(VoucherFacts f) {
  if (!f.partyChosen) return _partyAsked[f.partyType] ?? 'اختر الطرف';

  for (var i = 0; i < f.lines.length; i++) {
    final line = f.lines[i];
    final n = i + 1;
    if (!line.hasAccount) return 'اختر حساب السطر $n';
    if (!line.isGold) {
      if (line.amount <= 0) return 'أدخل مبلغ السطر $n';
      continue;
    }
    final weighed = line.gold.where((g) => g.weight > 0).toList();
    if (weighed.isEmpty) return 'أدخل وزن السطر $n';
    if (weighed.any((g) => !g.hasKarat)) return 'اختر عيار السطر $n';
    for (final g in weighed) {
      final stones = g.stones ?? 0;
      final gross = g.gross ?? (g.weight + stones);
      if (stones < 0 || gross + 0.001 < g.weight) {
        return 'الوزن القائم في السطر $n أقل من الصافي';
      }
    }
  }

  if (f.unbalanced) return 'السطور غير متوازنة';
  if (f.cashInvoiceMissing) return 'اختر الفاتورة التي تخصها الدفعة';
  if (f.cashExceedsInvoice) return 'مبلغ السند أكبر من المتبقي على الفاتورة';
  return null;
}
