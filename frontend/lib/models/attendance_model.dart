class AttendanceModel {
  final int? id;
  final int employeeId;
  final DateTime attendanceDate;
  final DateTime? checkInTime;
  final DateTime? checkOutTime;
  final String status;
  final String? notes;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final AttendanceEmployeeSummary? employee;

  const AttendanceModel({
    required this.id,
    required this.employeeId,
    required this.attendanceDate,
    required this.checkInTime,
    required this.checkOutTime,
    required this.status,
    required this.notes,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.employee,
  });

  factory AttendanceModel.fromJson(Map<String, dynamic> json) {
    return AttendanceModel(
      id: json['id'] as int?,
      employeeId: json['employee_id'] as int? ?? 0,
      attendanceDate: _parseDate(json['attendance_date']) ?? DateTime.now(),
      checkInTime: _parseTime(json['check_in_time']),
      checkOutTime: _parseTime(json['check_out_time']),
      status: json['status'] as String? ?? 'present',
      notes: json['notes'] as String?,
      createdBy: json['created_by'] as String?,
      createdAt: _parseDateTime(json['created_at']),
      updatedAt: _parseDateTime(json['updated_at']),
      employee: json['employee'] != null
          ? AttendanceEmployeeSummary.fromJson(
              json['employee'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'employee_id': employeeId,
      'attendance_date': _formatDate(attendanceDate),
      'check_in_time': _formatTime(checkInTime),
      'check_out_time': _formatTime(checkOutTime),
      'status': status,
      'notes': notes,
      'created_by': createdBy,
    }..removeWhere((key, value) => value == null);
  }

  AttendanceModel copyWith({
    int? id,
    int? employeeId,
    DateTime? attendanceDate,
    DateTime? checkInTime,
    DateTime? checkOutTime,
    String? status,
    String? notes,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    AttendanceEmployeeSummary? employee,
  }) {
    return AttendanceModel(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      attendanceDate: attendanceDate ?? this.attendanceDate,
      checkInTime: checkInTime ?? this.checkInTime,
      checkOutTime: checkOutTime ?? this.checkOutTime,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      employee: employee ?? this.employee,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    return DateTime.tryParse(value as String);
  }

  static DateTime? _parseTime(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    final date = DateTime.tryParse('1970-01-01T$value');
    return date;
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value == null || value == '') {
      return null;
    }
    return DateTime.tryParse(value as String);
  }

  static String? _formatDate(DateTime? value) {
    return value?.toIso8601String().split('T').first;
  }

  static String? _formatTime(DateTime? value) {
    if (value == null) {
      return null;
    }
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    final ss = value.second.toString().padLeft(2, '0');
    if (ss == '00') {
      return '$hh:$mm';
    }
    return '$hh:$mm:$ss';
  }
}

class AttendanceEmployeeSummary {
  final int id;
  final String name;
  final String employeeCode;

  const AttendanceEmployeeSummary({
    required this.id,
    required this.name,
    required this.employeeCode,
  });

  factory AttendanceEmployeeSummary.fromJson(Map<String, dynamic> json) {
    return AttendanceEmployeeSummary(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      employeeCode: json['employee_code'] as String? ?? '',
    );
  }
}
