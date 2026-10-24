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

  /// Its employees' names, as the server says them (bonus study م3ج).
  final List<String> targetEmployeeNames;
  final List<String>? applicableInvoiceTypes;
  final bool isActive;
  final DateTime? validFrom;
  final DateTime? validTo;
  final DateTime? createdAt;
  final String? createdBy;

  /// A tiered rule's terms (bonus study م2): what it measures, over which
  /// period, and its tiers -- [{from, per_unit | amount}], ascending.
  final String? measure;
  final String? period;
  final List<Map<String, dynamic>>? tiers;

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
    this.targetEmployeeNames = const [],
    this.applicableInvoiceTypes,
    this.isActive = true,
    this.validFrom,
    this.validTo,
    this.createdAt,
    this.createdBy,
    this.measure,
    this.period,
    this.tiers,
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
          ?.map((e) => (e as num).toInt())
          .toList(),
      targetEmployeeNames: [
        for (final e in (json['target_employees'] as List<dynamic>?) ?? const [])
          if (e is Map) '${e['name']}',
      ],
      applicableInvoiceTypes:
          (json['applicable_invoice_types'] as List<dynamic>?)
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
      measure: json['measure'] as String?,
      period: json['period'] as String?,
      tiers: (json['tiers'] as List<dynamic>?)
          ?.map((t) => Map<String, dynamic>.from(t as Map))
          .toList(),
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
      targetEmployeeNames: targetEmployeeNames,
      applicableInvoiceTypes:
          applicableInvoiceTypes ?? this.applicableInvoiceTypes,
      isActive: isActive ?? this.isActive,
      validFrom: validFrom ?? this.validFrom,
      validTo: validTo ?? this.validTo,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  /// الأنواع المتاحة للقواعد
  static const List<String> ruleTypes = [
    'sales_target', // تحقيق هدف مبيعات
    'attendance', // الحضور والانضباط
    'performance', // تقييم الأداء
    'fixed', // مكافأة ثابتة
    'profit_based', // مكافأة على أساس الربح
    'points_based', // مكافأة على أساس نقاط السباق
    'custom', // مخصصة
  ];

  /// What a rule's form offers: the types the server computes (bonus study
  /// م0, ث10) -- «مخصصة» has no calculator, «الحضور» and «الأداء» are refused
  /// by their flag -- and [current], when a rule is already of another.
  static const List<String> computedRuleTypes = [
    'tiered', // شرائح: يقول ما قالته «على أساس النقاط» وأكثر (م2)
    'sales_target',
    'fixed',
    'profit_based',
  ];

  static List<String> ruleTypesFor(String? current) => [
    ...computedRuleTypes,
    if (current != null && !computedRuleTypes.contains(current)) current,
  ];

  /// The payouts each rule type computes (bonus_calculator); another pays
  /// nothing, unsaid -- the form offers only these (bonus study م3ج).
  static const Map<String, List<String>> bonusTypesByRule = {
    'sales_target': ['percentage', 'fixed', 'sales_percentage'],
    'fixed': ['percentage', 'fixed'],
    'profit_based': ['percentage', 'fixed', 'profit_percentage'],
    'points_based': ['points_per_unit', 'fixed', 'percentage'],
  };

  /// أنواع احتساب المكافأة
  static const List<String> bonusTypes = [
    'percentage', // نسبة من الراتب
    'fixed', // مبلغ ثابت
    'sales_percentage', // نسبة من المبيعات
    'profit_percentage', // نسبة من الربح
    'points_per_unit', // مبلغ لكل نقطة مكتسبة
  ];

  /// فترات سباق النقاط
  static const List<String> pointsPeriods = [
    'today', // اليوم
    'week', // الأسبوع
    'month', // الشهر
  ];

  /// أسماء الأنواع بالعربية
  static String getRuleTypeNameAr(String ruleType) {
    switch (ruleType) {
      case 'tiered':
        return 'شرائح';
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
      case 'points_based':
        return 'على أساس النقاط';
      case 'custom':
        return 'مخصصة';
      default:
        return ruleType;
    }
  }

  /// One line saying the rule: a tiered one its measure, period and tiers
  /// (bonus study م2) -- «tiers» was shown as it is stored.
  String get summaryAr {
    if (ruleType != 'tiered') {
      return '${getRuleTypeNameAr(ruleType)} - ${getBonusTypeNameAr(bonusType)}';
    }
    const measures = {'points': 'النقاط', 'sales': 'المبيعات', 'sold_weight': 'الوزن المباع', 'count': 'عدد الفواتير'};
    const periods = {'daily': 'يومي', 'weekly': 'أسبوعي', 'monthly': 'شهري'};
    String n(num v) => v == v.truncate() ? '${v.toInt()}' : '$v';
    final steps = [
      for (final t in tiers ?? const <Map<String, dynamic>>[])
        'من ${n(t['from'] as num)}: '
            '${t['per_unit'] != null ? '${n(t['per_unit'] as num)} لكل وحدة' : '${n(t['amount'] as num)} ثابت'}',
    ];
    return 'شرائح · ${measures[measure] ?? measure} · ${periods[period] ?? period} · ${steps.join('، ')}';
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
      case 'points_per_unit':
        return 'مبلغ لكل نقطة';
      default:
        return bonusType;
    }
  }

  static String getPointsPeriodNameAr(String period) {
    switch (period) {
      case 'today':
        return 'اليوم';
      case 'week':
        return 'الأسبوع';
      case 'month':
        return 'الشهر';
      default:
        return period;
    }
  }

  bool get isPointsBased => ruleType == 'points_based';
}
