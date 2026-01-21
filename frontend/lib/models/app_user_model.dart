class AppUserModel {
  final int? id;
  final String username;
  final String? fullName;
  final String? email;
  final String? phone;
  final int? employeeId;
  final String role;
  final Object? permissions;
  final bool isActive;
  final bool mustChangePassword;
  final DateTime? lastLoginAt;
  final DateTime? passwordChangedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final EmployeeSummary? employee;

  const AppUserModel({
    required this.id,
    required this.username,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.employeeId,
    required this.role,
    required this.permissions,
    required this.isActive,
    required this.mustChangePassword,
    required this.lastLoginAt,
    required this.passwordChangedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.employee,
  });

  factory AppUserModel.fromJson(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];
    Object? parsedPermissions;
    if (rawPermissions is Map) {
      parsedPermissions = rawPermissions.cast<String, dynamic>();
    } else if (rawPermissions is List) {
      parsedPermissions = List<dynamic>.from(rawPermissions);
    }

    return AppUserModel(
      id: json['id'] as int?,
      username: json['username'] as String? ?? '',
      fullName: json['full_name'] as String?,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      employeeId: json['employee_id'] as int?,
      role: json['role'] as String? ?? 'staff',
      permissions: parsedPermissions,
      isActive: json['is_active'] as bool? ?? true,
      mustChangePassword: json['must_change_password'] as bool? ?? false,
      lastLoginAt: _parseDateTime(json['last_login_at']),
      passwordChangedAt: _parseDateTime(json['password_changed_at']),
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      employee: json['employee'] != null
          ? EmployeeSummary.fromJson(json['employee'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson({String? password}) {
    final Map<String, dynamic> data = {
      'username': username,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'employee_id': employeeId,
      'role': role,
      'permissions': permissions,
      'is_active': isActive,
    };

    if (password != null && password.isNotEmpty) {
      data['password'] = password;
    }

    data.removeWhere((key, value) => value == null);
    return data;
  }

  Map<String, dynamic> toStorageMap() {
    final data = <String, dynamic>{
      'id': id,
      'username': username,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'employee_id': employeeId,
      'role': role,
      'permissions': permissions,
      'is_active': isActive,
      'must_change_password': mustChangePassword,
      'last_login_at': lastLoginAt?.toIso8601String(),
      'password_changed_at': passwordChangedAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'employee': employee?.toMap(),
    };

    data.removeWhere((key, value) => value == null);
    return data;
  }

  factory AppUserModel.fromStorageMap(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];
    Object? parsedPermissions;
    if (rawPermissions is Map) {
      parsedPermissions = rawPermissions.cast<String, dynamic>();
    } else if (rawPermissions is List) {
      parsedPermissions = List<dynamic>.from(rawPermissions);
    }

    return AppUserModel(
      id: json['id'] as int?,
      username: json['username'] as String? ?? '',
      fullName: json['full_name'] as String?,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      employeeId: json['employee_id'] as int?,
      role: json['role'] as String? ?? 'staff',
      permissions: parsedPermissions,
      isActive: json['is_active'] as bool? ?? true,
      mustChangePassword: json['must_change_password'] as bool? ?? false,
      lastLoginAt: _parseDateTime(json['last_login_at']),
      passwordChangedAt: _parseDateTime(json['password_changed_at']),
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      employee: json['employee'] is Map<String, dynamic>
          ? EmployeeSummary.fromJson(json['employee'] as Map<String, dynamic>)
          : null,
    );
  }

  AppUserModel copyWith({
    int? id,
    String? username,
    String? fullName,
    String? email,
    String? phone,
    int? employeeId,
    String? role,
    Object? permissions,
    bool? isActive,
    bool? mustChangePassword,
    DateTime? lastLoginAt,
    DateTime? passwordChangedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    EmployeeSummary? employee,
  }) {
    return AppUserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      employeeId: employeeId ?? this.employeeId,
      role: role ?? this.role,
      permissions: permissions ?? this.permissions,
      isActive: isActive ?? this.isActive,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      passwordChangedAt: passwordChangedAt ?? this.passwordChangedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      employee: employee ?? this.employee,
    );
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    return DateTime.tryParse(value as String);
  }
}

class EmployeeSummary {
  final int id;
  final String name;
  final String employeeCode;
  final int? goldSafeBoxId;
  final int? cashSafeBoxId;

  const EmployeeSummary({
    required this.id,
    required this.name,
    required this.employeeCode,
    this.goldSafeBoxId,
    this.cashSafeBoxId,
  });

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) {
    return EmployeeSummary(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      employeeCode: json['employee_code'] as String? ?? '',
      goldSafeBoxId: json['gold_safe_box_id'] as int?,
      cashSafeBoxId: json['cash_safe_box_id'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
      'gold_safe_box_id': goldSafeBoxId,
      'cash_safe_box_id': cashSafeBoxId,
    };
  }
}
