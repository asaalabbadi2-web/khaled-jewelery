// ignore_for_file: non_constant_identifier_names

library;

/// The stock screen (INV-1, ADR-086): each stock location by karat from the
/// books, its last approved count and open session, by section.
class StockLocations {
  final List<StockSection> sections;
  final double grandTotalMain;

  /// Allocations against their lines (the nightly STOCK_ALLOCATION_INVALID).
  final int violations;

  /// A session over every location at once (before ADR-086), if one is open.
  final OpenCount? allLocationsSession;

  const StockLocations({
    required this.sections,
    required this.grandTotalMain,
    required this.violations,
    this.allLocationsSession,
  });

  factory StockLocations.fromJson(Map<String, dynamic> j) => StockLocations(
    sections: (j['sections'] as List)
        .map((e) => StockSection.fromJson(e as Map<String, dynamic>))
        .toList(),
    grandTotalMain: (j['grand_total_main'] as num).toDouble(),
    violations: (j['violations'] as num?)?.toInt() ?? 0,
    allLocationsSession: j['all_locations_session'] == null
        ? null
        : OpenCount.fromJson(
            j['all_locations_session'] as Map<String, dynamic>,
          ),
  );
}

/// The stock, the employees' custody, the deposits with offices (not counted).
class StockSection {
  final String key;
  final String label;
  final bool counted;
  final double totalMain;
  final List<StockLocation> locations;

  const StockSection({
    required this.key,
    required this.label,
    required this.counted,
    required this.totalMain,
    required this.locations,
  });

  factory StockSection.fromJson(Map<String, dynamic> j) => StockSection(
    key: j['key'] as String,
    label: j['label'] as String,
    counted: j['counted'] as bool? ?? true,
    totalMain: (j['total_main'] as num).toDouble(),
    locations: (j['locations'] as List)
        .map((e) => StockLocation.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class StockLocation {
  final int safeBoxId;
  final String name;
  final String? stockLocation;
  final List<StockKarat> karats;
  final double totalMain;
  final bool negative;
  final LastCount? lastCount;
  final OpenCount? openSession;

  /// Its categories hold balances once an approved count classified it;
  /// before, their sums are their movement since the allocations began.
  final bool categoriesAreBalances;
  final List<StockCategory> categories;

  const StockLocation({
    required this.safeBoxId,
    required this.name,
    this.stockLocation,
    required this.karats,
    required this.totalMain,
    required this.negative,
    this.lastCount,
    this.openSession,
    required this.categoriesAreBalances,
    required this.categories,
  });

  factory StockLocation.fromJson(Map<String, dynamic> j) => StockLocation(
    safeBoxId: j['safe_box_id'] as int,
    name: j['name'] as String? ?? '',
    stockLocation: j['stock_location'] as String?,
    karats: (j['karats'] as List)
        .map((e) => StockKarat.fromJson(e as Map<String, dynamic>))
        .toList(),
    totalMain: (j['total_main'] as num).toDouble(),
    negative: j['negative'] as bool? ?? false,
    lastCount: j['last_count'] == null
        ? null
        : LastCount.fromJson(j['last_count'] as Map<String, dynamic>),
    openSession: j['open_session'] == null
        ? null
        : OpenCount.fromJson(j['open_session'] as Map<String, dynamic>),
    categoriesAreBalances: j['categories_are_balances'] as bool? ?? false,
    categories: (j['categories'] as List)
        .map((e) => StockCategory.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

class StockKarat {
  final int karat;
  final double grams;
  const StockKarat({required this.karat, required this.grams});
  factory StockKarat.fromJson(Map<String, dynamic> j) => StockKarat(
    karat: (j['karat'] as num).toInt(),
    grams: (j['grams'] as num).toDouble(),
  );
}

class StockCategory {
  final int? categoryId;
  final String name;
  final int karat;
  final double grams;
  const StockCategory({
    this.categoryId,
    required this.name,
    required this.karat,
    required this.grams,
  });
  factory StockCategory.fromJson(Map<String, dynamic> j) => StockCategory(
    categoryId: j['category_id'] as int?,
    name: j['name'] as String? ?? '',
    karat: (j['karat'] as num).toInt(),
    grams: (j['grams'] as num).toDouble(),
  );
}

/// A location's last approved count: when, who, its difference entry.
class LastCount {
  final int sessionId;
  final DateTime? approvedAt;
  final String? approvedBy;
  final String? entryNumber;
  const LastCount({
    required this.sessionId,
    this.approvedAt,
    this.approvedBy,
    this.entryNumber,
  });
  factory LastCount.fromJson(Map<String, dynamic> j) => LastCount(
    sessionId: j['session_id'] as int,
    approvedAt: j['approved_at'] == null
        ? null
        : DateTime.tryParse(j['approved_at'] as String),
    approvedBy: j['approved_by'] as String?,
    entryNumber: j['entry_number'] as String?,
  );
}

/// A count session open on a location, not yet approved.
class OpenCount {
  final int id;
  final String status;
  final int? linesCounted;
  final int? linesTotal;
  const OpenCount({
    required this.id,
    required this.status,
    this.linesCounted,
    this.linesTotal,
  });
  factory OpenCount.fromJson(Map<String, dynamic> j) => OpenCount(
    id: j['id'] as int,
    status: j['status'] as String? ?? 'open',
    linesCounted: (j['lines_counted'] as num?)?.toInt(),
    linesTotal: (j['lines_total'] as num?)?.toInt(),
  );
}

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

  /// Each karat's books, counted and difference -- once the count may be
  /// compared (closed, or not blind); empty before (ADR-086).
  final List<KaratReview> byKarat;

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
    this.byKarat = const [],
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
    byKarat: (j['by_karat'] as List? ?? [])
        .map((e) => KaratReview.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}

/// One karat of a count: the books (the counted lines' expected weights),
/// the counted, the difference the approval writes.
class KaratReview {
  final double karat;
  final double books;
  final double counted;
  final double difference;
  const KaratReview({
    required this.karat,
    required this.books,
    required this.counted,
    required this.difference,
  });
  factory KaratReview.fromJson(Map<String, dynamic> j) => KaratReview(
    karat: (j['karat'] as num).toDouble(),
    books: (j['books'] as num).toDouble(),
    counted: (j['counted'] as num).toDouble(),
    difference: (j['difference'] as num).toDouble(),
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
  }) => CountLine(
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
    variance: j['variance'] != null ? (j['variance'] as num).toDouble() : null,
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
    AdjustmentReason(code: 'LOSS', label: 'فاقد', requiresNote: true),
    AdjustmentReason(code: 'NEW_ITEM', label: 'قطعة جديدة'),
    AdjustmentReason(code: 'OTHER', label: 'سبب آخر', requiresNote: true),
  ];
}
