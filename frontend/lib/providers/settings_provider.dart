import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../api_service.dart';

class SettingsProvider with ChangeNotifier {
  static const Map<String, dynamic> _defaultWeightClosingSettings = {
    'enabled': true,
    'price_source': 'live',
    'allow_override': true,
    'shift_close_cash_deficit_threshold': 50.0,
    'shift_close_gold_pure_deficit_threshold_grams': 0.10,
  };

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

  List<int> get vatExemptKarats {
    final raw = _settings['vat_exempt_karats'];

    List<dynamic> candidates = const [];
    if (raw is List) {
      candidates = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is List) {
          candidates = decoded;
        } else {
          candidates = [decoded];
        }
      } catch (_) {
        candidates = raw.split(',');
      }
    }

    final out = <int>{};
    for (final v in candidates) {
      final parsed = int.tryParse(v.toString().trim());
      if (parsed == null) continue;
      if (parsed == 18 || parsed == 21 || parsed == 22 || parsed == 24) {
        out.add(parsed);
      }
    }

    // Default policy: 24k exempt, unless explicitly configured otherwise.
    if (out.isEmpty) return const [24];
    final sorted = out.toList()..sort();
    return sorted;
  }

  bool isVatExemptKarat(num karat) {
    final k = karat.round();
    return vatExemptKarats.contains(k);
  }

  double taxRateForKarat(num karat) {
    if (!taxEnabled) return 0.0;
    if (isVatExemptKarat(karat)) return 0.0;
    return taxRate;
  }

  bool get allowDiscount =>
      _safeBool(_settings['allow_discount'], fallback: true);
  bool get allowManualInvoiceItems =>
      _safeBool(_settings['allow_manual_invoice_items'], fallback: true);

  bool get allowPartialInvoicePayments =>
      _safeBool(_settings['allow_partial_invoice_payments'], fallback: false);

  bool get idleTimeoutEnabled =>
      _safeBool(_settings['idle_timeout_enabled'], fallback: true);

  int get idleTimeoutMinutes {
    final dynamic raw = _settings['idle_timeout_minutes'];
    int? minutes;
    if (raw is int) {
      minutes = raw;
    } else if (raw is double) {
      minutes = raw.toInt();
    } else if (raw != null) {
      minutes = int.tryParse(raw.toString().trim());
    }

    // Fallback if server doesn't provide it yet.
    minutes ??= const int.fromEnvironment(
      'IDLE_TIMEOUT_MINUTES',
      defaultValue: 30,
    );

    if (minutes < 1) minutes = 1;
    if (minutes > 10080) minutes = 10080;
    return minutes;
  }

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

  Map<String, dynamic> get weightClosingSettings =>
      _normalizeWeightClosingSettings(_settings['weight_closing_settings']);

  bool get weightClosingEnabled =>
      _safeBool(weightClosingSettings['enabled'], fallback: true);

  String get weightClosingPriceSource =>
      (weightClosingSettings['price_source']?.toString() ?? 'live');

  bool get weightClosingAllowOverride =>
      _safeBool(weightClosingSettings['allow_override'], fallback: true);

  double get shiftCloseCashDeficitThreshold => _safeDouble(
    weightClosingSettings['shift_close_cash_deficit_threshold'],
    fallback: 50.0,
  );

  double get shiftCloseGoldPureDeficitThresholdGrams => _safeDouble(
    weightClosingSettings['shift_close_gold_pure_deficit_threshold_grams'],
    fallback: 0.10,
  );

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

  Map<String, dynamic> _normalizeWeightClosingSettings(dynamic raw) {
    final normalized = Map<String, dynamic>.from(_defaultWeightClosingSettings);
    Map<String, dynamic>? parsed;

    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map<String, dynamic>) {
          parsed = decoded;
        } else if (decoded is Map) {
          parsed = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        parsed = null;
      }
    } else if (raw is Map<String, dynamic>) {
      parsed = raw;
    } else if (raw is Map) {
      parsed = Map<String, dynamic>.from(raw);
    }

    if (parsed != null) {
      final priceSource =
          (parsed['price_source']?.toString().toLowerCase()) ?? 'live';
      if (priceSource == 'average') {
        normalized['price_source'] = 'average';
      } else if (priceSource == 'invoice') {
        normalized['price_source'] = 'invoice';
      } else {
        normalized['price_source'] = 'live';
      }
      normalized['enabled'] = _safeBool(
        parsed['enabled'],
        fallback: normalized['enabled'] as bool,
      );
      normalized['allow_override'] = _safeBool(
        parsed['allow_override'],
        fallback: normalized['allow_override'] as bool,
      );

      final cashThreshold = _safeDouble(
        parsed['shift_close_cash_deficit_threshold'],
        fallback: (normalized['shift_close_cash_deficit_threshold'] as num)
            .toDouble(),
      );
      normalized['shift_close_cash_deficit_threshold'] = cashThreshold < 0
          ? 0.0
          : cashThreshold;

      final goldThreshold = _safeDouble(
        parsed['shift_close_gold_pure_deficit_threshold_grams'],
        fallback:
            (normalized['shift_close_gold_pure_deficit_threshold_grams'] as num)
                .toDouble(),
      );
      normalized['shift_close_gold_pure_deficit_threshold_grams'] =
          goldThreshold < 0 ? 0.0 : goldThreshold;
    }

    return normalized;
  }

  // تحميل الإعدادات من SharedPreferences أو API
  // - fetchRemote=false: لا يستدعي API (مفيد للحسابات التي لا تملك system.settings)
  Future<void> loadSettings({bool fetchRemote = true}) async {
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

      // Then fetch from API to get latest (only if allowed)
      if (fetchRemote) {
        await fetchSettings();
      }
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

  Future<Map<String, dynamic>> fetchWeightClosingSettings() async {
    try {
      final data = await ApiService().getWeightClosingSettings();
      await _applyWeightClosingSettings(data);
      return data;
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> updateWeightClosingSettingsPayload(
    Map<String, dynamic> payload,
  ) async {
    try {
      final updated = await ApiService().updateWeightClosingSettings(payload);
      await _applyWeightClosingSettings(updated);
      return updated;
    } catch (e) {
      _error = e.toString();
      rethrow;
    }
  }

  Future<void> applyWeightClosingSettingsLocally(
    Map<String, dynamic> settings,
  ) async {
    await _applyWeightClosingSettings(settings);
  }

  Future<void> _applyWeightClosingSettings(
    Map<String, dynamic> settings,
  ) async {
    _settings = {..._settings, 'weight_closing_settings': settings};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_settings', json.encode(_settings));
    notifyListeners();
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
