import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';

class SystemResetScreen extends StatefulWidget {
  const SystemResetScreen({super.key});

  @override
  State<SystemResetScreen> createState() => _SystemResetScreenState();
}

class _SystemResetScreenState extends State<SystemResetScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  bool _isCostingAction = false;
  Map<String, dynamic>? _systemInfo;

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    if (value == true) return 1;
    return 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _loadSystemInfo();
  }

  Future<void> _loadSystemInfo() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final response = await _apiService.getSystemResetInfo();
      if (!mounted) return;
      setState(() {
        _systemInfo = response['data'];
      });
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog('خطأ في تحميل البيانات: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _performReset(
    String resetType,
    String title,
    String description,
  ) async {
    final confirmed = await _showConfirmationDialog(
      title,
      description,
      confirmationText: title,
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      final response = await _apiService.resetSystem(resetType: resetType);
      if (!mounted) return;

      if (response['status'] == 'success') {
        _showSuccessDialog(response['message']);

        // If this was a full reset, the system has no users anymore.
        // Clear local auth state and go straight to the setup wizard.
        if (resetType == 'all' || resetType == 'all_with_accounts') {
          final auth = context.read<AuthProvider>();
          await auth.logout();
          await auth.init();
          if (!mounted) return;
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/setup', (route) => false);
          return;
        }

        _loadSystemInfo(); // Refresh info after reset
      } else {
        _showErrorDialog(response['message']);
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog('خطأ: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleCostingAction({required bool rebuild}) async {
    final title = rebuild ? 'إعادة بناء متوسط التكلفة' : 'تصفير متوسط التكلفة';
    final description = rebuild
        ? 'سيتم قراءة جميع فواتير الشراء لإعادة بناء المتوسط المتحرك. قد يستغرق ذلك بضع دقائق.'
        : 'سيتم تصفير جميع قيم متوسط التكلفة المتحرك لتبدأ من الصفر.';
    final confirmationToken = rebuild ? 'REBUILD' : 'RESET';

    final confirmed = await _showConfirmationDialog(
      title,
      description,
      confirmationText: confirmationToken,
    );

    if (confirmed != true) return;

    setState(() => _isCostingAction = true);

    try {
      final response = await _apiService.resetGoldCosting(
        mode: rebuild ? 'rebuild' : 'zero',
      );

      if (!mounted) return;

      if (response['status'] == 'success') {
        final result = (response['result'] as Map<String, dynamic>?) ?? {};
        final processed = result['processed_invoices'];
        final snapshot = (result['snapshot'] as Map<String, dynamic>?) ?? {};
        final avg = _toDouble(snapshot['avg_total']);
        final buffer = StringBuffer(
          rebuild ? 'تمت إعادة بناء المتوسط بنجاح.' : 'تم تصفير المتوسط بنجاح.',
        );
        if (processed != null) {
          buffer.write(' الفواتير المعاد احتسابها: $processed.');
        }
        buffer.write(' المتوسط الحالي: ${avg.toStringAsFixed(2)} ر.س/جم');
        _showSuccessDialog(buffer.toString());
        await _loadSystemInfo();
      } else {
        _showErrorDialog(response['message'] ?? 'فشلت عملية تحديث المتوسط');
      }
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog('خطأ أثناء تحديث المتوسط: $e');
    } finally {
      if (mounted) {
        setState(() => _isCostingAction = false);
      }
    }
  }

  Future<bool> _showConfirmationDialog(
    String title,
    String message, {
    required String confirmationText,
  }) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormFieldState>();

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return StatefulBuilder(
              builder: (context, setState) {
                return AlertDialog(
                  title: Row(
                    children: [
                      Icon(
                        Icons.warning,
                        color: Theme.of(context).colorScheme.error,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(message, style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 24),
                      Text(
                        'للتأكيد، يرجى كتابة "$confirmationText" في الحقل أدناه:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        key: formKey,
                        controller: controller,
                        autofocus: true,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: confirmationText,
                        ),
                        onChanged: (value) {
                          setState(() {}); // Re-check button state
                        },
                        validator: (value) {
                          if (value != confirmationText) {
                            return 'النص غير متطابق';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('إلغاء'),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, child) {
                        return FilledButton(
                          onPressed: value.text == confirmationText
                              ? () => Navigator.of(context).pop(true)
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          child: const Text('تأكيد الحذف'),
                        );
                      },
                    ),
                  ],
                );
              },
            );
          },
        ) ??
        false;
  }

  void _showSuccessDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700, size: 28),
            const SizedBox(width: 12),
            const Text(
              'نجحت العملية',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.error,
              color: Theme.of(context).colorScheme.error,
              size: 28,
            ),
            const SizedBox(width: 12),
            const Text('خطأ', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  Widget _buildResetCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required int itemCount,
  }) {
    bool disabled = itemCount == 0;
    final radius = BorderRadius.circular(16);
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: radius),
      child: InkWell(
        onTap: disabled ? null : onPressed,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Opacity(
            opacity: disabled ? 0.6 : 1,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$itemCount سجل',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color.withValues(alpha: 0.8),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCostingSummaryCard(
    ThemeData theme,
    Map<String, dynamic> costingData,
  ) {
    if (costingData.isEmpty) {
      return const SizedBox.shrink();
    }

    final snapshot = (costingData['snapshot'] as Map<String, dynamic>?) ?? {};
    final weight = _toDouble(costingData['total_inventory_weight']);
    final avgTotal = _toDouble(snapshot['avg_total']);
    final avgGold = _toDouble(snapshot['avg_gold']);
    final avgWage = _toDouble(snapshot['avg_manufacturing']);
    final lastUpdated = costingData['last_updated'] as String?;

    String formatWeight(double value) => value.toStringAsFixed(3);
    String formatCost(double value) => value.toStringAsFixed(2);

    final infoColor = theme.colorScheme.primary;
    final secondaryColor = theme.colorScheme.tertiary;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: infoColor.withValues(alpha: 0.15),
                  child: Icon(Icons.scale, color: infoColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'سلامة متوسط التكلفة',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'يُستخدم هذا المتوسط لأي فاتورة شراء أو بيع قادمة. احرص على تصفيره قبل بدء دورة بيانات جديدة.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildStatChip(
                  'الوزن بالمخزون',
                  '${formatWeight(weight)} جم',
                  infoColor,
                ),
                _buildStatChip(
                  'متوسط إجمالي/جم',
                  '${formatCost(avgTotal)} ر.س',
                  secondaryColor,
                ),
                _buildStatChip(
                  'مكون الذهب/جم',
                  '${formatCost(avgGold)} ر.س',
                  theme.colorScheme.secondary,
                ),
                _buildStatChip(
                  'مكون الأجرة/جم',
                  '${formatCost(avgWage)} ر.س',
                  theme.colorScheme.error,
                ),
              ],
            ),
            if (lastUpdated != null) ...[
              const SizedBox(height: 12),
              Text('آخر تحديث: $lastUpdated', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            if (_isCostingAction) const LinearProgressIndicator(),
            if (_isCostingAction) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isCostingAction
                        ? null
                        : () => _handleCostingAction(rebuild: false),
                    icon: const Icon(Icons.restart_alt),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                    ),
                    label: const Text('تصفير المتوسط'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isCostingAction
                        ? null
                        : () => _handleCostingAction(rebuild: true),
                    icon: const Icon(Icons.replay_circle_filled_outlined),
                    label: const Text('إعادة بناء من الفواتير'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = _systemInfo;

    final transactions = (data?['transactions'] as Map<String, dynamic>?) ?? {};
    final customersSuppliers =
        (data?['customers_suppliers'] as Map<String, dynamic>?) ?? {};
    final settingsData = (data?['settings'] as Map<String, dynamic>?) ?? {};
    final costingData =
        (data?['inventory_costing'] as Map<String, dynamic>?) ?? {};

    final int journalEntries = _toInt(transactions['journal_entries']);
    final int invoicesCount = _toInt(transactions['invoices']);
    final int vouchersCount = _toInt(transactions['vouchers']);
    final int transactionsTotal =
        journalEntries + invoicesCount + vouchersCount;

    final int customersCount = _toInt(customersSuppliers['customers']);
    final int suppliersCount = _toInt(customersSuppliers['suppliers']);
    final int customersSuppliersTotal = customersCount + suppliersCount;

    final bool hasSettings = settingsData['has_settings'] == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'إعادة تهيئة النظام',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: theme.colorScheme.errorContainer,
        foregroundColor: theme.colorScheme.onErrorContainer,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadSystemInfo,
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _systemInfo == null
          ? Center(
              child: Text(
                'خطأ في تحميل بيانات النظام',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadSystemInfo,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: theme.colorScheme.error,
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            'إعادة تهيئة النظام ستحذف البيانات بشكل نهائي. يرجى أخذ نسخة احتياطية أولاً.',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildCostingSummaryCard(theme, costingData),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      'اختر نوع إعادة التهيئة:',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  _buildResetCard(
                    title: 'حذف العمليات',
                    description: 'حذف جميع القيود والفواتير والسندات',
                    icon: Icons.receipt_long,
                    color: theme.colorScheme.primary,
                    itemCount: transactionsTotal,
                    onPressed: () => _performReset(
                      'transactions',
                      'حذف العمليات',
                      'سيتم حذف جميع العمليات ($transactionsTotal سجل). ستبقى بيانات العملاء والموردين والحسابات.',
                    ),
                  ),
                  _buildResetCard(
                    title: 'حذف العملاء والموردين',
                    description: 'حذف جميع بيانات العملاء والموردين',
                    icon: Icons.people_outline,
                    color: theme.colorScheme.secondary,
                    itemCount: customersSuppliersTotal,
                    onPressed: () => _performReset(
                      'customers_suppliers',
                      'حذف العملاء والموردين',
                      'سيتم حذف جميع بيانات العملاء ($customersCount) والموردين ($suppliersCount).',
                    ),
                  ),
                  _buildResetCard(
                    title: 'إعادة تعيين الإعدادات',
                    description: 'إرجاع جميع الإعدادات للقيم الافتراضية',
                    icon: Icons.settings_backup_restore,
                    color: theme.colorScheme.tertiary,
                    itemCount: hasSettings ? 1 : 0,
                    onPressed: () => _performReset(
                      'settings',
                      'إعادة تعيين الإعدادات',
                      'سيتم إعادة تعيين جميع الإعدادات للقيم الافتراضية.',
                    ),
                  ),
                  _buildResetCard(
                    title: 'إعادة تهيئة كاملة (مع الحفاظ على شجرة الحسابات)',
                    description:
                        'حذف جميع البيانات التشغيلية مع الحفاظ على شجرة الحسابات',
                    icon: Icons.delete_sweep,
                    color: theme.colorScheme.error,
                    itemCount: 1,
                    onPressed: () => _performReset(
                      'all',
                      'إعادة تهيئة كاملة',
                      'سيتم حذف جميع البيانات نهائياً مع الحفاظ على شجرة الحسابات. سيؤدي ذلك إلى حذف المستخدمين والبيانات التشغيلية.',
                    ),
                  ),
                  _buildResetCard(
                    title: 'إعادة تهيئة كاملة (مع حذف شجرة الحسابات)',
                    description: 'حذف جميع البيانات بما في ذلك شجرة الحسابات',
                    icon: Icons.delete_forever,
                    color: theme.colorScheme.error,
                    itemCount: 1,
                    onPressed: () => _performReset(
                      'all_with_accounts',
                      'إعادة تهيئة كاملة',
                      'سيتم حذف كل شيء نهائياً من قاعدة البيانات (بما في ذلك شجرة الحسابات). لا يمكن التراجع عن هذه العملية.',
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
