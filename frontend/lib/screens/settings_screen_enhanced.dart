import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printing/printing.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import 'accounting_mapping_screen_enhanced.dart';
import 'payment_methods_screen_enhanced.dart';
import 'safe_boxes_screen.dart';
import 'chart_of_accounts_screen.dart';
import 'gold_price_manual_screen_enhanced.dart';
import 'backup_restore_screen.dart';
import 'system_reset_screen.dart';
import 'weight_closing_settings_screen.dart';
import 'template_studio_screen.dart';
import '../utils.dart';

enum SettingsEntry {
  goldPrice,
  weightClosing,
  systemReset,
  printerSettings,
  about,
}

enum _AccountPickFilter { all, weightOnly, nonWeightOnly }

class SettingsScreenEnhanced extends StatefulWidget {
  static const int systemTabIndex = 5;

  final int initialTabIndex;
  final SettingsEntry? focusEntry;

  const SettingsScreenEnhanced({
    super.key,
    this.initialTabIndex = 0,
    this.focusEntry,
  });

  @override
  State<SettingsScreenEnhanced> createState() => _SettingsScreenEnhancedState();
}

class _SettingsScreenEnhancedState extends State<SettingsScreenEnhanced>
    with SingleTickerProviderStateMixin {
  late final ApiService _apiService;
  late final TabController _tabController;
  static const int _tabCount = 6;

  final ScrollController _systemScrollController = ScrollController();
  late final Map<SettingsEntry, GlobalKey> _systemSectionKeys = {
    SettingsEntry.goldPrice: GlobalKey(),
    SettingsEntry.weightClosing: GlobalKey(),
    SettingsEntry.systemReset: GlobalKey(),
    SettingsEntry.printerSettings: GlobalKey(),
    SettingsEntry.about: GlobalKey(),
  };

  SettingsEntry? _pendingFocusEntry;

  int get _systemTabIndex => SettingsScreenEnhanced.systemTabIndex;

  final TextEditingController _currencyController = TextEditingController();
  final TextEditingController _companyNameController = TextEditingController();
  final TextEditingController _companyAddressController =
      TextEditingController();
  final TextEditingController _companyPhoneController = TextEditingController();
  final TextEditingController _companyTaxNumberController =
      TextEditingController();
  final TextEditingController _invoicePrefixController =
      TextEditingController();

  final List<int> _karatOptions = const [18, 21, 22, 24];
  final List<int> _decimalOptions = const [2, 3, 4];
  final List<String> _dateFormats = const [
    'DD/MM/YYYY',
    'MM/DD/YYYY',
    'YYYY-MM-DD',
  ];

  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isSaving = false;

  int _mainKarat = 21;
  int _decimalPlaces = 2;
  String _dateFormat = 'DD/MM/YYYY';

  bool _taxEnabled = true;
  double _taxRatePercent = 15.0;
  Set<int> _vatExemptKarats = {24};

  bool _showCompanyLogo = true;
  bool _allowDiscount = true;
  double _defaultDiscountPercent = 0.0;
  bool _allowManualInvoiceItems = false;

  bool _requireAuthForInvoiceCreate = false;

  bool _idleTimeoutEnabled = true;
  int _idleTimeoutMinutes = 30;

  bool _allowPartialInvoicePayments = false;

  bool _voucherAutoPost = false;

  // ---------------------------------------------------------------------------
  // 🆕 Feature toggles + default safes (employee routing)
  // ---------------------------------------------------------------------------
  bool _employeeCashSafesEnabled = false;
  bool _employeeGoldSafesEnabled = false;
  int? _mainCashSafeBoxId;
  int? _saleGoldSafeBoxId;
  int? _mainScrapGoldSafeBoxId;

  bool _safeBoxesLoaded = false;
  bool _isLoadingSafeBoxes = false;
  List<SafeBoxModel> _cashSafeBoxes = const [];
  List<SafeBoxModel> _goldSafeBoxes = const [];

  bool _accountsLoaded = false;
  bool _isLoadingAccounts = false;
  List<Map<String, dynamic>> _allAccounts = const [];


  bool _printerAutoConnect = true;
  bool _printerShowPreview = false;
  bool _printerAutoCut = true;
  String _printerPaperSize = '80 مم';
  final List<String> _printerPaperOptions = const ['58 مم', '80 مم', 'A4'];

  static const String _printerAutoConnectKey = 'printer_auto_connect_v1';
  static const String _printerShowPreviewKey = 'printer_show_preview_v1';
  static const String _printerAutoCutKey = 'printer_auto_cut_v1';
  static const String _printerPaperSizeKey = 'printer_paper_size_v1';
  static const String _printerPreferredNameKey = 'printer_preferred_name_v1';

  String? _preferredPrinterName;
  bool _isLoadingPrinters = false;
  List<Printer> _availablePrinters = const [];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService();
    _pendingFocusEntry = widget.focusEntry;

    int initialTab = widget.initialTabIndex;
    if (_pendingFocusEntry != null) {
      initialTab = _systemTabIndex;
    }
    if (initialTab < 0) {
      initialTab = 0;
    } else if (initialTab >= _tabCount) {
      initialTab = _tabCount - 1;
    }

    _tabController = TabController(
      length: _tabCount,
      vsync: this,
      initialIndex: initialTab,
    );
    _loadInitialData();
  }

  @override
  void dispose() {
    _systemScrollController.dispose();
    _tabController.dispose();
    _currencyController.dispose();
    _companyNameController.dispose();
    _companyAddressController.dispose();
    _companyPhoneController.dispose();
    _companyTaxNumberController.dispose();
    _invoicePrefixController.dispose();
    super.dispose();
  }

  ColorScheme get _colors => Theme.of(context).colorScheme;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Color get _primaryColor => _colors.primary;
  Color get _accentColor => _colors.secondary;
  Color get _successColor => _colors.tertiary;
  Color get _errorColor => _colors.error;
  Color get _surfaceColor => _colors.surface;
  Color get _outlineColor => _colors.outline;

  Color get _mutedTextColor =>
      _isDark ? _colors.onSurfaceVariant : _colors.onSurfaceVariant;
  Color get _strongTextColor => _isDark ? _colors.onSurface : _colors.onSurface;
  Color get _cardColor => _isDark
      ? Color.alphaBlend(
          _withOpacity(_colors.surfaceContainerHighest, 0.45),
          _surfaceColor,
        )
      : Color.alphaBlend(_withOpacity(_colors.primary, 0.06), _surfaceColor);

  String get _currencySymbol => _currencyController.text.trim().isEmpty
      ? 'ر.س'
      : _currencyController.text.trim();

  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = await _apiService.getSettings();

      // Load safe boxes for selectors (best-effort)
      List<SafeBoxModel> cashSafes = const [];
      List<SafeBoxModel> goldSafes = const [];
      try {
        final results = await Future.wait<List<SafeBoxModel>>([
          _apiService.getSafeBoxes(
            safeType: 'cash',
            includeAccount: true,
          ),
          _apiService.getSafeBoxes(
            safeType: 'gold',
            includeAccount: true,
          ),
        ]);

        cashSafes = results[0];
        goldSafes = results[1];

        cashSafes.sort((a, b) => a.name.compareTo(b.name));
        goldSafes.sort((a, b) => a.name.compareTo(b.name));
      } catch (_) {
        cashSafes = const [];
        goldSafes = const [];
      }

      if (!mounted) return;

      final printerAutoConnect = prefs.getBool(_printerAutoConnectKey) ?? true;
      final printerShowPreview = prefs.getBool(_printerShowPreviewKey) ?? false;
      final printerAutoCut = prefs.getBool(_printerAutoCutKey) ?? true;
      final printerPaperSize = prefs.getString(_printerPaperSizeKey) ?? '80 مم';
      final preferredPrinterName = prefs.getString(_printerPreferredNameKey);

      _currencyController.text =
          settings['currency_symbol']?.toString() ?? 'ر.س';
      _companyNameController.text = settings['company_name']?.toString() ?? '';
      _companyAddressController.text =
          settings['company_address']?.toString() ?? '';
      _companyPhoneController.text =
          settings['company_phone']?.toString() ?? '';
      _companyTaxNumberController.text =
          settings['company_tax_number']?.toString() ?? '';
      _invoicePrefixController.text =
          settings['invoice_prefix']?.toString() ?? 'INV';

      setState(() {
        _isInitialized = true;
        _mainKarat = _safeInt(settings['main_karat'], fallback: 21);
        _decimalPlaces = _safeInt(
          settings['decimal_places'],
          fallback: 2,
        ).clamp(2, 4);
        _dateFormat =
            settings['date_format']?.toString().toUpperCase() ?? 'DD/MM/YYYY';

        _taxEnabled = _safeBool(settings['tax_enabled'], fallback: true);
        _taxRatePercent = _normalizePercent(
          settings['tax_rate'],
          fallbackPercent: 15,
        );

        // VAT exemptions by karat (default: 24)
        final rawExempt = settings['vat_exempt_karats'];
        final parsed = <int>{};
        if (rawExempt is List) {
          for (final v in rawExempt) {
            final k = int.tryParse(v.toString().trim());
            if (k == null) continue;
            if (_karatOptions.contains(k)) parsed.add(k);
          }
        } else if (rawExempt is String && rawExempt.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(rawExempt);
            if (decoded is List) {
              for (final v in decoded) {
                final k = int.tryParse(v.toString().trim());
                if (k == null) continue;
                if (_karatOptions.contains(k)) parsed.add(k);
              }
            }
          } catch (_) {
            for (final part in rawExempt.split(',')) {
              final k = int.tryParse(part.trim());
              if (k == null) continue;
              if (_karatOptions.contains(k)) parsed.add(k);
            }
          }
        }
        _vatExemptKarats = parsed.isEmpty ? {24} : parsed;

        _showCompanyLogo = _safeBool(
          settings['show_company_logo'],
          fallback: true,
        );
        _allowDiscount = _safeBool(settings['allow_discount'], fallback: true);
        _allowManualInvoiceItems = _safeBool(
          settings['allow_manual_invoice_items'],
          fallback: false,
        );

        _requireAuthForInvoiceCreate = _safeBool(
          settings['require_auth_for_invoice_create'],
          fallback: false,
        );

        _idleTimeoutEnabled = _safeBool(
          settings['idle_timeout_enabled'],
          fallback: true,
        );

        final dynamic rawIdleMinutes = settings['idle_timeout_minutes'];
        int? parsedIdleMinutes;
        if (rawIdleMinutes is int) {
          parsedIdleMinutes = rawIdleMinutes;
        } else if (rawIdleMinutes is double) {
          parsedIdleMinutes = rawIdleMinutes.toInt();
        } else if (rawIdleMinutes != null) {
          parsedIdleMinutes = int.tryParse(rawIdleMinutes.toString().trim());
        }
        parsedIdleMinutes ??= 30;
        if (parsedIdleMinutes < 1) parsedIdleMinutes = 1;
        if (parsedIdleMinutes > 10080) parsedIdleMinutes = 10080;
        _idleTimeoutMinutes = parsedIdleMinutes;

        _allowPartialInvoicePayments = _safeBool(
          settings['allow_partial_invoice_payments'],
          fallback: false,
        );
        _defaultDiscountPercent = _normalizePercent(
          settings['default_discount_rate'],
          fallbackPercent: 0,
        );

        _voucherAutoPost = _safeBool(
          settings['voucher_auto_post'],
          fallback: false,
        );

        // 🆕 Feature toggles + default safes
        _employeeCashSafesEnabled = _safeBool(
          settings['employee_cash_safes_enabled'],
          fallback: false,
        );
        _employeeGoldSafesEnabled = _safeBool(
          settings['employee_gold_safes_enabled'],
          fallback: false,
        );
        _mainCashSafeBoxId = _safeNullableInt(settings['main_cash_safe_box_id']);
        _saleGoldSafeBoxId = _safeNullableInt(settings['sale_gold_safe_box_id']);
        _mainScrapGoldSafeBoxId = _safeNullableInt(
          settings['main_scrap_gold_safe_box_id'],
        );

        _cashSafeBoxes = cashSafes;
        _goldSafeBoxes = goldSafes;
        _safeBoxesLoaded = cashSafes.isNotEmpty || goldSafes.isNotEmpty;

        _printerAutoConnect = printerAutoConnect;
        _printerShowPreview = printerShowPreview;
        _printerAutoCut = printerAutoCut;
        _printerPaperSize = _printerPaperOptions.contains(printerPaperSize)
            ? printerPaperSize
            : '80 مم';
        _preferredPrinterName = preferredPrinterName;

      });
    } catch (error) {
      if (!mounted) return;
      _showSnack('تعذر تحميل الإعدادات: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        if (_pendingFocusEntry != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _pendingFocusEntry == null) return;
            _scrollToSystemEntry(_pendingFocusEntry!);
          });
        }
      }
    }
  }

  Future<void> _saveSettings() async {
    if (_isSaving) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _isSaving = true;
    });

    final payload = <String, dynamic>{
      'main_karat': _mainKarat,
      'currency_symbol': _currencySymbol,
      'decimal_places': _decimalPlaces,
      'date_format': _dateFormat,
      'tax_enabled': _taxEnabled,
      'tax_rate': _taxRatePercent / 100,
      'vat_exempt_karats': (_vatExemptKarats.toList()..sort()),
      'allow_discount': _allowDiscount,
      'allow_manual_invoice_items': _allowManualInvoiceItems,
      'default_discount_rate': _defaultDiscountPercent / 100,
      'invoice_prefix': _invoicePrefixController.text.trim(),
      'show_company_logo': _showCompanyLogo,
      'company_name': _companyNameController.text.trim(),
      'company_address': _companyAddressController.text.trim(),
      'company_phone': _companyPhoneController.text.trim(),
      'company_tax_number': _companyTaxNumberController.text.trim(),
      'voucher_auto_post': _voucherAutoPost,
      'require_auth_for_invoice_create': _requireAuthForInvoiceCreate,
      'idle_timeout_enabled': _idleTimeoutEnabled,
      'idle_timeout_minutes': _idleTimeoutMinutes,
      'allow_partial_invoice_payments': _allowPartialInvoicePayments,

      // 🆕 Feature toggles + default safes (employee routing)
      'employee_cash_safes_enabled': _employeeCashSafesEnabled,
      'employee_gold_safes_enabled': _employeeGoldSafesEnabled,
      'main_cash_safe_box_id': _mainCashSafeBoxId,
      'sale_gold_safe_box_id': _saleGoldSafeBoxId,
      'main_scrap_gold_safe_box_id': _mainScrapGoldSafeBoxId,
    };

    try {
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      await settingsProvider.updateSettings(payload);

      // Persist printer preferences locally (not part of backend settings).
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_printerAutoConnectKey, _printerAutoConnect);
        await prefs.setBool(_printerShowPreviewKey, _printerShowPreview);
        await prefs.setBool(_printerAutoCutKey, _printerAutoCut);
        await prefs.setString(_printerPaperSizeKey, _printerPaperSize);
        final preferred = _preferredPrinterName?.trim();
        if (preferred == null || preferred.isEmpty) {
          await prefs.remove(_printerPreferredNameKey);
        } else {
          await prefs.setString(_printerPreferredNameKey, preferred);
        }
      } catch (_) {
        // ignore local persistence failures
      }

      if (!mounted) return;
      _showSnack('✅ تم حفظ الإعدادات وتطبيقها على جميع الشاشات');
    } catch (error) {
      if (!mounted) return;
      _showSnack('تعذر حفظ الإعدادات: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, textAlign: TextAlign.center),
          backgroundColor: isError ? _errorColor : _primaryColor,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إعدادات النظام'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(icon: Icon(Icons.tune), text: 'عام'),
            Tab(icon: Icon(Icons.business), text: 'الشركة والفواتير'),
            Tab(icon: Icon(Icons.payments), text: 'المدفوعات'),
            Tab(icon: Icon(Icons.account_tree), text: 'محاسبة'),
            Tab(icon: Icon(Icons.print), text: 'الطباعة'),
            Tab(icon: Icon(Icons.settings_applications), text: 'النظام'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(
              end: 16,
              top: 8,
              bottom: 8,
            ),
            child: FilledButton.icon(
              onPressed: (_isSaving || !_isInitialized) ? null : _saveSettings,
              icon: _isSaving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _colors.onPrimary,
                        ),
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(_isSaving ? 'جار الحفظ...' : 'حفظ'),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? _buildLoading(theme)
          : TabBarView(
              controller: _tabController,
              children: [
                _buildGeneralTab(),
                _buildCompanyAndInvoicesTab(),
                _buildPaymentTab(),
                _buildAccountingTab(),
                _buildPrintingTab(),
                _buildSystemTab(),
              ],
            ),
    );
  }

  Widget _buildLoading(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _primaryColor),
          const SizedBox(height: 16),
          Text('جار تحميل الإعدادات...', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildGeneralTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.diamond_outlined,
          iconColor: _primaryColor,
          title: 'إعدادات الذهب',
          children: [
            Text('العيار الرئيسي', style: _fieldLabelStyle()),
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.rtl,
              child: DropdownMenu<int>(
                initialSelection: _mainKarat,
                onSelected: (value) {
                  if (value == null) return;
                  setState(() => _mainKarat = value);
                },
                leadingIcon: Icon(Icons.scale, color: _primaryColor),
                trailingIcon: const Icon(Icons.keyboard_arrow_down),
                textStyle: Theme.of(context).textTheme.bodyLarge,
                enableSearch: false,
                inputDecorationTheme: _dropdownDecoration(
                  accentColor: _primaryColor,
                ),
                dropdownMenuEntries: _karatOptions
                    .map(
                      (karat) => DropdownMenuEntry<int>(
                        value: karat,
                        label: 'عيار $karat',
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.style,
          iconColor: _accentColor,
          title: 'التنسيق والعملة',
          children: [
            Text('رمز العملة', style: _fieldLabelStyle()),
            const SizedBox(height: 12),
            TextFormField(
              controller: _currencyController,
              textDirection: TextDirection.rtl,
              decoration: _inputDecoration(
                icon: Icons.attach_money,
                accentColor: _accentColor,
              ),
            ),
            const SizedBox(height: 20),
            Text('عدد المنازل العشرية', style: _fieldLabelStyle()),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _decimalOptions
                  .map(
                    (value) => ChoiceChip(
                      label: Text('$value'),
                      selected: _decimalPlaces == value,
                      onSelected: (_) => setState(() => _decimalPlaces = value),
                      selectedColor: _blendOnSurface(_accentColor, 0.4),
                      labelStyle: TextStyle(
                        color: _decimalPlaces == value
                            ? _colors.onPrimary
                            : _mutedTextColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 20),
            Text('تنسيق التاريخ', style: _fieldLabelStyle()),
            const SizedBox(height: 12),
            Directionality(
              textDirection: TextDirection.rtl,
              child: DropdownMenu<String>(
                initialSelection: _dateFormat,
                onSelected: (value) {
                  if (value == null) return;
                  setState(() => _dateFormat = value);
                },
                leadingIcon: Icon(Icons.calendar_month, color: _accentColor),
                trailingIcon: const Icon(Icons.keyboard_arrow_down),
                textStyle: Theme.of(context).textTheme.bodyLarge,
                enableSearch: false,
                inputDecorationTheme: _dropdownDecoration(
                  accentColor: _accentColor,
                ),
                dropdownMenuEntries: _dateFormats
                    .map(
                      (format) => DropdownMenuEntry<String>(
                        value: format,
                        label: format,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.percent,
          iconColor: _successColor,
          title: 'الخصومات',
          children: [
            SwitchListTile.adaptive(
              value: _allowDiscount,
              onChanged: (value) => setState(() => _allowDiscount = value),
              thumbColor: _thumbColorFor(_successColor),
              trackColor: _trackColorFor(_successColor),
              title: Text(
                'السماح بالخصم على الفواتير',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            AnimatedOpacity(
              opacity: _allowDiscount ? 1 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('نسبة الخصم الافتراضية', style: _fieldLabelStyle()),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: _successColor,
                      inactiveTrackColor: _withOpacity(_successColor, 0.3),
                      thumbColor: _successColor,
                      overlayColor: _withOpacity(_successColor, 0.15),
                    ),
                    child: Slider(
                      value: _defaultDiscountPercent,
                      min: 0,
                      max: 50,
                      divisions: 100,
                      label: '${_defaultDiscountPercent.toStringAsFixed(1)}%',
                      onChanged: _allowDiscount
                          ? (value) =>
                                setState(() => _defaultDiscountPercent = value)
                          : null,
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      '${_defaultDiscountPercent.toStringAsFixed(1)}%',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: _successColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompanyAndInvoicesTab() {
    final examples = [1000, 5000, 10000];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.business,
          iconColor: _accentColor,
          title: 'بيانات الشركة',
          children: [
            TextFormField(
              controller: _companyNameController,
              decoration: _inputDecoration(
                icon: Icons.business_center,
                label: 'اسم الشركة',
                accentColor: _accentColor,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _companyPhoneController,
              keyboardType: TextInputType.phone,
              decoration: _inputDecoration(
                icon: Icons.phone,
                label: 'رقم الهاتف',
                accentColor: _accentColor,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _companyAddressController,
              maxLines: 2,
              decoration: _inputDecoration(
                icon: Icons.location_on,
                label: 'العنوان',
                accentColor: _accentColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.receipt_long_outlined,
          iconColor: _colors.tertiary,
          title: 'إعدادات الضريبة والفواتير',
          children: [
            TextFormField(
              controller: _companyTaxNumberController,
              keyboardType: TextInputType.number,
              inputFormatters: [NormalizeNumberFormatter()],
              decoration: _inputDecoration(
                icon: Icons.badge_outlined,
                label: 'الرقم الضريبي',
                accentColor: _colors.tertiary,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _invoicePrefixController,
              decoration: _inputDecoration(
                icon: Icons.confirmation_number,
                label: 'بادئة رقم الفاتورة',
                accentColor: _colors.tertiary,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _showCompanyLogo,
              onChanged: (value) => setState(() => _showCompanyLogo = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'عرض شعار الشركة على الفواتير',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              value: _allowManualInvoiceItems,
              onChanged: (value) =>
                  setState(() => _allowManualInvoiceItems = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'السماح بإضافة صنف يدوي من شاشة الفاتورة',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'عند التفعيل يظهر زر لإدخال صنف ببيانات مخصصة (اسم، وزن، عيار) أثناء إنشاء فاتورة بيع.',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              value: _requireAuthForInvoiceCreate,
              onChanged: (value) =>
                  setState(() => _requireAuthForInvoiceCreate = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'إلزام تسجيل الدخول لإنشاء الفواتير',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'عند التفعيل: يمنع إنشاء الفاتورة بدون توكن. هذا يضمن تسجيل posted_by وبالتالي ظهور مكافأة الموظف بشكل صحيح.',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              value: _allowPartialInvoicePayments,
              onChanged: (value) =>
                  setState(() => _allowPartialInvoicePayments = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'السماح بالدفع الجزئي (بيع آجل)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: const Text(
                'عند التفعيل: يمكن حفظ فاتورة بيع بمدفوع أقل من الإجمالي أو بدون دفعات بعد تأكيد.\nعند التعطيل: يلزم أن يساوي مجموع الدفعات إجمالي الفاتورة.',
              ),
            ),
            const Divider(height: 32),
            SwitchListTile.adaptive(
              value: _taxEnabled,
              onChanged: (value) => setState(() => _taxEnabled = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'تفعيل احتساب الضريبة',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 16),
            AnimatedOpacity(
              opacity: _taxEnabled ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('نسبة الضريبة (%)', style: _fieldLabelStyle()),
                  const SizedBox(height: 12),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: _colors.tertiary,
                      inactiveTrackColor: _withOpacity(_colors.tertiary, 0.3),
                      thumbColor: _colors.tertiary,
                      overlayColor: _withOpacity(_colors.tertiary, 0.15),
                    ),
                    child: Slider(
                      value: _taxRatePercent,
                      min: 0,
                      max: 30,
                      divisions: 300,
                      label: '${_taxRatePercent.toStringAsFixed(1)}%',
                      onChanged: _taxEnabled
                          ? (value) => setState(() => _taxRatePercent = value)
                          : null,
                    ),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      '${_taxRatePercent.toStringAsFixed(1)}%',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: _colors.tertiary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'إعفاء العيارات من ضريبة الذهب',
                    style: _fieldLabelStyle(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _karatOptions.map((karat) {
                      final selected = _vatExemptKarats.contains(karat);
                      return FilterChip(
                        label: Text('عيار $karat'),
                        selected: selected,
                        onSelected: _taxEnabled
                            ? (value) {
                                setState(() {
                                  if (value) {
                                    _vatExemptKarats.add(karat);
                                  } else {
                                    _vatExemptKarats.remove(karat);
                                  }
                                  if (_vatExemptKarats.isEmpty) {
                                    _vatExemptKarats = {24};
                                  }
                                });
                              }
                            : null,
                        selectedColor: _withOpacity(_colors.tertiary, 0.15),
                        checkmarkColor: _colors.tertiary,
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.calculate_outlined,
          iconColor: _accentColor,
          title: 'أمثلة حسابية للضريبة',
          children: [...examples.map(_buildTaxExampleRow)],
        ),
      ],
    );
  }

  Widget _buildPaymentTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.payments_outlined,
          iconColor: _accentColor,
          title: 'إدارة المدفوعات',
          children: [
            Text(
              'أدر طرق الدفع والخزائن المرتبطة بها لتبسيط عمليات الدفع والتحصيل.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.credit_card),
              label: const Text('إدارة وسائل الدفع'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PaymentMethodsScreenEnhanced(),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.account_balance_wallet),
              label: const Text('إدارة الخزائن'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SafeBoxesScreen(
                      api: _apiService,
                      balancesView: true,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAccountingTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.rule_folder_outlined,
          iconColor: _primaryColor,
          title: 'سير العمل المحاسبي',
          children: [
            SwitchListTile.adaptive(
              value: _voucherAutoPost,
              onChanged: (value) => setState(() => _voucherAutoPost = value),
              title: const Text('ترحيل السندات تلقائياً عند الحفظ'),
              subtitle: const Text(
                'عند التفعيل سيتم إنشاء قيد محاسبي فور حفظ السند. عند الإيقاف ستُحفظ السندات كمسودة وتحتاج للموافقة يدوياً.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.account_balance_wallet_outlined,
          iconColor: _primaryColor,
          title: 'مسار خزائن الموظفين (Feature Toggles)',
          children: [
            Text(
              'يحدد النظام بشكل افتراضي أين تُسجّل حركة النقد/الذهب في فواتير البيع وشراء الكسر: خزائن الموظفين أو الخزائن الرئيسية.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _employeeCashSafesEnabled,
              onChanged: (value) => setState(() => _employeeCashSafesEnabled = value),
              title: const Text('تفعيل خزائن الموظفين للنقد'),
              subtitle: const Text(
                'عند التفعيل: إذا كانت الفاتورة مرتبطة بموظف لديه خزينة نقدية، تُستخدم كمسار افتراضي للنقد.\n'
                'عند الإيقاف: يُستخدم الصندوق الرئيسي/الافتراضي.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            SwitchListTile.adaptive(
              value: _employeeGoldSafesEnabled,
              onChanged: (value) => setState(() => _employeeGoldSafesEnabled = value),
              title: const Text('تفعيل خزائن الموظفين للذهب (الكسر)'),
              subtitle: const Text(
                'عند التفعيل: في شراء الكسر من العميل، تُضاف الأوزان إلى خزينة الذهب الخاصة بالموظف إن كانت مربوطة.\n'
                'عند الإيقاف: تُضاف إلى خزينة الكسر الرئيسية.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            const SizedBox(height: 12),
            if (_isLoadingSafeBoxes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _primaryColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('جار تحميل الخزائن...'),
                  ],
                ),
              ),
            if (!_safeBoxesLoaded && !_isLoadingSafeBoxes)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'لم يتم تحميل قائمة الخزائن. يمكنك فتح شاشة الخزائن أو إعادة المحاولة.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _mutedTextColor,
                      ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _isLoadingSafeBoxes ? null : _reloadSafeBoxes,
                    icon: const Icon(Icons.refresh),
                    label: const Text('تحديث الخزائن'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SafeBoxesScreen(
                            api: _apiService,
                            balancesView: true,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('فتح الخزائن'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildSafeBoxSelector(
              label: 'الصندوق النقدي الرئيسي (Fallback)',
              icon: Icons.money,
              options: _cashSafeBoxes,
              value: _mainCashSafeBoxId,
              onChanged: (v) => setState(() => _mainCashSafeBoxId = v),
              accentColor: _primaryColor,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: (_isSaving || _isLoadingAccounts)
                    ? null
                    : () async {
                        final picked = await _pickAccountSheet(
                          title: 'اختر الحساب المرتبط بالصندوق النقدي الرئيسي',
                          filter: _AccountPickFilter.all,
                        );
                        if (picked == null) return;
                        final id = await _ensureSafeBoxForAccount(
                          account: picked,
                          safeType: 'cash',
                        );
                        if (!mounted) return;
                        if (id != null) {
                          setState(() => _mainCashSafeBoxId = id);
                          await _reloadSafeBoxes();
                          _showSnack('تم ربط/إنشاء صندوق نقدي للحساب المختار');
                        }
                      },
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('اختيار من الحسابات (بدلاً من الخزائن)'),
              ),
            ),
            const SizedBox(height: 12),
            _buildSafeBoxSelector(
              label: 'خزينة ذهب مشغول معروض للبيع (للبيع)',
              icon: Icons.diamond_outlined,
              options: _goldSafeBoxes,
              value: _saleGoldSafeBoxId,
              onChanged: (v) => setState(() => _saleGoldSafeBoxId = v),
              accentColor: _primaryColor,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: (_isSaving || _isLoadingAccounts)
                    ? null
                    : () async {
                        final picked = await _pickAccountSheet(
                          title: 'اختر حساب ذهب مشغول معروض للبيع',
                          filter: _AccountPickFilter.all,
                        );
                        if (picked == null) return;
                        final id = await _ensureSafeBoxForAccount(
                          account: picked,
                          safeType: 'gold',
                        );
                        if (!mounted) return;
                        if (id != null) {
                          setState(() => _saleGoldSafeBoxId = id);
                          await _reloadSafeBoxes();
                          _showSnack('تم ربط/إنشاء خزينة ذهب للحساب المختار');
                        }
                      },
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('اختيار من الحسابات (بدلاً من الخزائن)'),
              ),
            ),
            const SizedBox(height: 12),
            _buildSafeBoxSelector(
              label: 'خزينة الكسر الرئيسية (لشراء الكسر)',
              icon: Icons.diamond,
              options: _goldSafeBoxes,
              value: _mainScrapGoldSafeBoxId,
              onChanged: (v) => setState(() => _mainScrapGoldSafeBoxId = v),
              accentColor: _primaryColor,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: (_isSaving || _isLoadingAccounts)
                    ? null
                    : () async {
                        final picked = await _pickAccountSheet(
                          title: 'اختر حساب صندوق الكسر الرئيسي',
                          filter: _AccountPickFilter.all,
                        );
                        if (picked == null) return;
                        final id = await _ensureSafeBoxForAccount(
                          account: picked,
                          safeType: 'gold',
                        );
                        if (!mounted) return;
                        if (id != null) {
                          setState(() => _mainScrapGoldSafeBoxId = id);
                          await _reloadSafeBoxes();
                          _showSnack('تم ربط/إنشاء خزينة ذهب للحساب المختار');
                        }
                      },
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('اختيار من الحسابات (بدلاً من الخزائن)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.account_tree_outlined,
          iconColor: _accentColor,
          title: 'الربط المحاسبي',
          children: [
            Text(
              'قم بإدارة ربط العمليات المحاسبية بالحسابات بسهولة لضمان دقة القيود.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AccountingMappingScreenEnhanced(),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('فتح شاشة الربط المحاسبي'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ChartOfAccountsScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.account_tree),
              label: const Text('فتح شجرة الحسابات (جميع الحسابات)'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPrintingTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.grid_view_outlined,
          iconColor: _primaryColor,
          title: 'موزع عناصر الفاتورة',
          children: [
            Text(
              'تعديل أماكن عناصر الطباعة (العنوان، جدول الأصناف، الإجماليات...) حسب مقاس الورق.\n'
              'يتم حفظ الإعدادات على نفس الجهاز.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TemplateStudioScreen(isArabic: true),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('فتح موزع عناصر الفاتورة'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.print_outlined,
          iconColor: _primaryColor,
          title: 'إعدادات الطابعة',
          children: [
            SwitchListTile.adaptive(
              value: _printerAutoConnect,
              onChanged: (value) => setState(() => _printerAutoConnect = value),
              title: const Text('الاتصال التلقائي عند فتح التطبيق'),
              subtitle: const Text(
                'يبحث النظام عن الطابعة المفضلة ويحاول الاتصال مباشرة.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            SwitchListTile.adaptive(
              value: _printerShowPreview,
              onChanged: (value) => setState(() => _printerShowPreview = value),
              title: const Text('عرض معاينة قبل الطباعة'),
              subtitle: const Text(
                'يعرض نسخة رقمية قبل تأكيد إرسال أمر الطباعة.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            SwitchListTile.adaptive(
              value: _printerAutoCut,
              onChanged: (value) => setState(() => _printerAutoCut = value),
              title: const Text('تشغيل القطع التلقائي بعد الطباعة'),
              subtitle: const Text(
                'يعمل مع الطابعات الحرارية الداعمة لخاصية القطع.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            const SizedBox(height: 12),
            Text('مقاس الورق الافتراضي', style: _fieldLabelStyle()),
            const SizedBox(height: 10),
            Directionality(
              textDirection: TextDirection.rtl,
              child: DropdownMenu<String>(
                initialSelection: _printerPaperSize,
                onSelected: (value) {
                  if (value == null) return;
                  setState(() => _printerPaperSize = value);
                },
                leadingIcon: Icon(Icons.straighten, color: _primaryColor),
                trailingIcon: const Icon(Icons.keyboard_arrow_down),
                enableSearch: false,
                textStyle: Theme.of(context).textTheme.bodyLarge,
                inputDecorationTheme: _dropdownDecoration(
                  accentColor: _primaryColor,
                ),
                dropdownMenuEntries: _printerPaperOptions
                    .map(
                      (option) => DropdownMenuEntry<String>(
                        value: option,
                        label: option,
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _showPrinterSetupSheet,
              icon: const Icon(Icons.print_rounded),
              label: const Text('إدارة الطابعات المتاحة'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSystemTab() {
    final settingsProvider = Provider.of<SettingsProvider>(context);
    final bool goldAutoEnabled =
        (settingsProvider.settings['gold_price_auto_update_enabled'] == true);
    final int goldAutoIntervalMinutes =
        (settingsProvider.settings['gold_price_auto_update_interval_minutes']
            is num)
        ? (settingsProvider.settings['gold_price_auto_update_interval_minutes']
                  as num)
              .toInt()
        : int.tryParse(
                settingsProvider
                        .settings['gold_price_auto_update_interval_minutes']
                        ?.toString() ??
                    '',
              ) ??
              60;
    final weightConfig = settingsProvider.weightClosingSettings;
    final bool weightEnabled = weightConfig['enabled'] == true;
    final String weightPriceSource =
        (weightConfig['price_source']?.toString() ?? 'live');
    final bool weightAllowOverride = weightConfig['allow_override'] != false;

    return ListView(
      controller: _systemScrollController,
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          sectionKey: _systemSectionKeys[SettingsEntry.goldPrice],
          icon: Icons.monetization_on_outlined,
          iconColor: _accentColor,
          title: 'أسعار الذهب',
          children: [
            Text(
              'تابع آخر تحديثات أسعار الذهب وقم بالمزامنة اليدوية عند الحاجة.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openGoldPriceManager,
              icon: const Icon(Icons.sync_alt),
              label: const Text('تحديث سعر الذهب'),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('إظهار شريط السعر في شاشة تسجيل الدخول'),
              subtitle: const Text(
                'يعرض شريط تحديث سعر الذهب قبل تسجيل الدخول (قد لا يتوفر إذا كان السيرفر يتطلب صلاحيات).',
              ),
              value: settingsProvider.showGoldPriceTickerOnLogin,
              onChanged: (val) async {
                await settingsProvider.setShowGoldPriceTickerOnLogin(val);
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('تم حفظ الإعداد')));
              },
            ),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('تحديث تلقائي'),
              subtitle: const Text('يتم التحديث تلقائياً حسب الفترة المحددة'),
              value: goldAutoEnabled,
              onChanged: (val) async {
                try {
                  await settingsProvider.updateSettings({
                    'gold_price_auto_update_enabled': val,
                    'gold_price_auto_update_mode': 'interval',
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم حفظ الإعداد')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('فشل حفظ الإعداد: $e')),
                    );
                  }
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('فترة التحديث'),
              subtitle: Text('كل $goldAutoIntervalMinutes دقيقة'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final controller = TextEditingController(
                  text: goldAutoIntervalMinutes.toString(),
                );
                final picked = await showDialog<int>(
                  context: context,
                  builder: (ctx) {
                    return AlertDialog(
                      title: const Text('تحديد فترة التحديث'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('أدخل عدد الدقائق بين كل تحديث.'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => controller.text = '1',
                                child: const Text('كل دقيقة'),
                              ),
                              OutlinedButton(
                                onPressed: () => controller.text = '5',
                                child: const Text('كل 5 دقائق'),
                              ),
                              OutlinedButton(
                                onPressed: () => controller.text = '60',
                                child: const Text('كل ساعة'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: controller,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'الدقائق',
                              hintText: 'مثال: 1 أو 5 أو 60',
                            ),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('إلغاء'),
                        ),
                        FilledButton(
                          onPressed: () {
                            final v = int.tryParse(controller.text.trim());
                            Navigator.pop(ctx, v);
                          },
                          child: const Text('حفظ'),
                        ),
                      ],
                    );
                  },
                );
                if (picked == null) return;

                final minutes = picked < 1 ? 1 : picked;
                try {
                  await settingsProvider.updateSettings({
                    'gold_price_auto_update_enabled': true,
                    'gold_price_auto_update_mode': 'interval',
                    'gold_price_auto_update_interval_minutes': minutes,
                  });
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم حفظ الفترة')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('فشل حفظ الفترة: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          sectionKey: _systemSectionKeys[SettingsEntry.weightClosing],
          icon: Icons.scale_outlined,
          iconColor: _successColor,
          title: 'التسكير الوزني الآلي',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildConfigChip(
                  icon: weightEnabled
                      ? Icons.check_circle
                      : Icons.pause_circle_filled,
                  label: weightEnabled ? 'مفعل' : 'متوقف مؤقتاً',
                  color: weightEnabled ? _successColor : _outlineColor,
                ),
                _buildConfigChip(
                  icon: Icons.price_change,
                  label:
                      'المصدر: ${_weightClosingPriceSourceLabel(weightPriceSource)}',
                  color: _accentColor,
                ),
                _buildConfigChip(
                  icon: weightAllowOverride
                      ? Icons.edit_attributes
                      : Icons.lock_outline,
                  label: weightAllowOverride ? 'يسمح بالتعديل' : 'سعر ثابت',
                  color: weightAllowOverride ? _primaryColor : _errorColor,
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openWeightClosingSettings,
              icon: const Icon(Icons.settings_suggest_outlined),
              label: const Text('فتح إعدادات التسكير'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.backup_outlined,
          iconColor: _primaryColor,
          title: 'النسخ الاحتياطي والاستعادة',
          children: [
            Text(
              'قم بتنزيل نسخة احتياطية كملف ZIP، أو استعادة نسخة، أو ضبط النسخ التلقائي على السيرفر.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                final isArabic =
                    Localizations.localeOf(context).languageCode == 'ar';
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BackupRestoreScreen(isArabic: isArabic),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_new),
              label: const Text('فتح شاشة النسخ الاحتياطي'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          sectionKey: _systemSectionKeys[SettingsEntry.systemReset],
          icon: Icons.restore_outlined,
          iconColor: _errorColor,
          title: 'إعادة تهيئة النظام',
          children: [
            Text(
              'استخدم هذه الأداة لمسح البيانات وإعادة ضبط النظام.\n'
              'ملاحظة: قد تكون بعض الخيارات مقفولة تلقائياً على الإنتاج (Production Lock).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(foregroundColor: _errorColor),
              onPressed: _openSystemReset,
              icon: const Icon(Icons.security_update_warning),
              label: const Text('فتح شاشة إعادة التهيئة'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          sectionKey: _systemSectionKeys[SettingsEntry.about],
          icon: Icons.info_outline,
          iconColor: _successColor,
          title: 'حول النظام',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                radius: 26,
                backgroundColor: _blendOnSurface(_successColor, 0.18),
                child: Icon(Icons.diamond, color: _successColor, size: 28),
              ),
              title: Text(
                'نظام مجوهرات خالد',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _strongTextColor,
                ),
              ),
              subtitle: Text(
                'إصدار 2.1 — منصة متكاملة لإدارة محلات الذهب.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _mutedTextColor),
              ),
            ),
            const SizedBox(height: 20),
            _buildSectionCard(
              icon: Icons.lock_outline,
              iconColor: _primaryColor,
              title: 'الأمان',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('تسجيل الخروج عند عدم النشاط'),
                  subtitle: const Text(
                    'عند التعطيل لن يتم إنهاء الجلسة تلقائياً بسبب الخمول',
                  ),
                  value: _idleTimeoutEnabled,
                  onChanged: (val) {
                    setState(() => _idleTimeoutEnabled = val);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('مدة عدم النشاط (بالدقائق)'),
                  subtitle: Text(
                    _idleTimeoutEnabled
                        ? '$_idleTimeoutMinutes دقيقة'
                        : 'الميزة معطلة',
                    style: TextStyle(color: _mutedTextColor),
                  ),
                  trailing: Icon(
                    Icons.edit,
                    color: _idleTimeoutEnabled
                        ? _primaryColor
                        : _mutedTextColor,
                  ),
                  enabled: _idleTimeoutEnabled,
                  onTap: !_idleTimeoutEnabled
                      ? null
                      : () async {
                          final controller = TextEditingController(
                            text: _idleTimeoutMinutes.toString(),
                          );
                          final result = await showDialog<int>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                title: const Text('مدة عدم النشاط'),
                                content: TextField(
                                  controller: controller,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'بالدقائق',
                                    hintText: 'مثال: 30',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    child: const Text('إلغاء'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () {
                                      final value = int.tryParse(
                                        controller.text.trim(),
                                      );
                                      Navigator.of(context).pop(value);
                                    },
                                    child: const Text('حفظ'),
                                  ),
                                ],
                              );
                            },
                          );

                          if (result == null) return;
                          var minutes = result;
                          if (minutes < 1) minutes = 1;
                          if (minutes > 10080) minutes = 10080;
                          setState(() {
                            _idleTimeoutMinutes = minutes;
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _showAboutDialog,
              icon: const Icon(Icons.article_outlined),
              label: const Text('عرض تفاصيل أكثر'),
            ),
          ],
        ),
      ],
    );
  }

  void _scrollToSystemEntry(SettingsEntry entry) {
    final key = _systemSectionKeys[entry];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
  }

  Future<void> _openGoldPriceManager() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GoldPriceManualScreenEnhanced()),
    );
  }

  Future<void> _openSystemReset() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SystemResetScreen()),
    );
  }

  Future<void> _openWeightClosingSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WeightClosingSettingsScreen()),
    );
  }

  Future<void> _showPrinterSetupSheet() async {
    Future<void> loadPrinters(StateSetter setSheetState) async {
      if (kIsWeb) return;
      setSheetState(() {
        _isLoadingPrinters = true;
      });
      try {
        final printers = await Printing.listPrinters();
        setSheetState(() {
          _availablePrinters = printers;
        });
      } catch (_) {
        setSheetState(() {
          _availablePrinters = const [];
        });
      } finally {
        setSheetState(() {
          _isLoadingPrinters = false;
        });
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            // Lazy-load on first open.
            if (!kIsWeb && _availablePrinters.isEmpty && !_isLoadingPrinters) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                loadPrinters(setSheetState);
              });
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: 20 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'إدارة الطابعات',
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                      ),
                      if (!kIsWeb)
                        IconButton(
                          tooltip: 'تحديث القائمة',
                          icon: const Icon(Icons.refresh),
                          onPressed: _isLoadingPrinters
                              ? null
                              : () => loadPrinters(setSheetState),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (kIsWeb)
                    _buildInfoBanner(
                      icon: Icons.info_outline,
                      color: _primaryColor,
                      text:
                          'على نسخة الويب لا يمكن اختيار الطابعة من داخل التطبيق. سيتم استخدام نافذة الطباعة الخاصة بالمتصفح.',
                    )
                  else if (_isLoadingPrinters)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_availablePrinters.isEmpty)
                    _buildInfoBanner(
                      icon: Icons.print_disabled_outlined,
                      color: _primaryColor,
                      text:
                          'لم يتم العثور على طابعات من النظام. تأكد من إضافة الطابعة في إعدادات النظام ثم اضغط تحديث.',
                    )
                  else
                    Flexible(
                      child: RadioGroup<String>(
                        groupValue: _preferredPrinterName,
                        onChanged: (value) async {
                          final next = value?.trim();
                          setState(() {
                            _preferredPrinterName = next;
                          });
                          setSheetState(() {
                            _preferredPrinterName = next;
                          });
                          try {
                            final prefs = await SharedPreferences.getInstance();
                            if (next == null || next.isEmpty) {
                              await prefs.remove(_printerPreferredNameKey);
                            } else {
                              await prefs.setString(
                                _printerPreferredNameKey,
                                next,
                              );
                            }
                          } catch (_) {
                            // ignore
                          }
                        },
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _availablePrinters.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final printer = _availablePrinters[index];
                            final name = printer.name;
                            final selected =
                                (_preferredPrinterName ?? '').trim() ==
                                name.trim();
                            return RadioListTile<String>(
                              value: name,
                              title: Text(name),
                              subtitle: selected
                                  ? const Text('الطابعة المفضلة')
                                  : null,
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            setState(() {
                              _preferredPrinterName = null;
                            });
                            setSheetState(() {
                              _preferredPrinterName = null;
                            });
                            try {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.remove(_printerPreferredNameKey);
                            } catch (_) {
                              // ignore
                            }
                          },
                          icon: const Icon(Icons.clear),
                          label: const Text('مسح التفضيل'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('إغلاق'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حول التطبيق'),
        content: const Text(
          'الإصدار: 2.1\nنظام متكامل لإدارة محلات الذهب والمجوهرات.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Chip(
      avatar: CircleAvatar(
        radius: 14,
        backgroundColor: color,
        child: Icon(icon, size: 16, color: _colors.onPrimary),
      ),
      label: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      backgroundColor: _blendOnSurface(color, 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
  }

  String _weightClosingPriceSourceLabel(String source) {
    switch (source.toLowerCase()) {
      case 'average':
        return 'متوسط التكلفة';
      case 'invoice':
        return 'سعر الفاتورة';
      default:
        return 'السعر المباشر';
    }
  }

  Widget _buildSectionCard({
    Key? sectionKey,
    required IconData icon,
    required Color iconColor,
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      key: sectionKey,
      elevation: 0,
      color: _cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBanner({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _blendOnSurface(color, 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  Widget _buildTaxExampleRow(int amount) {
    final double taxValue = _taxRatePercent / 100 * amount;
    final double total = amount + taxValue;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _blendOnSurface(_colors.secondary, 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${amount.toStringAsFixed(0)} $_currencySymbol',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 16, color: _mutedTextColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'ضريبة: ${taxValue.toStringAsFixed(2)} $_currencySymbol',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _colors.tertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 16, color: _mutedTextColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'الإجمالي: ${total.toStringAsFixed(2)} $_currencySymbol',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _primaryColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _fieldLabelStyle() {
    return Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: _strongTextColor,
        ) ??
        const TextStyle(fontWeight: FontWeight.w700);
  }

  InputDecoration _inputDecoration({
    IconData? icon,
    Color? accentColor,
    String? label,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: icon == null
          ? null
          : Icon(icon, color: accentColor ?? _primaryColor),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: _withOpacity(accentColor ?? _outlineColor, 0.3),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accentColor ?? _primaryColor, width: 2),
      ),
      filled: true,
      fillColor: _blendOnSurface(accentColor ?? _outlineColor, 0.05),
    );
  }

  InputDecorationTheme _dropdownDecoration({Color? accentColor}) {
    final Color color = accentColor ?? _primaryColor;
    return InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: _withOpacity(color, 0.3)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: 2),
      ),
      filled: true,
      fillColor: _blendOnSurface(color, 0.05),
      prefixIconColor: color,
      suffixIconColor: _mutedTextColor,
      helperStyle: TextStyle(color: _mutedTextColor),
    );
  }

  double _normalizePercent(dynamic value, {required double fallbackPercent}) {
    if (value is num) {
      final double doubleValue = value.toDouble();
      if (doubleValue <= 1.0) {
        return doubleValue * 100;
      }
      return doubleValue;
    }
    return fallbackPercent;
  }

  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  bool _safeBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'true';
    return fallback;
  }

  WidgetStateProperty<Color?> _thumbColorFor(Color color) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) return color;
      return null;
    });
  }

  WidgetStateProperty<Color?> _trackColorFor(Color color) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return color.withValues(alpha: 0.5);
      }
      return null;
    });
  }

  Color _withOpacity(Color color, double opacity) =>
      color.withValues(alpha: opacity.clamp(0.0, 1.0));

  Color _blendOnSurface(Color color, double opacity) {
    return Color.alphaBlend(
      color.withValues(alpha: opacity.clamp(0.0, 1.0)),
      _surfaceColor,
    );
  }

  int? _safeNullableInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }

  String _safeBoxLabel(SafeBoxModel sb) {
    final acct = sb.account?.accountNumber;
    final inactiveSuffix = sb.isActive ? '' : ' (غير نشطة)';
    if (acct != null && acct.trim().isNotEmpty) {
      return '${sb.name}$inactiveSuffix • $acct';
    }
    return '${sb.name}$inactiveSuffix';
  }

  bool _containsSafeId(List<SafeBoxModel> list, int? id) {
    if (id == null) return false;
    return list.any((e) => e.id == id);
  }

  Widget _buildSafeBoxSelector({
    required String label,
    required IconData icon,
    required List<SafeBoxModel> options,
    required int? value,
    required ValueChanged<int?> onChanged,
    Color? accentColor,
  }) {
    final items = <DropdownMenuItem<int?>>[
      const DropdownMenuItem<int?>(
        value: null,
        child: Text('— غير محدد —'),
      ),
    ];

    if (value != null && !_containsSafeId(options, value)) {
      items.add(
        DropdownMenuItem<int?>(
          value: value,
          child: Text('معرّف خزينة #$value (غير موجود حالياً)'),
        ),
      );
    }

    for (final sb in options) {
      final id = sb.id;
      if (id == null) continue;
      items.add(
        DropdownMenuItem<int?>(
          value: id,
          child: Text(_safeBoxLabel(sb)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _fieldLabelStyle()),
        const SizedBox(height: 10),
        Directionality(
          textDirection: TextDirection.rtl,
          child: DropdownButtonFormField<int?>(
            value: value,
            items: items,
            onChanged: _isSaving ? null : onChanged,
            isExpanded: true,
            decoration: _inputDecoration(
              icon: icon,
              accentColor: accentColor ?? _primaryColor,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _loadAccountsIfNeeded() async {
    if (_accountsLoaded || _isLoadingAccounts) return;
    setState(() {
      _isLoadingAccounts = true;
    });

    try {
      final raw = await _apiService.getAccounts();
      final parsed = <Map<String, dynamic>>[];
      for (final row in raw) {
        if (row is Map<String, dynamic>) {
          parsed.add(row);
        } else if (row is Map) {
          parsed.add(Map<String, dynamic>.from(row));
        }
      }
      parsed.sort((a, b) {
        final an = (a['account_number'] ?? '').toString();
        final bn = (b['account_number'] ?? '').toString();
        return an.compareTo(bn);
      });
      if (!mounted) return;
      setState(() {
        _allAccounts = parsed;
        _accountsLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      _showSnack('تعذر تحميل الحسابات: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingAccounts = false;
        });
      }
    }
  }

  String _accountLabel(Map<String, dynamic> a) {
    final number = (a['account_number'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    if (number.isEmpty) return name;
    if (name.isEmpty) return number;
    return '$number • $name';
  }

  int? _accountId(Map<String, dynamic> a) {
    final v = a['id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return int.tryParse(s);
  }

  bool _accountTracksWeight(Map<String, dynamic> a) {
    final v = a['tracks_weight'];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  Future<Map<String, dynamic>?> _pickAccountSheet({
    required String title,
    required _AccountPickFilter filter,
  }) async {
    await _loadAccountsIfNeeded();

    final filtered = _allAccounts.where((a) {
      if (!_accountsLoaded) return false;
      final isWeight = _accountTracksWeight(a);
      switch (filter) {
        case _AccountPickFilter.weightOnly:
          return isWeight;
        case _AccountPickFilter.nonWeightOnly:
          return !isWeight;
        case _AccountPickFilter.all:
          return true;
      }
      // Should be unreachable, but keep analyzer happy.
      // ignore: dead_code
      return true;
    }).toList();

    if (!mounted) return null;
    if (filtered.isEmpty) {
      _showSnack('لا توجد حسابات مناسبة للاختيار', isError: true);
      return null;
    }

    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final ctrl = TextEditingController();
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            String q = ctrl.text.trim();
            final visible = filtered.where((a) {
              if (q.isEmpty) return true;
              final label = _accountLabel(a);
              return label.toLowerCase().contains(q.toLowerCase());
            }).toList();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 8,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      'ملاحظة: سيتم إنشاء خزينة تلقائياً للحساب المختار إذا لم تكن موجودة.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _mutedTextColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctrl,
                      onChanged: (_) => setSheetState(() {}),
                      decoration: _inputDecoration(
                        icon: Icons.search,
                        accentColor: _primaryColor,
                        label: 'بحث بالرقم أو الاسم',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 420,
                      child: ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, index) => Divider(
                          height: 1,
                          color: _withOpacity(_outlineColor, 0.25),
                        ),
                        itemBuilder: (_, i) {
                          final a = visible[i];
                          return ListTile(
                            dense: true,
                            title: Text(_accountLabel(a)),
                            onTap: () => Navigator.pop(ctx, a),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<int?> _ensureSafeBoxForAccount({
    required Map<String, dynamic> account,
    required String safeType,
  }) async {
    final accountId = _accountId(account);
    if (accountId == null) return null;

    // Soft warning when choosing a weight-tracking account for a cash safe.
    if (mounted && safeType == 'cash' && _accountTracksWeight(account)) {
      _showSnack('تنبيه: اخترت حساب وزني لصندوق نقدي. تأكد أن هذا مقصود.', isError: true);
    }

    // Try existing first.
    try {
      final existing = await _apiService.getSafeBoxes(
        safeType: safeType,
        includeAccount: true,
      );
      final hit = existing.where((sb) => sb.accountId == accountId).toList();
      if (hit.isNotEmpty && hit.first.id != null) {
        return hit.first.id;
      }
    } catch (_) {
      // ignore and try create
    }

    final name = (account['name'] ?? '').toString().trim();
    final number = (account['account_number'] ?? '').toString().trim();
    final label = name.isNotEmpty ? name : number;

    final safeName = safeType == 'gold'
        ? 'خزينة ذهب $label'
        : 'صندوق $label';

    try {
      final created = await _apiService.createSafeBox(
        SafeBoxModel(
          name: safeName,
          safeType: safeType,
          accountId: accountId,
          isActive: true,
          isDefault: false,
        ),
      );
      return created.id;
    } catch (e) {
      if (mounted) {
        _showSnack('تعذر إنشاء خزينة للحساب: $e', isError: true);
      }
      return null;
    }
  }

  Future<void> _reloadSafeBoxes() async {
    if (_isLoadingSafeBoxes) return;
    setState(() {
      _isLoadingSafeBoxes = true;
    });

    try {
      final results = await Future.wait<List<SafeBoxModel>>([
        _apiService.getSafeBoxes(
          safeType: 'cash',
          includeAccount: true,
        ),
        _apiService.getSafeBoxes(
          safeType: 'gold',
          includeAccount: true,
        ),
      ]);

      final cashSafes = results[0]..sort((a, b) => a.name.compareTo(b.name));
      final goldSafes = results[1]..sort((a, b) => a.name.compareTo(b.name));

      if (!mounted) return;
      setState(() {
        _cashSafeBoxes = cashSafes;
        _goldSafeBoxes = goldSafes;
        _safeBoxesLoaded = cashSafes.isNotEmpty || goldSafes.isNotEmpty;
      });
    } catch (e) {
      if (!mounted) return;
      _showSnack('تعذر تحديث الخزائن: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingSafeBoxes = false;
        });
      }
    }
  }
}
