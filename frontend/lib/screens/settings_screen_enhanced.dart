import '../utils/paper_format.dart';
import 'settings_center_screen.dart';
import '../widgets/invoice_settings_sheet.dart' show InvoiceUiContext, InvoiceUiSettings;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printing/printing.dart';

import '../api_service.dart';
import '../providers/sales_race_refresh_provider.dart';
import '../providers/settings_provider.dart';
import 'accounting_mapping_screen_enhanced.dart';
import 'payment_methods_screen_enhanced.dart';
import 'safe_boxes_screen.dart';
import 'accounts_screen.dart';
import 'gold_price_manual_screen_enhanced.dart';
import 'backup_restore_screen.dart';
import 'system_reset_screen.dart';
import 'supplier_settlement_policy_screen.dart';
import 'weight_closing_settings_screen.dart';
import '../widgets/app_bar_tab_bar.dart';
import '../widgets/app_feedback.dart';

enum SettingsEntry {
  goldPrice,
  weightClosing,
  systemReset,
  about,
}

class SettingsScreenEnhanced extends StatefulWidget {
  static const int printingTabIndex = 4;
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
    SettingsEntry.about: GlobalKey(),
  };

  SettingsEntry? _pendingFocusEntry;

  int get _systemTabIndex => SettingsScreenEnhanced.systemTabIndex;



  bool _isInitialized = false;
  bool _isLoading = true;
  bool _isSaving = false;

  // The settings' main karat from the start -- never a fixed one.




  bool _idleTimeoutEnabled = true;
  int _idleTimeoutMinutes = 30;


  /// VAT on sales, apart from purchases (SALES-VAT-1).

  /// Coding the stock on hand opened on its own day (the owner, 19 Nov 2026):
  /// the server keeps the day it was turned on.
  bool _codingOn = false;
  String? _codingFrom;

  /// How a purchase and a sale treat manufacturing wages (ADR-039).

  bool _voucherAutoPost = false;
  // هامش فرق سداد الذهب (2 أكتوبر 2026): رقم ثابت بالغرام، زاد الوزن أو نقص.
  // سعر الشراء = سعر السوق × النسبة (PRICE-BUY-1)؛ تُعرض بالمئة.
  // The closing office's terms (OFFICE-PRICE-1): what the server prices gold by.
  // حدّ اعتماد المحاسب (ADR-036 R4): يعتمد سندات غيره ما دونه؛ 0 = لا شيء.

  // ---------------------------------------------------------------------------
  // 🆕 Feature toggles + default safes (employee routing)
  // ---------------------------------------------------------------------------



  bool _printerAutoConnect = true;
  bool _printerShowPreview = false;
  bool _printerAutoCut = true;
  String _printerPaperSize = '80 مم';
  final List<String> _printerPaperOptions = const ['58 مم', '80 مم', 'A4'];

  bool _printInColor = true;
  String _invoicePaperSize = 'A4';
  // The invoice paper is the invoice screens' own (its sheet, on this device): B2.
  final List<String> _invoicePaperOptions = InvoiceUiSettings.supportedPaperSizes;

  static const String _printerAutoConnectKey = 'printer_auto_connect_v1';
  static const String _printerShowPreviewKey = 'printer_show_preview_v1';
  static const String _printerAutoCutKey = 'printer_auto_cut_v1';
  static const String _printerPaperSizeKey = 'printer_paper_size_v1';
  static const String _printerPreferredNameKey = 'printer_preferred_name_v1';
  static const String _printInColorKey = 'print_in_color';

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

  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = await _apiService.getSettings();

      if (!mounted) return;

      final printerAutoConnect = prefs.getBool(_printerAutoConnectKey) ?? true;
      final printerShowPreview = prefs.getBool(_printerShowPreviewKey) ?? false;
      final printerAutoCut = prefs.getBool(_printerAutoCutKey) ?? true;
      final printerPaperSize = prefs.getString(_printerPaperSizeKey) ?? '80 مم';
      final preferredPrinterName = prefs.getString(_printerPreferredNameKey);
      final printInColor = prefs.getBool(_printInColorKey) ?? true;
      final invoicePaperSize = (await InvoiceUiSettings.load(InvoiceUiContext.saleNew)).paperSize;


      setState(() {
        _isInitialized = true;




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

        _codingFrom = settings['coding_from']?.toString();
        _codingOn = _codingFrom != null;

        _voucherAutoPost = _safeBool(
          settings['voucher_auto_post'],
          fallback: false,
        );

        // 🆕 Feature toggles + default safes


        _printerAutoConnect = printerAutoConnect;
        _printerShowPreview = printerShowPreview;
        _printerAutoCut = printerAutoCut;
        _printerPaperSize = _printerPaperOptions.contains(printerPaperSize)
            ? printerPaperSize
            : '80 مم';
        _preferredPrinterName = preferredPrinterName;
        _printInColor = printInColor;
        _invoicePaperSize = _invoicePaperOptions.contains(invoicePaperSize)
            ? invoicePaperSize
            : 'A4';
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
      'voucher_auto_post': _voucherAutoPost,
      'idle_timeout_enabled': _idleTimeoutEnabled,
      'idle_timeout_minutes': _idleTimeoutMinutes,
      'coding_on': _codingOn,

      // 🆕 Feature toggles + default safes (employee routing)
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
        await prefs.setBool(_printInColorKey, _printInColor);
        await InvoiceUiSettings.setPaperSize(_invoicePaperSize);
      } catch (_) {
        // ignore local persistence failures
      }

      if (!mounted) return;
      // Notify the home screen to re-fetch the leaderboard with the latest
      // settings config. This is the reliable trigger path (watched in build()).
      try {
        Provider.of<SalesRaceRefreshProvider>(
          context,
          listen: false,
        ).notifySettingsChanged();
      } catch (_) {}
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
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إعدادات النظام'),
        bottom: AppBarTabBar(
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
        _buildMovedNote('العيار الرئيسي في «الذهب والأسعار»، والعملة والمنازل العشرية وتنسيق التاريخ في «المنشأة»، '
            'والخصم في «البيع والفواتير»'),
      ],
    );
  }

  /// Where settings moved out of this tab now live (settings spec v2, phase 7):
  /// the center edits them; this tab no longer holds or sends them.
  Widget _buildMovedNote(String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const Key('settings-moved-note'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(Icons.open_in_new, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(child: Text('انتقلت إلى مركز الإعدادات: $text.')),
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsCenterScreen()),
          ),
          child: const Text('افتح المركز'),
        ),
      ]),
    );
  }

  Widget _buildCompanyAndInvoicesTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildMovedNote('بيانات الشركة والترقيم في «المنشأة»، والصنف اليدوي والدفع الجزئي وإلزام الدخول في «البيع والفواتير»، '
            'وضريبة المبيعات ونسبة الضريبة والعيارات المعفاة في «الضريبة»'),
        const SizedBox(height: 16),
        _buildSectionCard(
          icon: Icons.receipt_long_outlined,
          iconColor: _colors.tertiary,
          title: 'الترميز',
          children: [
            SwitchListTile.adaptive(
              key: const Key('settings-coding-on'),
              value: _codingOn,
              onChanged: (value) => setState(() => _codingOn = value),
              thumbColor: _thumbColorFor(_colors.tertiary),
              trackColor: _trackColorFor(_colors.tertiary),
              title: Text(
                'ترميز المخزون الموجود قطعًا',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              subtitle: Text(
                _codingOn && _codingFrom != null
                    ? 'مفتوح منذ $_codingFrom: «ترميز من المخزون الموجود» في محطة ترميز القطع، تصنيفًا تصنيفًا قبل جرد 31 ديسمبر. '
                        'الاستلام من المورد يبقى كما هو.'
                    : 'عند التفعيل يُفتح «ترميز من المخزون الموجود» في محطة ترميز القطع من اليوم، لتُرمَّز قطع المخزون قبل جرد 31 ديسمبر. '
                        'الاستلام من المورد يبقى كما هو.',
              ),
            ),
          ],
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
                    builder: (_) =>
                        SafeBoxesScreen(api: _apiService),
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
                'عند التفعيل سيتم إنشاء قيد محاسبي فور حفظ السند. عند الإيقاف ستُحفظ السندات غير مُرحّلة وتحتاج للترحيل/الموافقة يدوياً.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildMovedNote('هامش فرق سداد الذهب وحدّا اعتماد المحاسب ومعالجة أجور المصنعية في «المحاسبة والاعتماد»، '
            'وسعر الشراء وشروط سعر مكتب التسكير في «الذهب والأسعار»'),
        const SizedBox(height: 20),
        _buildMovedNote('خزائن الموظفين والصندوق النقدي الرئيسي وخزينتا الذهب المعروض والكسر في «المدفوعات والخزائن»'),
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
                    builder: (_) => const AccountsScreen(openOnTree: true),
                  ),
                );
              },
              icon: const Icon(Icons.account_tree),
              label: const Text('فتح دليل الحسابات'),
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
          icon: Icons.palette_outlined,
          iconColor: _primaryColor,
          title: 'نمط الطباعة',
          children: [
            SwitchListTile.adaptive(
              value: _printInColor,
              onChanged: (value) => setState(() => _printInColor = value),
              title: const Text('طباعة ملونة'),
              subtitle: const Text(
                'استخدم الألوان الكاملة (ذهبي وتدرجات). أوقفه للطباعة بالأسود فقط على الطابعات العادية.',
              ),
              thumbColor: _thumbColorFor(_primaryColor),
              trackColor: _trackColorFor(_primaryColor),
            ),
            const SizedBox(height: 12),
            Text('حجم ورق الفواتير', style: _fieldLabelStyle()),
            const SizedBox(height: 10),
            Directionality(
              textDirection: TextDirection.rtl,
              child: DropdownMenu<String>(
                initialSelection: _invoicePaperSize,
                onSelected: (value) {
                  if (value == null) return;
                  setState(() => _invoicePaperSize = value);
                },
                leadingIcon: Icon(Icons.straighten, color: _primaryColor),
                trailingIcon: const Icon(Icons.keyboard_arrow_down),
                enableSearch: false,
                textStyle: Theme.of(context).textTheme.bodyLarge,
                inputDecorationTheme: _dropdownDecoration(
                  accentColor: _primaryColor,
                ),
                dropdownMenuEntries: _invoicePaperOptions
                    .map(
                      (option) => DropdownMenuEntry<String>(
                        value: option,
                        label: paperLabel(option),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
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
            Text('مقاس ورق السندات', style: _fieldLabelStyle()),
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
                        label: paperLabel(option),
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
            const SizedBox(height: 12),
            _buildMovedNote('التحديث التلقائي وفترته في «الذهب والأسعار»'),
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
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _openWeightClosingSettings,
                  icon: const Icon(Icons.settings_suggest_outlined),
                  label: const Text('فتح إعدادات التسكير'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildSectionCard(
          icon: Icons.rule,
          iconColor: _accentColor,
          title: 'حدود تسوية فروقات الموردين',
          children: [
            Text(
              'ثلاثة حدود تحكم كل تسوية: حدّ العملية الواحدة، وحدّ المراجعة، '
              'والسقف الشهري لكل مورد — نقدًا ووزنًا بمكافئ العيار الرئيسي. '
              'ولكل سبب حدوده الخاصة، فلا يُقاس تنازل موثّق بحدّ التقريب.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openSupplierSettlementPolicy,
              icon: const Icon(Icons.tune),
              label: const Text('فتح حدود التسوية'),
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

  Future<void> _openSupplierSettlementPolicy() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SupplierSettlementPolicyScreen(api: _apiService),
      ),
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


  TextStyle _fieldLabelStyle() {
    return Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: _strongTextColor,
        ) ??
        const TextStyle(fontWeight: FontWeight.w700);
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

}
