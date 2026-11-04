/// The reports' contract, as the server says it (REPORTS ت1, ADR-083 law 6):
/// one shape every report answers (backend services/reports/contract.py), so
/// one shell shows, exports and prints any report. Nothing is reckoned here.
library;

/// A column's kind: how its figures are written.
/// `date`: YYYY-MM-DD, shown as figures are (left to right), never the wide column.
enum ReportColumnKind { text, money, grams, count, percent, date }

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

/// The one chart a report asks for over its table (REPORTS ت4-2): its rows
/// along [x] (a text column), the height of figure [y] -- and of [also],
/// figures beside it (ت4-4ب), one axis for all.
class ReportChart {
  const ReportChart({
    required this.x,
    required this.y,
    this.also = const [],
    this.kind = 'bar',
  });

  final String x;
  final String y;
  final List<String> also;

  /// 'bar' (from zero: amounts) or 'line' (its axis spans its values: a price
  /// over time, ت5-4).
  final String kind;

  /// Its figures, in order: [y], then [also].
  List<String> get series => [y, ...also];

  static ReportChart? fromJson(Object? json) => switch (json) {
    {'x': final String x, 'y': final String y} => ReportChart(
      x: x,
      y: y,
      also: [
        for (final a in ((json as Map)['also'] as List? ?? const [])) '$a',
      ],
      kind: '${json['kind'] ?? 'bar'}',
    ),
    _ => null,
  };
}

/// A statement's line: a section's heading, its total, a line said apart, a
/// note beside it (not summed).
enum ReportRowStyle { line, heading, subtotal, finding, note }

class ReportRow {
  const ReportRow({
    required this.values,
    this.drill,
    this.style = ReportRowStyle.line,
  });

  final Map<String, dynamic> values;
  final ReportDrill? drill;
  final ReportRowStyle style;

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
    this.chart,
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

  /// The chart it asks for over its table, if any.
  final ReportChart? chart;

  /// Where its figures come from, in words.
  String get basisLabel => switch (basis) {
    'documents' => 'من المستندات المرحّلة، مطابقًا للدفاتر في المجموع',
    'prices' => 'من أسعار الذهب المسجّلة',
    _ => 'من القيود المرحّلة',
  };

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
            style:
                ReportRowStyle.values.asNameMap()[(r)['style']] ??
                ReportRowStyle.line,
          ),
      ],
      totals: Map<String, dynamic>.from(json['totals'] as Map? ?? const {}),
      chart: ReportChart.fromJson(json['chart']),
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
