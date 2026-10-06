import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../models/safe_box_model.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/adaptive_invoice_summary_dialog.dart';
import '../widgets/invoice_settings_sheet.dart';
import '../widgets/original_invoice_selector.dart';
import '../widgets/party_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';
import '../utils/invoice_direct_print.dart';
import '../utils/purchase_readiness.dart';
import '../utils/supplier_position.dart';
import '../utils/wage_treatment.dart';
import 'add_supplier_screen.dart';
import '../utils.dart';

enum _PurchaseSettlementMode { credit, barter, partial }

class _GoldSettlementLine {
  int? safeBoxId;
  int? karat;
  final TextEditingController weightController;
  double commissionPerGram = 0;
  String commissionDirection = ''; // '' = بدون | 'earn' = عمولة | 'pay' = رسوم
  final TextEditingController commissionController;

  _GoldSettlementLine({this.safeBoxId, this.karat, String initialWeight = ''})
    : weightController = TextEditingController(text: initialWeight),
      commissionController = TextEditingController();

  double commissionTotal(double weight) => weight * commissionPerGram;

  void dispose() {
    weightController.dispose();
    commissionController.dispose();
  }
}

class _CommissionToggleButton extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _CommissionToggleButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? effectiveColor.withOpacity(0.15)
              : Colors.transparent,
          border: Border.all(
            color: selected ? effectiveColor : theme.colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected
                ? effectiveColor
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class PurchaseInvoiceScreen extends StatefulWidget {
  final int? supplierId;
  final bool supplierReturnMode;
  final int? originalInvoiceId;
  final int? editInvoiceId;
  final Map<String, dynamic>? editInvoiceData;

  /// The server; tests pass a fake.
  final ApiService? apiService;

  const PurchaseInvoiceScreen({
    super.key,
    this.apiService,
    this.supplierId,
    this.supplierReturnMode = false,
    this.originalInvoiceId,
    this.editInvoiceId,
    this.editInvoiceData,
  });

  @override
  State<PurchaseInvoiceScreen> createState() => _PurchaseInvoiceScreenState();
}

class _PurchaseInvoiceScreenState extends State<PurchaseInvoiceScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();

  bool _manualPricing = false;
  bool _applyVatOnGold = false;

  /// The company's wage treatment, read from the server (ADR-039); null
  /// until the settings answer. The screen shows it; it does not choose it.
  String? _wageMode;
  bool _isLoadingSuppliers = false;
  bool _isSavingInvoice = false;

  /// Up from the save press until the flow ends -- through the review, which
  /// waits on the supplier's statement -- so a second press opens nothing.
  bool _saveFlowOpen = false;

  bool _uiLockPriceEdits = false;

  /// This invoice's VAT decision (PURCHASE-VAT-1): null follows the supplier
  /// -- with a tax number it starts with VAT, without one it starts without;
  /// true / false is the user's choice for this invoice alone.
  bool? _vatChoice;

  bool get _supplierHasTaxNumber =>
      (_selectedSupplierMap()?['tax_number'] ?? '')
          .toString()
          .trim()
          .isNotEmpty;

  bool get _vatApplied => _vatChoice ?? _supplierHasTaxNumber;
  bool _uiAutoOpenPrintAfterSave = false;
  String _uiPaperSize = 'A4';

  bool _checkedLocalDraft = false;

  // What the server enforces on gold settlements (from /settings and the
  // signed-in employee): employee gold safes, and no gold on unposted invoices.
  bool _employeeGoldSafesEnabled = false;
  int? _employeeGoldSafeId;
  bool _autoPostInvoices = true;

  // Where each readiness reason is fixed, to bring it into view.
  final _supplierSectionKey = GlobalKey();
  final _itemsSectionKey = GlobalKey();
  final _karatSectionKey = GlobalKey();
  final _paymentSectionKey = GlobalKey();

  // Supplier return (مرتجع شراء (مورد))
  Map<String, dynamic>? _selectedOriginalInvoice;
  bool _isLoadingOriginalInvoiceDetails = false;
  String? _originalInvoiceDetailsError;

  bool get _isSupplierReturnMode => widget.supplierReturnMode == true;
  bool get _isEditMode => widget.editInvoiceId != null;

  // Branches (فروع المعرض/المحل)
  bool _isLoadingBranches = false;
  List<Map<String, dynamic>> _branches = [];
  int? _selectedBranchId;
  String? _branchError;

  List<Map<String, dynamic>> _suppliers = [];
  int? _selectedSupplierId;
  String? _supplierError;

  // Payment Methods
  List<Map<String, dynamic>> _paymentMethods = [];
  int? _selectedPaymentMethodId;

  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId;

  // Settlement
  _PurchaseSettlementMode _settlementMode = _PurchaseSettlementMode.credit;
  final TextEditingController _cashPaidController = TextEditingController();
  final TextEditingController _goldPaidWeightController =
      TextEditingController();
  List<SafeBoxModel> _goldSafeBoxes = [];
  int? _selectedGoldSafeBoxId;
  int _selectedGoldPaidKarat = 21;

  final List<_GoldSettlementLine> _goldSettlementLines =
      <_GoldSettlementLine>[];

  // حقول gold24k القديمة — محتفظ بها للتوافق مع draft restore
  bool _gold24kSettlement = false;
  final TextEditingController _gold24kCommissionPerGramController =
      TextEditingController(text: '0.00');

  bool get _isGoldSettlementContext =>
      _settlementMode == _PurchaseSettlementMode.partial ||
      _settlementMode == _PurchaseSettlementMode.barter;

  void _refreshGoldPaidTotalFromLines() {
    if (!_isGoldSettlementContext) {
      _goldPaidWeightController.text = '0.000';
      return;
    }

    final total = _goldSettlementLinesTotalMainEquivalent();
    _goldPaidWeightController.text = total.toStringAsFixed(3);
  }

  int _effectiveGoldSettlementLineKarat(_GoldSettlementLine line) {
    final raw = line.karat ?? _selectedGoldPaidKarat;
    if ({18, 21, 22, 24}.contains(raw)) return raw;
    final main = _mainKaratFromSettings();
    return {18, 21, 22, 24}.contains(main) ? main : 21;
  }

  double _goldSettlementLineWeight(_GoldSettlementLine line) {
    final normalized = normalizeNumber(line.weightController.text).trim();
    return _toDouble(normalized);
  }

  double _goldSettlementLinesTotalMainEquivalent() {
    final mainKarat = _mainKaratFromSettings();
    if (mainKarat <= 0) return 0.0;

    double total = 0.0;
    for (final line in _goldSettlementLines) {
      final weight = _goldSettlementLineWeight(line);
      if (weight <= 0) continue;
      final karat = _effectiveGoldSettlementLineKarat(line);
      total += weight * (karat / mainKarat);
    }
    return _round(total, 3);
  }

  bool _isSettlementLineEffectivelyEmpty(_GoldSettlementLine line) {
    final safeId = line.safeBoxId;
    final raw = normalizeNumber(line.weightController.text).trim();
    final weight = _toDouble(raw);
    return safeId == null && (raw.isEmpty || weight <= 0);
  }

  void _clearGoldSettlementLines() {
    for (final line in _goldSettlementLines) {
      line.dispose();
    }
    _goldSettlementLines.clear();
  }

  SafeBoxModel? _findGoldSafeBoxById(int? safeBoxId) {
    if (safeBoxId == null) return null;
    try {
      return _goldSafeBoxes.firstWhere((b) => b.id == safeBoxId);
    } catch (_) {
      return null;
    }
  }

  SafeBoxModel? _findCashSafeBoxById(int? safeBoxId) {
    if (safeBoxId == null) return null;
    try {
      return _safeBoxes.firstWhere((b) => b.id == safeBoxId);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _selectedSupplierMap() {
    final selectedId = _selectedSupplierId;
    if (selectedId == null) return null;
    try {
      return _suppliers.firstWhere((s) => _parseId(s['id']) == selectedId);
    } catch (_) {
      return null;
    }
  }

  int? _selectedSupplierDefaultSafeBoxId() {
    final supplier = _selectedSupplierMap();
    if (supplier == null) return null;
    return _parseId(supplier['default_safe_box_id']);
  }

  bool _goldSafeIdExists(int? safeBoxId) {
    if (safeBoxId == null) return false;
    return _goldSafeBoxes.any((b) => b.id == safeBoxId);
  }

  int? _preferredGoldSafeIdForNewLine(int defaultKarat) {
    final supplierDefaultId = _selectedSupplierDefaultSafeBoxId();
    if (supplierDefaultId == null) return null;

    final goldSafe = _findGoldSafeBoxById(supplierDefaultId);
    if (goldSafe == null) return null;

    final fixed = goldSafe.karat;
    if (fixed != null && fixed != 0) {
      return supplierDefaultId;
    }

    return _goldSafeAcceptsKarat(goldSafe, defaultKarat)
        ? supplierDefaultId
        : null;
  }

  void _applySupplierDefaultSafeBoxSelections({bool onlyWhenEmpty = true}) {
    if (!mounted) return;
    final supplierDefaultId = _selectedSupplierDefaultSafeBoxId();
    if (supplierDefaultId == null) return;

    bool changed = false;

    // Cash SafeBox preference (for partial cash payments).
    final cashBox = _findCashSafeBoxById(supplierDefaultId);
    final cashType = cashBox?.safeType;
    if (cashBox != null && (cashType == 'cash' || cashType == 'bank')) {
      if (!onlyWhenEmpty || _selectedSafeBoxId == null) {
        _selectedSafeBoxId = cashBox.id;
        changed = true;
      }
    }

    // Gold SafeBox preference (for gold settlements).
    if (_isGoldSettlementContext && _goldSafeIdExists(supplierDefaultId)) {
      if (_goldSettlementLines.isNotEmpty) {
        final first = _goldSettlementLines.first;
        final canOverride =
            !onlyWhenEmpty || _goldSettlementLineWeight(first) <= 0;
        if (canOverride) {
          first.safeBoxId = supplierDefaultId;
          final picked = _findGoldSafeBoxById(supplierDefaultId);
          final fixed = picked?.karat;
          if (fixed != null && {18, 21, 22, 24}.contains(fixed)) {
            first.karat = fixed;
          } else {
            first.karat ??= _selectedGoldPaidKarat;
          }
          _selectedGoldSafeBoxId = supplierDefaultId;
          changed = true;
        }
      }
    }

    if (!changed) return;
    _clearIncompatibleGoldSettlementSafes();
    _refreshGoldPaidTotalFromLines();
    setState(() {});
  }

  bool _goldSafeAcceptsKarat(SafeBoxModel box, int karat) {
    final fixed = box.karat;
    if (fixed == null || fixed == 0) return true;
    return fixed == karat;
  }

  List<SafeBoxModel> _goldSafeBoxesForKarat(int karat) {
    return _goldSafeBoxes
        .where((b) => b.id != null && _goldSafeAcceptsKarat(b, karat))
        .toList();
  }

  int? _defaultGoldSafeIdForKarat(int karat) {
    final candidates = _goldSafeBoxesForKarat(karat);
    if (candidates.isEmpty) return null;

    final def = candidates.firstWhere(
      (b) => b.isDefault == true && b.id != null,
      orElse: () => candidates.first,
    );
    return def.id;
  }

  String _goldSafeLabel(SafeBoxModel box) {
    final k = box.karat;
    if (k != null && k > 0) {
      return '${box.name} (عيار $k)';
    }
    return box.name;
  }

  Widget _buildGoldSettlementsEditor({required bool requiredSettlement}) {
    if (!_isGoldSettlementContext) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final totalLinesMainEquiv = _goldSettlementLinesTotalMainEquivalent();

    if (_goldSafeBoxes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          'لا توجد خزائن ذهب متاحة',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          'توزيع السداد الذهبي على الخزائن',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        if (_goldSettlementLines.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              requiredSettlement
                  ? 'أضف سطر سداد ذهبي واحد على الأقل.'
                  : 'اختياري: يمكنك إضافة سداد ذهبي وتوزيعه على أكثر من خزينة.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: requiredSettlement
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ...List.generate(_goldSettlementLines.length, (index) {
          final line = _goldSettlementLines[index];
          final lineKarat = _effectiveGoldSettlementLineKarat(line);
          final availableSafes = _goldSafeBoxesForKarat(lineKarat);
          final safeValue =
              (line.safeBoxId != null &&
                  availableSafes.any((b) => b.id == line.safeBoxId))
              ? line.safeBoxId
              : null;

          final lineWeight = _goldSettlementLineWeight(line);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<int>(
                        value: safeValue,
                        decoration: const InputDecoration(
                          labelText: 'خزينة الذهب',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: availableSafes
                            .where((b) => b.id != null)
                            .map(
                              (box) => DropdownMenuItem<int>(
                                value: box.id!,
                                child: Text(
                                  _goldSafeLabel(box),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            line.safeBoxId = value;

                            final picked = _findGoldSafeBoxById(value);
                            final fixed = picked?.karat;
                            if (fixed != null &&
                                {18, 21, 22, 24}.contains(fixed)) {
                              line.karat = fixed;
                            } else {
                              line.karat ??= _selectedGoldPaidKarat;
                            }

                            if (index == 0) {
                              _selectedGoldSafeBoxId = value;
                            }

                            _refreshGoldPaidTotalFromLines();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 110,
                      child: DropdownButtonFormField<int>(
                        value: lineKarat,
                        decoration: const InputDecoration(
                          labelText: 'العيار',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [24, 22, 21, 18]
                            .map(
                              (k) => DropdownMenuItem<int>(
                                value: k,
                                child: Text('عيار $k'),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            line.karat = value;

                            final box = _findGoldSafeBoxById(line.safeBoxId);
                            if (box != null &&
                                !_goldSafeAcceptsKarat(box, value)) {
                              line.safeBoxId = null;
                            }

                            line.safeBoxId ??= _defaultGoldSafeIdForKarat(
                              value,
                            );
                            _refreshGoldPaidTotalFromLines();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: line.weightController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          NormalizeNumberFormatter(),
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'وزن',
                          border: OutlineInputBorder(),
                          isDense: true,
                          hintText: '0.000',
                        ),
                        onChanged: (_) {
                          setState(() {
                            _refreshGoldPaidTotalFromLines();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'حذف',
                      onPressed:
                          (requiredSettlement &&
                              _goldSettlementLines.length <= 1)
                          ? null
                          : () {
                              setState(() {
                                final removed = _goldSettlementLines.removeAt(
                                  index,
                                );
                                removed.dispose();
                                _refreshGoldPaidTotalFromLines();
                              });
                            },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                // صف العمولة / الرسوم
                if (lineWeight > 0)
                  _buildSettlementLineCommissionRow(line, lineWeight),
              ],
            ),
          );
        }),
        Row(
          children: [
            TextButton.icon(
              onPressed: () {
                setState(() {
                  final defaultKarat = _selectedGoldPaidKarat;
                  final supplierPreferred = _preferredGoldSafeIdForNewLine(
                    defaultKarat,
                  );
                  final defaultSafeId =
                      supplierPreferred ??
                      _defaultGoldSafeIdForKarat(defaultKarat);

                  final picked = _findGoldSafeBoxById(defaultSafeId);
                  final fixed = picked?.karat;
                  final lineKarat =
                      (fixed != null && {18, 21, 22, 24}.contains(fixed))
                      ? fixed
                      : defaultKarat;
                  _goldSettlementLines.add(
                    _GoldSettlementLine(
                      safeBoxId: defaultSafeId,
                      karat: lineKarat,
                      initialWeight: '',
                    ),
                  );
                  _refreshGoldPaidTotalFromLines();
                });
              },
              icon: const Icon(Icons.add),
              label: const Text('إضافة خزينة'),
            ),
            const Spacer(),
            Text(
              'الإجمالي (مكافئ): ${_formatWeight(totalLinesMainEquiv)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: totalLinesMainEquiv > 0
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: totalLinesMainEquiv > 0
                    ? FontWeight.w800
                    : FontWeight.normal,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettlementLineCommissionRow(
    _GoldSettlementLine line,
    double weight,
  ) {
    final theme = Theme.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final hasCommission = line.commissionDirection.isNotEmpty;
    final isEarn = line.commissionDirection == 'earn';
    final total = line.commissionTotal(weight);

    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 4),
      child: Row(
        children: [
          // أزرار الاتجاه
          _CommissionToggleButton(
            label: 'بدون',
            selected: !hasCommission,
            onTap: () => setState(() {
              line.commissionDirection = '';
              line.commissionPerGram = 0;
              line.commissionController.clear();
            }),
          ),
          const SizedBox(width: 4),
          _CommissionToggleButton(
            label: 'عمولة',
            selected: line.commissionDirection == 'earn',
            color: theme.colorScheme.tertiary,
            onTap: () => setState(() {
              line.commissionDirection = 'earn';
            }),
          ),
          const SizedBox(width: 4),
          _CommissionToggleButton(
            label: 'رسوم',
            selected: line.commissionDirection == 'pay',
            color: theme.colorScheme.error,
            onTap: () => setState(() {
              line.commissionDirection = 'pay';
            }),
          ),
          if (hasCommission) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: TextFormField(
                controller: line.commissionController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                // Arabic digits are read, not dropped to 0 (٢٫٥ was 0).
                inputFormatters: [
                  NormalizeNumberFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: '$currency/جم',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixText: currency,
                  labelStyle: TextStyle(
                    fontSize: 11,
                    color: isEarn
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.error,
                  ),
                ),
                onChanged: (v) => setState(() {
                  line.commissionPerGram = _toDouble(normalizeNumber(v));
                }),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '= ${total.toStringAsFixed(2)} $currency',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isEarn
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _clearIncompatibleGoldSettlementSafes() {
    for (final line in _goldSettlementLines) {
      final karat = _effectiveGoldSettlementLineKarat(line);
      final box = _findGoldSafeBoxById(line.safeBoxId);
      if (box == null) continue;
      if (!_goldSafeAcceptsKarat(box, karat)) {
        line.safeBoxId = null;
      }
    }
  }

  int? _selectedGoldSafeFixedKarat() {
    final safeId = _selectedGoldSafeBoxId;
    if (safeId == null) return null;
    try {
      final match = _goldSafeBoxes.firstWhere((b) => b.id == safeId);
      final k = match.karat;
      if (k == null) return null;
      if (!{18, 21, 22, 24}.contains(k)) return null;
      return k;
    } catch (_) {
      return null;
    }
  }

  List<int> _allowedGoldKaratsForSelectedSafe() {
    final fixed = _selectedGoldSafeFixedKarat();
    if (fixed != null) return [fixed];
    return const [24, 22, 21, 18];
  }

  void _syncGoldPaidKaratWithSafeIfNeeded() {
    final allowed = _allowedGoldKaratsForSelectedSafe();
    if (allowed.isEmpty) return;
    if (!allowed.contains(_selectedGoldPaidKarat)) {
      _selectedGoldPaidKarat = allowed.first;
    }
  }

  List<Category> _categories = [];
  bool _isLoadingCategories = false;
  String? _categoriesError;

  Map<String, dynamic>? _goldPrice;
  List<PurchaseKaratLine> _karatLines = [];
  List<PurchaseInlineItem> _inlineItems = [];

  double _totalWeight = 0;
  double _goldSubtotal = 0;
  double _wageSubtotal = 0;
  double _goldTaxTotal = 0;
  double _wageTaxTotal = 0;
  double _subtotal = 0;
  double _taxTotal = 0;
  double _grandTotal = 0;

  void _resetAfterSave() {
    for (final line in _goldSettlementLines) {
      line.dispose();
    }
    _goldSettlementLines.clear();
    setState(() {
      _selectedSupplierId = null;
      _vatChoice = null;
      _applyVatOnGold = false;
      _karatLines = [];
      _inlineItems = [];
      _selectedOriginalInvoice = null;
      _originalInvoiceDetailsError = null;
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _supplierError = null;

      _settlementMode = _PurchaseSettlementMode.credit;
      _cashPaidController.clear();
      _goldPaidWeightController.clear();
      _selectedGoldSafeBoxId = null;
      _selectedGoldPaidKarat = _mainKaratFromSettings();
      _applyTotals(_KaratTotals.zero);
      _gold24kSettlement = false;
      _gold24kCommissionPerGramController.text = '0.00';
      for (final line in _goldSettlementLines) {
        line.commissionDirection = '';
        line.commissionPerGram = 0;
        line.commissionController.clear();
      }
    });
  }

  void _prefillFromEditData() {
    final data = widget.editInvoiceData;
    if (data == null) return;

    double toDouble(dynamic v) {
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? 0.0;
    }

    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}');
    }

    _PurchaseSettlementMode modeFromStr(String? s) {
      switch (s) {
        case 'barter':
          return _PurchaseSettlementMode.barter;
        case 'partial':
          return _PurchaseSettlementMode.partial;
        default:
          return _PurchaseSettlementMode.credit;
      }
    }

    final karatLinesList =
        (data['karat_lines'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    final restoredKaratLines = karatLinesList
        .map(
          (line) => PurchaseKaratLine(
            karat: toDouble(line['karat']),
            weightGrams: toDouble(line['weight_grams']),
            wagePerGram: 0,
            goldValueOverride: toDouble(line['gold_value_cash']),
            wageCashOverride: toDouble(line['manufacturing_wage_cash']),
            description: line['description']?.toString(),
          ),
        )
        .toList();

    final itemsList =
        (data['items'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        [];
    final restoredInlineItems = itemsList.map((item) {
      final entryType = (item['entry_type']?.toString() == 'category')
          ? PurchaseInlineEntryType.category
          : PurchaseInlineEntryType.item;
      return PurchaseInlineItem(
        name: (item['name'] ?? '').toString(),
        karat: toDouble(item['karat']),
        weightGrams: toDouble(item['weight']),
        wagePerGram: toDouble(
          item['wage_per_gram'] ?? item['manufacturing_wage_per_gram'],
        ),
        allowInlineCreation: false,
        description: item['description']?.toString(),
        hasStones: item['has_stones'] == true,
        stonesWeight: toDouble(item['stones_weight']),
        stonesValue: toDouble(item['stones_value']),
        itemCode: item['item_code']?.toString(),
        barcode: item['barcode']?.toString(),
        category: item['category']?.toString(),
        categoryId: toInt(item['category_id']),
        entryType: entryType,
      );
    }).toList();

    setState(() {
      _selectedSupplierId = toInt(data['supplier_id']);
      _selectedBranchId = toInt(data['branch_id']);
      // Manual lines come back with the values they were saved with; priced
      // automatically they would be revalued at today's price, unseen.
      if (restoredKaratLines.isNotEmpty) _manualPricing = true;
      // Editing keeps the invoice's own decision, else what its tax says.
      final vatApplied = data['vat_applied'];
      _vatChoice = vatApplied is bool
          ? vatApplied
          : toDouble(data['total_tax']) > 0;
      _applyVatOnGold = data['apply_gold_tax'] == true;
      _settlementMode = modeFromStr(data['settlement_method']?.toString());
      _karatLines = restoredKaratLines;
      _inlineItems = restoredInlineItems;
    });
    _applyCombinedTotals();
  }

  String _localDraftKey() => 'yasargold_purchase_invoice_complete_later';

  Map<String, dynamic> _buildLocalDraftPayload() {
    String modeToString(_PurchaseSettlementMode m) {
      switch (m) {
        case _PurchaseSettlementMode.credit:
          return 'credit';
        case _PurchaseSettlementMode.barter:
          return 'barter';
        case _PurchaseSettlementMode.partial:
          return 'partial';
      }
    }

    return {
      'version': 1,
      'supplier_id': _selectedSupplierId,
      'branch_id': _selectedBranchId,
      'manual_pricing': _manualPricing,
      'apply_vat_on_gold': _applyVatOnGold,
      'ui_lock_price_edits': _uiLockPriceEdits,
      'vat_choice': _vatChoice,
      'ui_auto_print': _uiAutoOpenPrintAfterSave,
      'ui_paper_size': _uiPaperSize,
      'selected_payment_method_id': _selectedPaymentMethodId,
      'selected_safe_box_id': _selectedSafeBoxId,
      'settlement_mode': modeToString(_settlementMode),
      'cash_paid': _cashPaidController.text,
      'gold_paid_weight': _goldPaidWeightController.text,
      'selected_gold_safe_box_id': _selectedGoldSafeBoxId,
      'selected_gold_paid_karat': _selectedGoldPaidKarat,
      'gold_settlements': _goldSettlementLines
          .map(
            (l) => {
              'safe_box_id': l.safeBoxId,
              'karat': l.karat,
              'weight': l.weightController.text,
            },
          )
          .toList(),
      'karat_lines': _karatLines
          .map(
            (l) => {
              'karat': l.karat,
              'weight_grams': l.weightGrams,
              'wage_per_gram': l.wagePerGram,
              'gold_value_override': l.goldValueOverride,
              'wage_cash_override': l.wageCashOverride,
              'description': l.description,
            },
          )
          .toList(),
      'inline_items': _inlineItems
          .map(
            (i) => {
              'name': i.name,
              'karat': i.karat,
              'weight_grams': i.weightGrams,
              'wage_per_gram': i.wagePerGram,
              'description': i.description,
              'has_stones': i.hasStones,
              'stones_weight': i.stonesWeight,
              'stones_value': i.stonesValue,
              'item_code': i.itemCode,
              'barcode': i.barcode,
              'category': i.category,
              'category_id': i.categoryId,
              'entry_type': i.entryType == PurchaseInlineEntryType.category
                  ? 'category'
                  : 'item',
            },
          )
          .toList(),
      'gold24k_settlement': _gold24kSettlement,
      'gold24k_commission_per_gram': _gold24kCommissionPerGramController.text,
    };
  }

  Future<void> _saveLocalDraft({bool showToast = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localDraftKey(),
      jsonEncode(_buildLocalDraftPayload()),
    );
    if (showToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ الفاتورة لإكمالها لاحقاً')),
      );
    }
  }

  Future<void> _clearLocalDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localDraftKey());
  }

  Future<void> _maybePromptRestoreLocalDraft() async {
    if (!mounted || _checkedLocalDraft) return;
    _checkedLocalDraft = true;

    // If screen is opened to create for a specific supplier, still allow restore.

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localDraftKey());
    if (raw == null || raw.trim().isEmpty) return;

    Map<String, dynamic>? decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      await _clearLocalDraft();
      return;
    }

    final bool? restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فاتورة محفوظة'),
        content: const Text(
          'يوجد نموذج فاتورة شراء محفوظ لإكماله لاحقاً. هل تريد استعادته؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('تجاهل'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('استعادة'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (restore != true) {
      await _clearLocalDraft();
      return;
    }

    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return int.tryParse('${v ?? ''}');
    }

    double toDouble(dynamic v) {
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? 0.0;
    }

    _PurchaseSettlementMode modeFromString(String? s) {
      switch (s) {
        case 'barter':
          return _PurchaseSettlementMode.barter;
        case 'partial':
          return _PurchaseSettlementMode.partial;
        case 'credit':
        default:
          return _PurchaseSettlementMode.credit;
      }
    }

    final payload = decoded;

    try {
      final decodedKaratLines =
          (payload['karat_lines'] as List?)?.whereType<Map>().toList() ?? [];
      final decodedInlineItems =
          (payload['inline_items'] as List?)?.whereType<Map>().toList() ?? [];

      final restoredKaratLines = <PurchaseKaratLine>[];
      for (final rawLine in decodedKaratLines) {
        final map = Map<String, dynamic>.from(rawLine);
        restoredKaratLines.add(
          PurchaseKaratLine(
            karat: toDouble(map['karat']),
            weightGrams: toDouble(map['weight_grams']),
            wagePerGram: toDouble(map['wage_per_gram']),
            goldValueOverride: map['gold_value_override'] == null
                ? null
                : toDouble(map['gold_value_override']),
            wageCashOverride: map['wage_cash_override'] == null
                ? null
                : toDouble(map['wage_cash_override']),
            description: map['description']?.toString(),
          ),
        );
      }

      final restoredInlineItems = <PurchaseInlineItem>[];
      for (final rawItem in decodedInlineItems) {
        final map = Map<String, dynamic>.from(rawItem);
        final entryType = (map['entry_type']?.toString() == 'category')
            ? PurchaseInlineEntryType.category
            : PurchaseInlineEntryType.item;
        restoredInlineItems.add(
          PurchaseInlineItem(
            name: (map['name'] ?? '').toString(),
            karat: toDouble(map['karat']),
            weightGrams: toDouble(map['weight_grams']),
            wagePerGram: toDouble(map['wage_per_gram']),
            description: map['description']?.toString(),
            hasStones: map['has_stones'] == true,
            stonesWeight: toDouble(map['stones_weight']),
            stonesValue: toDouble(map['stones_value']),
            itemCode: map['item_code']?.toString(),
            barcode: map['barcode']?.toString(),
            category: map['category']?.toString(),
            categoryId: toInt(map['category_id']),
            entryType: entryType,
          ),
        );
      }

      final restoredGoldSettlements = <_GoldSettlementLine>[];
      try {
        final raw =
            (payload['gold_settlements'] as List?)?.whereType<Map>().toList() ??
            [];
        for (final rawLine in raw) {
          final map = Map<String, dynamic>.from(rawLine);
          restoredGoldSettlements.add(
            _GoldSettlementLine(
              safeBoxId: toInt(map['safe_box_id']),
              karat: toInt(map['karat']),
              initialWeight: (map['weight'] ?? '').toString(),
            ),
          );
        }
      } catch (_) {
        // ignore
      }

      for (final line in _goldSettlementLines) {
        line.dispose();
      }

      setState(() {
        _goldSettlementLines
          ..clear()
          ..addAll(restoredGoldSettlements);
        _selectedSupplierId = toInt(payload['supplier_id']);
        _selectedBranchId = toInt(payload['branch_id']);
        _manualPricing = payload['manual_pricing'] == true;
        _applyVatOnGold = payload['apply_vat_on_gold'] == true;
        _uiLockPriceEdits = payload['ui_lock_price_edits'] == true;
        final vatChoice = payload['vat_choice'];
        _vatChoice = vatChoice is bool ? vatChoice : null;
        _uiAutoOpenPrintAfterSave = payload['ui_auto_print'] == true;
        _uiPaperSize = (payload['ui_paper_size'] ?? _uiPaperSize).toString();

        _selectedPaymentMethodId = toInt(payload['selected_payment_method_id']);
        _selectedSafeBoxId = toInt(payload['selected_safe_box_id']);

        _settlementMode = modeFromString(
          payload['settlement_mode']?.toString(),
        );
        _cashPaidController.text = (payload['cash_paid'] ?? '').toString();
        _goldPaidWeightController.text = (payload['gold_paid_weight'] ?? '')
            .toString();
        _selectedGoldSafeBoxId = toInt(payload['selected_gold_safe_box_id']);
        _selectedGoldPaidKarat =
            toInt(payload['selected_gold_paid_karat']) ??
            _selectedGoldPaidKarat;

        _karatLines = restoredKaratLines;
        _inlineItems = restoredInlineItems;

        _gold24kSettlement = payload['gold24k_settlement'] == true;
        _gold24kCommissionPerGramController.text =
            (payload['gold24k_commission_per_gram'] ?? '0.00').toString();
      });

      _clearIncompatibleGoldSettlementSafes();
      _refreshGoldPaidTotalFromLines();
      _applyCombinedTotals();
    } catch (_) {
      await _clearLocalDraft();
    }
  }

  Future<void> _completeLater() async {
    await _saveLocalDraft(showToast: true);
    if (mounted) Navigator.of(context).pop();
  }

  double _vatRateFromSettings() {
    if (!_vatApplied) return 0.0;
    try {
      final settings = context.read<SettingsProvider>();
      return settings.taxEnabled ? settings.taxRate : 0.0;
    } catch (_) {
      return 0.15;
    }
  }

  int _mainKaratFromSettings() {
    try {
      final settings = context.read<SettingsProvider>();
      final value = settings.mainKarat;
      if (value <= 0) return 21;
      return value;
    } catch (_) {
      return 21;
    }
  }

  Set<int> _vatExemptKaratsFromSettings() {
    try {
      final settings = context.read<SettingsProvider>();
      return settings.vatExemptKarats.toSet();
    } catch (_) {
      return {24};
    }
  }

  String _selectedSupplierDefaultWageType() {
    final selectedId = _selectedSupplierId;
    if (selectedId == null) return 'cash';
    try {
      final supplier = _suppliers.firstWhere(
        (s) => _parseId(s['id']) == selectedId,
        orElse: () => <String, dynamic>{},
      );
      final raw = supplier['default_wage_type'] ?? supplier['defaultWageType'];
      final normalized = (raw ?? 'cash').toString().trim().toLowerCase();
      return normalized == 'gold' ? 'gold' : 'cash';
    } catch (_) {
      return 'cash';
    }
  }

  double _cashDueForSupplier() {
    final wageType = _selectedSupplierDefaultWageType();
    return _round(
      (wageType == 'cash' ? _wageSubtotal : 0.0) +
          _goldTaxTotal +
          _wageTaxTotal,
      2,
    );
  }

  double _supplierMainEquivalentWeight() {
    final weightSummary = _aggregateWeightByKarat();
    final wageType = _selectedSupplierDefaultWageType();
    final mainKarat = _mainKaratFromSettings().toDouble();
    if (mainKarat <= 0) return 0.0;

    double mainEquivalentWeight = 0.0;
    for (final entry in weightSummary.entries) {
      final karat = double.tryParse(entry.key) ?? 0.0;
      final weight = entry.value;
      if (karat <= 0 || weight <= 0) continue;
      mainEquivalentWeight += weight * (karat / mainKarat);
    }

    // If supplier wages are settled in gold, convert wage cash value to gold weight (main karat)
    // and include it in the main-equivalent view.
    if (wageType == 'gold' && _wageSubtotal > 0) {
      final priceMain = _resolveGoldPrice(mainKarat);
      if (priceMain > 0) {
        mainEquivalentWeight += (_wageSubtotal / priceMain);
      }
    }

    return _round(mainEquivalentWeight, 3);
  }

  double _cashPaid() {
    final normalized = normalizeNumber(_cashPaidController.text).trim();
    return _round(_toDouble(normalized), 2);
  }

  double _goldPaidWeight() {
    if (_isGoldSettlementContext) {
      return _goldSettlementLinesTotalMainEquivalent();
    }
    final normalized = normalizeNumber(_goldPaidWeightController.text).trim();
    return _round(_toDouble(normalized), 3);
  }

  double _goldPaidMainEquivalent() {
    // When gold settlements are entered as lines, the paid field is already main-equivalent.
    if (_isGoldSettlementContext) {
      return _goldSettlementLinesTotalMainEquivalent();
    }

    final paidWeight = _goldPaidWeight();
    if (paidWeight <= 0) return 0.0;
    final karat = _selectedGoldPaidKarat;
    final mainKarat = _mainKaratFromSettings();
    if (karat <= 0 || mainKarat <= 0) return 0.0;
    return _round(paidWeight * (karat / mainKarat), 3);
  }

  Future<void> _loadGoldSafeBoxes() async {
    try {
      final auth = context.read<AuthProvider>();
      final employeeId = auth.currentUser?.employeeId;
      int? employeeGoldSafeBoxId;
      if (employeeId != null) {
        try {
          final employee = await _api.getEmployee(employeeId);
          employeeGoldSafeBoxId = employee.goldSafeBoxId;
        } catch (_) {
          // Ignore failures; fall back to default safe selection.
        }
      }

      final allBoxes = await _api.getSafeBoxes();
      if (!mounted) return;

      final goldBoxes = allBoxes
          .where((box) => box.safeType == 'gold')
          .toList();
      setState(() {
        _goldSafeBoxes = goldBoxes;
        _employeeGoldSafeId = employeeGoldSafeBoxId;

        final mainKarat = _mainKaratFromSettings();
        if (_selectedGoldPaidKarat <= 0) {
          _selectedGoldPaidKarat = mainKarat;
        }

        final hasSelected =
            _selectedGoldSafeBoxId != null &&
            _goldSafeBoxes.any((b) => b.id == _selectedGoldSafeBoxId);

        // Prefer the employee-linked gold safe (if configured).
        if (!hasSelected && employeeGoldSafeBoxId != null) {
          final match = _goldSafeBoxes
              .where((b) => b.id == employeeGoldSafeBoxId)
              .toList();
          if (match.isNotEmpty) {
            _selectedGoldSafeBoxId = match.first.id;
          }
        }

        // Otherwise fall back to the default/first safe.
        if (_selectedGoldSafeBoxId == null && _goldSafeBoxes.isNotEmpty) {
          final defaultBox = _goldSafeBoxes.firstWhere(
            (box) => box.isDefault == true && box.id != null,
            orElse: () => _goldSafeBoxes.first,
          );
          _selectedGoldSafeBoxId = defaultBox.id;
        }

        _syncGoldPaidKaratWithSafeIfNeeded();

        // Ensure settlement lines get a sensible default safe after loading.
        _clearIncompatibleGoldSettlementSafes();
        for (final line in _goldSettlementLines) {
          line.karat ??= _effectiveGoldSettlementLineKarat(line);
          final k = _effectiveGoldSettlementLineKarat(line);
          line.safeBoxId ??= _defaultGoldSafeIdForKarat(k);
        }

        _refreshGoldPaidTotalFromLines();
      });
    } catch (e) {
      debugPrint('فشل تحميل خزائن الذهب: $e');
    }
  }

  /// Changing how the invoice is settled clears what was entered for the old
  /// way -- the cash typed and the gold lines -- so it asks first.
  Future<void> _requestSettlementMode(_PurchaseSettlementMode mode) async {
    if (mode == _settlementMode) return;
    final cash = _cashPaid();
    final goldLines = _goldSettlementLines
        .where((l) => !_isSettlementLineEffectivelyEmpty(l))
        .length;
    if (cash > 0 || goldLines > 0) {
      final lost = [
        if (cash > 0) 'المدفوع نقدًا ${_formatCurrency(cash)}',
        if (goldLines > 0) 'أسطر سداد الذهب ($goldLines)',
      ].join(' و');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('تغيير السداد إلى «${_settlementModeLabel(mode)}»'),
          content: Text('سيُمسح ما أُدخل: $lost.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إبقاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('تغيير ومسح'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    _setSettlementMode(mode);
  }

  void _setSettlementMode(_PurchaseSettlementMode mode) {
    if (mode == _settlementMode) return;

    setState(() {
      _settlementMode = mode;

      final mainKarat = _mainKaratFromSettings();
      _selectedGoldPaidKarat = mainKarat;

      if (mode == _PurchaseSettlementMode.partial) {
        _cashPaidController.text = '0.00';
        _clearGoldSettlementLines();
        _goldPaidWeightController.text = '0.000';
      } else if (mode == _PurchaseSettlementMode.barter) {
        _cashPaidController.text = '0.00';
        _clearGoldSettlementLines();
        final defaultKarat = _selectedGoldPaidKarat;
        final supplierPreferred = _preferredGoldSafeIdForNewLine(defaultKarat);
        final defaultSafeId =
            supplierPreferred ?? _defaultGoldSafeIdForKarat(defaultKarat);

        final picked = _findGoldSafeBoxById(defaultSafeId);
        final fixed = picked?.karat;
        final lineKarat = (fixed != null && {18, 21, 22, 24}.contains(fixed))
            ? fixed
            : defaultKarat;
        _goldSettlementLines.add(
          _GoldSettlementLine(
            safeBoxId: defaultSafeId,
            karat: lineKarat,
            initialWeight: '0.000',
          ),
        );
        _refreshGoldPaidTotalFromLines();
      } else {
        _cashPaidController.text = '0.00';
        _goldPaidWeightController.text = '0.000';
        _clearGoldSettlementLines();
      }

      _refreshGoldPaidTotalFromLines();
    });

    if (mode != _PurchaseSettlementMode.credit && _goldSafeBoxes.isEmpty) {
      _loadGoldSafeBoxes();
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedSupplierId = widget.supplierId;
    _cashPaidController.text = '0.00';
    _goldPaidWeightController.text = '0.000';
    _loadInvoiceUiSettingsFromPrefs();
    _loadBranches();
    _loadSuppliers();
    _loadCategories();
    _loadGoldPrice();
    _loadPaymentMethods();
    _loadGoldSafeBoxes();
    _loadSettings();
    _applyTotals(_KaratTotals.zero);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isSupplierReturnMode && !_isEditMode) {
        _maybePromptRestoreLocalDraft();
      }

      final originalId = widget.originalInvoiceId;
      if (_isSupplierReturnMode && originalId != null) {
        _loadOriginalInvoiceDetails(originalId);
      }

      if (_isEditMode) {
        _prefillFromEditData();
      }
    });
  }

  Future<void> _loadInvoiceUiSettingsFromPrefs() async {
    try {
      final settings = await InvoiceUiSettings.load(InvoiceUiContext.purchase);
      if (!mounted) return;
      setState(() {
        _uiLockPriceEdits = settings.lockPriceEdits;
        _uiAutoOpenPrintAfterSave = settings.autoOpenPrintAfterSave;
        _uiPaperSize = settings.paperSize;
      });

      if (!mounted) return;
      _applyCombinedTotals();
    } catch (_) {
      // ignore
    }
  }

  @override
  void dispose() {
    _cashPaidController.dispose();
    _goldPaidWeightController.dispose();
    _gold24kCommissionPerGramController.dispose();
    for (final line in _goldSettlementLines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBranches() async {
    setState(() {
      _isLoadingBranches = true;
      _branchError = null;
    });

    try {
      final raw = await _api.getBranches(activeOnly: true);
      if (!mounted) return;

      final branches = raw
          .whereType<Map>()
          .map((b) => Map<String, dynamic>.from(b))
          .toList();

      setState(() {
        _branches = branches;
        if (_selectedBranchId == null && _branches.length == 1) {
          final id = _parseId(_branches.first['id']);
          if (id != null) _selectedBranchId = id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _branchError = e.toString();
      });
    }

    if (!mounted) return;
    setState(() {
      _isLoadingBranches = false;
    });
  }

  Future<void> _loadSettings() async {
    Map<String, dynamic>? settings;

    // 1) Prefer cached settings to avoid permission noise
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('app_settings');
      if (cached != null && cached.trim().isNotEmpty) {
        final decoded = jsonDecode(cached);
        if (decoded is Map<String, dynamic>) {
          settings = decoded;
        } else if (decoded is Map) {
          settings = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {
      // ignore cache failures
    }

    // 2) Fetch latest only if the user is allowed to read settings
    try {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.isAuthenticated) {
        settings = await _api.getSettings();
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('app_settings', jsonEncode(settings));
        } catch (_) {
          // ignore caching failures
        }
      }
    } catch (_) {
      // ignore network/auth failures; fallback to cached/defaults
    }

    if (!mounted || settings == null) return;

    final loaded = settings;
    setState(() {
      _employeeGoldSafesEnabled = loaded['employee_gold_safes_enabled'] == true;
      _autoPostInvoices = loaded['auto_post_invoices'] != false;
    });

    final rawMode = settings['manufacturing_wage_mode']
        ?.toString()
        .toLowerCase()
        .trim();
    setState(() {
      _wageMode = rawMode == kWageModeInventory
          ? kWageModeInventory
          : kWageModeExpense;
    });
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
        // The supplier's tax number is now known: its VAT default may apply.
        _applyCombinedTotals();
      });

      _applySupplierDefaultSafeBoxSelections();
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

  Future<void> _loadCategories() async {
    setState(() {
      _isLoadingCategories = true;
      _categoriesError = null;
    });

    try {
      final response = await _api.getCategories();
      if (!mounted) return;

      final categories =
          response
              .whereType<Map<String, dynamic>>()
              .map(Category.fromJson)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));

      setState(() {
        _categories = categories;
      });
    } catch (e) {
      if (!mounted) return;
      final message = 'فشل تحميل التصنيفات: $e';
      setState(() {
        _categoriesError = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCategories = false;
        });
      }
    }
  }

  Future<void> _loadPaymentMethods() async {
    try {
      final methods = await _api.getActivePaymentMethods();
      if (!mounted) return;

      final normalizedMethods = methods
          .whereType<Map<String, dynamic>>()
          .map<Map<String, dynamic>>((method) {
            final map = Map<String, dynamic>.from(method);
            final id = _parseInt(map['id']);
            final commission = _toDouble(map['commission_rate']);
            final settlement = _parseInt(map['settlement_days']) ?? 0;
            final displayOrder = _parseInt(map['display_order']) ?? 999;

            return {
              ...map,
              'id': id,
              'commission_rate': commission,
              'settlement_days': settlement,
              'display_order': displayOrder,
            };
          })
          .where((method) => method['id'] != null)
          .toList();

      normalizedMethods.sort((a, b) {
        final aOrder = a['display_order'] as int;
        final bOrder = b['display_order'] as int;
        return aOrder.compareTo(bOrder);
      });

      setState(() {
        _paymentMethods = normalizedMethods;

        if (_paymentMethods.isNotEmpty) {
          final defaultMethod = _paymentMethods.firstWhere(
            (m) => (m['name'] ?? '').toString().trim() == 'نقداً',
            orElse: () => _paymentMethods.first,
          );
          _selectedPaymentMethodId = defaultMethod['id'] as int?;
        } else {
          _selectedPaymentMethodId = null;
        }

        // قم بإعادة تعيين الخزائن قبل تحميلها من جديد
        _safeBoxes = [];
        _selectedSafeBoxId = null;
      });

      if (_selectedPaymentMethodId != null) {
        await _loadSafeBoxesForPaymentMethod(_selectedPaymentMethodId!);
      } else {
        await _loadDefaultSafeBox();
      }
    } catch (e) {
      debugPrint('فشل تحميل وسائل الدفع: $e');
    }
  }

  Future<void> _loadSafeBoxesForPaymentMethod(int paymentMethodId) async {
    try {
      final method = _paymentMethods.firstWhere(
        (m) => m['id'] == paymentMethodId,
        orElse: () => {},
      );

      if (method.isEmpty) return;

      final paymentType = method['payment_type'] as String?;
      if (paymentType == null) return;

      final allBoxes = await _api.getSafeBoxes();

      // Discard this response if the user has since switched to a different
      // payment method while we were waiting on the network -- otherwise an
      // earlier, slower-to-resolve call can overwrite the safe box chosen for
      // whatever method is now actually selected, routing the GL entry to
      // the wrong account.
      if (!mounted || _selectedPaymentMethodId != paymentMethodId) return;

      List<SafeBoxModel> boxes;

      switch (paymentType) {
        case 'cash':
          boxes = allBoxes.where((box) => box.safeType == 'cash').toList();
          break;
        case 'bank_transfer':
        case 'check':
          boxes = allBoxes.where((box) => box.safeType == 'bank').toList();
          break;
        default:
          boxes = allBoxes
              .where(
                (box) =>
                    box.safeType == 'cash' ||
                    box.safeType == 'bank' ||
                    box.safeType == 'clearing',
              )
              .toList();
      }

      if (!mounted) return;

      if (boxes.isEmpty) {
        await _loadDefaultSafeBox();
        return;
      }

      setState(() {
        _safeBoxes = boxes;
        SafeBoxModel picked;
        final clearingBoxes = _safeBoxes
            .where((box) => (box.safeType).toLowerCase() == 'clearing')
            .toList();
        if (clearingBoxes.isNotEmpty && paymentType != 'cash') {
          picked = clearingBoxes.firstWhere(
            (box) => box.isDefault == true,
            orElse: () => clearingBoxes.first,
          );
        } else {
          picked = _safeBoxes.firstWhere(
            (box) => box.isDefault == true,
            orElse: () => _safeBoxes.first,
          );
        }

        _selectedSafeBoxId = picked.id;
      });
    } catch (e) {
      debugPrint('فشل تحميل الخزائن: $e');
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
        _applyCombinedTotals();
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
    final result = await Navigator.push<bool?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddSupplierScreen(
          api: _api,
          onSupplierSaved: (saved) {
            if (!mounted) return;
            final normalized = Map<String, dynamic>.from(saved);
            normalized['id'] = _parseId(saved['id']);
            final supplierId = normalized['id'] as int?;
            if (supplierId == null) return;

            setState(() {
              _suppliers.removeWhere(
                (supplier) => _parseId(supplier['id']) == supplierId,
              );
              _suppliers.add(normalized);
              _suppliers.sort(
                (a, b) => ((a['name'] ?? '') as String).compareTo(
                  (b['name'] ?? '') as String,
                ),
              );
              _selectedSupplierId = supplierId;
              _supplierError = null;
              _vatChoice = null;
              _applyCombinedTotals();
            });

            _applySupplierDefaultSafeBoxSelections();
          },
        ),
      ),
    );

    if (result == true) {
      debugPrint('Supplier added via AddSupplierScreen (purchase)');
    }
  }

  int? _parseId(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  String? _selectedSupplierName() {
    final selectedId = _selectedSupplierId;
    if (selectedId == null) return null;
    for (final s in _suppliers) {
      if (_parseId(s['id']) == selectedId) {
        final name = (s['name'] ?? '').toString().trim();
        return name.isEmpty ? null : name;
      }
    }
    return null;
  }

  Future<void> _pickSupplier() async {
    if (_isLoadingSuppliers) return;
    if (_suppliers.isEmpty) return;

    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => PartyPickerDialog(
        title: 'اختيار مورد',
        items: _suppliers,
        selectedId: _selectedSupplierId,
        emptyText: 'لا يوجد مورد مطابق',
      ),
    );

    if (selected == null) return;
    final id = _parseId(selected['id']);
    if (id == null) return;

    setState(() {
      _selectedSupplierId = id;
      _supplierError = null;
      // A new supplier: the VAT decision starts again from its tax number.
      _vatChoice = null;
      _applyCombinedTotals();
      // في وضع المرتجع: إعادة تعيين الفاتورة الأصلية عند تغيير المورد
      if (_isSupplierReturnMode) {
        _selectedOriginalInvoice = null;
        _inlineItems = [];
        _karatLines = [];
        _applyTotals(_KaratTotals.zero);
      }
    });

    _applySupplierDefaultSafeBoxSelections();
  }

  int? _parseInt(dynamic value) {
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

  /// A line's VAT: computed, never typed, on the values the line carries --
  /// the manual ones when priced by hand -- as the server checks it
  /// (tax_policy_mismatch). One reading for the line and its dialog.
  ({double goldTax, double wageTax}) _lineVat({
    required double vatRate,
    required bool goldTaxed,
    required double goldValue,
    required double wageCash,
  }) => (
    goldTax: goldTaxed && goldValue > 0 ? goldValue * vatRate : 0.0,
    wageTax: wageCash > 0 ? wageCash * vatRate : 0.0,
  );

  _KaratLineSnapshot _snapshotFor(PurchaseKaratLine line) {
    final pricePerGram = _resolveGoldPrice(line.karat);
    final autoGoldValue = line.weightGrams * pricePerGram;
    final autoWageCash = line.weightGrams * line.wagePerGram;

    final vatRate = _vatRateFromSettings();
    final exemptKarats = _vatExemptKaratsFromSettings();
    final karatInt = line.karat.round();
    final isGoldVatExempt = exemptKarats.contains(karatInt);

    final goldValue = _manualPricing
        ? (line.goldValueOverride ?? autoGoldValue)
        : autoGoldValue;
    final wageCash = _manualPricing
        ? (line.wageCashOverride ?? autoWageCash)
        : autoWageCash;
    final vat = _lineVat(
      vatRate: vatRate,
      goldTaxed: _applyVatOnGold && !isGoldVatExempt,
      goldValue: goldValue,
      wageCash: wageCash,
    );
    final goldTax = vat.goldTax;
    final wageTax = vat.wageTax;

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

  List<PurchaseKaratLine> _derivedInlineKaratLines(
    List<PurchaseInlineItem>? items,
  ) {
    final source = items ?? _inlineItems;
    return source
        .map(
          (item) => PurchaseKaratLine(
            karat: item.karat,
            weightGrams: item.weightGrams,
            wagePerGram: item.wagePerGram,
          ),
        )
        .toList();
  }

  void _applyCombinedTotals({
    List<PurchaseKaratLine>? manualLines,
    List<PurchaseInlineItem>? inlineItems,
  }) {
    final resolvedManual = manualLines ?? _karatLines;
    final resolvedInline = inlineItems ?? _inlineItems;
    final combinedLines = [
      ...resolvedManual,
      ..._derivedInlineKaratLines(resolvedInline),
    ];
    _applyTotals(_calculateTotals(combinedLines));
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
    setState(() {
      _karatLines = lines;
      _applyCombinedTotals(manualLines: lines);
    });
  }

  void _updateInlineItems(List<PurchaseInlineItem> items) {
    setState(() {
      _inlineItems = items;
      _applyCombinedTotals(inlineItems: items);
    });
  }

  Future<void> _addInlineItem() async {
    final item = await _showInlineItemDialog();
    if (item == null) return;
    _updateInlineItems([..._inlineItems, item]);
  }

  Future<void> _addInlineItemsBulk() async {
    final result = await _showInlineBulkDialog();
    if (result == null || result.weights.isEmpty) return;

    final newItems = result.weights
        .map(
          (weight) => PurchaseInlineItem(
            name: result.name,
            karat: result.karat,
            weightGrams: weight,
            wagePerGram: result.wagePerGram,
            allowInlineCreation: !_isSupplierReturnMode,
            description: result.description,
            itemCode: result.itemCode,
            barcode: result.barcode,
            category: result.category,
            categoryId: result.categoryId,
            entryType: result.entryType,
          ),
        )
        .toList();

    _updateInlineItems([..._inlineItems, ...newItems]);

    if (!mounted) return;
    final totalWeight = newItems.fold<double>(
      0,
      (sum, item) => sum + item.weightGrams,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تمت إضافة ${newItems.length} وزناً (${_formatWeight(totalWeight)}) للصنف ${result.name}',
        ),
      ),
    );
  }

  Future<void> _editInlineItem(int index) async {
    final existing = _inlineItems[index];
    final item = await _showInlineItemDialog(existing: existing);
    if (item == null) return;

    final updated = [..._inlineItems];
    updated[index] = item;
    _updateInlineItems(updated);
  }

  Future<void> _removeInlineItem(int index) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الصنف'),
        content: Text('هل تريد حذف الصنف "${_inlineItems[index].name}"؟'),
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
      ),
    );

    if (confirm != true) return;

    final updated = [..._inlineItems]..removeAt(index);
    _updateInlineItems(updated);
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

  Future<void> _addManualKaratLine() async {
    final line = await _showKaratLineDialog();
    if (line == null) return;

    _updateLines([..._karatLines, line]);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تمت إضافة وزن ${_formatWeight(line.weightGrams)} لعيار ${line.karat.toStringAsFixed(0)}',
        ),
      ),
    );
  }

  Future<void> _addBulkWeights() async {
    final result = await _showBulkWeightsDialog();
    if (result == null) return;

    final updated = [..._karatLines];
    for (final weight in result.weights) {
      updated.add(
        PurchaseKaratLine(
          karat: result.karat,
          weightGrams: weight,
          wagePerGram: result.wagePerGram,
          description: result.notes,
        ),
      );
    }

    _updateLines(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تمت إضافة ${result.weights.length} من الأوزان لعيار ${result.karat.toStringAsFixed(0)}',
        ),
      ),
    );
  }

  Map<String, double> _aggregateManualWeightByKarat() {
    final Map<String, double> summary = {};
    for (final line in _karatLines) {
      final key = _normalizeKaratKey(line.karat);
      summary[key] = (summary[key] ?? 0) + line.weightGrams;
    }
    return summary;
  }

  Map<String, double> _aggregateInlineWeightByKarat() {
    final Map<String, double> summary = {};
    for (final item in _inlineItems) {
      final key = _normalizeKaratKey(item.karat);
      summary[key] = (summary[key] ?? 0) + item.weightGrams;
    }
    return summary;
  }

  Map<String, double> _aggregateWeightByKarat() {
    final summary = Map<String, double>.from(_aggregateManualWeightByKarat());
    for (final entry in _aggregateInlineWeightByKarat().entries) {
      summary[entry.key] = (summary[entry.key] ?? 0) + entry.value;
    }
    return summary;
  }

  double get _inlineTotalWeight =>
      _inlineItems.fold(0.0, (sum, item) => sum + item.weightGrams);

  double get _inlineTotalWage => _inlineItems.fold(
    0.0,
    (sum, item) => sum + (item.weightGrams * item.wagePerGram),
  );

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

  String _formatCurrency(double value) =>
      '${value.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}';

  String _formatWeight(double value) => '${value.toStringAsFixed(3)} جم';

  List<InvoiceSummaryMetricDetail> _buildWeightBreakdownLines(
    Iterable<dynamic> rawItems,
  ) {
    double asDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0.0;
    }

    String formatKarat(dynamic value) {
      final karat = asDouble(value);
      if ((karat - karat.roundToDouble()).abs() < 0.001) {
        return karat.round().toString();
      }
      return karat.toStringAsFixed(1);
    }

    final byKarat = <String, double>{};
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final weight = asDouble(item['weight']);
      if (weight <= 0) continue;
      final karatLabel = formatKarat(item['karat']);
      byKarat[karatLabel] = (byKarat[karatLabel] ?? 0) + weight;
    }

    final entries = byKarat.entries.toList()
      ..sort(
        (a, b) => (double.tryParse(b.key) ?? 0).compareTo(
          double.tryParse(a.key) ?? 0,
        ),
      );

    return entries
        .map(
          (entry) => InvoiceSummaryMetricDetail(
            label: '${entry.key}k',
            value: '${entry.value.toStringAsFixed(3)} جم',
            accentColor: AppColors.karatColorFor(entry.key),
          ),
        )
        .toList();
  }

  /// The one answer the save button and the status read: ready only when the
  /// server would take the invoice as it stands (utils/purchase_readiness.dart).
  PurchaseReadiness _readiness() {
    final settings = context.read<SettingsProvider>();
    // The server's VAT policy, which the screen's «disable VAT» switch does
    // not change: the server checks manual lines against it.
    final policyRate = (_vatApplied && settings.taxEnabled)
        ? settings.taxRate
        : 0.0;
    final exempt = _vatExemptKaratsFromSettings();

    final karatLines = _karatLines.map((line) {
      final snap = _snapshotFor(line);
      final goldTaxed =
          _vatApplied &&
          _applyVatOnGold &&
          !exempt.contains(line.karat.round());
      return PurchaseKaratLineFacts(
        weight: snap.weight,
        goldTax: snap.goldTax,
        wageTax: snap.wageTax,
        expectedGoldTax: goldTaxed && snap.goldValue > 0
            ? snap.goldValue * policyRate
            : 0.0,
        expectedWageTax: snap.wageCash > 0 ? snap.wageCash * policyRate : 0.0,
      );
    }).toList();

    final goldLines = _goldSettlementLines.map((line) {
      final fixed = _findGoldSafeBoxById(line.safeBoxId)?.karat;
      return PurchaseGoldLineFacts(
        safeId: line.safeBoxId,
        karat: _effectiveGoldSettlementLineKarat(line),
        weight: _goldSettlementLineWeight(line),
        safeFixedKarat: (fixed != null && {18, 21, 22, 24}.contains(fixed))
            ? fixed
            : null,
      );
    }).toList();

    return purchaseReadiness(
      PurchaseReadinessFacts(
        branchChosen: _selectedBranchId != null,
        supplierChosen: _selectedSupplierId != null,
        goldPriceKnown: _toDouble(_goldPrice?['price_24k']) > 0,
        manualPricing: _manualPricing,
        items: _inlineItems
            .map(
              (item) => PurchaseItemFacts(
                weight: item.weightGrams,
                maxWeight: item.maxWeightGrams,
              ),
            )
            .toList(),
        karatLines: karatLines,
        settlement: switch (_settlementMode) {
          _PurchaseSettlementMode.credit => PurchaseSettlement.credit,
          _PurchaseSettlementMode.barter => PurchaseSettlement.barter,
          _PurchaseSettlementMode.partial => PurchaseSettlement.partial,
        },
        cashDue: _cashDueForSupplier(),
        cashPaid: _cashPaid(),
        paymentMethodsAvailable: _paymentMethods.isNotEmpty,
        paymentMethodChosen: _selectedPaymentMethodId != null,
        allowPartialPayments: settings.allowPartialInvoicePayments,
        goldLines: goldLines,
        goldSafesAvailable: _goldSafeBoxes.isNotEmpty,
        forcedGoldSafeId: _employeeGoldSafesEnabled
            ? _employeeGoldSafeId
            : null,
        autoPostInvoices: _autoPostInvoices,
      ),
      formatCash: _formatCurrency,
    );
  }

  /// Marks the field that blocks the save and brings its section into view.
  void _revealProblem(PurchaseReadiness readiness) {
    setState(() {
      if (readiness.target == PurchaseReadinessTarget.branch) {
        _branchError = readiness.message;
      }
      if (readiness.target == PurchaseReadinessTarget.supplier) {
        _supplierError = readiness.message;
      }
    });
    final key = switch (readiness.target) {
      PurchaseReadinessTarget.branch ||
      PurchaseReadinessTarget.supplier => _supplierSectionKey,
      PurchaseReadinessTarget.goldPrice => null, // in the app bar, in view
      PurchaseReadinessTarget.item => _itemsSectionKey,
      PurchaseReadinessTarget.karatLine =>
        _karatLines.isEmpty ? _itemsSectionKey : _karatSectionKey,
      PurchaseReadinessTarget.cashPaid ||
      PurchaseReadinessTarget.paymentMethod ||
      PurchaseReadinessTarget.goldLine => _paymentSectionKey,
      PurchaseReadinessTarget.none => null,
    };
    final target = key?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        alignment: 0.1,
      );
    }
  }

  Map<String, dynamic> _buildInvoicePayload() {
    // IMPORTANT:
    // Backend enforces strict weight integrity in some contexts (scrap/barter/settlement).
    // To avoid double-counting and payload conflicts, we keep `karat_lines` sourced ONLY
    // from explicit karat lines (and keep `items` sourced ONLY from inline items).
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

    final inlineItemsPayload = _inlineItems
        .map((item) => item.toPayload())
        .toList();
    final inlineWeights = _aggregateInlineWeightByKarat();
    final weightByKarat = _aggregateWeightByKarat();
    final supplierGoldLines = weightByKarat.entries
        .map(
          (entry) => {
            'karat': double.tryParse(entry.key) ?? 0,
            'weight': _round(entry.value, 3),
          },
        )
        .toList();

    final paidCash = _settlementMode == _PurchaseSettlementMode.partial
        ? _cashPaid()
        : 0.0;
    final paidGoldWeight = _isGoldSettlementContext
        ? _goldSettlementLinesTotalMainEquivalent()
        : 0.0;

    String settlementMethod;
    if (_settlementMode == _PurchaseSettlementMode.credit) {
      settlementMethod = 'credit';
    } else if (_settlementMode == _PurchaseSettlementMode.barter) {
      settlementMethod = 'barter';
    } else {
      settlementMethod = 'partial';
    }

    final payload = <String, dynamic>{
      'branch_id': _selectedBranchId,
      'supplier_id': _selectedSupplierId,
      'invoice_type': _isSupplierReturnMode ? 'مرتجع شراء (مورد)' : 'شراء',
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
      'apply_gold_tax': _vatApplied && _applyVatOnGold,
      'vat_applied': _vatApplied,
      'karat_lines': linePayloads,
      'items': inlineItemsPayload,
      'supplier_gold_lines': supplierGoldLines,
      'supplier_gold_weights': weightByKarat.map(
        (key, value) => MapEntry(key, _round(value, 3)),
      ),
      'manufacturing_wage_cash': _round(_wageSubtotal, 2),
      'wage_cash': _round(_wageSubtotal, 2),
      'valuation_cash_total': _round(_goldSubtotal, 2),
      'gold_tax': _round(_goldTaxTotal, 2),
      'wage_tax': _round(_wageTaxTotal, 2),
      'settlement_method': settlementMethod,
      'valuation': {
        'cash_total': _round(_goldSubtotal, 2),
        'weight_by_karat': weightByKarat.map(
          (key, value) => MapEntry(key, _round(value, 3)),
        ),
        'wage_total': _round(_wageSubtotal, 2),
      },
      if (_inlineItems.isNotEmpty) ...{
        'inline_items_summary': {
          'count': _inlineItems.length,
          'total_weight': _round(_inlineTotalWeight, 3),
          'total_wage_cash': _round(_inlineTotalWage, 2),
        },
        'inline_items_weight_by_karat': inlineWeights.map(
          (key, value) => MapEntry(key, _round(value, 3)),
        ),
      },
    };

    if (_isSupplierReturnMode) {
      final originalId = _parseId(_selectedOriginalInvoice?['id']);
      if (originalId != null) {
        payload['original_invoice_id'] = originalId;
      }
    }

    // Gold settled with items and manual weights together is never sent: the
    // server refuses it (payload_conflict_weight_sources) and readiness says so
    // on the screen. Items are not dropped silently.

    // Invoice drafts are not supported.

    // Cash settlement (جزئي): use payments[] so backend can support partial cash.
    if (_settlementMode == _PurchaseSettlementMode.partial &&
        paidCash > 0 &&
        _selectedPaymentMethodId != null) {
      payload['payments'] = [
        {
          'payment_method_id': _selectedPaymentMethodId,
          'amount': _round(paidCash, 2),
          if (_selectedSafeBoxId != null) 'safe_box_id': _selectedSafeBoxId,
        },
      ];
      payload['amount_paid'] = _round(paidCash, 2);
    } else {
      payload['amount_paid'] = 0.0;
    }

    // Gold settlement (مقايضة/جزئي): post one row per (safe, karat).
    if (paidGoldWeight > 0) {
      final Map<String, double> bySafeAndKarat = {};
      final Map<String, int> safeIdByKey = {};
      final Map<String, int> karatByKey = {};
      for (final line in _goldSettlementLines) {
        final safeId = line.safeBoxId;
        if (safeId == null) continue;
        final karat = _effectiveGoldSettlementLineKarat(line);
        final weight = _toDouble(
          normalizeNumber(line.weightController.text).trim(),
        );
        if (weight <= 0) continue;

        final key = '${safeId}_$karat';
        safeIdByKey[key] = safeId;
        karatByKey[key] = karat;
        bySafeAndKarat[key] = (bySafeAndKarat[key] ?? 0) + weight;
      }

      payload['gold_settlements'] = bySafeAndKarat.entries
          .map((e) {
            final safeId = safeIdByKey[e.key];
            final karat = karatByKey[e.key];
            if (safeId == null || karat == null) return null;
            return {
              'safe_box_id': safeId,
              'karat': karat,
              'weight': _round(e.value, 3),
            };
          })
          .whereType<Map<String, dynamic>>()
          .toList();
    }

    // Invoice-level cash SafeBox preference (fallback server-side).
    // Only attach this when we're actually paying cash.
    if (_settlementMode == _PurchaseSettlementMode.partial &&
        paidCash > 0 &&
        _selectedSafeBoxId != null) {
      payload['safe_box_id'] = _selectedSafeBoxId;
    }

    // عمولة / رسوم فرق العيار — مجمّع من سطور التسوية
    double karatDiffEarnTotal = 0.0;
    double karatDiffPayTotal = 0.0;
    for (final line in _goldSettlementLines) {
      final w = _goldSettlementLineWeight(line);
      if (w <= 0 || line.commissionDirection.isEmpty) continue;
      final amount = _round(w * line.commissionPerGram, 2);
      if (line.commissionDirection == 'earn') karatDiffEarnTotal += amount;
      if (line.commissionDirection == 'pay') karatDiffPayTotal += amount;
    }
    if (karatDiffEarnTotal > 0) {
      payload['karat_diff_earn_total'] = _round(karatDiffEarnTotal, 2);
    }
    if (karatDiffPayTotal > 0) {
      payload['karat_diff_pay_total'] = _round(karatDiffPayTotal, 2);
    }

    return payload;
  }

  /// One save at a time, from the press to the server's answer.
  Future<void> _saveInvoice() async {
    if (_saveFlowOpen) return;
    final readiness = _readiness();
    if (!readiness.isReady) {
      _revealProblem(readiness);
      return;
    }

    setState(() {
      _saveFlowOpen = true;
    });

    try {
      final shouldProceed = await _showPreSaveInvoiceSummary();
      if (!shouldProceed || !mounted) return;

      setState(() {
        _isSavingInvoice = true;
      });

      final payload = _buildInvoicePayload();
      final response = _isEditMode
          ? await _api.updateUnpostedInvoice(widget.editInvoiceId!, payload)
          : await _api.addInvoice(payload);

      if (!mounted) return;

      final invoiceForPrint = Map<String, dynamic>.from(response);

      try {
        final supplier = _suppliers.firstWhere(
          (s) => s['id'] == _selectedSupplierId,
        );
        invoiceForPrint['supplier_name'] ??=
            supplier['name'] ?? supplier['supplier_name'];
        invoiceForPrint['supplier_phone'] ??=
            supplier['phone'] ?? supplier['supplier_phone'];
      } catch (_) {
        // ignore
      }

      double totalWeight = 0.0;
      if (invoiceForPrint['items'] is List) {
        for (final item in (invoiceForPrint['items'] as List<dynamic>)) {
          totalWeight += (item['weight'] ?? 0.0) as num;
        }
      }

      final settingsProvider = Provider.of<SettingsProvider>(
        context,
        listen: false,
      );
      final currency = settingsProvider.currencySymbolText;
      final weightBreakdown = _buildWeightBreakdownLines(
        invoiceForPrint['items'] is List
            ? List<dynamic>.from(invoiceForPrint['items'])
            : const [],
      );

      final shouldPrint = _uiAutoOpenPrintAfterSave
          ? 'print'
          : await showAdaptiveInvoiceSummaryDialog<String>(
                  context: context,
                  title: 'تم حفظ الفاتورة',
                  subtitle: _isSupplierReturnMode
                      ? 'تم حفظ مرتجع الشراء بنجاح'
                      : 'تم حفظ فاتورة الشراء بنجاح',
                  icon: Icons.check_circle,
                  accentColor: AppColors.success,
                  highlightMessage: _isSupplierReturnMode
                      ? 'مرتجع الشراء #${invoiceForPrint['id'] ?? ''}'
                      : 'فاتورة الشراء #${invoiceForPrint['id'] ?? ''}',
                  statusTitle: 'حالة الفاتورة',
                  statusMessage: 'الفاتورة جاهزة للطباعة أو المشاركة',
                  statusTone: InvoiceSummaryStatusTone.success,
                  metrics: [
                    if ((invoiceForPrint['id'] ?? '').toString().isNotEmpty)
                      InvoiceSummaryMetric(
                        label: 'رقم الفاتورة',
                        value: '#${invoiceForPrint['id'] ?? ''}',
                        icon: Icons.tag_rounded,
                        accentColor: AppColors.primaryGold,
                      ),
                    if ((invoiceForPrint['supplier_name'] ?? '')
                        .toString()
                        .isNotEmpty)
                      InvoiceSummaryMetric(
                        label: 'المورد',
                        value: invoiceForPrint['supplier_name'] ?? '',
                        icon: Icons.person_outline_rounded,
                        accentColor: AppColors.info,
                      ),
                    InvoiceSummaryMetric(
                      label: 'الإجمالي',
                      value:
                          '${(invoiceForPrint['total'] ?? 0.0).toStringAsFixed(2)} $currency',
                      icon: Icons.payments_outlined,
                      accentColor: AppColors.primaryGold,
                      emphasize: true,
                    ),
                    if (totalWeight > 0)
                      InvoiceSummaryMetric(
                        label: 'إجمالي الوزن',
                        value: '${totalWeight.toStringAsFixed(3)} جم',
                        icon: Icons.scale_outlined,
                        accentColor: AppColors.info,
                        fullWidth: true,
                        details: weightBreakdown,
                      ),
                  ],
                  actions: [
                    InvoiceSummaryAction.secondary(
                      label: 'طباعة',
                      icon: Icons.print_rounded,
                      value: 'print',
                    ),
                    InvoiceSummaryAction.secondary(
                      label: 'مشاركة',
                      icon: Icons.share_rounded,
                      value: 'share',
                    ),
                    InvoiceSummaryAction.secondary(
                      label: 'فاتورة جديدة',
                      icon: Icons.add_circle_outline_rounded,
                      value: 'new_invoice',
                    ),
                    InvoiceSummaryAction.primary(
                      label: 'تم',
                      icon: Icons.check_rounded,
                      value: 'done',
                    ),
                  ],
                ) ??
                'close';

      if (!mounted) return;
      if (shouldPrint == 'print') {
        try {
          await printInvoiceDirect(
            context: context,
            invoice: invoiceForPrint,
            paperSize: _uiPaperSize,
            isArabic: true,
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('تعذر فتح الطباعة: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } else if (shouldPrint == 'share') {
        try {
          await shareInvoicePdf(
            context: context,
            invoice: invoiceForPrint,
            paperSize: _uiPaperSize,
            isArabic: true,
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('تعذر مشاركة الفاتورة: $e')));
        }
      }

      if (!mounted) return;
      if (_isEditMode) {
        Navigator.pop(context, true);
      } else if (shouldPrint == 'new_invoice') {
        await _clearLocalDraft();
        _resetAfterSave();
      } else {
        await _clearLocalDraft();
        // 'done' or null → return to home
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      }
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
          _saveFlowOpen = false;
        });
      }
    }
  }

  String _settlementModeLabel(_PurchaseSettlementMode mode) {
    switch (mode) {
      case _PurchaseSettlementMode.credit:
        return 'آجل';
      case _PurchaseSettlementMode.barter:
        return 'مقايضة';
      case _PurchaseSettlementMode.partial:
        return 'سداد الآن';
    }
  }

  String _fmtMoney(double value) => value.toStringAsFixed(2);
  String _fmtWeight(double value) => value.toStringAsFixed(3);

  Future<bool> _showPreSaveInvoiceSummary() async {
    if (!mounted) return false;
    final supplierId = _selectedSupplierId;
    if (supplierId == null) return true;

    // Invoice summary (based on current UI state)
    final totalWeight = _round(_totalWeight, 3);
    final grandTotal = _round(_grandTotal, 2);

    final dueCash = _cashDueForSupplier();
    final paidCash = _cashPaid();
    final netCashDue = _round(dueCash - paidCash, 2);

    final dueGoldMain = _supplierMainEquivalentWeight();
    final paidGoldMain = _goldPaidMainEquivalent();
    final netGoldDueMain = _round(dueGoldMain - paidGoldMain, 3);

    Map<String, dynamic>? supplierStatement;
    String? statementError;
    try {
      supplierStatement = await _api.getSupplierStatement(supplierId);
    } catch (e) {
      statementError = e.toString();
    }

    final mainKarat = _mainKaratFromSettings();

    double? currentCashBalance;
    double? currentGoldBalanceMain;
    double? projectedCashBalance;
    double? projectedGoldBalanceMain;

    if (supplierStatement != null) {
      try {
        currentCashBalance = _toDouble(
          normalizeNumber('${supplierStatement['closing_balance_cash'] ?? 0}'),
        );
        currentGoldBalanceMain = _toDouble(
          normalizeNumber(
            '${supplierStatement['closing_balance_gold_normalized'] ?? 0}',
          ),
        );

        if (_isSupplierReturnMode) {
          projectedCashBalance = _round(currentCashBalance + netCashDue, 2);
          projectedGoldBalanceMain = _round(
            currentGoldBalanceMain + netGoldDueMain,
            3,
          );
        } else {
          projectedCashBalance = _round(currentCashBalance - netCashDue, 2);
          projectedGoldBalanceMain = _round(
            currentGoldBalanceMain - netGoldDueMain,
            3,
          );
        }
      } catch (_) {
        // Keep balances null if parsing fails.
      }
    }

    String supplierName = '';
    try {
      final supplier = _suppliers.firstWhere((s) => s['id'] == supplierId);
      supplierName = (supplier['name'] ?? supplier['supplier_name'] ?? '')
          .toString();
    } catch (_) {
      supplierName = '';
    }

    final currency = Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).currencySymbolText;
    final notices = <String>[];
    // What the save does to what we owe the supplier: a purchase adds to it,
    // a return takes from it (it said «سيزداد» for both).
    String cash(double v) => '${_fmtMoney(v)} $currency';
    if (netCashDue.abs() > 0.01) {
      notices.add(
        supplierCashEffect(
          netCashDue,
          isReturn: _isSupplierReturnMode,
          formatCash: cash,
        ),
      );
    }
    if (netGoldDueMain.abs() > 0.001) {
      notices.add(
        supplierGoldEffect(
          netGoldDueMain,
          isReturn: _isSupplierReturnMode,
          mainKarat: mainKarat,
        ),
      );
    }
    // An exception to the supplier's usual VAT is seen, not missed (PURCHASE-VAT-1).
    if (!_vatApplied && _supplierHasTaxNumber) {
      notices.add('بلا ضريبة، والمورد له رقم ضريبي');
    } else if (_vatApplied && !_supplierHasTaxNumber) {
      notices.add('بضريبة، والمورد ليس له رقم ضريبي');
    }
    if (statementError != null) {
      notices.add(
        'تعذر جلب الرصيد الحالي من السيرفر. سيتم المتابعة بدون عرض رصيد تفصيلي.',
      );
    }
    final gp24k = (_goldPrice?['price_24k'] as num?)?.toDouble() ?? 0.0;
    if (totalWeight > 0 && gp24k > 0 && grandTotal > 0) {
      final pricePerGram = grandTotal / totalWeight;
      if (pricePerGram > gp24k * 2) {
        notices.add(
          '⚠️ سعر الجرام المحسوب ${pricePerGram.toStringAsFixed(0)} $currency أعلى بكثير من سعر السوق'
          ' (${gp24k.toStringAsFixed(0)} $currency/جم). تأكد من صحة المبلغ والوزن.',
        );
      } else if (pricePerGram < gp24k * 0.15) {
        notices.add(
          '⚠️ سعر الجرام المحسوب ${pricePerGram.toStringAsFixed(0)} $currency أقل بكثير من سعر السوق'
          ' (${gp24k.toStringAsFixed(0)} $currency/جم). تأكد من صحة المبلغ والوزن.',
        );
      }
    }

    return await showAdaptiveInvoiceSummaryDialog<bool>(
          context: context,
          title: 'مراجعة الفاتورة',
          subtitle: 'راجع البيانات الأساسية سريعاً قبل تنفيذ الحفظ.',
          icon: Icons.receipt_long_rounded,
          accentColor: AppColors.primaryGold,
          statusTitle: 'حالة التسوية',
          statusMessage: _settlementModeLabel(_settlementMode),
          statusTone: InvoiceSummaryStatusTone.neutral,
          metrics: [
            InvoiceSummaryMetric(
              label: 'الإجمالي',
              value: '${_fmtMoney(grandTotal)} $currency',
              icon: Icons.payments_outlined,
              accentColor: AppColors.primaryGold,
              emphasize: true,
            ),
            InvoiceSummaryMetric(
              label: 'الضريبة',
              value: _vatApplied ? 'بضريبة' : 'بلا ضريبة',
              icon: Icons.receipt_long_outlined,
              accentColor: AppSemanticColors.of(context).info.fg,
            ),
            if (_selectedPaymentMethodId != null && paidCash > 0.01)
              InvoiceSummaryMetric(
                label: 'طريقة السداد',
                value: '${_fmtMoney(paidCash)} $currency',
                icon: Icons.credit_card_outlined,
                accentColor: AppColors.info,
                fullWidth: true,
                highlightCard: true,
                details: [
                  InvoiceSummaryMetricDetail(
                    label:
                        _paymentMethods
                            .where((m) => m['id'] == _selectedPaymentMethodId)
                            .map<String>(
                              (m) => m['name']?.toString() ?? 'غير محدد',
                            )
                            .firstOrNull ??
                        'غير محدد',
                    value: '${_fmtMoney(paidCash)} $currency',
                    accentColor: AppColors.info,
                  ),
                ],
              ),
            if (totalWeight > 0)
              InvoiceSummaryMetric(
                label: 'إجمالي الوزن',
                value: '${_fmtWeight(totalWeight)} جم',
                icon: Icons.scale_outlined,
                accentColor: AppColors.info,
                fullWidth: true,
              ),
            // ── تفاصيل ثانوية (تظهر بعد الثلاثة الأساسية عند التمرير) ──
            if (supplierName.isNotEmpty)
              InvoiceSummaryMetric(
                label: 'المورد',
                value: supplierName,
                icon: Icons.person_outline_rounded,
                accentColor: AppColors.info,
              ),
            InvoiceSummaryMetric(
              label: _isSupplierReturnMode
                  ? 'نقد يُخصم مما علينا بهذا المرتجع'
                  : 'نقد علينا بهذه الفاتورة',
              value: '${_fmtMoney(netCashDue)} $currency',
              icon: Icons.money,
              accentColor: AppColors.success,
            ),
            InvoiceSummaryMetric(
              label: _isSupplierReturnMode
                  ? 'ذهب يُخصم مما علينا بهذا المرتجع (عيار $mainKarat)'
                  : 'ذهب علينا بهذه الفاتورة (عيار $mainKarat)',
              value: '${_fmtWeight(netGoldDueMain)} جم',
              icon: Icons.monitor_weight_outlined,
              accentColor: AppColors.karat24,
            ),
            if (currentGoldBalanceMain != null)
              InvoiceSummaryMetric(
                label: 'مع المورد الآن (ذهب)',
                value: supplierGoldPosition(
                  currentGoldBalanceMain,
                  mainKarat: mainKarat,
                ),
                icon: Icons.monitor_weight_outlined,
                accentColor: AppColors.info,
                badgeLabel: 'الحالي',
                badgeColor: AppColors.info,
              ),
            if (projectedGoldBalanceMain != null)
              InvoiceSummaryMetric(
                label: 'مع المورد بعد الحفظ (ذهب)',
                value: supplierGoldPosition(
                  projectedGoldBalanceMain,
                  mainKarat: mainKarat,
                ),
                icon: Icons.monitor_weight_outlined,
                accentColor: AppColors.primaryGold,
                badgeLabel: 'بعد الحفظ',
                badgeColor: AppColors.primaryGold,
              ),
            if (currentCashBalance != null)
              InvoiceSummaryMetric(
                label: 'مع المورد الآن (نقد)',
                value: supplierCashPosition(
                  currentCashBalance,
                  formatCash: cash,
                ),
                icon: Icons.account_balance_outlined,
                accentColor: AppColors.info,
                badgeLabel: 'الحالي',
                badgeColor: AppColors.info,
              ),
            if (projectedCashBalance != null)
              InvoiceSummaryMetric(
                label: 'مع المورد بعد الحفظ (نقد)',
                value: supplierCashPosition(
                  projectedCashBalance,
                  formatCash: cash,
                ),
                icon: Icons.trending_up_rounded,
                accentColor: AppColors.primaryGold,
                badgeLabel: 'بعد الحفظ',
                badgeColor: AppColors.primaryGold,
              ),
          ],
          notices: notices,
          closeValue: false,
          actions: const [
            InvoiceSummaryAction.secondary(
              label: 'رجوع',
              icon: Icons.arrow_back_rounded,
              value: false,
            ),
            InvoiceSummaryAction.primary(
              label: 'حفظ الفاتورة',
              icon: Icons.save_rounded,
              value: true,
            ),
          ],
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    final size = MediaQuery.of(context).size;
    final isWideLayout = size.width >= 1100;

    final readiness = _readiness();

    final leftColumn = <Widget>[
      KeyedSubtree(key: _supplierSectionKey, child: _buildSupplierSection()),
      if (_isSupplierReturnMode) ...[
        const SizedBox(height: 16),
        _buildOriginalInvoiceSection(),
      ],
      const SizedBox(height: 24),
      KeyedSubtree(key: _itemsSectionKey, child: _buildInlineItemsSection()),
      if (!_isSupplierReturnMode) ...[
        const SizedBox(height: 24),
        KeyedSubtree(key: _karatSectionKey, child: _buildKaratLinesSection()),
      ],
      const SizedBox(height: 24),
      KeyedSubtree(key: _paymentSectionKey, child: _buildPaymentSection()),
    ];

    // The gold price is in the app bar; its card said it a second time.
    final rightColumn = <Widget>[
      _buildSummaryCard(),
      const SizedBox(height: 24),
      _buildWagePostingModeCard(),
    ];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _saveInvoice,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              _saveInvoice,
        },
        child: Focus(
          autofocus: true,
          child: _buildScaffold(
            readiness,
            isWideLayout,
            leftColumn,
            rightColumn,
          ),
        ),
      ),
    );
  }

  Widget _buildScaffold(
    PurchaseReadiness readiness,
    bool isWideLayout,
    List<Widget> leftColumn,
    List<Widget> rightColumn,
  ) {
    return Scaffold(
      bottomNavigationBar: _buildFooter(readiness),
      appBar: AppBar(
        title: Text(
          _isSupplierReturnMode
              ? 'مرتجع شراء (مورد)'
              : (_isEditMode ? 'تعديل فاتورة شراء' : 'فاتورة شراء جديدة'),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26.0),
          child: Builder(
            builder: (context) {
              final gp24 =
                  (_goldPrice?['price_24k'] as num?)?.toDouble() ?? 0.0;
              final gpOz =
                  (_goldPrice?['price_usd_per_oz'] as num?)?.toDouble() ?? 0.0;
              final mk = _mainKaratFromSettings();
              return Container(
                color: Colors.black.withValues(alpha: 0.20),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: gp24 > 0
                      ? Row(
                          children: [
                            const Icon(
                              Icons.monetization_on_outlined,
                              size: 12,
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'أونصة: \$${gpOz.toStringAsFixed(0)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 5),
                              child: Text(
                                '|',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                            ...([24, 22, 21, 18].map((k) {
                              final isMain = k == mk;
                              return Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Text(
                                  '${k}k: ${(gp24 * k / 24).toStringAsFixed(2)}',
                                  style: TextStyle(
                                    color: isMain ? Colors.amber : Colors.white,
                                    fontSize: 11,
                                    fontWeight: isMain
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                  ),
                                ),
                              );
                            }).toList()),
                            context.read<SettingsProvider>().buildText(
                              '${context.read<SettingsProvider>().currencySymbolText}/جم',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        )
                      : const Text(
                          'جاري تحميل سعر الذهب...',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                ),
              );
            },
          ),
        ),
        actions: [
          Consumer<AuthProvider>(
            builder: (context, auth, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.person_outline,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      auth.fullName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!_isSupplierReturnMode)
            IconButton(
              tooltip: 'إكمال لاحقاً',
              icon: const Icon(Icons.schedule),
              onPressed: _completeLater,
            ),
          IconButton(
            tooltip: 'تحديث سعر الذهب',
            icon: const Icon(Icons.refresh),
            onPressed: _loadGoldPrice,
          ),
          IconButton(
            tooltip: 'إعدادات الفاتورة',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await InvoiceSettingsSheet.show(
                context,
                contextType: InvoiceUiContext.purchase,
                supportsVatToggle: false,
                supportsLockEdits: true,
                supportsAutoOpenPrint: true,
                onChanged: (s) {
                  if (!mounted) return;
                  setState(() {
                    _uiLockPriceEdits = s.lockPriceEdits;
                    _uiAutoOpenPrintAfterSave = s.autoOpenPrintAfterSave;
                    _uiPaperSize = s.paperSize;
                  });
                  _applyCombinedTotals();
                },
              );
            },
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

    final hasOriginalInvoice = _selectedOriginalInvoice != null;
    final lockedByReturn = _isSupplierReturnMode && hasOriginalInvoice;
    final helperText = lockedByReturn
        ? 'المورد والفرع يتم تحديدهما تلقائياً من الفاتورة الأصلية.'
        : (_isSupplierReturnMode
              ? 'اختيار الفاتورة الأصلية اختياري. إذا كانت الفاتورة قديمة يمكنك إدخال المورد والفرع يدوياً.'
              : 'اختر المورد أو أضف مورداً جديداً قبل متابعة إدخال الأوزان.');

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
                    color: colorScheme.primary.withValues(
                      alpha: isDark ? 0.18 : 0.12,
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
                      Text(helperText, style: theme.textTheme.bodyMedium),
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
                if (!_isLoadingSuppliers && !lockedByReturn) ...[
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
            if (_isLoadingBranches)
              const LinearProgressIndicator(minHeight: 2)
            else
              DropdownButtonFormField<int>(
                initialValue: _selectedBranchId,
                items: _branches
                    .map((branch) {
                      final id = _parseId(branch['id']);
                      if (id == null) return null;
                      final name = (branch['name'] ?? 'فرع').toString();
                      return DropdownMenuItem<int>(
                        value: id,
                        child: Text(name),
                      );
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(),
                decoration: InputDecoration(
                  labelText: 'اختر الفرع',
                  border: const OutlineInputBorder(),
                  prefixIcon: Icon(
                    Icons.account_tree,
                    color: colorScheme.primary,
                  ),
                  errorText: _branchError,
                ),
                dropdownColor: theme.cardColor,
                icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
                onChanged: lockedByReturn
                    ? null
                    : (value) {
                        setState(() {
                          _selectedBranchId = value;
                          _branchError = null;
                        });
                      },
              ),
            const SizedBox(height: 16),
            SearchablePickerField(
              labelText: 'اختر المورد',
              valueText: _selectedSupplierName(),
              hintText: lockedByReturn
                  ? (hasOriginalInvoice
                        ? 'تم تحديد المورد من الفاتورة الأصلية'
                        : 'اختياري: اختر فاتورة أصلية')
                  : 'اضغط للبحث والاختيار',
              errorText: _supplierError,
              prefixIcon: Icons.store_mall_directory,
              enabled: !lockedByReturn && _suppliers.isNotEmpty,
              onTap: lockedByReturn ? null : _pickSupplier,
            ),
            const SizedBox(height: 16),
            if (!lockedByReturn)
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
          ],
        ),
      ),
    );
  }

  Widget _buildOriginalInvoiceSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'اختياري: اختر الفاتورة الأصلية لربط المرتجع تلقائياً. إذا كانت الفاتورة قديمة يمكنك تركها فارغة.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OriginalInvoiceSelector(
          api: _api,
          invoiceType: 'شراء',
          supplierId: _selectedSupplierId,
          selectedInvoice: _selectedOriginalInvoice,
          onInvoiceSelected: _onOriginalInvoiceSelected,
        ),
        if (_isLoadingOriginalInvoiceDetails)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_originalInvoiceDetailsError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _originalInvoiceDetailsError!,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
            ),
          ),
      ],
    );
  }

  void _onOriginalInvoiceSelected(Map<String, dynamic> invoice) {
    final id = _parseId(invoice['id']);
    if (id == null) return;
    setState(() {
      _selectedOriginalInvoice = invoice;
      _originalInvoiceDetailsError = null;
    });
    _loadOriginalInvoiceDetails(id);
  }

  Future<void> _loadOriginalInvoiceDetails(int invoiceId) async {
    if (!_isSupplierReturnMode) return;

    setState(() {
      _isLoadingOriginalInvoiceDetails = true;
      _originalInvoiceDetailsError = null;
      _karatLines = [];
      _inlineItems = [];
      _applyTotals(_KaratTotals.zero);
    });

    try {
      final details = await _api.getInvoiceById(invoiceId);
      if (!mounted) return;

      final merged = {...?_selectedOriginalInvoice, ...details};

      final supplierId = _parseId(merged['supplier_id']);
      final branchId = _parseId(merged['branch_id']);
      if (supplierId == null || branchId == null) {
        setState(() {
          _selectedOriginalInvoice = merged;
          _originalInvoiceDetailsError =
              'تعذر تحميل بيانات الفاتورة الأصلية (supplier_id/branch_id غير متوفر).';
        });
        return;
      }

      final items = (merged['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final mapped = _mapOriginalInvoiceItemsToReturnInlineItems(items);

      setState(() {
        _selectedOriginalInvoice = merged;
        _selectedSupplierId = supplierId;
        _selectedBranchId = branchId;
        // A return mirrors its original's VAT decision.
        final originalVat = merged['vat_applied'];
        _vatChoice = originalVat is bool
            ? originalVat
            : _toDouble(merged['total_tax']) > 0;
        _supplierError = null;
        _branchError = null;
        _inlineItems = mapped;
        _karatLines = [];
        _applyCombinedTotals(inlineItems: mapped, manualLines: const []);
      });

      _applySupplierDefaultSafeBoxSelections(onlyWhenEmpty: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _originalInvoiceDetailsError = 'خطأ في تحميل تفاصيل الفاتورة: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في تحميل تفاصيل الفاتورة: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingOriginalInvoiceDetails = false;
        });
      }
    }
  }

  List<PurchaseInlineItem> _mapOriginalInvoiceItemsToReturnInlineItems(
    List<Map<String, dynamic>> items,
  ) {
    final result = <PurchaseInlineItem>[];

    for (final item in items) {
      final origItemId = _parseId(item['id']);
      if (origItemId == null) continue;

      final rawQty = _parseId(item['quantity']);
      final quantity = (rawQty == null || rawQty <= 0) ? 1 : rawQty;

      final weightPerUnit = _toDouble(
        item['weight'] ?? item['weight_grams'] ?? item['total_weight'],
      );

      final karatRaw = item['karat'] ?? 21;
      final karat = _toDouble(karatRaw);

      var wagePerGram = _toDouble(
        item['manufacturing_wage_per_gram'] ?? item['wage_per_gram'],
      );
      if (wagePerGram <= 0 && weightPerUnit > 0) {
        final wageTotal = _toDouble(item['wage_total'] ?? item['wage']);
        if (wageTotal > 0) wagePerGram = wageTotal / weightPerUnit;
      }

      final name = (item['name'] ?? item['item_name'] ?? 'صنف').toString();
      final categoryName = (item['category'] ?? item['category_name'])
          ?.toString();
      final categoryId = _parseId(item['category_id']);
      final description = item['description']?.toString();

      final hasStones = item['has_stones'] == true;
      final stonesWeight = _toDouble(item['stones_weight']);
      final stonesValue = _toDouble(item['stones_value']);

      for (int i = 0; i < quantity; i++) {
        result.add(
          PurchaseInlineItem(
            name: name,
            karat: karat <= 0 ? 21 : karat,
            weightGrams: weightPerUnit,
            wagePerGram: wagePerGram,
            description: (description == null || description.trim().isEmpty)
                ? null
                : description.trim(),
            category: categoryName,
            categoryId: categoryId,
            hasStones: hasStones,
            stonesWeight: hasStones ? stonesWeight : 0,
            stonesValue: hasStones ? stonesValue : 0,
            entryType: PurchaseInlineEntryType.item,
            allowInlineCreation: false,
            originalInvoiceItemId: origItemId,
            maxWeightGrams: weightPerUnit > 0 ? weightPerUnit : null,
          ),
        );
      }
    }

    return result;
  }

  Widget _buildPaymentSection() {
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
            Text(
              'الدفع',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'آجل: لا سداد الآن. مقايضة: ذهب مقابل ذهب. سداد الآن: نقد أو ذهب أو كلاهما، كله أو بعضه.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            const Text(
              'طريقة السداد',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            ToggleButtons(
              isSelected: [
                _settlementMode == _PurchaseSettlementMode.credit,
                _settlementMode == _PurchaseSettlementMode.barter,
                _settlementMode == _PurchaseSettlementMode.partial,
              ],
              borderRadius: BorderRadius.circular(12),
              onPressed: (index) => _requestSettlementMode(
                const [
                  _PurchaseSettlementMode.credit,
                  _PurchaseSettlementMode.barter,
                  _PurchaseSettlementMode.partial,
                ][index],
              ),
              children: const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('آجل'),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('مقايضة'),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('سداد الآن'),
                ),
              ],
            ),

            if (_settlementMode == _PurchaseSettlementMode.partial) ...[
              const SizedBox(height: 16),
              _buildPartialSettlementMiniTable(),
              // How the cash is paid, asked once there is cash to pay.
              if (_cashPaid() > 0 && _paymentMethods.isNotEmpty) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _selectedPaymentMethodId,
                  decoration: InputDecoration(
                    labelText: 'وسيلة الدفع',
                    border: const OutlineInputBorder(),
                    prefixIcon: Icon(Icons.payment, color: colorScheme.primary),
                  ),
                  dropdownColor: theme.cardColor,
                  icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
                  items: _paymentMethods
                      .map(
                        (method) => DropdownMenuItem<int>(
                          value: method['id'] as int,
                          child: Text(method['name']?.toString() ?? 'بدون اسم'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedPaymentMethodId = value;
                    });
                    if (value != null) {
                      _loadSafeBoxesForPaymentMethod(value);
                    }
                  },
                ),
              ],
            ],

            if (_settlementMode == _PurchaseSettlementMode.barter) ...[
              const SizedBox(height: 16),
              _buildBarterSettlementInputs(),
            ],

            if (_settlementMode == _PurchaseSettlementMode.partial &&
                _safeBoxes.isNotEmpty &&
                _cashPaid() > 0) ...[
              const SizedBox(height: 16),
              Builder(
                builder: (context) {
                  final safeBoxesWithIds = _safeBoxes
                      .where((box) => box.id != null)
                      .toList();
                  final uniqueSafeBoxesWithIds = <SafeBoxModel>[];
                  final seenSafeBoxIds = <int>{};
                  for (final box in safeBoxesWithIds) {
                    final id = box.id;
                    if (id != null && seenSafeBoxIds.add(id)) {
                      uniqueSafeBoxesWithIds.add(box);
                    }
                  }

                  final maxSafeBoxNameWidth =
                      (MediaQuery.sizeOf(context).width * 0.45).clamp(
                        160.0,
                        420.0,
                      );

                  final safeBoxValue =
                      (_selectedSafeBoxId != null &&
                          uniqueSafeBoxesWithIds.any(
                            (box) => box.id == _selectedSafeBoxId,
                          ))
                      ? _selectedSafeBoxId
                      : null;

                  return DropdownButtonFormField<int>(
                    initialValue: safeBoxValue,
                    decoration: const InputDecoration(
                      labelText: 'الخزينة المستخدمة للدفع',
                      border: OutlineInputBorder(),
                    ),
                    items: uniqueSafeBoxesWithIds
                        .map(
                          (box) => DropdownMenuItem<int>(
                            value: box.id!,
                            child: Row(
                              children: [
                                Icon(box.icon, color: box.typeColor, size: 18),
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: maxSafeBoxNameWidth,
                                  ),
                                  child: Text(
                                    box.name,
                                    overflow: TextOverflow.ellipsis,
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
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPartialSettlementMiniTable() {
    final dueCash = _cashDueForSupplier();
    final dueGoldMain = _supplierMainEquivalentWeight();
    final paidCash = _cashPaid();
    final paidGoldMain = _goldPaidMainEquivalent();

    final remainingCash = _round(dueCash - paidCash, 2);
    final remainingGold = _round(dueGoldMain - paidGoldMain, 3);

    final theme = Theme.of(context);
    final paidColor = theme.colorScheme.tertiary;
    final remainingColor = theme.colorScheme.error;

    Widget headerCell(String text) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    Widget valueCell(String text, {Color? color, FontWeight? fontWeight}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: context.read<SettingsProvider>().buildText(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: color,
            fontWeight: fontWeight,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'تفاصيل السداد',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(1.2),
            1: FlexColumnWidth(1.0),
            2: FlexColumnWidth(1.6),
            3: FlexColumnWidth(1.0),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder.all(
            color: theme.dividerColor.withValues(alpha: 0.6),
          ),
          children: [
            TableRow(
              children: [
                headerCell('البند'),
                headerCell('المستحق'),
                headerCell('المدفوع'),
                headerCell('المتبقي'),
              ],
            ),
            TableRow(
              children: [
                valueCell('نقد'),
                valueCell(_formatCurrency(dueCash)),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 6,
                  ),
                  child: TextFormField(
                    controller: _cashPaidController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      NormalizeNumberFormatter(),
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(
                      color: paidCash > 0 ? paidColor : null,
                      fontWeight: paidCash > 0 ? FontWeight.w700 : null,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '0.00',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                valueCell(
                  _formatCurrency(remainingCash),
                  color: remainingCash.abs() > 0.01 ? remainingColor : null,
                  fontWeight: remainingCash.abs() > 0.01
                      ? FontWeight.w800
                      : null,
                ),
              ],
            ),
            TableRow(
              children: [
                valueCell('ذهب (مكافئ)'),
                valueCell(_formatWeight(dueGoldMain)),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _goldPaidWeightController,
                          readOnly: true,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          enabled: false,
                          style: TextStyle(
                            color: _goldPaidWeight() > 0 ? paidColor : null,
                            fontWeight: _goldPaidWeight() > 0
                                ? FontWeight.w700
                                : null,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: '0.000',
                            helperText: 'محسوب تلقائياً من الأسطر',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                valueCell(
                  _formatWeight(remainingGold),
                  color: remainingGold.abs() > 0.0005 ? remainingColor : null,
                  fontWeight: remainingGold.abs() > 0.0005
                      ? FontWeight.w800
                      : null,
                ),
              ],
            ),
          ],
        ),
        _buildGoldSettlementsEditor(requiredSettlement: false),
      ],
    );
  }

  Widget _buildBarterSettlementInputs() {
    final dueGoldMain = _supplierMainEquivalentWeight();
    final paidGoldMain = _goldPaidMainEquivalent();
    final remainingGold = _round(dueGoldMain - paidGoldMain, 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'تفاصيل المقايضة (ذهب)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _goldPaidWeightController,
                readOnly: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                enabled: false,
                decoration: const InputDecoration(
                  labelText: 'وزن الذهب المدفوع',
                  border: OutlineInputBorder(),
                  hintText: '0.000',
                  helperText: 'محسوب تلقائياً من الأسطر',
                ),
              ),
            ),
          ],
        ),
        _buildGoldSettlementsEditor(requiredSettlement: true),
        const SizedBox(height: 10),
        Text(
          'المستحق (مكافئ): ${_formatWeight(dueGoldMain)} | المدفوع (مكافئ): ${_formatWeight(paidGoldMain)} | المتبقي: ${_formatWeight(remainingGold)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// The one summary (PURCHASE-UX-4): what the invoice puts on what we owe
  /// the supplier -- gold in the main karat and cash, not the invoice total,
  /// whose gold value is settled in gold -- then its VAT decision and how its
  /// value is made. It replaces «ملخص الفاتورة» and «مستحقات المورد», which
  /// said the same twice and computed the dues a second time.
  Widget _buildSummaryCard() {
    final theme = Theme.of(context);
    final mainKarat = _mainKaratFromSettings();
    final goldOwed = _supplierMainEquivalentWeight();
    final cashOwed = _cashDueForSupplier();
    final byKarat = _aggregateWeightByKarat();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isSupplierReturnMode
                  ? 'يُخصم مما علينا للمورد بهذا المرتجع'
                  : 'علينا للمورد بهذه الفاتورة',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildMetricTile(
                  icon: Icons.balance,
                  label: 'ذهب (مكافئ عيار $mainKarat)',
                  value: _formatWeight(goldOwed),
                  iconColor: theme.colorScheme.primary,
                ),
                _buildMetricTile(
                  icon: Icons.payments_outlined,
                  label: 'نقد (أجور وضريبة)',
                  value: _formatCurrency(cashOwed),
                  iconColor: theme.colorScheme.tertiary,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildVatDecision(),
            const Divider(height: 24),
            _buildSummaryRow('الوزن كما استُلم', _formatWeight(_totalWeight)),
            _buildSummaryRow(
              'قيمة الذهب (قبل الضريبة)',
              _formatCurrency(_goldSubtotal),
            ),
            _buildSummaryRow('أجور المصنعية', _formatCurrency(_wageSubtotal)),
            if (_goldTaxTotal > 0)
              _buildSummaryRow(
                'ضريبة على الذهب',
                _formatCurrency(_goldTaxTotal),
              ),
            _buildSummaryRow(
              'ضريبة على الأجور',
              _formatCurrency(_wageTaxTotal),
            ),
            const Divider(),
            _buildSummaryRow(
              'قيمة الفاتورة (ذهب + أجور + ضريبة)',
              _formatCurrency(_grandTotal),
              highlight: true,
            ),
            if (byKarat.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: byKarat.entries
                    .map(
                      (e) => Chip(
                        label: Text(
                          'عيار ${e.key}: ${_formatWeight(e.value)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The invoice's VAT decision, on its face (PURCHASE-VAT-1): it starts from
  /// the supplier's tax number and is changed for this invoice alone.
  Widget _buildVatDecision() {
    final theme = Theme.of(context);
    final followsSupplier = _vatChoice == null;
    final origin = followsSupplier
        ? (_supplierHasTaxNumber
              ? 'حسب المورد: له رقم ضريبي'
              : 'حسب المورد: ليس له رقم ضريبي')
        : 'غُيِّر لهذه الفاتورة';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('بضريبة')),
            ButtonSegment(value: false, label: Text('بلا ضريبة')),
          ],
          selected: {_vatApplied},
          onSelectionChanged: _uiLockPriceEdits
              ? null
              : (selection) => setState(() {
                  final choice = selection.first;
                  _vatChoice = choice == _supplierHasTaxNumber ? null : choice;
                  _applyCombinedTotals();
                }),
        ),
        const SizedBox(height: 4),
        Text(origin, style: theme.textTheme.bodySmall),
        if (_vatApplied)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _applyVatOnGold,
            title: const Text('الضريبة على قيمة الذهب أيضًا'),
            subtitle: Text(
              _applyVatOnGold
                  ? 'على قيمة الذهب وأجور المصنعية.'
                  : 'على أجور المصنعية فقط.',
            ),
            onChanged: _uiLockPriceEdits
                ? null
                : (value) => setState(() {
                    _applyVatOnGold = value;
                    _applyCombinedTotals();
                  }),
          ),
      ],
    );
  }

  /// What the server does with this invoice's wages -- the company's setting,
  /// shown, not chosen here (ADR-039).
  Widget _buildWagePostingModeCard() {
    final theme = Theme.of(context);
    final mode = _wageMode;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('معالجة أجور المصنعية', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              mode == null ? 'تُقرأ من إعدادات الشركة…' : wageModeLabel(mode),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (mode != null) ...[
              const SizedBox(height: 4),
              Text(wageModeExplanation(mode), style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                'حسب إعدادات الشركة، وتُغيَّر من شاشة الإعدادات.',
                style: theme.textTheme.bodySmall,
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
    final theme = Theme.of(context);
    final Color resolvedIconColor =
        iconColor ?? theme.colorScheme.onSurface.withValues(alpha: 0.65);

    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: resolvedIconColor.withValues(alpha: 0.12),
            child: Icon(icon, color: resolvedIconColor, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color?.withValues(
                      alpha: 0.75,
                    ),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                context.read<SettingsProvider>().buildText(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
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
    final theme = Theme.of(context);
    final weight = highlight ? FontWeight.bold : FontWeight.normal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: weight,
              color: theme.colorScheme.onSurface,
            ),
          ),
          context.read<SettingsProvider>().buildText(
            value,
            style: TextStyle(
              fontWeight: weight,
              color: highlight
                  ? AppSemanticColors.of(context).ready.fg
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineItemsSection() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasOriginalInvoice = _selectedOriginalInvoice != null;

    final lockedByReturn = _isSupplierReturnMode && hasOriginalInvoice;

    return Card(
      elevation: isDark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'الأصناف داخل الفاتورة',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lockedByReturn
                            ? 'تم تحميل أصناف الفاتورة الأصلية. عدّل الوزن أو احذف السطر لتحديد الأصناف المُرتجعة.'
                            : (_isSupplierReturnMode
                                  ? 'يمكنك إدخال المرتجع يدوياً، أو اختيار فاتورة أصلية (اختياري) للربط التلقائي.'
                                  : 'أدخل وزناً واحداً للصنف أو ألصق عدة أوزان لنفس الصنف دفعة واحدة.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (!lockedByReturn)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _addInlineItem,
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('إضافة وزن واحد'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _addInlineItemsBulk,
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('إضافة عدة أوزان'),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_inlineItems.isEmpty)
              _buildInlineItemsEmptyState()
            else ...[
              _buildInlineItemsMetrics(),
              const SizedBox(height: 12),
              _buildInlineWeightChips(),
              const SizedBox(height: 12),
              _buildInlineItemsTable(),
            ],
          ],
        ),
      ),
    );
  }

  /// Anything typed that leaving would lose.
  bool get _hasUnsavedWork =>
      _inlineItems.isNotEmpty ||
      _karatLines.isNotEmpty ||
      _cashPaid() > 0 ||
      _goldSettlementLines.any((l) => !_isSettlementLineEffectivelyEmpty(l));

  /// Back, the system gesture, the app bar arrow: leave at once when nothing
  /// was entered, otherwise ask -- the invoice is lost with the screen.
  Future<void> _confirmLeave() async {
    if (_saveFlowOpen) return;
    if (!_hasUnsavedWork) {
      Navigator.of(context).pop();
      return;
    }
    final canKeepForLater = !_isSupplierReturnMode && !_isEditMode;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فاتورة غير محفوظة'),
        content: const Text(
          'في الفاتورة أصناف أو مبالغ لم تُحفظ. ماذا تريد أن تفعل؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('stay'),
            child: const Text('متابعة التحرير'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('خروج دون حفظ'),
          ),
          if (canKeepForLater)
            FilledButton(
              onPressed: () => Navigator.of(context).pop('later'),
              child: const Text('إكمال لاحقاً'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'later') {
      await _completeLater();
    } else if (choice == 'discard') {
      Navigator.of(context).pop();
    }
  }

  Widget _buildFooter(PurchaseReadiness readiness) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            children: [
              Expanded(child: _buildStatus(readiness)),
              const SizedBox(width: 16),
              _buildSaveButton(readiness),
            ],
          ),
        ),
      ),
    );
  }

  /// The one state the user reads: green only when the server would take the
  /// invoice as it stands.
  Widget _buildStatus(PurchaseReadiness readiness) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final (IconData icon, Color color, String text) = switch (readiness.kind) {
      PurchaseReadinessKind.ready => (
        Icons.check_circle,
        tones.ready.fg,
        'جاهز للحفظ',
      ),
      PurchaseReadinessKind.notReady => (
        Icons.error_outline,
        tones.blocked.fg,
        'غير جاهز للحفظ — ${readiness.message}',
      ),
      PurchaseReadinessKind.empty => (
        Icons.edit_note,
        theme.colorScheme.onSurfaceVariant,
        readiness.message,
      ),
    };
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(PurchaseReadiness readiness) {
    final label = _isSupplierReturnMode ? 'حفظ المرتجع' : 'حفظ الفاتورة';
    if (_isSavingInvoice) {
      return const FilledButton(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('جارٍ الحفظ…'),
          ],
        ),
      );
    }
    if (readiness.isReady) {
      return FilledButton.icon(
        onPressed: _saveFlowOpen ? null : _saveInvoice,
        icon: const Icon(Icons.check),
        label: Text(label),
      );
    }
    // Grey, not disabled: a press brings the reason into view.
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: readiness.message,
      child: FilledButton.icon(
        onPressed: _saveInvoice,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurfaceVariant,
        ),
        icon: const Icon(Icons.block, size: 18),
        label: Text(label),
      ),
    );
  }

  Widget _buildInlineItemsMetrics() {
    final entries = <Widget>[
      _buildInlineMetricChip('عدد الأصناف', _inlineItems.length.toString()),
      _buildInlineMetricChip('إجمالي الوزن', _formatWeight(_inlineTotalWeight)),
      _buildInlineMetricChip(
        'أجور المصنعية',
        _formatCurrency(_inlineTotalWage),
      ),
    ];

    return Wrap(spacing: 8, runSpacing: 8, children: entries);
  }

  Widget _buildInlineMetricChip(String label, String value) {
    final theme = Theme.of(context);
    return Chip(
      backgroundColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.35,
      ),
      label: Text('$label: $value'),
    );
  }

  Widget _buildInlineWeightChips() {
    final summary = _aggregateInlineWeightByKarat();
    if (summary.isEmpty) {
      return const SizedBox.shrink();
    }

    final entries = summary.entries.toList()
      ..sort(
        (a, b) => (double.tryParse(a.key) ?? 0).compareTo(
          double.tryParse(b.key) ?? 0,
        ),
      );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: entries.map((entry) {
        final tone = AppSemanticColors.of(
          context,
        ).karat(double.tryParse(entry.key)?.round() ?? 0);
        return Chip(
          backgroundColor: tone.container,
          label: Text(
            'عيار ${entry.key}: ${_formatWeight(entry.value)}',
            style: TextStyle(color: tone.onContainer),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildInlineItemsEmptyState() {
    return Column(
      children: [
        const SizedBox(height: 16),
        Icon(
          Icons.inventory_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SizedBox(height: 12),
        Text(
          'لا توجد أصناف بعد. استخدم زر "إضافة وزن واحد" أو "إضافة عدة أوزان".',
        ),
      ],
    );
  }

  Widget _buildInlineItemsTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 44,
        dataRowMinHeight: 56,
        dataRowMaxHeight: 120,
        columnSpacing: 20,
        columns: const [
          DataColumn(label: Text('الصنف')),
          DataColumn(label: Text('العيار')),
          DataColumn(label: Text('الوزن (جم)')),
          DataColumn(label: Text('أجرة/جرام')),
          DataColumn(label: Text('أجور كلية')),
          DataColumn(label: Text('أحجار')),
          DataColumn(label: Text('ملاحظات')),
          DataColumn(label: Text('إجراءات')),
        ],
        rows: [
          for (int index = 0; index < _inlineItems.length; index++)
            _buildInlineItemRow(_inlineItems[index], index),
        ],
      ),
    );
  }

  int? _categoryIdForName(String? name) {
    if (name == null || name.isEmpty) return null;
    try {
      return _categories.firstWhere((category) => category.name == name).id;
    } catch (_) {
      return null;
    }
  }

  List<DropdownMenuItem<String?>> _buildCategoryDropdownItems() {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('بدون تصنيف')),
    ];

    for (final category in _categories) {
      items.add(
        DropdownMenuItem<String?>(
          value: category.name,
          child: Text(category.name),
        ),
      );
    }

    return items;
  }

  InputDecoration _categoryDropdownDecoration({
    String labelText = 'التصنيف (اختياري)',
  }) {
    return InputDecoration(
      labelText: labelText,
      border: const OutlineInputBorder(),
      prefixIcon: const Icon(Icons.category_outlined),
      helperText:
          _categoriesError ??
          (_categories.isEmpty ? 'لا توجد تصنيفات متاحة حالياً.' : null),
    );
  }

  DataRow _buildInlineItemRow(PurchaseInlineItem item, int index) {
    return DataRow(
      cells: [
        DataCell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                item.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (item.entryType == PurchaseInlineEntryType.category)
                Text(
                  'نوع: تصنيف فقط',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (item.category?.isNotEmpty ?? false)
                Text(
                  'تصنيف: ${item.category}',
                  style: const TextStyle(fontSize: 12),
                ),
              if (item.entryType == PurchaseInlineEntryType.item &&
                  (item.itemCode?.isNotEmpty ?? false))
                Text(
                  'كود: ${item.itemCode}',
                  style: const TextStyle(fontSize: 12),
                ),
              if (item.entryType == PurchaseInlineEntryType.item &&
                  (item.barcode?.isNotEmpty ?? false))
                Text(
                  'باركود: ${item.barcode}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        DataCell(Text(item.karat.toStringAsFixed(0))),
        DataCell(Text(item.weightGrams.toStringAsFixed(3))),
        DataCell(Text(item.wagePerGram.toStringAsFixed(2))),
        DataCell(
          Text((item.weightGrams * item.wagePerGram).toStringAsFixed(2)),
        ),
        DataCell(Text(item.hasStones ? 'نعم' : '-')),
        DataCell(
          item.description == null || item.description!.isEmpty
              ? const Text('-')
              : Tooltip(
                  message: item.description!,
                  child: Text(
                    item.description!,
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
                icon: const Icon(Icons.edit),
                tooltip: 'تعديل',
                onPressed: () => _editInlineItem(index),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                tooltip: 'حذف',
                onPressed: () => _removeInlineItem(index),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<PurchaseInlineItem?> _showInlineItemDialog({
    PurchaseInlineItem? existing,
  }) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final weightController = TextEditingController(
      text: existing != null ? existing.weightGrams.toStringAsFixed(3) : '',
    );
    final wageController = TextEditingController(
      text: existing != null ? existing.wagePerGram.toStringAsFixed(2) : '0',
    );
    final wageTotalController = TextEditingController(
      text: existing != null
          ? (existing.weightGrams * existing.wagePerGram).toStringAsFixed(2)
          : '0',
    );
    final descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    final itemCodeController = TextEditingController(
      text: existing?.itemCode ?? '',
    );
    final barcodeController = TextEditingController(
      text: existing?.barcode ?? '',
    );
    final stonesWeightController = TextEditingController(
      text: existing != null && existing.stonesWeight > 0
          ? existing.stonesWeight.toStringAsFixed(3)
          : '',
    );
    final stonesValueController = TextEditingController(
      text: existing != null && existing.stonesValue > 0
          ? existing.stonesValue.toStringAsFixed(2)
          : '',
    );
    final weightFocusNode = FocusNode();
    final wageFocusNode = FocusNode();
    final descriptionFocusNode = FocusNode();
    final itemCodeFocusNode = FocusNode();
    final barcodeFocusNode = FocusNode();
    final stonesWeightFocusNode = FocusNode();
    final stonesValueFocusNode = FocusNode();

    nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: nameController.text.length,
    );
    weightController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: weightController.text.length,
    );
    wageController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageController.text.length,
    );
    wageTotalController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageTotalController.text.length,
    );
    descriptionController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: descriptionController.text.length,
    );
    itemCodeController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: itemCodeController.text.length,
    );
    barcodeController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: barcodeController.text.length,
    );
    stonesWeightController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: stonesWeightController.text.length,
    );
    stonesValueController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: stonesValueController.text.length,
    );

    double karat = existing?.karat ?? 21;
    const allowedKarats = [18.0, 21.0, 22.0, 24.0];
    final normalizedInitialKarat = allowedKarats.contains(karat)
        ? karat
        : (allowedKarats.contains(karat.roundToDouble())
              ? karat.roundToDouble()
              : 21.0);
    karat = normalizedInitialKarat;
    bool hasStones = existing?.hasStones ?? false;
    bool wageInputIsTotal = false;
    var entryType = existing?.entryType ?? PurchaseInlineEntryType.item;
    String? selectedCategoryName = (existing?.category?.isNotEmpty ?? false)
        ? existing!.category
        : null;

    void focusAndSelect(FocusNode focusNode, TextEditingController controller) {
      focusNode.requestFocus();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }

    final result = await showDialog<PurchaseInlineItem>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              final name = nameController.text.trim();
              final parsedWeight = double.tryParse(weightController.text) ?? 0;
              final parsedWagePerGram =
                  double.tryParse(wageController.text) ?? 0;
              final parsedWageTotal =
                  double.tryParse(wageTotalController.text) ?? 0;

              final maxWeight = existing?.maxWeightGrams;
              final clampedWeight =
                  (maxWeight != null && maxWeight > 0 && parsedWeight > 0)
                  ? math.min(parsedWeight, maxWeight)
                  : parsedWeight;

              final categoryItems = _buildCategoryDropdownItems();
              final hasCategoryValue = categoryItems.any(
                (item) => item.value == selectedCategoryName,
              );
              final effectiveCategoryName = hasCategoryValue
                  ? selectedCategoryName
                  : null;
              final effectiveCategoryId = _categoryIdForName(
                effectiveCategoryName,
              );

              final stonesWeight =
                  double.tryParse(stonesWeightController.text) ?? 0;
              final stonesValue =
                  double.tryParse(stonesValueController.text) ?? 0;

              final resolvedWagePerGram = wageInputIsTotal
                  ? (clampedWeight > 0
                        ? (parsedWageTotal / clampedWeight)
                        : 0.0)
                  : parsedWagePerGram;

              final isCategoryOnly =
                  entryType == PurchaseInlineEntryType.category;

              if (clampedWeight <= 0) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('الوزن مطلوب')));
                return;
              }

              if (!isCategoryOnly && name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('اسم الصنف مطلوب لإضافة صنف')),
                );
                return;
              }

              if (isCategoryOnly &&
                  (effectiveCategoryId == null ||
                      effectiveCategoryName == null ||
                      effectiveCategoryName.trim().isEmpty)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('اختر تصنيفاً قبل الحفظ')),
                );
                return;
              }

              final resolvedName = isCategoryOnly
                  ? (name.isNotEmpty
                        ? name
                        : (effectiveCategoryName ?? 'تصنيف'))
                  : name;

              Navigator.of(dialogContext).pop(
                PurchaseInlineItem(
                  name: resolvedName,
                  karat: karat,
                  weightGrams: clampedWeight,
                  wagePerGram: resolvedWagePerGram,
                  allowInlineCreation:
                      existing?.allowInlineCreation ?? !_isSupplierReturnMode,
                  originalInvoiceItemId: existing?.originalInvoiceItemId,
                  maxWeightGrams: existing?.maxWeightGrams,
                  description: descriptionController.text.trim().isEmpty
                      ? null
                      : descriptionController.text.trim(),
                  itemCode: isCategoryOnly
                      ? null
                      : (itemCodeController.text.trim().isEmpty
                            ? null
                            : itemCodeController.text.trim()),
                  barcode: isCategoryOnly
                      ? null
                      : (barcodeController.text.trim().isEmpty
                            ? null
                            : barcodeController.text.trim()),
                  category: effectiveCategoryName,
                  categoryId: effectiveCategoryId,
                  hasStones: hasStones,
                  stonesWeight: hasStones ? stonesWeight : 0,
                  stonesValue: hasStones ? stonesValue : 0,
                  entryType: entryType,
                ),
              );
            }

            final weight = double.tryParse(weightController.text) ?? 0;
            final wagePerGramInput = double.tryParse(wageController.text) ?? 0;
            final wageTotalInput =
                double.tryParse(wageTotalController.text) ?? 0;
            final effectiveWagePerGram = wageInputIsTotal
                ? (weight > 0 ? (wageTotalInput / weight) : 0.0)
                : wagePerGramInput;
            final effectiveWageTotal = weight * effectiveWagePerGram;
            final stonesWeight =
                double.tryParse(stonesWeightController.text) ?? 0;
            final stonesValue =
                double.tryParse(stonesValueController.text) ?? 0;
            final resolvedStonesWeight = hasStones ? stonesWeight : 0.0;
            final netWeight = math.max(0.0, weight - resolvedStonesWeight);
            final categoryItems = _buildCategoryDropdownItems();
            final hasCategoryValue = categoryItems.any(
              (item) => item.value == selectedCategoryName,
            );
            final dropdownCategoryValue = hasCategoryValue
                ? selectedCategoryName
                : null;

            final isCategoryOnly =
                entryType == PurchaseInlineEntryType.category;

            return AlertDialog(
              title: Text(
                existing == null
                    ? (isCategoryOnly ? 'إضافة تصنيف' : 'إضافة صنف')
                    : (isCategoryOnly ? 'تعديل التصنيف' : 'تعديل الصنف'),
              ),
              content: DefaultTabController(
                length: 2,
                child: Builder(
                  builder: (context) {
                    final theme = Theme.of(context);
                    final mediaSize = MediaQuery.sizeOf(context);

                    final maxWidth = mediaSize.width * 0.95;
                    final maxHeight = mediaSize.height * 0.80;

                    final contentWidth = math.max(
                      280.0,
                      math.min(520.0, maxWidth),
                    );
                    final contentHeight = math.max(
                      420.0,
                      math.min(560.0, maxHeight),
                    );

                    final normalizedKarat = karat;

                    return SizedBox(
                      width: contentWidth,
                      height: contentHeight,
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const TabBar(
                              tabs: [
                                Tab(text: 'بيانات الأساسية'),
                                Tab(text: 'الأحجار والإضافات'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: TabBarView(
                              children: [
                                ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    ToggleButtons(
                                      isSelected: [
                                        entryType ==
                                            PurchaseInlineEntryType.item,
                                        entryType ==
                                            PurchaseInlineEntryType.category,
                                      ],
                                      borderRadius: BorderRadius.circular(12),
                                      onPressed: (index) {
                                        final next = index == 0
                                            ? PurchaseInlineEntryType.item
                                            : PurchaseInlineEntryType.category;
                                        if (next == entryType) return;
                                        setDialogState(() {
                                          entryType = next;
                                        });
                                      },
                                      children: const [
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Text('تسجيل كصنف'),
                                        ),
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Text('تسجيل كتصنيف'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: nameController,
                                      textInputAction: TextInputAction.next,
                                      onTap: () => nameController.selection =
                                          TextSelection(
                                            baseOffset: 0,
                                            extentOffset:
                                                nameController.text.length,
                                          ),
                                      onSubmitted: (_) => focusAndSelect(
                                        weightFocusNode,
                                        weightController,
                                      ),
                                      decoration: InputDecoration(
                                        labelText: isCategoryOnly
                                            ? 'اسم/وصف (اختياري)'
                                            : 'اسم الصنف',
                                        border: const OutlineInputBorder(),
                                        prefixIcon: const Icon(Icons.title),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    DropdownButtonFormField<double>(
                                      initialValue: normalizedKarat,
                                      decoration: const InputDecoration(
                                        labelText: 'العيار',
                                        border: OutlineInputBorder(),
                                      ),
                                      items: allowedKarats
                                          .map(
                                            (value) => DropdownMenuItem<double>(
                                              value: value,
                                              child: Text(
                                                value.toStringAsFixed(0),
                                              ),
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
                                      focusNode: weightFocusNode,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      textInputAction: TextInputAction.next,
                                      onTap: () => weightController.selection =
                                          TextSelection(
                                            baseOffset: 0,
                                            extentOffset:
                                                weightController.text.length,
                                          ),
                                      inputFormatters: [
                                        NormalizeNumberFormatter(),
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                                        ),
                                      ],
                                      decoration: const InputDecoration(
                                        labelText: 'الوزن (جرام)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.scale),
                                      ),
                                      onSubmitted: (_) => focusAndSelect(
                                        wageFocusNode,
                                        wageInputIsTotal
                                            ? wageTotalController
                                            : wageController,
                                      ),
                                      onChanged: (_) => setDialogState(() {}),
                                    ),
                                    const SizedBox(height: 12),
                                    ToggleButtons(
                                      isSelected: [
                                        !wageInputIsTotal,
                                        wageInputIsTotal,
                                      ],
                                      borderRadius: BorderRadius.circular(12),
                                      onPressed: (index) {
                                        final nextIsTotal = index == 1;
                                        if (nextIsTotal == wageInputIsTotal) {
                                          return;
                                        }
                                        setDialogState(() {
                                          wageInputIsTotal = nextIsTotal;
                                          if (wageInputIsTotal) {
                                            wageTotalController.text =
                                                effectiveWageTotal
                                                    .toStringAsFixed(2);
                                          } else {
                                            wageController.text =
                                                effectiveWagePerGram
                                                    .toStringAsFixed(2);
                                          }
                                        });
                                      },
                                      children: const [
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Text('ريال/جرام'),
                                        ),
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Text('إجمالي الأجور'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: wageInputIsTotal
                                          ? wageTotalController
                                          : wageController,
                                      focusNode: wageFocusNode,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      textInputAction: TextInputAction.next,
                                      onTap: () {
                                        final c = wageInputIsTotal
                                            ? wageTotalController
                                            : wageController;
                                        c.selection = TextSelection(
                                          baseOffset: 0,
                                          extentOffset: c.text.length,
                                        );
                                      },
                                      inputFormatters: [
                                        NormalizeNumberFormatter(),
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                                        ),
                                      ],
                                      onSubmitted: (_) => focusAndSelect(
                                        descriptionFocusNode,
                                        descriptionController,
                                      ),
                                      decoration: InputDecoration(
                                        labelText: wageInputIsTotal
                                            ? 'إجمالي أجور المصنعية (ريال)'
                                            : 'أجور المصنعية (ريال/جرام)',
                                        border: const OutlineInputBorder(),
                                        prefixIcon: const Icon(
                                          Icons.design_services,
                                        ),
                                      ),
                                      onChanged: (_) => setDialogState(() {}),
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: descriptionController,
                                      focusNode: descriptionFocusNode,
                                      maxLines: 2,
                                      onTap: () =>
                                          descriptionController
                                              .selection = TextSelection(
                                            baseOffset: 0,
                                            extentOffset: descriptionController
                                                .text
                                                .length,
                                          ),
                                      textInputAction: isCategoryOnly
                                          ? TextInputAction.done
                                          : TextInputAction.next,
                                      onSubmitted: (_) {
                                        if (isCategoryOnly) {
                                          submit();
                                          return;
                                        }
                                        focusAndSelect(
                                          itemCodeFocusNode,
                                          itemCodeController,
                                        );
                                      },
                                      decoration: const InputDecoration(
                                        labelText: 'ملاحظات (اختياري)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(
                                          Icons.sticky_note_2_outlined,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (!isCategoryOnly) ...[
                                      TextField(
                                        controller: itemCodeController,
                                        focusNode: itemCodeFocusNode,
                                        textInputAction: TextInputAction.next,
                                        onTap: () =>
                                            itemCodeController
                                                .selection = TextSelection(
                                              baseOffset: 0,
                                              extentOffset: itemCodeController
                                                  .text
                                                  .length,
                                            ),
                                        onSubmitted: (_) => focusAndSelect(
                                          barcodeFocusNode,
                                          barcodeController,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'كود الصنف (اختياري)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.tag),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    DropdownButtonFormField<String?>(
                                      initialValue: dropdownCategoryValue,
                                      items: categoryItems,
                                      isExpanded: true,
                                      onChanged: _isLoadingCategories
                                          ? null
                                          : (value) => setDialogState(() {
                                              selectedCategoryName = value;
                                            }),
                                      decoration: _categoryDropdownDecoration(
                                        labelText: isCategoryOnly
                                            ? 'التصنيف (مطلوب)'
                                            : 'التصنيف (اختياري)',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (!isCategoryOnly)
                                      TextField(
                                        controller: barcodeController,
                                        focusNode: barcodeFocusNode,
                                        textInputAction: TextInputAction.done,
                                        onTap: () =>
                                            barcodeController
                                                .selection = TextSelection(
                                              baseOffset: 0,
                                              extentOffset:
                                                  barcodeController.text.length,
                                            ),
                                        onSubmitted: (_) => submit(),
                                        decoration: const InputDecoration(
                                          labelText: 'الباركود (اختياري)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.qr_code_2),
                                        ),
                                      ),
                                  ],
                                ),
                                ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    SwitchListTile(
                                      title: const Text(
                                        'يتضمن أحجاراً أو إضافات',
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                      value: hasStones,
                                      onChanged: (value) => setDialogState(() {
                                        hasStones = value;
                                      }),
                                    ),
                                    if (hasStones) ...[
                                      TextField(
                                        controller: stonesWeightController,
                                        focusNode: stonesWeightFocusNode,
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        textInputAction: TextInputAction.next,
                                        onTap: () =>
                                            stonesWeightController.selection =
                                                TextSelection(
                                                  baseOffset: 0,
                                                  extentOffset:
                                                      stonesWeightController
                                                          .text
                                                          .length,
                                                ),
                                        inputFormatters: [
                                          NormalizeNumberFormatter(),
                                          FilteringTextInputFormatter.allow(
                                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                                          ),
                                        ],
                                        onSubmitted: (_) => focusAndSelect(
                                          stonesValueFocusNode,
                                          stonesValueController,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'وزن الأحجار (جم)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.diamond),
                                        ),
                                        onChanged: (_) => setDialogState(() {}),
                                      ),
                                      const SizedBox(height: 12),
                                      TextField(
                                        controller: stonesValueController,
                                        focusNode: stonesValueFocusNode,
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        textInputAction: TextInputAction.done,
                                        onTap: () =>
                                            stonesValueController.selection =
                                                TextSelection(
                                                  baseOffset: 0,
                                                  extentOffset:
                                                      stonesValueController
                                                          .text
                                                          .length,
                                                ),
                                        inputFormatters: [
                                          NormalizeNumberFormatter(),
                                          FilteringTextInputFormatter.allow(
                                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                                          ),
                                        ],
                                        decoration: const InputDecoration(
                                          labelText: 'قيمة الأحجار (ريال)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.attach_money),
                                        ),
                                        onChanged: (_) => setDialogState(() {}),
                                        onSubmitted: (_) => submit(),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'معاينة سريعة',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _previewRow('الوزن', _formatWeight(weight)),
                                _previewRow(
                                  'الوزن الصافي (بعد خصم الأحجار)',
                                  _formatWeight(netWeight),
                                ),
                                _previewRow(
                                  'أجور المصنعية',
                                  _formatCurrency(effectiveWageTotal),
                                ),
                                _previewRow(
                                  'الأجور/جرام',
                                  effectiveWagePerGram.toStringAsFixed(2),
                                ),
                                if (hasStones)
                                  _previewRow(
                                    'وزن الأحجار',
                                    _formatWeight(stonesWeight),
                                  ),
                                if (hasStones)
                                  _previewRow(
                                    'قيمة الأحجار',
                                    _formatCurrency(stonesValue),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: submit,
                  icon: const Icon(Icons.save),
                  label: Text(existing == null ? 'إضافة' : 'تحديث'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    weightController.dispose();
    wageController.dispose();
    wageTotalController.dispose();
    descriptionController.dispose();
    itemCodeController.dispose();
    barcodeController.dispose();
    stonesWeightController.dispose();
    stonesValueController.dispose();
    weightFocusNode.dispose();
    wageFocusNode.dispose();
    descriptionFocusNode.dispose();
    itemCodeFocusNode.dispose();
    barcodeFocusNode.dispose();
    stonesWeightFocusNode.dispose();
    stonesValueFocusNode.dispose();

    return result;
  }

  Future<_InlineBulkResult?> _showInlineBulkDialog() async {
    final nameController = TextEditingController();
    final weightsController = TextEditingController();
    final wageController = TextEditingController(text: '0');
    final wageTotalController = TextEditingController(text: '0');
    final descriptionController = TextEditingController();
    final itemCodeController = TextEditingController();
    final barcodeController = TextEditingController();
    double karat = 21;
    const allowedKarats = [18.0, 21.0, 22.0, 24.0];
    String? selectedCategoryName;
    final weightsFocusNode = FocusNode();
    int wageModeIndex = 0; // 0: per-gram, 1: total
    var entryType = PurchaseInlineEntryType.item;

    wageController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageController.text.length,
    );

    wageTotalController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageTotalController.text.length,
    );

    List<double> parseWeights(String input) {
      final tokens = input
          .split(RegExp(r'[\s,;،]+'))
          .map((token) => token.trim())
          .where((token) => token.isNotEmpty)
          .toList();

      final values = <double>[];
      for (final token in tokens) {
        final normalized = token.replaceAll(',', '.');
        final parsed = double.tryParse(normalized);
        if (parsed != null && parsed > 0) {
          values.add(parsed);
        }
      }
      return values;
    }

    final parentContext = context;

    final result = await showDialog<_InlineBulkResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final parsedWeights = parseWeights(weightsController.text);
            final totalWeight = parsedWeights.fold<double>(
              0,
              (sum, value) => sum + value,
            );

            final wageIsTotal = wageModeIndex == 1;
            final wagePerGramInput = double.tryParse(wageController.text) ?? 0;
            final wageTotalInput =
                double.tryParse(wageTotalController.text) ?? 0;
            final effectiveWagePerGram = wageIsTotal
                ? (totalWeight > 0 ? wageTotalInput / totalWeight : 0.0)
                : wagePerGramInput;
            final computedWageTotal = wageIsTotal
                ? wageTotalInput
                : (wagePerGramInput * totalWeight);
            final categoryItems = _buildCategoryDropdownItems();
            final hasCategoryValue = categoryItems.any(
              (item) => item.value == selectedCategoryName,
            );
            final dropdownCategoryValue = hasCategoryValue
                ? selectedCategoryName
                : null;

            void handleInsertNewline() {
              final selection = weightsController.selection;
              final text = weightsController.text;
              final start = selection.isValid ? selection.start : text.length;
              final end = selection.isValid ? selection.end : text.length;

              final updatedText = text.replaceRange(start, end, '\n');
              final caretOffset = start + 1;

              weightsController.value = TextEditingValue(
                text: updatedText,
                selection: TextSelection.collapsed(offset: caretOffset),
              );

              setDialogState(() {});
              weightsFocusNode.requestFocus();
            }

            final isCategoryOnly =
                entryType == PurchaseInlineEntryType.category;

            return AlertDialog(
              title: Text(
                isCategoryOnly
                    ? 'إضافة عدة أوزان لنفس التصنيف'
                    : 'إضافة عدة أوزان لنفس الصنف',
              ),
              content: DefaultTabController(
                length: 2,
                child: Builder(
                  builder: (context) {
                    final theme = Theme.of(context);
                    final mediaSize = MediaQuery.sizeOf(context);

                    final maxWidth = mediaSize.width * 0.95;
                    final maxHeight = mediaSize.height * 0.80;

                    final contentWidth = math.max(
                      280.0,
                      math.min(520.0, maxWidth),
                    );
                    final contentHeight = math.max(
                      420.0,
                      math.min(620.0, maxHeight),
                    );

                    final normalizedKarat = allowedKarats.contains(karat)
                        ? karat
                        : 21.0;

                    return SizedBox(
                      width: contentWidth,
                      height: contentHeight,
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const TabBar(
                              tabs: [
                                Tab(text: 'بيانات الأساسية'),
                                Tab(text: 'تفاصيل إضافية'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: TabBarView(
                              children: [
                                ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    ToggleButtons(
                                      isSelected: [
                                        entryType ==
                                            PurchaseInlineEntryType.item,
                                        entryType ==
                                            PurchaseInlineEntryType.category,
                                      ],
                                      borderRadius: BorderRadius.circular(12),
                                      onPressed: (index) {
                                        final next = index == 0
                                            ? PurchaseInlineEntryType.item
                                            : PurchaseInlineEntryType.category;
                                        if (next == entryType) return;
                                        setDialogState(() {
                                          entryType = next;
                                        });
                                      },
                                      children: const [
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Text('تسجيل كصنف'),
                                        ),
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Text('تسجيل كتصنيف'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: nameController,
                                      decoration: InputDecoration(
                                        labelText: isCategoryOnly
                                            ? 'اسم/وصف (اختياري)'
                                            : 'اسم الصنف',
                                        border: const OutlineInputBorder(),
                                        prefixIcon: const Icon(
                                          Icons.inventory_2_outlined,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    DropdownButtonFormField<double>(
                                      initialValue: normalizedKarat,
                                      decoration: const InputDecoration(
                                        labelText: 'العيار',
                                        border: OutlineInputBorder(),
                                      ),
                                      items: allowedKarats
                                          .map(
                                            (value) => DropdownMenuItem<double>(
                                              value: value,
                                              child: Text(
                                                value.toStringAsFixed(0),
                                              ),
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
                                    DropdownButtonFormField<String?>(
                                      initialValue: dropdownCategoryValue,
                                      items: categoryItems,
                                      isExpanded: true,
                                      onChanged: _isLoadingCategories
                                          ? null
                                          : (value) => setDialogState(() {
                                              selectedCategoryName = value;
                                            }),
                                      decoration: _categoryDropdownDecoration(
                                        labelText: isCategoryOnly
                                            ? 'التصنيف (مطلوب)'
                                            : 'التصنيف (اختياري)',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    ToggleButtons(
                                      isSelected: [
                                        wageModeIndex == 0,
                                        wageModeIndex == 1,
                                      ],
                                      borderRadius: BorderRadius.circular(12),
                                      onPressed: (index) {
                                        setDialogState(() {
                                          wageModeIndex = index;
                                          if (wageModeIndex == 1) {
                                            wageTotalController.text =
                                                computedWageTotal
                                                    .toStringAsFixed(2);
                                          } else {
                                            wageController.text =
                                                effectiveWagePerGram
                                                    .toStringAsFixed(2);
                                          }
                                        });
                                      },
                                      children: const [
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Text('ريال/جرام'),
                                        ),
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                          ),
                                          child: Text('إجمالي الأجور'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: wageIsTotal
                                          ? wageTotalController
                                          : wageController,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      inputFormatters: [
                                        NormalizeNumberFormatter(),
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                                        ),
                                      ],
                                      decoration: InputDecoration(
                                        labelText: wageIsTotal
                                            ? 'إجمالي الأجور (ريال)'
                                            : 'أجرة المصنعية (ريال/جرام)',
                                        helperText: wageIsTotal
                                            ? (totalWeight > 0
                                                  ? 'سيتم تحويلها إلى ${effectiveWagePerGram.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}/جرام'
                                                  : 'أدخل الأوزان أولاً لحساب ${context.read<SettingsProvider>().currencySymbolText}/جرام')
                                            : (parsedWeights.isEmpty
                                                  ? null
                                                  : 'إجمالي الأجور: ${computedWageTotal.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}'),
                                        border: const OutlineInputBorder(),
                                        prefixIcon: const Icon(
                                          Icons.design_services,
                                        ),
                                      ),
                                      onChanged: (_) => setDialogState(() {}),
                                    ),
                                    const SizedBox(height: 12),
                                    Shortcuts(
                                      shortcuts:
                                          const <ShortcutActivator, Intent>{
                                            SingleActivator(
                                              LogicalKeyboardKey.enter,
                                            ): _InsertNewlineIntent(),
                                            SingleActivator(
                                              LogicalKeyboardKey.numpadEnter,
                                            ): _InsertNewlineIntent(),
                                          },
                                      child: Actions(
                                        actions: <Type, Action<Intent>>{
                                          _InsertNewlineIntent:
                                              CallbackAction<
                                                _InsertNewlineIntent
                                              >(
                                                onInvoke: (intent) {
                                                  handleInsertNewline();
                                                  return null;
                                                },
                                              ),
                                        },
                                        child: TextField(
                                          focusNode: weightsFocusNode,
                                          controller: weightsController,
                                          keyboardType:
                                              const TextInputType.numberWithOptions(
                                                decimal: true,
                                              ),
                                          inputFormatters: [
                                            NormalizeNumberFormatter(),
                                            FilteringTextInputFormatter.allow(
                                              RegExp(
                                                '[0-9\u0660-\u0669\u06F0-\u06F9.,،؛;\\s]',
                                              ),
                                            ),
                                          ],
                                          textInputAction:
                                              TextInputAction.newline,
                                          minLines: 4,
                                          maxLines: 8,
                                          decoration: const InputDecoration(
                                            labelText: 'الأوزان المراد إضافتها',
                                            hintText:
                                                'مثال:\n10.500\n9.350\n8.125',
                                            helperText:
                                                'افصل بين الأوزان بسطر جديد أو فاصلة أو مسافة.',
                                            alignLabelWithHint: true,
                                            border: OutlineInputBorder(),
                                          ),
                                          onChanged: (_) =>
                                              setDialogState(() {}),
                                          onEditingComplete:
                                              handleInsertNewline,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      parsedWeights.isEmpty
                                          ? 'لم يتم التعرف على أي وزن بعد.'
                                          : 'سيتم إضافة ${parsedWeights.length} وزنًا بإجمالي ${_formatWeight(totalWeight)}',
                                      style: TextStyle(
                                        color: parsedWeights.isEmpty
                                            ? Colors.redAccent
                                            : Colors.green.shade700,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    TextField(
                                      controller: descriptionController,
                                      maxLines: 2,
                                      decoration: const InputDecoration(
                                        labelText: 'ملاحظات (اختياري)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(
                                          Icons.note_alt_outlined,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (!isCategoryOnly) ...[
                                      TextField(
                                        controller: itemCodeController,
                                        decoration: const InputDecoration(
                                          labelText: 'كود الصنف (اختياري)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.tag),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                    ],
                                    if (!isCategoryOnly) ...[
                                      const SizedBox(height: 12),
                                      TextField(
                                        controller: barcodeController,
                                        decoration: const InputDecoration(
                                          labelText: 'الباركود (اختياري)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.qr_code_2),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'معاينة سريعة',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _previewRow(
                                  'عدد الأوزان',
                                  parsedWeights.length.toString(),
                                ),
                                _previewRow(
                                  'إجمالي الوزن',
                                  _formatWeight(totalWeight),
                                  highlight: totalWeight > 0,
                                ),
                                _previewRow(
                                  'إجمالي الأجور',
                                  _formatCurrency(computedWageTotal),
                                ),
                                _previewRow(
                                  'الأجور/جرام',
                                  effectiveWagePerGram.toStringAsFixed(2),
                                ),
                                _previewRow(
                                  'التصنيف',
                                  dropdownCategoryValue ?? 'بدون تصنيف',
                                ),
                                if (!isCategoryOnly &&
                                    itemCodeController.text.trim().isNotEmpty)
                                  _previewRow(
                                    'كود الصنف',
                                    itemCodeController.text.trim(),
                                  ),
                                if (!isCategoryOnly &&
                                    barcodeController.text.trim().isNotEmpty)
                                  _previewRow(
                                    'الباركود',
                                    barcodeController.text.trim(),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  onPressed: () {
                    final name = nameController.text.trim();
                    final weights = parseWeights(weightsController.text);
                    final wagePerGram = effectiveWagePerGram;
                    final wageTotal = computedWageTotal;

                    final effectiveCategoryName = dropdownCategoryValue;
                    final effectiveCategoryId = _categoryIdForName(
                      effectiveCategoryName,
                    );

                    if (!isCategoryOnly && name.isEmpty) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(content: Text('اسم الصنف مطلوب')),
                      );
                      return;
                    }

                    if (isCategoryOnly &&
                        (effectiveCategoryId == null ||
                            effectiveCategoryName == null ||
                            effectiveCategoryName.trim().isEmpty)) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(content: Text('اختر تصنيفاً قبل الحفظ')),
                      );
                      return;
                    }

                    if (weights.isEmpty) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(
                          content: Text('أدخل وزناً واحداً على الأقل'),
                        ),
                      );
                      return;
                    }

                    if (wageTotal < 0 || wagePerGram < 0) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(
                          content: Text('لا يمكن أن تكون أجرة المصنعية سالبة'),
                        ),
                      );
                      return;
                    }

                    final resolvedName = isCategoryOnly
                        ? (name.isNotEmpty
                              ? name
                              : (effectiveCategoryName ?? 'تصنيف'))
                        : name;

                    Navigator.of(dialogContext).pop(
                      _InlineBulkResult(
                        name: resolvedName,
                        karat: karat,
                        wagePerGram: wagePerGram,
                        weights: weights,
                        description: descriptionController.text.trim().isEmpty
                            ? null
                            : descriptionController.text.trim(),
                        itemCode: isCategoryOnly
                            ? null
                            : (itemCodeController.text.trim().isEmpty
                                  ? null
                                  : itemCodeController.text.trim()),
                        barcode: isCategoryOnly
                            ? null
                            : (barcodeController.text.trim().isEmpty
                                  ? null
                                  : barcodeController.text.trim()),
                        category: effectiveCategoryName,
                        categoryId: effectiveCategoryId,
                        entryType: entryType,
                      ),
                    );
                  },
                  icon: const Icon(Icons.save_alt),
                  label: const Text('إضافة الأوزان'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    weightsController.dispose();
    wageController.dispose();
    wageTotalController.dispose();
    descriptionController.dispose();
    itemCodeController.dispose();
    barcodeController.dispose();
    weightsFocusNode.dispose();

    return result;
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
            const Text(
              'الأوزان اليدوية (اختياري)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'استخدم هذا القسم لإدخال أوزان مستلمة مباشرة بدون إنشاء صنف داخل الفاتورة.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // How these lines are priced -- it acts on them alone, so it sits
            // with them (it was a card of its own across the screen).
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('سعر الذهب الحالي')),
                ButtonSegment(value: true, label: Text('قيمة يدوية')),
              ],
              selected: {_manualPricing},
              onSelectionChanged: _uiLockPriceEdits
                  ? null
                  : (selection) => setState(() {
                      _manualPricing = selection.first;
                      _applyCombinedTotals();
                    }),
            ),
            const SizedBox(height: 4),
            Text(
              _manualPricing
                  ? 'تُدخل قيمة الذهب والأجور لكل وزن، والضريبة تُحسب عليها.'
                  : 'تُحسب قيمة الذهب من الوزن وسعر الذهب الحالي، والضريبة عليها.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _addManualKaratLine,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('إضافة وزن'),
                ),
                OutlinedButton.icon(
                  onPressed: _addBulkWeights,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('إضافة عدة أوزان'),
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
    final summary = _aggregateManualWeightByKarat();
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
      children: [
        const SizedBox(height: 16),
        Icon(
          Icons.balance,
          size: 64,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        SizedBox(height: 12),
        Text('لم يتم إضافة أسطر عيار بعد.'),
      ],
    );
  }

  Widget _buildKaratLinesTable(List<_KaratLineSnapshot> snapshots) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 44,
        dataRowMinHeight: 56,
        dataRowMaxHeight: 100,
        columnSpacing: 20,
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
    final notesController = TextEditingController(
      text: existing?.description ?? '',
    );
    final weightFocusNode = FocusNode();
    final wageFocusNode = FocusNode();
    final goldValueFocusNode = FocusNode();
    final wageCashFocusNode = FocusNode();
    final notesFocusNode = FocusNode();

    final allowedKarats = _allowedGoldKaratsForSelectedSafe();
    final defaultKarat = allowedKarats.isNotEmpty
        ? allowedKarats.first.toDouble()
        : 21.0;
    double karat = existing?.karat ?? defaultKarat;
    if (allowedKarats.isNotEmpty && !allowedKarats.contains(karat.round())) {
      karat = defaultKarat;
    }

    void focusAndSelect(FocusNode focusNode, TextEditingController controller) {
      focusNode.requestFocus();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }

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
            final vatRate = _vatRateFromSettings();
            final exemptKarats = _vatExemptKaratsFromSettings();
            final karatInt = karat.round();
            final isGoldVatExempt = exemptKarats.contains(karatInt);
            final manualGoldValue = double.tryParse(goldValueController.text);
            final manualWageCash = double.tryParse(wageCashController.text);

            final effectiveGoldValue = _manualPricing
                ? (manualGoldValue ?? autoGoldValue)
                : autoGoldValue;
            final effectiveWageCash = _manualPricing
                ? (manualWageCash ?? autoWageCash)
                : autoWageCash;
            final vat = _lineVat(
              vatRate: vatRate,
              goldTaxed: _applyVatOnGold && !isGoldVatExempt,
              goldValue: effectiveGoldValue,
              wageCash: effectiveWageCash,
            );
            final effectiveGoldTax = vat.goldTax;
            final effectiveWageTax = vat.wageTax;
            final total =
                effectiveGoldValue +
                effectiveWageCash +
                effectiveGoldTax +
                effectiveWageTax;

            return AlertDialog(
              title: Text(existing == null ? 'إضافة وزن' : 'تعديل سطر العيار'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<double>(
                      initialValue: karat,
                      decoration: const InputDecoration(
                        labelText: 'العيار',
                        border: OutlineInputBorder(),
                      ),
                      items:
                          (allowedKarats.isNotEmpty
                                  ? allowedKarats
                                        .map((k) => k.toDouble())
                                        .toList()
                                  : const [18.0, 21.0, 22.0, 24.0])
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
                      focusNode: weightFocusNode,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        NormalizeNumberFormatter(),
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'الوزن (جرام)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.scale),
                      ),
                      onSubmitted: (_) =>
                          focusAndSelect(wageFocusNode, wagePerGramController),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: wagePerGramController,
                      focusNode: wageFocusNode,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: _manualPricing
                          ? TextInputAction.next
                          : TextInputAction.next,
                      inputFormatters: [
                        NormalizeNumberFormatter(),
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
                      onSubmitted: (_) {
                        if (_manualPricing) {
                          focusAndSelect(
                            goldValueFocusNode,
                            goldValueController,
                          );
                          return;
                        }
                        focusAndSelect(notesFocusNode, notesController);
                      },
                    ),
                    if (_manualPricing) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: goldValueController,
                        focusNode: goldValueFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          NormalizeNumberFormatter(),
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                          ),
                        ],
                        onSubmitted: (_) => focusAndSelect(
                          wageCashFocusNode,
                          wageCashController,
                        ),
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
                        focusNode: wageCashFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          NormalizeNumberFormatter(),
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]*$'),
                          ),
                        ],
                        onSubmitted: (_) =>
                            focusAndSelect(notesFocusNode, notesController),
                        decoration: const InputDecoration(
                          labelText: 'أجور المصنعية (ريال)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.construction),
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      focusNode: notesFocusNode,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        final weightValue =
                            double.tryParse(weightController.text) ?? 0;
                        final wageValue =
                            double.tryParse(wagePerGramController.text) ?? 0;
                        if (weightValue <= 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('يرجى إدخال وزن صحيح'),
                            ),
                          );
                          return;
                        }
                        if (wageValue < 0) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'لا يمكن أن تكون أجرة المصنعية سالبة',
                              ),
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
                            description: notesController.text.trim().isEmpty
                                ? null
                                : notesController.text.trim(),
                          ),
                        );
                      },
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات (اختياري)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.note_alt_outlined),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
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
                        description: notesController.text.trim().isEmpty
                            ? null
                            : notesController.text.trim(),
                      ),
                    );
                  },
                  child: Text(existing == null ? 'إضافة' : 'تحديث'),
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
    notesController.dispose();
    weightFocusNode.dispose();
    wageFocusNode.dispose();
    goldValueFocusNode.dispose();
    wageCashFocusNode.dispose();
    notesFocusNode.dispose();

    return result;
  }

  Future<_BulkWeightEntry?> _showBulkWeightsDialog() async {
    final weightsController = TextEditingController();
    final wageController = TextEditingController(text: '0');
    final wageTotalController = TextEditingController(text: '0');
    final notesController = TextEditingController();
    final allowedKarats = _allowedGoldKaratsForSelectedSafe();
    double karat = allowedKarats.isNotEmpty
        ? allowedKarats.first.toDouble()
        : 21.0;
    int wageModeIndex = 0; // 0: per-gram, 1: total

    wageController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageController.text.length,
    );

    wageTotalController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageTotalController.text.length,
    );

    List<double> parseWeights(String input) {
      final tokens = input
          .split(RegExp(r'[\s,;،]+'))
          .map((token) => token.trim())
          .where((token) => token.isNotEmpty)
          .toList();
      final values = <double>[];
      for (final token in tokens) {
        final normalized = token.replaceAll(',', '.');
        final parsed = double.tryParse(normalized);
        if (parsed != null && parsed > 0) {
          values.add(parsed);
        }
      }
      return values;
    }

    final parentContext = context;

    final result = await showDialog<_BulkWeightEntry>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final parsedWeights = parseWeights(weightsController.text);
            final totalWeight = parsedWeights.fold<double>(
              0,
              (sum, value) => sum + value,
            );
            final wageIsTotal = wageModeIndex == 1;
            final wagePerGramInput = double.tryParse(wageController.text) ?? 0;
            final wageTotalInput =
                double.tryParse(wageTotalController.text) ?? 0;
            final effectiveWagePerGram = wageIsTotal
                ? (totalWeight > 0 ? wageTotalInput / totalWeight : 0.0)
                : wagePerGramInput;
            final computedWageTotal = wageIsTotal
                ? wageTotalInput
                : (wagePerGramInput * totalWeight);
            final statusText = parsedWeights.isEmpty
                ? 'أدخل الأوزان المطلوب إضافتها (سطر لكل وزن).'
                : 'سيتم إضافة ${parsedWeights.length} وزنًا بإجمالي ${_formatWeight(totalWeight)}';

            return AlertDialog(
              title: const Text('إضافة عدة أوزان دفعة واحدة'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<double>(
                      initialValue: karat,
                      decoration: const InputDecoration(
                        labelText: 'العيار',
                        border: OutlineInputBorder(),
                      ),
                      items:
                          (allowedKarats.isNotEmpty
                                  ? allowedKarats
                                        .map((k) => k.toDouble())
                                        .toList()
                                  : const [18.0, 21.0, 22.0, 24.0])
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
                    ToggleButtons(
                      isSelected: [wageModeIndex == 0, wageModeIndex == 1],
                      onPressed: (index) {
                        setDialogState(() {
                          wageModeIndex = index;
                          if (wageModeIndex == 1) {
                            wageTotalController.text =
                                (wagePerGramInput * totalWeight)
                                    .toStringAsFixed(2);
                          } else {
                            wageController.text = effectiveWagePerGram
                                .toStringAsFixed(2);
                          }
                        });
                      },
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('ريال/جرام'),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text('إجمالي الأجور'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: wageIsTotal
                          ? wageTotalController
                          : wageController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        NormalizeNumberFormatter(),
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^[0-9]*\.?[0-9]*$'),
                        ),
                      ],
                      decoration: InputDecoration(
                        labelText: wageIsTotal
                            ? 'إجمالي الأجور (ريال)'
                            : 'أجرة المصنعية (ريال/جرام)',
                        helperText: wageIsTotal
                            ? (totalWeight > 0
                                  ? 'سيتم تحويلها إلى ${effectiveWagePerGram.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}/جرام'
                                  : 'أدخل الأوزان أولاً لحساب ${context.read<SettingsProvider>().currencySymbolText}/جرام')
                            : (parsedWeights.isEmpty
                                  ? null
                                  : 'إجمالي الأجور: ${computedWageTotal.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}'),
                        border: OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.design_services),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: weightsController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        NormalizeNumberFormatter(),
                        FilteringTextInputFormatter.allow(
                          RegExp('[0-9\u0660-\u0669\u06F0-\u06F9.,،؛;\\s]'),
                        ),
                      ],
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'الأوزان المراد إضافتها',
                        hintText: 'مثال:\n2.350\n1.780\n0.955',
                        helperText:
                            'افصل بين الأوزان بسطر جديد أو مسافة أو فاصلة.',
                        alignLabelWithHint: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      statusText,
                      style: TextStyle(
                        color: parsedWeights.isEmpty
                            ? Colors.redAccent
                            : Colors.green.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات (اختياري)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.note_alt_outlined),
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
                FilledButton.icon(
                  onPressed: () {
                    final weights = parseWeights(weightsController.text);
                    if (weights.isEmpty) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(
                          content: Text('يجب إضافة وزن واحد على الأقل'),
                        ),
                      );
                      return;
                    }

                    final wagePerGram = effectiveWagePerGram;
                    final wageTotal = computedWageTotal;
                    if (wageTotal < 0 || wagePerGram < 0) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(
                          content: Text('لا يمكن أن تكون أجرة المصنعية سالبة'),
                        ),
                      );
                      return;
                    }

                    Navigator.of(dialogContext).pop(
                      _BulkWeightEntry(
                        karat: karat,
                        wagePerGram: wagePerGram,
                        weights: weights,
                        notes: notesController.text.trim().isEmpty
                            ? null
                            : notesController.text.trim(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.save_alt),
                  label: const Text('إضافة الأوزان'),
                ),
              ],
            );
          },
        );
      },
    );

    weightsController.dispose();
    wageController.dispose();
    wageTotalController.dispose();
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
  final String? description;

  const PurchaseKaratLine({
    required this.karat,
    required this.weightGrams,
    required this.wagePerGram,
    this.goldValueOverride,
    this.wageCashOverride,
    this.description,
  });

  PurchaseKaratLine copyWith({
    double? karat,
    double? weightGrams,
    double? wagePerGram,
    double? goldValueOverride,
    double? wageCashOverride,
    String? description,
  }) {
    return PurchaseKaratLine(
      karat: karat ?? this.karat,
      weightGrams: weightGrams ?? this.weightGrams,
      wagePerGram: wagePerGram ?? this.wagePerGram,
      goldValueOverride: goldValueOverride ?? this.goldValueOverride,
      wageCashOverride: wageCashOverride ?? this.wageCashOverride,
      description: description ?? this.description,
    );
  }
}

class _BulkWeightEntry {
  final double karat;
  final double wagePerGram;
  final List<double> weights;
  final String? notes;

  const _BulkWeightEntry({
    required this.karat,
    required this.wagePerGram,
    required this.weights,
    this.notes,
  });
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

class PurchaseInlineItem {
  final String name;
  final double karat;
  final double weightGrams;
  final double wagePerGram;
  final bool allowInlineCreation;
  final int? originalInvoiceItemId;
  final double? maxWeightGrams;
  final String? description;
  final bool hasStones;
  final double stonesWeight;
  final double stonesValue;
  final String? itemCode;
  final String? barcode;
  final String? category;
  final int? categoryId;
  final PurchaseInlineEntryType entryType;

  const PurchaseInlineItem({
    required this.name,
    required this.karat,
    required this.weightGrams,
    required this.wagePerGram,
    this.allowInlineCreation = true,
    this.originalInvoiceItemId,
    this.maxWeightGrams,
    this.description,
    this.hasStones = false,
    this.stonesWeight = 0,
    this.stonesValue = 0,
    this.itemCode,
    this.barcode,
    this.category,
    this.categoryId,
    this.entryType = PurchaseInlineEntryType.item,
  });

  PurchaseInlineItem copyWith({
    String? name,
    double? karat,
    double? weightGrams,
    double? wagePerGram,
    bool? allowInlineCreation,
    int? originalInvoiceItemId,
    double? maxWeightGrams,
    String? description,
    bool? hasStones,
    double? stonesWeight,
    double? stonesValue,
    String? itemCode,
    String? barcode,
    String? category,
    int? categoryId,
    PurchaseInlineEntryType? entryType,
  }) {
    return PurchaseInlineItem(
      name: name ?? this.name,
      karat: karat ?? this.karat,
      weightGrams: weightGrams ?? this.weightGrams,
      wagePerGram: wagePerGram ?? this.wagePerGram,
      allowInlineCreation: allowInlineCreation ?? this.allowInlineCreation,
      originalInvoiceItemId:
          originalInvoiceItemId ?? this.originalInvoiceItemId,
      maxWeightGrams: maxWeightGrams ?? this.maxWeightGrams,
      description: description ?? this.description,
      hasStones: hasStones ?? this.hasStones,
      stonesWeight: stonesWeight ?? this.stonesWeight,
      stonesValue: stonesValue ?? this.stonesValue,
      itemCode: itemCode ?? this.itemCode,
      barcode: barcode ?? this.barcode,
      category: category ?? this.category,
      categoryId: categoryId ?? this.categoryId,
      entryType: entryType ?? this.entryType,
    );
  }

  Map<String, dynamic> toPayload() {
    final payload = {
      'name': name,
      'karat': karat,
      'weight': weightGrams,
      if (originalInvoiceItemId != null)
        'original_invoice_item_id': originalInvoiceItemId,
      if (originalInvoiceItemId != null) 'quantity': 1,
      'manufacturing_wage_per_gram': wagePerGram,
      'wage_per_gram': wagePerGram,
      'wage_total': weightGrams * wagePerGram,
      'description': description,
      'item_code': itemCode,
      'barcode': barcode,
      'has_stones': hasStones,
      'stones_weight': stonesWeight,
      'stones_value': stonesValue,
      'category': category,
      'category_id': categoryId,
    };

    if (allowInlineCreation && entryType == PurchaseInlineEntryType.item) {
      payload['create_inline'] = true;
    }

    payload.removeWhere((key, value) => value == null);
    return payload;
  }
}

enum PurchaseInlineEntryType { item, category }

class _InlineBulkResult {
  final String name;
  final double karat;
  final double wagePerGram;
  final List<double> weights;
  final String? description;
  final String? itemCode;
  final String? barcode;
  final String? category;
  final int? categoryId;
  final PurchaseInlineEntryType entryType;

  const _InlineBulkResult({
    required this.name,
    required this.karat,
    required this.wagePerGram,
    required this.weights,
    this.description,
    this.itemCode,
    this.barcode,
    this.category,
    this.categoryId,
    this.entryType = PurchaseInlineEntryType.item,
  });
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}
