import 'package:flutter/material.dart';

class SafeBoxModel {
  final int? id;
  final String name;
  final String? nameEn;
  final String safeType; // cash, bank, gold, check
  final int accountId;
  final int? karat; // للذهب
  final String? bankName;
  final String? iban;
  final String? swiftCode;
  final String? branch;
  final bool isActive;
  final bool isDefault;
  final String? notes;
  final String? createdAt;
  final String? updatedAt;
  final String? createdBy;

  // معلومات الحساب المرتبط
  final AccountInfo? account;
  final BalanceInfo? balance;

  // Ledger-based balances (SafeBoxTransaction)
  final Map<String, double>? weightBalance;
  final double? totalWeightMainKarat;
  final double? ledgerCashBalance;

  SafeBoxModel({
    this.id,
    required this.name,
    this.nameEn,
    required this.safeType,
    required this.accountId,
    this.karat,
    this.bankName,
    this.iban,
    this.swiftCode,
    this.branch,
    this.isActive = true,
    this.isDefault = false,
    this.notes,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.account,
    this.balance,
    this.weightBalance,
    this.totalWeightMainKarat,
    this.ledgerCashBalance,
  });

  factory SafeBoxModel.fromJson(Map<String, dynamic> json) {
    Map<String, double>? parseWeightBalance(dynamic raw) {
      if (raw is Map) {
        final out = <String, double>{};
        raw.forEach((key, value) {
          final k = key.toString();
          if (value is num) {
            out[k] = value.toDouble();
          } else {
            final v = double.tryParse(value?.toString() ?? '');
            if (v != null) out[k] = v;
          }
        });
        return out;
      }
      return null;
    }

    return SafeBoxModel(
      id: json['id'],
      name: json['name'],
      nameEn: json['name_en'],
      safeType: json['safe_type'],
      accountId: json['account_id'],
      karat: json['karat'],
      bankName: json['bank_name'],
      iban: json['iban'],
      swiftCode: json['swift_code'],
      branch: json['branch'],
      isActive: json['is_active'] ?? true,
      isDefault: json['is_default'] ?? false,
      notes: json['notes'],
      createdAt: json['created_at'],
      updatedAt: json['updated_at'],
      createdBy: json['created_by'],
      account: json['account'] != null
          ? AccountInfo.fromJson(json['account'])
          : null,
      balance: json['balance'] != null
          ? BalanceInfo.fromJson(json['balance'])
          : null,
      weightBalance: parseWeightBalance(json['weight_balance']),
      totalWeightMainKarat:
          (json['total_weight_main_karat'] as num?)?.toDouble(),
      ledgerCashBalance: (json['cash_balance'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'name_en': nameEn,
      'safe_type': safeType,
      'account_id': accountId,
      if (karat != null) 'karat': karat,
      if (bankName != null) 'bank_name': bankName,
      if (iban != null) 'iban': iban,
      if (swiftCode != null) 'swift_code': swiftCode,
      if (branch != null) 'branch': branch,
      'is_active': isActive,
      'is_default': isDefault,
      if (notes != null) 'notes': notes,
      if (createdBy != null) 'created_by': createdBy,
    };
  }

  /// الأيقونة حسب نوع الخزينة
  IconData get icon {
    switch (safeType) {
      case 'cash':
        return Icons.money;
      case 'bank':
        return Icons.account_balance;
      case 'clearing':
        return Icons.swap_horiz;
      case 'gold':
        return Icons.diamond;
      case 'check':
        return Icons.receipt_long;
      default:
        return Icons.account_balance_wallet;
    }
  }

  /// اسم النوع بالعربية
  String get typeNameAr {
    switch (safeType) {
      case 'cash':
        return 'نقدي';
      case 'bank':
        return 'بنكي';
      case 'clearing':
        return 'مستحقات تحصيل';
      case 'gold':
        return 'ذهبي';
      case 'check':
        return 'شيكات';
      default:
        return 'غير محدد';
    }
  }

  /// اسم النوع بالإنجليزية
  String get typeNameEn {
    switch (safeType) {
      case 'cash':
        return 'Cash';
      case 'bank':
        return 'Bank';
      case 'clearing':
        return 'Clearing';
      case 'gold':
        return 'Gold';
      case 'check':
        return 'Check';
      default:
        return 'Unknown';
    }
  }

  /// اللون حسب النوع
  Color get typeColor {
    switch (safeType) {
      case 'cash':
        return Colors.green;
      case 'bank':
        return Colors.blue;
      case 'clearing':
        return Colors.teal;
      case 'gold':
        return Colors.amber;
      case 'check':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  /// الرصيد النقدي
  double get cashBalance => ledgerCashBalance ?? balance?.cash ?? 0.0;

  /// الرصيد الوزني (إن توفر من الـ ledger)
  double get goldBalance24k => weightBalance?['24k'] ?? 0.0;
  double get goldBalance22k => weightBalance?['22k'] ?? 0.0;
  double get goldBalance21k => weightBalance?['21k'] ?? 0.0;
  double get goldBalance18k => weightBalance?['18k'] ?? 0.0;

  /// نسخة من الكائن مع تحديثات
  SafeBoxModel copyWith({
    int? id,
    String? name,
    String? nameEn,
    String? safeType,
    int? accountId,
    int? karat,
    String? bankName,
    String? iban,
    String? swiftCode,
    String? branch,
    bool? isActive,
    bool? isDefault,
    String? notes,
    String? createdAt,
    String? updatedAt,
    String? createdBy,
    AccountInfo? account,
    BalanceInfo? balance,
  }) {
    return SafeBoxModel(
      id: id ?? this.id,
      name: name ?? this.name,
      nameEn: nameEn ?? this.nameEn,
      safeType: safeType ?? this.safeType,
      accountId: accountId ?? this.accountId,
      karat: karat ?? this.karat,
      bankName: bankName ?? this.bankName,
      iban: iban ?? this.iban,
      swiftCode: swiftCode ?? this.swiftCode,
      branch: branch ?? this.branch,
      isActive: isActive ?? this.isActive,
      isDefault: isDefault ?? this.isDefault,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      account: account ?? this.account,
      balance: balance ?? this.balance,
    );
  }
}

/// معلومات الحساب المرتبط
class AccountInfo {
  final int id;
  final String accountNumber;
  final String name;
  final String type;

  AccountInfo({
    required this.id,
    required this.accountNumber,
    required this.name,
    required this.type,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) {
    return AccountInfo(
      id: json['id'],
      accountNumber: json['account_number'],
      name: json['name'],
      type: json['type'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'account_number': accountNumber,
      'name': name,
      'type': type,
    };
  }
}

/// معلومات الرصيد
class BalanceInfo {
  final double cash;
  final WeightBalance? weight;

  BalanceInfo({required this.cash, this.weight});

  factory BalanceInfo.fromJson(Map<String, dynamic> json) {
    return BalanceInfo(
      cash: (json['cash'] ?? 0.0).toDouble(),
      weight: json['weight'] != null
          ? WeightBalance.fromJson(json['weight'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {'cash': cash, if (weight != null) 'weight': weight!.toJson()};
  }
}

/// رصيد الوزن (للذهب)
class WeightBalance {
  final double karat18;
  final double karat21;
  final double karat22;
  final double karat24;
  final double total;

  WeightBalance({
    required this.karat18,
    required this.karat21,
    required this.karat22,
    required this.karat24,
    required this.total,
  });

  factory WeightBalance.fromJson(Map<String, dynamic> json) {
    return WeightBalance(
      karat18: (json['18k'] ?? 0.0).toDouble(),
      karat21: (json['21k'] ?? 0.0).toDouble(),
      karat22: (json['22k'] ?? 0.0).toDouble(),
      karat24: (json['24k'] ?? 0.0).toDouble(),
      total: (json['total'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      '18k': karat18,
      '21k': karat21,
      '22k': karat22,
      '24k': karat24,
      'total': total,
    };
  }
}
