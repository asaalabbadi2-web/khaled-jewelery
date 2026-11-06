/// A new year's opening figures beside the closing books (ADR-044, TR-2):
/// the server's rows, figures and difference -- nothing computed here.
library;

const openingKarats = ['18', '21', '22', '24'];

class OpeningRow {
  final int accountId;
  final String number;
  final String name;
  final String section;

  /// A customer's, supplier's or office's account: its cash says whether it
  /// opens as gold at the closing price or stays waiting to be closed.
  final bool party;

  /// 'cash' and each karat ('18', '21', ...), as the books close.
  final Map<String, double> books;

  /// The figure entered -- null until it is (the owner: «فارغة حتى تُؤكَّد»).
  final Map<String, double>? actual;
  final Map<String, double>? difference;
  final String? source;
  final String? treatment;
  final String? note;
  final String? enteredBy;

  /// A customer opening as gold: his riyals at the count day's closing
  /// price, frozen on the approval (TR-3).
  final double? goldGrams;

  const OpeningRow({
    required this.accountId,
    required this.number,
    required this.name,
    required this.section,
    required this.party,
    required this.books,
    this.actual,
    this.difference,
    this.source,
    this.treatment,
    this.note,
    this.enteredBy,
    this.goldGrams,
  });

  bool get entered => actual != null;

  static Map<String, double> _figures(Map<String, dynamic> j) =>
      {for (final e in j.entries) e.key: (e.value as num).toDouble()};

  factory OpeningRow.fromJson(Map<String, dynamic> j) => OpeningRow(
    accountId: j['account_id'] as int,
    number: j['number'] as String? ?? '',
    name: j['name'] as String? ?? '',
    section: j['section'] as String? ?? '',
    party: j['party'] as bool? ?? false,
    books: _figures(j['books'] as Map<String, dynamic>),
    actual: j['actual'] == null ? null : _figures(j['actual'] as Map<String, dynamic>),
    difference: j['difference'] == null
        ? null
        : _figures(j['difference'] as Map<String, dynamic>),
    source: j['source'] as String?,
    treatment: j['treatment'] as String?,
    note: j['note'] as String?,
    enteredBy: j['entered_by'] as String?,
    goldGrams: (j['gold_grams'] as num?)?.toDouble(),
  );
}

class Opening {
  final int year;
  final List<OpeningRow> rows;

  /// {code: label} -- the server's words.
  final Map<String, String> sources;
  final Map<String, String> treatments;
  final int entered;
  final int total;

  /// The figures less the books: what equity takes.
  final double differenceCash;
  final double differenceGrams;
  final String? approvedBy;
  final DateTime? approvedAt;

  /// Frozen on the approval (TR-3): the count day's closing price per gram of
  /// the main karat, the sales' riyals waiting then, and of them what
  /// customers opened as gold -- the next year's queue starts from them.
  final String? countDay;
  final double? closingPrice;
  final double? waitingCash;
  final double? toGoldCash;

  /// What the year starts with waiting -- the server's (carried_cash).
  final double? carriedCash;

  const Opening({
    required this.year,
    required this.rows,
    required this.sources,
    required this.treatments,
    required this.entered,
    required this.total,
    required this.differenceCash,
    required this.differenceGrams,
    this.approvedBy,
    this.approvedAt,
    this.countDay,
    this.closingPrice,
    this.waitingCash,
    this.toGoldCash,
    this.carriedCash,
  });

  bool get approved => approvedBy != null;

  factory Opening.fromJson(Map<String, dynamic> j) {
    final approval = j['approved'] as Map<String, dynamic>?;
    final difference = j['difference'] as Map<String, dynamic>;
    return Opening(
      year: j['year'] as int,
      rows: (j['rows'] as List)
          .map((e) => OpeningRow.fromJson(e as Map<String, dynamic>))
          .toList(),
      sources: Map<String, String>.from(j['sources'] as Map),
      treatments: Map<String, String>.from(j['treatments'] as Map),
      entered: j['entered'] as int,
      total: j['total'] as int,
      differenceCash: (difference['cash'] as num).toDouble(),
      differenceGrams: (difference['grams'] as num).toDouble(),
      approvedBy: approval?['by'] as String?,
      approvedAt: approval == null
          ? null
          : DateTime.tryParse(approval['at'] as String),
      countDay: approval?['count_day'] as String?,
      closingPrice: (approval?['closing_price'] as num?)?.toDouble(),
      waitingCash: (approval?['waiting_cash'] as num?)?.toDouble(),
      toGoldCash: (approval?['to_gold_cash'] as num?)?.toDouble(),
      carriedCash: (approval?['carried_cash'] as num?)?.toDouble(),
    );
  }
}
