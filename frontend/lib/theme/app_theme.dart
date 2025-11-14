import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// نظام الألوان الذهبي لتطبيق ياسار للذهب
class AppColors {
  // ألوان ذهبية - مشتركة بين الوضعين
  static const Color primaryGold = Color(0xFFD4AF37); // ذهبي فاخر
  static const Color darkGold = Color(0xFFB8860B); // ذهبي داكن
  static const Color mediumGold = Color(0xFFCD9D3C); // ذهبي متوسط
  static const Color lightGold = Color(0xFFF4E4C1); // ذهبي فاتح
  static const Color deepGold = Color(0xFF9A7D0A); // ذهبي عميق

  // ألوان الحالة
  static const Color success = Color(0xFF2E7D32); // أخضر للنجاح
  static const Color warning = Color(0xFFE65100); // برتقالي للتحذير
  static const Color error = Color(0xFFD32F2F); // أحمر للخطأ
  static const Color info = Color(0xFF1976D2); // أزرق للمعلومات

  // ألوان العيارات
  static const Color karat18 = Color(0xFFFF6B6B); // أحمر فاتح
  static const Color karat21 = Color(0xFFD4AF37); // ذهبي كلاسيكي
  static const Color karat22 = Color(0xFF4ECDC4); // تركواز
  static const Color karat24 = Color(0xFF9B59B6); // بنفسجي

  // ألوان الفواتير - للتفريق البصري بين أنواع الفواتير
  static const Color invoiceSaleNew = Color(
    0xFF2E7D32,
  ); // أخضر زيتوني - بيع جديد
  static const Color invoiceSaleScrap = Color(
    0xFF00897B,
  ); // تركواز غامق - بيع كسر
  static const Color invoicePurchaseScrap = Color(
    0xFFD84315,
  ); // برتقالي محمر - شراء كسر
  static const Color invoicePurchaseNew = Color(
    0xFF5E35B1,
  ); // بنفسجي غامق - شراء جديد
  static const Color invoiceReturn = Color(0xFFE53935); // أحمر - مرتجع
}

/// ثيم فاتح - أبيض + ذهبي
class LightTheme {
  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,

      // الألوان الأساسية
      primaryColor: AppColors.primaryGold,
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),

      // نظام الألوان
      colorScheme: ColorScheme.light(
        primary: AppColors.primaryGold,
        secondary: AppColors.darkGold,
        surface: Colors.white,
        error: AppColors.error,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: const Color(0xFF212121),
        onError: Colors.white,
        brightness: Brightness.light,
      ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.darkGold,
        foregroundColor: Colors.white,
        elevation: 4,
        centerTitle: false,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          fontFamily: 'Cairo',
        ),
      ),

      // البطاقات
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: Colors.black.withValues(alpha: 0.08),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: AppColors.darkGold,
        unselectedItemColor: Colors.grey[400],
        selectedLabelStyle: const TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12,
        ),
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),

      // Drawer
      drawerTheme: DrawerThemeData(
        backgroundColor: Colors.white,
        elevation: 16,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(0),
            bottomRight: Radius.circular(0),
          ),
        ),
      ),

      // ListTile
      listTileTheme: ListTileThemeData(
        iconColor: Colors.grey[700],
        textColor: Colors.grey[800],
        selectedTileColor: AppColors.lightGold.withValues(alpha: 0.2),
        selectedColor: AppColors.darkGold,
      ),

      // النصوص
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: Colors.grey[900],
          fontFamily: 'Cairo',
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: Colors.grey[900],
          fontFamily: 'Cairo',
        ),
        displaySmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.grey[800],
          fontFamily: 'Cairo',
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.grey[800],
          fontFamily: 'Cairo',
        ),
        headlineSmall: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.grey[800],
          fontFamily: 'Cairo',
        ),
        titleLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.grey[800],
          fontFamily: 'Cairo',
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.grey[700],
          fontFamily: 'Cairo',
        ),
        bodyLarge: TextStyle(
          fontSize: 14,
          color: Colors.grey[800],
          fontFamily: 'Cairo',
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          color: Colors.grey[700],
          fontFamily: 'Cairo',
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
          fontFamily: 'Cairo',
        ),
      ),

      // الأزرار
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryGold,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
          ),
        ),
      ),

      // حقول الإدخال
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[50],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primaryGold, width: 2),
        ),
        labelStyle: TextStyle(color: Colors.grey[700], fontFamily: 'Cairo'),
        hintStyle: TextStyle(color: Colors.grey[400], fontFamily: 'Cairo'),
      ),

      // FloatingActionButton
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primaryGold,
        foregroundColor: Colors.white,
        elevation: 4,
      ),

      // Divider
      dividerTheme: DividerThemeData(
        color: Colors.grey[300],
        thickness: 1,
        space: 1,
      ),

      // الخط الافتراضي
      fontFamily: 'Cairo',
    );
  }
}

/// ثيم داكن - رمادي فحمي + ذهبي
class DarkTheme {
  static ThemeData get theme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,

      // الألوان الأساسية
      primaryColor: AppColors.primaryGold,
      scaffoldBackgroundColor: const Color(0xFF1A1A1A),

      // نظام الألوان
      colorScheme: ColorScheme.dark(
        primary: AppColors.primaryGold,
        secondary: AppColors.darkGold,
        surface: const Color(0xFF2D2D2D),
        error: AppColors.error,
        onPrimary: const Color(0xFF1A1A1A),
        onSecondary: Colors.white,
        onSurface: Colors.white,
        onError: Colors.white,
        brightness: Brightness.dark,
      ),

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF2D2D2D),
        foregroundColor: AppColors.primaryGold,
        elevation: 4,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.primaryGold),
        titleTextStyle: TextStyle(
          color: AppColors.primaryGold,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          fontFamily: 'Cairo',
        ),
      ),

      // البطاقات
      cardTheme: CardThemeData(
        color: const Color(0xFF2D2D2D),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        shadowColor: Colors.black.withValues(alpha: 0.3),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: const Color(0xFF2D2D2D),
        selectedItemColor: AppColors.primaryGold,
        unselectedItemColor: Colors.grey[600],
        selectedLabelStyle: const TextStyle(
          fontFamily: 'Cairo',
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
        unselectedLabelStyle: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12,
        ),
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),

      // Drawer
      drawerTheme: const DrawerThemeData(
        backgroundColor: Color(0xFF1A1A1A),
        elevation: 16,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(0),
            bottomRight: Radius.circular(0),
          ),
        ),
      ),

      // ListTile
      listTileTheme: ListTileThemeData(
        iconColor: Colors.grey[400],
        textColor: Colors.grey[300],
        selectedTileColor: AppColors.darkGold.withValues(alpha: 0.2),
        selectedColor: AppColors.primaryGold,
      ),

      // النصوص
      textTheme: TextTheme(
        displayLarge: const TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontFamily: 'Cairo',
        ),
        displayMedium: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontFamily: 'Cairo',
        ),
        displaySmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: Colors.grey[200],
          fontFamily: 'Cairo',
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.grey[200],
          fontFamily: 'Cairo',
        ),
        headlineSmall: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.grey[300],
          fontFamily: 'Cairo',
        ),
        titleLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.grey[300],
          fontFamily: 'Cairo',
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.grey[400],
          fontFamily: 'Cairo',
        ),
        bodyLarge: TextStyle(
          fontSize: 14,
          color: Colors.grey[300],
          fontFamily: 'Cairo',
        ),
        bodyMedium: TextStyle(
          fontSize: 13,
          color: Colors.grey[400],
          fontFamily: 'Cairo',
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: Colors.grey[500],
          fontFamily: 'Cairo',
        ),
      ),

      // الأزرار
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primaryGold,
          foregroundColor: const Color(0xFF1A1A1A),
          elevation: 4,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
          ),
        ),
      ),

      // حقول الإدخال
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2D2D2D),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[700]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[700]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primaryGold, width: 2),
        ),
        labelStyle: TextStyle(color: Colors.grey[400], fontFamily: 'Cairo'),
        hintStyle: TextStyle(color: Colors.grey[600], fontFamily: 'Cairo'),
      ),

      // FloatingActionButton
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primaryGold,
        foregroundColor: Color(0xFF1A1A1A),
        elevation: 6,
      ),

      // Divider
      dividerTheme: DividerThemeData(
        color: Colors.grey[800],
        thickness: 1,
        space: 1,
      ),

      // الخط الافتراضي
      fontFamily: 'Cairo',
    );
  }
}

/// مزود الثيم - للتحكم في تبديل الوضع
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;

  ThemeMode get themeMode => _themeMode;

  bool get isDarkMode => _themeMode == ThemeMode.dark;

  ThemeProvider() {
    _loadThemePreference();
  }

  // تحميل التفضيلات المحفوظة
  Future<void> _loadThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDark = prefs.getBool('isDarkMode') ?? false;
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
      notifyListeners();
    } catch (e) {
      debugPrint('خطأ في تحميل إعدادات الثيم: $e');
    }
  }

  // حفظ التفضيلات
  Future<void> _saveThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isDarkMode', isDarkMode);
    } catch (e) {
      debugPrint('خطأ في حفظ إعدادات الثيم: $e');
    }
  }

  void toggleTheme() {
    _themeMode = _themeMode == ThemeMode.light
        ? ThemeMode.dark
        : ThemeMode.light;
    _saveThemePreference();
    notifyListeners();
  }

  void setTheme(ThemeMode mode) {
    _themeMode = mode;
    _saveThemePreference();
    notifyListeners();
  }
}
