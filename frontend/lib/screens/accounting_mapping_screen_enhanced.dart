import 'package:flutter/material.dart';
import '../api_service.dart';

class AccountingMappingScreenEnhanced extends StatefulWidget {
  const AccountingMappingScreenEnhanced({super.key});

  @override
  State<AccountingMappingScreenEnhanced> createState() =>
      _AccountingMappingScreenEnhancedState();
}

class _AccountingMappingScreenEnhancedState
    extends State<AccountingMappingScreenEnhanced>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();

  late final TabController _tabController;

  final List<_OperationConfig> _operationConfigs = const [
    _OperationConfig(
      key: 'سندات',
      label: 'سندات',
      description: 'سندات القبض والصرف (ربط حسابات العملاء والموردين التجميعية)',
      icon: Icons.receipt_long,
      tone: _Tone.info,
    ),
    _OperationConfig(
      key: 'بيع',
      label: 'بيع',
      description: 'عمليات بيع المجوهرات مباشرة للعملاء',
      icon: Icons.shopping_cart,
      tone: _Tone.success,
    ),
    _OperationConfig(
      key: 'شراء من عميل',
      label: 'شراء من عميل',
      description: 'استلام ذهب من عميل مقابل دفع نقدي أو وزن',
      icon: Icons.person_add_alt_1,
      tone: _Tone.primary,
    ),
    _OperationConfig(
      key: 'مرتجع بيع',
      label: 'مرتجع بيع',
      description: 'إرجاع مبيعات سابقة وما يتبعها من قيود',
      icon: Icons.assignment_return,
      tone: _Tone.warning,
    ),
    _OperationConfig(
      key: 'مرتجع شراء',
      label: 'مرتجع شراء',
      description: 'إرجاع مشتريات سابقة من العملاء أو الموردين',
      icon: Icons.undo,
      tone: _Tone.info,
    ),
    _OperationConfig(
      key: 'شراء',
      label: 'شراء',
      description: 'توريد ذهب من موردين مع قيد التكلفة',
      icon: Icons.business_center,
      tone: _Tone.secondary,
    ),
    _OperationConfig(
      key: 'مرتجع شراء (مورد)',
      label: 'مرتجع شراء (مورد)',
      description: 'إرجاع ذهب تم شراؤه من موردين',
      icon: Icons.keyboard_return,
      tone: _Tone.danger,
    ),
  ];

  final Map<String, _AccountTypeConfig> _accountTypeConfigs = const {
    'inventory_18k': _AccountTypeConfig(
      name: 'مخزون ذهب عيار 18',
      category: 'المخزون',
      icon: Icons.inventory_2,
      tone: _Tone.secondary,
    ),
    'inventory_21k': _AccountTypeConfig(
      name: 'مخزون ذهب عيار 21',
      category: 'المخزون',
      icon: Icons.inventory,
      tone: _Tone.secondary,
    ),
    'inventory_22k': _AccountTypeConfig(
      name: 'مخزون ذهب عيار 22',
      category: 'المخزون',
      icon: Icons.inventory_outlined,
      tone: _Tone.secondary,
    ),
    'inventory_24k': _AccountTypeConfig(
      name: 'مخزون ذهب عيار 24',
      category: 'المخزون',
      icon: Icons.inventory_rounded,
      tone: _Tone.secondary,
    ),
    'cash': _AccountTypeConfig(
      name: 'النقدية / الصندوق',
      category: 'النقدية',
      icon: Icons.account_balance_wallet,
      tone: _Tone.primary,
    ),
    'customers': _AccountTypeConfig(
      name: 'العملاء (حساب تجميعي)',
      category: 'العملاء والموردين',
      icon: Icons.people_alt,
      tone: _Tone.info,
    ),
    'suppliers': _AccountTypeConfig(
      name: 'الموردون (حساب تجميعي)',
      category: 'العملاء والموردين',
      icon: Icons.store,
      tone: _Tone.info,
    ),
    'revenue': _AccountTypeConfig(
      name: 'الإيرادات',
      category: 'الإيرادات والمصروفات',
      icon: Icons.trending_up,
      tone: _Tone.success,
    ),
    'cost': _AccountTypeConfig(
      name: 'تكلفة البضاعة المباعة',
      category: 'الإيرادات والمصروفات',
      icon: Icons.request_quote,
      tone: _Tone.success,
    ),
    'commission': _AccountTypeConfig(
      name: 'مصروف العمولات',
      category: 'العمولات',
      icon: Icons.receipt_long,
      tone: _Tone.info,
    ),
    'commission_vat': _AccountTypeConfig(
      name: 'ضريبة القيمة المضافة على العمولات',
      category: 'العمولات',
      icon: Icons.receipt,
      tone: _Tone.info,
    ),
    'vat_payable': _AccountTypeConfig(
      name: 'ضريبة القيمة المضافة المستحقة (دائنة)',
      category: 'الضرائب',
      icon: Icons.balance,
      tone: _Tone.warning,
    ),
    'vat_receivable': _AccountTypeConfig(
      name: 'ضريبة القيمة المضافة المدفوعة (مدينة)',
      category: 'الضرائب',
      icon: Icons.balance_outlined,
      tone: _Tone.warning,
    ),
    'profit_loss': _AccountTypeConfig(
      name: 'الأرباح والخسائر',
      category: 'حسابات إضافية',
      icon: Icons.leaderboard,
      tone: _Tone.neutral,
    ),
    'sales_returns': _AccountTypeConfig(
      name: 'مردودات المبيعات',
      category: 'حسابات إضافية',
      icon: Icons.reply,
      tone: _Tone.neutral,
    ),
    'purchase_returns': _AccountTypeConfig(
      name: 'مردودات المشتريات',
      category: 'حسابات إضافية',
      icon: Icons.reply_all,
      tone: _Tone.neutral,
    ),
  };

  final Map<String, _Tone> _categoryTones = const {
    'المخزون': _Tone.secondary,
    'النقدية': _Tone.primary,
    'العملاء والموردين': _Tone.info,
    'الإيرادات والمصروفات': _Tone.success,
    'العمولات': _Tone.info,
    'الضرائب': _Tone.warning,
    'حسابات إضافية': _Tone.neutral,
  };

  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _mappings = [];
  Map<String, Map<String, int?>> _pendingChanges = {};
  bool _hasUnsavedChanges = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _operationConfigs.length,
      vsync: this,
    );
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  ColorScheme get _scheme => Theme.of(context).colorScheme;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Color get _surfaceColor => _scheme.surface;
  Color get _cardColor => _isDark
      ? Color.alphaBlend(
          _withOpacity(_scheme.surfaceContainerHighest, 0.45),
          _surfaceColor,
        )
      : Color.alphaBlend(_withOpacity(_scheme.primary, 0.05), _surfaceColor);

  Color get _outlineColor => _scheme.outline;
  Color get _strongTextColor => _scheme.onSurface;
  Color get _mutedTextColor => _scheme.onSurfaceVariant;

  Color _toneColor(_Tone tone) {
    switch (tone) {
      case _Tone.primary:
        return _scheme.primary;
      case _Tone.secondary:
        return _scheme.secondary;
      case _Tone.tertiary:
        return _scheme.tertiary;
      case _Tone.success:
        return _scheme.tertiary;
      case _Tone.warning:
        return _scheme.errorContainer;
      case _Tone.info:
        return _scheme.secondaryContainer;
      case _Tone.danger:
        return _scheme.error;
      case _Tone.neutral:
        return _scheme.outlineVariant;
    }
  }

  Color _withOpacity(Color color, double opacity) {
    final clamped = opacity.clamp(0.0, 1.0);
    final alpha = (clamped * 255).round();
    return color.withAlpha(alpha);
  }

  Color _blendOnSurface(Color color, double opacity) {
    return Color.alphaBlend(_withOpacity(color, opacity), _surfaceColor);
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        _apiService.getAccounts(),
        _apiService.getAccountingMappings(),
      ]);

      if (!mounted) return;
      setState(() {
        _accounts = List<Map<String, dynamic>>.from(results[0]);
        _mappings = List<Map<String, dynamic>>.from(results[1]);
        _pendingChanges = {};
        _hasUnsavedChanges = false;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar('خطأ في تحميل البيانات: $error', _toneColor(_Tone.danger));
    }
  }

  int? _getMappedAccountId(String operationType, String accountType) {
    if (_pendingChanges.containsKey(operationType) &&
        _pendingChanges[operationType]!.containsKey(accountType)) {
      return _pendingChanges[operationType]![accountType];
    }

    final mapping = _mappings.firstWhere(
      (m) =>
          m['operation_type'] == operationType &&
          m['account_type'] == accountType,
      orElse: () => {},
    );

    return mapping['account_id'];
  }

  void _updateMapping(
    String operationType,
    String accountType,
    int? accountId,
  ) {
    setState(() {
      _pendingChanges.putIfAbsent(operationType, () => {});
      _pendingChanges[operationType]![accountType] = accountId;
      _hasUnsavedChanges = true;
    });
  }

  Future<void> _saveAllChanges() async {
    if (_pendingChanges.isEmpty) {
      _showSnackBar('لا توجد تغييرات للحفظ', _toneColor(_Tone.warning));
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          content: SizedBox(
            width: 260,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: _scheme.primary),
                const SizedBox(height: 16),
                const Text('جاري حفظ التغييرات...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      for (final entry in _pendingChanges.entries) {
        final operationType = entry.key;
        for (final accountEntry in entry.value.entries) {
          final accountType = accountEntry.key;
          final accountId = accountEntry.value;
          if (accountId != null) {
            await _apiService.createAccountingMapping(
              operationType: operationType,
              accountType: accountType,
              accountId: accountId,
            );
          }
        }
      }

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      await _loadData();

      if (mounted) {
        _showSnackBar(
          '✅ تم حفظ جميع التغييرات بنجاح',
          _toneColor(_Tone.success),
        );
      }
    } catch (error) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnackBar('خطأ في الحفظ: $error', _toneColor(_Tone.danger));
      }
    }
  }

  Future<bool> _confirmDiscardChanges() async {
    if (!_hasUnsavedChanges) {
      return true;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(Icons.warning, color: _toneColor(_Tone.warning)),
              const SizedBox(width: 12),
              const Text('إلغاء التغييرات؟'),
            ],
          ),
          content: const Text(
            'سيتم فقدان جميع التعديلات غير المحفوظة. هل تريد المتابعة؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('متابعة التحرير'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('إلغاء التغييرات'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      setState(() {
        _pendingChanges = {};
        _hasUnsavedChanges = false;
      });
      _showSnackBar('تم تجاهل التغييرات', _toneColor(_Tone.info));
      return true;
    }

    return false;
  }

  void _showSnackBar(String message, Color backgroundColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _accountLabel(Map<String, dynamic> account) {
    final number = account['account_number'] ?? '---';
    final name = account['name'] ?? 'غير معروف';
    return '$number - $name';
  }

  String _getAccountName(int? accountId) {
    if (accountId == null) return '---';
    final account = _accounts.firstWhere(
      (a) => a['id'] == accountId,
      orElse: () => {'account_number': '---', 'name': 'غير معروف'},
    );
    return _accountLabel(account);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || !_hasUnsavedChanges) {
          return;
        }
        final shouldLeave = await _confirmDiscardChanges();
        if (!mounted || !shouldLeave) {
          return;
        }
        Navigator.of(this.context).pop(result);
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: _buildAppBar(),
          body: _isLoading ? _buildLoadingState() : _buildMainContent(),
          floatingActionButton: _hasUnsavedChanges ? _buildSaveButton() : null,
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: const [
          Icon(Icons.settings),
          SizedBox(width: 12),
          Text('إعدادات الربط المحاسبي'),
        ],
      ),
      actions: [
        if (_hasUnsavedChanges)
          IconButton(
            icon: const Icon(Icons.cancel_outlined),
            tooltip: 'إلغاء التغييرات',
            onPressed: () async {
              await _confirmDiscardChanges();
            },
          ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'تحديث البيانات',
          onPressed: _loadData,
        ),
        IconButton(
          icon: const Icon(Icons.help_outline),
          tooltip: 'مساعدة',
          onPressed: _showHelpDialog,
        ),
      ],
      bottom: TabBar(
        controller: _tabController,
        isScrollable: true,
        labelColor: _strongTextColor,
        unselectedLabelColor: _mutedTextColor,
        indicatorColor: _scheme.primary,
        tabs: _operationConfigs
            .map(
              (config) => Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(config.icon, size: 20),
                    const SizedBox(width: 8),
                    Text(config.label),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: _scheme.primary),
          const SizedBox(height: 16),
          Text(
            'جاري تحميل البيانات...',
            style: TextStyle(color: _mutedTextColor),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        _buildStatisticsCard(),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _operationConfigs
                .map((config) => _buildOperationTypeSettings(config))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildStatisticsCard() {
    final totalMappings = _mappings.length;
    final totalAccountTypes = _accountTypeConfigs.length;
    final totalOperations = _operationConfigs.length;
    final completionPercent = totalAccountTypes == 0
        ? 0
        : (totalMappings / (totalOperations * totalAccountTypes) * 100)
              .clamp(0, 100)
              .round();

    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 0,
      color: _cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem(
              'إجمالي الربطات',
              '$totalMappings',
              Icons.link,
              _toneColor(_Tone.success),
            ),
            _buildStatItem(
              'أنواع الحسابات',
              '$totalAccountTypes',
              Icons.account_tree,
              _toneColor(_Tone.primary),
            ),
            _buildStatItem(
              'أنواع العمليات',
              '$totalOperations',
              Icons.category,
              _toneColor(_Tone.warning),
            ),
            _buildStatItem(
              'نسبة الإكمال',
              '$completionPercent%',
              Icons.percent,
              _toneColor(_Tone.info),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _blendOnSurface(color, 0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: _strongTextColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: _mutedTextColor, fontSize: 12)),
      ],
    );
  }

  Widget _buildOperationTypeSettings(_OperationConfig config) {
    final Map<String, List<MapEntry<String, _AccountTypeConfig>>> grouped = {};
    final List<String> categoryOrder = [];

    for (final entry in _accountTypeConfigs.entries) {
      final accountConfig = entry.value;
      final category = accountConfig.category;
      if (!grouped.containsKey(category)) {
        grouped[category] = [];
        categoryOrder.add(category);
      }
      grouped[category]!.add(entry);
    }

    final toneColor = _toneColor(config.tone);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: _cardColor,
          elevation: 1,
          shadowColor: _withOpacity(toneColor, 0.12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
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
                        color: _blendOnSurface(toneColor, 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(config.icon, color: toneColor, size: 28),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إعدادات الربط المحاسبي لـ ${config.label}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _strongTextColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            config.description,
                            style: TextStyle(
                              color: _mutedTextColor,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _blendOnSurface(_scheme.secondary, 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: _scheme.secondary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'اختر الحساب المحاسبي المناسب لكل نوع حساب لضمان قيود دقيقة.',
                          style: TextStyle(
                            color: _mutedTextColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        for (final category in categoryOrder) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              category,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: _strongTextColor,
              ),
            ),
          ),
          ...grouped[category]!.map(
            (accountEntry) => _buildMappingCard(
              operationType: config.key,
              accountKey: accountEntry.key,
              config: accountEntry.value,
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildMappingCard({
    required String operationType,
    required String accountKey,
    required _AccountTypeConfig config,
  }) {
    final tone =
        config.tone ?? _categoryTones[config.category] ?? _Tone.neutral;
    final color = _toneColor(tone);
    final mappedAccountId = _getMappedAccountId(operationType, accountKey);
    final hasMapping = mappedAccountId != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      shadowColor: _withOpacity(color, 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: hasMapping
              ? _withOpacity(color, 0.35)
              : _blendOnSurface(_outlineColor, 0.4),
          width: 1.2,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: _cardColor,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _blendOnSurface(color, 0.16),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(config.icon, color: color, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      config.name,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _strongTextColor,
                      ),
                    ),
                  ),
                  if (hasMapping)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _toneColor(_Tone.success),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            Icons.check_circle,
                            color: Colors.white,
                            size: 16,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'مرتبط',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                key: ValueKey(
                  '${operationType}_${accountKey}_${mappedAccountId ?? 'null'}',
                ),
                initialValue: mappedAccountId,
                decoration: InputDecoration(
                  labelText: 'اختر الحساب المحاسبي',
                  labelStyle: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                  filled: true,
                  fillColor: _blendOnSurface(color, _isDark ? 0.18 : 0.08),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: color, width: 2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _blendOnSurface(color, 0.3)),
                  ),
                ),
                icon: Icon(Icons.arrow_drop_down, color: color),
                isExpanded: true,
                items: _accounts.map((account) {
                  return DropdownMenuItem<int>(
                    value: account['id'] as int?,
                    child: Text(
                      _accountLabel(account),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _strongTextColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  _updateMapping(operationType, accountKey, value);
                },
              ),
              if (hasMapping) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _blendOnSurface(_toneColor(_Tone.success), 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _withOpacity(_toneColor(_Tone.success), 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.link,
                        color: _toneColor(_Tone.success),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'مرتبط بـ ${_getAccountName(mappedAccountId)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: _strongTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return FloatingActionButton.extended(
      onPressed: _saveAllChanges,
      backgroundColor: _toneColor(_Tone.success),
      icon: const Icon(Icons.save_outlined),
      label: const Text('حفظ التغييرات'),
    );
  }

  void _showHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              Icon(Icons.help_outline, color: _scheme.primary),
              const SizedBox(width: 12),
              const Text('مساعدة - الربط المحاسبي'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                _HelpItem(
                  icon: Icons.info,
                  title: 'ما هو الربط المحاسبي؟',
                  description:
                      'يحدد الحسابات المحاسبية المستخدمة تلقائياً لكل عملية في النظام لضمان توازن القيود.',
                ),
                _HelpItem(
                  icon: Icons.settings,
                  title: 'كيف أعدّل الإعدادات؟',
                  description:
                      'اختر نوع العملية من الأعلى، ثم عيّن الحساب المناسب لكل بند باستخدام القائمة المنسدلة، وبعد الانتهاء اضغط حفظ التغييرات.',
                ),
                _HelpItem(
                  icon: Icons.lightbulb,
                  title: 'نصيحة',
                  description:
                      'يمكنك إجراء عدة تغييرات دفعة واحدة ثم حفظها مرة واحدة فقط لتقليل عدد الطلبات على الخادم.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpItem extends StatelessWidget {
  const _HelpItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colorScheme.secondary, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(description, style: TextStyle(color: muted, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _Tone {
  primary,
  secondary,
  tertiary,
  success,
  warning,
  info,
  danger,
  neutral,
}

class _OperationConfig {
  const _OperationConfig({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.tone,
  });

  final String key;
  final String label;
  final String description;
  final IconData icon;
  final _Tone tone;
}

class _AccountTypeConfig {
  const _AccountTypeConfig({
    required this.name,
    required this.category,
    required this.icon,
    this.tone,
  });

  final String name;
  final String category;
  final IconData icon;
  final _Tone? tone;
}
