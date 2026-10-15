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

  /// The employee's own accounts by role -- salary_payable, commission_payable,
  /// eos_payable, bonus_payable -- their links on the server (employee_account).
  /// Read here, never found by a number prefix and a name (CHART-002 5c).
  final Map<String, int> payableAccounts;
  final int? goldSafeBoxId;
  final int? cashSafeBoxId;
  final bool isActive;
  final String? notes;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final AccountSummary? account;
  final int payrollCount;
  final int attendanceCount;
  final String? photo;

  // 🎯 أهداف الأداء الشخصية
  final String? goalMetric;
  final String? goalName;
  final double? goalWeightMonthly;
  final double? goalWeightWeekly;
  final double? goalPointsMonthly;
  final double? goalPointsWeekly;
  final int? goalInvoicesMonthly;
  final int? goalInvoicesWeekly;
  // 💰 مبلغ المكافأة المباشر عند تحقيق الهدف
  final double? goalBonusMonthly;
  final double? goalBonusWeekly;
  // 🎛️ تفعيل/تعطيل الاحتفالية لكل فترة
  final bool goalDailyEnabled;
  final bool goalWeeklyEnabled;
  final bool goalMonthlyEnabled;
  // 📅 هدف يومي
  final double? goalWeightDaily;
  final double? goalPointsDaily;
  final int? goalInvoicesDaily;
  final double? goalBonusDaily;
  // 🏆 نوع المكافأة: 'fixed' | 'rule'
  final String goalRewardTypeDaily;
  final String goalRewardTypeWeekly;
  final String goalRewardTypeMonthly;
  // 🔗 ربط بـ BonusRule
  final int? goalBonusRuleIdDaily;
  final int? goalBonusRuleIdWeekly;
  final int? goalBonusRuleIdMonthly;

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
    this.payableAccounts = const {},
    required this.goldSafeBoxId,
    required this.cashSafeBoxId,
    required this.isActive,
    required this.notes,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.account,
    required this.payrollCount,
    required this.attendanceCount,
    this.photo,
    this.goalMetric,
    this.goalName,
    this.goalWeightMonthly,
    this.goalWeightWeekly,
    this.goalPointsMonthly,
    this.goalPointsWeekly,
    this.goalInvoicesMonthly,
    this.goalInvoicesWeekly,
    this.goalBonusMonthly,
    this.goalBonusWeekly,
    this.goalDailyEnabled = false,
    this.goalWeeklyEnabled = true,
    this.goalMonthlyEnabled = true,
    this.goalWeightDaily,
    this.goalPointsDaily,
    this.goalInvoicesDaily,
    this.goalBonusDaily,
    this.goalRewardTypeDaily = 'fixed',
    this.goalRewardTypeWeekly = 'fixed',
    this.goalRewardTypeMonthly = 'fixed',
    this.goalBonusRuleIdDaily,
    this.goalBonusRuleIdWeekly,
    this.goalBonusRuleIdMonthly,
  });

  static Map<String, int> _parsePayableAccounts(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, int>{};
    raw.forEach((key, value) {
      final id = value is int ? value : int.tryParse('$value');
      if (id != null) out['$key'] = id;
    });
    return out;
  }

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
      payableAccounts: _parsePayableAccounts(json['payable_accounts']),
      goldSafeBoxId: json['gold_safe_box_id'] as int?,
      cashSafeBoxId: json['cash_safe_box_id'] as int?,
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
      photo: json['photo'] as String?,
      goalMetric: json['goal_metric'] as String?,
      goalName: json['goal_name'] as String?,
      goalWeightMonthly: (json['goal_weight_monthly'] as num?)?.toDouble(),
      goalWeightWeekly: (json['goal_weight_weekly'] as num?)?.toDouble(),
      goalPointsMonthly: (json['goal_points_monthly'] as num?)?.toDouble(),
      goalPointsWeekly: (json['goal_points_weekly'] as num?)?.toDouble(),
      goalInvoicesMonthly: json['goal_invoices_monthly'] as int?,
      goalInvoicesWeekly: json['goal_invoices_weekly'] as int?,
      goalBonusMonthly: (json['goal_bonus_monthly'] as num?)?.toDouble(),
      goalBonusWeekly: (json['goal_bonus_weekly'] as num?)?.toDouble(),
      goalDailyEnabled: json['goal_daily_enabled'] as bool? ?? false,
      goalWeeklyEnabled: json['goal_weekly_enabled'] as bool? ?? true,
      goalMonthlyEnabled: json['goal_monthly_enabled'] as bool? ?? true,
      goalWeightDaily: (json['goal_weight_daily'] as num?)?.toDouble(),
      goalPointsDaily: (json['goal_points_daily'] as num?)?.toDouble(),
      goalInvoicesDaily: json['goal_invoices_daily'] as int?,
      goalBonusDaily: (json['goal_bonus_daily'] as num?)?.toDouble(),
      goalRewardTypeDaily: json['goal_reward_type_daily'] as String? ?? 'fixed',
      goalRewardTypeWeekly: json['goal_reward_type_weekly'] as String? ?? 'fixed',
      goalRewardTypeMonthly: json['goal_reward_type_monthly'] as String? ?? 'fixed',
      goalBonusRuleIdDaily: json['goal_bonus_rule_id_daily'] as int?,
      goalBonusRuleIdWeekly: json['goal_bonus_rule_id_weekly'] as int?,
      goalBonusRuleIdMonthly: json['goal_bonus_rule_id_monthly'] as int?,
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
      'gold_safe_box_id': goldSafeBoxId,
      'cash_safe_box_id': cashSafeBoxId,
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
    int? goldSafeBoxId,
    int? cashSafeBoxId,
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
      payableAccounts: payableAccounts,
      goldSafeBoxId: goldSafeBoxId ?? this.goldSafeBoxId,
      cashSafeBoxId: cashSafeBoxId ?? this.cashSafeBoxId,
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
