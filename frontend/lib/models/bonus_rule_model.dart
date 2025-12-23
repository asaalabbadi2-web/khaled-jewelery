class BonusRuleModel {
  final int? id;
  final String name;
  final String? description;
  final String ruleType;
  final Map<String, dynamic>? conditions;
  final String bonusType;
  final double bonusValue;
  final double minBonus;
  final double? maxBonus;
  final List<String>? targetDepartments;
  final List<String>? targetPositions;
  final List<int>? targetEmployeeIds;
  final List<String>? applicableInvoiceTypes;
  final bool isActive;
  final DateTime? validFrom;
  final DateTime? validTo;
  final DateTime? createdAt;
  final String? createdBy;

  const BonusRuleModel({
    this.id,
    required this.name,
    this.description,
    required this.ruleType,
    this.conditions,
    required this.bonusType,
    required this.bonusValue,
    this.minBonus = 0.0,
    this.maxBonus,
    this.targetDepartments,
    this.targetPositions,
    this.targetEmployeeIds,
    this.applicableInvoiceTypes,
    this.isActive = true,
    this.validFrom,
    this.validTo,
    this.createdAt,
    this.createdBy,
  });

  factory BonusRuleModel.fromJson(Map<String, dynamic> json) {
    return BonusRuleModel(
      id: json['id'] as int?,
      name: json['name'] as String,
      description: json['description'] as String?,
      ruleType: json['rule_type'] as String,
      conditions: json['conditions'] != null && json['conditions'] is Map
          ? json['conditions'] as Map<String, dynamic>
          : null,
      bonusType: json['bonus_type'] as String,
      bonusValue: (json['bonus_value'] as num).toDouble(),
      minBonus: (json['min_bonus'] as num?)?.toDouble() ?? 0.0,
      maxBonus: (json['max_bonus'] as num?)?.toDouble(),
      targetDepartments: (json['target_departments'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      targetPositions: (json['target_positions'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      targetEmployeeIds: (json['target_employee_ids'] as List<dynamic>?)
          ?.map((e) => e as int)
          .toList(),
      applicableInvoiceTypes: (json['applicable_invoice_types'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList(),
      isActive: json['is_active'] as bool? ?? true,
      validFrom: json['valid_from'] != null
          ? DateTime.parse(json['valid_from'] as String)
          : null,
      validTo: json['valid_to'] != null
          ? DateTime.parse(json['valid_to'] as String)
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      createdBy: json['created_by'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'description': description,
      'rule_type': ruleType,
      'conditions': conditions,
      'bonus_type': bonusType,
      'bonus_value': bonusValue,
      'min_bonus': minBonus,
      'max_bonus': maxBonus,
      'target_departments': targetDepartments,
      'target_positions': targetPositions,
      'target_employee_ids': targetEmployeeIds,
      'applicable_invoice_types': applicableInvoiceTypes,
      'is_active': isActive,
      'valid_from': validFrom?.toIso8601String().split('T').first,
      'valid_to': validTo?.toIso8601String().split('T').first,
      'created_by': createdBy,
    };
  }

  BonusRuleModel copyWith({
    int? id,
    String? name,
    String? description,
    String? ruleType,
    Map<String, dynamic>? conditions,
    String? bonusType,
    double? bonusValue,
    double? minBonus,
    double? maxBonus,
    List<String>? targetDepartments,
    List<String>? targetPositions,
    List<int>? targetEmployeeIds,
    List<String>? applicableInvoiceTypes,
    bool? isActive,
    DateTime? validFrom,
    DateTime? validTo,
    String? createdBy,
  }) {
    return BonusRuleModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      ruleType: ruleType ?? this.ruleType,
      conditions: conditions ?? this.conditions,
      bonusType: bonusType ?? this.bonusType,
      bonusValue: bonusValue ?? this.bonusValue,
      minBonus: minBonus ?? this.minBonus,
      maxBonus: maxBonus ?? this.maxBonus,
      targetDepartments: targetDepartments ?? this.targetDepartments,
      targetPositions: targetPositions ?? this.targetPositions,
      targetEmployeeIds: targetEmployeeIds ?? this.targetEmployeeIds,
      applicableInvoiceTypes: applicableInvoiceTypes ?? this.applicableInvoiceTypes,
      isActive: isActive ?? this.isActive,
      validFrom: validFrom ?? this.validFrom,
      validTo: validTo ?? this.validTo,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  /// الأنواع المتاحة للقواعد
  static const List<String> ruleTypes = [
    'sales_target',   // تحقيق هدف مبيعات
    'attendance',     // الحضور والانضباط
    'performance',    // تقييم الأداء
    'fixed',          // مكافأة ثابتة
    'profit_based',   // مكافأة على أساس الربح
    'custom',         // مخصصة
  ];

  /// أنواع احتساب المكافأة
  static const List<String> bonusTypes = [
    'percentage',       // نسبة من الراتب
    'fixed',           // مبلغ ثابت
    'sales_percentage', // نسبة من المبيعات
    'profit_percentage', // نسبة من الربح
  ];

  /// أسماء الأنواع بالعربية
  static String getRuleTypeNameAr(String ruleType) {
    switch (ruleType) {
      case 'sales_target':
        return 'هدف مبيعات';
      case 'attendance':
        return 'الحضور';
      case 'performance':
        return 'الأداء';
      case 'fixed':
        return 'ثابتة';
      case 'profit_based':
        return 'على أساس الربح';
      case 'custom':
        return 'مخصصة';
      default:
        return ruleType;
    }
  }

  static String getBonusTypeNameAr(String bonusType) {
    switch (bonusType) {
      case 'percentage':
        return 'نسبة من الراتب';
      case 'fixed':
        return 'مبلغ ثابت';
      case 'sales_percentage':
        return 'نسبة من المبيعات';
      case 'profit_percentage':
        return 'نسبة من الربح';
      default:
        return bonusType;
    }
  }
}
