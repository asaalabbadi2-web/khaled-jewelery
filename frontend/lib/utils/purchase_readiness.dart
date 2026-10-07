/// Whether a supplier purchase invoice can be saved, and if not, the first
/// reason and where it is.
///
/// «Ready» means the server will take it (backend/routes/invoices.py
/// add_invoice): branch and supplier, weights on every line, a return no
/// heavier than its original line, gold settlement lines each on a gold safe
/// that takes their karat (karat_mismatch_for_safe_box), on the employee's
/// safe when employee gold safes are on (gold_settlement_forced_employee_safe),
/// and never on an unposted invoice (unposted_no_gold_settlement).
///
/// Weights are entered as items only: the manual weights card is gone. An
/// invoice being edited that holds weight lines without items (an office
/// reservation's purchase) is not saved from this screen -- an edit replaces
/// the invoice with what the screen sends, and it would drop them.
///
/// Cash is held to the cash the supplier is owed (wages and VAT --
/// Invoice.cash_obligation, Phase 13), stricter than add_invoice, which
/// compares payments against the invoice total that includes the gold value.
enum PurchaseReadinessKind { empty, notReady, ready }

enum PurchaseSettlement { credit, barter, partial }

enum PurchaseReadinessTarget {
  none,
  branch,
  supplier,
  goldPrice,
  item,
  cashPaid,
  paymentMethod,
  goldLine,
}

class PurchaseItemFacts {
  final double weight;
  final double? maxWeight;
  const PurchaseItemFacts({required this.weight, this.maxWeight});
}

class PurchaseGoldLineFacts {
  final int? safeId;
  final int karat;
  final double weight;

  /// The karat the chosen safe is fixed to, when it is.
  final int? safeFixedKarat;

  const PurchaseGoldLineFacts({
    required this.safeId,
    required this.karat,
    required this.weight,
    this.safeFixedKarat,
  });

  bool get isEmpty => safeId == null && weight <= 0;
}

class PurchaseReadinessFacts {
  final bool branchChosen;
  final bool supplierChosen;
  final bool goldPriceKnown;
  final List<PurchaseItemFacts> items;

  /// The invoice being edited holds weight lines without items, which this
  /// screen neither shows nor sends.
  final bool editsHeldWeightLines;
  final PurchaseSettlement settlement;
  final double cashDue;
  final double cashPaid;
  final bool paymentMethodsAvailable;
  final bool paymentMethodChosen;
  final bool allowPartialPayments;
  final List<PurchaseGoldLineFacts> goldLines;
  final bool goldSafesAvailable;

  /// Employee gold safes are on and this employee has one: the server takes
  /// gold settlements on that safe only.
  final int? forcedGoldSafeId;

  /// With auto-post off the invoice is saved unposted, and the server takes
  /// no gold settlement on an unposted invoice.
  final bool autoPostInvoices;

  const PurchaseReadinessFacts({
    required this.branchChosen,
    required this.supplierChosen,
    this.goldPriceKnown = true,
    this.items = const [],
    this.editsHeldWeightLines = false,
    this.settlement = PurchaseSettlement.credit,
    this.cashDue = 0,
    this.cashPaid = 0,
    this.paymentMethodsAvailable = true,
    this.paymentMethodChosen = true,
    this.allowPartialPayments = true,
    this.goldLines = const [],
    this.goldSafesAvailable = true,
    this.forcedGoldSafeId,
    this.autoPostInvoices = true,
  });
}

class PurchaseReadiness {
  final PurchaseReadinessKind kind;
  final String message;
  final PurchaseReadinessTarget target;
  final int? index;

  const PurchaseReadiness._(
    this.kind, {
    this.message = '',
    this.target = PurchaseReadinessTarget.none,
    this.index,
  });

  bool get isReady => kind == PurchaseReadinessKind.ready;
}

/// The server's tolerance for a VAT figure and for cash (backend `tol = 0.01`).
const double kPurchaseCashTolerance = 0.01;

PurchaseReadiness purchaseReadiness(
  PurchaseReadinessFacts facts, {
  required String Function(double) formatCash,
}) {
  PurchaseReadiness notReady(
    String message,
    PurchaseReadinessTarget target, [
    int? index,
  ]) => PurchaseReadiness._(
    PurchaseReadinessKind.notReady,
    message: message,
    target: target,
    index: index,
  );

  if (facts.editsHeldWeightLines) {
    return notReady(
      'في هذه الفاتورة أوزان بلا أصناف لا تعرضها هذه الشاشة، فلا تُعدَّل منها',
      PurchaseReadinessTarget.none,
    );
  }
  if (!facts.branchChosen) {
    return notReady('اختر الفرع', PurchaseReadinessTarget.branch);
  }
  if (!facts.supplierChosen) {
    return notReady('اختر المورد', PurchaseReadinessTarget.supplier);
  }

  if (facts.items.isEmpty) {
    return const PurchaseReadiness._(
      PurchaseReadinessKind.empty,
      message: 'أضف أصناف الفاتورة',
      target: PurchaseReadinessTarget.item,
    );
  }

  for (var i = 0; i < facts.items.length; i++) {
    final item = facts.items[i];
    if (item.weight <= 0) {
      return notReady(
        'أدخل وزن الصنف ${i + 1}',
        PurchaseReadinessTarget.item,
        i,
      );
    }
    final max = item.maxWeight;
    if (max != null && item.weight - max > 0.0005) {
      return notReady(
        'وزن الصنف ${i + 1} أكبر من وزنه في الفاتورة الأصلية '
        '(${max.toStringAsFixed(3)} جم)',
        PurchaseReadinessTarget.item,
        i,
      );
    }
  }

  if (!facts.goldPriceKnown) {
    return notReady(
      'سعر الذهب لم يُحمَّل؛ حدّثه قبل الحفظ',
      PurchaseReadinessTarget.goldPrice,
    );
  }

  // Cash is sent only for a partial settlement (the payload's rule).
  if (facts.settlement == PurchaseSettlement.partial && facts.cashPaid > 0) {
    if (facts.cashPaid - facts.cashDue > kPurchaseCashTolerance) {
      return notReady(
        'المدفوع نقدًا أكبر من النقد المستحق (${formatCash(facts.cashDue)})',
        PurchaseReadinessTarget.cashPaid,
      );
    }
    if (facts.paymentMethodsAvailable && !facts.paymentMethodChosen) {
      return notReady(
        'اختر وسيلة الدفع',
        PurchaseReadinessTarget.paymentMethod,
      );
    }
    final isPartial = facts.cashDue - facts.cashPaid > kPurchaseCashTolerance;
    if (isPartial && !facts.allowPartialPayments) {
      return notReady(
        'الدفع النقدي الجزئي غير مفعّل في الإعدادات؛ '
        'ادفع ${formatCash(facts.cashDue)} كاملًا أو اجعلها آجلة',
        PurchaseReadinessTarget.cashPaid,
      );
    }
  }

  // Gold is sent only for barter or partial (the payload's rule).
  final goldContext =
      facts.settlement == PurchaseSettlement.barter ||
      facts.settlement == PurchaseSettlement.partial;
  if (goldContext) {
    final used = <int>[
      for (var i = 0; i < facts.goldLines.length; i++)
        if (!facts.goldLines[i].isEmpty) i,
    ];

    if (facts.settlement == PurchaseSettlement.barter && used.isEmpty) {
      return notReady('أضف سداد ذهب', PurchaseReadinessTarget.goldLine);
    }
    if (used.isNotEmpty && !facts.goldSafesAvailable) {
      return notReady(
        'لا توجد خزائن ذهب متاحة',
        PurchaseReadinessTarget.goldLine,
      );
    }

    for (final i in used) {
      final line = facts.goldLines[i];
      final n = i + 1;
      if (line.safeId == null) {
        return notReady(
          'اختر خزينة الذهب لسطر السداد $n',
          PurchaseReadinessTarget.goldLine,
          i,
        );
      }
      if (line.weight <= 0) {
        return notReady(
          'أدخل وزن سطر السداد $n',
          PurchaseReadinessTarget.goldLine,
          i,
        );
      }
      final forced = facts.forcedGoldSafeId;
      if (forced != null && line.safeId != forced) {
        return notReady(
          'سداد الذهب على خزينة ذهب الموظف فقط (سطر السداد $n)',
          PurchaseReadinessTarget.goldLine,
          i,
        );
      }
      final fixed = line.safeFixedKarat;
      if (fixed != null && fixed != line.karat) {
        return notReady(
          'خزينة سطر السداد $n لعيار $fixed فقط',
          PurchaseReadinessTarget.goldLine,
          i,
        );
      }
    }

    if (used.isNotEmpty && !facts.autoPostInvoices) {
      return notReady(
        'الترحيل التلقائي معطّل، والفاتورة غير المرحّلة لا تقبل سداد ذهب؛ '
        'أزل سداد الذهب',
        PurchaseReadinessTarget.goldLine,
      );
    }
  }

  return const PurchaseReadiness._(PurchaseReadinessKind.ready);
}
