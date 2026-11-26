import 'settings_center_screen.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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






  /// VAT on sales, apart from purchases (SALES-VAT-1).

  /// Coding the stock on hand opened on its own day (the owner, 19 Nov 2026):
  /// the server keeps the day it was turned on.

  /// How a purchase and a sale treat manufacturing wages (ADR-039).

  bool _voucherAutoPost = false;
  // هامش فرق سداد الذهب (2 أكتوبر 2026): رقم ثابت بالغرام، زاد الوزن أو نقص.
  // سعر الشراء = سعر السوق × النسبة (PRICE-BUY-1)؛ تُعرض بالمئة.
  // The closing office's terms (OFFICE-PRICE-1): what the server prices gold by.
  // حدّ اعتماد المحاسب (ADR-036 R4): يعتمد سندات غيره ما دونه؛ 0 = لا شيء.

  // ---------------------------------------------------------------------------
  // 🆕 Feature toggles + default safes (employee routing)
  // ---------------------------------------------------------------------------




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
      final settings = await _apiService.getSettings();

      if (!mounted) return;



      setState(() {
        _isInitialized = true;






        _voucherAutoPost = _safeBool(
          settings['voucher_auto_post'],
          fallback: false,
        );

        // 🆕 Feature toggles + default safes


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

      // 🆕 Feature toggles + default safes (employee routing)
    };

    try {
      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      await settingsProvider.updateSettings(payload);


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
            'وضريبة المبيعات ونسبة الضريبة والعيارات المعفاة في «الضريبة»، وترميز المخزون الموجود في «الأصناف والقطع»'),
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
        _buildMovedNote('الطباعة الملونة ومقاسا ورق الفواتير والسندات في «هذا الجهاز»'),
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
            const SizedBox(height: 12),
            _buildMovedNote('التحديث التلقائي وفترته في «الذهب والأسعار»، وشريط السعر في شاشة الدخول في «هذا الجهاز»'),
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
            _buildMovedNote('تسجيل الخروج عند عدم النشاط ومدته في «المستخدمون والأمان»'),
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
