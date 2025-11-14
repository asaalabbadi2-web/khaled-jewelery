import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../api_service.dart';

class SettingsProvider with ChangeNotifier {
  Map<String, dynamic> _settings = {};
  bool _isLoading = false;
  String? _error;

  Map<String, dynamic> get settings => _settings;
  bool get isLoading => _isLoading;
  String? get error => _error;

  // Getters للإعدادات الهامة
  String get currencySymbol => _settings['currency_symbol'] ?? 'ر.س';
  int get mainKarat => _safeInt(_settings['main_karat'], fallback: 21);
  int get decimalPlaces => _safeInt(_settings['decimal_places'], fallback: 2);
  String get dateFormat => _settings['date_format']?.toString() ?? 'DD/MM/YYYY';
  bool get taxEnabled => _safeBool(_settings['tax_enabled'], fallback: true);
  double get taxRate => _safeDouble(_settings['tax_rate'], fallback: 0.15);
  double get taxRatePercent => taxRate * 100;
  bool get allowDiscount =>
      _safeBool(_settings['allow_discount'], fallback: true);
  double get defaultDiscountRate =>
      _safeDouble(_settings['default_discount_rate'], fallback: 0.0);
  double get defaultDiscountPercent => defaultDiscountRate * 100;
  String get invoicePrefix => _settings['invoice_prefix']?.toString() ?? 'INV';
  bool get showCompanyLogo =>
      _safeBool(_settings['show_company_logo'], fallback: true);
  String get companyName => _settings['company_name']?.toString() ?? '';
  String get companyAddress => _settings['company_address']?.toString() ?? '';
  String get companyPhone => _settings['company_phone']?.toString() ?? '';
  String get companyTaxNumber =>
      _settings['company_tax_number']?.toString() ?? '';

  // Workflow: whether vouchers should be auto-posted on save
  bool get voucherAutoPost =>
      _safeBool(_settings['voucher_auto_post'], fallback: false);

  // Helper methods
  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  bool _safeBool(dynamic value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return fallback;
  }

  double _safeDouble(dynamic value, {double fallback = 0.0}) {
    if (value == null) return fallback;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  // تحميل الإعدادات من SharedPreferences أو API
  Future<void> loadSettings() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Try to load from local storage first
      final prefs = await SharedPreferences.getInstance();
      final cachedSettings = prefs.getString('app_settings');

      if (cachedSettings != null) {
        _settings = json.decode(cachedSettings);
        notifyListeners();
      }

      // Then fetch from API to get latest
      await fetchSettings();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> fetchSettings() async {
    try {
      _settings = await ApiService().getSettings();

      // Cache settings locally
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_settings', json.encode(_settings));

      notifyListeners();
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  Future<void> updateSettings(Map<String, dynamic> newSettings) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await ApiService().updateSettings(newSettings);

      // Update local settings immediately
      _settings = {..._settings, ...newSettings};

      // Cache updated settings
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_settings', json.encode(_settings));

      // Notify all listeners to update UI
      notifyListeners();

      // Fetch fresh settings from API
      await fetchSettings();
    } catch (e) {
      _error = e.toString();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // دالة مساعدة لتنسيق الأرقام حسب عدد الأصفار
  String formatNumber(double value) {
    return value.toStringAsFixed(decimalPlaces);
  }

  // دالة مساعدة لحساب الضريبة
  double calculateTax(double amount) {
    if (!taxEnabled) return 0.0;
    return amount * taxRate;
  }

  // دالة مساعدة لحساب الخصم
  double calculateDiscount(double amount, {double? customRate}) {
    if (!allowDiscount) return 0.0;
    final rate = customRate ?? defaultDiscountRate;
    return amount * rate;
  }
}
