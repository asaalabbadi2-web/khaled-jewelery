class AppUserModel {
  final int? id;
  final String username;
  final int? employeeId;
  final String role;
  final Map<String, dynamic>? permissions;
  final bool isActive;
  final DateTime? lastLoginAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final EmployeeSummary? employee;

  const AppUserModel({
    required this.id,
    required this.username,
    required this.employeeId,
    required this.role,
    required this.permissions,
    required this.isActive,
    required this.lastLoginAt,
    required this.createdAt,
    required this.updatedAt,
    required this.employee,
  });

  factory AppUserModel.fromJson(Map<String, dynamic> json) {
    return AppUserModel(
      id: json['id'] as int?,
      username: json['username'] as String? ?? '',
      employeeId: json['employee_id'] as int?,
      role: json['role'] as String? ?? 'staff',
      permissions: (json['permissions'] as Map<String, dynamic>?)?.map(
        (key, value) => MapEntry(key, value),
      ),
      isActive: json['is_active'] as bool? ?? true,
      lastLoginAt: _parseDateTime(json['last_login_at']),
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
      'employee_id': employeeId,
      'role': role,
      'permissions': permissions,
      'is_active': isActive,
      'last_login_at': lastLoginAt?.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'employee': employee?.toMap(),
    };

    data.removeWhere((key, value) => value == null);
    return data;
  }

  factory AppUserModel.fromStorageMap(Map<String, dynamic> json) {
    return AppUserModel(
      id: json['id'] as int?,
      username: json['username'] as String? ?? '',
      employeeId: json['employee_id'] as int?,
      role: json['role'] as String? ?? 'staff',
      permissions: (json['permissions'] as Map?)?.cast<String, dynamic>(),
      isActive: json['is_active'] as bool? ?? true,
      lastLoginAt: _parseDateTime(json['last_login_at']),
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
    int? employeeId,
    String? role,
    Map<String, dynamic>? permissions,
    bool? isActive,
    DateTime? lastLoginAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    EmployeeSummary? employee,
  }) {
    return AppUserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      employeeId: employeeId ?? this.employeeId,
      role: role ?? this.role,
      permissions: permissions ?? this.permissions,
      isActive: isActive ?? this.isActive,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
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

  const EmployeeSummary({
    required this.id,
    required this.name,
    required this.employeeCode,
  });

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) {
    return EmployeeSummary(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      employeeCode: json['employee_code'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'employee_code': employeeCode,
    };
  }
}
