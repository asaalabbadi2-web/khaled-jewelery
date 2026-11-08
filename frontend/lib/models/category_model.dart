/// نموذج تصنيف الأصناف
/// يساعد في تنظيم الأصناف وتحسين دقة التقارير
class Category {
  final int? id;
  final String name;
  final String? description;
  final String? karat;
  final double? defaultWage;
  final DateTime? createdAt;
  final int? itemsCount;

  /// Stopped, never deleted once used -- offered to no one (ADR-045 B).
  final bool isActive;

  /// Its karat's scrap category: a customer scrap purchase line is given it.
  final bool isScrap;

  /// Derived from the name by the server (the name without its karat).
  final String? groupName;

  /// 'weight' or 'piece' -- its gold coded piece by piece (ADR-087 §5).
  final String tracking;


  bool get byThePiece => tracking == 'piece';

  Category({
    this.id,
    required this.name,
    this.description,
    this.karat,
    this.defaultWage,
    this.createdAt,
    this.itemsCount,
    this.isActive = true,
    this.isScrap = false,
    this.groupName,
    this.tracking = 'weight',
  });

  /// إنشاء Category من JSON
  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: json['id'],
      name: json['name'] ?? '',
      description: json['description'],
      karat: json['karat'],
      defaultWage: (json['default_wage'] as num?)?.toDouble(),
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : null,
      itemsCount: json['items_count'] ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      isScrap: json['is_scrap'] as bool? ?? false,
      groupName: json['group_name'] as String?,
      tracking: json['tracking'] as String? ?? 'weight',
    );
  }

  /// تحويل Category إلى JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'karat': karat,
      'default_wage': defaultWage,
    };
  }

  /// نسخة معدلة من التصنيف
  Category copyWith({
    int? id,
    String? name,
    String? description,
    String? karat,
    double? defaultWage,
    DateTime? createdAt,
    int? itemsCount,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      karat: karat ?? this.karat,
      defaultWage: defaultWage ?? this.defaultWage,
      createdAt: createdAt ?? this.createdAt,
      itemsCount: itemsCount ?? this.itemsCount,
      isActive: isActive,
      isScrap: isScrap,
      groupName: groupName,
      tracking: tracking,
    );
  }

  @override
  String toString() {
    return 'Category(id: $id, name: $name, itemsCount: $itemsCount)';
  }
}
