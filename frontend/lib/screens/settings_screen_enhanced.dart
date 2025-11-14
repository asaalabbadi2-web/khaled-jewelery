import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import 'accounting_mapping_screen_enhanced.dart';
import 'customize_quick_actions_screen.dart';
import 'payment_methods_screen_enhanced.dart';
import 'safe_boxes_screen.dart';
import 'gold_price_manual_screen_enhanced.dart';
import 'system_reset_screen.dart';

enum SettingsEntry { goldPrice, systemReset, printerSettings, about }

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

  bool _showCompanyLogo = true;
  bool _allowDiscount = true;
  double _defaultDiscountPercent = 0.0;

  // whether vouchers are auto-posted when saved
  bool _voucherAutoPost = false;

  bool _printerAutoConnect = true;
  bool _printerShowPreview = false;
  bool _printerAutoCut = true;
  String _printerPaperSize = '80 مم';
  final List<String> _printerPaperOptions = const ['58 مم', '80 مم', 'A4'];

  List<Map<String, dynamic>> _paymentMethods = const [];

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
      final results = await Future.wait([
        _apiService.getSettings(),
        _apiService.getPaymentMethods(),
      ]);

      if (!mounted) return;
      final settings = Map<String, dynamic>.from(results[0] as Map);
      final paymentMethodsRaw = results[1] as List<dynamic>;

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

        _showCompanyLogo = _safeBool(
          settings['show_company_logo'],
          fallback: true,
        );
        _allowDiscount = _safeBool(settings['allow_discount'], fallback: true);
        _defaultDiscountPercent = _normalizePercent(
          settings['default_discount_rate'],
          fallbackPercent: 0,
        );

        // workflow setting: whether vouchers are auto-posted on save
        _voucherAutoPost = _safeBool(
          settings['voucher_auto_post'],
          fallback: false,
        );

        _paymentMethods =
            paymentMethodsRaw
                .map((method) => Map<String, dynamic>.from(method as Map))
                .toList()
              ..sort(
                (a, b) => _safeInt(
                  a['display_order'],
                ).compareTo(_safeInt(b['display_order'])),
              );
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

  Future<void> _refreshPaymentMethods() async {
    try {
      final methods = await _apiService.getPaymentMethods();
      if (!mounted) return;
      setState(() {
        _paymentMethods =
            methods
                .map((method) => Map<String, dynamic>.from(method as Map))
                .toList()
              ..sort(
                (a, b) => _safeInt(
                  a['display_order'],
                ).compareTo(_safeInt(b['display_order'])),
              );
      });
    } catch (error) {
      if (!mounted) return;
      _showSnack('تعذر تحديث وسائل الدفع: $error', isError: true);
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
      'allow_discount': _allowDiscount,
      'default_discount_rate': _defaultDiscountPercent / 100,
      'invoice_prefix': _invoicePrefixController.text.trim(),
      'show_company_logo': _showCompanyLogo,
      'company_name': _companyNameController.text.trim(),
      'company_address': _companyAddressController.text.trim(),
      'company_phone': _companyPhoneController.text.trim(),
      'company_tax_number': _companyTaxNumberController.text.trim(),
      // include voucher workflow setting
      'voucher_auto_post': _voucherAutoPost,
    };

    try {
      // Update via Provider to apply changes globally
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      await settingsProvider.updateSettings(payload);

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

  Future<void> _togglePaymentMethodStatus(
    Map<String, dynamic> method,
    bool isActive,
  ) async {
    final int methodId = _safeInt(method['id']);
    if (methodId == 0) {
      _showSnack('لا يمكن تحديث هذه الوسيلة الآن', isError: true);
      return;
    }

    setState(() {
      method['is_active'] = isActive;
    });

    try {
      await _apiService.updatePaymentMethod(
        methodId,
        paymentType: method['payment_type']?.toString() ?? 'cash',
        name: method['name']?.toString() ?? 'وسيلة دفع',
        commissionRate: _safeDouble(method['commission_rate']),
        isActive: isActive,
      );
      if (!mounted) return;
      _showSnack(
        isActive ? 'تم تفعيل وسيلة الدفع' : 'تم إلغاء تفعيل وسيلة الدفع',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        method['is_active'] = !isActive;
      });
      _showSnack('تعذر تحديث الحالة: $error', isError: true);
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
            Tab(icon: Icon(Icons.payments), text: 'المدفوعات'),
            Tab(icon: Icon(Icons.receipt_long), text: 'الضريبة'),
            Tab(icon: Icon(Icons.business), text: 'الشركة'),
            Tab(icon: Icon(Icons.account_tree), text: 'محاسبة'),
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
                _buildPaymentTab(),
                _buildTaxTab(),
                _buildCompanyTab(),
                _buildAccountingTab(),
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
            const SizedBox(height: 16),
            _buildKaratHint(),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.currency_exchange,
          iconColor: _accentColor,
          title: 'العملة والدقة',
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
            const SizedBox(height: 12),
            _buildInfoBanner(
              icon: Icons.info_outline,
              color: _accentColor,
              text:
                  'يؤثر هذا الخيار على طريقة عرض التاريخ في التقارير والفواتير.',
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.percent,
          iconColor: _successColor,
          title: 'الخصومات الافتراضية',
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
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.dashboard_customize,
          iconColor: _primaryColor,
          title: 'الشاشة الرئيسية',
          children: [
            Text('الوصول السريع', style: _fieldLabelStyle()),
            const SizedBox(height: 12),
            _buildNavigationTile(
              title: 'تخصيص أزرار الوصول السريع',
              subtitle:
                  'إضافة، حذف أو إعادة ترتيب الاختصارات في الشاشة الرئيسية',
              icon: Icons.flash_on,
              accentColor: _primaryColor,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CustomizeQuickActionsScreen(),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 32),
        _buildTipsCard(
          title: 'نصائح سريعة',
          tips: const [
            'يمكنك تغيير الإعدادات في أي وقت دون التأثير على الفواتير السابقة.',
            'العيار الأساسي هو المرجع لجميع حسابات الوزن.',
            'استخدم رمز عملة قصيراً ليسهل قراءته داخل الفاتورة.',
            'جرّب إعدادات مختلفة للمنازل العشرية لمعرفة الأنسب لعملك.',
          ],
        ),
      ],
    );
  }

  Widget _buildPaymentTab() {
    final activeCount = _paymentMethods
        .where((m) => m['is_active'] == true)
        .length;
    final inactiveCount = _paymentMethods.length - activeCount;

    return RefreshIndicator(
      color: _primaryColor,
      onRefresh: _refreshPaymentMethods,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSectionCard(
            icon: Icons.payments_outlined,
            iconColor: _accentColor,
            title: 'ملخص طرق الدفع',
            children: [
              Row(
                children: [
                  _buildPaymentBadge(
                    label: 'نشط',
                    count: activeCount,
                    color: _successColor,
                  ),
                  const SizedBox(width: 12),
                  _buildPaymentBadge(
                    label: 'معطّل',
                    count: inactiveCount,
                    color: _colors.secondaryContainer,
                    textColor: _colors.onSecondaryContainer,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _refreshPaymentMethods,
                    icon: Icon(Icons.refresh, color: _accentColor),
                    tooltip: 'تحديث',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.manage_accounts),
                label: const Text('إدارة وسائل الدفع'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PaymentMethodsScreenEnhanced(),
                    ),
                  ).then((_) => _refreshPaymentMethods());
                },
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.account_balance_wallet),
                label: const Text('إدارة الخزائن'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.amber.shade700,
                ),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SafeBoxesScreen(api: _apiService),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_paymentMethods.isEmpty)
            _buildEmptyState(
              icon: Icons.credit_card_off,
              title: 'لا توجد طرق دفع مسجلة',
              message:
                  'استخدم زر إدارة وسائل الدفع لإضافة أو تحديث الطرق المتاحة.',
            )
          else
            ..._paymentMethods.map(_buildPaymentMethodCard),
        ],
      ),
    );
  }

  Widget _buildTaxTab() {
    final examples = [1000, 5000, 10000];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildSectionCard(
          icon: Icons.receipt_long_outlined,
          iconColor: _colors.tertiary,
          title: 'إعدادات الضريبة',
          children: [
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
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: _blendOnSurface(_colors.tertiary, 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _withOpacity(_colors.tertiary, 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _taxRatePercent.toStringAsFixed(1),
                              style: Theme.of(context).textTheme.displaySmall
                                  ?.copyWith(
                                    color: _colors.tertiary,
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '%',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    color: _withOpacity(_colors.tertiary, 0.8),
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: _colors.tertiary,
                            inactiveTrackColor: _withOpacity(
                              _colors.tertiary,
                              0.3,
                            ),
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
                                ? (value) =>
                                      setState(() => _taxRatePercent = value)
                                : null,
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '0%',
                              style: TextStyle(color: _mutedTextColor),
                            ),
                            Text(
                              '30%',
                              style: TextStyle(color: _mutedTextColor),
                            ),
                          ],
                        ),
                      ],
                    ),
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
          title: 'أمثلة حسابية',
          children: [...examples.map(_buildTaxExampleRow)],
        ),
      ],
    );
  }

  Widget _buildCompanyTab() {
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
            const SizedBox(height: 16),
            TextFormField(
              controller: _companyTaxNumberController,
              keyboardType: TextInputType.number,
              decoration: _inputDecoration(
                icon: Icons.badge_outlined,
                label: 'الرقم الضريبي',
                accentColor: _colors.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.receipt_outlined,
          iconColor: _primaryColor,
          title: 'إعدادات الفاتورة',
          children: [
            TextFormField(
              controller: _invoicePrefixController,
              decoration: _inputDecoration(
                icon: Icons.confirmation_number,
                label: 'بادئة رقم الفاتورة',
                accentColor: _primaryColor,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _showCompanyLogo,
              onChanged: (value) => setState(() => _showCompanyLogo = value),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
              title: Text(
                'عرض شعار الشركة على الفواتير',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoBanner(
              icon: Icons.lightbulb_outline,
              color: _primaryColor,
              text:
                  'تأكد من تحديث رقم الهاتف والعنوان ليظهر بشكل صحيح في رأس الفاتورة.',
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
            OutlinedButton.icon(
              onPressed: () {
                _tabController.animateTo(1);
              },
              icon: const Icon(Icons.payments_rounded),
              label: const Text('مراجعة طرق الدفع'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildTipsCard(
          title: 'تلميحات محاسبية',
          tips: const [
            'قم بمراجعة الخرائط المحاسبية بعد أي تعديل على الحسابات الأساسية.',
            'تأكد من ربط طرق الدفع بحساباتها الصحيحة لضمان تطابق التقارير.',
            'استخدم شاشة الربط المحاسبي لمراجعة الأرصدة قبل إقفال الفترة.',
          ],
        ),
      ],
    );
  }

  Widget _buildSystemTab() {
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
            _buildInfoBanner(
              icon: Icons.info_outline,
              color: _accentColor,
              text:
                  'يمكنك تفعيل التحديث الآلي من شاشة ربط الحسابات لضمان دقة القيود.',
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
              'استخدم هذه الأداة لمسح البيانات وإعادة ضبط النظام مع أخذ نسخة احتياطية.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(foregroundColor: _errorColor),
              onPressed: _openSystemReset,
              icon: const Icon(Icons.security_update_warning),
              label: const Text('فتح شاشة إعادة التهيئة'),
            ),
            const SizedBox(height: 12),
            _buildInfoBanner(
              icon: Icons.warning_amber_outlined,
              color: _errorColor,
              text:
                  'ننصح بإنشاء نسخة احتياطية قبل المتابعة لتجنب فقدان البيانات المهمة.',
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          sectionKey: _systemSectionKeys[SettingsEntry.printerSettings],
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
            // Voucher workflow toggle
            SwitchListTile.adaptive(
              value: _voucherAutoPost,
              onChanged: (value) => setState(() => _voucherAutoPost = value),
              title: const Text('ترحيل السندات تلقائياً عند الحفظ'),
              subtitle: const Text(
                'عند التفعيل سيتم إنشاء قيد محاسبي فور حفظ السند. عند الإيقاف ستُحفظ السندات كقيد مبدئي (معلق) وتحتاج للموافقة يدوياً.',
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
                'نظام الياسر للذهب والمجوهرات',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _strongTextColor,
                ),
              ),
              subtitle: Text(
                'إصدار 2.0 — منصة متكاملة لإدارة محلات الذهب.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _mutedTextColor),
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoBanner(
              icon: Icons.lightbulb_outline,
              color: _successColor,
              text:
                  'تم تصميم الواجهة لتكون ثنائية اللغة وتدعم الأعمال القائمة على وزن الذهب.',
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
    if (key == null) {
      return;
    }
    final context = key.currentContext;
    if (context == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToSystemEntry(entry),
      );
      return;
    }

    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      alignment: 0.08,
    );
    _pendingFocusEntry = null;
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

  Future<void> _showPrinterSetupSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.print, color: _primaryColor),
                  const SizedBox(width: 12),
                  Text(
                    'إدارة الطابعات',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildInfoBanner(
                icon: Icons.info_outline,
                color: _primaryColor,
                text:
                    'سيتم توفير دعم الطابعات الحرارية والبلوتوث في التحديثات القادمة.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _showSnack('ميزة إدارة الطابعات ستتوفر قريباً');
                },
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('البحث عن طابعة عبر البلوتوث'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.diamond, color: _accentColor),
              const SizedBox(width: 12),
              const Text('حول التطبيق'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('الإصدار: 2.0'),
              SizedBox(height: 8),
              Text('نظام متكامل لإدارة محلات الذهب والمجوهرات.'),
              SizedBox(height: 8),
              Text('© 2025 جميع الحقوق محفوظة لدى الياسر للذهب.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('حسناً'),
            ),
          ],
        );
      },
    );
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
      elevation: 1,
      color: _cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _blendOnSurface(iconColor, 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: iconColor, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _strongTextColor,
                    ),
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

  Widget _buildKaratHint() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _blendOnSurface(_primaryColor, 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _withOpacity(_primaryColor, 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _karatOptions.map((karat) {
          final selected = karat == _mainKarat;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: selected
                        ? _primaryColor
                        : _withOpacity(_primaryColor, 0.6),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'عيار $karat',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    color: selected ? _primaryColor : _mutedTextColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${(karat / 24 * 100).toStringAsFixed(1)}% نقاء)',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _mutedTextColor),
                ),
                if (selected) ...[
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _successColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'محدد',
                      style: TextStyle(
                        color: _colors.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
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
        color: _blendOnSurface(color, 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _withOpacity(color, 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _mutedTextColor,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _blendOnSurface(accentColor, 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _withOpacity(accentColor, 0.25)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _withOpacity(accentColor, 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: accentColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _mutedTextColor),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_back_ios_new, color: accentColor, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildTipsCard({required String title, required List<String> tips}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _blendOnSurface(_accentColor, 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _withOpacity(_accentColor, 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tips_and_updates, color: _accentColor),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _accentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...tips.map(
            (tip) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ', style: TextStyle(color: _accentColor)),
                  Expanded(
                    child: Text(
                      tip,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: _mutedTextColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentBadge({
    required String label,
    required int count,
    required Color color,
    Color? textColor,
  }) {
    final effectiveTextColor = textColor ?? _colors.onPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _blendOnSurface(color, 0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _withOpacity(color, 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: effectiveTextColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: effectiveTextColor),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentMethodCard(Map<String, dynamic> method) {
    final bool isActive = method['is_active'] == true;
    final Color baseColor = isActive ? _successColor : _outlineColor;
    final Color background = _blendOnSurface(baseColor, isActive ? 0.18 : 0.08);
    final double commission = _safeDouble(method['commission_rate']);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _withOpacity(baseColor, isActive ? 0.35 : 0.2),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _withOpacity(baseColor, 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.credit_card, color: baseColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  method['name']?.toString() ?? 'وسيلة دفع',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _strongTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  method['payment_type']?.toString() ?? '-',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _mutedTextColor),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.percent, size: 16, color: baseColor),
                    const SizedBox(width: 6),
                    Text(
                      'عمولة ${commission.toStringAsFixed(2)}%',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: baseColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: isActive,
            onChanged: (value) => _togglePaymentMethodStatus(method, value),
            thumbColor: _thumbColorFor(_successColor),
            trackColor: _trackColorFor(_successColor),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: _blendOnSurface(_outlineColor, 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _withOpacity(_outlineColor, 0.2)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 64, color: _outlineColor),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: _strongTextColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _mutedTextColor),
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
        TextStyle(fontWeight: FontWeight.w700, color: _strongTextColor);
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

  double _safeDouble(dynamic value, {double fallback = 0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
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
      if (states.contains(WidgetState.disabled)) {
        return _withOpacity(color, 0.4);
      }
      if (states.contains(WidgetState.selected)) {
        return color;
      }
      return null;
    });
  }

  WidgetStateProperty<Color?> _trackColorFor(Color color) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return _withOpacity(color, 0.12);
      }
      if (states.contains(WidgetState.selected)) {
        return _withOpacity(color, 0.45);
      }
      return null;
    });
  }

  Color _withOpacity(Color color, double opacity) {
    final double clamped = opacity.clamp(0.0, 1.0);
    return color.withAlpha((clamped * 255).round());
  }

  Color _blendOnSurface(Color color, double opacity) {
    return Color.alphaBlend(_withOpacity(color, opacity), _surfaceColor);
  }
}
