import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';

class WeightClosingSettingsScreen extends StatefulWidget {
  const WeightClosingSettingsScreen({super.key});

  @override
  State<WeightClosingSettingsScreen> createState() =>
      _WeightClosingSettingsScreenState();
}

class _WeightClosingSettingsScreenState
    extends State<WeightClosingSettingsScreen> {
  bool _isLoading = true;
  bool _isSaving = false;

  bool _autoCloseEnabled = true;
  String _priceSource = 'live';
  bool _allowOverride = true;

  double _cashDeficitThreshold = 50.0;
  double _goldPureDeficitThresholdGrams = 0.10;

  late final TextEditingController _cashThresholdController;
  late final TextEditingController _goldThresholdController;

  static const Map<String, IconData> _priceSourceIcons = {
    'live': Icons.podcasts_outlined,
    'average': Icons.auto_graph_outlined,
    'invoice': Icons.receipt_long_outlined,
  };

  static const Map<String, String> _priceSourceTitles = {
    'live': 'السعر المباشر (Live)',
    'average': 'متوسط تكلفة المخزون',
    'invoice': 'سعر الفاتورة نفسها',
  };

  static const Map<String, String> _priceSourceDescriptions = {
    'live': 'يستخدم آخر سعر جرام محدث من شاشة أسعار الذهب.',
    'average': 'يعتمد على متوسط التكلفة من خدمة التكاليف (GoldCostingService).',
    'invoice': 'يقرأ سعر الجرام من الفاتورة التي سيتم تسكيرها.',
  };

  @override
  void initState() {
    super.initState();
    _cashThresholdController = TextEditingController();
    _goldThresholdController = TextEditingController();
    _hydrateFromProvider();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSettings());
  }

  @override
  void dispose() {
    _cashThresholdController.dispose();
    _goldThresholdController.dispose();
    super.dispose();
  }

  void _hydrateFromProvider() {
    final config = Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).weightClosingSettings;
    _applyConfig(config, shouldSetState: false);
  }

  Future<void> _loadSettings() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final config = await context
          .read<SettingsProvider>()
          .fetchWeightClosingSettings();
      if (!mounted) return;
      _applyConfig(config);
    } catch (error) {
      if (!mounted) return;
      _showSnack('تعذر تحديث الإعدادات: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyConfig(Map<String, dynamic> config, {bool shouldSetState = true}) {
    final enabled = config['enabled'] == true;
    final priceSource =
        (config['price_source']?.toString().toLowerCase()) ?? 'live';
    final allowOverride = config['allow_override'] == null
        ? true
        : (config['allow_override'] == true);

    final cashThreshold = _asDouble(
      config['shift_close_cash_deficit_threshold'],
      fallback: 50.0,
    );
    final goldThreshold = _asDouble(
      config['shift_close_gold_pure_deficit_threshold_grams'],
      fallback: 0.10,
    );

    if (shouldSetState) {
      setState(() {
        _autoCloseEnabled = enabled;
        _priceSource = _normalizePriceSource(priceSource);
        _allowOverride = allowOverride;
        _cashDeficitThreshold = cashThreshold < 0 ? 0.0 : cashThreshold;
        _goldPureDeficitThresholdGrams = goldThreshold < 0
            ? 0.0
            : goldThreshold;
      });
    } else {
      _autoCloseEnabled = enabled;
      _priceSource = _normalizePriceSource(priceSource);
      _allowOverride = allowOverride;
      _cashDeficitThreshold = cashThreshold < 0 ? 0.0 : cashThreshold;
      _goldPureDeficitThresholdGrams = goldThreshold < 0 ? 0.0 : goldThreshold;
    }

    _cashThresholdController.text = _cashDeficitThreshold.toStringAsFixed(2);
    _goldThresholdController.text = _goldPureDeficitThresholdGrams
        .toStringAsFixed(3);
  }

  double _asDouble(dynamic value, {double fallback = 0.0}) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  String _normalizePriceSource(String source) {
    switch (source) {
      case 'average':
        return 'average';
      case 'invoice':
        return 'invoice';
      default:
        return 'live';
    }
  }

  Future<void> _saveSettings() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final payload = {
      'enabled': _autoCloseEnabled,
      'price_source': _priceSource,
      'allow_override': _allowOverride,
      'shift_close_cash_deficit_threshold': _cashDeficitThreshold,
      'shift_close_gold_pure_deficit_threshold_grams':
          _goldPureDeficitThresholdGrams,
    };

    try {
      final updated = await context
          .read<SettingsProvider>()
          .updateWeightClosingSettingsPayload(payload);
      if (!mounted) return;
      _applyConfig(updated);
      _showSnack('✅ تم حفظ إعدادات التسكير الآلي بنجاح');
    } catch (error) {
      if (!mounted) return;
      _showSnack('تعذر حفظ الإعدادات: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, textAlign: TextAlign.center),
          backgroundColor: isError
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إعدادات التسكير الآلي'),
        actions: [
          IconButton(
            tooltip: 'إعادة تحميل الإعدادات',
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadSettings,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSettings,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                children: [
                  _buildHeroCard(theme),
                  const SizedBox(height: 16),
                  _buildStatusChips(theme),
                  const SizedBox(height: 16),
                  _buildAutoCloseToggle(theme),
                  const SizedBox(height: 16),
                  _buildPriceSourceCard(theme),
                  const SizedBox(height: 16),
                  _buildOverrideCard(theme),
                  const SizedBox(height: 16),
                  _buildSecurityThresholds(theme),
                  const SizedBox(height: 16),
                  _buildChecklist(theme),
                  const SizedBox(height: 24),
                  _buildActionButtons(theme),
                ],
              ),
            ),
    );
  }

  Widget _buildHeroCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Icon(Icons.auto_mode, size: 32),
            SizedBox(height: 12),
            Text(
              'تحكم كامل في التسكير الوزني',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 10),
            Text(
              'حدد مصدر السعر، فعل/عطل الإغلاق التلقائي، واسمح للمستخدمين بتعديل السعر عند الحاجة.',
              style: TextStyle(fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChips(ThemeData theme) {
    final success = theme.colorScheme.tertiary;
    final warning = theme.colorScheme.secondary;
    final info = theme.colorScheme.primary;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _buildInfoChip(
          icon: _autoCloseEnabled ? Icons.check_circle : Icons.pause_circle,
          label: _autoCloseEnabled
              ? 'التسكير الآلي مفعل'
              : 'التسكير الآلي متوقف',
          color: _autoCloseEnabled ? success : theme.colorScheme.outline,
        ),
        _buildInfoChip(
          icon: _priceSourceIcons[_priceSource] ?? Icons.stacked_line_chart,
          label: _priceSourceTitles[_priceSource] ?? 'السعر المباشر',
          color: warning,
        ),
        _buildInfoChip(
          icon: _allowOverride ? Icons.edit_note : Icons.block,
          label: _allowOverride
              ? 'المستخدم يستطيع التعديل'
              : 'لا يسمح بالتعديل اليدوي',
          color: info,
        ),
      ],
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Chip(
      avatar: Icon(icon, size: 18, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
      backgroundColor: color.withValues(alpha: 0.9),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    );
  }

  Widget _buildPriceSourceOption(ThemeData theme, String key) {
    final isSelected = _priceSource == key;
    final Color primary = theme.colorScheme.primary;
    final Color outline = theme.colorScheme.outlineVariant;
    final String title = _priceSourceTitles[key] ?? key;
    final String subtitle = _priceSourceDescriptions[key] ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => setState(() => _priceSource = key),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isSelected ? primary : outline),
            color: isSelected
                ? primary.withValues(alpha: 0.08)
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.05,
                  ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _priceSourceIcons[key] ?? Icons.price_change,
                color: isSelected ? primary : outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected
                            ? primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: isSelected ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.check_circle, color: primary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutoCloseToggle(ThemeData theme) {
    return Card(
      child: SwitchListTile.adaptive(
        value: _autoCloseEnabled,
        onChanged: (value) => setState(() => _autoCloseEnabled = value),
        title: const Text('تشغيل التسكير التلقائي عند حفظ فاتورة البيع'),
        subtitle: Text(valueDescription, style: theme.textTheme.bodySmall),
      ),
    );
  }

  String get valueDescription => _autoCloseEnabled
      ? 'سيقوم النظام بإغلاق الوزن تلقائياً باستخدام القواعد أدناه.'
      : 'لن يتم إغلاق الوزن تلقائياً، ويمكنك إغلاقه لاحقاً من شاشة التقارير.';

  Widget _buildPriceSourceCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'مصدر سعر التسكير',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ..._priceSourceTitles.keys.map(
              (key) => _buildPriceSourceOption(theme, key),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverrideCard(ThemeData theme) {
    return Card(
      child: SwitchListTile.adaptive(
        value: _allowOverride,
        onChanged: (value) => setState(() => _allowOverride = value),
        title: const Text('السماح بتعديل سعر التسكير يدوياً'),
        subtitle: Text(
          _allowOverride
              ? 'يمكن للمستخدم تغيير سعر الإغلاق قبل الاعتماد.'
              : 'لن يمكن لأي مستخدم تغيير السعر الذي يحدده النظام.',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _buildSecurityThresholds(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'عتبات تنبيه العُهد (Shift Closing)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'لن يتم إنشاء تنبيه إلا إذا تجاوز العجز هذه العتبات لتجنب الفروقات البسيطة.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _cashThresholdController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'عجز نقدي أكبر من (ر.س)',
                hintText: 'مثال: 50',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
              onChanged: (v) {
                final parsed = double.tryParse(v.trim());
                if (parsed == null) return;
                setState(
                  () => _cashDeficitThreshold = parsed < 0 ? 0.0 : parsed,
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _goldThresholdController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'عجز ذهب صافي أكبر من (جم 24k)',
                hintText: 'مثال: 0.10',
                prefixIcon: Icon(Icons.scale_outlined),
              ),
              onChanged: (v) {
                final parsed = double.tryParse(v.trim());
                if (parsed == null) return;
                setState(
                  () => _goldPureDeficitThresholdGrams = parsed < 0
                      ? 0.0
                      : parsed,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChecklist(ThemeData theme) {
    final items = [
      'تأكد من تحديث سعر الذهب من شاشة أسعار الذهب بشكل دوري.',
      'يفضل اختيار "متوسط التكلفة" إذا كنت تعتمد على تقييم مخزون دقيق.',
      'إيقاف خيار التعديل يمنع الأخطاء الناتجة عن تدخل بشري.',
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'نصائح العمل الذهبي',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...items.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _saveSettings,
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_isSaving ? 'جارٍ الحفظ...' : 'حفظ الإعدادات'),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: _isLoading ? null : _loadSettings,
          icon: const Icon(Icons.replay),
          label: const Text('تحديث من الخادم'),
        ),
      ],
    );
  }
}
