import 'package:flutter/material.dart';

/// One report the centre lists.
class ReportDescriptor {
  final String id;
  final IconData icon;
  final String titleAr;
  final String titleEn;

  /// One line: what the report answers.
  final String descriptionAr;
  final String descriptionEn;
  final String route;

  /// The words people use for it, which its title does not hold -- the home
  /// screen's search and the centre's find it by them (ADR-057 ق٠).
  final List<String> keywords;

  const ReportDescriptor({
    required this.id,
    required this.icon,
    required this.titleAr,
    required this.titleEn,
    required this.descriptionAr,
    required this.descriptionEn,
    required this.route,
    this.keywords = const [],
  });

  String localizedTitle(bool isArabic) => isArabic ? titleAr : titleEn;

  String localizedDescription(bool isArabic) =>
      isArabic ? descriptionAr : descriptionEn;
}

/// A question the owner asks, and the reports that answer it.
class ReportCategory {
  final String id;
  final IconData icon;
  final String nameAr;
  final String nameEn;
  final List<ReportDescriptor> reports;

  const ReportCategory({
    required this.id,
    required this.icon,
    required this.nameAr,
    required this.nameEn,
    required this.reports,
  });

  String localizedName(bool isArabic) => isArabic ? nameAr : nameEn;
}
