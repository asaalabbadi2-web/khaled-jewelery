class PayrollModel {
  final int? id;
  final int employeeId;
  final int month;
  final int year;
  final double basicSalary;
  final double allowances;
  final double deductions;
  final double netSalary;
  final int? voucherId;
  final DateTime? paidDate;
  final String status;
  final String? notes;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final PayrollEmployeeSummary? employee;
  final VoucherSummary? voucher;

  const PayrollModel({
    required this.id,
    required this.employeeId,
    required this.month,
    required this.year,
    required this.basicSalary,
    required this.allowances,
    required this.deductions,
    required this.netSalary,
    required this.voucherId,
    required this.paidDate,
    required this.status,
    required this.notes,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.employee,
    required this.voucher,
  });

  factory PayrollModel.fromJson(Map<String, dynamic> json) {
    return PayrollModel(
      id: json['id'] as int?,
      employeeId: json['employee_id'] as int? ?? 0,
      month: json['month'] as int? ?? 1,
      year: json['year'] as int? ?? DateTime.now().year,
      basicSalary: (json['basic_salary'] as num?)?.toDouble() ?? 0.0,
      allowances: (json['allowances'] as num?)?.toDouble() ?? 0.0,
      deductions: (json['deductions'] as num?)?.toDouble() ?? 0.0,
      netSalary: (json['net_salary'] as num?)?.toDouble() ?? 0.0,
      voucherId: json['voucher_id'] as int?,
      paidDate: _parseDate(json['paid_date']),
      status: json['status'] as String? ?? 'pending',
      notes: json['notes'] as String?,
      createdBy: json['created_by'] as String?,
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      employee: json['employee'] != null
          ? PayrollEmployeeSummary.fromJson(
              json['employee'] as Map<String, dynamic>,
            )
          : null,
      voucher: json['voucher'] != null
          ? VoucherSummary.fromJson(json['voucher'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'employee_id': employeeId,
      'month': month,
      'year': year,
      'basic_salary': basicSalary,
      'allowances': allowances,
      'deductions': deductions,
      'net_salary': netSalary,
      'voucher_id': voucherId,
      'paid_date': paidDate?.toIso8601String(),
      'status': status,
      'notes': notes,
      'created_by': createdBy,
    }..removeWhere((key, value) => value == null);
  }

  PayrollModel copyWith({
    int? id,
    int? employeeId,
    int? month,
    int? year,
    double? basicSalary,
    double? allowances,
    double? deductions,
    double? netSalary,
    int? voucherId,
    DateTime? paidDate,
    String? status,
    String? notes,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    PayrollEmployeeSummary? employee,
    VoucherSummary? voucher,
  }) {
    return PayrollModel(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      month: month ?? this.month,
      year: year ?? this.year,
      basicSalary: basicSalary ?? this.basicSalary,
      allowances: allowances ?? this.allowances,
      deductions: deductions ?? this.deductions,
      netSalary: netSalary ?? this.netSalary,
      voucherId: voucherId ?? this.voucherId,
      paidDate: paidDate ?? this.paidDate,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      employee: employee ?? this.employee,
      voucher: voucher ?? this.voucher,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    return DateTime.tryParse(value as String);
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    return DateTime.tryParse(value as String);
  }
}

class PayrollEmployeeSummary {
  final int id;
  final String name;
  final String employeeCode;

  const PayrollEmployeeSummary({
    required this.id,
    required this.name,
    required this.employeeCode,
  });

  factory PayrollEmployeeSummary.fromJson(Map<String, dynamic> json) {
    return PayrollEmployeeSummary(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      employeeCode: json['employee_code'] as String? ?? '',
    );
  }
}

class VoucherSummary {
  final int id;
  final String voucherNumber;
  final String status;
  final DateTime? date;

  const VoucherSummary({
    required this.id,
    required this.voucherNumber,
    required this.status,
    required this.date,
  });

  factory VoucherSummary.fromJson(Map<String, dynamic> json) {
    return VoucherSummary(
      id: json['id'] as int? ?? 0,
      voucherNumber: json['voucher_number'] as String? ?? '',
      status: json['status'] as String? ?? '',
      date: PayrollModel._parseDate(json['date']),
    );
  }
}
