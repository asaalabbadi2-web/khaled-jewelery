import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_semantic_colors.dart';

export 'app_semantic_colors.dart';

/// نظام الألوان الذهبي لتطبيق مجوهرات خالد
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

  static Color karatColorFor(dynamic karatOrKey) {
    final s = (karatOrKey ?? '').toString();
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    final k = int.tryParse(digits.isNotEmpty ? digits : s) ?? 21;
    switch (k) {
      case 18:
        return karat18;
      case 21:
        return karat21;
      case 22:
        return karat22;
      case 24:
        return karat24;
      default:
        return primaryGold;
    }
  }

  /// Dark variant for karat badge text on light-tinted backgrounds (WCAG AA).
  /// Use instead of karatColorFor() when text sits on karatColor.withOpacity(0.12).
  static Color karatBadgeTextColorFor(dynamic karatOrKey) {
    final s = (karatOrKey ?? '').toString();
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    final k = int.tryParse(digits.isNotEmpty ? digits : s) ?? 21;
    switch (k) {
      case 18:
        return const Color(0xFFB71C1C); // dark red — 9.7:1 on #FFF0F0
      case 21:
        return const Color(0xFF795500); // dark gold — 6.5:1 on #FAF4E5
      case 22:
        return const Color(0xFF004D40); // dark teal — 8.6:1 on #EAF9F9
      case 24:
        return const Color(0xFF4A148C); // dark purple — 7.2:1 on #F3EEF8
      default:
        return const Color(0xFF5D4037); // dark brown fallback
    }
  }

  /// Gold color safe for text on light backgrounds (dark mode: primaryGold, light mode: darkGold).
  static Color goldText(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? primaryGold : darkGold;

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

  // ===== شجرة الحسابات =====
  // انتقلت من constants/colors.dart (ثيم-٠: مصدر واحد للألوان) بقيمها كما هي.
  // للوضع الفاتح وحده؛ تنتقل إلى AppSemanticColors حين يُعمل على الشجرة.

  /// مدين — أخضر داكن
  static const Color debit = Color(0xFF0F6E56);

  /// دائن — أحمر داكن
  static const Color credit = Color(0xFFA32D2D);

  /// ذهبي محاسبي (الحسابات الوزنية، سهم التوسيع)
  static const Color goldTone = Color(0xFFC9A84C);

  /// خطوط شجرة التسلسل الهرمي
  static const Color treeLine = Color(0xFFEBE3D0);

  /// خلفية الحسابات التجميعية (Parent)
  static const Color parentRowBg = Color(0xFFFAF7F0);

  /// لون الحسابات المعطلة / النص الخافت
  static const Color muted = Color(0xFF5F5E5A);

  /// لون سهم التوسيع
  static const Color expandArrow = Color(0xFFA89968);

  // شارات أنواع الحسابات
  static const Color assetBadgeBg = Color(0xFFE1F5EE);
  static const Color assetBadgeFg = Color(0xFF0F6E56);
  static const Color liabBadgeBg = Color(0xFFFCEBEB);
  static const Color liabBadgeFg = Color(0xFFA32D2D);
  static const Color equityBadgeBg = Color(0xFFEEEDFE);
  static const Color equityBadgeFg = Color(0xFF534AB7);
  static const Color revenueBadgeBg = Color(0xFFEAF3DE);
  static const Color revenueBadgeFg = Color(0xFF3B6D11);
  static const Color expenseBadgeBg = Color(0xFFFAEEDA);
  static const Color expenseBadgeFg = Color(0xFF854F0B);
}

/// لوحة الألوان: كل دور معرّف صراحةً في الوضعين (ثيم-٠).
/// الدور غير المعرّف يرجع في Flutter إلى غيره: الحدّ إلى الأسود أو الأبيض،
/// و«أعلى حاوية» إلى لون البطاقة. لذلك لا يُترك هنا دور فارغ.
class AppSchemes {
  static const ColorScheme light = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF87600A),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFF4E4C1),
    onPrimaryContainer: Color(0xFF3A2C00),
    secondary: Color(0xFF6F5100),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF7E1A6),
    onSecondaryContainer: Color(0xFF3B2F05),
    tertiary: Color(0xFF006A60),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFC2EDE6),
    onTertiaryContainer: Color(0xFF00201C),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: Color(0xFFF7F3EC),
    onSurface: Color(0xFF1F1B13),
    onSurfaceVariant: Color(0xFF4D4635),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFBF8F2),
    surfaceContainer: Color(0xFFF6F1E8),
    surfaceContainerHigh: Color(0xFFF1EBE0),
    surfaceContainerHighest: Color(0xFFECE5D8),
    outline: Color(0xFF7F7663),
    outlineVariant: Color(0xFFD6CCB8),
    inverseSurface: Color(0xFF353027),
    onInverseSurface: Color(0xFFF8EFE2),
    inversePrimary: Color(0xFFE6C24F),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  static const ColorScheme dark = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFD4AF37),
    onPrimary: Color(0xFF1A1A1A),
    primaryContainer: Color(0xFF4F3F06),
    onPrimaryContainer: Color(0xFFFFE08B),
    secondary: Color(0xFFC99A2E),
    onSecondary: Color(0xFF241A00),
    secondaryContainer: Color(0xFF544519),
    onSecondaryContainer: Color(0xFFF7E1A6),
    tertiary: Color(0xFF82D5C8),
    onTertiary: Color(0xFF003731),
    tertiaryContainer: Color(0xFF005048),
    onTertiaryContainer: Color(0xFFC2EDE6),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: Color(0xFF1A1A1A),
    onSurface: Color(0xFFECE6DA),
    onSurfaceVariant: Color(0xFFCFC6B4),
    surfaceContainerLowest: Color(0xFF141414),
    surfaceContainerLow: Color(0xFF212121),
    surfaceContainer: Color(0xFF262626),
    surfaceContainerHigh: Color(0xFF2D2D2D),
    surfaceContainerHighest: Color(0xFF383838),
    outline: Color(0xFF999080),
    outlineVariant: Color(0xFF4A463E),
    inverseSurface: Color(0xFFE8E2D6),
    onInverseSurface: Color(0xFF32302B),
    inversePrimary: Color(0xFF87600A),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
}

ThemeData _buildTheme({
  required ColorScheme scheme,
  required Color card,
  required Color appBar,
  required Color onAppBar,
  required Color fieldFill,
}) {
  TextStyle t(double size, FontWeight weight, Color color) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    fontFamily: 'Cairo',
  );
  final isDark = scheme.brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    primaryColor: scheme.primary,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    cardColor: card,
    dividerColor: scheme.outlineVariant,
    extensions: [isDark ? AppSemanticColors.dark : AppSemanticColors.light],

    appBarTheme: AppBarTheme(
      backgroundColor: appBar,
      foregroundColor: onAppBar,
      elevation: isDark ? 4 : 2,
      centerTitle: false,
      iconTheme: IconThemeData(color: onAppBar),
      titleTextStyle: t(20, FontWeight.bold, onAppBar),
    ),

    cardTheme: CardThemeData(
      color: card,
      surfaceTintColor: Colors.transparent,
      elevation: isDark ? 4 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: card,
      surfaceTintColor: Colors.transparent,
    ),

    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: card,
      selectedItemColor: scheme.primary,
      unselectedItemColor: scheme.onSurfaceVariant,
      selectedLabelStyle: t(12, FontWeight.bold, scheme.primary),
      unselectedLabelStyle: t(12, FontWeight.normal, scheme.onSurfaceVariant),
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),

    drawerTheme: DrawerThemeData(
      backgroundColor: isDark ? scheme.surface : card,
      elevation: 16,
      shape: const RoundedRectangleBorder(),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      textColor: scheme.onSurface,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.5),
      selectedColor: scheme.primary,
    ),

    textTheme: TextTheme(
      displayLarge: t(32, FontWeight.bold, scheme.onSurface),
      displayMedium: t(28, FontWeight.bold, scheme.onSurface),
      displaySmall: t(24, FontWeight.bold, scheme.onSurface),
      headlineMedium: t(20, FontWeight.bold, scheme.onSurface),
      headlineSmall: t(18, FontWeight.w600, scheme.onSurface),
      titleLarge: t(16, FontWeight.w600, scheme.onSurface),
      titleMedium: t(14, FontWeight.w500, scheme.onSurface),
      bodyLarge: t(14, FontWeight.normal, scheme.onSurface),
      bodyMedium: t(13, FontWeight.normal, scheme.onSurfaceVariant),
      bodySmall: t(12, FontWeight.normal, scheme.onSurfaceVariant),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: isDark ? 4 : 2,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: t(14, FontWeight.bold, scheme.onPrimary),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      labelStyle: TextStyle(
        color: scheme.onSurfaceVariant,
        fontFamily: 'Cairo',
      ),
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        fontFamily: 'Cairo',
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: isDark ? 6 : 4,
    ),

    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),

    fontFamily: 'Cairo',
  );
}

/// ثيم فاتح - أبيض + ذهبي
class LightTheme {
  static ThemeData get theme => _buildTheme(
    scheme: AppSchemes.light,
    card: AppSchemes.light.surfaceContainerLowest,
    appBar: AppSchemes.light.primary,
    onAppBar: AppSchemes.light.onPrimary,
    fieldFill: AppSchemes.light.surfaceContainerLow,
  );
}

/// ثيم داكن - رمادي فحمي + ذهبي
class DarkTheme {
  static ThemeData get theme => _buildTheme(
    scheme: AppSchemes.dark,
    card: AppSchemes.dark.surfaceContainerHigh,
    appBar: AppSchemes.dark.surfaceContainerHigh,
    onAppBar: AppSchemes.dark.primary,
    fieldFill: AppSchemes.dark.surfaceContainer,
  );
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
