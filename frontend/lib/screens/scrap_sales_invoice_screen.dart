import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';

/// شاشة فاتورة بيع الكسر - النسخة الهجينة المحسّنة
/// تجمع بين Smart Input (Progressive) و DataTable (Professional)
class ScrapSalesInvoiceScreen extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> customers;

  const ScrapSalesInvoiceScreen({
    Key? key,
    required this.items,
    required this.customers,
  }) : super(key: key);

  @override
  State<ScrapSalesInvoiceScreen> createState() =>
      _ScrapSalesInvoiceScreenState();
}

class _ScrapSalesInvoiceScreenState extends State<ScrapSalesInvoiceScreen> {
  // ==================== State Variables ====================
  final _smartInputController = TextEditingController();
  final _smartInputFocus = FocusNode();
  final _customAmountController = TextEditingController(); // 🆕 للمبلغ المخصص

  // Customer
  int? _selectedCustomerId;

  // Items List
  final List<InvoiceItem> _items = [];

  // Gold Price & Settings
  double _goldPrice24k = 0.0;
  late SettingsProvider _settingsProvider;

  // Payment - 🆕 وسائل دفع متعددة
  List<Map<String, dynamic>> _paymentMethods = [];
  List<PaymentEntry> _payments = []; // 🆕 قائمة الدفعات المضافة
  int? _selectedPaymentMethodId; // للـ Dropdown

  // 🆕 الخزائن
  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadPaymentMethods(); // 🆕 جلب وسائل الدفع
    _loadDefaultSafeBox(); // 🆕 تحميل الخزينة
    _smartInputFocus.requestFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settingsProvider = Provider.of<SettingsProvider>(context);
  }

  @override
  void dispose() {
    _smartInputController.dispose();
    _smartInputFocus.dispose();
    _customAmountController.dispose(); // 🆕
    super.dispose();
  }

  // ==================== Data Loading ====================
  Future<void> _loadSettings() async {
    try {
      final apiService = ApiService();
      final priceData = await apiService.getGoldPrice();
      if (!mounted) return;
      setState(() {
        _goldPrice24k = _parseDouble(priceData['price_24k']);
      });
    } catch (e) {
      _showError('فشل تحميل سعر الذهب: $e');
    }
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  // 🆕 جلب وسائل الدفع النشطة
  Future<void> _loadPaymentMethods() async {
    try {
      final apiService = ApiService();
      final methods = await apiService
          .getActivePaymentMethods(); // ✅ استخدام getActivePaymentMethods بدلاً من getPaymentMethods
      if (!mounted) return;

      final normalizedMethods = methods
          .whereType<Map<String, dynamic>>()
          .map<Map<String, dynamic>>((method) {
            final map = Map<String, dynamic>.from(method);
            final id = _parseInt(map['id']);
            final commission = _parseDouble(map['commission_rate']);
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
      });
    } catch (e) {
      _showError('فشل تحميل وسائل الدفع: $e');
    }
  }

  // 🆕 تحميل الخزينة النقدية الافتراضية
  Future<void> _loadDefaultSafeBox() async {
    try {
      final apiService = ApiService();
      final boxes = await apiService.getSafeBoxes();
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

  // 🆕 إضافة دفعة جديدة
  void _addPayment({double? customAmount}) {
    if (_selectedPaymentMethodId == null) {
      _showError('اختر وسيلة الدفع');
      return;
    }

    final method = _paymentMethods.firstWhere(
      (m) => m['id'] == _selectedPaymentMethodId,
    );

    final total = _calculateGrandTotal();
    final alreadyPaid = _payments.fold<double>(0, (sum, p) => sum + p.amount);
    final remaining = double.parse(
      (total - alreadyPaid).toStringAsFixed(2),
    ); // تقريب لتجنب مشاكل الدقة

    if (remaining <= 0.01) {
      // استخدام threshold بدلاً من 0
      _showError('تم دفع المبلغ بالكامل');
      return;
    }

    // استخدام المبلغ المخصص أو المتبقي
    final amount = customAmount ?? remaining;

    if (amount > remaining + 0.01) {
      // إضافة tolerance صغير
      _showError(
        'المبلغ أكبر من المتبقي (${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbol})',
      );
      return;
    }

    if (amount <= 0) {
      _showError('المبلغ يجب أن يكون أكبر من صفر');
      return;
    }

    // ✅ استخدام commission_rate بدلاً من commission
    final rate = (method['commission_rate'] ?? 0.0) is String
        ? double.tryParse(method['commission_rate'].toString()) ?? 0.0
        : (method['commission_rate'] ?? 0.0).toDouble();

    // تقريب العمولة لمنزلتين عشريتين لتجنب مشاكل الدقة
    final commission = double.parse((amount * (rate / 100)).toStringAsFixed(2));
    // حساب ضريبة القيمة المضافة على العمولة بحسب الإعدادات
    final commissionVat = double.parse(
      (commission * _settingsProvider.taxRate).toStringAsFixed(2),
    );
    // الصافي = المبلغ - العمولة - ضريبة العمولة
    final net = double.parse(
      (amount - commission - commissionVat).toStringAsFixed(2),
    );

    setState(() {
      _payments.add(
        PaymentEntry(
          paymentMethodId: method['id'],
          paymentMethodName: method['name'],
          amount: amount,
          commissionRate: rate,
          commissionAmount: commission,
          commissionVat: commissionVat,
          netAmount: net,
          settlementDays: method['settlement_days'] ?? 0,
        ),
      );

      // إعادة تعيين الحقول
      _customAmountController.clear();
      _selectedPaymentMethodId = null;
    });
  }

  // 🆕 حذف دفعة
  void _removePayment(int index) {
    setState(() {
      _payments.removeAt(index);
    });
  }

  // 🆕 حساب إجماليات الدفعات
  double get _totalPayments =>
      _payments.fold<double>(0, (sum, p) => sum + p.amount);
  double get _totalCommission =>
      _payments.fold<double>(0, (sum, p) => sum + p.commissionAmount);
  double get _totalCommissionVAT =>
      _payments.fold<double>(0, (sum, p) => sum + p.commissionVat);
  double get _totalNet =>
      _payments.fold<double>(0, (sum, p) => sum + p.netAmount);
  double get _remainingAmount {
    final remaining = _calculateGrandTotal() - _totalPayments;
    // تجاهل الفروقات الصغيرة (أقل من 0.01 ريال)
    return remaining.abs() < 0.01 ? 0.0 : remaining;
  }

  // ملاحظة: _isFullyPaid غير مستخدم حالياً - يمكن حذفه لاحقاً
  // bool get _isFullyPaid {
  //   final remaining = (_calculateGrandTotal() - _totalPayments).abs();
  //   return remaining < 0.01;  // tolerance = 1 قرش
  // }

  // ==================== Smart Input Processing ====================
  Future<void> _processSmartInput(String input) async {
    if (input.trim().isEmpty) return;

    debugPrint('🔍 البحث عن: "$input"');
    debugPrint('📦 عدد الأصناف المتاحة: ${widget.items.length}');

    try {
      // البحث بالترتيب: Barcode → Item Code → Name
      Map<String, dynamic>? foundItem;

      // 1. البحث بالباركود
      foundItem = widget.items.firstWhere((item) {
        final barcode = item['barcode']?.toString().toLowerCase();
        final match = barcode == input.toLowerCase();
        if (match) debugPrint('✅ تطابق بالباركود: ${item['name']}');
        return match;
      }, orElse: () => {});

      // 2. البحث برقم الصنف
      if (foundItem.isEmpty) {
        foundItem = widget.items.firstWhere((item) {
          final code = item['item_code']?.toString().toLowerCase();
          final match = code == input.toLowerCase();
          if (match) debugPrint('✅ تطابق برقم الصنف: ${item['name']}');
          return match;
        }, orElse: () => {});
      }

      // 3. البحث بالاسم
      if (foundItem.isEmpty) {
        foundItem = widget.items.firstWhere((item) {
          final name = item['name']?.toString().toLowerCase();
          final match = name?.contains(input.toLowerCase()) ?? false;
          if (match) debugPrint('✅ تطابق بالاسم: ${item['name']}');
          return match;
        }, orElse: () => {});
      }

      if (foundItem.isNotEmpty) {
        debugPrint('✨ تمت إضافة: ${foundItem['name']}');
        _addItemFromData(foundItem);
        _smartInputController.clear();
        _smartInputFocus.requestFocus();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ تمت إضافة: ${foundItem['name']}'),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        debugPrint('❌ لم يتم العثور على الصنف');
        _showError('⚠️ لم يتم العثور على الصنف');
      }
    } catch (e) {
      debugPrint('🔴 خطأ في البحث: $e');
      _showError('خطأ في البحث: $e');
    }
  }

  Future<void> _addItemFromData(Map<String, dynamic> itemData) async {
    debugPrint('➕ إضافة صنف: ${itemData['name']} (ID: ${itemData['id']})');
    debugPrint(
      '   البيانات الخام: karat=${itemData['karat']}, wage=${itemData['wage']}',
    );

    // تحديث سعر الذهب قبل إضافة الصنف
    try {
      final apiService = ApiService();
      final priceData = await apiService.getGoldPrice();
      final newPrice = _parseDouble(priceData['price_24k']);
      if (newPrice > 0) {
        if (mounted) {
          setState(() {
            _goldPrice24k = newPrice;
          });
        }
        debugPrint('💰 سعر الذهب المحدث: $_goldPrice24k ر.س/جم');
      } else {
        debugPrint('⚠️ سعر الذهب غير صالح في الاستجابة: ${priceData['price_24k']}');
      }
    } catch (e) {
      debugPrint('⚠️ فشل تحديث سعر الذهب: $e');
      // الاستمرار باستخدام السعر الحالي
    }

    // تحويل آمن للقيم
    double karat = _parseDouble(itemData['karat']);
    if (karat <= 0) karat = 21.0;

    double wage = _parseDouble(itemData['wage']);

    // تحويل آمن للوزن
    double weight = _parseDouble(itemData['weight']);
    if (weight <= 0) weight = 10.0; // افتراضي إذا لم يكن موجود

    setState(() {
      _items.add(
        InvoiceItem(
          id: itemData['id'],
          name: itemData['name'] ?? '',
          barcode: itemData['barcode'] ?? '',
          karat: karat,
          weight: weight, // استخدام الوزن الفعلي من قاعدة البيانات
          wage: wage,
          goldPrice24k: _goldPrice24k,
          mainKarat: _settingsProvider.mainKarat,
          taxRate: _settingsProvider.taxRate,
        ),
      );
      debugPrint('📋 عدد الأصناف الآن: ${_items.length}');
    });
  }

  // ==================== Item Actions ====================
  void _updateItem(int index, String field, double value) {
    setState(() {
      final item = _items[index];

      switch (field) {
        case 'karat':
          item.karat = value;
          // إذا كان هناك إجمالي محدد، أعد حساب الحقول للوصول له
          if (item._hasManualTotal && item._targetTotal != null) {
            _recalculateFieldsForTarget(item);
          }
          break;
        case 'weight':
          item.weight = value;
          // إذا كان هناك إجمالي محدد، أعد حساب الحقول للوصول له
          if (item._hasManualTotal && item._targetTotal != null) {
            _recalculateFieldsForTarget(item);
          }
          break;
        case 'wage':
          item.wage = value;
          // إذا كان هناك إجمالي محدد، أعد حساب الحقول للوصول له
          if (item._hasManualTotal && item._targetTotal != null) {
            _recalculateFieldsForTarget(item);
          }
          break;
        case 'total':
          // تحديد الإجمالي المستهدف
          item.setManualTotal(value);
          break;
      }
    });
  }

  // إعادة حساب الحقول للوصول للإجمالي المستهدف
  void _recalculateFieldsForTarget(InvoiceItem item) {
    if (!item._hasManualTotal || item._targetTotal == null) return;

    final targetTotal = item._targetTotal!;
    final targetNet =
        targetTotal / (1 + _settingsProvider.taxRate); // إزالة الضريبة

    // حساب التكلفة الحالية
    final currentCost = item.cost;

    // حساب الربح المطلوب
    final requiredProfit = targetNet - currentCost;

    // تحديث الربح
    item.profit = requiredProfit;

    debugPrint('🔄 إعادة حساب للوصول للإجمالي ${targetTotal.toStringAsFixed(2)}:');
    debugPrint('   التكلفة: ${currentCost.toStringAsFixed(2)}');
    debugPrint('   الربح: ${requiredProfit.toStringAsFixed(2)}');
    debugPrint('   الصافي: ${targetNet.toStringAsFixed(2)}');
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
    });
  }

  // ==================== Auto Distribution ====================
  Future<void> _showAutoDistributeDialog() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('توزيع تلقائي للمبلغ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'الإجمالي الحالي: ${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'المبلغ المستهدف',
                suffixText: _settingsProvider.currencySymbol,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final target = double.tryParse(controller.text);
              if (target != null && target > 0) {
                _distributeAmount(target);
                Navigator.pop(context);
              }
            },
            child: const Text('توزيع'),
          ),
        ],
      ),
    );
  }

  void _distributeAmount(double targetTotal) {
    if (_items.isEmpty) return;

    // الخطوة 1: حساب إجمالي التكاليف
    final totalCosts = _items.fold<double>(0.0, (sum, item) => sum + item.cost);

    // الخطوة 2: حساب المبلغ بدون ضريبة
    final amountWithoutTax = targetTotal / (1 + _settingsProvider.taxRate);

    // الخطوة 3: حساب الربح المتاح للتوزيع
    final profitPool = amountWithoutTax - totalCosts;

    // الخطوة 4: حساب إجمالي الأوزان
    final totalWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );

    if (totalWeight == 0) return;

    // الخطوة 5: توزيع الربح حسب نسبة الوزن
    setState(() {
      for (var item in _items) {
        // 🔥 إزالة حالة التعديل اليدوي قبل التوزيع التلقائي
        item.clearManualTotal();

        // توزيع الربح بناءً على نسبة وزن الصنف من الوزن الكلي
        item.profit = (item.weight / totalWeight) * profitPool;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ تم توزيع $targetTotal ${_settingsProvider.currencySymbol} على ${_items.length} صنف\n'
          'التكاليف: ${totalCosts.toStringAsFixed(2)} • الربح الموزع: ${profitPool.toStringAsFixed(2)}',
        ),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ==================== Submit Invoice ====================
  Future<void> _submitInvoice() async {
    if (_items.isEmpty) {
      _showError('يرجى إضافة أصناف للفاتورة');
      return;
    }

    // 🆕 التحقق من وجود دفعات
    if (_payments.isEmpty) {
      _showError('يرجى إضافة وسيلة دفع واحدة على الأقل');
      return;
    }

    // 🆕 التحقق من اكتمال الدفع مع tolerance للفروقات العشرية
    final total = _calculateGrandTotal();
    final remaining = (total - _totalPayments).abs();

    if (remaining > 0.01) {
      // tolerance = 1 قرش
      _showError(
        'المبلغ المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}\nيرجى إكمال الدفع',
      );
      return;
    }

    try {
      final apiService = ApiService();

      // إذا لم يتم اختيار عميل، استخدم عميل "نقدي" (ID = 1)
      int customerId = _selectedCustomerId ?? 1;

      // تحقق من وجود عميل "نقدي" في القائمة، إذا لم يكن موجوداً استخدم أول عميل
      final cashCustomer = widget.customers.firstWhere(
        (c) => c['name']?.toString().toLowerCase() == 'نقدي' || c['id'] == 1,
        orElse: () =>
            widget.customers.isNotEmpty ? widget.customers.first : {'id': 1},
      );

      if (_selectedCustomerId == null) {
        customerId = cashCustomer['id'] ?? 1;
        debugPrint('💵 لم يتم اختيار عميل - تقييد للعميل النقدي (ID: $customerId)');
      }

      // حساب الإجماليات
      final totalAmount = _calculateGrandTotal();
      final totalWeight = _items.fold<double>(
        0.0,
        (sum, item) => sum + item.weight,
      );
      final totalCost = _items.fold<double>(
        0.0,
        (sum, item) => sum + item.cost,
      );
      final totalTax = _items.fold<double>(0.0, (sum, item) => sum + item.tax);

      final invoiceData = {
        'customer_id': customerId,
        'transaction_type': 'sell',
        'date': DateTime.now().toIso8601String(),
        'total': totalAmount,
        'total_weight': totalWeight,
        'total_cost': totalCost,
        'total_tax': totalTax,
        'payments': _payments
            .map((p) => p.toJson())
            .toList(), // 🆕 إرسال array من الدفعات
        'amount_paid': _totalPayments, // 🆕 إجمالي المدفوع
        if (_selectedSafeBoxId != null)
          'safe_box_id': _selectedSafeBoxId, // 🆕 الخزينة
        'items': _items.map((item) => item.toJson()).toList(),
      };

      final response = await apiService.addInvoice(invoiceData);

      if (context.mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ تم حفظ الفاتورة #${response['id']}'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      _showError('فشل حفظ الفاتورة: $e');
    }
  }

  // ==================== Calculations ====================
  double _calculateGrandTotal() {
    return _items.fold<double>(0.0, (sum, item) => sum + item.totalWithTax);
  }

  // حساب إجمالي الضريبة من الأصناف
  double _calculateTotalVAT() {
    return _items.fold<double>(0.0, (sum, item) => sum + item.tax);
  }

  // ==================== Helpers ====================
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  // 🆕 Helper methods لأيقونات وألوان طرق الدفع
  IconData _getPaymentIcon(String paymentType) {
    switch (paymentType) {
      case 'cash':
        return Icons.money;
      case 'bank_transfer':
        return Icons.account_balance;
      case 'credit_card':
        return Icons.credit_card;
      case 'mada':
        return Icons.credit_card;
      case 'check':
        return Icons.receipt_long;
      case 'other':
        return Icons.more_horiz;
      default:
        return Icons.payment;
    }
  }

  Color _getPaymentColor(String paymentType) {
    switch (paymentType) {
      case 'cash':
        return AppColors.success;
      case 'bank_transfer':
        return AppColors.info;
      case 'credit_card':
        return AppColors.karat24;
      case 'mada':
        return AppColors.karat22;
      case 'check':
        return AppColors.warning;
      case 'other':
        return Colors.grey;
      default:
        return AppColors.primaryGold;
    }
  }

  // إضافة عميل جديد
  Future<void> _addNewCustomer() async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();

    await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: colorScheme.surface,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.person_add, color: AppColors.success),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'إضافة عميل جديد',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'اسم العميل *',
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'رقم الجوال',
                    prefixIcon: Icon(Icons.phone),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: addressController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'العنوان',
                    prefixIcon: Icon(Icons.location_on),
                  ),
                ),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(
                'إلغاء',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.secondary,
                ),
              ),
            ),
            FilledButton.icon(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('⚠️ يرجى إدخال اسم العميل'),
                      backgroundColor: AppColors.warning.withValues(alpha: 0.9),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                  return;
                }

                try {
                  final apiService = ApiService();
                  final customerData = {
                    'name': nameController.text.trim(),
                    'phone': phoneController.text.trim(),
                    'address_line_1': addressController.text.trim(),
                    'active': true,
                  };

                  final response = await apiService.addCustomer(customerData);

                  if (!mounted) return;

                  setState(() {
                    widget.customers.add(response);
                    _selectedCustomerId = response['id'];
                  });

                  Navigator.pop(dialogContext, true);

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ تم إضافة العميل: ${response['name']}'),
                      backgroundColor: AppColors.success,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('❌ فشل إضافة العميل: $e'),
                      backgroundColor: AppColors.error,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              icon: const Icon(Icons.save),
              label: const Text('حفظ'),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openCameraScanner() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => _BarcodeScannerPlaceholder()),
    );

    if (barcode != null && barcode.isNotEmpty && mounted) {
      debugPrint('📷 تم مسح الباركود: $barcode'); // للتتبع
      _smartInputController.text = barcode;
      await _processSmartInput(barcode);
      _smartInputFocus.requestFocus(); // إعادة التركيز للإدخال
    }
  }

  Future<void> _showItemSelectionDialog() async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'اختر صنف',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: ListView.builder(
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
              final item = widget.items[index];
              return ListTile(
                leading: Icon(Icons.inventory_2, color: colorScheme.primary),
                title: Text(item['name'] ?? ''),
                subtitle: Text(
                  'عيار: ${item['karat']} • ${item['barcode'] ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _addItemFromData(item);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }

  // ==================== UI Build ====================
  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final size = MediaQuery.of(context).size;
        final isWideLayout = size.width >= 1100;

        final bodyContent = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCustomerSection(theme),
            const SizedBox(height: 24),
            if (isWideLayout)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 7,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSmartInputSection(),
                        const SizedBox(height: 24),
                        _buildDataTable(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildActionButtons(),
                        const SizedBox(height: 24),
                        _buildPaymentSection(),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              _buildSmartInputSection(),
              const SizedBox(height: 24),
              _buildDataTable(),
              const SizedBox(height: 24),
              _buildActionButtons(),
              const SizedBox(height: 24),
              _buildPaymentSection(),
            ],
            const SizedBox(height: 32),
            Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: FilledButton.icon(
                  onPressed:
                      _items.isEmpty ||
                          _payments.isEmpty ||
                          _remainingAmount > 0.01
                      ? null
                      : _submitInvoice,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(
                    _remainingAmount > 0.01
                        ? 'أكمل الدفع (${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol} متبقية)'
                        : 'حفظ الفاتورة',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 24,
                    ),
                    textStyle: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        );

        return Scaffold(
          appBar: AppBar(
            title: const Text('فاتورة بيع الكسر'),
            actions: [
              IconButton(
                tooltip: 'تحديث سعر الذهب',
                onPressed: _loadSettings,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: bodyContent,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCustomerSection(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Map<String, dynamic>? selectedCustomer;
    if (_selectedCustomerId != null) {
      selectedCustomer = widget.customers.firstWhere((customer) {
        final rawId = customer['id'];
        if (rawId == null) return false;
        final parsed = rawId is int ? rawId : int.tryParse(rawId.toString());
        return parsed == _selectedCustomerId;
      }, orElse: () => {});
      if (selectedCustomer.isEmpty) {
        selectedCustomer = null;
      }
    }

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
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 
                      isDark ? 0.18 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.person_outline, color: colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'بيانات العميل',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'اختر العميل أو أضف عميلًا جديدًا لإتمام الفاتورة.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _addNewCustomer,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('عميل جديد'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
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
            ),
            const SizedBox(height: 20),
            if (widget.customers.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceVariant.withValues(alpha: 
                    isDark ? 0.25 : 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'لا يوجد عملاء مسجلون بعد، أضف عميلًا للمتابعة.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              DropdownButtonFormField<int>(
                value: _selectedCustomerId,
                items: widget.customers
                    .map((customer) {
                      final rawId = customer['id'];
                      if (rawId == null) return null;
                      final id = rawId is int
                          ? rawId
                          : int.tryParse(rawId.toString());
                      if (id == null) return null;
                      final name = (customer['name'] ?? 'عميل').toString();
                      final phone =
                          (customer['phone'] ?? customer['phone_number'] ?? '')
                              .toString();
                      final isCashCustomer = name.trim() == 'نقدي';
                      final accentColor = isCashCustomer
                          ? AppColors.success
                          : colorScheme.primary;

                      return DropdownMenuItem<int>(
                        value: id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.badge, color: accentColor, size: 20),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                name,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (phone.isNotEmpty)
                              Flexible(
                                child: Text(
                                  phone,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      );
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedCustomerId = value;
                  });
                },
                decoration: InputDecoration(
                  labelText: 'اختر العميل',
                  prefixIcon: Icon(Icons.people, color: colorScheme.primary),
                ),
                dropdownColor: theme.cardColor,
                icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
              ),
            if (selectedCustomer != null) ...[
              const SizedBox(height: 16),
              _buildSelectedCustomerDetails(theme, selectedCustomer),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerInfoChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedCustomerDetails(
    ThemeData theme,
    Map<String, dynamic> customer,
  ) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final name = (customer['name'] ?? '').toString();
    final phone = (customer['phone'] ?? customer['phone_number'] ?? '')
        .toString();
    final address = (customer['address'] ?? customer['address_line_1'] ?? '')
        .toString();
    final code = customer['customer_code']?.toString();

    final infoChips = <Widget>[];
    if (phone.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(theme, icon: Icons.phone_iphone, label: phone),
      );
    }
    if (address.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(
          theme,
          icon: Icons.location_on_outlined,
          label: address,
        ),
      );
    }
    if (code != null && code.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(
          theme,
          icon: Icons.qr_code_2,
          label: 'رمز: $code',
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user, color: colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (infoChips.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, children: infoChips),
          ],
        ],
      ),
    );
  }

  // ==================== Smart Input Section ====================
  Widget _buildSmartInputSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary.withValues(alpha: 0.15),
            theme.colorScheme.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.qr_code_scanner,
                  color: colorScheme.onSurface,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'إدخال سريع',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'باركود • اسم • رقم صنف',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              _buildQuickButton(
                Icons.camera_alt,
                AppColors.info,
                'كاميرا',
                _openCameraScanner,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.list_alt,
                AppColors.success,
                'قائمة',
                _showItemSelectionDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Smart Input Field
          TextField(
            controller: _smartInputController,
            focusNode: _smartInputFocus,
            autofocus: true,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              labelText: 'امسح الباركود أو ابحث...',
              labelStyle: theme.textTheme.bodyMedium,
              hintText: 'YAS000001 • اسم الصنف • I-000001',
              hintStyle: theme.textTheme.bodySmall,
              prefixIcon: Icon(Icons.search, color: colorScheme.primary),
              suffixIcon: _smartInputController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, color: theme.iconTheme.color),
                      onPressed: () {
                        _smartInputController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.primary, width: 2),
              ),
            ),
            onChanged: (value) => setState(() {}),
            onSubmitted: _processSmartInput,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickButton(
    IconData icon,
    Color color,
    String tooltip,
    VoidCallback onPressed,
  ) {
    final theme = Theme.of(context);
    final backgroundOpacity = theme.brightness == Brightness.dark ? 0.2 : 0.1;
    final borderOpacity = theme.brightness == Brightness.dark ? 0.5 : 0.3;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: backgroundOpacity),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: borderOpacity)),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }

  // ==================== Data Table ====================
  Widget _buildDataTable() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final dividerColor = theme.dividerColor;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dividerColor.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 
              theme.brightness == Brightness.dark ? 0.3 : 0.06,
            ),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.table_chart,
                  color: colorScheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الأصناف المضافة',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_items.isNotEmpty)
                      Text(
                        '${_items.length} صنف',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Table or Empty State
          if (_items.isEmpty) _buildEmptyState() else _buildTable(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: theme.brightness == Brightness.dark
              ? [colorScheme.surfaceVariant, theme.scaffoldBackgroundColor]
              : [colorScheme.surface, theme.scaffoldBackgroundColor],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.6),
          width: 2,
        ),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.shopping_cart_outlined,
              size: 64,
              color: colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'لم تتم إضافة أصناف بعد',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color:
                    theme.textTheme.titleLarge?.color ?? colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'ابدأ بمسح الباركود أو البحث عن الأصناف',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final headerStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    final cellStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(
          colorScheme.primary.withValues(alpha: 0.15),
        ),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.1);
          }
          return theme.cardColor;
        }),
        columns: [
          DataColumn(label: Text('#', style: headerStyle)),
          DataColumn(label: Text('الاسم', style: headerStyle)),
          DataColumn(label: Text('العيار', style: headerStyle)),
          DataColumn(label: Text('الوزن (جم)', style: headerStyle)),
          DataColumn(label: Text('المصنعية', style: headerStyle)),
          DataColumn(label: Text('السعر/جم', style: headerStyle)),
          DataColumn(label: Text('التكلفة', style: headerStyle)),
          DataColumn(label: Text('الصافي', style: headerStyle)),
          DataColumn(label: Text('الضريبة', style: headerStyle)),
          DataColumn(label: Text('الإجمالي', style: headerStyle)),
          DataColumn(label: Text('إجراءات', style: headerStyle)),
        ],
        rows: _items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;

          return DataRow(
            cells: [
              DataCell(Text('${index + 1}', style: cellStyle)),
              DataCell(Text(item.name, style: cellStyle)),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'karat', item.karat),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.info.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${item.karat.toStringAsFixed(0)}',
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'weight', item.weight),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${item.weight.toStringAsFixed(2)}',
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'wage', item.wage),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${item.wage.toStringAsFixed(2)}',
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                Text(
                  '${item.calculateSellingPricePerGram().toStringAsFixed(2)}',
                  style: cellStyle,
                ),
              ),
              DataCell(
                Text('${item.cost.toStringAsFixed(2)}', style: cellStyle),
              ),
              DataCell(
                Text('${item.net.toStringAsFixed(2)}', style: cellStyle),
              ),
              DataCell(
                Text('${item.tax.toStringAsFixed(2)}', style: cellStyle),
              ),
              DataCell(
                InkWell(
                  onTap: () =>
                      _showEditDialog(index, 'total', item.totalWithTax),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.karat24.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.karat24.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${item.totalWithTax.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                IconButton(
                  icon: const Icon(
                    Icons.delete,
                    size: 22,
                    color: AppColors.error,
                  ),
                  onPressed: () => _removeItem(index),
                  tooltip: 'حذف',
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Future<void> _showEditDialog(
    int index,
    String field,
    double currentValue,
  ) async {
    final controller = TextEditingController(text: currentValue.toString());
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String title = '';
    String label = '';

    switch (field) {
      case 'karat':
        title = 'تعديل العيار';
        label = 'العيار';
        break;
      case 'weight':
        title = 'تعديل الوزن';
        label = 'الوزن (جم)';
        break;
      case 'wage':
        title = 'تعديل المصنعية';
        label = 'المصنعية (للجرام)';
        break;
      case 'total':
        title = 'تعديل الإجمالي';
        label = 'الإجمالي';
        break;
    }

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                _updateItem(index, field, value);
                Navigator.pop(context);
              }
            },
            child: const Text('حفظ'),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Action Buttons ====================
  Widget _buildActionButtons() {
    final grandTotal = _calculateGrandTotal();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [colorScheme.surfaceVariant, theme.scaffoldBackgroundColor]
              : [colorScheme.surface, theme.scaffoldBackgroundColor],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Auto Distribute Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _items.isEmpty ? null : _showAutoDistributeDialog,
              icon: const Icon(Icons.auto_awesome, size: 22),
              label: Text(
                'توزيع تلقائي للمبلغ',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 56),
                backgroundColor: AppColors.karat24,
                foregroundColor: Colors.white,
                disabledBackgroundColor: theme.disabledColor.withValues(alpha: 0.2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Grand Total
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colorScheme.primary, AppColors.lightGold],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: isDark ? 0.35 : 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الإجمالي الكلي',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                        shadows: !isDark ? [
                          Shadow(
                            color: Colors.white.withValues(alpha: 0.8),
                            blurRadius: 2,
                          ),
                        ] : null,
                      ),
                    ),
                    Text(
                      '${_items.length} صنف',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black87,
                        fontWeight: FontWeight.w500,
                        shadows: !isDark ? [
                          Shadow(
                            color: Colors.white.withValues(alpha: 0.8),
                            blurRadius: 2,
                          ),
                        ] : null,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${grandTotal.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                    shadows: !isDark ? [
                      Shadow(
                        color: Colors.white.withValues(alpha: 0.9),
                        blurRadius: 3,
                      ),
                    ] : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Payment Section ====================
  Widget _buildPaymentSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final totalAmount = _calculateGrandTotal();
    final dividerColor = theme.dividerColor.withValues(alpha: 0.6);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 2,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.payment, color: colorScheme.primary, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      'وسائل الدفع',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: isDark ? 0.2 : 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    'الإجمالي: ${totalAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 🆕 جدول الدفعات المضافة
            if (_payments.isNotEmpty) ...[
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.4),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            colorScheme.primary.withValues(alpha: 
                              isDark ? 0.25 : 0.3,
                            ),
                            AppColors.lightGold.withValues(alpha: 
                              isDark ? 0.2 : 0.35,
                            ),
                          ],
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(6),
                          topRight: Radius.circular(6),
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
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 2,
                                  ),
                                ] : null,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'المبلغ',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 2,
                                  ),
                                ] : null,
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
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 2,
                                  ),
                                ] : null,
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
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 2,
                                  ),
                                ] : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              'حذف',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark ? [
                                  Shadow(
                                    color: Colors.white.withValues(alpha: 0.8),
                                    blurRadius: 2,
                                  ),
                                ] : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Rows
                    ...List.generate(_payments.length, (index) {
                      final payment = _payments[index];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: index % 2 == 0
                              ? theme.colorScheme.surface
                              : theme.colorScheme.surfaceVariant.withValues(alpha: 
                                  isDark ? 0.3 : 0.5,
                                ),
                          border: Border(
                            bottom: BorderSide(color: dividerColor, width: 1),
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
                                    payment.paymentMethodName,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (payment.commissionRate > 0)
                                    Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.warning.withValues(alpha: 
                                          isDark ? 0.2 : 0.25,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'عمولة ${payment.commissionRate}%',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 11,
                                              color: AppColors.warning,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '${payment.amount.toStringAsFixed(2)} ر.س',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                payment.commissionAmount > 0
                                    ? '${payment.commissionAmount.toStringAsFixed(2)} ر.س'
                                    : '-',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: payment.commissionAmount > 0
                                      ? AppColors.error
                                      : theme.disabledColor,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '${payment.netAmount.toStringAsFixed(2)} ر.س',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.info,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            SizedBox(
                              width: 45,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.delete_forever,
                                  size: 22,
                                ),
                                color: AppColors.error,
                                tooltip: 'حذف',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _removePayment(index),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 🆕 إضافة وسيلة دفع جديدة
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: isDark ? 0.15 : 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'إضافة وسيلة دفع',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      // Dropdown وسيلة الدفع - محسّن 🆕
                      Expanded(
                        flex: 3,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.primary.withValues(alpha: 0.5),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.primary.withValues(alpha: 0.16),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: _selectedPaymentMethodId,
                              hint: Row(
                                children: [
                                  Icon(
                                    Icons.payment,
                                    color: theme.iconTheme.color,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'اختر وسيلة الدفع',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              isExpanded: true,
                              dropdownColor: theme.colorScheme.surface,
                              icon: Icon(
                                Icons.arrow_drop_down,
                                color: colorScheme.primary,
                                size: 28,
                              ),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              selectedItemBuilder: (BuildContext context) {
                                return _paymentMethods.map<Widget>((method) {
                                  return Row(
                                    children: [
                                      Icon(
                                        _getPaymentIcon(
                                          method['payment_type'] ?? '',
                                        ),
                                        color: _getPaymentColor(
                                          method['payment_type'] ?? '',
                                        ),
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          method['name'] ?? '',
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList();
                              },
                              items: _paymentMethods.map((method) {
                                final commission =
                                    method['commission_rate'] ?? 0.0;

                                return DropdownMenuItem<int>(
                                  value: method['id'],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                      horizontal: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _getPaymentIcon(
                                            method['payment_type'] ?? '',
                                          ),
                                          color: _getPaymentColor(
                                            method['payment_type'] ?? '',
                                          ),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            method['name'] ?? '',
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                        if (commission > 0)
                                          Flexible(
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                              ),
                                              child: Text(
                                                '($commission%)',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: AppColors.warning,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _selectedPaymentMethodId = value;
                                });
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // حقل المبلغ مع أيقونة ملء باقي المبلغ
                      Expanded(
                        flex: 2,
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _remainingAmount > 0
                                  ? colorScheme.primary
                                  : dividerColor,
                              width: _remainingAmount > 0 ? 2 : 1,
                            ),
                            boxShadow: _remainingAmount > 0
                                ? [
                                    BoxShadow(
                                      color: colorScheme.primary.withValues(alpha: 
                                        0.25,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _customAmountController,
                                  decoration: InputDecoration(
                                    labelText: 'المبلغ',
                                    labelStyle: theme.textTheme.bodyMedium
                                        ?.copyWith(
                                          color: colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                    hintText: _remainingAmount.toStringAsFixed(
                                      0,
                                    ),
                                    hintStyle: theme.textTheme.bodySmall,
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    suffixText: 'ر.س',
                                    suffixStyle: theme.textTheme.bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w500),
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              if (_remainingAmount > 0)
                                Container(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      right: BorderSide(
                                        color: colorScheme.primary.withValues(alpha: 
                                          0.4,
                                        ),
                                      ),
                                    ),
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.playlist_add_check,
                                      color: colorScheme.primary,
                                      size: 24,
                                    ),
                                    tooltip:
                                        'ملء باقي المبلغ (${_remainingAmount.toStringAsFixed(2)})',
                                    onPressed: () {
                                      setState(() {
                                        _customAmountController.text =
                                            _remainingAmount.toStringAsFixed(2);
                                      });
                                    },
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // زر الإضافة
                      ElevatedButton.icon(
                        onPressed: () {
                          final customAmount = double.tryParse(
                            _customAmountController.text,
                          );
                          _addPayment(customAmount: customAmount);
                        },
                        icon: const Icon(Icons.add_circle, size: 20),
                        label: Text(
                          'إضافة',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                          elevation: 3,
                          shadowColor: colorScheme.primary.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 
                        isDark ? 0.18 : 0.12,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: AppColors.warning,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'المتبقي: ${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            color: AppColors.warning,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 🆕 ملخص النهائي
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _remainingAmount > 0
                      ? [
                          colorScheme.error.withValues(alpha: isDark ? 0.16 : 0.12),
                          colorScheme.error.withValues(alpha: isDark ? 0.28 : 0.2),
                        ]
                      : [
                          AppColors.success.withValues(alpha: isDark ? 0.16 : 0.12),
                          AppColors.success.withValues(alpha: isDark ? 0.28 : 0.2),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _remainingAmount > 0
                      ? colorScheme.error.withValues(alpha: 0.5)
                      : AppColors.success.withValues(alpha: 0.5),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (_remainingAmount > 0
                                ? colorScheme.error
                                : AppColors.success)
                            .withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // إجمالي الفاتورة مع ضريبة القيمة المضافة
                  if (_items.isNotEmpty) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.receipt,
                              size: 18,
                              color: theme.iconTheme.color,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'إجمالي الفاتورة:',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                        Text(
                          '${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.description,
                              size: 16,
                              color: AppColors.info,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ضريبة القيمة المضافة:',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        Text(
                          '${_calculateTotalVAT().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.info,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 16, thickness: 1),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.account_balance_wallet,
                            size: 20,
                            color: theme.iconTheme.color,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'المدفوع:',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${_totalPayments.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (_totalCommission > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.percent,
                              size: 18,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'إجمالي العمولات:',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                        Text(
                          '${_totalCommission.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.warning,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.receipt_long,
                              size: 16,
                              color: AppColors.info,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ضريبة العمولات (15%):',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        Text(
                          '${_totalCommissionVAT.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.info,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              size: 18,
                              color: AppColors.success,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'صافي المستلم:',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${_totalNet.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.success,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 20, thickness: 1.5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _remainingAmount > 0
                                ? Icons.warning_amber_rounded
                                : Icons.check_circle_outline,
                            size: 22,
                            color: _remainingAmount > 0
                                ? colorScheme.error
                                : AppColors.success,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _remainingAmount > 0
                                ? 'المتبقي:'
                                : '✓ تم الدفع بالكامل',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: _remainingAmount > 0
                                  ? colorScheme.error
                                  : AppColors.success,
                            ),
                          ),
                        ],
                      ),
                      if (_remainingAmount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onError,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== Invoice Item Model ====================
class InvoiceItem {
  final int id;
  final String name;
  final String barcode;
  double karat;
  double weight;
  double wage; // أجور المصنعية للجرام الواحد
  final double goldPrice24k;
  final int mainKarat;
  final double taxRate;

  // الربح الموزع (يتم حسابه في _distributeAmount)
  double profit = 0.0;

  // علامة لتتبع إذا تم تحديد الإجمالي يدوياً
  bool _hasManualTotal = false;
  double? _targetTotal;

  InvoiceItem({
    required this.id,
    required this.name,
    required this.barcode,
    required this.karat,
    required this.weight,
    required this.wage,
    required this.goldPrice24k,
    required this.mainKarat,
    required this.taxRate,
  });

  // حساب سعر الجرام الخام (سعر الذهب فقط حسب العيار)
  double calculatePricePerGram() {
    return goldPrice24k * (karat / 24.0);
  }

  // التكلفة = الوزن × (سعر الذهب للجرام + المصنعية للجرام)
  double get cost {
    return weight * (calculatePricePerGram() + wage);
  }

  // الصافي = التكلفة + الربح الموزع
  double get net {
    if (_hasManualTotal && _targetTotal != null) {
      // إذا تم تحديد إجمالي يدوي، احسب الصافي من الإجمالي
      return _targetTotal! / (1 + taxRate);
    }
    return cost + profit;
  }

  // الضريبة 15% على الصافي
  double get tax {
    return net * taxRate;
  }

  // الإجمالي مع الضريبة
  double get totalWithTax {
    if (_hasManualTotal && _targetTotal != null) {
      return _targetTotal!;
    }
    return net + tax;
  }

  // حساب سعر البيع للجرام (للعرض فقط)
  double calculateSellingPricePerGram() {
    if (weight == 0) return 0;
    return net / weight;
  }

  // تحديد إجمالي يدوي
  void setManualTotal(double total) {
    _hasManualTotal = true;
    _targetTotal = total;
    // إعادة حساب الربح بناءً على الإجمالي الجديد
    final targetNet = total / (1 + taxRate);
    profit = targetNet - cost;
  }

  // مسح الإجمالي اليدوي عند تعديل الحقول
  void clearManualTotal() {
    _hasManualTotal = false;
    _targetTotal = null;
  }

  Map<String, dynamic> toJson() {
    return {
      'item_id': id,
      'name': name,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'cost': cost,
      'profit': profit,
      'net': net,
      'tax': tax,
      'price': totalWithTax, // الـ backend يتوقع 'price' بدلاً من 'total'
      'quantity': 1,
      'calculated_selling_price_per_gram': calculateSellingPricePerGram(),
    };
  }
}

// ==================== Barcode Scanner Widget ====================
class _BarcodeScannerPlaceholder extends StatefulWidget {
  @override
  State<_BarcodeScannerPlaceholder> createState() =>
      _BarcodeScannerPlaceholderState();
}

class _BarcodeScannerPlaceholderState
    extends State<_BarcodeScannerPlaceholder> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _isProcessing = false; // منع تكرار المسح

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'مسح الباركود 📷',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, child) {
                final torchState = value.torchState;
                switch (torchState) {
                  case TorchState.auto:
                  case TorchState.off:
                    return const Icon(Icons.flash_off, color: Colors.white);
                  case TorchState.on:
                    return const Icon(Icons.flash_on, color: Colors.yellow);
                  case TorchState.unavailable:
                    return const Icon(Icons.flash_off, color: Colors.grey);
                }
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_isProcessing) return; // منع التكرار

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final code = barcodes.first.rawValue;
                debugPrint('📸 تم قراءة الباركود: $code');
                if (code != null && code.isNotEmpty) {
                  _isProcessing = true; // تعليم كـ "قيد المعالجة"
                  debugPrint('✅ إغلاق الكاميرا وإرجاع: $code');
                  Navigator.pop(context, code);
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.symmetric(horizontal: 32),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '🎯 وجّه الكاميرا نحو الباركود',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 🆕 Class لتخزين معلومات الدفعة
class PaymentEntry {
  int paymentMethodId;
  String paymentMethodName;
  double amount;
  double commissionRate;
  double commissionAmount;
  double commissionVat; // ضريبة القيمة المضافة على العمولة
  double netAmount;
  int settlementDays;
  String? notes;

  PaymentEntry({
    required this.paymentMethodId,
    required this.paymentMethodName,
    required this.amount,
    required this.commissionRate,
    required this.commissionAmount,
    required this.commissionVat,
    required this.netAmount,
    required this.settlementDays,
    this.notes,
  });

  Map<String, dynamic> toJson() {
    return {
      'payment_method_id': paymentMethodId,
      'amount': amount,
      'commission_rate': commissionRate,
      'commission_amount': commissionAmount,
      'commission_vat': commissionVat,
      'net_amount': netAmount,
      'notes': notes,
    };
  }
}
