/// A month's payroll run and its lines (PAYROLL-2, ADR-068) -- as the server
/// says them (`/api/payroll/runs`); nothing is computed here.
library;

double _num(Object? v) => (v as num?)?.toDouble() ?? 0.0;

class PayrollRunSummary {
  const PayrollRunSummary({
    required this.id,
    required this.month,
    required this.year,
    required this.status,
  });

  final int id;
  final int month;
  final int year;

  /// draft, approved, paid, cancelled
  final String status;

  factory PayrollRunSummary.fromJson(Map<String, dynamic> json) =>
      PayrollRunSummary(
        id: json['id'] as int,
        month: json['month'] as int,
        year: json['year'] as int,
        status: json['status'] as String? ?? 'draft',
      );
}

/// An addition or a deduction of a line, with its reason. A deduction is of
/// a kind (PAYROLL-3): 'absence' and 'penalty' are keyed by the reviewer;
/// 'contribution' and 'advance' are reckoned by the server and not edited.
class PayrollLabelledAmount {
  const PayrollLabelledAmount(this.label, this.amount, {this.kind});
  final String label;
  final double amount;
  final String? kind;

  bool get isKeyed => kind == null || kind == 'absence' || kind == 'penalty';

  factory PayrollLabelledAmount.fromJson(Map<String, dynamic> json) =>
      PayrollLabelledAmount(
        json['label'] as String? ?? '',
        _num(json['amount']),
        kind: json['kind'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'label': label,
    'amount': amount,
    if (kind != null) 'kind': kind,
  };
}

class PayrollRunLine {
  const PayrollRunLine({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.paymentMethod,
    required this.basic,
    required this.allowances,
    required this.deductions,
    required this.net,
    required this.status,
    required this.voucherNumber,
    required this.days,
    required this.wholeMonth,
    required this.earned,
    required this.additions,
    required this.deductionLines,
    required this.employerContributions,
    required this.notes,
  });

  final int id;
  final int employeeId;
  final String employeeName;

  /// bank, cash, or null when not said yet
  final String? paymentMethod;
  final double basic;
  final double allowances;
  final double deductions;
  final double net;
  final String status;
  final String? voucherNumber;
  final int days;
  final bool wholeMonth;

  /// basic, housing, transport, other_allowances -- for the days worked
  final Map<String, double> earned;
  final List<PayrollLabelledAmount> additions;
  final List<PayrollLabelledAmount> deductionLines;

  /// The employer's share of his contributions -- the line's, not deducted.
  final double employerContributions;
  final String? notes;

  factory PayrollRunLine.fromJson(Map<String, dynamic> json) {
    final employee = json['employee'] as Map<String, dynamic>? ?? const {};
    final breakdown = json['breakdown'] as Map<String, dynamic>? ?? const {};
    final earned = breakdown['earned'] as Map<String, dynamic>? ?? const {};
    List<PayrollLabelledAmount> lines(Object? raw) => (raw as List? ?? const [])
        .map((e) => PayrollLabelledAmount.fromJson(e as Map<String, dynamic>))
        .toList();
    return PayrollRunLine(
      id: json['id'] as int,
      employeeId: json['employee_id'] as int,
      employeeName: employee['name'] as String? ?? '',
      paymentMethod: employee['payment_method'] as String?,
      basic: _num(json['basic_salary']),
      allowances: _num(json['allowances']),
      deductions: _num(json['deductions']),
      net: _num(json['net_salary']),
      status: json['status'] as String? ?? 'pending',
      voucherNumber:
          (json['voucher'] as Map<String, dynamic>?)?['voucher_number']
              as String?,
      days: breakdown['days'] as int? ?? 0,
      wholeMonth: breakdown['whole_month'] as bool? ?? true,
      earned: {for (final e in earned.entries) e.key: _num(e.value)},
      additions: lines(breakdown['additions']),
      deductionLines: lines(breakdown['deductions']),
      employerContributions:
          (breakdown['employer_contributions'] as List? ?? const [])
              .fold<double>(
                0,
                (s, e) => s + _num((e as Map<String, dynamic>)['amount']),
              ),
      notes: json['notes'] as String?,
    );
  }
}

/// An employee the run has no line for, and why: no_structure,
/// has_an_entry, not_employed, removed.
class PayrollLeftOut {
  const PayrollLeftOut(this.employeeId, this.name, this.reason);
  final int employeeId;
  final String name;
  final String reason;

  factory PayrollLeftOut.fromJson(Map<String, dynamic> json) => PayrollLeftOut(
    json['employee_id'] as int,
    json['name'] as String? ?? '',
    json['reason'] as String? ?? '',
  );
}

class PayrollRun {
  const PayrollRun({
    required this.summary,
    required this.lines,
    required this.leftOut,
    required this.totals,
  });

  final PayrollRunSummary summary;
  final List<PayrollRunLine> lines;
  final List<PayrollLeftOut> leftOut;

  /// basic_salary, allowances, deductions, net_salary
  final Map<String, double> totals;

  factory PayrollRun.fromJson(Map<String, dynamic> json) => PayrollRun(
    summary: PayrollRunSummary.fromJson(json),
    lines: (json['entries'] as List? ?? const [])
        .map((e) => PayrollRunLine.fromJson(e as Map<String, dynamic>))
        .toList(),
    leftOut: (json['left_out'] as List? ?? const [])
        .map((e) => PayrollLeftOut.fromJson(e as Map<String, dynamic>))
        .toList(),
    totals: {
      for (final e
          in (json['totals'] as Map<String, dynamic>? ?? const {}).entries)
        e.key: _num(e.value),
    },
  );
}

class SalaryStructureModel {
  const SalaryStructureModel({
    required this.id,
    required this.effectiveFrom,
    required this.basic,
    required this.housing,
    required this.transport,
    required this.otherAllowances,
    required this.gross,
  });

  final int id;
  final String effectiveFrom;
  final double basic;
  final double housing;
  final double transport;
  final double otherAllowances;
  final double gross;

  factory SalaryStructureModel.fromJson(Map<String, dynamic> json) =>
      SalaryStructureModel(
        id: json['id'] as int,
        effectiveFrom: json['effective_from'] as String? ?? '',
        basic: _num(json['basic']),
        housing: _num(json['housing']),
        transport: _num(json['transport']),
        otherAllowances: _num(json['other_allowances']),
        gross: _num(json['gross']),
      );
}

/// How an advance the books hold is repaid (PAYROLL-3).
class AdvancePlanModel {
  const AdvancePlanModel({
    required this.id,
    required this.amount,
    required this.installment,
    required this.startMonth,
    required this.startYear,
    required this.status,
    required this.taken,
    required this.remaining,
    required this.consent,
  });

  final int id;
  final double amount;
  final double installment;
  final int startMonth;
  final int startYear;

  /// active, settled, cancelled
  final String status;
  final double taken;
  final double remaining;
  final bool consent;

  factory AdvancePlanModel.fromJson(Map<String, dynamic> json) =>
      AdvancePlanModel(
        id: json['id'] as int,
        amount: _num(json['amount']),
        installment: _num(json['installment']),
        startMonth: json['start_month'] as int,
        startYear: json['start_year'] as int,
        status: json['status'] as String? ?? 'active',
        taken: _num(json['taken']),
        remaining: _num(json['remaining']),
        consent: json['consent'] as bool? ?? false,
      );
}
