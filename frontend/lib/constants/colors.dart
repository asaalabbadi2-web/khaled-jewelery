import 'package:flutter/material.dart';

/// ملف الألوان الثابتة للتطبيق
/// يضمن التناسق والتباين الجيد في جميع الشاشات
class AppColors {
  // ===== الألوان الأساسية =====

  /// اللون الذهبي الرئيسي للتطبيق
  static const Color gold = Color(0xFFFFD700);

  /// الذهبي الفاتح
  static const Color goldLight = Color(0xFFFFE55C);

  /// الذهبي الداكن
  static const Color goldDark = Color(0xFFDAA520);

  // ===== ألوان النصوص على الخلفية الذهبية =====

  /// لون النص الأساسي للاستخدام على الخلفية الذهبية
  /// يضمن تباين عالي وقراءة واضحة
  static const Color textOnGold = Colors.black87;

  /// لون الأيقونات على الخلفية الذهبية
  static const Color iconOnGold = Colors.black87;

  // ===== الألوان الوظيفية =====

  /// لون النجاح (للحالات الإيجابية)
  static const Color success = Color(0xFF4CAF50);

  /// لون التحذير
  static const Color warning = Color(0xFFFF9800);

  /// لون الخطأ
  static const Color error = Color(0xFFF44336);

  /// لون المعلومات
  static const Color info = Color(0xFF2196F3);

  // ===== ألوان العمولات ووسائل الدفع =====

  /// لون وسيلة الدفع بدون عمولة
  static Color noCommissionBackground = Colors.green.shade100;
  static const Color noCommissionIcon = Color(0xFF4CAF50);

  /// لون وسيلة الدفع مع عمولة
  static Color withCommissionBackground = Colors.orange.shade100;
  static const Color withCommissionIcon = Color(0xFFFF9800);

  // ===== الخلفيات =====

  /// خلفية ذهبية خفيفة للبطاقات
  static Color goldBackground10 = gold.withValues(alpha: 0.1);
  static Color goldBackground20 = gold.withValues(alpha: 0.2);
  static Color goldBackground30 = gold.withValues(alpha: 0.3);

  // ===== Theme للـ AppBar الذهبي =====

  /// إعدادات AppBar الذهبي الافتراضية
  static AppBarTheme get goldAppBarTheme => const AppBarTheme(
    backgroundColor: gold,
    foregroundColor: textOnGold,
    iconTheme: IconThemeData(color: iconOnGold),
    titleTextStyle: TextStyle(
      color: textOnGold,
      fontSize: 20,
      fontWeight: FontWeight.bold,
      fontFamily: 'Cairo',
    ),
    elevation: 2,
  );

  /// إعدادات ElevatedButton الذهبي
  static ButtonStyle get goldButtonStyle => ElevatedButton.styleFrom(
    backgroundColor: gold,
    foregroundColor: textOnGold,
    elevation: 2,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  /// إعدادات FloatingActionButton الذهبي
  static ButtonStyle get goldFABStyle => ElevatedButton.styleFrom(
    backgroundColor: gold,
    foregroundColor: textOnGold,
    elevation: 4,
  );

  // ===== دوال مساعدة =====

  /// يرجع اللون المناسب حسب وجود العمولة
  static Color getCommissionColor(double commission) {
    return commission > 0 ? withCommissionIcon : noCommissionIcon;
  }

  /// يرجع لون الخلفية المناسب حسب وجود العمولة
  static Color getCommissionBackgroundColor(double commission) {
    return commission > 0 ? withCommissionBackground : noCommissionBackground;
  }

  /// يرجع لون النص المناسب للخلفية
  static Color getContrastingTextColor(Color backgroundColor) {
    // حساب السطوع (luminance)
    final luminance = backgroundColor.computeLuminance();
    // إذا كانت الخلفية فاتحة، استخدم نص داكن والعكس
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }
}

/// Constants للقيم الثابتة
class AppConstants {
  // أقصى عدد لوسائل الدفع
  static const int maxPaymentMethods = 20;

  // نطاق نسبة الضريبة
  static const double minTaxRate = 0.0;
  static const double maxTaxRate = 100.0;

  // العيارات المتاحة
  static const List<int> availableKarats = [18, 21, 22, 24];

  // نطاق نسبة العمولة
  static const double minCommission = 0.0;
  static const double maxCommission = 100.0;
}
