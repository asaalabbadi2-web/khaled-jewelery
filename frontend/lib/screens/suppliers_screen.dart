import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart' as app_theme;

import 'account_statement_screen.dart';
import 'add_supplier_screen.dart';

class SuppliersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SuppliersScreen({super.key, required this.api, this.isArabic = true});

  @override
  SuppliersScreenState createState() => SuppliersScreenState();
}

class SuppliersScreenState extends State<SuppliersScreen> {
  late Future<List<dynamic>> _suppliersFuture;

  final TextEditingController _searchController = TextEditingController();

  bool _filterNonZero = false;

  int _mainKarat = 21;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.watch<SettingsProvider>();
    final newMainKarat = settings.mainKarat;
    if (newMainKarat != _mainKarat) {
      setState(() {
        _mainKarat = newMainKarat;
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadSuppliers() {
    setState(() {
      _suppliersFuture = widget.api.getSuppliers();
    });
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  double _goldMainEquivalent(Map<String, dynamic> supplier) {
    final b18 = _toDouble(supplier['balance_gold_18k']);
    final b21 = _toDouble(supplier['balance_gold_21k']);
    final b22 = _toDouble(supplier['balance_gold_22k']);
    final b24 = _toDouble(supplier['balance_gold_24k']);

    final main = _mainKarat <= 0 ? 21.0 : _mainKarat.toDouble();

    // Convert each karat into main-karat-equivalent weight:
    // w_main = w * (karat / main)
    return (b18 * (18.0 / main)) +
        (b21 * (21.0 / main)) +
        (b22 * (22.0 / main)) +
        (b24 * (24.0 / main));
  }

  static const double _epsCash = 0.01;
  static const double _epsGold = 0.0005;

  ({String label, Color color}) _sideLabelForBalance(
    double value, {
    required bool isCash,
  }) {
    final eps = isCash ? _epsCash : _epsGold;
    if (value.abs() <= eps) {
      return (label: '—', color: Theme.of(context).hintColor);
    }
    if (value < 0) {
      return (
        label: widget.isArabic ? 'له' : 'Credit',
        color: app_theme.AppColors.success,
      );
    }
    return (
      label: widget.isArabic ? 'عليه' : 'Due',
      color: app_theme.AppColors.error,
    );
  }

  Widget _buildBalancePill({
    required bool isAr,
    required IconData icon,
    required String title,
    required double value,
    required String formattedAbsValue,
    required String unit,
    required bool isCash,
  }) {
    final side = _sideLabelForBalance(value, isCash: isCash);
    final theme = Theme.of(context);
    final isZero = (isCash ? _epsCash : _epsGold) >= value.abs();
    final pillColor = isZero ? theme.hintColor : side.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: pillColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pillColor.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: pillColor),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${side.label}: ',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: pillColor,
            ),
          ),
          Text(
            '$formattedAbsValue $unit',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAndDeleteSupplier(Map<String, dynamic> supplier) async {
    final isAr = widget.isArabic;
    final id = supplier['id'] as int?;
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isAr ? 'تأكيد الإجراء' : 'Confirm action'),
          content: Text(
            isAr
                ? 'سيتم حذف المورد إن لم يكن عليه أي أرصدة أو مسودات. إن كان لديه تاريخ حركات سيتم تعطيله بدلاً من الحذف.'
                : 'Supplier will be deleted if safe; otherwise it will be deactivated when history exists.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isAr ? 'متابعة' : 'Continue'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      final result = await widget.api.deleteSupplier(id);
      if (!mounted) return;
      _loadSuppliers();

      final action = (result['action'] ?? '').toString();
      final msg = action == 'deactivated'
          ? (isAr ? 'تم تعطيل المورد بنجاح' : 'Supplier deactivated')
          : (isAr ? 'تم حذف المورد بنجاح' : 'Supplier deleted');

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete supplier: $e')));
    }
  }

  void _navigateToAddSupplier({Map<String, dynamic>? supplier}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddSupplierScreen(api: widget.api, supplier: supplier),
      ),
    );
    if (result == true) {
      if (!mounted) return;
      _loadSuppliers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'الموردين' : 'Suppliers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _navigateToAddSupplier(),
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _suppliersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('لا يوجد موردين'));
          }

          final rawSuppliers = snapshot.data!;
          final isAr = widget.isArabic;
          final localeName = Localizations.localeOf(context).toString();
          final moneyFmt = NumberFormat('#,##0.00', localeName);
          final weightFmt = NumberFormat('#,##0.000', localeName);

          final query = _searchController.text.trim().toLowerCase();
          final suppliers = rawSuppliers
              .whereType<Map<String, dynamic>>()
              .where((s) {
                if (query.isEmpty) return true;
                final name = (s['name'] ?? '').toString().toLowerCase();
                final code = (s['supplier_code'] ?? '')
                    .toString()
                    .toLowerCase();
                final phone = (s['phone'] ?? '').toString().toLowerCase();
                final tax = (s['tax_number'] ?? '').toString().toLowerCase();
                return name.contains(query) ||
                    code.contains(query) ||
                    phone.contains(query) ||
                    tax.contains(query);
              })
              .where((s) {
                if (!_filterNonZero) return true;
                final cash = _toDouble(s['balance_cash']);
                final goldMain = _goldMainEquivalent(s);
                return cash.abs() > 0.01 || goldMain.abs() > 0.0005;
              })
              .toList();

          final totalCashCredit = suppliers.fold<double>(0.0, (sum, s) {
            final v = _toDouble(s['balance_cash']);
            return v < 0 ? sum + (-v) : sum;
          });
          final totalGoldCreditMain = suppliers.fold<double>(0.0, (sum, s) {
            final v = _goldMainEquivalent(s);
            return v < 0 ? sum + (-v) : sum;
          });
          final activeSuppliersCount = suppliers
              .where((s) => (s['active'] ?? true) == true)
              .length;

          Widget buildSummaryCard({
            required Color background,
            required Color foreground,
            required String title,
            required String value,
          }) {
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                    textAlign: isAr ? TextAlign.right : TextAlign.left,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    value,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                    textAlign: isAr ? TextAlign.right : TextAlign.left,
                  ),
                ],
              ),
            );
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: isAr
                            ? 'بحث بالاسم / الكود / الهاتف / الرقم الضريبي'
                            : 'Search by name/code/phone/tax',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: Text(isAr ? 'غير صفري' : 'Non-zero'),
                          selected: _filterNonZero,
                          onSelected: (v) => setState(() => _filterNonZero = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: buildSummaryCard(
                            background: app_theme.AppColors.primaryGold,
                            foreground: Colors.black87,
                            title: isAr
                                ? 'إجمالي الذهب الدائن (مكافئ $_mainKarat)'
                                : 'Total gold credit ($_mainKarat equiv)',
                            value: weightFmt.format(totalGoldCreditMain),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: buildSummaryCard(
                            background: app_theme.AppColors.success,
                            foreground: Colors.white,
                            title: isAr
                                ? 'إجمالي النقد الدائن'
                                : 'Total cash credit',
                            value: moneyFmt.format(totalCashCredit),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: buildSummaryCard(
                            background: app_theme.AppColors.info,
                            foreground: Colors.white,
                            title: isAr
                                ? 'الموردون النشطون'
                                : 'Active suppliers',
                            value: activeSuppliersCount.toString(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: suppliers.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.filter_alt_off_outlined,
                                size: 44,
                                color: Theme.of(context).hintColor,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                (_filterNonZero && query.isEmpty)
                                    ? (isAr
                                          ? 'لا يوجد موردون بأرصدة معلقة حالياً'
                                          : 'No suppliers with pending balances')
                                    : (isAr
                                          ? 'لا توجد نتائج مطابقة حالياً'
                                          : 'No matching results'),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: suppliers.length,
                        itemBuilder: (context, index) {
                          final supplier = suppliers[index];
                          final supplierId = supplier['id'] as int?;
                          final supplierName = (supplier['name'] ?? '')
                              .toString();
                          final supplierCode = (supplier['supplier_code'] ?? '')
                              .toString();
                          final phone = (supplier['phone'] ?? '').toString();
                          final tax = (supplier['tax_number'] ?? '').toString();
                          final active = (supplier['active'] ?? true) == true;

                          final cash = _toDouble(supplier['balance_cash']);
                          final goldMain = _goldMainEquivalent(supplier);

                          final cashAbs = cash.abs();
                          final goldAbs = goldMain.abs();
                          final cashUnit = isAr ? 'ر.س' : 'SAR';
                          final goldUnit = isAr ? 'جم' : 'g';

                          final theme = Theme.of(context);
                          final actionsEnabled = supplierId != null;

                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                14,
                                16,
                                12,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: isAr
                                          ? CrossAxisAlignment.end
                                          : CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                supplierName,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800,
                                                  color: active
                                                      ? null
                                                      : theme.disabledColor,
                                                ),
                                                textAlign: isAr
                                                    ? TextAlign.right
                                                    : TextAlign.left,
                                              ),
                                            ),
                                            if (supplierCode.isNotEmpty) ...[
                                              const SizedBox(width: 10),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: app_theme
                                                      .AppColors
                                                      .lightGold
                                                      .withValues(alpha: 0.35),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  border: Border.all(
                                                    color: app_theme
                                                        .AppColors
                                                        .darkGold,
                                                    width: 1,
                                                  ),
                                                ),
                                                child: Text(
                                                  supplierCode,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),

                                        if (phone.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 8,
                                            ),
                                            child: Text(
                                              phone,
                                              style: theme.textTheme.bodyMedium,
                                              textAlign: isAr
                                                  ? TextAlign.right
                                                  : TextAlign.left,
                                            ),
                                          ),
                                        if (tax.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Text(
                                              isAr
                                                  ? 'الرقم الضريبي: $tax'
                                                  : 'Tax: $tax',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme.hintColor,
                                                  ),
                                              textAlign: isAr
                                                  ? TextAlign.right
                                                  : TextAlign.left,
                                            ),
                                          ),

                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 10,
                                          alignment: isAr
                                              ? WrapAlignment.end
                                              : WrapAlignment.start,
                                          children: [
                                            _buildBalancePill(
                                              isAr: isAr,
                                              icon: Icons.payments_outlined,
                                              title: isAr ? 'نقد' : 'Cash',
                                              value: cash,
                                              formattedAbsValue: moneyFmt
                                                  .format(cashAbs),
                                              unit: cashUnit,
                                              isCash: true,
                                            ),
                                            _buildBalancePill(
                                              isAr: isAr,
                                              icon: Icons.scale_outlined,
                                              title: isAr
                                                  ? 'ذهب (مكافئ $_mainKarat)'
                                                  : 'Gold ($_mainKarat equiv)',
                                              value: goldMain,
                                              formattedAbsValue: weightFmt
                                                  .format(goldAbs),
                                              unit: goldUnit,
                                              isCash: false,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: theme.dividerColor.withValues(
                                          alpha: 0.6,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.receipt_long),
                                          tooltip: isAr
                                              ? 'كشف حساب المورد'
                                              : 'Supplier Ledger',
                                          color: app_theme.AppColors.info,
                                          onPressed: actionsEnabled
                                              ? () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) =>
                                                          AccountStatementScreen(
                                                            accountId:
                                                                supplierId,
                                                            accountName:
                                                                supplierName,
                                                            entityType:
                                                                'supplier',
                                                          ),
                                                    ),
                                                  );
                                                }
                                              : null,
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_outlined),
                                          tooltip: isAr ? 'تعديل' : 'Edit',
                                          color: app_theme.AppColors.darkGold,
                                          onPressed: () =>
                                              _navigateToAddSupplier(
                                                supplier: supplier,
                                              ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          tooltip: isAr
                                              ? 'حذف/تعطيل'
                                              : 'Delete/Deactivate',
                                          color: app_theme.AppColors.error,
                                          onPressed: () =>
                                              _confirmAndDeleteSupplier(
                                                supplier,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
