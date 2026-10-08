import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../models/safe_box_model.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import 'add_customer_screen.dart';
import '../widgets/invoice_settings_sheet.dart';
import '../widgets/pay_box.dart';
import '../widgets/scrap_purchase_entry_row.dart';
import '../utils/scrap_purchase_readiness.dart';
import '../widgets/adaptive_invoice_summary_dialog.dart';
import '../utils/invoice_direct_print.dart';
import '../utils.dart';

// نسبة افتراضية لخفض سعر السوق للحصول على سعر شراء آمن عند عدم توفر بيانات مخاطبة من المتوسط
const double kScrapPurchasePriceDiscount = 0.98;

/// شاشة فاتورة شراء الكسر - نسخة مبسطة
/// ميزات: تصوير الذهب + ملاحظات + دفع نقدي/تحويل فقط + بدون ضريبة
/// Whether to warn that the purchased gold will go to the main scrap safe:
/// only when the signed-in account is not linked to an employee -- and, on an
/// edit, only when the invoice's holder has no custody safe. The edit keeps the
/// holder and the safe box the gold went to (EDIT-001), so the signed-in
/// account does not decide where the gold goes.
bool warnsGoldGoesToMainScrapSafe({
  required int? signedInEmployeeId,
  Map<String, dynamic>? editInvoiceData,
}) {
  if (signedInEmployeeId != null) return false;
  if (editInvoiceData != null && editInvoiceData['scrap_holder_gold_safe_box_id'] != null) {
    return false;
  }
  return true;
}

/// The walk-in customer, by the names the server knows it by
/// (models.CASH_CUSTOMER_NAMES) -- a name that merely holds «نقد» is a
/// customer, and needs their identity on file.
const _cashCustomerNames = {'عميل نقدي', 'نقدي', 'عميل كاش'};

String _foldSpaces(Object? value) =>
    (value ?? '').toString().trim().split(RegExp(r'\s+')).join(' ');

class ScrapPurchaseInvoiceScreen extends StatefulWidget {
  final List<Map<String, dynamic>> customers;

  /// Edit mode: an unposted purchase from a customer (EDIT-001). The server
  /// keeps its number, its date and who holds the gold; this screen only
  /// corrects the lines and the payments.
  final int? editInvoiceId;
  final Map<String, dynamic>? editInvoiceData;

  /// The server; a test hands its own.
  final ApiService? apiService;

  const ScrapPurchaseInvoiceScreen({
    super.key,
    required this.customers,
    this.editInvoiceId,
    this.editInvoiceData,
    this.apiService,
  });

  @override
  State<ScrapPurchaseInvoiceScreen> createState() =>
      _ScrapPurchaseInvoiceScreenState();
}

class _ScrapPurchaseInvoiceScreenState
    extends State<ScrapPurchaseInvoiceScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  // ==================== State Variables ====================
  final _smartInputController = TextEditingController();
  final _smartInputFocus = FocusNode();
  final _customAmountController = TextEditingController(); // 🆕 للمبلغ المخصص

  // Branches (فروع المعرض/المحل)
  List<Map<String, dynamic>> _branches = [];
  bool _isLoadingBranches = false;
  String? _branchesLoadingError;
  int? _selectedBranchId;

  // Customer
  int? _selectedCustomerId;

  // Items List
  final List<InvoiceItem> _items = [];

  // 🆕 تصنيفات (للتسمية فقط في سطور شراء من عميل)
  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingCategories = false;
  String? _categoriesError;

  // 🆕 قائمة أصناف شراء بسيطة (اسم + عيار)
  List<Map<String, dynamic>> _purchaseItems = [];

  // Gold Price & Settings
  double _goldPrice24k = 0.0;
  double _purchasePrice24k = 0.0;
  late SettingsProvider _settingsProvider;

  bool _uiLockPriceEdits = false;
  bool _uiAutoOpenPrintAfterSave = false;
  String _uiPaperSize = 'A4';

  // Payment - 🆕 وسائل دفع متعددة
  List<Map<String, dynamic>> _paymentMethods = [];
  final List<PaymentEntry> _payments = []; // 🆕 قائمة الدفعات المضافة
  int? _selectedPaymentMethodId; // للـ Dropdown

  // 🆕 الخزائن
  // ignore: unused_field
  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId;
  // ignore: unused_field
  final bool _showAdvancedPaymentOptions = false; // 🎯 للتحكم في إظهار الخزائن

  // 🆕 صور الذهب المشترى
  final List<File> _goldImages = [];
  final ImagePicker _imagePicker = ImagePicker();

  // 🆕 الملاحظات وحالة الذهب
  final TextEditingController _purchaseNotesController =
      TextEditingController();
  static const List<String> _goldConditionOptions = [
    'ممتاز',
    'جيد',
    'متوسط',
    'تالف',
  ];
  String _goldCondition = _goldConditionOptions[1];

  void _resetAfterSave() {
    setState(() {
      _selectedCustomerId = null;
      _items.clear();
      _payments.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _smartInputController.clear();
      _customAmountController.clear();
      _goldImages.clear();
      _purchaseNotesController.clear();
      _goldCondition = _goldConditionOptions[1];
    });
    _smartInputFocus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _loadInvoiceUiSettingsFromPrefs();
    _loadSettings();
    _loadBranches();
    _loadPaymentMethods(); // 🆕 جلب وسائل الدفع
    _loadDefaultSafeBox(); // 🆕 تحميل الخزينة النقدية
    _loadPurchaseBaseline();
    _loadPurchaseItems();
    _ensureCategoriesLoaded();
    _smartInputFocus.requestFocus();
    if (_isEditMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prefillFromExistingInvoice());
    }
  }

  bool get _isEditMode => widget.editInvoiceId != null;

  // ==================== Edit Mode Prefill ====================
  void _prefillFromExistingInvoice() {
    final data = widget.editInvoiceData;
    if (data == null || !mounted) return;
    double num0(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;
    int? int0(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');
    setState(() {
      _selectedCustomerId = int0(data['customer_id']);
      _selectedBranchId = int0(data['branch_id']) ?? _selectedBranchId;
      _selectedSafeBoxId = int0(data['safe_box_id']) ?? _selectedSafeBoxId;
      _items.clear();
      for (final raw in (data['items'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final standing = num0(m['standing_weight']) > 0 ? num0(m['standing_weight']) : num0(m['weight']);
        final item = InvoiceItem(
          itemId: int0(m['item_id']),
          name: (m['name'] ?? '').toString(),
          barcode: '',
          karat: num0(m['karat']),
          standingWeight: standing,
          stonesWeight: num0(m['stones_weight']),
          quantity: int0(m['quantity']) ?? 1,
          weight: num0(m['weight']),
          wage: num0(m['wage']),
          goldPrice24k: _effectivePurchasePrice24k,
          mainKarat: _settingsProvider.mainKarat,
          isCategoryLine: m['item_id'] == null,
        );
        item.updateWeightFromStandingAndStones();
        if (num0(m['price']) > 0) item.setManualTotal(num0(m['price']));
        _items.add(item);
      }
      _payments.clear();
      for (final raw in (data['payments'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        _payments.add(PaymentEntry(
          paymentMethodId: int0(m['payment_method_id']) ?? 0,
          paymentMethodName: (m['payment_method_name'] ?? '').toString(),
          amount: num0(m['amount']),
          commissionRate: num0(m['commission_rate']),
          commissionAmount: num0(m['commission_amount']),
          commissionVat: num0(m['commission_vat']),
          netAmount: num0(m['net_amount']),
          settlementDays: int0(m['settlement_days']) ?? 0,
        ));
      }
    });
  }

  Future<void> _ensureCategoriesLoaded() async {
    if (_isLoadingCategories) return;
    if (_categories.isNotEmpty) return;

    setState(() {
      _isLoadingCategories = true;
      _categoriesError = null;
    });

    try {
      final api = _api;
      final response = await api.getCategories();
      final parsed = response
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      parsed.sort((a, b) {
        final an = (a['name'] ?? '').toString();
        final bn = (b['name'] ?? '').toString();
        return an.compareTo(bn);
      });

      if (!mounted) return;
      setState(() {
        _categories = parsed;
        _isLoadingCategories = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _categories = [];
        _isLoadingCategories = false;
        _categoriesError = 'فشل تحميل التصنيفات: $e';
      });
    }
  }

  Future<void> _addCategoryLine() async {
    await _ensureCategoriesLoaded();
    if (!mounted) return;

    if (_categories.isEmpty) {
      _showError(
        _categoriesError ??
            'لا توجد تصنيفات. أنشئ تصنيفاً أولاً من شاشة الأصناف.',
      );
      return;
    }

    final result = await showDialog<_ScrapCategoryLineResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ScrapCategoryLineDialog(
        categories: _categories,
        currencySymbol: _settingsProvider.currencySymbolText,
        mainKarat: _settingsProvider.mainKarat,
      ),
    );

    if (result == null || !mounted) return;

    _addScrapLine(
      name: result.categoryName,
      karat: result.karat,
      standing: result.weight,
      stones: result.stonesWeight,
      count: result.count,
      wage: result.wage,
      amount: result.amountCash,
    );
  }

  /// A line typed in the entry row: one piece, no wage — those are the
  /// dialog's.
  void _addEnteredScrap(ScrapPurchaseEntry e) => _addScrapLine(
    name: '${e.category['name'] ?? ''}',
    karat: e.karat.toDouble(),
    standing: e.standing,
    stones: e.stones,
    count: 1,
    wage: 0,
    amount: e.amount,
  );

  void _addScrapLine({
    required String name,
    required double karat,
    required double standing,
    required double stones,
    required int count,
    required double wage,
    required double amount,
  }) {
    setState(() {
      final item = InvoiceItem(
        itemId: null,
        name: name,
        barcode: '',
        karat: karat,
        standingWeight: standing,
        stonesWeight: stones,
        quantity: count,
        weight: standing,
        wage: wage,
        goldPrice24k: _effectivePurchasePrice24k,
        mainKarat: _settingsProvider.mainKarat,
        isCategoryLine: true,
      );
      item.updateWeightFromStandingAndStones();
      if (amount > 0) {
        item.setManualTotal(amount);
      }
      _items.add(item);
    });
  }

  Future<void> _loadInvoiceUiSettingsFromPrefs() async {
    try {
      final loaded = await InvoiceUiSettings.load(
        InvoiceUiContext.scrapPurchase,
      );
      if (!mounted) return;
      setState(() {
        _uiLockPriceEdits = loaded.lockPriceEdits;
        _uiAutoOpenPrintAfterSave = loaded.autoOpenPrintAfterSave;
        _uiPaperSize = loaded.paperSize;
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loadDefaultSafeBox() async {
    // For scrap gold purchases the invoice-level safe_box_id tracks which gold safe
    // receives the scrap. Prefer the employee's gold safe (set at submission time), then
    // the system default gold safe. Cash movement is handled via the payment method's
    // configured safe box — not this field.
    try {
      final api = _api;
      final goldSafe = await api.getDefaultSafeBox('gold');
      if (!mounted) return;
      setState(() {
        _selectedSafeBoxId = goldSafe.id;
        if (goldSafe.id != null) {
          final exists = _safeBoxes.any((sb) => sb.id == goldSafe.id);
          if (!exists) {
            _safeBoxes = [goldSafe, ..._safeBoxes];
          }
        }
      });
    } catch (_) {
      // Ignore if no default gold safe box exists; backend resolves it via fallbacks.
    }
  }

  Future<void> _loadBranches() async {
    if (_isLoadingBranches) return;
    setState(() {
      _isLoadingBranches = true;
      _branchesLoadingError = null;
    });

    try {
      final apiService = _api;
      final raw = await apiService.getBranches(activeOnly: true);
      if (!mounted) return;

      final branches = raw
          .whereType<Map>()
          .map((b) => Map<String, dynamic>.from(b))
          .toList();

      setState(() {
        _branches = branches;
        if (_selectedBranchId == null && _branches.length == 1) {
          _selectedBranchId = _parseInt(_branches.first['id']);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _branchesLoadingError = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoadingBranches = false;
      });
    }
  }

  Future<void> _loadPurchaseItems() async {
    try {
      final apiService = _api;
      final response = await apiService.getPurchaseItems();
      if (!mounted) return;
      final normalized = response
          .whereType<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _purchaseItems = normalized;
      });
    } catch (e) {
      debugPrint('⚠️ فشل تحميل قائمة أصناف الشراء: $e');
      if (mounted) {
        setState(() {
          _purchaseItems = [];
        });
      }
      _showError('فشل تحميل أصناف الشراء: $e');
    }
  }

  List<Map<String, dynamic>> get _availableItemsForPurchase {
    return _purchaseItems;
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
    _purchaseNotesController.dispose(); // 🆕
    super.dispose();
  }

  // ==================== Data Loading ====================
  Future<void> _loadSettings() async {
    try {
      final apiService = _api;
      final priceData = await apiService.getGoldPrice();
      if (!mounted) return;
      setState(() {
        final fetched = _parseDouble(priceData['price_24k']);
        _goldPrice24k = fetched;
        if (_purchasePrice24k <= 0) {
          _purchasePrice24k = _fallbackPurchasePriceFromMarket(fetched);
        }
      });
    } catch (e) {
      _showError('فشل تحميل سعر الذهب: $e');
    }
  }

  Future<void> _loadPurchaseBaseline() async {
    try {
      final apiService = _api;
      // The server's suggestion (the last purchase price, else the average) --
      // the seller is not sent the cost snapshot (ADR-036, the owner 2 Oct 2026).
      final resolved = await apiService.getSuggestedPurchasePrice() ?? 0.0;
      if (!mounted || resolved <= 0) return;
      setState(() {
        _purchasePrice24k = resolved;
      });
    } catch (e) {
      debugPrint('⚠️ فشل تحميل سعر شراء الذهب: $e');
    }
  }

  double _fallbackPurchasePriceFromMarket(double marketPrice) {
    if (marketPrice <= 0) return 0.0;
    return double.parse(
      (marketPrice * kScrapPurchasePriceDiscount).toStringAsFixed(2),
    );
  }

  double get _effectivePurchasePrice24k {
    if (_purchasePrice24k > 0) return _purchasePrice24k;
    if (_goldPrice24k > 0) {
      return _fallbackPurchasePriceFromMarket(_goldPrice24k);
    }
    return 0.0;
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
      final apiService = _api;
      final methods = await apiService.getActivePaymentMethods(
        invoiceType: 'شراء من عميل',
      );
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

      // The methods set for a scrap purchase (PAY-TYPES-1): the owner's
      // setting, which the server filters by and holds the invoice to -- no
      // longer a rule written here (cash and transfer).
      final filteredMethods = normalizedMethods;

      final uniqueById = <int, Map<String, dynamic>>{};
      for (final method in filteredMethods) {
        final id = method['id'] as int;
        uniqueById[id] = method;
      }

      final filteredUniqueMethods = uniqueById.values.toList();

      filteredUniqueMethods.sort((a, b) {
        final aOrder = a['display_order'] as int;
        final bOrder = b['display_order'] as int;
        return aOrder.compareTo(bOrder);
      });

      setState(() {
        _paymentMethods = filteredUniqueMethods;

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
    final remaining = double.parse((total - alreadyPaid).toStringAsFixed(2));

    if (remaining <= 0.01) {
      _showError('تم دفع المبلغ بالكامل');
      return;
    }

    final amount = customAmount ?? remaining;

    if (amount > remaining + 0.01) {
      _showError(
        'المبلغ أكبر من المتبقي (${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText})',
      );
      return;
    }

    if (amount <= 0) {
      _showError('المبلغ يجب أن يكون أكبر من صفر');
      return;
    }

    final dynamic rawRate = method['commission_rate'] ?? 0.0;
    final rate = rawRate is num
        ? rawRate.toDouble()
        : double.tryParse(rawRate.toString()) ?? 0.0;

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

      _customAmountController.clear();
      _selectedPaymentMethodId = null;
    });
  }

  /// An amount as the cashier typed it: Arabic digits, «٫», a thousands
  /// comma. Null when it is not a number -- never «the remainder» (an unread
  /// amount was recorded as all that was due).
  double? _readAmount(String text) => double.tryParse(
    normalizeNumber(text).replaceAll(',', '').replaceAll('،', '').trim(),
  );

  /// The chosen method takes the amount typed, or what remains when none is.
  void _addTypedPayment() {
    final typed = _customAmountController.text.trim();
    final customAmount = typed.isEmpty ? null : _readAmount(typed);
    if (typed.isNotEmpty && customAmount == null) {
      _showError('لم يُقرأ المبلغ «$typed»؛ اكتبه أرقامًا فقط');
      return;
    }
    _addPayment(customAmount: customAmount);
  }

  /// One press: the method, and the amount typed or what remains.
  void _payWith(int methodId) {
    setState(() => _selectedPaymentMethodId = methodId);
    _addTypedPayment();
  }

  void _payWithShortcut(int n) {
    if (n > _paymentMethods.length) return;
    if (_items.isEmpty || _remainingAmount <= 0.01) return;
    _payWith(_paymentMethods[n - 1]['id'] as int);
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
  double get _remainingAmount {
    final remaining = _calculateGrandTotal() - _totalPayments;
    // تجاهل الفروقات الصغيرة (أقل من 0.01 ${context.read<SettingsProvider>().currencySymbolText})
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
    debugPrint('📦 عدد الأصناف المتاحة: ${_availableItemsForPurchase.length}');

    try {
      // البحث بالترتيب: Barcode → Item Code → Name
      Map<String, dynamic>? foundItem;

      // 1. البحث بالباركود
      foundItem = _availableItemsForPurchase.firstWhere((item) {
        final barcode = item['barcode']?.toString().toLowerCase();
        final match = barcode == input.toLowerCase();
        if (match) debugPrint('✅ تطابق بالباركود: ${item['name']}');
        return match;
      }, orElse: () => {});

      // 2. البحث برقم الصنف
      if (foundItem.isEmpty) {
        foundItem = _availableItemsForPurchase.firstWhere((item) {
          final code = item['item_code']?.toString().toLowerCase();
          final match = code == input.toLowerCase();
          if (match) debugPrint('✅ تطابق برقم الصنف: ${item['name']}');
          return match;
        }, orElse: () => {});
      }

      // 3. البحث بالاسم
      if (foundItem.isEmpty) {
        foundItem = _availableItemsForPurchase.firstWhere((item) {
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
      final apiService = _api;
      final priceData = await apiService.getGoldPrice();
      final newPrice = _parseDouble(priceData['price_24k']);
      if (newPrice > 0) {
        if (mounted) {
          setState(() {
            _goldPrice24k = newPrice;
            if (_purchasePrice24k <= 0) {
              _purchasePrice24k = _fallbackPurchasePriceFromMarket(newPrice);
            }
          });
        }
        debugPrint(
          '💰 سعر الذهب المحدث: $_goldPrice24k ${context.read<SettingsProvider>().currencySymbolText}/جم',
        );
      } else {
        debugPrint(
          '⚠️ سعر الذهب غير صالح في الاستجابة: ${priceData['price_24k']}',
        );
      }
    } catch (e) {
      debugPrint('⚠️ فشل تحديث سعر الذهب: $e');
      // الاستمرار باستخدام السعر الحالي
    }

    // تحويل آمن للقيم
    double karat = _parseDouble(itemData['karat']);
    if (karat <= 0) {
      karat = _settingsProvider.mainKarat.toDouble();
    }

    // شراء الكسر: الوزن القائم والعدد تُدخل يدوياً
    double wage = 0.0;
    double weight = 0.0;
    double standingWeight = 0.0;
    double stonesWeight = 0.0;
    int quantity = 1;

    final parsedId = _parseInt(itemData['id']);

    setState(() {
      _items.add(
        InvoiceItem(
          itemId: parsedId,
          name: itemData['name'] ?? '',
          barcode: itemData['barcode'] ?? '',
          karat: karat,
          standingWeight: standingWeight,
          stonesWeight: stonesWeight,
          quantity: quantity,
          weight: weight,
          wage: wage,
          goldPrice24k: _effectivePurchasePrice24k,
          mainKarat: _settingsProvider.mainKarat,
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
        case 'standing_weight':
          item.standingWeight = value;
          item.updateWeightFromStandingAndStones();
          if (item._hasManualTotal && item._targetTotal != null) {
            _recalculateFieldsForTarget(item);
          }
          break;
        case 'stones_weight':
          item.stonesWeight = value;
          item.updateWeightFromStandingAndStones();
          if (item._hasManualTotal && item._targetTotal != null) {
            _recalculateFieldsForTarget(item);
          }
          break;
        case 'quantity':
          item.quantity = value.round().clamp(1, 999999);
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
    item.applyTargetTotalCalculations(targetTotal);

    debugPrint(
      '🔄 إعادة حساب شراء كسر للوصول للإجمالي ${targetTotal.toStringAsFixed(2)}:',
    );
    debugPrint(
      '   تكلفة الشراء/جرام: ${item.calculateDirectPurchaseCostPerGram().toStringAsFixed(2)}',
    );
    debugPrint('   الوزن الصافي: ${item.weight.toStringAsFixed(2)}');
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
    });
  }

  void _distributeAmount(double targetTotal) {
    if (_items.isEmpty) return;

    final fixedTotal = _items
        .where((i) => i._hasManualTotal && i._targetTotal != null)
        .fold<double>(0.0, (sum, item) => sum + item.totalWithTax);

    final adjustableItems = _items
        .where(
          (i) => i.weight > 0 && !(i._hasManualTotal && i._targetTotal != null),
        )
        .toList();

    if (adjustableItems.isEmpty) {
      _showError('لا توجد أصناف وزن قابلة للتوزيع');
      return;
    }

    // الخطوة 1: حساب إجمالي التكاليف
    final totalCosts = adjustableItems.fold<double>(
      0.0,
      (sum, item) => sum + item.cost,
    );

    // الخطوة 2: المبلغ المستهدف (لا توجد ضريبة على شراء الكسر)
    final amountWithoutTax = targetTotal;

    // الخطوة 3: حساب الربح المتاح للتوزيع
    final profitPool = (amountWithoutTax - fixedTotal) - totalCosts;

    // الخطوة 4: حساب إجمالي الأوزان
    final totalWeight = adjustableItems.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );

    if (totalWeight == 0) return;

    // الخطوة 5: توزيع الربح حسب نسبة الوزن
    setState(() {
      for (final item in adjustableItems) {
        item.clearManualTotal();
        item.profit = (item.weight / totalWeight) * profitPool;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: _settingsProvider.buildText(
          '✅ تم توزيع $targetTotal ${_settingsProvider.currencySymbolText} على ${adjustableItems.length} صنف\n'
          'التكاليف: ${totalCosts.toStringAsFixed(2)} • الربح الموزع: ${profitPool.toStringAsFixed(2)}',
        ),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ==================== Image Picking Methods ====================
  Future<void> _pickImageFromCamera() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      _showError(
        'التقاط الصورة مدعوم فقط على الهواتف. استخدم خيار المعرض على هذا الجهاز.',
      );
      return;
    }

    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _goldImages.add(File(image.path));
        });
      }
    } catch (e) {
      _showError('فشل التقاط الصورة: ${e.toString()}');
    }
  }

  Future<void> _pickImagesFromGallery() async {
    try {
      final List<XFile> images = await _imagePicker.pickMultiImage(
        imageQuality: 85,
      );

      if (images.isNotEmpty) {
        setState(() {
          _goldImages.addAll(images.map((xFile) => File(xFile.path)));
        });
      }
    } catch (e) {
      _showError('فشل اختيار الصور: ${e.toString()}');
    }
  }

  // ==================== Submit Invoice ====================
  Future<void> _refreshLiveGoldPriceForValidation() async {
    try {
      final apiService = _api;
      final priceData = await apiService.getGoldPrice();
      if (!mounted) return;
      final fetched = _parseDouble(priceData['price_24k']);
      if (fetched > 0) {
        setState(() {
          _goldPrice24k = fetched;
        });
      }
    } catch (_) {
      // Ignore: we'll validate with whatever live price we already have.
    }
  }

  bool _validateItemsAgainstLiveGoldPrice() {
    final live24k = _goldPrice24k;
    if (live24k <= 0) {
      _showError('تعذر التحقق من السعر: سعر الذهب المباشر غير متاح حالياً');
      return false;
    }

    // Allow a tiny tolerance for rounding / input entry.
    const tolerancePct = 0.005; // 0.5%

    for (final item in _items) {
      // Ensure weight is always derived from standing - stones.
      item.updateWeightFromStandingAndStones();

      final hasManualTotal = item._hasManualTotal && item._targetTotal != null;
      final hasWeight = item.weight > 0;
      if (!hasWeight && !hasManualTotal) {
        _showError('يرجى إدخال الوزن أو المبلغ للصنف: ${item.name}');
        return false;
      }

      // Amount-only lines (manual total) are allowed; skip weight-based checks.
      if (!hasWeight && hasManualTotal) {
        if (item.totalWithTax <= 0) {
          _showError('يرجى إدخال مبلغ صحيح للصنف: ${item.name}');
          return false;
        }
        continue;
      }

      if (item.standingWeight <= 0) {
        _showError('يرجى إدخال الوزن القائم لجميع الأصناف');
        return false;
      }
      if (item.stonesWeight < 0) {
        _showError('وزن الأحجار لا يمكن أن يكون سالباً');
        return false;
      }
      if (item.stonesWeight > item.standingWeight + 0.0001) {
        _showError('وزن الأحجار أكبر من الوزن القائم للصنف: ${item.name}');
        return false;
      }
      if (item.weight <= 0) {
        _showError(
          'الوزن الصافي (القائم - الأحجار) يجب أن يكون أكبر من صفر للصنف: ${item.name}',
        );
        return false;
      }

      final livePerGram = live24k * (item.karat / 24.0);
      final paidPerGram = item.net / item.weight;
      final maxAllowed = livePerGram * (1 + tolerancePct);

      // لا نمنع الحفظ هنا؛ إذا تجاوز السعر الحد يُحوَّل القرار إلى
      // نظام الاعتماد في السيرفر مثل فاتورة البيع.
      if (livePerGram > 0 && paidPerGram > maxAllowed) {
        debugPrint(
          '⚠️ purchase_above_live_price: ${item.name} paid=${paidPerGram.toStringAsFixed(2)} live=${livePerGram.toStringAsFixed(2)}',
        );
      }
    }

    return true;
  }

  /// From the press to the server's answer, review included.
  bool _saving = false;

  Future<void> _submitInvoice() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _submitInvoiceOnce();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submitInvoiceOnce() async {
    if (_items.isEmpty) {
      _showError('يرجى إضافة أصناف قبل الحفظ');
      return;
    }
    if (_selectedBranchId == null) {
      _showError('يرجى اختيار الفرع قبل الحفظ');
      return;
    }

    await _refreshLiveGoldPriceForValidation();
    if (!_validateItemsAgainstLiveGoldPrice()) return;

    // ✅ ملخص قبل الحفظ (حفظ/رجوع)
    String customerLabel = 'عميل نقدي';
    if (_selectedCustomerId != null) {
      try {
        final match = widget.customers.firstWhere(
          (c) => c['id'].toString() == _selectedCustomerId.toString(),
        );
        customerLabel = (match['name'] ?? match['customer_name'] ?? 'عميل')
            .toString();
      } catch (_) {
        customerLabel = 'عميل';
      }
    }

    final total = _calculateGrandTotal();
    final totalWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );
    final paid = _totalPayments;
    final remaining = total - paid;

    final proceed = await _showPreSaveInvoiceSummary(
      customerLabel: customerLabel,
      itemsCount: _items.length,
      total: total,
      totalWeight: totalWeight,
      paid: paid,
      remaining: remaining,
      imagesCount: _goldImages.length,
    );
    if (!proceed) return;

    final apiService = _api;
    int? customerId = _selectedCustomerId;

    try {
      Map<String, dynamic>? cashCustomer = _findCashCustomer();

      if (customerId == null) {
        cashCustomer ??= await _getOrCreateCashCustomer(promptIfMissing: false);
        if (cashCustomer == null || cashCustomer['id'] == null) {
          _showError(
            'لا يوجد عميل نقدي متاح. يرجى إنشاء عميل نقدي أو اختيار عميل محدد للمتابعة.',
          );
          return;
        }

        customerId = cashCustomer['id'] as int?;
        if (mounted) {
          setState(() {
            _selectedCustomerId = customerId;
          });
        }

        debugPrint(
          '💵 لم يتم اختيار عميل - تم استخدام عميل نقدي تلقائياً (ID: $customerId)',
        );
      }

      if (customerId == null) {
        _showError('تعذر تحديد العميل للفاتورة');
        return;
      }

      // ================= Identity fields enforcement for scrap purchase =================
      // If the selected customer is not the cash customer, ensure identity fields exist
      Map<String, dynamic>? selectedCustomer;
      if (_selectedCustomerId != null) {
        selectedCustomer = widget.customers.firstWhere((c) {
          final rawId = c['id'];
          if (rawId == null) return false;
          final parsed = rawId is int ? rawId : int.tryParse(rawId.toString());
          return parsed == _selectedCustomerId;
        }, orElse: () => {});
        if (selectedCustomer.isEmpty) selectedCustomer = null;
      }

      // Only enforce identity for real customers (not the special 'نقدي' cash customer)
      final isCashCustomer = (selectedCustomer == null)
          ? (cashCustomer != null && _isCashCustomerEntry(cashCustomer))
          : _isCashCustomerEntry(selectedCustomer);

      if (!isCashCustomer) {
        final idNumber =
            selectedCustomer?['id_number']?.toString().trim() ?? '';
        final idVersion =
            selectedCustomer?['id_version_number']?.toString().trim() ?? '';
        final birthDate =
            selectedCustomer?['birth_date']?.toString().trim() ?? '';

        if (idNumber.isEmpty || idVersion.isEmpty || birthDate.isEmpty) {
          _showError(
            'يجب أن يحتوي العميل المختار على رقم الهوية، رقم نسخة الهوية وتاريخ الميلاد قبل حفظ فاتورة شراء الكسر.\nيرجى تعديل بيانات العميل أو إضافة عميل جديد مع معلومات الهوية.',
          );
          return;
        }
      }

      // حساب الإجماليات
      final totalAmount = _calculateGrandTotal();
      final weightItems = _items.where((i) => i.weight > 0).toList();
      final totalWeight = weightItems.fold<double>(
        0.0,
        (sum, item) => sum + item.weight,
      );
      final totalCost = weightItems.fold<double>(
        0.0,
        (sum, item) => sum + item.cost,
      );
      // لا توجد ضريبة على شراء الكسر
      final totalTax = 0.0;

      // الحصول على بيانات الموظف الحالي
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final currentUser = authProvider.currentUser;
      final employeeId = currentUser?.employeeId;
      final employeeName =
          currentUser?.employee?.name ?? currentUser?.fullName ?? '';
      final employeeGoldSafeId = currentUser?.employee?.goldSafeBoxId;

      // حساب الموظف الحالي غير مربوط بسجل موظف → لن يُسنَد الذهب لخزينته الشخصية.
      // النظام يتراجع للخزينة الرئيسية للكسر. يُنصح بربط الحساب بموظف من إدارة المستخدمين.
      if (warnsGoldGoesToMainScrapSafe(
            signedInEmployeeId: employeeId,
            editInvoiceData: _isEditMode ? widget.editInvoiceData : null,
          ) &&
          mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('تنبيه: حساب غير مرتبط بموظف'),
            content: const Text(
              'حسابك الحالي غير مرتبط بسجل موظف، لذلك لن يُسجَّل الذهب المستلم في خزينة موظف شخصية.\n\n'
              'سيتم حفظ الفاتورة وإسناد الذهب للخزينة الرئيسية للكسر تلقائياً.\n\n'
              'هل تريد المتابعة؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('متابعة'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }

      final effectiveSafeBoxId = employeeGoldSafeId ?? _selectedSafeBoxId;

      final invoiceData = {
        'customer_id': customerId,
        'branch_id': _selectedBranchId,
        'invoice_type': 'شراء من عميل',
        'gold_type': 'scrap',
        'transaction_type': 'buy', // 🆕 شراء من العميل
        if (employeeName.isNotEmpty) 'posted_by': employeeName,
        if (employeeId != null) 'employee_id': employeeId,
        if (employeeId != null) 'scrap_holder_employee_id': employeeId,
        if (effectiveSafeBoxId != null) 'safe_box_id': effectiveSafeBoxId,
        'date': DateTime.now().toIso8601String(),
        'total': totalAmount,
        'total_weight': totalWeight,
        'total_cost': totalCost,
        'total_tax': totalTax,
        'payments': _payments
            .map((p) => p.toJson())
            .toList(), // 🆕 إرسال array من الدفعات
        'amount_paid': _totalPayments, // 🆕 إجمالي المدفوع
        'items': _items.map((item) => item.toJson()).toList(),
        // 🆕 بيانات شراء الكسر
        'notes': _purchaseNotesController.text.trim(),
        'gold_condition': _goldCondition,
        'gold_images_count': _goldImages.length,
      };

      final response = _isEditMode
          ? await apiService.updateUnpostedInvoice(widget.editInvoiceId!, invoiceData)
          : await apiService.addInvoice(invoiceData);

      final approvalRequired = response['approval_required'] == true;
      final approvalReasons = (response['approval_reasons'] is List)
          ? List<String>.from(response['approval_reasons'])
          : <String>[
              if (response['approval_reason'] != null)
                response['approval_reason'].toString(),
            ];

      String? approvalWarning;
      if (approvalRequired) {
        final parts = <String>[];
        if (approvalReasons.contains('above_live_price')) {
          final above = (response['above_live_price'] is Map)
              ? Map<String, dynamic>.from(response['above_live_price'])
              : const <String, dynamic>{};
          final items = (above['items'] is List)
              ? List<Map<String, dynamic>>.from(
                  (above['items'] as List).whereType<Map>(),
                )
              : const <Map<String, dynamic>>[];
          if (items.isNotEmpty) {
            final first = items.first;
            parts.add(
              '⚠️ شراء أعلى من السعر المباشر: ${first['name'] ?? 'صنف'} '
              'بسعر/جرام ${((first['paid_per_gram'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2)} '
              'مقابل مباشر ${((first['live_per_gram'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2)}',
            );
          } else {
            parts.add('⚠️ شراء أعلى من السعر المباشر');
          }
        }

        approvalWarning = parts.isNotEmpty
            ? '${parts.join('\n')}\nسيتم حفظ الفاتورة لكن لن تُرحَّل حتى اعتماد المدير.'
            : '⚠️ تم حفظ الفاتورة لكن تحتاج اعتماد مدير قبل الترحيل.';

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(approvalWarning),
              backgroundColor: Colors.orange.shade800,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }

      if (!mounted) return;

      // Edit mode: back to the invoices list, which reloads on `true`.
      if (_isEditMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ التعديل — الفاتورة برقمها وتاريخها')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      final invoiceForPrint = Map<String, dynamic>.from(response);
      try {
        final match = widget.customers.firstWhere(
          (c) => c['id'].toString() == customerId.toString(),
        );
        invoiceForPrint['customer_name'] ??=
            match['name'] ?? match['customer_name'];
        invoiceForPrint['customer_phone'] ??=
            match['phone'] ?? match['customer_phone'];
      } catch (_) {
        // ignore
      }

      final shouldPrint = _uiAutoOpenPrintAfterSave
          ? 'print'
          : await _showPostSaveInvoiceSummary(
              invoice: invoiceForPrint,
              approvalRequired: approvalRequired,
              approvalWarning: approvalWarning,
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
          _showError('تعذر فتح الطباعة: $e');
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
          _showError('تعذر مشاركة الفاتورة: $e');
        }
      }

      if (!mounted) return;
      if (shouldPrint == 'new_invoice') {
        _resetAfterSave();
      } else {
        // 'done' or null → return to home
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      _showError('فشل حفظ الفاتورة: $e');
    }
  }

  Future<bool> _showPreSaveInvoiceSummary({
    required String customerLabel,
    required int itemsCount,
    required double total,
    required double totalWeight,
    required double paid,
    required double remaining,
    required int imagesCount,
  }) async {
    final currency = _settingsProvider.currencySymbolText;
    final weightBreakdown = _buildWeightBreakdownLines(
      _items.map((item) => item.toJson()),
    );

    final notices = <String>[];
    if (remaining > 0.01) {
      notices.add('يوجد مبلغ متبقي. تأكد من الدفعات قبل الحفظ.');
    }
    if (imagesCount == 0) {
      notices.add('لم يتم إرفاق صور للذهب.');
    }
    if (_purchaseNotesController.text.trim().isEmpty) {
      notices.add('لا توجد ملاحظات على الفاتورة.');
    }
    notices.addAll(
      scrapPurchasePriceWarnings(
        lines: _lineFacts(),
        goldPrice24k: _goldPrice24k,
        formatCash: _formatCurrency,
      ),
    );

    return await showAdaptiveInvoiceSummaryDialog<bool>(
          context: context,
          title: 'مراجعة فاتورة ${InvoiceKind.purchaseScrap.label}',
          subtitle: 'راجع البيانات الأساسية سريعاً قبل تنفيذ الحفظ.',
          icon: Icons.receipt_long_rounded,
          accentColor: AppSemanticColors.of(
            context,
          ).invoice(InvoiceKind.purchaseScrap).fg,
          statusTitle: 'حالة السداد',
          statusMessage: remaining > 0.01
              ? 'متبقي ${remaining.toStringAsFixed(2)} $currency'
              : 'تم الدفع بالكامل',
          statusTone: remaining > 0.01
              ? InvoiceSummaryStatusTone.due
              : InvoiceSummaryStatusTone.success,
          metrics: [
            if (customerLabel.trim().isNotEmpty)
              InvoiceSummaryMetric(
                label: 'العميل',
                value: customerLabel.trim(),
                icon: Icons.person_outline_rounded,
                accentColor: AppColors.info,
              ),
            InvoiceSummaryMetric(
              label: 'عدد الأصناف',
              value: itemsCount.toString(),
              icon: Icons.inventory_2_outlined,
              accentColor: AppColors.info,
            ),
            InvoiceSummaryMetric(
              label: 'الإجمالي',
              value: '${total.toStringAsFixed(2)} $currency',
              icon: Icons.payments_outlined,
              accentColor: AppColors.primaryGold,
              emphasize: true,
            ),
            InvoiceSummaryMetric(
              label: 'المدفوع',
              value: '${paid.toStringAsFixed(2)} $currency',
              icon: Icons.account_balance_wallet_outlined,
              accentColor: AppColors.success,
            ),
            InvoiceSummaryMetric(
              label: 'المتبقي',
              value: '${remaining.toStringAsFixed(2)} $currency',
              icon: Icons.pending_outlined,
              accentColor: remaining > 0.01
                  ? AppColors.error
                  : AppColors.success,
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
            if (imagesCount > 0)
              InvoiceSummaryMetric(
                label: 'الصور المرفقة',
                value: imagesCount.toString(),
                icon: Icons.image_outlined,
                accentColor: AppColors.info,
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

  // ==================== Calculations ====================
  double _calculateGrandTotal() {
    return _items.fold<double>(0.0, (sum, item) => sum + item.totalWithTax);
  }

  // ==================== Helpers ====================
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  Map<String, dynamic>? _findCashCustomer() {
    Map<String, dynamic>? best;
    int? bestId;
    for (final customer in widget.customers) {
      if (!_isCashCustomerEntry(customer)) continue;
      final rawId = customer['id'];
      final id = rawId is int ? rawId : int.tryParse('$rawId');
      if (id == null) continue;
      if (best == null || id < bestId!) {
        best = {...customer, 'id': id};
        bestId = id;
      }
    }
    return best;
  }

  bool _isCashCustomerEntry(Map<String, dynamic>? customer) =>
      customer != null &&
      _cashCustomerNames.contains(_foldSpaces(customer['name']));

  Future<Map<String, dynamic>?> _getOrCreateCashCustomer({
    bool promptIfMissing = true,
  }) async {
    final existing = _findCashCustomer();
    if (existing != null) return existing;

    if (!promptIfMissing) {
      return _createCashCustomerRecord();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final shouldCreate =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Text(
                'لا يوجد عميل نقدي',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                'لا يوجد عميل نقدي في قائمة العملاء الحالية. هل ترغب في إنشاء عميل نقدي افتراضي الآن؟',
                style: theme.textTheme.bodyMedium,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('إلغاء', style: theme.textTheme.bodyMedium),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('إنشاء عميل نقدي'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldCreate) {
      return null;
    }

    return _createCashCustomerRecord();
  }

  Future<Map<String, dynamic>?> _createCashCustomerRecord() async {
    try {
      final api = _api;
      final payload = {
        'name': 'عميل نقدي',
        'phone': '',
        'address_line_1': 'إنشاء تلقائي',
        'notes': 'تم إنشاؤه تلقائياً للاستخدام كعميل نقدي',
        'active': true,
      };

      final response = await api.addCustomer(payload);
      if (!mounted) return response;
      setState(() {
        widget.customers.add(response);
      });
      return response;
    } catch (e) {
      _showError('فشل إنشاء عميل نقدي: $e');
      return null;
    }
  }

  Future<String?> _showPostSaveInvoiceSummary({
    required Map<String, dynamic> invoice,
    bool approvalRequired = false,
    String? approvalWarning,
  }) async {
    double asDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0.0;
    }

    final total = asDouble(invoice['total']);
    final paid = asDouble(invoice['amount_paid']);
    final remaining = total - paid;
    final totalWeight = asDouble(invoice['total_weight']);
    final invoiceId = invoice['id']?.toString() ?? '';

    final customerName = (invoice['customer_name'] ?? invoice['customer'] ?? '')
        .toString()
        .trim();

    final currency = _settingsProvider.currencySymbolText;
    final weightBreakdown = _buildWeightBreakdownLines(
      invoice['items'] is List
          ? List<dynamic>.from(invoice['items'])
          : const [],
    );

    return await showAdaptiveInvoiceSummaryDialog<String>(
          context: context,
          title: 'تم حفظ الفاتورة',
          subtitle: 'تم حفظ فاتورة شراء الكسر بنجاح',
          icon: Icons.check_circle,
          accentColor: AppColors.success,
          highlightMessage: 'فاتورة الشراء #${invoice['id'] ?? ''}',
          statusTitle: 'حالة الفاتورة',
          statusMessage: approvalRequired
              ? 'تحتاج اعتماد مدير'
              : 'جاهزة للطباعة والمشاركة',
          statusTone: approvalRequired
              ? InvoiceSummaryStatusTone.due
              : InvoiceSummaryStatusTone.success,
          metrics: [
            if (invoiceId.isNotEmpty)
              InvoiceSummaryMetric(
                label: 'رقم الفاتورة',
                value: '#$invoiceId',
                icon: Icons.tag_rounded,
                accentColor: AppColors.primaryGold,
              ),
            if (customerName.isNotEmpty)
              InvoiceSummaryMetric(
                label: 'العميل',
                value: customerName,
                icon: Icons.person_outline_rounded,
                accentColor: AppColors.info,
              ),
            InvoiceSummaryMetric(
              label: 'الإجمالي',
              value: '${total.toStringAsFixed(2)} $currency',
              icon: Icons.payments_outlined,
              accentColor: AppColors.primaryGold,
              emphasize: true,
            ),
            InvoiceSummaryMetric(
              label: 'المدفوع',
              value: '${paid.toStringAsFixed(2)} $currency',
              icon: Icons.account_balance_wallet_outlined,
              accentColor: AppColors.success,
            ),
            InvoiceSummaryMetric(
              label: 'المتبقي',
              value: '${remaining.toStringAsFixed(2)} $currency',
              icon: Icons.pending_outlined,
              accentColor: remaining > 0.01
                  ? AppColors.error
                  : AppColors.success,
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
          notices: approvalRequired && approvalWarning != null
              ? [approvalWarning]
              : [],
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
  }

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

  // Open the reusable AddCustomerScreen so we can enforce identity fields when needed
  Future<void> _addNewCustomer() async {
    final result = await Navigator.push<bool?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddCustomerScreen(
          api: _api,
          enforceIdentityFields: true, // scrap purchases require identity data
          onCustomerSaved: (saved) {
            if (!mounted) return;
            setState(() {
              widget.customers.add(saved);
              final rawId = saved['id'];
              _selectedCustomerId = rawId is int
                  ? rawId
                  : int.tryParse(rawId.toString());
            });
          },
        ),
      ),
    );

    if (result == true) {
      debugPrint('Customer added via AddCustomerScreen');
    }
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
            itemCount: _availableItemsForPurchase.length,
            itemBuilder: (context, index) {
              final item = _availableItemsForPurchase[index];
              return ListTile(
                leading: Icon(Icons.inventory_2, color: colorScheme.primary),
                title: Text(item['name'] ?? ''),
                subtitle: Text(
                  'عيار: ${item['karat']}',
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
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              await _showAddPurchaseItemDialog();
            },
            icon: const Icon(Icons.add),
            label: const Text('إضافة صنف'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddPurchaseItemDialog() async {
    final theme = Theme.of(context);
    final nameController = TextEditingController();
    String selectedKarat = _settingsProvider.mainKarat.toString();

    try {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'إضافة صنف شراء',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'اسم الصنف *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedKarat,
                decoration: const InputDecoration(
                  labelText: 'العيار',
                  border: OutlineInputBorder(),
                ),
                items: const ['14', '18', '21', '22', '24']
                    .map(
                      (k) => DropdownMenuItem<String>(
                        value: k,
                        child: Text('عيار $k'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  selectedKarat = value;
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('اسم الصنف مطلوب')),
                  );
                  return;
                }

                try {
                  final api = _api;
                  final created = await api.createPurchaseItem(
                    name: name,
                    karat: selectedKarat,
                  );

                  if (!mounted) return;
                  setState(() {
                    _purchaseItems = [
                      Map<String, dynamic>.from(created),
                      ..._purchaseItems,
                    ];
                  });

                  Navigator.pop(context);
                  await _addItemFromData(Map<String, dynamic>.from(created));

                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(
                        content: Text('✅ تمت إضافة: ${created['name']}'),
                        backgroundColor: AppColors.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('فشل إضافة الصنف: $e'),
                      backgroundColor: AppColors.error,
                    ),
                  );
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      );
    } finally {
      nameController.dispose();
    }
  }

  // ==================== UI Build ====================
  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        final theme = Theme.of(context);
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
                        _buildSummaryCard(),
                        const SizedBox(height: 24),
                        _buildGoldImagesSection(),
                        const SizedBox(height: 24),
                        _buildNotesSection(),
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
              _buildSummaryCard(),
              const SizedBox(height: 24),
              _buildGoldImagesSection(),
              const SizedBox(height: 24),
              _buildNotesSection(),
              const SizedBox(height: 24),
              _buildPaymentSection(),
            ],
            const SizedBox(height: 32),
          ],
        );

        final readiness = _readiness();
        final scaffold = Scaffold(
          bottomNavigationBar: _buildFooter(theme, readiness),
          appBar: AppBar(
            backgroundColor: AppSemanticColors.invoiceBar(
              context,
              InvoiceKind.purchaseScrap,
            ).background,
            foregroundColor: AppSemanticColors.invoiceBar(
              context,
              InvoiceKind.purchaseScrap,
            ).foreground,
            iconTheme: IconThemeData(
              color: AppSemanticColors.invoiceBar(
                context,
                InvoiceKind.purchaseScrap,
              ).foreground,
            ),
            title: const Text('فاتورة شراء الكسر'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(26.0),
              child: Container(
                color: Colors.black.withValues(alpha: 0.20),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: _goldPrice24k > 0
                      ? Row(
                          children: [
                            const Icon(
                              Icons.monetization_on_outlined,
                              size: 12,
                              color: Colors.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'أونصة: \$${(_goldPrice24k * 31.1035 / 3.75).toStringAsFixed(0)}',
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
                              final gp = _goldPrice24k * k / 24;
                              final isMain = k == _settingsProvider.mainKarat;
                              return Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Text(
                                  '${k}k: ${gp.toStringAsFixed(2)}',
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
                            const Text(
                              '/جم',
                              style: TextStyle(
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
              ),
            ),
            actions: [
              Consumer<AuthProvider>(
                builder: (context, auth, _) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
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
                tooltip: 'تحديث سعر الذهب',
                onPressed: _loadSettings,
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: 'إعدادات الفاتورة',
                icon: const Icon(Icons.settings),
                onPressed: () async {
                  await InvoiceSettingsSheet.show(
                    context,
                    contextType: InvoiceUiContext.scrapPurchase,
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
                    },
                  );
                },
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

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _confirmLeave();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                  _saveIfReady,
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                  _saveIfReady,
              for (var n = 1; n <= 9; n++)
                SingleActivator(
                  LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + n),
                  alt: true,
                ): () => _payWithShortcut(n),
            },
            // A scope, so a field left with Enter hands focus back under the
            // shortcuts -- not to the route, where Ctrl+S is not heard.
            child: FocusScope(autofocus: true, child: scaffold),
          ),
        );
      },
    );
  }

  /// The one answer the footer and the save button read: ready only when the
  /// purchase would be saved (utils/scrap_purchase_readiness.dart).
  ScrapPurchaseReadiness _readiness() {
    Map<String, dynamic>? customer;
    for (final c in widget.customers) {
      final rawId = c['id'];
      final id = rawId is int ? rawId : int.tryParse('$rawId');
      if (id != null && id == _selectedCustomerId) customer = c;
    }
    // The walk-in customer needs no identity; any other does.
    String? missing;
    if (customer != null && !_isCashCustomerEntry(customer)) {
      bool blank(String k) => (customer?[k]?.toString().trim() ?? '').isEmpty;
      if (blank('id_number') ||
          blank('id_version_number') ||
          blank('birth_date')) {
        missing = _foldSpaces(customer['name']);
      }
    }
    return scrapPurchaseReadiness(
      ScrapPurchaseFacts(
        branchChosen: _selectedBranchId != null,
        lines: _lineFacts(),
        total: _calculateGrandTotal(),
        paid: _totalPayments,
        customerMissingIdentity: missing,
        goldPriceKnown: _goldPrice24k > 0,
      ),
      formatCash: _formatCurrency,
    );
  }

  List<ScrapLineFacts> _lineFacts() => [
    for (final i in _items)
      ScrapLineFacts(
        standing: i.standingWeight,
        stones: i.stonesWeight,
        weight: (i.standingWeight - i.stonesWeight) > 0
            ? i.standingWeight - i.stonesWeight
            : 0,
        karat: i.karat,
        total: i.totalWithTax,
      ),
  ];

  String _formatCurrency(double amount) =>
      '${amount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}';

  void _saveIfReady() {
    if (_saving) return;
    if (_readiness().isReady) _submitInvoice();
  }

  bool get _hasUnsavedWork => _items.isNotEmpty || _payments.isNotEmpty;

  /// Back, the system gesture, the app bar arrow: leave at once when nothing
  /// was entered, otherwise ask -- the invoice is lost with the screen.
  Future<void> _confirmLeave() async {
    if (_saving) return;
    if (!_hasUnsavedWork) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('فاتورة غير محفوظة'),
        content: const Text(
          'في الفاتورة أصناف أو مبالغ لم تُحفظ. ماذا تريد أن تفعل؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('متابعة التحرير'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('خروج دون حفظ'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (discard == true) Navigator.of(context).pop();
  }

  /// What stands between the buyer and a saved purchase, and the button that
  /// saves it -- always in view, never a message that passes.
  Widget _buildFooter(ThemeData theme, ScrapPurchaseReadiness readiness) {
    final colorScheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final ready = readiness.isReady;
    final empty = readiness.kind == ScrapPurchaseReadinessKind.empty;
    final tone = ready ? tones.ready : (empty ? tones.info : tones.blocked);
    final text = _saving
        ? 'جارٍ الحفظ…'
        : ready
        ? 'جاهز للحفظ'
        : empty
        ? readiness.message
        : 'غير جاهز للحفظ — ${readiness.message}';
    return Material(
      color: colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      ready
                          ? Icons.check_circle
                          : (empty ? Icons.info_outline : Icons.error_outline),
                      color: tone.fg,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: tone.fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: ready && !_saving ? _submitInvoice : null,
                icon: const Icon(Icons.check_circle_outline, size: 22),
                label: _settingsProvider.buildText('حفظ الفاتورة'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    vertical: 16,
                    horizontal: 24,
                  ),
                  textStyle: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
                    color: colorScheme.primary.withValues(
                      alpha: isDark ? 0.18 : 0.12,
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
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: isDark ? 0.25 : 0.5,
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
                initialValue: _selectedCustomerId,
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

            const SizedBox(height: 14),
            if (_isLoadingBranches)
              const LinearProgressIndicator(minHeight: 2)
            else if (_branchesLoadingError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'فشل تحميل الفروع: $_branchesLoadingError',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _loadBranches,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة'),
                    ),
                  ],
                ),
              )
            else
              DropdownButtonFormField<int>(
                initialValue: _selectedBranchId,
                items: _branches
                    .map((branch) {
                      final id = _parseInt(branch['id']);
                      if (id == null) return null;
                      final name = (branch['name'] ?? 'فرع').toString();
                      return DropdownMenuItem<int>(
                        value: id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.account_tree,
                              color: colorScheme.primary,
                              size: 20,
                            ),
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
                          ],
                        ),
                      );
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedBranchId = value;
                  });
                },
                decoration: InputDecoration(
                  labelText: 'اختر الفرع',
                  prefixIcon: Icon(
                    Icons.account_tree,
                    color: colorScheme.primary,
                  ),
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
    if (_categories.isEmpty) return _buildQuickInputBox(theme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'سطر كسر',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'اكتب الوزن القائم أو المبلغ أو كليهما: Enter يضيف السطر.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                ScrapPurchaseEntryRow(
                  categories: _categories,
                  mainKarat: _settingsProvider.mainKarat,
                  onAdd: _addEnteredScrap,
                ),
              ],
            ),
          ),
        ),
        _buildQuickInputBox(theme),
      ],
    );
  }

  Widget _buildQuickInputBox(ThemeData theme) {
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
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.category_outlined,
                AppColors.warning,
                'سطر تصنيف',
                _addCategoryLine,
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
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.3 : 0.06,
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
              ? [
                  colorScheme.surfaceContainerHighest,
                  theme.scaffoldBackgroundColor,
                ]
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
        columnSpacing: 16,
        horizontalMargin: 12,
        headingRowColor: WidgetStateProperty.all(
          colorScheme.primary.withValues(alpha: 0.15),
        ),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.1);
          }
          return theme.cardColor;
        }),
        columns: [
          DataColumn(label: Text('#', style: headerStyle)),
          DataColumn(label: Text('الاسم', style: headerStyle)),
          DataColumn(label: Text('العيار', style: headerStyle)),
          DataColumn(label: Text('الوزن القائم', style: headerStyle)),
          DataColumn(label: Text('العدد', style: headerStyle)),
          DataColumn(label: Text('وزن الأحجار', style: headerStyle)),
          DataColumn(label: Text('الوزن', style: headerStyle)),
          DataColumn(label: Text('تكلفة الشراء/جرام', style: headerStyle)),
          DataColumn(label: Text('الإجمالي', style: headerStyle)),
          DataColumn(label: Text('إجراءات', style: headerStyle)),
        ],
        rows: _items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;

          return DataRow(
            cells: [
              DataCell(Text((index + 1).toString(), style: cellStyle)),
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
                      item.karat.toStringAsFixed(0),
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(
                    index,
                    'standing_weight',
                    item.standingWeight,
                  ),
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
                      item.standingWeight.toStringAsFixed(2),
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(
                    index,
                    'quantity',
                    item.quantity.toDouble(),
                  ),
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
                    child: Text(item.quantity.toString(), style: cellStyle),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(
                    index,
                    'stones_weight',
                    item.stonesWeight,
                  ),
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
                      item.stonesWeight.toStringAsFixed(2),
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(Text(item.weight.toStringAsFixed(2), style: cellStyle)),
              DataCell(
                Text(
                  item.calculateDirectPurchaseCostPerGram().toStringAsFixed(2),
                  style: cellStyle,
                ),
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
                    child: _settingsProvider.buildText(
                      '${item.totalWithTax.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
    if (_uiLockPriceEdits) {
      _showError('التعديلات مقفلة من إعدادات الفاتورة');
      return;
    }

    final controller = TextEditingController(text: currentValue.toString());
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String title = '';
    String label = '';

    switch (field) {
      case 'karat':
        title = 'تعديل العيار';
        label = 'العيار';
        break;
      case 'standing_weight':
        title = 'تعديل الوزن القائم';
        label = 'الوزن القائم';
        break;
      case 'stones_weight':
        title = 'تعديل وزن الأحجار';
        label = 'وزن الأحجار';
        break;
      case 'quantity':
        title = 'تعديل العدد';
        label = 'العدد';
        break;
      case 'total':
        title = 'تعديل الإجمالي';
        label = 'الإجمالي';
        break;
    }

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: field == 'quantity'
              ? TextInputType.number
              : const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          inputFormatters: [NormalizeNumberFormatter()],
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (_) {
            final value = double.tryParse(controller.text);
            if (value != null) {
              _updateItem(index, field, value);
              Navigator.pop(dialogContext);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                _updateItem(index, field, value);
                Navigator.pop(dialogContext);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  // ==================== Gold Images Section ====================
  Widget _buildGoldImagesSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.camera_alt, color: colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Text(
                  'صور الذهب',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _pickImageFromCamera,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('التقاط صورة'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _pickImagesFromGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('اختيار من المعرض'),
                  ),
                ),
              ],
            ),
            if (_goldImages.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'الصور المختارة: ${_goldImages.length}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _goldImages.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              _goldImages[index],
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            top: 4,
                            left: 4,
                            child: IconButton.filled(
                              onPressed: () {
                                setState(() {
                                  _goldImages.removeAt(index);
                                });
                              },
                              icon: const Icon(Icons.close, size: 18),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.red.shade700,
                                minimumSize: const Size(28, 28),
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== Notes Section ====================
  Widget _buildNotesSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selectedCondition = _goldConditionOptions.contains(_goldCondition)
        ? _goldCondition
        : _goldConditionOptions[1];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notes, color: colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Text(
                  'ملاحظات الشراء',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: selectedCondition,
              decoration: InputDecoration(
                labelText: 'حالة الذهب',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
              ),
              items: _goldConditionOptions
                  .map(
                    (option) => DropdownMenuItem<String>(
                      value: option,
                      child: Text(option),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _goldCondition = _goldConditionOptions.contains(value)
                      ? value!
                      : 'جيد';
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _purchaseNotesController,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'ملاحظات إضافية',
                hintText: 'أدخل أي ملاحظات حول الشراء...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Summary ====================
  /// The total, what is paid and what remains, said once. The target amount
  /// spreads a price over the lines (Enter).
  Widget _buildSummaryCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final currency = _settingsProvider.currencySymbolText;
    final total = _calculateGrandTotal();
    final remaining = _remainingAmount;
    final weight = _items.fold<double>(0.0, (sum, i) => sum + i.weight);

    Widget row(String label, String value, {Color? color, bool bold = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              _settingsProvider.buildText(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: bold ? FontWeight.bold : FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        );

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'ملخص الفاتورة',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _settingsProvider.buildText(
              '${total.toStringAsFixed(2)} $currency',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            Text(
              '${_items.length} صنف • الوزن الصافي ${weight.toStringAsFixed(3)} جم',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            row('المدفوع', '${_totalPayments.toStringAsFixed(2)} $currency'),
            if (_totalCommission > 0)
              row(
                'إجمالي العمولات',
                '${_totalCommission.toStringAsFixed(2)} $currency',
                color: tones.warning.fg,
              ),
            const Divider(height: 16),
            if (_items.isEmpty)
              const SizedBox.shrink()
            else if (remaining > 0.01)
              row(
                'المتبقي',
                '${remaining.toStringAsFixed(2)} $currency',
                color: tones.blocked.fg,
                bold: true,
              )
            else
              Text(
                '✓ تم الدفع بالكامل',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: tones.ready.fg,
                  fontWeight: FontWeight.bold,
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('target-amount'),
              enabled: _items.isNotEmpty,
              inputFormatters: [NormalizeNumberFormatter()],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'المبلغ المطلوب',
                helperText: 'يُوزَّع على الأسطر',
                suffixText: currency,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (value) {
                final target = _readAmount(value);
                if (target == null || target <= 0) {
                  _showError('اكتب المبلغ المطلوب أرقامًا');
                  return;
                }
                _distributeAmount(target);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ==================== Payment Section ====================
  Widget _buildPaymentSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
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
                            colorScheme.primary.withValues(
                              alpha: isDark ? 0.25 : 0.3,
                            ),
                            AppColors.lightGold.withValues(
                              alpha: isDark ? 0.2 : 0.35,
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
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
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
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
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
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
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
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
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
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
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
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: isDark ? 0.3 : 0.5),
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
                                        color: AppColors.warning.withValues(
                                          alpha: isDark ? 0.2 : 0.25,
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
                              child: _settingsProvider.buildText(
                                '${payment.amount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: _settingsProvider.buildText(
                                payment.commissionAmount > 0
                                    ? '${payment.commissionAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}'
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
                              child: _settingsProvider.buildText(
                                '${payment.netAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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

            if (_items.isNotEmpty && _remainingAmount > 0.01) ...[
              PayBox(
                amount: _customAmountController,
                remaining: _remainingAmount,
                currency: _settingsProvider.currencySymbolText,
                methods: _paymentMethods,
                onPay: _payWith,
                remainingText: _settingsProvider.buildText(
                  'المتبقي: ${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
                ),
              ),
            ],

          ],
        ),
      ),
    );
  }
}

class _ScrapCategoryLineResult {
  final String categoryName;
  final double amountCash;
  final double karat;
  final double weight;
  final double stonesWeight;
  final double wage;
  final int count;

  const _ScrapCategoryLineResult({
    required this.categoryName,
    required this.amountCash,
    required this.karat,
    required this.weight,
    this.stonesWeight = 0.0,
    required this.wage,
    required this.count,
  });
}

class _ScrapCategoryLineDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final String currencySymbol;
  final int mainKarat;

  const _ScrapCategoryLineDialog({
    required this.categories,
    required this.currencySymbol,
    required this.mainKarat,
  });

  @override
  State<_ScrapCategoryLineDialog> createState() =>
      _ScrapCategoryLineDialogState();
}

class _ScrapCategoryLineDialogState extends State<_ScrapCategoryLineDialog> {
  final _formKey = GlobalKey<FormState>();
  final _searchController = TextEditingController();
  final _weightController = TextEditingController(text: '1.0');
  final _stonesWeightController = TextEditingController(text: '0');
  final _wageController = TextEditingController(text: '0');
  final _countController = TextEditingController(text: '1');
  final _amountController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _weightFocusNode = FocusNode();
  final _stonesWeightFocusNode = FocusNode();
  final _wageFocusNode = FocusNode();
  final _countFocusNode = FocusNode();
  final _amountFocusNode = FocusNode();

  Map<String, dynamic>? _selected;
  String _query = '';

  late int _selectedKarat;
  bool _karatLockedByCategory = false;

  @override
  void initState() {
    super.initState();
    _selectedKarat = widget.mainKarat;
    for (final c in [
      _weightController,
      _stonesWeightController,
      _wageController,
      _countController,
    ]) {
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _weightController.dispose();
    _stonesWeightController.dispose();
    _wageController.dispose();
    _countController.dispose();
    _amountController.dispose();
    _searchFocusNode.dispose();
    _weightFocusNode.dispose();
    _stonesWeightFocusNode.dispose();
    _wageFocusNode.dispose();
    _countFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  double _tryParseDouble(String value) {
    final normalized = normalizeNumber(value).trim();
    return double.tryParse(normalized) ?? 0.0;
  }

  int? _tryParseCategoryKarat(Map<String, dynamic> category) {
    final raw = category['karat'];
    final parsed = int.tryParse('${raw ?? ''}');
    if (parsed == null) return null;
    if (const [18, 21, 22, 24].contains(parsed)) return parsed;
    return null;
  }

  void _focusAndSelect(FocusNode focusNode, TextEditingController controller) {
    focusNode.requestFocus();
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  void _selectFirstMatchingCategory(List<Map<String, dynamic>> options) {
    if (options.isEmpty) return;
    final first = options.first;
    final karat = _tryParseCategoryKarat(first);
    setState(() {
      _selected = first;
      _karatLockedByCategory = karat != null;
      if (karat != null) {
        _selectedKarat = karat;
      }
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final selected = _selected;
    if (selected == null) return;

    final name = (selected['name'] ?? '').toString().trim();
    final weight = _tryParseDouble(_weightController.text);
    final stonesWeight = _tryParseDouble(_stonesWeightController.text);
    final wage = _tryParseDouble(_wageController.text);
    final count =
        int.tryParse(normalizeNumber(_countController.text).trim()) ?? 0;
    final amount = _tryParseDouble(_amountController.text);

    if (name.isEmpty) return;
    if (count < 1) return;
    if (weight <= 0 && amount <= 0) return;

    Navigator.of(context).pop(
      _ScrapCategoryLineResult(
        categoryName: name,
        amountCash: amount,
        karat: _selectedKarat.toDouble(),
        weight: weight,
        stonesWeight: stonesWeight,
        wage: wage,
        count: count,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final filtered = widget.categories.where((c) {
      final name = (c['name'] ?? '').toString().toLowerCase();
      if (_query.isEmpty) return true;
      return name.contains(_query);
    }).toList();

    final limited = filtered.take(120).toList();
    final screenSize = MediaQuery.sizeOf(context);
    final dialogMaxHeight = (screenSize.height * 0.85).clamp(720.0, 900.0);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: dialogMaxHeight),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.category_outlined, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'إضافة سطر تصنيف',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'يُستخدم اسم التصنيف للتسمية فقط ولا يؤثر على حركة التصنيفات.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.75),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _searchController,
                        autofocus: true,
                        focusNode: _searchFocusNode,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'ابحث عن التصنيف',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() {
                          _query = v.trim().toLowerCase();
                        }),
                        onFieldSubmitted: (_) {
                          if (_selected == null) {
                            _selectFirstMatchingCategory(limited);
                          }
                          if (_selected != null) {
                            _focusAndSelect(
                              _weightFocusNode,
                              _weightController,
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      FormField<int>(
                        validator: (_) =>
                            _selected == null ? 'الرجاء اختيار تصنيف' : null,
                        builder: (state) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                height: 240,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: state.hasError
                                        ? colorScheme.error
                                        : theme.dividerColor,
                                  ),
                                ),
                                child: limited.isEmpty
                                    ? const Center(child: Text('لا توجد نتائج'))
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(8),
                                        itemCount: limited.length,
                                        itemBuilder: (_, idx) {
                                          final c = limited[idx];
                                          final id = c['id'];
                                          final selectedId = _selected?['id'];
                                          final isSelected =
                                              (id != null && selectedId != null)
                                              ? id.toString() ==
                                                    selectedId.toString()
                                              : identical(c, _selected);

                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              onTap: () {
                                                setState(() {
                                                  _selected = c;
                                                  final karat =
                                                      _tryParseCategoryKarat(c);
                                                  _karatLockedByCategory =
                                                      karat != null;
                                                  if (karat != null) {
                                                    _selectedKarat = karat;
                                                  }
                                                });
                                                state.didChange(1);
                                              },
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 12,
                                                      vertical: 12,
                                                    ),
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                  color: isSelected
                                                      ? colorScheme.primary
                                                            .withValues(
                                                              alpha: 0.12,
                                                            )
                                                      : colorScheme
                                                            .surfaceContainerHighest
                                                            .withValues(
                                                              alpha: 0.25,
                                                            ),
                                                  border: Border.all(
                                                    color: isSelected
                                                        ? colorScheme.primary
                                                        : Colors.transparent,
                                                    width: 2,
                                                  ),
                                                ),
                                                child: Row(
                                                  children: [
                                                    const Icon(Icons.label),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Text(
                                                        (c['name'] ?? '')
                                                            .toString(),
                                                        style: theme
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  isSelected
                                                                  ? FontWeight
                                                                        .w700
                                                                  : FontWeight
                                                                        .w600,
                                                            ),
                                                      ),
                                                    ),
                                                    if (isSelected)
                                                      const Icon(Icons.check),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                              ),
                              if (state.hasError) ...[
                                const SizedBox(height: 8),
                                Text(
                                  state.errorText ?? '',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: _selectedKarat,
                        decoration: InputDecoration(
                          labelText: 'العيار',
                          border: const OutlineInputBorder(),
                          prefixIcon: _karatLockedByCategory
                              ? Icon(Icons.lock, size: 20, color: theme.colorScheme.primary)
                              : null,
                          filled: _karatLockedByCategory,
                          fillColor: _karatLockedByCategory
                              ? theme.colorScheme.primary.withValues(alpha: 0.07)
                              : null,
                          helperText: _karatLockedByCategory ? 'محدد من التصنيف' : null,
                          helperStyle: TextStyle(color: theme.colorScheme.primary, fontSize: 11),
                        ),
                        items: const [
                          DropdownMenuItem(value: 18, child: Text('18')),
                          DropdownMenuItem(value: 21, child: Text('21')),
                          DropdownMenuItem(value: 22, child: Text('22')),
                          DropdownMenuItem(value: 24, child: Text('24')),
                        ],
                        onChanged: _karatLockedByCategory
                            ? null
                            : (v) {
                          if (v == null) return;
                          setState(() {
                            _selectedKarat = v;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _weightController,
                        focusNode: _weightFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [NormalizeNumberFormatter()],
                        onTap: () => _focusAndSelect(
                          _weightFocusNode,
                          _weightController,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'الوزن',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.scale_outlined),
                        ),
                        validator: (v) {
                          final w = _tryParseDouble(v ?? '');
                          final amount = _tryParseDouble(
                            _amountController.text,
                          );
                          if (w <= 0 && amount <= 0) {
                            return 'أدخل الوزن أو المبلغ';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) => _focusAndSelect(
                          _stonesWeightFocusNode,
                          _stonesWeightController,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _stonesWeightController,
                        focusNode: _stonesWeightFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [NormalizeNumberFormatter()],
                        onTap: () => _focusAndSelect(
                          _stonesWeightFocusNode,
                          _stonesWeightController,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'وزن الأحجار',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.diamond_outlined),
                        ),
                        validator: (v) {
                          final sw = _tryParseDouble(v ?? '');
                          if (sw < 0) {
                            return 'وزن الأحجار لا يمكن أن يكون سالباً';
                          }
                          final w = _tryParseDouble(_weightController.text);
                          if (sw > w && w > 0) {
                            return 'وزن الأحجار أكبر من الوزن';
                          }
                          return null;
                        },
                        onFieldSubmitted: (_) =>
                            _focusAndSelect(_wageFocusNode, _wageController),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _wageController,
                        focusNode: _wageFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [NormalizeNumberFormatter()],
                        onTap: () =>
                            _focusAndSelect(_wageFocusNode, _wageController),
                        decoration: const InputDecoration(
                          labelText: 'المصنعية/جم',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.handyman_outlined),
                        ),
                        validator: (v) {
                          final value = _tryParseDouble(v ?? '');
                          if (value < 0) return 'قيمة غير صحيحة';
                          return null;
                        },
                        onFieldSubmitted: (_) =>
                            _focusAndSelect(_countFocusNode, _countController),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _countController,
                        focusNode: _countFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: false,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [NormalizeNumberFormatter()],
                        onTap: () =>
                            _focusAndSelect(_countFocusNode, _countController),
                        decoration: const InputDecoration(
                          labelText: 'العدد',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.numbers),
                        ),
                        validator: (v) {
                          final count =
                              int.tryParse(normalizeNumber(v ?? '').trim()) ??
                              0;
                          if (count < 1) return 'العدد يجب أن يكون 1 أو أكثر';
                          return null;
                        },
                        onFieldSubmitted: (_) => _focusAndSelect(
                          _amountFocusNode,
                          _amountController,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _amountController,
                        focusNode: _amountFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        inputFormatters: [NormalizeNumberFormatter()],
                        onTap: () => _focusAndSelect(
                          _amountFocusNode,
                          _amountController,
                        ),
                        decoration: InputDecoration(
                          labelText: 'المبلغ (اختياري)',
                          suffixText: widget.currencySymbol,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.payments_outlined),
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) return null;
                          final amount = _tryParseDouble(v ?? '');
                          if (amount <= 0) return 'أدخل مبلغ صحيح';
                          return null;
                        },
                        onFieldSubmitted: (_) => _submit(),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(18),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('إلغاء'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.check),
                      label: const Text('إضافة'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== Invoice Item Model ====================
class InvoiceItem {
  final int? itemId;
  final String name;
  final String barcode;
  double karat;
  double standingWeight; // الوزن القائم (يدخل يدوياً)
  double stonesWeight; // وزن الأحجار (يدخل يدوياً)
  int quantity; // العدد (يدخل يدوياً)
  double weight;
  double wage; // أجور المصنعية للجرام الواحد
  final double goldPrice24k; // سعر الشراء لعيار 24 بعد أي خصم مطبق
  final int mainKarat;
  final bool isCategoryLine;

  // الربح الموزع (يتم حسابه في _distributeAmount)
  double profit = 0.0;

  // علامة لتتبع إذا تم تحديد الإجمالي يدوياً
  bool _hasManualTotal = false;
  double? _targetTotal;

  InvoiceItem({
    required this.itemId,
    required this.name,
    required this.barcode,
    required this.karat,
    required this.standingWeight,
    required this.stonesWeight,
    required this.quantity,
    required this.weight,
    required this.wage,
    required this.goldPrice24k,
    required this.mainKarat,
    this.isCategoryLine = false,
  });

  // حساب سعر الجرام الخام (سعر الذهب فقط حسب العيار)
  double calculatePricePerGram() {
    return goldPrice24k * (karat / 24.0);
  }

  // تكلفة الشراء/جرام = سعر شراء الجرام المباشر للعيار (بدون مصنعية)
  double calculateDirectPurchaseCostPerGram() {
    return calculatePricePerGram();
  }

  // سعر الشراء/جرام = الإجمالي / الوزن القائم
  double calculatePurchasePricePerGram() {
    if (standingWeight <= 0) return 0;
    return totalWithTax / standingWeight;
  }

  // الوزن الديناميكي = الوزن القائم - وزن الأحجار
  void applyTargetTotalCalculations(double targetTotal) {
    // NOTE: In scrap purchase, weight is derived from (standing - stones).
    // Manual totals should NOT mutate weight; instead, adjust the per-line profit
    // so that net matches the target.
    final resolvedCost = cost;
    profit = targetTotal - resolvedCost;
  }

  // تحديث الوزن الديناميكي (صافي الذهب) = القائم - الأحجار
  void updateWeightFromStandingAndStones() {
    final net = standingWeight - stonesWeight;
    weight = net < 0 ? 0.0 : net;
  }

  // التكلفة = الوزن × تكلفة الشراء/جرام
  double get cost {
    return weight * calculateDirectPurchaseCostPerGram();
  }

  // الصافي = التكلفة + الربح الموزع
  double get net {
    if (_hasManualTotal && _targetTotal != null) {
      // إذا تم تحديد إجمالي يدوي، استخدمه مباشرة (لا توجد ضريبة على شراء الكسر)
      return _targetTotal!;
    }
    return cost + profit;
  }

  // الإجمالي (نفس الصافي لأنه لا توجد ضريبة على شراء الكسر)
  double get totalWithTax {
    return net;
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
    applyTargetTotalCalculations(total);
  }

  // مسح الإجمالي اليدوي عند تعديل الحقول
  void clearManualTotal() {
    _hasManualTotal = false;
    _targetTotal = null;
  }

  Map<String, dynamic> toJson() {
    return {
      'item_id': isCategoryLine ? null : itemId,
      'name': name,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'standing_weight': standingWeight,
      'stones_weight': stonesWeight,
      // سعر الشراء المباشر/جرام للعيار (ليس سعر البيع)
      'direct_purchase_price_per_gram': calculateDirectPurchaseCostPerGram(),
      'cost': cost,
      'profit': profit,
      'net': net,
      'tax': 0.0, // لا توجد ضريبة على شراء الكسر
      'price': totalWithTax, // الـ backend يتوقع 'price' بدلاً من 'total'
      'quantity': quantity,
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
