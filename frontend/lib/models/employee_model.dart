import 'dart:convert';

class EmployeeModel {
  final int? id;
  final String employeeCode;
  final String name;
  final String? jobTitle;
  final String? department;
  final String? phone;
  final String? email;
  final String? nationalId;
  final double salary;
  final DateTime? hireDate;
  final DateTime? terminationDate;
  final int? accountId;
  final bool isActive;
  final String? notes;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final AccountSummary? account;
  final int payrollCount;
  final int attendanceCount;

  const EmployeeModel({
    required this.id,
    required this.employeeCode,
    required this.name,
    required this.jobTitle,
    required this.department,
    required this.phone,
    required this.email,
    required this.nationalId,
    required this.salary,
    required this.hireDate,
    required this.terminationDate,
    required this.accountId,
    required this.isActive,
    required this.notes,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.account,
    required this.payrollCount,
    required this.attendanceCount,
  });

  factory EmployeeModel.fromJson(Map<String, dynamic> json) {
    return EmployeeModel(
      id: json['id'] as int?,
      employeeCode: json['employee_code'] as String? ?? '',
      name: json['name'] as String? ?? '',
      jobTitle: json['job_title'] as String?,
      department: json['department'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      nationalId: json['national_id'] as String?,
      salary: (json['salary'] as num?)?.toDouble() ?? 0.0,
      hireDate: _parseDate(json['hire_date']),
      terminationDate: _parseDate(json['termination_date']),
      accountId: json['account_id'] as int?,
      isActive: json['is_active'] as bool? ?? true,
      notes: json['notes'] as String?,
      createdBy: json['created_by'] as String?,
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      account: json['account'] != null
          ? AccountSummary.fromJson(json['account'] as Map<String, dynamic>)
          : null,
      payrollCount: json['payroll_count'] as int? ?? 0,
      attendanceCount: json['attendance_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'employee_code': employeeCode,
      'name': name,
      'job_title': jobTitle,
      'department': department,
      'phone': phone,
      'email': email,
      'national_id': nationalId,
      'salary': salary,
      'hire_date': hireDate?.toIso8601String(),
      'termination_date': terminationDate?.toIso8601String(),
      'account_id': accountId,
      'is_active': isActive,
      'notes': notes,
      'created_by': createdBy,
    }..removeWhere((key, value) => value == null);
  }

  EmployeeModel copyWith({
    int? id,
    String? employeeCode,
    String? name,
    String? jobTitle,
    String? department,
    String? phone,
    String? email,
    String? nationalId,
    double? salary,
    DateTime? hireDate,
    DateTime? terminationDate,
    int? accountId,
    bool? isActive,
    String? notes,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    AccountSummary? account,
    int? payrollCount,
    int? attendanceCount,
  }) {
    return EmployeeModel(
      id: id ?? this.id,
      employeeCode: employeeCode ?? this.employeeCode,
      name: name ?? this.name,
      jobTitle: jobTitle ?? this.jobTitle,
      department: department ?? this.department,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      nationalId: nationalId ?? this.nationalId,
      salary: salary ?? this.salary,
      hireDate: hireDate ?? this.hireDate,
      terminationDate: terminationDate ?? this.terminationDate,
      accountId: accountId ?? this.accountId,
      isActive: isActive ?? this.isActive,
      notes: notes ?? this.notes,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      account: account ?? this.account,
      payrollCount: payrollCount ?? this.payrollCount,
      attendanceCount: attendanceCount ?? this.attendanceCount,
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

  static List<EmployeeModel> listFromJson(String bodyBytes) {
    final decoded = json.decode(bodyBytes) as List<dynamic>;
    return decoded
        .map((e) => EmployeeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

class AccountSummary {
  final int id;
  final String accountNumber;
  final String name;

  const AccountSummary({
    required this.id,
    required this.accountNumber,
    required this.name,
  });

  factory AccountSummary.fromJson(Map<String, dynamic> json) {
    return AccountSummary(
      id: json['id'] as int,
      accountNumber: json['account_number'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }
}
