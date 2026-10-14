// ignore_for_file: non_constant_identifier_names

library;


/// The stock per (location, category, karat) -- the books themselves
/// (ADR-045): a location is a stock safe (the showroom, a custody, scrap).
class InventoryBucket {
  final int safeBoxId;
  final String? safeBoxName;
  final String? stockLocation;
  final int? categoryId;
  final String? categoryName;
  final double karat;
  final double balance;

  const InventoryBucket({
    required this.safeBoxId,
    this.safeBoxName,
    this.stockLocation,
    required this.categoryId,
    this.categoryName,
    required this.karat,
    required this.balance,
  });

  factory InventoryBucket.fromJson(Map<String, dynamic> j) => InventoryBucket(
        safeBoxId: j['safe_box_id'] as int,
        safeBoxName: j['safe_box_name'] as String?,
        stockLocation: j['stock_location'] as String?,
        categoryId: j['category_id'] as int?,
        categoryName: j['category_name'] as String?,
        karat: (j['karat'] as num).toDouble(),
        balance: (j['balance'] as num).toDouble(),
      );
}

class InventoryBalanceSummary {
  final List<LocationTotal> byLocation;
  final List<KaratTotal> byKarat;
  final double grandTotalWeight;
  final double unclassifiedWeight;
  final DateTime generatedAt;

  const InventoryBalanceSummary({
    required this.byLocation,
    required this.byKarat,
    required this.grandTotalWeight,
    required this.unclassifiedWeight,
    required this.generatedAt,
  });

  factory InventoryBalanceSummary.fromJson(Map<String, dynamic> j) =>
      InventoryBalanceSummary(
        byLocation: (j['by_location'] as List? ?? [])
            .map((e) => LocationTotal.fromJson(e as Map<String, dynamic>))
            .toList(),
        byKarat: (j['by_karat'] as List)
            .map((e) => KaratTotal.fromJson(e as Map<String, dynamic>))
            .toList(),
        grandTotalWeight: (j['grand_total_weight'] as num).toDouble(),
        unclassifiedWeight: (j['unclassified_weight'] as num? ?? 0).toDouble(),
        generatedAt: DateTime.parse(j['generated_at'] as String),
      );
}

/// A location's total, at the main karat.
class LocationTotal {
  final int safeBoxId;
  final String safeBoxName;
  final String? stockLocation;
  final double totalWeight;
  const LocationTotal(
      {required this.safeBoxId,
      required this.safeBoxName,
      this.stockLocation,
      required this.totalWeight});
  factory LocationTotal.fromJson(Map<String, dynamic> j) => LocationTotal(
        safeBoxId: j['safe_box_id'] as int,
        safeBoxName: j['safe_box_name'] as String? ?? '—',
        stockLocation: j['stock_location'] as String?,
        totalWeight: (j['total_weight'] as num).toDouble(),
      );
}

class KaratTotal {
  final double karat;
  final double totalWeight;
  const KaratTotal({required this.karat, required this.totalWeight});
  factory KaratTotal.fromJson(Map<String, dynamic> j) => KaratTotal(
        karat: (j['karat'] as num).toDouble(),
        totalWeight: (j['total_weight'] as num).toDouble(),
      );
}

// ── Count Sessions ────────────────────────────────────────────────────────────

class CountSession {
  final int id;
  final int? branchId;
  /// The location counted -- one stock safe; null: every one (ADR-045).
  final int? safeBoxId;
  /// The posted entry its approval wrote; null: nothing differed.
  final int? entryId;
  /// The location's name -- null: every location.
  final String? safeBoxName;
  /// The lines and the counted ones -- in a summary, which carries no lines.
  final int? linesTotal;
  final int? linesCounted;
  final String status; // open | counting | closed | approved | cancelled
  final String sessionType; // periodic | opening
  final bool blindCount;
  final int? snapshotLedgerId;
  final String? openedBy;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? notes;
  final List<CountLine> lines;

  const CountSession({
    required this.id,
    required this.branchId,
    this.safeBoxId,
    this.entryId,
    this.safeBoxName,
    this.linesTotal,
    this.linesCounted,
    required this.status,
    this.sessionType = 'periodic',
    required this.blindCount,
    this.snapshotLedgerId,
    this.openedBy,
    this.openedAt,
    this.closedAt,
    this.approvedBy,
    this.approvedAt,
    this.notes,
    this.lines = const [],
  });

  bool get isActive => status == 'open' || status == 'counting';
  bool get canClose => status == 'counting' || status == 'open';
  bool get canApprove => status == 'closed';
  bool get isOpening => sessionType == 'opening';

  factory CountSession.fromJson(Map<String, dynamic> j) => CountSession(
        id: j['id'] as int,
        branchId: j['branch_id'] as int?,
        safeBoxId: j['safe_box_id'] as int?,
        entryId: j['entry_id'] as int?,
        safeBoxName: j['safe_box_name'] as String?,
        linesTotal: j['lines_total'] as int?,
        linesCounted: j['lines_counted'] as int?,
        status: j['status'] as String,
        sessionType: j['session_type'] as String? ?? 'periodic',
        blindCount: j['blind_count'] as bool? ?? true,
        snapshotLedgerId: j['snapshot_ledger_id'] as int?,
        openedBy: j['opened_by'] as String?,
        openedAt: j['opened_at'] != null
            ? DateTime.tryParse(j['opened_at'] as String)
            : null,
        closedAt: j['closed_at'] != null
            ? DateTime.tryParse(j['closed_at'] as String)
            : null,
        approvedBy: j['approved_by'] as String?,
        approvedAt: j['approved_at'] != null
            ? DateTime.tryParse(j['approved_at'] as String)
            : null,
        notes: j['notes'] as String?,
        lines: (j['lines'] as List? ?? [])
            .map((e) => CountLine.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CountLine {
  final int id;
  final int sessionId;
  final int? branchId;
  /// Where it is counted -- a stock safe (ADR-045).
  final int? safeBoxId;
  final String? safeBoxName;
  /// null: «بلا تصنيف» -- counted like any other line.
  final int? categoryId;
  final String? categoryName;
  final double karat;
  // null when blind_count=true and session is still open/counting
  final double? expectedWeight;
  final double? countedWeight;
  final double? variance;
  final String? countedBy;
  final DateTime? countedAt;
  final String? notes;

  // UI-only state — not from API
  final CountLineStatus uiStatus;

  const CountLine({
    required this.id,
    required this.sessionId,
    required this.branchId,
    this.safeBoxId,
    this.safeBoxName,
    required this.categoryId,
    this.categoryName,
    required this.karat,
    this.expectedWeight,
    this.countedWeight,
    this.variance,
    this.countedBy,
    this.countedAt,
    this.notes,
    this.uiStatus = CountLineStatus.idle,
  });

  bool get isCounted => countedWeight != null;

  CountLine copyWith({
    double? countedWeight,
    double? variance,
    double? expectedWeight,
    CountLineStatus? uiStatus,
    String? countedBy,
    DateTime? countedAt,
  }) =>
      CountLine(
        id: id,
        sessionId: sessionId,
        branchId: branchId,
        safeBoxId: safeBoxId,
        safeBoxName: safeBoxName,
        categoryId: categoryId,
        categoryName: categoryName,
        karat: karat,
        expectedWeight: expectedWeight ?? this.expectedWeight,
        countedWeight: countedWeight ?? this.countedWeight,
        variance: variance ?? this.variance,
        countedBy: countedBy ?? this.countedBy,
        countedAt: countedAt ?? this.countedAt,
        notes: notes,
        uiStatus: uiStatus ?? this.uiStatus,
      );

  factory CountLine.fromJson(Map<String, dynamic> j) => CountLine(
        id: j['id'] as int,
        sessionId: j['session_id'] as int,
        branchId: j['branch_id'] as int?,
        safeBoxId: j['safe_box_id'] as int?,
        safeBoxName: j['safe_box_name'] as String?,
        categoryId: j['category_id'] as int?,
        categoryName: j['category_name'] as String?,
        karat: (j['karat'] as num).toDouble(),
        expectedWeight: j['expected_weight'] != null
            ? (j['expected_weight'] as num).toDouble()
            : null,
        countedWeight: j['counted_weight'] != null
            ? (j['counted_weight'] as num).toDouble()
            : null,
        variance: j['variance'] != null
            ? (j['variance'] as num).toDouble()
            : null,
        countedBy: j['counted_by'] as String?,
        countedAt: j['counted_at'] != null
            ? DateTime.tryParse(j['counted_at'] as String)
            : null,
        notes: j['notes'] as String?,
      );
}

enum CountLineStatus { idle, saving, saved, failed }

class AdjustmentReason {
  final String code;
  final String label;
  final bool requiresNote;
  const AdjustmentReason({
    required this.code,
    required this.label,
    this.requiresNote = false,
  });
  factory AdjustmentReason.fromJson(Map<String, dynamic> j) => AdjustmentReason(
        code: j['code'] as String,
        label: j['label'] as String,
        requiresNote: (j['requires_note'] as bool?) ?? false,
      );

  static const List<AdjustmentReason> fallback = [
    AdjustmentReason(code: 'COUNT_ERROR', label: 'خطأ عدّ'),
    AdjustmentReason(code: 'LOSS',        label: 'فاقد',        requiresNote: true),
    AdjustmentReason(code: 'NEW_ITEM',    label: 'قطعة جديدة'),
    AdjustmentReason(code: 'OTHER',       label: 'سبب آخر',     requiresNote: true),
  ];
}

// ── Audit (ADR-045 C2) ───────────────────────────────────────────────────────

/// «مركز التدقيق»: per (location, karat) the books, how much is classified,
/// and the last approved count. The stock is the books -- there is no second
/// ledger to match against.
class ReconciliationReport {
  final DateTime generatedAt;
  final bool isClean;
  final int violations;
  final List<ReconciliationRow> rows;

  const ReconciliationReport({
    required this.generatedAt,
    required this.isClean,
    required this.violations,
    required this.rows,
  });

  factory ReconciliationReport.fromJson(Map<String, dynamic> j) =>
      ReconciliationReport(
        generatedAt: DateTime.parse(j['generated_at'] as String),
        isClean: j['is_clean'] as bool? ?? true,
        violations: j['violations'] as int? ?? 0,
        rows: (j['rows'] as List? ?? [])
            .map((e) => ReconciliationRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ReconciliationRow {
  final int safeBoxId;
  final String? safeBoxName;
  final String? stockLocation;
  final double karat;
  final double booksGrams;
  final double classifiedGrams;
  final double unclassifiedGrams;
  final int? lastCountSessionId;
  final DateTime? lastCountAt;
  final double? lastCountVariance;

  const ReconciliationRow({
    required this.safeBoxId,
    this.safeBoxName,
    this.stockLocation,
    required this.karat,
    required this.booksGrams,
    required this.classifiedGrams,
    required this.unclassifiedGrams,
    this.lastCountSessionId,
    this.lastCountAt,
    this.lastCountVariance,
  });

  factory ReconciliationRow.fromJson(Map<String, dynamic> j) =>
      ReconciliationRow(
        safeBoxId: j['safe_box_id'] as int,
        safeBoxName: j['safe_box_name'] as String?,
        stockLocation: j['stock_location'] as String?,
        karat: (j['karat'] as num).toDouble(),
        booksGrams: (j['books_grams'] as num).toDouble(),
        classifiedGrams: (j['classified_grams'] as num).toDouble(),
        unclassifiedGrams: (j['unclassified_grams'] as num).toDouble(),
        lastCountSessionId: j['last_count_session_id'] as int?,
        lastCountAt: j['last_count_at'] != null
            ? DateTime.tryParse(j['last_count_at'] as String)
            : null,
        lastCountVariance: j['last_count_variance'] != null
            ? (j['last_count_variance'] as num).toDouble()
            : null,
      );
}

// ── Health ────────────────────────────────────────────────────────────────────

class HealthReport {
  final bool hasIssues;
  final DateTime generatedAt;
  final List<HealthMetric> metrics;

  const HealthReport({
    required this.hasIssues,
    required this.generatedAt,
    required this.metrics,
  });

  HealthMetric? metric(String key) =>
      metrics.where((m) => m.key == key).firstOrNull;

  factory HealthReport.fromJson(Map<String, dynamic> j) => HealthReport(
        hasIssues: j['has_issues'] as bool? ?? false,
        generatedAt: j['generated_at'] != null
            ? DateTime.parse(j['generated_at'] as String)
            : DateTime.now(),
        metrics: (j['metrics'] as List? ?? [])
            .map((e) => HealthMetric.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class HealthMetric {
  final String key;
  final String label;
  final String detail;
  final bool ok;

  const HealthMetric(
      {required this.key,
      required this.label,
      required this.detail,
      required this.ok});

  factory HealthMetric.fromJson(Map<String, dynamic> j) => HealthMetric(
        key: j['key'] as String,
        label: j['label'] as String,
        detail: j['detail'] as String,
        ok: j['ok'] as bool? ?? true,
      );
}
