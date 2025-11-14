import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../widgets/add_supplier_dialog.dart';

class PurchaseInvoiceScreen extends StatefulWidget {
  final int? supplierId;

  const PurchaseInvoiceScreen({super.key, this.supplierId});

  @override
  State<PurchaseInvoiceScreen> createState() => _PurchaseInvoiceScreenState();
}

class _PurchaseInvoiceScreenState extends State<PurchaseInvoiceScreen> {
  final ApiService _api = ApiService();

  bool _manualPricing = false;
  bool _applyVatOnGold = true;
  String _wagePostingMode = 'expense';
  bool _isLoadingSuppliers = false;
  bool _isSavingInvoice = false;
  bool _showAdvancedPaymentOptions = false;

  List<Map<String, dynamic>> _suppliers = [];
  int? _selectedSupplierId;
  String? _supplierError;

  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId;

  Map<String, dynamic>? _goldPrice;
  List<PurchaseKaratLine> _karatLines = [];

  double _totalWeight = 0;
  double _goldSubtotal = 0;
  double _wageSubtotal = 0;
  double _goldTaxTotal = 0;
  double _wageTaxTotal = 0;
  double _subtotal = 0;
  double _taxTotal = 0;
  double _grandTotal = 0;

  static const double _vatRate = 0.15;

  @override
  void initState() {
    super.initState();
    _selectedSupplierId = widget.supplierId;
    _loadSuppliers();
    _loadGoldPrice();
    _loadDefaultSafeBox();
    _loadSettings();
    _applyTotals(_KaratTotals.zero);
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _api.getSettings();
      if (!mounted) return;

      final rawMode = settings['manufacturing_wage_mode'];
      final normalized = rawMode is String
          ? rawMode.toLowerCase().trim()
          : rawMode?.toString().toLowerCase().trim();

      if (normalized == 'inventory' || normalized == 'expense') {
        setState(() {
          _wagePostingMode = normalized!;
        });
      }
    } catch (e) {
      debugPrint('فشل تحميل الإعدادات: $e');
    }
  }

  Future<void> _loadSuppliers() async {
    setState(() {
      _isLoadingSuppliers = true;
      _supplierError = null;
    });

    try {
      final response = await _api.getSuppliers();
      if (!mounted) return;

      final suppliers = response
          .whereType<Map<String, dynamic>>()
          .map((supplier) {
            final normalized = Map<String, dynamic>.from(supplier);
            normalized['id'] = _parseId(supplier['id']);
            return normalized;
          })
          .where((supplier) => supplier['id'] != null)
          .toList();

      suppliers.sort(
        (a, b) => ((a['name'] ?? '') as String).compareTo(
          (b['name'] ?? '') as String,
        ),
      );

      final int? initialId = _selectedSupplierId ?? widget.supplierId;
      final bool hasInitial =
          initialId != null &&
          suppliers.any((supplier) => supplier['id'] == initialId);

      final int? resolvedId;
      if (hasInitial) {
        resolvedId = initialId;
      } else if (suppliers.length == 1) {
        resolvedId = suppliers.first['id'] as int?;
      } else {
        resolvedId = null;
      }

      setState(() {
        _suppliers = suppliers;
        _selectedSupplierId = resolvedId;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل تحميل الموردين: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingSuppliers = false;
        });
      }
    }
  }

  Future<void> _loadDefaultSafeBox() async {
    try {
      final boxes = await _api.getSafeBoxes();
      final cashBoxes = boxes.where((box) => box.safeType == 'cash').toList();

      if (!mounted) return;

      setState(() {
        _safeBoxes = cashBoxes;
        if (cashBoxes.isNotEmpty) {
          final defaultBox = cashBoxes.firstWhere(
            (box) => box.isDefault == true,
            orElse: () => cashBoxes.first,
          );
          _selectedSafeBoxId = defaultBox.id;
        }
      });
    } catch (e) {
      debugPrint('فشل تحميل الخزائن: $e');
    }
  }

  Future<void> _loadGoldPrice() async {
    try {
      final price = await _api.getGoldPrice();
      if (!mounted) return;

      final enriched = Map<String, dynamic>.from(price);
      final base24 = _toDouble(enriched['price_24k']);
      enriched['price_24k'] = base24;
      enriched['price_22k'] = base24 * 22 / 24;
      enriched['price_21k'] = base24 * 21 / 24;
      enriched['price_18k'] = base24 * 18 / 24;

      setState(() {
        _goldPrice = enriched;
        _applyTotals(_calculateTotals(_karatLines));
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في تحميل سعر الذهب: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _openAddSupplierDialog() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AddSupplierDialog(api: _api),
    );

    if (created == null) return;

    final normalized = Map<String, dynamic>.from(created);
    normalized['id'] = _parseId(created['id']);
    final supplierId = normalized['id'] as int?;
    if (supplierId == null) {
      return;
    }

    setState(() {
      _suppliers.add(normalized);
      _suppliers.sort(
        (a, b) => ((a['name'] ?? '') as String).compareTo(
          (b['name'] ?? '') as String,
        ),
      );
      _selectedSupplierId = supplierId;
      _supplierError = null;
    });
  }

  int? _parseId(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  double _resolveGoldPrice(double karat) {
    if (_goldPrice == null) return 0.0;
    final base24 = _toDouble(_goldPrice!['price_24k']);
    if (base24 <= 0) return 0.0;
    return (base24 * karat) / 24.0;
  }

  _KaratLineSnapshot _snapshotFor(PurchaseKaratLine line) {
    final pricePerGram = _resolveGoldPrice(line.karat);
    final autoGoldValue = line.weightGrams * pricePerGram;
    final autoWageCash = line.weightGrams * line.wagePerGram;
    final autoGoldTax = _applyVatOnGold ? autoGoldValue * _vatRate : 0.0;
    final autoWageTax = autoWageCash * _vatRate;

    final goldValue = _manualPricing
        ? (line.goldValueOverride ?? autoGoldValue)
        : autoGoldValue;
    final wageCash = _manualPricing
        ? (line.wageCashOverride ?? autoWageCash)
        : autoWageCash;
    final goldTax = _manualPricing
        ? (line.goldTaxOverride ?? autoGoldTax)
        : autoGoldTax;
    final wageTax = _manualPricing
        ? (line.wageTaxOverride ?? autoWageTax)
        : autoWageTax;

    return _KaratLineSnapshot(
      line: line,
      pricePerGram: pricePerGram,
      weight: line.weightGrams,
      goldValue: goldValue,
      wageCash: wageCash,
      goldTax: goldTax,
      wageTax: wageTax,
    );
  }

  _KaratTotals _calculateTotals(List<PurchaseKaratLine> lines) {
    double totalWeight = 0;
    double goldSubtotal = 0;
    double wageSubtotal = 0;
    double goldTaxTotal = 0;
    double wageTaxTotal = 0;

    for (final line in lines) {
      final snapshot = _snapshotFor(line);
      totalWeight += snapshot.weight;
      goldSubtotal += snapshot.goldValue;
      wageSubtotal += snapshot.wageCash;
      goldTaxTotal += snapshot.goldTax;
      wageTaxTotal += snapshot.wageTax;
    }

    return _KaratTotals(
      totalWeight: totalWeight,
      goldSubtotal: goldSubtotal,
      wageSubtotal: wageSubtotal,
      goldTaxTotal: goldTaxTotal,
      wageTaxTotal: wageTaxTotal,
    );
  }

  void _applyTotals(_KaratTotals totals) {
    _totalWeight = _round(totals.totalWeight, 3);
    _goldSubtotal = _round(totals.goldSubtotal, 2);
    _wageSubtotal = _round(totals.wageSubtotal, 2);
    _goldTaxTotal = _round(totals.goldTaxTotal, 2);
    _wageTaxTotal = _round(totals.wageTaxTotal, 2);
    _subtotal = _round(_goldSubtotal + _wageSubtotal, 2);
    _taxTotal = _round(_goldTaxTotal + _wageTaxTotal, 2);
    _grandTotal = _round(_subtotal + _taxTotal, 2);
  }

  void _updateLines(List<PurchaseKaratLine> lines) {
    final totals = _calculateTotals(lines);
    setState(() {
      _karatLines = lines;
      _applyTotals(totals);
    });
  }

  Future<void> _addKaratLine() async {
    final line = await _showKaratLineDialog();
    if (line == null) return;

    _updateLines([..._karatLines, line]);
  }

  Future<void> _editKaratLine(int index) async {
    final existing = _karatLines[index];
    final line = await _showKaratLineDialog(existing: existing);
    if (line == null) return;

    final updated = [..._karatLines];
    updated[index] = line;
    _updateLines(updated);
  }

  Future<void> _removeKaratLine(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('حذف سطر العيار'),
          content: const Text('هل أنت متأكد من حذف هذا السطر؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('حذف'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    final updated = [..._karatLines]..removeAt(index);
    _updateLines(updated);
  }

  Map<String, double> _aggregateWeightByKarat() {
    final Map<String, double> summary = {};
    for (final line in _karatLines) {
      final key = _normalizeKaratKey(line.karat);
      summary[key] = (summary[key] ?? 0) + line.weightGrams;
    }
    return summary;
  }

  String _normalizeKaratKey(double karat) {
    if (karat.isNaN || !karat.isFinite) return '0';
    final rounded = karat.round();
    if ((karat - rounded).abs() < 0.0001) {
      return rounded.toString();
    }
    return _round(karat, 2).toString();
  }

  double _round(double value, int fractionDigits) {
    final double mod = math.pow(10.0, fractionDigits).toDouble();
    return (value * mod).round() / mod;
  }

  String _formatCurrency(double value) => '${value.toStringAsFixed(2)} ر.س';

  String _formatWeight(double value) => '${value.toStringAsFixed(3)} جم';

  bool _validateBeforeSave() {
    if (_selectedSupplierId == null) {
      setState(() {
        _supplierError = 'يجب اختيار مورد';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى اختيار المورد قبل الحفظ')),
      );
      return false;
    }

    if (_karatLines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أضف سطر عيار واحد على الأقل قبل الحفظ')),
      );
      return false;
    }

    if (_totalWeight <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('إجمالي الوزن يجب أن يكون أكبر من صفر')),
      );
      return false;
    }

    return true;
  }

  Map<String, dynamic> _buildInvoicePayload() {
    final linePayloads = _karatLines.map((line) {
      final snapshot = _snapshotFor(line);
      return {
        'karat': line.karat,
        'weight_grams': _round(snapshot.weight, 3),
        'gold_value_cash': _round(snapshot.goldValue, 2),
        'manufacturing_wage_cash': _round(snapshot.wageCash, 2),
        'gold_tax': _round(snapshot.goldTax, 2),
        'wage_tax': _round(snapshot.wageTax, 2),
        if (line.description?.isNotEmpty ?? false)
          'description': line.description,
      };
    }).toList();

    final weightByKarat = _aggregateWeightByKarat();
    final supplierGoldLines = weightByKarat.entries
        .map(
          (entry) => {
            'karat': double.tryParse(entry.key) ?? 0,
            'weight': _round(entry.value, 3),
          },
        )
        .toList();

    return {
      'supplier_id': _selectedSupplierId,
      'invoice_type': 'شراء من مورد',
      'date': DateTime.now().toIso8601String(),
      'total': _round(_grandTotal, 2),
      'total_cost': _round(_subtotal, 2),
      'total_tax': _round(_taxTotal, 2),
      'total_weight': _round(_totalWeight, 3),
      'gold_type': 'new',
      'gold_subtotal': _round(_goldSubtotal, 2),
      'wage_subtotal': _round(_wageSubtotal, 2),
      'gold_tax_total': _round(_goldTaxTotal, 2),
      'wage_tax_total': _round(_wageTaxTotal, 2),
      'apply_gold_tax': _applyVatOnGold,
      'karat_lines': linePayloads,
      'items': [],
      'supplier_gold_lines': supplierGoldLines,
      'supplier_gold_weights': weightByKarat.map(
        (key, value) => MapEntry(key, _round(value, 3)),
      ),
      'manufacturing_wage_cash': _round(_wageSubtotal, 2),
      'wage_cash': _round(_wageSubtotal, 2),
      'valuation_cash_total': _round(_goldSubtotal, 2),
      'gold_tax': _round(_goldTaxTotal, 2),
      'wage_tax': _round(_wageTaxTotal, 2),
      'wage_posting_mode': _wagePostingMode,
      'valuation': {
        'cash_total': _round(_goldSubtotal, 2),
        'weight_by_karat': weightByKarat.map(
          (key, value) => MapEntry(key, _round(value, 3)),
        ),
        'wage_total': _round(_wageSubtotal, 2),
      },
      if (_selectedSafeBoxId != null) 'safe_box_id': _selectedSafeBoxId,
    };
  }

  Future<void> _saveInvoice() async {
    if (_isSavingInvoice) return;
    if (!_validateBeforeSave()) return;

    setState(() {
      _isSavingInvoice = true;
    });

    try {
      final payload = _buildInvoicePayload();
      await _api.addInvoice(payload);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم حفظ فاتورة الشراء بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل حفظ الفاتورة: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSavingInvoice = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isWideLayout = size.width >= 1100;

    final leftColumn = <Widget>[
      _buildSupplierSection(),
      const SizedBox(height: 24),
      _buildKaratLinesSection(),
    ];

    final rightColumn = <Widget>[
      _buildGoldPriceCard(),
      const SizedBox(height: 24),
      _buildPricingModeCard(),
      const SizedBox(height: 24),
      _buildTotalsCard(),
      const SizedBox(height: 24),
      _buildWagePostingModeCard(),
      const SizedBox(height: 24),
      _buildSettlementCard(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('فاتورة شراء جديدة'),
        actions: [
          IconButton(
            tooltip: 'تحديث سعر الذهب',
            icon: const Icon(Icons.refresh),
            onPressed: _loadGoldPrice,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWideLayout)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 7,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: leftColumn,
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: rightColumn,
                      ),
                    ),
                  ],
                )
              else ...[
                ...leftColumn,
                const SizedBox(height: 24),
                ...rightColumn,
              ],
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: FilledButton.icon(
                    onPressed: _isSavingInvoice ? null : _saveInvoice,
                    icon: _isSavingInvoice
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.save_alt),
                    label: Text(
                      _isSavingInvoice ? 'جارٍ الحفظ...' : 'حفظ الفاتورة',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      textStyle: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSupplierSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: isDark ? 2 : 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.25 : 0.08),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 
                      isDark ? 0.18 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.handshake_outlined,
                    color: colorScheme.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'بيانات المورد',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'اختر المورد أو أضف مورداً جديداً قبل متابعة إدخال الأوزان.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_isLoadingSuppliers)
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!_isLoadingSuppliers) ...[
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _openAddSupplierDialog,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('مورد جديد'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      textStyle: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<int>(
              value: _selectedSupplierId,
              items: _suppliers
                  .map(
                    (supplier) => DropdownMenuItem<int>(
                      value: supplier['id'] as int,
                      child: Text(supplier['name']?.toString() ?? 'بدون اسم'),
                    ),
                  )
                  .toList(),
              decoration: InputDecoration(
                labelText: 'اختر المورد',
                border: const OutlineInputBorder(),
                prefixIcon: Icon(
                  Icons.store_mall_directory,
                  color: colorScheme.primary,
                ),
                errorText: _supplierError,
              ),
              dropdownColor: theme.cardColor,
              icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
              onChanged: (value) {
                setState(() {
                  _selectedSupplierId = value;
                  _supplierError = null;
                });
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _loadSuppliers,
                  icon: const Icon(Icons.refresh),
                  label: const Text('تحديث قائمة الموردين'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
                const Spacer(),
                if (_safeBoxes.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _showAdvancedPaymentOptions =
                            !_showAdvancedPaymentOptions;
                      });
                    },
                    icon: Icon(
                      _showAdvancedPaymentOptions
                          ? Icons.settings
                          : Icons.settings_outlined,
                      color: _showAdvancedPaymentOptions
                          ? colorScheme.primary
                          : colorScheme.primary.withValues(alpha: 0.6),
                    ),
                    label: Text(
                      _showAdvancedPaymentOptions
                          ? 'إخفاء خيارات الدفع'
                          : 'خيارات الدفع',
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
              ],
            ),
            if (_safeBoxes.isNotEmpty && _showAdvancedPaymentOptions) ...[
              const SizedBox(height: 20),
              DropdownButtonFormField<int>(
                value: _selectedSafeBoxId,
                decoration: const InputDecoration(
                  labelText: 'الخزينة المستخدمة للدفع',
                  border: OutlineInputBorder(),
                ),
                items: _safeBoxes
                    .map(
                      (box) => DropdownMenuItem<int>(
                        value: box.id,
                        child: Row(
                          children: [
                            Icon(box.icon, color: box.typeColor, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(box.name)),
                            if (box.isDefault)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                margin: const EdgeInsetsDirectional.only(
                                  start: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'افتراضي',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedSafeBoxId = value;
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGoldPriceCard() {
    if (_goldPrice == null) {
      return Card(
        color: const Color(0xFFFFF3CD),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'سعر الذهب',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'لم يتم تحميل سعر الذهب بعد. استخدم زر التحديث في الأعلى لإعادة المحاولة.',
              ),
            ],
          ),
        ),
      );
    }

    final chips = <Widget>[
      _buildPriceChip('عيار 24', _goldPrice!['price_24k']),
      _buildPriceChip('عيار 22', _goldPrice!['price_22k']),
      _buildPriceChip('عيار 21', _goldPrice!['price_21k']),
      _buildPriceChip('عيار 18', _goldPrice!['price_18k']),
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      color: const Color(0xFFFAF5E4),
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'سعر الذهب',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, children: chips),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceChip(String label, dynamic value) {
    final price = _toDouble(value);
    final display = price > 0 ? price.toStringAsFixed(2) : '-';
    return Chip(
      label: Text('$label: $display ر.س'),
      backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.18),
    );
  }

  Widget _buildPricingModeCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'طريقة التسعير',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ToggleButtons(
              isSelected: [_manualPricing, !_manualPricing],
              borderRadius: BorderRadius.circular(12),
              onPressed: (index) {
                final manual = index == 0;
                if (manual == _manualPricing) return;
                setState(() {
                  _manualPricing = manual;
                  _applyTotals(_calculateTotals(_karatLines));
                });
              },
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('تسعير يدوي لكل عيار'),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('تسعير تلقائي من سعر الذهب'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _manualPricing
                  ? 'يمكنك إدخال القيم النقدية والضرائب لكل عيار يدوياً.'
                  : 'سيتم حساب قيمة الذهب والضرائب تلقائياً اعتماداً على الوزن وسعر الذهب الحالي.',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalsCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      color: const Color(0xFFFFFAF0),
      elevation: isDark ? 1 : 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ملخص الفاتورة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _applyVatOnGold,
              title: const Text('تطبيق ضريبة القيمة المضافة على قيمة الذهب'),
              subtitle: Text(
                _applyVatOnGold
                    ? 'سيتم احتساب الضريبة على قيمة الذهب وأجور المصنعية.'
                    : 'سيتم احتساب الضريبة على أجور المصنعية فقط.',
              ),
              onChanged: (value) {
                setState(() {
                  _applyVatOnGold = value;
                  _applyTotals(_calculateTotals(_karatLines));
                });
              },
            ),
            const SizedBox(height: 12),
            _buildSummaryRow('إجمالي الوزن', _formatWeight(_totalWeight)),
            _buildSummaryRow(
              'قيمة الذهب (قبل الضريبة)',
              _formatCurrency(_goldSubtotal),
            ),
            _buildSummaryRow('أجور المصنعية', _formatCurrency(_wageSubtotal)),
            const Divider(),
            _buildSummaryRow('ضريبة على الذهب', _formatCurrency(_goldTaxTotal)),
            _buildSummaryRow(
              'ضريبة على الأجور',
              _formatCurrency(_wageTaxTotal),
            ),
            const Divider(),
            _buildSummaryRow(
              'الإجمالي قبل الضريبة',
              _formatCurrency(_subtotal),
            ),
            _buildSummaryRow('إجمالي الضريبة', _formatCurrency(_taxTotal)),
            const Divider(),
            _buildSummaryRow(
              'الإجمالي الكلي',
              _formatCurrency(_grandTotal),
              highlight: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWagePostingModeCard() {
    final selection = _wagePostingMode;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'معالجة أجور المصنعية',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ToggleButtons(
              isSelected: [selection == 'expense', selection == 'inventory'],
              borderRadius: BorderRadius.circular(12),
              onPressed: (index) {
                final mode = index == 0 ? 'expense' : 'inventory';
                if (mode == _wagePostingMode) {
                  return;
                }
                setState(() {
                  _wagePostingMode = mode;
                });
              },
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('تحميل على المصروفات'),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('رسملة ضمن المخزون'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              selection == 'inventory'
                  ? 'سيتم رسملة أجور المصنعية ضمن حساب المخزون أو الحساب المحدد في الربط المحاسبي.'
                  : 'سيتم تحميل أجور المصنعية مباشرةً على حساب المصروفات أو تكلفة المبيعات.',
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettlementCard() {
    final weightSummary = _aggregateWeightByKarat();
    final cashDue = _round(_wageSubtotal + _goldTaxTotal + _wageTaxTotal, 2);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'مستحقات المورد',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildMetricTile(
                  icon: Icons.scale,
                  label: 'ذهب مستحق',
                  value: _totalWeight > 0
                      ? _formatWeight(_totalWeight)
                      : '0.000 جم',
                  iconColor: const Color(0xFFDAA520),
                ),
                _buildMetricTile(
                  icon: Icons.payments_outlined,
                  label: 'نقد مستحق',
                  value: _formatCurrency(cashDue),
                  iconColor: Colors.green.shade700,
                ),
                _buildMetricTile(
                  icon: Icons.design_services,
                  label: 'أجور مصنعية',
                  value: _formatCurrency(_wageSubtotal),
                ),
                _buildMetricTile(
                  icon: Icons.receipt_long,
                  label: 'إجمالي الضرائب',
                  value: _formatCurrency(_goldTaxTotal + _wageTaxTotal),
                ),
              ],
            ),
            if (weightSummary.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'توزيع العيارات',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: weightSummary.entries.map((entry) {
                  final karatLabel = entry.key;
                  final weightValue = entry.value;
                  return Chip(
                    backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.12),
                    label: Text(
                      'عيار $karatLabel: ${_formatWeight(weightValue)}',
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile({
    required IconData icon,
    required String label,
    required String value,
    Color? iconColor,
  }) {
    final Color resolvedIconColor = iconColor ?? Colors.blueGrey.shade600;
    return Container(
      constraints: const BoxConstraints(minWidth: 160),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: resolvedIconColor.withValues(alpha: 0.12),
            child: Icon(icon, color: resolvedIconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(
    String label,
    String value, {
    bool highlight = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: highlight 
                  ? (isDark ? Colors.green[300] : Colors.green[700])
                  : (isDark ? Colors.white : Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKaratLinesSection() {
    final snapshots = _karatLines.map(_snapshotFor).toList();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'أسطر العيار',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _addKaratLine,
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة سطر'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_karatLines.isNotEmpty) _buildKaratSummaryChips(),
            if (_karatLines.isNotEmpty) const SizedBox(height: 12),
            if (snapshots.isEmpty)
              _buildKaratLinesEmptyState()
            else
              _buildKaratLinesTable(snapshots),
          ],
        ),
      ),
    );
  }

  Widget _buildKaratSummaryChips() {
    final summary = _aggregateWeightByKarat();
    final entries = summary.entries.toList()
      ..sort(
        (a, b) => (double.tryParse(a.key) ?? 0).compareTo(
          double.tryParse(b.key) ?? 0,
        ),
      );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries
          .map(
            (entry) => Chip(
              backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.15),
              label: Text('عيار ${entry.key}: ${_formatWeight(entry.value)}'),
            ),
          )
          .toList(),
    );
  }

  Widget _buildKaratLinesEmptyState() {
    return Column(
      children: const [
        SizedBox(height: 16),
        Icon(Icons.balance, size: 64, color: Colors.grey),
        SizedBox(height: 12),
        Text(
          'لم يتم إضافة أسطر عيار بعد. استخدم زر "إضافة سطر" لبدء إدخال الأوزان.',
        ),
      ],
    );
  }

  Widget _buildKaratLinesTable(List<_KaratLineSnapshot> snapshots) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('العيار')),
          DataColumn(label: Text('الوزن (جم)')),
          DataColumn(label: Text('سعر/جرام')),
          DataColumn(label: Text('قيمة الذهب')),
          DataColumn(label: Text('أجور المصنعية')),
          DataColumn(label: Text('ضريبة الذهب')),
          DataColumn(label: Text('ضريبة الأجور')),
          DataColumn(label: Text('الإجمالي')),
          DataColumn(label: Text('ملاحظات')),
          DataColumn(label: Text('إجراءات')),
        ],
        rows: [
          for (int index = 0; index < snapshots.length; index++)
            _buildKaratLineRow(snapshots[index], index),
        ],
      ),
    );
  }

  DataRow _buildKaratLineRow(_KaratLineSnapshot snapshot, int index) {
    final description = snapshot.line.description;
    return DataRow(
      cells: [
        DataCell(Text(snapshot.line.karat.toStringAsFixed(0))),
        DataCell(Text(snapshot.weight.toStringAsFixed(3))),
        DataCell(
          Text(
            snapshot.pricePerGram > 0
                ? snapshot.pricePerGram.toStringAsFixed(2)
                : '-',
          ),
        ),
        DataCell(Text(snapshot.goldValue.toStringAsFixed(2))),
        DataCell(Text(snapshot.wageCash.toStringAsFixed(2))),
        DataCell(Text(snapshot.goldTax.toStringAsFixed(2))),
        DataCell(Text(snapshot.wageTax.toStringAsFixed(2))),
        DataCell(Text(snapshot.total.toStringAsFixed(2))),
        DataCell(
          description == null || description.isEmpty
              ? const Text('-')
              : Tooltip(
                  message: description,
                  child: Text(
                    description,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
        ),
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'تعديل',
                icon: const Icon(Icons.edit),
                onPressed: () => _editKaratLine(index),
              ),
              IconButton(
                tooltip: 'حذف',
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () => _removeKaratLine(index),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<PurchaseKaratLine?> _showKaratLineDialog({
    PurchaseKaratLine? existing,
  }) async {
    final weightController = TextEditingController(
      text: existing != null ? existing.weightGrams.toStringAsFixed(3) : '',
    );
    final wagePerGramController = TextEditingController(
      text: existing != null ? existing.wagePerGram.toStringAsFixed(2) : '0',
    );
    final goldValueController = TextEditingController(
      text: existing?.goldValueOverride != null
          ? existing!.goldValueOverride!.toStringAsFixed(2)
          : '',
    );
    final wageCashController = TextEditingController(
      text: existing?.wageCashOverride != null
          ? existing!.wageCashOverride!.toStringAsFixed(2)
          : '',
    );
    final goldTaxController = TextEditingController(
      text: existing?.goldTaxOverride != null
          ? existing!.goldTaxOverride!.toStringAsFixed(2)
          : '',
    );
    final wageTaxController = TextEditingController(
      text: existing?.wageTaxOverride != null
          ? existing!.wageTaxOverride!.toStringAsFixed(2)
          : '',
    );
    final notesController = TextEditingController(
      text: existing?.description ?? '',
    );

    double karat = existing?.karat ?? 21;

    final result = await showDialog<PurchaseKaratLine>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final weight = double.tryParse(weightController.text) ?? 0;
            final wagePerGram =
                double.tryParse(wagePerGramController.text) ?? 0;
            final autoPricePerGram = _resolveGoldPrice(karat);
            final autoGoldValue = weight * autoPricePerGram;
            final autoWageCash = weight * wagePerGram;
            final autoGoldTax = _applyVatOnGold
                ? autoGoldValue * _vatRate
                : 0.0;
            final autoWageTax = autoWageCash * _vatRate;

            final manualGoldValue = double.tryParse(goldValueController.text);
            final manualWageCash = double.tryParse(wageCashController.text);
            final manualGoldTax = double.tryParse(goldTaxController.text);
            final manualWageTax = double.tryParse(wageTaxController.text);

            final effectiveGoldValue = _manualPricing
                ? (manualGoldValue ?? autoGoldValue)
                : autoGoldValue;
            final effectiveWageCash = _manualPricing
                ? (manualWageCash ?? autoWageCash)
                : autoWageCash;
            final effectiveGoldTax = _manualPricing
                ? (manualGoldTax ?? autoGoldTax)
                : autoGoldTax;
            final effectiveWageTax = _manualPricing
                ? (manualWageTax ?? autoWageTax)
                : autoWageTax;
            final total =
                effectiveGoldValue +
                effectiveWageCash +
                effectiveGoldTax +
                effectiveWageTax;

            return AlertDialog(
              title: Text(
                existing == null ? 'إضافة سطر عيار' : 'تعديل سطر العيار',
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<double>(
                      value: karat,
                      decoration: const InputDecoration(
                        labelText: 'العيار',
                        border: OutlineInputBorder(),
                      ),
                      items: const [18.0, 21.0, 22.0, 24.0]
                          .map(
                            (value) => DropdownMenuItem<double>(
                              value: value,
                              child: Text(value.toStringAsFixed(0)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setDialogState(() {
                          karat = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: weightController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'الوزن (جرام)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.scale),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: wagePerGramController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'أجرة المصنعية (ريال/جرام)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.build),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    if (_manualPricing) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: goldValueController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'قيمة الذهب (ريال)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.attach_money),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: wageCashController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'أجور المصنعية (ريال)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.construction),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: goldTaxController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^[0-9]*\.?[0-9]*$'),
                                ),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'ضريبة الذهب',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: wageTaxController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'^[0-9]*\.?[0-9]*$'),
                                ),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'ضريبة الأجور',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) => setDialogState(() {}),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات (اختياري)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.note_alt_outlined),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 16),
                    Card(
                      color: const Color(0xFFFAF5E4),
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'معاينة السطر',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            _previewRow(
                              'قيمة الذهب',
                              _formatCurrency(effectiveGoldValue),
                            ),
                            _previewRow(
                              'أجور المصنعية',
                              _formatCurrency(effectiveWageCash),
                            ),
                            _previewRow(
                              'ضريبة الذهب',
                              _formatCurrency(effectiveGoldTax),
                            ),
                            _previewRow(
                              'ضريبة الأجور',
                              _formatCurrency(effectiveWageTax),
                            ),
                            const Divider(),
                            _previewRow(
                              'الإجمالي',
                              _formatCurrency(total),
                              highlight: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final weightValue =
                        double.tryParse(weightController.text) ?? 0;
                    final wageValue =
                        double.tryParse(wagePerGramController.text) ?? 0;
                    if (weightValue <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('يرجى إدخال وزن صحيح')),
                      );
                      return;
                    }
                    if (wageValue < 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('لا يمكن أن تكون أجرة المصنعية سالبة'),
                        ),
                      );
                      return;
                    }

                    Navigator.of(dialogContext).pop(
                      PurchaseKaratLine(
                        karat: karat,
                        weightGrams: weightValue,
                        wagePerGram: wageValue,
                        goldValueOverride: _manualPricing
                            ? manualGoldValue
                            : null,
                        wageCashOverride: _manualPricing
                            ? manualWageCash
                            : null,
                        goldTaxOverride: _manualPricing ? manualGoldTax : null,
                        wageTaxOverride: _manualPricing ? manualWageTax : null,
                        description: notesController.text.trim().isEmpty
                            ? null
                            : notesController.text.trim(),
                      ),
                    );
                  },
                  child: const Text('حفظ'),
                ),
              ],
            );
          },
        );
      },
    );

    weightController.dispose();
    wagePerGramController.dispose();
    goldValueController.dispose();
    wageCashController.dispose();
    goldTaxController.dispose();
    wageTaxController.dispose();
    notesController.dispose();

    return result;
  }

  Widget _previewRow(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: TextStyle(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
              color: highlight ? Colors.green[800] : Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}

class PurchaseKaratLine {
  final double karat;
  final double weightGrams;
  final double wagePerGram;
  final double? goldValueOverride;
  final double? wageCashOverride;
  final double? goldTaxOverride;
  final double? wageTaxOverride;
  final String? description;

  const PurchaseKaratLine({
    required this.karat,
    required this.weightGrams,
    required this.wagePerGram,
    this.goldValueOverride,
    this.wageCashOverride,
    this.goldTaxOverride,
    this.wageTaxOverride,
    this.description,
  });

  PurchaseKaratLine copyWith({
    double? karat,
    double? weightGrams,
    double? wagePerGram,
    double? goldValueOverride,
    double? wageCashOverride,
    double? goldTaxOverride,
    double? wageTaxOverride,
    String? description,
  }) {
    return PurchaseKaratLine(
      karat: karat ?? this.karat,
      weightGrams: weightGrams ?? this.weightGrams,
      wagePerGram: wagePerGram ?? this.wagePerGram,
      goldValueOverride: goldValueOverride ?? this.goldValueOverride,
      wageCashOverride: wageCashOverride ?? this.wageCashOverride,
      goldTaxOverride: goldTaxOverride ?? this.goldTaxOverride,
      wageTaxOverride: wageTaxOverride ?? this.wageTaxOverride,
      description: description ?? this.description,
    );
  }
}

class _KaratLineSnapshot {
  final PurchaseKaratLine line;
  final double pricePerGram;
  final double weight;
  final double goldValue;
  final double wageCash;
  final double goldTax;
  final double wageTax;

  _KaratLineSnapshot({
    required this.line,
    required this.pricePerGram,
    required this.weight,
    required this.goldValue,
    required this.wageCash,
    required this.goldTax,
    required this.wageTax,
  });

  double get total => goldValue + wageCash + goldTax + wageTax;
}

class _KaratTotals {
  final double totalWeight;
  final double goldSubtotal;
  final double wageSubtotal;
  final double goldTaxTotal;
  final double wageTaxTotal;

  const _KaratTotals({
    required this.totalWeight,
    required this.goldSubtotal,
    required this.wageSubtotal,
    required this.goldTaxTotal,
    required this.wageTaxTotal,
  });

  static const _KaratTotals zero = _KaratTotals(
    totalWeight: 0,
    goldSubtotal: 0,
    wageSubtotal: 0,
    goldTaxTotal: 0,
    wageTaxTotal: 0,
  );

  double get subtotal => goldSubtotal + wageSubtotal;
  double get taxTotal => goldTaxTotal + wageTaxTotal;
  double get grandTotal => subtotal + taxTotal;
}
