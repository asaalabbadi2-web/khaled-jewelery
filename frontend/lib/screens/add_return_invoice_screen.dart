import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../api_service.dart';
import '../widgets/currency_manager_dialog.dart';
import '../widgets/widgets.dart'; // Import shared widgets
import '../theme/app_theme.dart';
import '../utils.dart';
import '../utils/invoice_direct_print.dart';
import '../utils/currency_utils.dart' as cu;

class _ReturnPaymentEntry {
  final int paymentMethodId;
  final String paymentMethodName;
  final double amount;
  final double commissionRate;
  final double commissionAmount;
  final double netAmount;

  const _ReturnPaymentEntry({
    required this.paymentMethodId,
    required this.paymentMethodName,
    required this.amount,
    required this.commissionRate,
    required this.commissionAmount,
    required this.netAmount,
  });

  Map<String, dynamic> toJson() => {
    'payment_method_id': paymentMethodId,
    'payment_method_name': paymentMethodName,
    'amount': amount,
    'commission_rate': commissionRate,
    'commission_amount': commissionAmount,
    'net_amount': netAmount,
  };
}

/// Screen for creating return invoices (مرتجعات)
/// Supports: مرتجع بيع, مرتجع شراء, مرتجع شراء (مورد)
class AddReturnInvoiceScreen extends StatefulWidget {
  final ApiService api;
  final String returnType; // 'مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)'
  final Map<String, dynamic>? prefilledOriginalInvoice;
  final int? editInvoiceId;
  final Map<String, dynamic>? editInvoiceData;

  const AddReturnInvoiceScreen({
    super.key,
    required this.api,
    required this.returnType,
    this.prefilledOriginalInvoice,
    this.editInvoiceId,
    this.editInvoiceData,
  });

  @override
  State<AddReturnInvoiceScreen> createState() => _AddReturnInvoiceScreenState();
}

// Data model for return item rows with proportional calculations
class ReturnItemRow {
  final int? originalItemId; // Reference to original invoice item
  final int? itemId; // Inventory item ID (if available)
  final String itemName;
  final double karat;
  final double originalWeight;
  final int originalQuantity;
  final double originalWage;
  final double originalNet;
  final double originalTax;
  final double originalTotal;

  bool isSelected;
  double weight;
  int quantity;
  double wage;
  double net;
  double tax;
  double total;
  double cost;

  /// إذا أدخل المستخدم مبلغاً يدوياً يُخزَّن هنا ويُلغي الحساب التلقائي
  double? manualTotal;

  ReturnItemRow({
    this.originalItemId,
    this.itemId,
    required this.itemName,
    required this.karat,
    required this.originalWeight,
    required this.originalQuantity,
    required this.originalWage,
    required this.originalNet,
    required this.originalTax,
    required this.originalTotal,
    this.isSelected = true,
  }) : weight = originalWeight,
       quantity = originalQuantity,
       wage = originalWage,
       net = originalNet,
       tax = originalTax,
       total = originalTotal,
       cost = originalNet;

  void updateWeight(double newWeight) {
    weight = newWeight.clamp(0, originalWeight);
    // إعادة الحساب التلقائي — يُلغي المبلغ اليدوي عند تغيير الوزن
    manualTotal = null;
    recalculateTotals();
  }

  void updateQuantity(int newQuantity) {
    final clamped = newQuantity.clamp(0, originalQuantity);
    quantity = clamped.toInt();
    // إعادة الحساب التلقائي — يُلغي المبلغ اليدوي عند تغيير الكمية
    manualTotal = null;
    recalculateTotals();
  }

  void updateWage(double newWage) {
    wage = newWage;
  }

  /// تعيين مبلغ يدوي — يُلغي الحساب التلقائي
  void setManualTotal(double? value) {
    if (value == null || value <= 0) {
      manualTotal = null;
      recalculateTotals(); // استرجاع الحساب التلقائي
    } else {
      manualTotal = value.clamp(0, originalTotal);
      // حساب net و tax بنسبة المبلغ اليدوي من الأصلي
      final ratio = originalTotal > 0 ? manualTotal! / originalTotal : 1.0;
      net = double.parse((originalNet * ratio).toStringAsFixed(2));
      tax = double.parse((originalTax * ratio).toStringAsFixed(2));
      total = manualTotal!;
      cost = net;
    }
  }

  void recalculateTotals() {
    // إذا كان هناك مبلغ يدوي → لا تُطبَّق نسبة الوزن
    if (manualTotal != null) return;

    final ratios = <double>[];
    if (originalWeight > 0) {
      ratios.add((weight / originalWeight).clamp(0.0, 1.0));
    }
    if (originalQuantity > 0) {
      ratios.add((quantity / originalQuantity).clamp(0.0, 1.0));
    }

    final ratio = ratios.isEmpty
        ? 1.0
        : ratios.reduce((value, element) => element < value ? element : value);

    net = originalNet * ratio;
    tax = originalTax * ratio;
    total = originalTotal * ratio;
    cost = net;
  }

  Map<String, dynamic> toPayload() {
    if (manualTotal == null) recalculateTotals();
    return {
      'item_id': itemId,
      'original_invoice_item_id': originalItemId,
      'name': itemName,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'quantity': quantity,
      'cost': cost,
      'net': net,
      'tax': tax,
      'tax_amount': tax,
      'price': total,
    };
  }
}

class _AddReturnInvoiceScreenState extends State<AddReturnInvoiceScreen> {
  // Stepper state
  int _currentStep = 0;

  // Form Keys
  final _selectInvoiceFormKey = GlobalKey<FormState>();
  final _returnReasonFormKey = GlobalKey<FormState>();
  final _paymentFormKey = GlobalKey<FormState>();

  // Controllers
  final _returnReasonController = TextEditingController();

  // Data
  Map<String, dynamic>? selectedOriginalInvoice;
  List<ReturnItemRow> _returnItems = [];
  bool _isLoadingInvoiceDetails = false;
  String? _invoiceDetailsError;
  String returnReason = '';

  // Currency settings
  double exchangeRate = 1.0;
  String currencySymbol = '\$';
  bool _isNewSar = false;
  String currencyName = 'USD';

  // Payment — multi-method (mirrors sales screen)
  List<Map<String, dynamic>> _paymentMethods = [];
  final List<_ReturnPaymentEntry> _payments = [];
  int? _selectedPaymentMethodId;
  final TextEditingController _customAmountController = TextEditingController();
  // Used when restoring a legacy single-PM edit
  String? _legacyEditPaymentMethod;
  double _legacyEditAmount = 0;

  bool _uiAutoOpenPrintAfterSave = false;
  String _uiPaperSize = 'A4';

  Future<void> _loadInvoiceUiSettingsFromPrefs() async {
    try {
      final loaded = await InvoiceUiSettings.load(InvoiceUiContext.returns);
      if (!mounted) return;
      setState(() {
        _uiAutoOpenPrintAfterSave = loaded.autoOpenPrintAfterSave;
        _uiPaperSize = loaded.paperSize;
      });
    } catch (_) {
      // ignore
    }
  }

  void _resetAfterSave() {
    setState(() {
      _currentStep = 0;
      selectedOriginalInvoice = null;
      _returnItems = [];
      _isLoadingInvoiceDetails = false;
      _invoiceDetailsError = null;
      returnReason = '';
      _payments.clear();
      _selectedPaymentMethodId = null;
      _customAmountController.clear();
      _returnReasonController.clear();
    });
  }

  List<ReturnItemRow> get _selectedItems => _returnItems
      .where(
        (item) => item.isSelected && (item.weight > 0 || item.quantity > 0),
      )
      .toList();

  // Computed totals based on currently selected items
  double get totalWeight =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.weight);
  double get totalCost =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.cost);
  double get totalTax =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.tax);
  double get grandTotal =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.total);
  double get _totalPayments => _payments.fold(0.0, (s, p) => s + p.amount);

  double get _originalInvoiceTotal => _parseDouble(
    selectedOriginalInvoice?['total'] ??
        selectedOriginalInvoice?['total_amount'],
  );

  double get _originalInvoiceWeight =>
      _parseDouble(selectedOriginalInvoice?['total_weight']);

  double? get _enteredPaymentAmount {
    final raw = _customAmountController.text.trim();
    if (raw.isEmpty) return null;
    final parsed = double.tryParse(raw.replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  bool get _isFullReturnSelection {
    if (_returnItems.isEmpty || _selectedItems.length != _returnItems.length) {
      return false;
    }

    for (final item in _returnItems) {
      if (!item.isSelected) return false;
      if ((item.weight - item.originalWeight).abs() > 0.005) return false;
      if (item.quantity != item.originalQuantity) return false;
    }

    return true;
  }

  /// Suggested total: full-weight return → original invoice total, partial → proportional.
  double get _suggestedTotal {
    if (_isFullReturnSelection && _originalInvoiceTotal > 0) {
      return _originalInvoiceTotal;
    }

    if (_originalInvoiceTotal > 0 &&
        _originalInvoiceWeight > 0 &&
        totalWeight > 0) {
      final proportional =
          (_originalInvoiceTotal * (totalWeight / _originalInvoiceWeight));
      return proportional.clamp(0.0, _originalInvoiceTotal).toDouble();
    }

    return grandTotal;
  }

  double get _effectiveReturnTotal => _totalPayments > 0
      ? _totalPayments
      : (_enteredPaymentAmount ?? _suggestedTotal);

  _ReturnPaymentEntry _buildPaymentEntry({
    required Map<String, dynamic> method,
    required double amount,
  }) {
    final rate = method['commission_rate'] as double;
    final commission = double.parse((amount * rate / 100).toStringAsFixed(2));
    final net = double.parse((amount - commission).toStringAsFixed(2));
    return _ReturnPaymentEntry(
      paymentMethodId: method['id'] as int,
      paymentMethodName: (method['name'] ?? '').toString(),
      amount: amount,
      commissionRate: rate,
      commissionAmount: commission,
      netAmount: net,
    );
  }

  bool _capturePayment({bool showErrors = true}) {
    if (_payments.isNotEmpty) return true;

    if (_selectedPaymentMethodId == null) {
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء اختيار وسيلة الدفع')),
        );
      }
      return false;
    }

    final amount = _enteredPaymentAmount;
    if (amount == null || amount <= 0) {
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء إدخال مبلغ المرتجع')),
        );
      }
      return false;
    }

    final method = _paymentMethods.firstWhere(
      (m) => m['id'] == _selectedPaymentMethodId,
      orElse: () => {},
    );
    if (method.isEmpty) {
      if (showErrors) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('وسيلة الدفع المحددة غير متاحة')),
        );
      }
      return false;
    }

    setState(() {
      _payments
        ..clear()
        ..add(_buildPaymentEntry(method: method, amount: amount));
    });
    return true;
  }

  double _parseDouble(dynamic value, [double fallback = 0]) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) {
      final normalized = value.replaceAll(',', '.');
      return double.tryParse(normalized) ?? fallback;
    }
    return fallback;
  }

  int _parseInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  int? _parseOptionalInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool _shouldInterpretReturnItemAmountsAsPerGram(
    Map<String, dynamic> invoiceDetails,
  ) {
    final invoiceTotal = _parseDouble(
      invoiceDetails['total'] ?? invoiceDetails['total_amount'],
    );
    final rawItems = (invoiceDetails['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (invoiceTotal <= 0 || rawItems.isEmpty) return false;

    double baseSum = 0.0;
    double weightedSum = 0.0;

    for (final item in rawItems) {
      final weight = _parseDouble(item['weight']);
      double lineTotal = _parseDouble(item['total']);
      if (lineTotal <= 0) {
        final net = _parseDouble(item['net']);
        final tax = _parseDouble(item['tax']);
        lineTotal = (net > 0 || tax > 0)
            ? (net + tax)
            : _parseDouble(item['price']);
      }
      if (lineTotal <= 0) continue;
      baseSum += lineTotal;
      weightedSum += lineTotal * (weight > 0 ? weight : 1.0);
    }

    if (baseSum <= 0 || weightedSum <= 0) return false;

    final baseDelta = (invoiceTotal - baseSum).abs();
    final weightedDelta = (invoiceTotal - weightedSum).abs();
    final tolerance = math.max(5.0, invoiceTotal * 0.02);

    return weightedDelta <= tolerance &&
        (weightedDelta + tolerance) < baseDelta;
  }

  ReturnItemRow _mapInvoiceItemToReturnRow(
    Map<String, dynamic> item, {
    bool assumePerGramAmounts = false,
  }) {
    final originalWeight = _parseDouble(item['weight']);
    final lineMultiplier = assumePerGramAmounts && originalWeight > 0
        ? originalWeight
        : 1.0;
    final originalTax = _parseDouble(item['tax']) * lineMultiplier;
    double originalNet = _parseDouble(item['net']) * lineMultiplier;
    final originalPriceField = _parseDouble(item['price']) * lineMultiplier;
    double originalTotal = _parseDouble(item['total']) * lineMultiplier;
    final parsedQuantity = _parseInt(item['quantity'], 1);
    final normalizedQuantity = parsedQuantity > 0 ? parsedQuantity : 1;

    // Some historical invoices expose `price` as a price-per-gram-ish value,
    // while `net + tax` carries the real line amount. Prefer explicit total,
    // then net+tax, then fall back to price.
    if (originalTotal <= 0 && (originalNet > 0 || originalTax > 0)) {
      originalTotal = originalNet + originalTax;
    }
    if (originalTotal <= 0) {
      originalTotal = originalPriceField;
    }

    if (originalNet == 0 && originalTotal > 0) {
      originalNet = (originalTotal - originalTax).clamp(0, originalTotal);
    }

    return ReturnItemRow(
      originalItemId: _parseOptionalInt(item['id']),
      itemId: _parseOptionalInt(item['item_id']),
      itemName: (item['name'] as String?)?.trim().isNotEmpty == true
          ? item['name']
          : 'صنف بدون اسم',
      karat: _parseDouble(item['karat'], 21),
      originalWeight: originalWeight,
      originalQuantity: normalizedQuantity,
      originalWage: _parseDouble(item['wage']),
      originalNet: originalNet,
      originalTax: originalTax,
      originalTotal: originalTotal > 0
          ? originalTotal
          : originalNet + originalTax,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrencySettings();
    _loadInvoiceUiSettingsFromPrefs();
    _fetchPaymentMethods();

    // If the caller already knows the original invoice, prefill it and load its details.
    final prefilled = widget.prefilledOriginalInvoice;
    if (prefilled != null) {
      selectedOriginalInvoice = Map<String, dynamic>.from(prefilled);
      final invoiceId = _parseOptionalInt(prefilled['id']);
      if (invoiceId != null) {
        // Move to items selection step after details are loaded.
        _currentStep = 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadOriginalInvoiceDetails(invoiceId);
        });
      }
    }

    // Edit mode: prefill from previously saved return invoice data.
    final editData = widget.editInvoiceData;
    final editId = widget.editInvoiceId;
    if (editData != null && editId != null) {
      _currentStep = 1;
      selectedOriginalInvoice = {
        'id': editData['original_invoice_id'],
        'customer_id': editData['customer_id'],
        'supplier_id': editData['supplier_id'],
        'branch_id': editData['branch_id'],
        'customer_name': editData['customer_name'],
        'supplier_name': editData['supplier_name'],
      };
      _returnItems =
          (editData['items'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(_mapInvoiceItemToReturnRow)
              .toList() ??
          [];
      returnReason = (editData['return_reason'] ?? '').toString();
      _returnReasonController.text = returnReason;
      // Restore payments: prefer payments[] array, fall back to legacy string field
      final savedPayments = editData['payments'];
      if (savedPayments is List && savedPayments.isNotEmpty) {
        for (final p in savedPayments.whereType<Map>()) {
          _payments.add(
            _ReturnPaymentEntry(
              paymentMethodId: _parseInt(p['payment_method_id']),
              paymentMethodName: (p['payment_method_name'] ?? '').toString(),
              amount: _parseDouble(p['amount']),
              commissionRate: _parseDouble(p['commission_rate']),
              commissionAmount: _parseDouble(p['commission_amount']),
              netAmount: _parseDouble(p['net_amount']),
            ),
          );
        }
      } else {
        // Resolve after payment methods are fetched
        _legacyEditPaymentMethod = (editData['payment_method'] ?? 'cash')
            .toString();
        _legacyEditAmount = _parseDouble(editData['amount_paid']);
      }
    }
  }

  @override
  void dispose() {
    _returnReasonController.dispose();
    _customAmountController.dispose();
    super.dispose();
  }

  String _getReturnTypeDisplayName() {
    switch (widget.returnType) {
      case 'مرتجع بيع':
        return 'مرتجع فاتورة بيع';
      case 'مرتجع شراء':
        return 'مرتجع فاتورة شراء من عميل';
      case 'مرتجع شراء (مورد)':
        return 'مرتجع فاتورة شراء';
      default:
        return widget.returnType;
    }
  }

  String _getOriginalInvoiceType() {
    switch (widget.returnType) {
      case 'مرتجع بيع':
        return 'بيع';
      case 'مرتجع شراء':
        return 'شراء من عميل';
      case 'مرتجع شراء (مورد)':
        return 'شراء';
      default:
        return '';
    }
  }

  Future<void> _loadCurrencySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final String? currenciesString = prefs.getString('currencies');
    if (currenciesString != null) {
      final List<dynamic> currencyList = jsonDecode(currenciesString);
      final activeCurrencyData = currencyList.firstWhere(
        (c) => c['isActive'] == true,
        orElse: () => null,
      );
      if (activeCurrencyData != null) {
        final activeCurrency = Currency.fromJson(activeCurrencyData);
        if (mounted) {
          setState(() {
            currencyName = activeCurrency.name;
            currencySymbol = activeCurrency.symbol;
            exchangeRate = activeCurrency.rate;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          currencyName = 'العملة المحلية';
          currencySymbol = context.read<SettingsProvider>().currencySymbolText;
          _isNewSar = context.read<SettingsProvider>().currencyIsNewSar;
          exchangeRate = 3.75;
        });
      }
    }
  }

  // --- Stepper Navigation ---
  void _onStepContinue() {
    bool isStepValid = false;

    switch (_currentStep) {
      case 0: // Select Original Invoice
        if (selectedOriginalInvoice == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الرجاء اختيار الفاتورة الأصلية')),
          );
          isStepValid = false;
        } else {
          isStepValid = true;
        }
        break;

      case 1: // Select Return Items
        if (_selectedItems.isEmpty) {
          final message = _isLoadingInvoiceDetails
              ? 'جاري تحميل أصناف الفاتورة الأصلية...'
              : 'الرجاء اختيار صنف واحد على الأقل للإرجاع';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          isStepValid = false;
        } else {
          isStepValid = true;
        }
        break;

      case 2: // Return Reason
        if (_returnReasonController.text.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الرجاء إدخال سبب الإرجاع')),
          );
          isStepValid = false;
        } else {
          returnReason = _returnReasonController.text.trim();
          isStepValid = true;
        }
        break;

      case 3: // Payment
        isStepValid = _capturePayment(showErrors: true);
        break;

      case 4: // Review
        _showSaveConfirmationDialog();
        isStepValid = false;
        break;
    }

    if (isStepValid && _currentStep < 4) {
      setState(() {
        _currentStep += 1;
      });
    }
  }

  void _onStepCancel() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep -= 1;
      });
    }
  }

  // --- Show Select Original Invoice Dialog ---
  // This method is now replaced by OriginalInvoiceSelector widget

  Future<void> _loadOriginalInvoiceDetails(int invoiceId) async {
    setState(() {
      _isLoadingInvoiceDetails = true;
      _invoiceDetailsError = null;
      _returnItems.clear();
    });

    try {
      final invoiceDetails = await widget.api.getInvoiceById(invoiceId);

      if (!mounted) return;

      final mergedInvoice = {...?selectedOriginalInvoice, ...invoiceDetails};
      final assumePerGramAmounts = _shouldInterpretReturnItemAmountsAsPerGram(
        mergedInvoice,
      );

      final items = (invoiceDetails['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => _mapInvoiceItemToReturnRow(
              item,
              assumePerGramAmounts: assumePerGramAmounts,
            ),
          )
          .toList();

      setState(() {
        selectedOriginalInvoice = mergedInvoice;
        _returnItems = items;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _invoiceDetailsError = 'خطأ في تحميل تفاصيل الفاتورة: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في تحميل تفاصيل الفاتورة: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingInvoiceDetails = false;
        });
      }
    }
  }

  // --- Fetch Payment Methods ---
  Future<void> _fetchPaymentMethods() async {
    try {
      final List<dynamic> methods = await widget.api.getPaymentMethods();
      if (!mounted) return;
      final normalized =
          methods
              .whereType<Map<String, dynamic>>()
              .map<Map<String, dynamic>>((m) {
                final map = Map<String, dynamic>.from(m);
                return {
                  ...map,
                  'id': _parseInt(map['id']),
                  'commission_rate': _parseDouble(map['commission_rate']),
                  'settlement_days': _parseInt(map['settlement_days']),
                  'display_order': _parseInt(map['display_order'], 999),
                };
              })
              .where((m) => m['id'] != null && m['id'] != 0)
              .toList()
            ..sort(
              (a, b) => (a['display_order'] as int).compareTo(
                b['display_order'] as int,
              ),
            );

      if (!mounted) return;
      setState(() {
        _paymentMethods = normalized;
      });

      // Resolve legacy edit-mode payment
      if (_legacyEditPaymentMethod != null &&
          _legacyEditAmount > 0 &&
          _payments.isEmpty) {
        final legacy = _legacyEditPaymentMethod!.toLowerCase();
        final pm = normalized.firstWhere(
          (m) {
            final type = (m['payment_type'] ?? '').toString().toLowerCase();
            final name = (m['name'] ?? '').toString();
            if (legacy == 'cash' || legacy.contains('نقد')) {
              return type == 'cash' || name.contains('نقد');
            }
            if (legacy == 'transfer' || legacy.contains('تحويل')) {
              return name.contains('تحويل') || type == 'bank_transfer';
            }
            if (legacy == 'card' || legacy == 'mada') {
              return type == 'mada' || type == 'card';
            }
            if (legacy == 'deferred' || legacy.contains('آجل')) {
              return type == 'receivable' || type == 'credit';
            }
            return false;
          },
          orElse: () =>
              normalized.isNotEmpty ? normalized.first : <String, dynamic>{},
        );
        if (pm.isNotEmpty) {
          final rate = pm['commission_rate'] as double;
          final commission = double.parse(
            (_legacyEditAmount * rate / 100).toStringAsFixed(2),
          );
          setState(() {
            _payments.add(
              _ReturnPaymentEntry(
                paymentMethodId: pm['id'] as int,
                paymentMethodName: (pm['name'] ?? '').toString(),
                amount: _legacyEditAmount,
                commissionRate: rate,
                commissionAmount: commission,
                netAmount: double.parse(
                  (_legacyEditAmount - commission).toStringAsFixed(2),
                ),
              ),
            );
          });
        }
        _legacyEditPaymentMethod = null;
      }
    } catch (_) {
      // non-fatal — payment methods list stays empty
    }
  }

  void _addPayment({double? customAmount}) {
    if (_selectedPaymentMethodId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('اختر وسيلة الدفع أولاً')));
      return;
    }
    final method = _paymentMethods.firstWhere(
      (m) => m['id'] == _selectedPaymentMethodId,
      orElse: () => {},
    );
    if (method.isEmpty) return;

    final amount = (customAmount ?? _enteredPaymentAmount ?? _suggestedTotal)
        .clamp(0.01, double.infinity);
    if (amount <= 0) return;

    setState(() {
      _payments
        ..clear()
        ..add(_buildPaymentEntry(method: method, amount: amount));
    });
  }

  void _removePayment(int index) {
    setState(() => _payments.removeAt(index));
  }

  // --- Save Return Invoice ---
  Future<void> _saveReturnInvoice() async {
    final selectedItems = _selectedItems;
    if (selectedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء اختيار صنف واحد على الأقل قبل الحفظ'),
        ),
      );
      return;
    }

    final originalBranchId = selectedOriginalInvoice?['branch_id'];
    if (originalBranchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'الفاتورة الأصلية لا تحتوي على فرع. لا يمكن حفظ المرتجع بدون فرع.',
          ),
        ),
      );
      return;
    }

    if (!_capturePayment(showErrors: true)) {
      return;
    }

    final returnItems = selectedItems.map((item) => item.toPayload()).toList();

    final payload = {
      'customer_id': widget.returnType != 'مرتجع شراء (مورد)'
          ? selectedOriginalInvoice!['customer_id']
          : null,
      'supplier_id': widget.returnType == 'مرتجع شراء (مورد)'
          ? selectedOriginalInvoice!['supplier_id']
          : null,
      'branch_id': originalBranchId,
      'date': DateTime.now().toIso8601String(),
      'invoice_type': widget.returnType,
      'original_invoice_id': selectedOriginalInvoice!['id'],
      'return_reason': returnReason,
      'total': _effectiveReturnTotal,
      'total_weight': totalWeight,
      'total_tax': totalTax,
      'total_cost': totalCost,
      'amount_paid': _effectiveReturnTotal,
      'payments': _payments.map((p) => p.toJson()).toList(),
      'items': returnItems,
    };

    try {
      final response = widget.editInvoiceId != null
          ? await widget.api.updateUnpostedInvoice(
              widget.editInvoiceId!,
              payload,
            )
          : await widget.api.addInvoice(payload);
      if (!mounted) return;

      final invoiceForPrint = Map<String, dynamic>.from(response);

      if (selectedOriginalInvoice != null) {
        invoiceForPrint['customer_name'] ??=
            selectedOriginalInvoice!['customer_name'] ??
            selectedOriginalInvoice!['name'];
        invoiceForPrint['supplier_name'] ??=
            selectedOriginalInvoice!['supplier_name'] ??
            selectedOriginalInvoice!['name'];
      }

      final shouldPrint = _uiAutoOpenPrintAfterSave
          ? 'print'
          : await showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) {
                return AlertDialog(
                  title: const Text('تم حفظ المرتجع'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '✅ تم حفظ المرتجع #${invoiceForPrint['id'] ?? ''}\nاختر الإجراء:',
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(dialogContext, 'print'),
                        icon: const Icon(Icons.print),
                        label: const Text('طباعة'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.pop(dialogContext, 'share'),
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('مشاركة'),
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, null),
                        child: const Text('تم'),
                      ),
                    ],
                  ),
                );
              },
            );

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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('تعذر فتح الطباعة: $e')));
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
      if (widget.editInvoiceId != null) {
        Navigator.pop(context, true);
      } else {
        _resetAfterSave();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
      }
    }
  }

  void _showSaveConfirmationDialog() {
    final original = selectedOriginalInvoice;
    final selected = _selectedItems;

    double originalTotal = 0.0;
    double originalTax = 0.0;
    double originalWeight = 0.0;
    String originalDate = '';
    String originalNumber = '';
    String originalParty = '';

    if (original != null) {
      originalTotal = _parseDouble(
        original['total'] ?? original['total_amount'],
      );
      originalTax = _parseDouble(original['total_tax']);
      originalWeight = _parseDouble(original['total_weight']);
      originalDate = (original['date'] ?? '').toString();
      originalNumber = (original['invoice_number'] ?? original['id'] ?? '')
          .toString();
      originalParty =
          (original['customer_name'] ?? original['supplier_name'] ?? '')
              .toString();
    }

    final returnTotal = _effectiveReturnTotal;
    final returnTax = totalTax;
    final returnWeight = totalWeight;

    final deltaTotal = -returnTotal;
    final deltaTax = -returnTax;
    final deltaWeight = -returnWeight;

    String fmt2(num v) => v.toStringAsFixed(2);
    String fmt3(num v) => v.toStringAsFixed(3);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('تأكيد الحفظ (قبل/بعد)'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getReturnTypeDisplayName(),
                    style: Theme.of(dialogContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  // Original invoice summary
                  if (original != null) ...[
                    Text(
                      'الفاتورة الأصلية',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    _buildInfoRow(
                      'الرقم/المعرف',
                      originalNumber.isEmpty ? '-' : originalNumber,
                    ),
                    if (originalDate.isNotEmpty)
                      _buildInfoRow('التاريخ', originalDate),
                    if (originalParty.isNotEmpty)
                      _buildInfoRow('العميل/المورد', originalParty),
                    _buildInfoRow(
                      'إجمالي الأصل',
                      '${fmt2(originalTotal)} $currencySymbol',
                    ),
                    _buildInfoRow(
                      'ضريبة الأصل',
                      '${fmt2(originalTax)} $currencySymbol',
                    ),
                    _buildInfoRow('وزن الأصل', '${fmt3(originalWeight)} جم'),
                    const SizedBox(height: 12),
                  ],

                  // Return summary
                  Text(
                    'المرتجع (سيتم حفظه)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  _buildInfoRow('عدد الأصناف', selected.length.toString()),
                  _buildInfoRow(
                    'إجمالي المرتجع',
                    '${fmt2(returnTotal)} $currencySymbol',
                  ),
                  _buildInfoRow(
                    'ضريبة المرتجع',
                    '${fmt2(returnTax)} $currencySymbol',
                  ),
                  _buildInfoRow('وزن المرتجع', '${fmt3(returnWeight)} جم'),

                  const SizedBox(height: 12),

                  // Deltas
                  Text(
                    'الأثر (Delta)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  _buildInfoRow(
                    'تغيير الإجمالي',
                    '${fmt2(deltaTotal)} $currencySymbol',
                  ),
                  _buildInfoRow(
                    'تغيير الضريبة',
                    '${fmt2(deltaTax)} $currencySymbol',
                  ),
                  _buildInfoRow('تغيير الوزن', '${fmt3(deltaWeight)} جم'),

                  const SizedBox(height: 12),

                  // Per-item diff
                  Text(
                    'تفاصيل الأصناف (قبل → بعد)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (selected.isEmpty)
                    const Text('لا توجد أصناف محددة')
                  else
                    ...selected.map((it) {
                      final weightChanged =
                          (it.weight - it.originalWeight).abs() > 0.0009;
                      final qtyChanged =
                          (it.quantity - it.originalQuantity).abs() > 0;
                      final changed = weightChanged || qtyChanged;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: changed
                                ? Colors.orange.shade300
                                : Colors.grey.shade300,
                            width: changed ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.itemName,
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Text('العيار: ${it.karat.toStringAsFixed(0)}'),
                            const SizedBox(height: 4),
                            Text(
                              'الوزن: ${fmt3(it.originalWeight)} → ${fmt3(it.weight)} جم',
                            ),
                            Text(
                              'الكمية: ${it.originalQuantity} → ${it.quantity}',
                            ),
                          ],
                        ),
                      );
                    }),

                  const SizedBox(height: 4),
                  Text(
                    'ملاحظة: يوصى بالمرتجع بدلاً من تعديل الفاتورة الأصلية للحفاظ على دقة المخزون والحسابات.',
                    style: Theme.of(
                      dialogContext,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('رجوع'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                _saveReturnInvoice();
              },
              icon: const Icon(Icons.save),
              label: const Text('اعتماد وحفظ'),
            ),
          ],
        );
      },
    );
  }

  // --- Build Steps ---

  Widget _buildSelectInvoiceStep() {
    return Form(
      key: _selectInvoiceFormKey,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            'اختر الفاتورة الأصلية',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),

          // Use shared widget
          OriginalInvoiceSelector(
            api: widget.api,
            invoiceType: _getOriginalInvoiceType(),
            selectedInvoice: selectedOriginalInvoice,
            onInvoiceSelected: (invoice) {
              setState(() {
                selectedOriginalInvoice = invoice;
              });
              if (invoice['id'] != null) {
                _loadOriginalInvoiceDetails(invoice['id']);
              }
            },
          ),

          // Show invoice details if selected
          if (selectedOriginalInvoice != null) ...[
            const SizedBox(height: 16),
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'تفاصيل الفاتورة',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Divider(),
                    _buildInfoRow(
                      'التاريخ',
                      selectedOriginalInvoice!['date'] ?? 'غير متوفر',
                    ),
                    _buildInfoRow(
                      'المبلغ',
                      '${_originalInvoiceTotal.toStringAsFixed(2)} $currencySymbol',
                    ),
                    if (selectedOriginalInvoice!['customer_name'] != null)
                      _buildInfoRow(
                        'العميل',
                        selectedOriginalInvoice!['customer_name'],
                      ),
                    if (selectedOriginalInvoice!['supplier_name'] != null)
                      _buildInfoRow(
                        'المورد',
                        selectedOriginalInvoice!['supplier_name'],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          cu.SarAwareText(value, isNewSar: _isNewSar),
        ],
      ),
    );
  }

  Widget _buildItemSummaryChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Chip(
      avatar: Icon(icon, size: 18, color: Colors.black87),
      label: cu.SarAwareText('$label: $value', isNewSar: _isNewSar),
      backgroundColor: Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  Widget _buildSelectItemsStep() {
    Widget content;

    if (_isLoadingInvoiceDetails) {
      content = const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_invoiceDetailsError != null) {
      content = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              _invoiceDetailsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
      );
    } else if (_returnItems.isEmpty) {
      content = const Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'سيتم عرض أصناف الفاتورة الأصلية هنا بعد الاختيار',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    } else {
      content = SizedBox(
        height: 320,
        child: ListView.separated(
          itemCount: _returnItems.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final item = _returnItems[index];
            return Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      value: item.isSelected,
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.itemName),
                      subtitle: Text(
                        'عيار ${item.karat} • وزن أصلي ${item.originalWeight.toStringAsFixed(3)} جم',
                      ),
                      onChanged: (value) {
                        setState(() {
                          item.isSelected = value ?? false;
                          item.recalculateTotals();
                        });
                      },
                    ),
                    if (item.isSelected) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: ValueKey(
                                'weight-${item.originalItemId}-$index',
                              ),
                              initialValue: item.weight.toStringAsFixed(3),
                              decoration: InputDecoration(
                                labelText: 'الوزن المرتجع (جم)',
                                helperText:
                                    'الأقصى ${item.originalWeight.toStringAsFixed(3)} جم',
                                border: const OutlineInputBorder(),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [NormalizeNumberFormatter()],
                              onChanged: (value) {
                                final newWeight =
                                    double.tryParse(
                                      value.replaceAll(',', '.'),
                                    ) ??
                                    item.weight;
                                setState(() {
                                  item.updateWeight(newWeight);
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (item.originalQuantity > 1)
                            Expanded(
                              child: TextFormField(
                                key: ValueKey(
                                  'qty-${item.originalItemId}-$index',
                                ),
                                initialValue: item.quantity.toString(),
                                decoration: InputDecoration(
                                  labelText: 'الكمية المرتجعة',
                                  helperText: 'الأقصى ${item.originalQuantity}',
                                  border: const OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [NormalizeNumberFormatter()],
                                onChanged: (value) {
                                  final newQty =
                                      int.tryParse(value) ?? item.quantity;
                                  setState(() {
                                    item.updateQuantity(newQty);
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          _buildItemSummaryChip(
                            icon: Icons.scale,
                            label: 'الوزن',
                            value: '${item.weight.toStringAsFixed(3)} جم',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.attach_money,
                            label: 'الصافي',
                            value:
                                '${item.net.toStringAsFixed(2)} $currencySymbol',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.percent,
                            label: 'الضريبة',
                            value:
                                '${item.tax.toStringAsFixed(2)} $currencySymbol',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.summarize,
                            label: 'الإجمالي',
                            value:
                                '${item.total.toStringAsFixed(2)} $currencySymbol',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'اختر الأصناف المرتجعة',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        content,
        const SizedBox(height: 16),
        ElevatedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('إضافة صنف يدوياً'),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('سيتم إضافة هذه الميزة قريباً')),
            );
          },
        ),
      ],
    );
  }

  Widget _buildReturnReasonStep() {
    return Form(
      key: _returnReasonFormKey,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text('سبب الإرجاع', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),
          // Use shared widget
          ReturnReasonInput(
            controller: _returnReasonController,
            isRequired: true,
            maxLines: 4,
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentStep() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Auto-fill: full weight → original invoice total, partial → proportional
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final existing =
          double.tryParse(_customAmountController.text.replaceAll(',', '.')) ??
          0;
      if (existing <= 0 && _payments.isEmpty && _suggestedTotal > 0.005) {
        _customAmountController.text = _suggestedTotal.toStringAsFixed(2);
      }
    });

    return Form(
      key: _paymentFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),

          // ── Totals chip ──────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('وسائل الدفع', style: theme.textTheme.titleLarge),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: isDark ? 0.25 : 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.4)),
                ),
                child: cu.SarAwareText(
                  'القيمة المرجعية حسب الوزن: ${_suggestedTotal.toStringAsFixed(2)} $currencySymbol',
                  isNewSar: _isNewSar,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Added payments table ─────────────────────────────────────
          if (_payments.isNotEmpty) ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: cs.primary.withValues(alpha: 0.4),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: isDark ? 0.25 : 0.15),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(6),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            'الوسيلة',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'المبلغ',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'عمولة',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            'صافي',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 40),
                      ],
                    ),
                  ),
                  // Rows
                  ...List.generate(_payments.length, (i) {
                    final p = _payments[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: i % 2 == 0
                            ? theme.colorScheme.surface
                            : theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: isDark ? 0.3 : 0.5),
                        border: Border(
                          bottom: BorderSide(
                            color: theme.dividerColor.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  p.paymentMethodName,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (p.commissionRate > 0)
                                  Text(
                                    'عمولة ${p.commissionRate}%',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.orange,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: cu.SarAwareText(
                              '${p.amount.toStringAsFixed(2)} $currencySymbol',
                              isNewSar: _isNewSar,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.green,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: cu.SarAwareText(
                              p.commissionAmount > 0
                                  ? '${p.commissionAmount.toStringAsFixed(2)} $currencySymbol'
                                  : '-',
                              isNewSar: _isNewSar,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: p.commissionAmount > 0
                                    ? Colors.red
                                    : theme.disabledColor,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: cu.SarAwareText(
                              '${p.netAmount.toStringAsFixed(2)} $currencySymbol',
                              isNewSar: _isNewSar,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: cs.primary,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 40,
                            child: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              color: Colors.red,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _removePayment(i),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  // Totals row
                  if (_payments.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(
                          alpha: isDark ? 0.15 : 0.08,
                        ),
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(6),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              'الإجمالي',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: cu.SarAwareText(
                              '${_totalPayments.toStringAsFixed(2)} $currencySymbol',
                              isNewSar: _isNewSar,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text('', textAlign: TextAlign.center),
                          ),
                          Expanded(flex: 2, child: Text('')),
                          const SizedBox(width: 40),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Status chip ───────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _payments.isEmpty
                  ? Colors.orange.withValues(alpha: isDark ? 0.2 : 0.12)
                  : Colors.green.withValues(alpha: isDark ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _payments.isEmpty
                    ? Colors.orange.withValues(alpha: 0.5)
                    : Colors.green.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _payments.isNotEmpty
                      ? '✓ المبلغ المعتمد'
                      : (_enteredPaymentAmount != null
                            ? 'المبلغ المدخل'
                            : 'المبلغ المقترح'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _payments.isEmpty ? Colors.orange : Colors.green,
                  ),
                ),
                cu.SarAwareText(
                  '${_effectiveReturnTotal.toStringAsFixed(2)} $currencySymbol',
                  isNewSar: _isNewSar,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _payments.isEmpty ? Colors.orange : Colors.green,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── Add payment row (only if no payment added yet — single payment) ──
          if (_payments.isEmpty) ...[
            Text(
              'إضافة وسيلة دفع',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (_paymentMethods.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                ),
              )
            else ...[
              DropdownButtonFormField<int>(
                value: _selectedPaymentMethodId,
                decoration: const InputDecoration(
                  labelText: 'وسيلة الدفع',
                  border: OutlineInputBorder(),
                ),
                items: _paymentMethods.map((m) {
                  final commission = m['commission_rate'] as double;
                  final label = commission > 0
                      ? '${m['name']} (${commission.toStringAsFixed(1)}%)'
                      : '${m['name']}';
                  return DropdownMenuItem<int>(
                    value: m['id'] as int,
                    child: Text(label),
                  );
                }).toList(),
                onChanged: (v) {
                  setState(() => _selectedPaymentMethodId = v);
                  if ((_enteredPaymentAmount ?? 0) <= 0 && _payments.isEmpty) {
                    _customAmountController.text = _suggestedTotal
                        .toStringAsFixed(2);
                  }
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _customAmountController,
                      decoration: InputDecoration(
                        labelText: 'المبلغ المسترجع (المعتمد للتسوية)',
                        border: const OutlineInputBorder(),
                        suffixText: currencySymbol,
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة'),
                    onPressed: () {
                      final txt = _customAmountController.text.trim();
                      final custom = txt.isEmpty
                          ? null
                          : double.tryParse(txt.replaceAll(',', '.'));
                      _addPayment(customAmount: custom);
                    },
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildReviewStep() {
    final invoice = selectedOriginalInvoice;
    if (invoice == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('الرجاء اختيار الفاتورة الأصلية قبل المتابعة'),
        ),
      );
    }

    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
    final invoiceDate = invoice['date'] ?? 'غير متوفر';
    final invoiceTotalRaw = invoice['total'] ?? invoice['total_amount'] ?? 0;
    final invoiceTotal = invoiceTotalRaw is num
        ? invoiceTotalRaw.toStringAsFixed(2)
        : invoiceTotalRaw.toString();
    final invoiceCustomer = invoice['customer_name'];
    final invoiceSupplier = invoice['supplier_name'];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text('مراجعة المرتجع', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),

          // Original Invoice Info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'الفاتورة الأصلية',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  _buildInfoRow('رقم الفاتورة', invoiceDisplayNumber),
                  _buildInfoRow('التاريخ', invoiceDate),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Return Reason
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'سبب الإرجاع',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  Text(returnReason),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          if (_selectedItems.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'الأصناف المرتجعة',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    ..._selectedItems.map(
                      (item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                item.itemName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${item.weight.toStringAsFixed(3)} جم',
                              style: const TextStyle(color: Colors.black54),
                            ),
                            const SizedBox(width: 8),
                            cu.SarAwareText(
                              '${item.total.toStringAsFixed(2)} $currencySymbol',
                              isNewSar: _isNewSar,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_selectedItems.isNotEmpty) const SizedBox(height: 16),

          // Totals
          Card(
            color: Colors.amber.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildTotalRow(
                    'الوزن الإجمالي',
                    '${totalWeight.toStringAsFixed(2)} جم',
                  ),
                  _buildTotalRow(
                    'صافي الأصناف',
                    '${totalCost.toStringAsFixed(2)} $currencySymbol',
                  ),
                  _buildTotalRow(
                    'ضريبة الأصناف',
                    '${totalTax.toStringAsFixed(2)} $currencySymbol',
                  ),
                  const Divider(),
                  _buildTotalRow(
                    'الإجمالي المعتمد',
                    '${_effectiveReturnTotal.toStringAsFixed(2)} $currencySymbol',
                    isTotal: true,
                  ),
                ],
              ),
            ),
          ),
          if (invoiceCustomer != null || invoiceSupplier != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'الأطراف المرتبطة',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    if (invoiceCustomer != null)
                      _buildInfoRow('العميل', invoiceCustomer),
                    if (invoiceSupplier != null)
                      _buildInfoRow('المورد', invoiceSupplier),
                    _buildInfoRow(
                      'إجمالي الفاتورة الأصلية',
                      '$invoiceTotal $currencySymbol',
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getInvoiceDisplayNumber(Map<String, dynamic> invoice) {
    final rawNumber = invoice['invoice_number'];
    if (rawNumber != null) {
      final trimmed = rawNumber.toString().trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    final legacyNumber = invoice['number'];
    if (legacyNumber != null) {
      final legacyStr = legacyNumber.toString().trim();
      if (legacyStr.isNotEmpty) {
        return '#$legacyStr';
      }
    }

    final legacyId = invoice['id'];
    return legacyId != null ? '#${legacyId.toString()}' : '#---';
  }

  Widget _buildTotalRow(String label, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 18 : 14,
            ),
          ),
          cu.SarAwareText(
            value,
            isNewSar: _isNewSar,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 18 : 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_getReturnTypeDisplayName()),
        backgroundColor: AppSemanticColors.invoiceBar(
          context,
          InvoiceKind.returned,
        ).background,
        foregroundColor: AppSemanticColors.invoiceBar(
          context,
          InvoiceKind.returned,
        ).foreground,
        iconTheme: IconThemeData(
          color: AppSemanticColors.invoiceBar(
            context,
            InvoiceKind.returned,
          ).foreground,
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
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'إعدادات الفاتورة',
            onPressed: () {
              InvoiceSettingsSheet.show(
                context,
                contextType: InvoiceUiContext.returns,
                supportsVatToggle: false,
                supportsLockEdits: false,
                supportsAutoOpenPrint: true,
                onChanged: (next) {
                  setState(() {
                    _uiAutoOpenPrintAfterSave = next.autoOpenPrintAfterSave;
                    _uiPaperSize = next.paperSize;
                  });
                },
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: Stepper(
              currentStep: _currentStep,
              onStepContinue: _onStepContinue,
              onStepCancel: _onStepCancel,
              controlsBuilder: (context, details) {
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    children: [
                      ElevatedButton(
                        onPressed: details.onStepContinue,
                        child: Text(_currentStep == 4 ? 'حفظ' : 'التالي'),
                      ),
                      const SizedBox(width: 8),
                      if (_currentStep > 0)
                        TextButton(
                          onPressed: details.onStepCancel,
                          child: const Text('السابق'),
                        ),
                    ],
                  ),
                );
              },
              steps: [
                Step(
                  title: const Text('اختيار الفاتورة'),
                  content: _buildSelectInvoiceStep(),
                  isActive: _currentStep >= 0,
                  state: _currentStep > 0
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('الأصناف المرتجعة'),
                  content: _buildSelectItemsStep(),
                  isActive: _currentStep >= 1,
                  state: _currentStep > 1
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('سبب الإرجاع'),
                  content: _buildReturnReasonStep(),
                  isActive: _currentStep >= 2,
                  state: _currentStep > 2
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('الدفع'),
                  content: _buildPaymentStep(),
                  isActive: _currentStep >= 3,
                  state: _currentStep > 3
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('مراجعة'),
                  content: _buildReviewStep(),
                  isActive: _currentStep >= 4,
                  state: StepState.indexed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
