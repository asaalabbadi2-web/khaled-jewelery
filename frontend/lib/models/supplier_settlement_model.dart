/// تسوية فروقات حساب المورد (SAD) — نموذج عرض فقط.
///
/// هذا النموذج **لا يحسب محاسبة**. كل القيم المالية والوزنية والاتجاه
/// والحدود تأتي محسوبة من الخادم، وما هنا إلا حمل لها وعرضها. تحديدًا لا
/// يُشتق هنا: مدين/دائن · اتجاه القيد · رصيد المورد · التحويل للعيار
/// الرئيسي · الاستهلاك الشهري · الحدود · توجيه الحسابات.
library;

/// العيارات بالترتيب الذي تُعرض به. مفاتيحها كما يرسلها الخادم.
const List<String> kSettlementKaratKeys = ['18k', '21k', '22k', '24k'];

double? _toDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

DateTime? _toDate(dynamic value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

/// يحوّل خريطة الأوزان القادمة من الخادم دون تغيير قيمها.
Map<String, double> _toWeights(dynamic value) {
  if (value is! Map) return const {};
  final result = <String, double>{};
  value.forEach((key, raw) {
    final parsed = _toDouble(raw);
    if (parsed != null) result[key.toString()] = parsed;
  });
  return result;
}

class SupplierSettlementAdjustment {
  final int id;
  final String adjustmentNumber;
  final int supplierId;
  final String? supplierName;
  final String status;
  final String reasonCode;
  final String? note;

  /// لقطة الرصيد وقت إنشاء المسودة — كما أرجعها الخادم.
  final double balanceBeforeFinancial;
  final Map<String, double> balanceBeforeWeight;
  final DateTime? snapshotCapturedAt;

  /// ما رُحِّل فعلًا (يُملأ عند الترحيل فقط).
  final double? postedAmountCash;
  final Map<String, double> postedAmountWeight;

  final int? policyId;
  final String? periodKey;

  /// مراجع الأثر المحاسبي. الخادم يرجع المعرّفات لا الأرقام.
  final int? voucherId;
  final int? journalEntryId;

  /// وثيقة العكس تشير إلى أصلها عبر هذا الحقل.
  final int? reversalOfId;

  final String? createdBy;
  final DateTime? createdAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final bool approvedByManager;
  final String? postedBy;
  final DateTime? postedAt;
  final String? reversedBy;
  final DateTime? reversedAt;
  final String? reversalReason;
  final String? cancelledBy;
  final DateTime? cancelledAt;
  final String? cancellationReason;

  const SupplierSettlementAdjustment({
    required this.id,
    required this.adjustmentNumber,
    required this.supplierId,
    required this.status,
    required this.reasonCode,
    this.supplierName,
    this.note,
    this.balanceBeforeFinancial = 0.0,
    this.balanceBeforeWeight = const {},
    this.snapshotCapturedAt,
    this.postedAmountCash,
    this.postedAmountWeight = const {},
    this.policyId,
    this.periodKey,
    this.voucherId,
    this.journalEntryId,
    this.reversalOfId,
    this.createdBy,
    this.createdAt,
    this.approvedBy,
    this.approvedAt,
    this.approvedByManager = false,
    this.postedBy,
    this.postedAt,
    this.reversedBy,
    this.reversedAt,
    this.reversalReason,
    this.cancelledBy,
    this.cancelledAt,
    this.cancellationReason,
  });

  factory SupplierSettlementAdjustment.fromJson(Map<String, dynamic> json) {
    return SupplierSettlementAdjustment(
      id: (json['id'] as num).toInt(),
      adjustmentNumber: json['adjustment_number']?.toString() ?? '',
      supplierId: (json['supplier_id'] as num).toInt(),
      supplierName: json['supplier_name']?.toString(),
      status: json['status']?.toString() ?? kSettlementStatusDraft,
      reasonCode: json['reason_code']?.toString() ?? '',
      note: json['note']?.toString(),
      balanceBeforeFinancial: _toDouble(json['balance_before_financial']) ?? 0.0,
      balanceBeforeWeight: _toWeights(json['balance_before_weight']),
      snapshotCapturedAt: _toDate(json['snapshot_captured_at']),
      postedAmountCash: _toDouble(json['posted_amount_cash']),
      postedAmountWeight: _toWeights(json['posted_amount_weight']),
      policyId: (json['policy_id'] as num?)?.toInt(),
      periodKey: json['period_key']?.toString(),
      voucherId: (json['voucher_id'] as num?)?.toInt(),
      journalEntryId: (json['journal_entry_id'] as num?)?.toInt(),
      reversalOfId: (json['reversal_of_id'] as num?)?.toInt(),
      createdBy: json['created_by']?.toString(),
      createdAt: _toDate(json['created_at']),
      approvedBy: json['approved_by']?.toString(),
      approvedAt: _toDate(json['approved_at']),
      approvedByManager: json['approved_by_manager'] == true,
      postedBy: json['posted_by']?.toString(),
      postedAt: _toDate(json['posted_at']),
      reversedBy: json['reversed_by']?.toString(),
      reversedAt: _toDate(json['reversed_at']),
      reversalReason: json['reversal_reason']?.toString(),
      cancelledBy: json['cancelled_by']?.toString(),
      cancelledAt: _toDate(json['cancelled_at']),
      cancellationReason: json['cancellation_reason']?.toString(),
    );
  }

  bool get isDraft => status == kSettlementStatusDraft;
  bool get isApproved => status == kSettlementStatusApproved;
  bool get isPosted => status == kSettlementStatusPosted;
  bool get isReversed => status == kSettlementStatusReversed;
  bool get isCancelled => status == kSettlementStatusCancelled;

  /// وثيقة عكس أنشأها النظام مقابل تسوية سابقة.
  bool get isReversalDocument => reversalOfId != null;

  /// الأوزان غير الصفرية فقط، بترتيب العرض. القيم كما جاءت من الخادم.
  Map<String, double> get openBalanceWeights =>
      _nonZeroOrdered(balanceBeforeWeight);

  Map<String, double> get settledWeights => _nonZeroOrdered(postedAmountWeight);

  static Map<String, double> _nonZeroOrdered(Map<String, double> source) {
    final result = <String, double>{};
    for (final key in kSettlementKaratKeys) {
      final value = source[key];
      if (value != null && value != 0) result[key] = value;
    }
    // أي مفتاح غير متوقع من الخادم يُعرض كما هو بدل أن يُسقط صامتًا.
    source.forEach((key, value) {
      if (!kSettlementKaratKeys.contains(key) && value != 0) {
        result[key] = value;
      }
    });
    return result;
  }
}

/// نتيجة `GET /supplier-settlement-adjustments/<id>/preview`.
///
/// كل رقم هنا وصل محسوبًا من الخادم: المكافئ بالعيار الرئيسي، وحدود السياسة،
/// والمستهلك من الفترة، والمتبقي من السقف، وحالة الأهلية وسبب المنع. لا يُشتق
/// أيٌّ منها هنا ولا يُعاد حسابه — لو غاب حقل تُعرض شرطة، ولا يُخمَّن.
class SettlementPreview {
  final int adjustmentId;
  final int supplierId;
  final String status;
  final String? periodKey;

  /// الرصيد الحي الذي سيتصرف عليه الترحيل — لا لقطة المستند المخزّنة.
  final double balanceBeforeFinancial;
  final Map<String, double> balanceBeforeWeight;

  /// مجموع الأوزان بعد تحويلها للعيار الرئيسي — من الخادم حصرًا.
  final double mainKaratEquivalent;

  /// هل ما تزال لقطة المستند مطابقة للرصيد الحي؟
  final bool storedSnapshotMatches;

  final bool eligible;
  final String? blockingCode;
  final String? blockingMessage;
  final List<SettlementCheck> checks;

  final SettlementPolicyView? policy;

  const SettlementPreview({
    required this.adjustmentId,
    required this.supplierId,
    required this.status,
    required this.balanceBeforeFinancial,
    required this.balanceBeforeWeight,
    required this.mainKaratEquivalent,
    required this.storedSnapshotMatches,
    required this.eligible,
    this.periodKey,
    this.blockingCode,
    this.blockingMessage,
    this.checks = const [],
    this.policy,
  });

  factory SettlementPreview.fromJson(Map<String, dynamic> json) {
    final eligibility =
        (json['eligibility'] as Map?)?.cast<String, dynamic>() ?? const {};
    final blocking =
        (eligibility['blocking_reason'] as Map?)?.cast<String, dynamic>();
    final rawChecks = eligibility['checks'];

    return SettlementPreview(
      adjustmentId: (json['adjustment_id'] as num?)?.toInt() ?? 0,
      supplierId: (json['supplier_id'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? '',
      periodKey: json['period_key']?.toString(),
      balanceBeforeFinancial: _toDouble(json['balance_before_financial']) ?? 0.0,
      balanceBeforeWeight: _toWeights(json['balance_before_weight']),
      mainKaratEquivalent: _toDouble(json['main_karat_equivalent']) ?? 0.0,
      storedSnapshotMatches: json['stored_snapshot_matches'] != false,
      eligible: eligibility['eligible'] == true,
      blockingCode: blocking?['code']?.toString(),
      blockingMessage: blocking?['message']?.toString(),
      checks: rawChecks is List
          ? rawChecks
              .whereType<Map>()
              .map((c) => SettlementCheck.fromJson(c.cast<String, dynamic>()))
              .toList()
          : const [],
      policy: json['policy'] is Map
          ? SettlementPolicyView.fromJson(
              (json['policy'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// العيارات غير الصفرية فقط، بترتيب العرض.
  Map<String, double> get openWeights =>
      SupplierSettlementAdjustment._nonZeroOrdered(balanceBeforeWeight);

  List<SettlementCheck> get failedChecks =>
      checks.where((c) => !c.passed).toList();
}

class SettlementCheck {
  final String name;
  final bool passed;
  final String detail;

  const SettlementCheck({
    required this.name,
    required this.passed,
    this.detail = '',
  });

  factory SettlementCheck.fromJson(Map<String, dynamic> json) => SettlementCheck(
        name: json['name']?.toString() ?? '',
        passed: json['passed'] == true,
        detail: json['detail']?.toString() ?? '',
      );
}

/// حدود السياسة النافذة وقت الطلب، واستهلاك الفترة. كلها من الخادم.
class SettlementPolicyView {
  final int? policyId;
  final double? toleranceCash;
  final double? toleranceWeight;
  final double? periodCapCash;
  final double? periodCapWeight;
  final double? reviewThresholdCash;
  final double? cashConsumed;
  final double? weightConsumed;
  final double? remainingCashCap;
  final double? remainingWeightCap;

  const SettlementPolicyView({
    this.policyId,
    this.toleranceCash,
    this.toleranceWeight,
    this.periodCapCash,
    this.periodCapWeight,
    this.reviewThresholdCash,
    this.cashConsumed,
    this.weightConsumed,
    this.remainingCashCap,
    this.remainingWeightCap,
  });

  factory SettlementPolicyView.fromJson(Map<String, dynamic> json) =>
      SettlementPolicyView(
        policyId: (json['policy_id'] as num?)?.toInt(),
        toleranceCash: _toDouble(json['tolerance_cash']),
        toleranceWeight: _toDouble(json['tolerance_weight']),
        periodCapCash: _toDouble(json['period_cap_cash']),
        periodCapWeight: _toDouble(json['period_cap_weight']),
        reviewThresholdCash: _toDouble(json['review_threshold_cash']),
        cashConsumed: _toDouble(json['cash_consumed']),
        weightConsumed: _toDouble(json['weight_consumed']),
        remainingCashCap: _toDouble(json['remaining_cash_cap']),
        remainingWeightCap: _toDouble(json['remaining_weight_cap']),
      );
}

/// ترجمة رمز المنع القادم من الخادم. الرمز الأصلي يبقى ظاهرًا للتشخيص،
/// ورسالة الخادم هي المعروضة — هذه العناوين تصنيف لا بديل عنها.
String settlementBlockingLabel(String? code, {bool isArabic = true}) {
  if (code == null) return '';
  if (!isArabic) return code;
  switch (code) {
    case 'below_review_threshold':
      return 'يتجاوز حد المراجعة';
    case 'snapshot_mismatch':
      return 'تغيّر الرصيد منذ إنشاء المسودة';
    case 'no_unpaid_invoices':
      return 'فواتير غير مسددة';
    case 'no_unposted_journal_entries':
      return 'قيود غير مرحّلة';
    case 'no_pending_vouchers':
      return 'سندات معلّقة';
    case 'no_other_open_adjustments':
      return 'تسوية أخرى مفتوحة';
    case 'has_residual':
      return 'لا يوجد فرق للتسوية';
    case 'within_operation_tolerance':
      return 'يتجاوز حد العملية';
    case 'within_period_cap':
      return 'يتجاوز سقف الفترة';
    case 'policy_configured':
      return 'لا توجد سياسة نافذة';
    default:
      return code;
  }
}

// ── الحالات ──────────────────────────────────────────────────────────────
// نفس القيم التي يرسلها الخادم حرفيًا.

const String kSettlementStatusDraft = 'draft';
const String kSettlementStatusApproved = 'approved';
const String kSettlementStatusPosted = 'posted';
const String kSettlementStatusReversed = 'reversed';
const String kSettlementStatusCancelled = 'cancelled';

String settlementStatusLabel(String status, {bool isArabic = true}) {
  if (!isArabic) return status;
  switch (status) {
    case kSettlementStatusDraft:
      return 'مسودة';
    case kSettlementStatusApproved:
      return 'معتمدة';
    case kSettlementStatusPosted:
      return 'مرحّلة';
    case kSettlementStatusReversed:
      return 'معكوسة';
    case kSettlementStatusCancelled:
      return 'ملغاة';
    default:
      return status;
  }
}

// ── أسباب التسوية ────────────────────────────────────────────────────────
// مطابقة لـ SupplierSettlementAdjustment.VALID_REASON_CODES في الخادم.
// PURCHASE_DISCOUNT ليست منها عمدًا: خصم المشتريات يمرّ بمساره المحاسبي.

const String kSettlementReasonRounding = 'ROUNDING_DIFFERENCE';
const String kSettlementReasonFinal = 'FINAL_SETTLEMENT_DIFFERENCE';
const String kSettlementReasonWeight = 'WEIGHT_DIFFERENCE';
const String kSettlementReasonWaiver = 'DOCUMENTED_SUPPLIER_WAIVER';
const String kSettlementReasonOther = 'OTHER';

const List<String> kSettlementReasonCodes = [
  kSettlementReasonRounding,
  kSettlementReasonFinal,
  kSettlementReasonWeight,
  kSettlementReasonWaiver,
  kSettlementReasonOther,
];

/// السبب الوحيد الذي يستلزم ملاحظة مكتوبة واعتماد مدير.
/// الخادم هو من يفرض ذلك؛ الواجهة تعكسه فقط.
const String kSettlementReasonRequiringNote = kSettlementReasonOther;

String settlementReasonLabel(String reasonCode, {bool isArabic = true}) {
  if (!isArabic) return reasonCode;
  switch (reasonCode) {
    case kSettlementReasonRounding:
      return 'فرق تقريب';
    case kSettlementReasonFinal:
      return 'فرق تسوية نهائية';
    case kSettlementReasonWeight:
      return 'فرق وزن';
    case kSettlementReasonWaiver:
      return 'تنازل مورد موثّق';
    case kSettlementReasonOther:
      return 'أخرى';
    default:
      return reasonCode;
  }
}
