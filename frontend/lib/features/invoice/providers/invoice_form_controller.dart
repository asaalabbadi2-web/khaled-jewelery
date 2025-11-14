import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../api_service.dart';
import '../models/invoice_flow_config.dart';
import '../models/invoice_item_row.dart';

class InvoiceSubmissionResult {
  final bool success;
  final List<String> errors;
  final Map<String, dynamic>? response;
  final Map<String, dynamic>? payload;

  const InvoiceSubmissionResult._({
    required this.success,
    required this.errors,
    this.response,
    this.payload,
  });

  factory InvoiceSubmissionResult.success(Map<String, dynamic> response) {
    return InvoiceSubmissionResult._(
      success: true,
      errors: const [],
      response: response,
    );
  }

  factory InvoiceSubmissionResult.failure(
    List<String> errors, {
    Map<String, dynamic>? payload,
  }) {
    return InvoiceSubmissionResult._(
      success: false,
      errors: errors,
      payload: payload,
    );
  }
}

class InvoiceFormController extends ChangeNotifier {
  InvoiceFormController({
    required this.api,
    required this.config,
    required List<Map<String, dynamic>> customers,
  }) : _customers = List<Map<String, dynamic>>.from(customers),
       _taxRate = config.defaultTaxRate {
    fetchGoldPrice();
  }

  final ApiService api;
  final InvoiceFlowConfig config;

  final List<Map<String, dynamic>> _customers;
  final List<InvoiceItemRow> _items = [];

  Map<String, dynamic>? _selectedCustomer;

  double _goldPrice24k = 0;
  double _exchangeRate = 1;
  double _taxRate;

  bool _isLoadingPrice = false;
  bool _isSubmitting = false;

  double paymentGoldWeight = 0;
  double paymentGoldKarat = 21;
  double settledGoldWeight = 0;
  double settledWageAmount = 0;
  String wagePaymentMethod = 'gold';
  String notes = '';

  // Getters
  List<Map<String, dynamic>> get customers => List.unmodifiable(_customers);
  Map<String, dynamic>? get selectedCustomer => _selectedCustomer;
  List<InvoiceItemRow> get items => List.unmodifiable(_items);
  bool get isLoadingPrice => _isLoadingPrice;
  bool get isSubmitting => _isSubmitting;
  double get goldPrice24k => _goldPrice24k;
  double get exchangeRate => _exchangeRate;
  double get taxRate => config.allowsTax ? _taxRate : 0.0;

  double get totalNet => _items.fold(0.0, (sum, item) => sum + item.net);
  double get totalTax =>
      config.allowsTax ? _items.fold(0.0, (sum, item) => sum + item.tax) : 0.0;
  double get totalCost => _items.fold(0.0, (sum, item) => sum + item.cost);
  double get totalWeight => _items.fold(0.0, (sum, item) => sum + item.weight);
  double get totalWeight21k => _items.fold(
    0.0,
    (sum, item) => sum + _convertToMainKarat(item.weight, item.karat),
  );
  double get totalWage => _items.fold(0.0, (sum, item) => sum + item.totalWage);

  double get paymentGoldWeight21k =>
      _convertToMainKarat(paymentGoldWeight, paymentGoldKarat);
  double get netGoldDifference21k =>
      totalWeight21k - paymentGoldWeight21k - settledGoldWeight;

  double get wageInGold21k {
    final goldPrice21k = _goldPrice24k > 0
        ? (_goldPrice24k / 24.0) * 21.0 * _exchangeRate
        : 0.0;
    if (goldPrice21k <= 0) return 0.0;
    return totalWage / goldPrice21k;
  }

  void setNotes(String value) {
    notes = value;
    notifyListeners();
  }

  void setPaymentGoldWeight(double value) {
    paymentGoldWeight = math.max(0, value);
    notifyListeners();
  }

  void setPaymentGoldKarat(double value) {
    paymentGoldKarat = value.clamp(1, 24).toDouble();
    notifyListeners();
  }

  void setSettledGoldWeight(double value) {
    settledGoldWeight = math.max(0, value);
    notifyListeners();
  }

  void setSettledWageAmount(double value) {
    settledWageAmount = math.max(0, value);
    notifyListeners();
  }

  void setWagePaymentMethod(String method) {
    if (method == 'gold' || method == 'cash') {
      wagePaymentMethod = method;
      notifyListeners();
    }
  }

  void setGoldPrice24k(double value) {
    _goldPrice24k = math.max(0, value);
    _recalculateAllItems();
    notifyListeners();
  }

  void setExchangeRate(double value) {
    _exchangeRate = value <= 0 ? 1 : value;
    _recalculateAllItems();
    notifyListeners();
  }

  void setTaxRate(double value) {
    _taxRate = value < 0 ? 0 : value;
    _recalculateAllItems();
    notifyListeners();
  }

  Future<void> fetchGoldPrice() async {
    _isLoadingPrice = true;
    notifyListeners();
    try {
      final response = await api.getGoldPrice();
      final parsedPrice = _parseGoldPrice(response);
      if (parsedPrice != null) {
        _goldPrice24k = parsedPrice;
      }
      final parsedExchange = _parseExchangeRate(response);
      if (parsedExchange != null && parsedExchange > 0) {
        _exchangeRate = parsedExchange;
      }
    } catch (e) {
      debugPrint('⚠️ Failed to fetch gold price: $e');
    } finally {
      _isLoadingPrice = false;
      _recalculateAllItems();
      notifyListeners();
    }
  }

  void addCustomer(Map<String, dynamic> customer) {
    _customers.add(customer);
    notifyListeners();
  }

  void updateCustomer(Map<String, dynamic> customer) {
    final index = _customers.indexWhere((c) => c['id'] == customer['id']);
    if (index != -1) {
      _customers[index] = customer;
    } else {
      _customers.add(customer);
    }
    if (_selectedCustomer != null &&
        _selectedCustomer!['id'] == customer['id']) {
      _selectedCustomer = customer;
    }
    notifyListeners();
  }

  void selectCustomerById(int? id) {
    if (id == null) {
      _selectedCustomer = null;
      notifyListeners();
      return;
    }
    try {
      final customer = _customers.firstWhere((c) => c['id'] == id);
      _selectedCustomer = customer;
      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ Customer with id=$id not found: $e');
    }
  }

  void addItem(InvoiceItemRow row) {
    final calculated = _applyCalculations(row);
    _items.add(calculated);
    notifyListeners();
  }

  void updateItem(int index, InvoiceItemRow row) {
    if (index < 0 || index >= _items.length) return;
    _items[index] = _applyCalculations(row);
    notifyListeners();
  }

  void removeItemAt(int index) {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    notifyListeners();
  }

  List<String> validate() {
    final errors = <String>[];

    if (_selectedCustomer == null) {
      errors.add('يرجى اختيار العميل قبل المتابعة.');
    }

    if (config.requiresIdentity && _selectedCustomer != null) {
      final idNumber = (_selectedCustomer!['id_number'] ?? '')
          .toString()
          .trim();
      final birthDate = (_selectedCustomer!['birth_date'] ?? '')
          .toString()
          .trim();
      final idVersion = (_selectedCustomer!['id_version_number'] ?? '')
          .toString()
          .trim();

      if (idNumber.isEmpty) {
        errors.add('رقم هوية العميل إلزامي لعمليات بيع الكسر.');
      }
      if (birthDate.isEmpty && idVersion.isEmpty) {
        errors.add('يرجى تسجيل تاريخ الميلاد أو رقم نسخة الهوية للعميل.');
      }
    }

    if (_items.isEmpty) {
      errors.add('أضف صنفاً واحداً على الأقل إلى الفاتورة.');
    }

    if (totalWeight <= 0) {
      errors.add('إجمالي الوزن يجب أن يكون أكبر من صفر.');
    }

    if (config.supportsGoldSettlement && paymentGoldWeight < 0) {
      errors.add('وزن الذهب المستلم لا يمكن أن يكون سالباً.');
    }

    return errors;
  }

  Map<String, dynamic> buildPayload({DateTime? date}) {
    final invoiceDate = date ?? DateTime.now();
    return {
      'invoice_type': config.invoiceType,
      'transaction_type': config.transactionType,
      'gold_type': config.goldType,
      'customer_id': _selectedCustomer?['id'],
      'date': invoiceDate.toIso8601String(),
      'items': _items
          .map(
            (item) => {
              'item_id': item.itemId,
              'name': item.itemName,
              'karat': item.karat,
              'weight': item.weight,
              'wage': item.wage,
              'quantity': item.count,
              'price': item.total,
              'net': item.net,
              'tax': config.allowsTax ? item.tax : 0.0,
            },
          )
          .toList(),
      'total': totalNet,
      'total_cost': totalCost,
      'total_tax': totalTax,
      'total_weight': totalWeight,
      'amount_paid': 0,
      'payments': <Map<String, dynamic>>[],
      'payment_gold_weight': paymentGoldWeight,
      'payment_gold_karat': paymentGoldKarat,
      'net_gold_difference_21k': netGoldDifference21k,
      'total_wage': totalWage,
      'wage_in_gold_21k': wageInGold21k,
      'settled_gold_weight': settledGoldWeight,
      'settled_wage_amount': settledWageAmount,
      'wage_payment_method': wagePaymentMethod,
      'notes': notes.isEmpty ? null : notes,
    };
  }

  Future<InvoiceSubmissionResult> submit() async {
    final errors = validate();
    if (errors.isNotEmpty) {
      return InvoiceSubmissionResult.failure(errors);
    }

    final payload = buildPayload();
    _isSubmitting = true;
    notifyListeners();

    try {
      final response = await api.addInvoice(payload);
      _isSubmitting = false;
      notifyListeners();
      return InvoiceSubmissionResult.success(response);
    } catch (e) {
      _isSubmitting = false;
      notifyListeners();
      return InvoiceSubmissionResult.failure([
        'فشل إرسال الفاتورة: $e',
      ], payload: payload);
    }
  }

  // Helpers
  void _recalculateAllItems() {
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _applyCalculations(_items[i]);
    }
  }

  InvoiceItemRow _applyCalculations(InvoiceItemRow row) {
    return row.withCalculations(
      goldPrice24k: _goldPrice24k,
      exchangeRate: _exchangeRate,
      taxRate: taxRate,
    );
  }

  double _convertToMainKarat(double weight, double karat) {
    if (weight <= 0) return 0.0;
    if (karat <= 0) return weight;
    return weight * (karat / 21.0);
  }

  double? _parseGoldPrice(Map<String, dynamic> response) {
    final candidates = [
      response['price_24k'],
      response['price24k'],
      response['gold_price_24k'],
      response['price'],
      response['price_usd_per_oz'],
    ];

    for (final candidate in candidates) {
      final value = _toDouble(candidate);
      if (value != null && value > 0) {
        // إذا كان السعر بالاونصة نحوله إلى جرام 24K
        if (response.containsKey('price_usd_per_oz') ||
            (candidate == response['price'])) {
          return value / 31.1035;
        }
        return value;
      }
    }
    return null;
  }

  double? _parseExchangeRate(Map<String, dynamic> response) {
    final candidates = [response['exchange_rate'], response['currency_rate']];
    for (final candidate in candidates) {
      final value = _toDouble(candidate);
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}
