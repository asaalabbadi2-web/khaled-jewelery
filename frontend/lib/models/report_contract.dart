/// The reports' contract, as the server says it (REPORTS ت1, ADR-083 law 6):
/// one shape every report answers (backend services/reports/contract.py), so
/// one shell shows, exports and prints any report. Nothing is reckoned here.
library;

/// A column's kind: how its figures are written.
enum ReportColumnKind { text, money, grams, count }

class ReportColumn {
  const ReportColumn({
    required this.key,
    required this.label,
    this.kind = ReportColumnKind.text,
    this.signed = false,
  });

  final String key;
  final String label;
  final ReportColumnKind kind;

  /// Its sign means something (a balance): shown so.
  final bool signed;

  bool get isFigure => kind != ReportColumnKind.text;

  factory ReportColumn.fromJson(Map<String, dynamic> json) => ReportColumn(
    key: json['key'] as String,
    label: json['label'] as String? ?? '',
    kind:
        ReportColumnKind.values.asNameMap()[json['kind']] ??
        ReportColumnKind.text,
    signed: json['signed'] == true,
  );
}

/// What a report checks of itself, and whether it holds.
class ReportCheck {
  const ReportCheck({required this.key, required this.label, required this.ok});

  final String key;
  final String label;
  final bool ok;

  factory ReportCheck.fromJson(Map<String, dynamic> json) => ReportCheck(
    key: json['key'] as String,
    label: json['label'] as String? ?? '',
    ok: json['ok'] == true,
  );
}

/// What a row opens: its account, its document.
class ReportDrill {
  const ReportDrill({required this.kind, required this.id});

  final String kind;
  final int id;

  static ReportDrill? fromJson(Object? json) => switch (json) {
    {'kind': final String kind, 'id': final int id} => ReportDrill(
      kind: kind,
      id: id,
    ),
    _ => null,
  };
}

class ReportRow {
  const ReportRow({required this.values, this.drill});

  final Map<String, dynamic> values;
  final ReportDrill? drill;

  Object? operator [](String key) => values[key];
}

class ReportData {
  const ReportData({
    required this.id,
    required this.title,
    required this.basis,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.checks,
    required this.readAt,
    this.start,
    this.end,
  });

  final String id;
  final String title;

  /// 'posted_entries' (the books) or 'documents' (an analysis).
  final String basis;
  final List<ReportColumn> columns;
  final List<ReportRow> rows;
  final Map<String, dynamic> totals;
  final List<ReportCheck> checks;
  final DateTime? readAt;
  final DateTime? start;
  final DateTime? end;

  /// Where its figures come from, in words.
  String get basisLabel => basis == 'documents'
      ? 'من المستندات المرحّلة، مطابقًا للدفاتر في المجموع'
      : 'من القيود المرحّلة';

  factory ReportData.fromJson(Map<String, dynamic> json) {
    final period = json['period'] as Map<String, dynamic>? ?? const {};
    DateTime? day(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return ReportData(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      basis: json['basis'] as String? ?? 'posted_entries',
      columns: [
        for (final c in (json['columns'] as List? ?? const []))
          ReportColumn.fromJson(c as Map<String, dynamic>),
      ],
      rows: [
        for (final r in (json['rows'] as List? ?? const []))
          ReportRow(
            values: Map<String, dynamic>.from(r as Map),
            drill: ReportDrill.fromJson((r)['drill']),
          ),
      ],
      totals: Map<String, dynamic>.from(json['totals'] as Map? ?? const {}),
      checks: [
        for (final c in (json['checks'] as List? ?? const []))
          ReportCheck.fromJson(c as Map<String, dynamic>),
      ],
      readAt: day(json['read_at']),
      start: day(period['start']),
      end: day(period['end']),
    );
  }
}
