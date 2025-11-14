import 'package:flutter/material.dart';

/// تعريف التقرير الفردي داخل النظام
class ReportDescriptor {
  final String id;
  final IconData icon;
  final String titleAr;
  final String titleEn;
  final String descriptionAr;
  final String descriptionEn;
  final String route;
  final ReportType type;
  final bool requiresFilters;
  final bool available;

  const ReportDescriptor({
    required this.id,
    required this.icon,
    required this.titleAr,
    required this.titleEn,
    required this.descriptionAr,
    required this.descriptionEn,
    required this.route,
    required this.type,
    this.requiresFilters = true,
    this.available = false,
  });

  String localizedTitle(bool isArabic) => isArabic ? titleAr : titleEn;

  String localizedDescription(bool isArabic) =>
      isArabic ? descriptionAr : descriptionEn;
}

/// تصنيف أعلى يضم مجموعة تقارير متجانسة
class ReportCategory {
  final String id;
  final IconData icon;
  final Color accentColor;
  final String nameAr;
  final String nameEn;
  final List<ReportDescriptor> reports;

  const ReportCategory({
    required this.id,
    required this.icon,
    required this.accentColor,
    required this.nameAr,
    required this.nameEn,
    required this.reports,
  });

  String localizedName(bool isArabic) => isArabic ? nameAr : nameEn;
}

/// نوع التقرير يساعد على بناء واجهات خاصة لاحقاً
enum ReportType {
  financial,
  sales,
  inventory,
  gold,
  payroll,
  accounting,
  other,
}
