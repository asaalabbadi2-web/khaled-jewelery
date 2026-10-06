import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AccountTypeBadge extends StatelessWidget {
  final String type;

  const AccountTypeBadge({super.key, required this.type});

  static const _labels = {
    'asset': 'أصول',
    'liability': 'خصوم',
    'equity': 'حقوق',
    'revenue': 'إيرادات',
    'expense': 'مصروفات',
  };

  static const _bg = {
    'asset': AppColors.assetBadgeBg,
    'liability': AppColors.liabBadgeBg,
    'equity': AppColors.equityBadgeBg,
    'revenue': AppColors.revenueBadgeBg,
    'expense': AppColors.expenseBadgeBg,
  };

  static const _fg = {
    'asset': AppColors.assetBadgeFg,
    'liability': AppColors.liabBadgeFg,
    'equity': AppColors.equityBadgeFg,
    'revenue': AppColors.revenueBadgeFg,
    'expense': AppColors.expenseBadgeFg,
  };

  @override
  Widget build(BuildContext context) {
    final label = _labels[type] ?? type;
    final bg = _bg[type] ?? Colors.grey.shade100;
    final fg = _fg[type] ?? Colors.grey.shade700;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
          fontFamily: 'Cairo',
        ),
      ),
    );
  }
}
