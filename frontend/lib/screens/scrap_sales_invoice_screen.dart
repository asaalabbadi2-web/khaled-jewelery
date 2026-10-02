import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../providers/settings_provider.dart';
import '../widgets/invoice_settings_sheet.dart';
import '../widgets/adaptive_invoice_summary_dialog.dart';
import '../utils/invoice_direct_print.dart';
import '../utils/arabic_number_formatter.dart';
import '../utils.dart';
import '../providers/auth_provider.dart';
import 'settings_screen_enhanced.dart';

enum _PreSaveDecision { cancel, proceed, proceedSuppressWarning }

/// شاشة فاتورة بيع الكسر - النسخة الهجينة المحسّنة
/// تجمع بين Smart Input (Progressive) و DataTable (Professional)
class ScrapSalesInvoiceScreen extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> customers;

  /// Edit mode: an unposted scrap sale. It opened in the ordinary sale screen,
  /// which sends no gold_type, and sale #1540 came back a sale of new gold (the
  /// owner, 2 Oct 2026). The server keeps its number, its date and its kind;
  /// this screen corrects the lines and the payments.
  final int? editInvoiceId;
  final Map<String, dynamic>? editInvoiceData;

  const ScrapSalesInvoiceScreen({
    super.key,
    required this.items,
    required this.customers,
    this.editInvoiceId,
    this.editInvoiceData,
  });

  @override
  State<ScrapSalesInvoiceScreen> createState() =>
      _ScrapSalesInvoiceScreenState();
}

class _ScrapSalesInvoiceScreenState extends State<ScrapSalesInvoiceScreen> {
  // ==================== State Variables ====================
  final _smartInputController = TextEditingController();
  final _smartInputFocus = FocusNode();
  final _customAmountController = TextEditingController(); // 🆕 للمبلغ المخصص

  bool _uiLockPriceEdits = false;
  bool _uiDisableVat = false;
  bool _uiAutoOpenPrintAfterSave = false;
  String _uiPaperSize = 'A4';

  double get _effectiveVatRate =>
      _uiDisableVat ? 0.0 : _settingsProvider.taxRate;

  double _effectiveTaxRateForKarat(double karat) {
    if (_uiDisableVat) return 0.0;
    return _settingsProvider.taxRateForKarat(karat);
  }

  // Branches (فروع المعرض/المحل)
  List<Map<String, dynamic>> _branches = [];
  bool _isLoadingBranches = false;
  String? _branchesLoadingError;
  int? _selectedBranchId;

  // Customer
  int? _selectedCustomerId;

  // Items List
  final List<InvoiceItem> _items = [];

  // Categories (for category-line dialog)
  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingCategories = false;
  String? _categoriesLoadingError;

  // Gold Price & Settings
  double _goldPrice24k = 0.0;
  late SettingsProvider _settingsProvider;

  // Payment - 🆕 وسائل دفع متعددة
  List<Map<String, dynamic>> _paymentMethods = [];
  final List<PaymentEntry> _payments = []; // 🆕 قائمة الدفعات المضافة
  int? _selectedPaymentMethodId; // للـ Dropdown

  // 🆕 الخزائن
  int? _selectedSafeBoxId;

  void _resetAfterSave() {
    setState(() {
      _selectedCustomerId = null;
      _items.clear();
      _payments.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _smartInputController.clear();
    });
    _smartInputFocus.requestFocus();
  }

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _loadInvoiceUiSettingsFromPrefs();
    _loadSettings();
    _loadBranches();
    _loadPaymentMethods(); // 🆕 جلب وسائل الدفع
    _loadDefaultSafeBox(); // 🆕 تحميل الخزينة
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
        final karat = num0(m['karat']);
        final item = InvoiceItem(
          id: int0(m['item_id']),
          name: (m['name'] ?? '').toString(),
          barcode: '',
          karat: karat,
          weight: num0(m['weight']),
          wage: num0(m['wage']),
          count: int0(m['quantity']) ?? 1,
          goldPrice24k: _goldPrice24k,
          mainKarat: _settingsProvider.mainKarat,
          taxRate: _uiDisableVat ? 0.0 : _settingsProvider.taxRateForKarat(karat),
        );
        // The line's total as it was saved: net + tax, or its price.
        final saved = num0(m['net']) > 0 ? num0(m['net']) + num0(m['tax']) : num0(m['price']);
        if (saved > 0) item.setManualTotal(saved);
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

  Future<void> _loadInvoiceUiSettingsFromPrefs() async {
    try {
      final loaded = await InvoiceUiSettings.load(InvoiceUiContext.scrapSale);
      if (!mounted) return;
      setState(() {
        _uiLockPriceEdits = loaded.lockPriceEdits;
        _uiDisableVat = loaded.disableVat;
        _uiAutoOpenPrintAfterSave = loaded.autoOpenPrintAfterSave;
        _uiPaperSize = loaded.paperSize;
      });
    } catch (_) {
      // ignore
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settingsProvider = Provider.of<SettingsProvider>(context);

    // Ensure VAT override is applied once settings are available.
    if (_uiDisableVat && mounted && _items.isNotEmpty) {
      for (final item in _items) {
        item.taxRate = 0.0;
      }
    }
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

  Future<void> _loadBranches() async {
    if (_isLoadingBranches) return;
    setState(() {
      _isLoadingBranches = true;
      _branchesLoadingError = null;
    });

    try {
      final apiService = ApiService();
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
    // بيع الكسر يخرج دائماً من خزينة الكسر الرئيسية (main_scrap_gold_safe_box_id).
    // نجلب الإعداد من الـ API ثم نضبط الخزينة تلقائياً.
    try {
      final apiService = ApiService();
      final settings = await apiService.getSettings();
      final rawId = settings['main_scrap_gold_safe_box_id'];
      final scrapSafeId = rawId is int
          ? rawId
          : int.tryParse(rawId?.toString() ?? '');

      if (scrapSafeId != null) {
        final safeBox = await apiService.getSafeBox(
          scrapSafeId,
          includeBalance: false,
        );
        if (!mounted) return;
        setState(() {
          _selectedSafeBoxId = safeBox.id;
        });
        return;
      }
    } catch (_) {
      // تراجع للخزينة الذهبية الافتراضية إن لم تُضبط الخزينة الرئيسية للكسر.
    }

    try {
      final apiService = ApiService();
      final goldSafe = await apiService.getDefaultSafeBox('gold');
      if (!mounted) return;
      setState(() {
        _selectedSafeBoxId = goldSafe.id;
      });
    } catch (_) {
      // لا خزينة ذهب متاحة — الباكيند يعالجها عبر إعدادات النظام.
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
        'المبلغ أكبر من المتبقي (${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText})',
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
      (commission * _effectiveVatRate).toStringAsFixed(2),
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
    // تجاهل الفروقات الصغيرة (أقل من 0.01 $_currencySymbol)
    return remaining.abs() < 0.01 ? 0.0 : remaining;
  }

  // ملاحظة: _isFullyPaid غير مستخدم حالياً - يمكن حذفه لاحقاً
  // bool get _isFullyPaid {
  //   final remaining = (_calculateGrandTotal() - _totalPayments).abs();
  //   return remaining < 0.01;  // tolerance = 1 قرش
  // }

  // ==================== Smart Input Processing ====================
  Map<String, dynamic>? _findItemBySmartInput(String input) {
    final normalizedInput = input.toLowerCase();
    final strategies = <bool Function(Map<String, dynamic>)>[
      (item) {
        final barcode = item['barcode']?.toString().toLowerCase();
        return barcode != null && barcode == normalizedInput;
      },
      (item) {
        final code = item['item_code']?.toString().toLowerCase();
        return code != null && code == normalizedInput;
      },
      (item) {
        final name = item['name']?.toString().toLowerCase();
        return name?.contains(normalizedInput) ?? false;
      },
    ];

    for (final matches in strategies) {
      for (final item in widget.items) {
        if (matches(item)) return item;
      }
    }
    return null;
  }

  Future<void> _processSmartInput(String input) async {
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty) return;

    try {
      final foundItem = _findItemBySmartInput(normalizedInput);

      if (foundItem != null && foundItem.isNotEmpty) {
        await _addItemFromData(foundItem);
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
        _showError('⚠️ لم يتم العثور على الصنف');
      }
    } catch (e) {
      _showError('خطأ في البحث: $e');
    }
  }

  Future<void> _addItemFromData(Map<String, dynamic> itemData) async {
    // تحديث سعر الذهب قبل إضافة الصنف
    try {
      final apiService = ApiService();
      final priceData = await apiService.getGoldPrice();
      final newPrice = _parseDouble(priceData['price_24k']);
      if (newPrice > 0 && mounted) {
        setState(() => _goldPrice24k = newPrice);
      }
    } catch (_) {
      // الاستمرار باستخدام السعر الحالي
    }

    double karat = _parseDouble(itemData['karat']);
    if (karat <= 0) karat = 21.0;
    double wage = _parseDouble(itemData['wage']);
    double weight = _parseDouble(itemData['weight']);
    if (weight <= 0) weight = 10.0;
    final count = (itemData['count'] is int)
        ? itemData['count'] as int
        : int.tryParse('${itemData['count'] ?? '1'}') ?? 1;

    setState(() {
      _items.add(
        InvoiceItem(
          id: itemData['id'] as int?,
          name: itemData['name'] ?? '',
          barcode: itemData['barcode'] ?? '',
          karat: karat,
          weight: weight,
          wage: wage,
          count: count,
          goldPrice24k: _goldPrice24k,
          mainKarat: _settingsProvider.mainKarat,
          taxRate: _effectiveTaxRateForKarat(karat),
        ),
      );
    });
  }

  // ==================== Categories Loading ====================
  Future<void> _ensureCategoriesLoaded() async {
    if (_isLoadingCategories || _categories.isNotEmpty) return;
    setState(() {
      _isLoadingCategories = true;
      _categoriesLoadingError = null;
    });
    try {
      final api = ApiService();
      final raw = await api.getCategories();
      final parsed = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      parsed.sort(
        (a, b) => ('${a['name'] ?? ''}').compareTo('${b['name'] ?? ''}'),
      );
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
        _categoriesLoadingError = e.toString();
      });
    }
  }

  // ==================== Manual Item Dialog ====================
  Future<void> _showManualItemDialog() async {
    if (!_settingsProvider.allowManualInvoiceItems) {
      _showError(
        'هذه الميزة معطلة من الإعدادات. فعّل خيار "السماح بإضافة صنف يدوي" أولاً.',
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final barcodeController = TextEditingController();
    final countController = TextEditingController(text: '1');
    final weightController = TextEditingController(text: '1.0');
    final wageController = TextEditingController(text: '0');
    final totalController = TextEditingController();
    final barcodeFocusNode = FocusNode();
    final countFocusNode = FocusNode();
    final weightFocusNode = FocusNode();
    final wageFocusNode = FocusNode();
    final totalFocusNode = FocusNode();

    int selectedKarat = _settingsProvider.mainKarat;

    double? tryParseOptionalDouble(String value) {
      final normalized = value.trim().replaceAll(',', '.');
      if (normalized.isEmpty) return null;
      return double.tryParse(normalized);
    }

    void focusAndSelect(FocusNode focusNode, TextEditingController controller) {
      focusNode.requestFocus();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    }

    if (!mounted) {
      nameController.dispose();
      barcodeController.dispose();
      weightController.dispose();
      wageController.dispose();
      totalController.dispose();
      return;
    }

    final manualData = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              if (!(formKey.currentState?.validate() ?? false)) return;
              final weight = tryParseOptionalDouble(weightController.text) ?? 0;
              final wage = tryParseOptionalDouble(wageController.text) ?? 0;
              final count = int.tryParse(countController.text) ?? 1;
              final manualTotal = tryParseOptionalDouble(totalController.text);
              Navigator.pop(dialogContext, {
                'name': nameController.text.trim(),
                'barcode': barcodeController.text.trim(),
                'count': count,
                'karat': selectedKarat.toDouble(),
                'weight': weight,
                'wage': wage,
                'total_with_tax': manualTotal,
              });
            }

            return AlertDialog(
              title: const Text('إضافة صنف يدوي'),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: nameController,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            focusAndSelect(barcodeFocusNode, barcodeController),
                        decoration: const InputDecoration(
                          labelText: 'اسم الصنف',
                          prefixIcon: Icon(Icons.label_outline),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'يرجى إدخال اسم الصنف';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: barcodeController,
                        focusNode: barcodeFocusNode,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            focusAndSelect(countFocusNode, countController),
                        decoration: const InputDecoration(
                          labelText: 'الباركود / رقم الصنف (اختياري)',
                          prefixIcon: Icon(Icons.qr_code_2),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: countController,
                        focusNode: countFocusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            focusAndSelect(weightFocusNode, weightController),
                        onTap: () => countController.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: countController.text.length,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'العدد (الكمية)',
                          prefixIcon: Icon(Icons.numbers),
                        ),
                        validator: (value) {
                          final count = int.tryParse(value ?? '');
                          if (count == null || count < 1) {
                            return 'أدخل عدداً صحيحاً أكبر من صفر';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: selectedKarat,
                        decoration: const InputDecoration(
                          labelText: 'العيار',
                          prefixIcon: Icon(Icons.diamond_outlined),
                        ),
                        items: const [18, 21, 22, 24]
                            .map(
                              (karat) => DropdownMenuItem<int>(
                                value: karat,
                                child: Text('عيار $karat'),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() => selectedKarat = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: weightController,
                        focusNode: weightFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            focusAndSelect(wageFocusNode, wageController),
                        onTap: () => weightController.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: weightController.text.length,
                        ),
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'الوزن بالجرام',
                          prefixIcon: Icon(Icons.scale),
                        ),
                        validator: (value) {
                          final parsed = double.tryParse(
                            (value ?? '').trim().replaceAll(',', '.'),
                          );
                          if (parsed == null || parsed <= 0) {
                            return 'أدخل وزناً صحيحاً أكبر من صفر';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: wageController,
                        focusNode: wageFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        onFieldSubmitted: (_) =>
                            focusAndSelect(totalFocusNode, totalController),
                        onTap: () => wageController.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: wageController.text.length,
                        ),
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'أجرة المصنعية للجرام (اختياري)',
                          prefixIcon: Icon(Icons.handyman_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: totalController,
                        focusNode: totalFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => submit(),
                        onTap: () => totalController.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: totalController.text.length,
                        ),
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        decoration: InputDecoration(
                          labelText: 'الإجمالي مع الضريبة (اختياري)',
                          prefixIcon: const Icon(Icons.attach_money),
                          helperText:
                              'اترك الحقل فارغاً ليتم احتساب السعر تلقائياً',
                          suffixText: _settingsProvider.currencySymbolText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('إضافة'),
                  onPressed: submit,
                ),
              ],
            );
          },
        );
      },
    );

    barcodeFocusNode.dispose();
    countFocusNode.dispose();
    weightFocusNode.dispose();
    wageFocusNode.dispose();
    totalFocusNode.dispose();

    if (manualData == null) return;

    final manualItem = InvoiceItem(
      id: null,
      name: manualData['name'] as String? ?? 'صنف يدوي',
      barcode: manualData['barcode'] as String? ?? '',
      karat: _parseDouble(manualData['karat']),
      weight: _parseDouble(manualData['weight']),
      wage: _parseDouble(manualData['wage']),
      count: manualData['count'] as int? ?? 1,
      goldPrice24k: _goldPrice24k,
      mainKarat: _settingsProvider.mainKarat,
      taxRate: _uiDisableVat
          ? 0.0
          : _settingsProvider.taxRateForKarat(
              _parseDouble(manualData['karat']),
            ),
    );

    final manualTotal = manualData['total_with_tax'];
    if (manualTotal is num && manualTotal > 0) {
      manualItem.setManualTotal(manualTotal.toDouble());
    }

    setState(() {
      _items.add(manualItem);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تمت إضافة صنف يدوي إلى الفاتورة'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  // ==================== Category Line Dialog ====================
  Future<void> _showCategoryLineDialog() async {
    await _ensureCategoriesLoaded();
    if (!mounted) return;

    if (_categories.isEmpty) {
      _showError(
        _categoriesLoadingError ??
            'لا توجد تصنيفات. أنشئ تصنيفاً أولاً من شاشة الأصناف.',
      );
      return;
    }

    final result = await showDialog<_ScrapSaleCategoryLineResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CategoryLineDialog(
        categories: _categories,
        mainKarat: _settingsProvider.mainKarat,
        currencySymbol: _settingsProvider.currencySymbolText,
      ),
    );

    if (result == null || !mounted) return;

    setState(() {
      final item = InvoiceItem(
        id: null,
        name: result.categoryName.isNotEmpty ? result.categoryName : 'تصنيف',
        barcode: '',
        karat: result.karat,
        weight: result.weight,
        wage: result.wage,
        count: result.count,
        goldPrice24k: _goldPrice24k,
        mainKarat: _settingsProvider.mainKarat,
        taxRate: _uiDisableVat
            ? 0.0
            : _settingsProvider.taxRateForKarat(result.karat),
      );
      if (result.amount > 0) item.setManualTotal(result.amount);
      _items.add(item);
    });
  }

  // ==================== Manual Item Feature Guide ====================
  Future<void> _showManualItemFeatureGuide() async {
    if (!mounted) return;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final shouldOpenSettings =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.info_outline, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'تفعيل الصنف اليدوي',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'لإضافة صنف يدوي يجب تفعيل الخيار من شاشة الإعدادات > الشركة والفواتير.',
                  ),
                  SizedBox(height: 8),
                  Text(
                    'بعد التفعيل سيظهر زر "صنف يدوي" دائماً داخل شاشة الفاتورة.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('لاحقاً'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.settings),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  label: const Text('فتح الإعدادات'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldOpenSettings || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SettingsScreenEnhanced(initialTabIndex: 1),
      ),
    );
  }

  // ==================== Item Actions ====================
  void _updateItem(int index, String field, double value) {
    setState(() {
      final item = _items[index];

      switch (field) {
        case 'karat':
          item.karat = value;
          item.taxRate = _effectiveTaxRateForKarat(value);
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
    final targetNet = _effectiveVatRate <= 0
        ? targetTotal
        : targetTotal / (1 + _effectiveVatRate); // إزالة الضريبة

    // حساب التكلفة الحالية
    final currentCost = item.cost;

    // حساب الربح المطلوب
    final requiredProfit = targetNet - currentCost;

    // تحديث الربح
    item.profit = requiredProfit;

    debugPrint(
      '🔄 إعادة حساب للوصول للإجمالي ${targetTotal.toStringAsFixed(2)}:',
    );
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
      builder: (dialogContext) => AlertDialog(
        title: const Text('توزيع تلقائي للمبلغ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _settingsProvider.buildText(
              'الإجمالي الحالي: ${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [NormalizeNumberFormatter()],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final target = double.tryParse(controller.text);
                if (target != null && target > 0) {
                  _distributeAmount(target);
                  Navigator.pop(dialogContext);
                }
              },
              decoration: InputDecoration(
                labelText: 'المبلغ المستهدف',
                suffixText: _settingsProvider.currencySymbolText,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final target = double.tryParse(controller.text);
              if (target != null && target > 0) {
                _distributeAmount(target);
                Navigator.pop(dialogContext);
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
    final amountWithoutTax = _effectiveVatRate <= 0
        ? targetTotal
        : targetTotal / (1 + _effectiveVatRate);

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
        content: _settingsProvider.buildText(
          '✅ تم توزيع $targetTotal ${_settingsProvider.currencySymbolText} على ${_items.length} صنف\n'
          'التكاليف: ${totalCosts.toStringAsFixed(2)} • الربح الموزع: ${profitPool.toStringAsFixed(2)}',
        ),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<_PreSaveDecision> _confirmDeferredInvoiceSave({
    required double total,
    required double totalPaid,
    required double remaining,
    required double totalCost,
    required bool paidBelowCost,
    required bool saleBelowCost,
  }) async {
    final lines = <String>[
      'إجمالي الفاتورة: ${total.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
      'المدفوع: ${totalPaid.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
      'المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
    ];

    if (totalCost > 0 && (paidBelowCost || saleBelowCost)) {
      lines.add('');
      lines.add('⚠️ تحذير:');
      if (saleBelowCost) {
        lines.add(
          'سعر البيع أقل من تكلفة الأصناف (التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText})',
        );
      } else if (paidBelowCost) {
        lines.add(
          'المدفوع أقل من تكلفة الأصناف (التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText})',
        );
      }
    }

    lines.add('');
    lines.add('هل تريد حفظ الفاتورة بهذا الشكل؟');

    final result = await showDialog<_PreSaveDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('فاتورة آجل / دفع جزئي'),
          content: Text(lines.join('\n')),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PreSaveDecision.cancel),
              child: const Text('إلغاء'),
            ),
            if (paidBelowCost || saleBelowCost)
              TextButton(
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(_PreSaveDecision.proceedSuppressWarning),
                child: const Text('حفظ بدون تحذير'),
              ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PreSaveDecision.proceed),
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );

    return result ?? _PreSaveDecision.cancel;
  }

  Future<_PreSaveDecision> _confirmBelowCostInvoiceSave({
    required double total,
    required double totalPaid,
    required double totalCost,
    required bool paidBelowCost,
    required bool saleBelowCost,
  }) async {
    final lines = <String>[
      'إجمالي الفاتورة: ${total.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
      'المدفوع: ${totalPaid.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
      'التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
      '',
      '⚠️ تحذير قبل الحفظ:',
      if (saleBelowCost) 'سعر البيع أقل من تكلفة الأصناف.',
      if (!saleBelowCost && paidBelowCost) 'المدفوع أقل من تكلفة الأصناف.',
      '',
      'يمكنك المتابعة، وسيتم حفظ الفاتورة لكن قد تحتاج اعتماد مدير قبل الترحيل.',
    ];

    final result = await showDialog<_PreSaveDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('تحذير قبل الحفظ'),
          content: Text(lines.join('\n')),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PreSaveDecision.cancel),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_PreSaveDecision.proceedSuppressWarning),
              child: const Text('حفظ بدون تحذير'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_PreSaveDecision.proceed),
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );

    return result ?? _PreSaveDecision.cancel;
  }

  // ==================== Submit Invoice ====================
  Future<String?> _showPostSaveInvoiceSummary({
    required Map<String, dynamic> invoice,
    required bool approvalRequired,
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
    final totalTax = asDouble(invoice['total_tax']);
    final invoiceId = invoice['id']?.toString() ?? '';

    final customerName = (invoice['customer_name'] ?? invoice['customer'] ?? '')
        .toString()
        .trim();
    final weightBreakdown = _buildWeightBreakdownLines(
      invoice['items'] is List
          ? List<dynamic>.from(invoice['items'])
          : const [],
    );

    final currency = _settingsProvider.currencySymbolText;
    final notices = <String>[
      if ((approvalWarning ?? '').trim().isNotEmpty) approvalWarning!,
    ];

    return await showAdaptiveInvoiceSummaryDialog<String>(
      context: context,
      title: 'تم حفظ الفاتورة',
      subtitle: approvalRequired
          ? 'تم الحفظ لكن الفاتورة تحتاج اعتماد مدير قبل الترحيل.'
          : 'يمكنك المتابعة بالطباعة أو المشاركة أو الإغلاق.',
      icon: approvalRequired
          ? Icons.pending_actions_rounded
          : Icons.check_circle,
      accentColor: approvalRequired ? AppColors.warning : AppColors.success,
      highlightMessage: approvalRequired
          ? 'تم حفظ الفاتورة وتنتظر الاعتماد'
          : 'تم حفظ الفاتورة بنجاح',
      statusTitle: 'حالة السداد',
      statusMessage: remaining > 0.01
          ? 'متبقي ${remaining.toStringAsFixed(2)} $currency'
          : 'تم الدفع بالكامل',
      statusTone: remaining > 0.01
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
        ),
        InvoiceSummaryMetric(
          label: 'المدفوع',
          value: '${paid.toStringAsFixed(2)} $currency',
          icon: Icons.account_balance_wallet_outlined,
          accentColor: AppColors.success,
          emphasize: true,
        ),
        InvoiceSummaryMetric(
          label: 'المتبقي',
          value: '${remaining.toStringAsFixed(2)} $currency',
          icon: Icons.pending_outlined,
          accentColor: remaining > 0.01 ? AppColors.error : AppColors.success,
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
        if (totalTax > 0)
          InvoiceSummaryMetric(
            label: 'الضريبة',
            value: '${totalTax.toStringAsFixed(2)} $currency',
            icon: Icons.receipt_long_outlined,
            accentColor: AppColors.warning,
          ),
      ],
      notices: notices,
      closeValue: null,
      actions: const [
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
    );
  }

  Future<bool> _showPreSaveInvoiceSummary({
    required String customerLabel,
    required int itemsCount,
    required double total,
    required double totalWeight,
    required double totalTax,
    required double totalCost,
    required double paidCash,
    required double remaining,
    required bool allowPartialPayments,
  }) async {
    final warnings = <String>[];
    if (!allowPartialPayments && remaining.abs() > 0.01) {
      warnings.add('هذا الإعداد يتطلب سداد كامل الفاتورة قبل الحفظ.');
    }
    if (remaining > 0.01) {
      warnings.add('الفاتورة آجل/جزئي: يوجد مبلغ متبقي قبل الإغلاق.');
    }
    if (totalCost > 0 && total + 0.01 < totalCost) {
      warnings.add(
        'سعر البيع أقل من التكلفة وقد تحتاج الفاتورة إلى اعتماد مدير.',
      );
    }
    if (totalWeight > 0 && _goldPrice24k > 0 && total > 0) {
      final pricePerGram = total / totalWeight;
      final cur = _settingsProvider.currencySymbolText;
      if (pricePerGram > _goldPrice24k * 2) {
        warnings.add(
          '⚠️ سعر الجرام المحسوب ${pricePerGram.toStringAsFixed(0)} $cur أعلى بكثير من سعر السوق'
          ' (${_goldPrice24k.toStringAsFixed(0)} $cur/جم). تأكد من صحة المبلغ والوزن.',
        );
      } else if (pricePerGram < _goldPrice24k * 0.15) {
        warnings.add(
          '⚠️ سعر الجرام المحسوب ${pricePerGram.toStringAsFixed(0)} $cur أقل بكثير من سعر السوق'
          ' (${_goldPrice24k.toStringAsFixed(0)} $cur/جم). تأكد من صحة المبلغ والوزن.',
        );
      }
    }

    final currency = _settingsProvider.currencySymbolText;
    final weightBreakdown = _buildWeightBreakdownLines(
      _items.map((item) => item.toJson()),
    );
    return await showAdaptiveInvoiceSummaryDialog<bool>(
          context: context,
          title: 'مراجعة الفاتورة',
          subtitle: 'راجع البيانات الأساسية سريعاً قبل تنفيذ الحفظ.',
          icon: Icons.receipt_long_rounded,
          accentColor: AppColors.primaryGold,
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
            if (totalTax > 0)
              InvoiceSummaryMetric(
                label: 'الضريبة',
                value: '${totalTax.toStringAsFixed(2)} $currency',
                icon: Icons.receipt_long_outlined,
                accentColor: AppColors.warning,
              ),
            InvoiceSummaryMetric(
              label: 'المدفوع',
              value: '${paidCash.toStringAsFixed(2)} $currency',
              icon: Icons.account_balance_wallet_outlined,
              accentColor: AppColors.success,
              emphasize: true,
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
          notices: warnings,
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

  Future<void> _submitInvoice() async {
    if (_items.isEmpty) {
      _showError('يرجى إضافة أصناف للفاتورة');
      return;
    }

    if (_selectedBranchId == null) {
      _showError('يرجى اختيار الفرع لإكمال الفاتورة.');
      return;
    }

    final allowPartialPayments = _settingsProvider.allowPartialInvoicePayments;

    // 🧾 التحقق من الدفع (مع دعم الفواتير الآجلة عند تفعيل الإعداد)
    final total = _calculateGrandTotal();
    final totalPaid = _totalPayments;
    final remaining = total - totalPaid;

    final totalCost = _items.fold<double>(0.0, (sum, item) => sum + item.cost);
    final paidBelowCost = totalPaid + 0.01 < totalCost;
    final saleBelowCost = total + 0.01 < totalCost;

    var suppressPostSaveApprovalWarning = false;
    var shownDeferredDialog = false;

    if (_payments.isEmpty) {
      if (!allowPartialPayments) {
        _showError('يرجى إضافة وسيلة دفع واحدة على الأقل');
        return;
      }

      final proceed = await _confirmDeferredInvoiceSave(
        total: total,
        totalPaid: totalPaid,
        remaining: total,
        totalCost: totalCost,
        paidBelowCost: paidBelowCost,
        saleBelowCost: saleBelowCost,
      );
      shownDeferredDialog = true;
      if (proceed == _PreSaveDecision.cancel) return;
      suppressPostSaveApprovalWarning =
          proceed == _PreSaveDecision.proceedSuppressWarning;
    } else {
      // منع الدفع الزائد
      if (remaining < -0.01) {
        _showError('مجموع الدفعات أكبر من إجمالي الفاتورة');
        return;
      }

      if (remaining > 0.01) {
        if (!allowPartialPayments) {
          _showError(
            'المبلغ المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}\nيرجى إكمال الدفع',
          );
          return;
        }

        final proceed = await _confirmDeferredInvoiceSave(
          total: total,
          totalPaid: totalPaid,
          remaining: remaining,
          totalCost: totalCost,
          paidBelowCost: paidBelowCost,
          saleBelowCost: saleBelowCost,
        );
        shownDeferredDialog = true;
        if (proceed == _PreSaveDecision.cancel) return;
        suppressPostSaveApprovalWarning =
            proceed == _PreSaveDecision.proceedSuppressWarning;
      }
    }

    if (!shownDeferredDialog &&
        totalCost > 0 &&
        (paidBelowCost || saleBelowCost)) {
      final decision = await _confirmBelowCostInvoiceSave(
        total: total,
        totalPaid: totalPaid,
        totalCost: totalCost,
        paidBelowCost: paidBelowCost,
        saleBelowCost: saleBelowCost,
      );
      if (decision == _PreSaveDecision.cancel) return;
      suppressPostSaveApprovalWarning =
          decision == _PreSaveDecision.proceedSuppressWarning;
    }

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

    final totalWeightForSummary = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );
    final totalTaxForSummary = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.tax,
    );

    final proceed = await _showPreSaveInvoiceSummary(
      customerLabel: customerLabel,
      itemsCount: _items.length,
      total: total,
      totalWeight: totalWeightForSummary,
      totalTax: totalTaxForSummary,
      totalCost: totalCost,
      paidCash: totalPaid,
      remaining: remaining,
      allowPartialPayments: allowPartialPayments,
    );
    if (!proceed) return;

    try {
      final apiService = ApiService();

      int? customerId = _selectedCustomerId;
      if (customerId != null && customerId <= 0) {
        customerId = null;
      }

      final cashCustomer = _findCashCustomer();
      if (customerId == null && cashCustomer != null) {
        final resolvedCashId = _parseInt(cashCustomer['id']);
        if (resolvedCashId != null && resolvedCashId > 0) {
          customerId = resolvedCashId;
          if (mounted) {
            setState(() {
              _selectedCustomerId = customerId;
            });
          }
          debugPrint(
            '💵 لم يتم اختيار عميل - تم استخدام عميل نقدي تلقائياً (ID: $customerId)',
          );
        }
      }

      if (customerId != null && customerId <= 0) {
        _showError('تعذر تحديد عميل صالح للفاتورة');
        return;
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
        'branch_id': _selectedBranchId,
        'invoice_type': 'بيع',
        'transaction_type': 'sell',
        'gold_type': 'scrap',
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
      if (approvalRequired && !suppressPostSaveApprovalWarning) {
        final parts = <String>[];
        if (approvalReasons.contains('below_cost') && response['below_cost'] is! Map) {
          // Without costing.view the server says "under cost", not the cost (ADR-036).
          parts.add('⚠️ بيع تحت التكلفة — يحتاج اعتماد المدير');
        } else if (approvalReasons.contains('below_cost')) {
          final below = (response['below_cost'] is Map)
              ? Map<String, dynamic>.from(response['below_cost'])
              : const <String, dynamic>{};
          final saleExVat = (below['effective_sale_cash_ex_vat'] is num)
              ? (below['effective_sale_cash_ex_vat'] as num).toDouble()
              : double.tryParse(
                      '${below['effective_sale_cash_ex_vat'] ?? 0}',
                    ) ??
                    0.0;
          final costCash = (below['cost_cash'] is num)
              ? (below['cost_cash'] as num).toDouble()
              : double.tryParse('${below['cost_cash'] ?? 0}') ?? 0.0;
          final profitEst = (below['profit_cash_estimate'] is num)
              ? (below['profit_cash_estimate'] as num).toDouble()
              : double.tryParse('${below['profit_cash_estimate'] ?? 0}') ?? 0.0;
          parts.add(
            '⚠️ بيع تحت التكلفة: صافي ${saleExVat.toStringAsFixed(2)} مقابل تكلفة ${costCash.toStringAsFixed(2)} (فرق ${profitEst.toStringAsFixed(2)})',
          );
        }
        if (approvalReasons.contains('large_discount')) {
          final discountPct = (response['discount_pct'] is num)
              ? (response['discount_pct'] as num).toDouble()
              : double.tryParse('${response['discount_pct'] ?? 0}') ?? 0.0;
          final thresholdPct = (response['threshold_pct'] is num)
              ? (response['threshold_pct'] as num).toDouble()
              : double.tryParse('${response['threshold_pct'] ?? 0}') ?? 0.0;
          parts.add(
            '⚠️ خصم كبير: ${discountPct.toStringAsFixed(2)}% (الحد ${thresholdPct.toStringAsFixed(2)}%)',
          );
        }

        approvalWarning = parts.isNotEmpty
            ? '${parts.join('\n')}\nسيتم حفظ الفاتورة لكن لن تُرحَّل حتى اعتماد المدير.'
            : '⚠️ تم حفظ الفاتورة لكن تحتاج اعتماد مدير قبل الترحيل.';

        if (context.mounted) {
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

      // Edit mode: back to the invoices list, which reloads on `true`.
      if (_isEditMode) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم حفظ التعديل — بيع كسر برقمه وتاريخه')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      if (context.mounted) {
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

        if (!context.mounted) return;
        if (shouldPrint == 'print') {
          try {
            await printInvoiceDirect(
              context: context,
              invoice: invoiceForPrint,
              paperSize: _uiPaperSize,
              isArabic: true,
            );
          } catch (e) {
            if (!context.mounted) return;
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
            if (!context.mounted) return;
            _showError('تعذر مشاركة الفاتورة: $e');
          }
        }

        if (!context.mounted) return;
        if (shouldPrint == 'new_invoice') {
          _resetAfterSave();
        } else {
          // 'done' or null → return to home
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
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

  Map<String, dynamic>? _findCashCustomer() {
    for (final customer in widget.customers) {
      final rawId = customer['id'];
      final id = rawId is int ? rawId : int.tryParse(rawId.toString());
      if (id == null || id <= 0) continue;

      if (_isCashCustomerEntry(customer)) {
        return {...customer, 'id': id};
      }
    }
    return null;
  }

  bool _isCashCustomerEntry(Map<String, dynamic>? customer) {
    if (customer == null) return false;
    final name = customer['name']?.toString().toLowerCase() ?? '';
    final code = customer['customer_code']?.toString().toLowerCase() ?? '';
    return _containsCashKeyword(name) || _containsCashKeyword(code);
  }

  bool _containsCashKeyword(String value) {
    if (value.isEmpty) return false;
    return value.contains('نقد') ||
        value.contains('كاش') ||
        value.contains('cash');
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
        Future<void> submit() async {
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
        }

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
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'اسم العميل *',
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'رقم الجوال',
                    prefixIcon: Icon(Icons.phone),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: addressController,
                  maxLines: 2,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => submit(),
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
              onPressed: submit,
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
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed:
                                _items.isEmpty ||
                                    _payments.isEmpty ||
                                    _remainingAmount > 0.01
                                ? null
                                : _submitInvoice,
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 24,
                            ),
                            label: _settingsProvider.buildText(
                              _remainingAmount > 0.01
                                  ? 'أكمل الدفع (${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText} متبقية)'
                                  : 'حفظ الفاتورة',
                            ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                vertical: 18,
                                horizontal: 24,
                              ),
                              textStyle: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              backgroundColor: colorScheme.primary,
                              foregroundColor: colorScheme.onPrimary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
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
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _items.isEmpty ||
                          _payments.isEmpty ||
                          _remainingAmount > 0.01
                      ? null
                      : _submitInvoice,
                  icon: const Icon(Icons.check_circle_outline, size: 24),
                  label: _settingsProvider.buildText(
                    _remainingAmount > 0.01
                        ? 'أكمل الدفع (${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText} متبقية)'
                        : 'حفظ الفاتورة',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 18,
                      horizontal: 24,
                    ),
                    textStyle: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ],
        );

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.invoiceSaleScrap,
            foregroundColor: Colors.white,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(_isEditMode
                ? 'تعديل فاتورة بيع الكسر #${widget.editInvoiceData?['invoice_type_id'] ?? ''}'
                : 'فاتورة بيع الكسر'),
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
                    contextType: InvoiceUiContext.scrapSale,
                    supportsVatToggle: true,
                    supportsLockEdits: true,
                    supportsAutoOpenPrint: true,
                    onChanged: (s) {
                      if (!mounted) return;
                      setState(() {
                        _uiLockPriceEdits = s.lockPriceEdits;
                        _uiDisableVat = s.disableVat;
                        _uiAutoOpenPrintAfterSave = s.autoOpenPrintAfterSave;
                        _uiPaperSize = s.paperSize;

                        if (_uiDisableVat) {
                          for (final item in _items) {
                            item.taxRate = 0.0;
                          }
                        } else {
                          for (final item in _items) {
                            item.taxRate = _effectiveTaxRateForKarat(
                              item.karat,
                            );
                          }
                        }
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
                    if (id == null || id <= 0) return null;
                      final name = (customer['name'] ?? 'عميل').toString();
                      final phone =
                          (customer['phone'] ?? customer['phone_number'] ?? '')
                              .toString();
                    final isCashCustomer = _isCashCustomerEntry(customer);
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
                Icons.edit_note,
                _settingsProvider.allowManualInvoiceItems
                    ? AppColors.warning
                    : theme.disabledColor,
                _settingsProvider.allowManualInvoiceItems
                    ? 'إضافة صنف يدوي'
                    : 'فعّل من الإعدادات لإضافة صنف يدوي',
                _settingsProvider.allowManualInvoiceItems
                    ? _showManualItemDialog
                    : _showManualItemFeatureGuide,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.category,
                _settingsProvider.allowManualInvoiceItems
                    ? AppColors.primaryGold
                    : theme.disabledColor,
                _settingsProvider.allowManualInvoiceItems
                    ? 'سطر تصنيف'
                    : 'فعّل من الإعدادات لإضافة سطر تصنيف',
                _settingsProvider.allowManualInvoiceItems
                    ? _showCategoryLineDialog
                    : _showManualItemFeatureGuide,
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
                      item.karat.toStringAsFixed(0),
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
                      item.weight.toStringAsFixed(2),
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
                    child: Text(item.wage.toStringAsFixed(2), style: cellStyle),
                  ),
                ),
              ),
              DataCell(
                Text(
                  item.calculateSellingPricePerGram().toStringAsFixed(2),
                  style: cellStyle,
                ),
              ),
              DataCell(Text(item.cost.toStringAsFixed(2), style: cellStyle)),
              DataCell(Text(item.net.toStringAsFixed(2), style: cellStyle)),
              DataCell(Text(item.tax.toStringAsFixed(2), style: cellStyle)),
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
          inputFormatters: [NormalizeNumberFormatter()],
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
              ? [
                  colorScheme.surfaceContainerHighest,
                  theme.scaffoldBackgroundColor,
                ]
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
                backgroundColor: isDark
                    ? AppColors.karat24
                    : AppColors.primaryGold,
                foregroundColor: isDark ? Colors.white : Colors.black,
                disabledBackgroundColor: theme.disabledColor.withValues(
                  alpha: 0.2,
                ),
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
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? 0.35 : 0.4,
                  ),
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
                        shadows: !isDark
                            ? [
                                Shadow(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  blurRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    Text(
                      '${_items.length} صنف',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.9)
                            : Colors.black87,
                        fontWeight: FontWeight.w500,
                        shadows: !isDark
                            ? [
                                Shadow(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  blurRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ],
                ),
                _settingsProvider.buildText(
                  '${grandTotal.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                    shadows: !isDark
                        ? [
                            Shadow(
                              color: Colors.white.withValues(alpha: 0.9),
                              blurRadius: 3,
                            ),
                          ]
                        : null,
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
                    color: AppColors.success.withValues(
                      alpha: isDark ? 0.2 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.4),
                    ),
                  ),
                  child: _settingsProvider.buildText(
                    'الإجمالي: ${totalAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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

            // 🆕 إضافة وسيلة دفع جديدة
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(
                  alpha: isDark ? 0.15 : 0.12,
                ),
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
                                color: colorScheme.primary.withValues(
                                  alpha: 0.16,
                                ),
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
                                      color: colorScheme.primary.withValues(
                                        alpha: 0.25,
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
                                    suffixText: _currencySymbol,
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
                                        color: colorScheme.primary.withValues(
                                          alpha: 0.4,
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
                          shadowColor: colorScheme.primary.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(
                        alpha: isDark ? 0.18 : 0.12,
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
                        _settingsProvider.buildText(
                          'المتبقي: ${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                          colorScheme.error.withValues(
                            alpha: isDark ? 0.16 : 0.12,
                          ),
                          colorScheme.error.withValues(
                            alpha: isDark ? 0.28 : 0.2,
                          ),
                        ]
                      : [
                          AppColors.success.withValues(
                            alpha: isDark ? 0.16 : 0.12,
                          ),
                          AppColors.success.withValues(
                            alpha: isDark ? 0.28 : 0.2,
                          ),
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
                        _settingsProvider.buildText(
                          '${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                        _settingsProvider.buildText(
                          '${_calculateTotalVAT().toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                      _settingsProvider.buildText(
                        '${_totalPayments.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                        _settingsProvider.buildText(
                          '${_totalCommission.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                        _settingsProvider.buildText(
                          '${_totalCommissionVAT.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                        _settingsProvider.buildText(
                          '${_totalNet.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
                          child: _settingsProvider.buildText(
                            '${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
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
  final int? id;
  final String name;
  final String barcode;
  int count;
  double karat;
  double weight;
  double wage; // أجور المصنعية للجرام الواحد
  final double goldPrice24k;
  final int mainKarat;
  double taxRate;

  // الربح الموزع (يتم حسابه في _distributeAmount)
  double profit = 0.0;

  // علامة لتتبع إذا تم تحديد الإجمالي يدوياً
  bool _hasManualTotal = false;
  double? _targetTotal;

  InvoiceItem({
    this.id,
    required this.name,
    required this.barcode,
    this.count = 1,
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

// ==================== Category Line Dialog (name-only catalog) ====================
class _ScrapSaleCategoryLineResult {
  final String categoryName;
  final double amount;
  final double karat;
  final double weight;
  final double wage;
  final int count;

  const _ScrapSaleCategoryLineResult({
    required this.categoryName,
    required this.amount,
    required this.karat,
    required this.weight,
    required this.wage,
    required this.count,
  });
}

class _CategoryLineDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final int mainKarat;
  final String currencySymbol;

  const _CategoryLineDialog({
    required this.categories,
    required this.mainKarat,
    required this.currencySymbol,
  });

  @override
  State<_CategoryLineDialog> createState() => _CategoryLineDialogState();
}

class _CategoryLineDialogState extends State<_CategoryLineDialog> {
  final _formKey = GlobalKey<FormState>();
  final _categorySearchController = TextEditingController();
  final _weightController = TextEditingController(text: '1.0');
  final _wageController = TextEditingController(text: '0');
  final _countController = TextEditingController(text: '1');
  final _amountController = TextEditingController();

  final _categorySearchFocusNode = FocusNode();
  final _weightFocusNode = FocusNode();
  final _wageFocusNode = FocusNode();
  final _countFocusNode = FocusNode();
  final _amountFocusNode = FocusNode();

  Map<String, dynamic>? _selectedCategory;
  late int _selectedKarat;
  bool _karatLockedByCategory = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedKarat = widget.mainKarat;
    for (final c in [_weightController, _wageController, _countController]) {
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    }
  }

  @override
  void dispose() {
    _categorySearchController.dispose();
    _weightController.dispose();
    _wageController.dispose();
    _countController.dispose();
    _amountController.dispose();
    _categorySearchFocusNode.dispose();
    _weightFocusNode.dispose();
    _wageFocusNode.dispose();
    _countFocusNode.dispose();
    _amountFocusNode.dispose();
    super.dispose();
  }

  double _tryParseDouble(String value, double fallback) {
    final normalized = value.trim().replaceAll(',', '.');
    return double.tryParse(normalized) ?? fallback;
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
    final categoryKarat = _tryParseCategoryKarat(first);
    setState(() {
      _selectedCategory = first;
      _karatLockedByCategory = categoryKarat != null;
      if (categoryKarat != null) _selectedKarat = categoryKarat;
    });
  }

  int? _tryParseCategoryKarat(Map<String, dynamic> category) {
    final raw = category['karat'];
    final parsed = int.tryParse('${raw ?? ''}');
    if (parsed == null) return null;
    if (const [18, 21, 22, 24].contains(parsed)) return parsed;
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final categoryName = (_selectedCategory?['name'] ?? '').toString().trim();
    final weight = _tryParseDouble(_weightController.text, 0);
    final wage = _tryParseDouble(_wageController.text, 0);
    final count = int.tryParse(_countController.text.trim()) ?? 0;
    final amount = _tryParseDouble(_amountController.text, 0);

    if (count < 1) {
      _focusAndSelect(_countFocusNode, _countController);
      return;
    }
    if (categoryName.isEmpty || weight <= 0) return;

    Navigator.pop(
      context,
      _ScrapSaleCategoryLineResult(
        categoryName: categoryName,
        amount: amount,
        karat: _selectedKarat.toDouble(),
        weight: weight,
        wage: wage,
        count: count,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _searchQuery.isEmpty
        ? widget.categories
        : widget.categories.where((c) {
            final name = (c['name'] ?? '').toString().trim().toLowerCase();
            return name.contains(_searchQuery);
          }).toList();
    final limited = filtered.take(100).toList();
    final screenSize = MediaQuery.sizeOf(context);
    final dialogMaxHeight = (screenSize.height * 0.85).clamp(680.0, 900.0);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: BoxConstraints(maxWidth: 550, maxHeight: dialogMaxHeight),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFD4AF37).withValues(alpha: 0.15),
                      const Color(0xFFD4AF37).withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD4AF37),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.category,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'إضافة سطر تصنيف',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'اختر تصنيفاً وحدد التفاصيل',
                          style: TextStyle(fontSize: 13, color: Colors.black54),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Content
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _categorySearchController,
                        autofocus: true,
                        focusNode: _categorySearchFocusNode,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'ابحث عن التصنيف',
                          hintText: 'اكتب لتصفية النتائج...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.search, size: 22),
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                        ),
                        onChanged: (v) {
                          setState(() => _searchQuery = v.trim().toLowerCase());
                        },
                        onFieldSubmitted: (_) {
                          if (_selectedCategory == null) {
                            _selectFirstMatchingCategory(limited);
                          }
                          if (_selectedCategory != null) {
                            _focusAndSelect(
                              _weightFocusNode,
                              _weightController,
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      FormField<int>(
                        validator: (_) => _selectedCategory == null
                            ? 'الرجاء اختيار تصنيف'
                            : null,
                        builder: (state) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'التصنيفات المتاحة (${limited.length})',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 220,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  border: Border.all(
                                    color: state.hasError
                                        ? theme.colorScheme.error
                                        : theme.dividerColor.withValues(
                                            alpha: 0.3,
                                          ),
                                    width: 1.5,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: limited.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.search_off,
                                              size: 56,
                                              color: theme.disabledColor,
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              'لا توجد نتائج',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    color: theme.disabledColor,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(8),
                                        itemCount: limited.length,
                                        itemBuilder: (_, index) {
                                          final opt = limited[index];
                                          final id = (opt['id'] is num)
                                              ? (opt['id'] as num).toInt()
                                              : int.tryParse('${opt['id']}');
                                          final name = (opt['name'] ?? '')
                                              .toString();
                                          final isSelected =
                                              _selectedCategory != null &&
                                              id != null &&
                                              ((_selectedCategory!['id'] is num)
                                                  ? (_selectedCategory!['id']
                                                                as num)
                                                            .toInt() ==
                                                        id
                                                  : int.tryParse(
                                                          '${_selectedCategory!['id']}',
                                                        ) ==
                                                        id);

                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: InkWell(
                                              onTap: () {
                                                setState(() {
                                                  _selectedCategory = opt;
                                                  final k =
                                                      _tryParseCategoryKarat(
                                                        opt,
                                                      );
                                                  _karatLockedByCategory =
                                                      k != null;
                                                  if (k != null) {
                                                    _selectedKarat = k;
                                                  }
                                                });
                                                state.didChange(id);
                                              },
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              child: AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 14,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? const Color(
                                                          0xFFD4AF37,
                                                        ).withValues(alpha: 0.2)
                                                      : theme
                                                            .colorScheme
                                                            .surfaceContainerHighest
                                                            .withValues(
                                                              alpha: 0.3,
                                                            ),
                                                  border: Border.all(
                                                    color: isSelected
                                                        ? const Color(
                                                            0xFFD4AF37,
                                                          )
                                                        : Colors.transparent,
                                                    width: 2,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.label,
                                                      size: 18,
                                                      color: isSelected
                                                          ? const Color(
                                                              0xFFD4AF37,
                                                            )
                                                          : theme
                                                                .iconTheme
                                                                .color,
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child: Text(
                                                        name,
                                                        style: TextStyle(
                                                          fontSize: 15,
                                                          fontWeight: isSelected
                                                              ? FontWeight.bold
                                                              : FontWeight.w500,
                                                        ),
                                                      ),
                                                    ),
                                                    if (isSelected)
                                                      const Icon(
                                                        Icons.check_circle,
                                                        color: Color(
                                                          0xFFD4AF37,
                                                        ),
                                                        size: 20,
                                                      ),
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
                                  state.errorText!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'تفاصيل الصنف',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: _selectedKarat,
                        decoration: InputDecoration(
                          labelText: 'العيار',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: Icon(
                            _karatLockedByCategory ? Icons.lock : Icons.diamond,
                            size: 20,
                            color: _karatLockedByCategory
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          filled: true,
                          fillColor: _karatLockedByCategory
                              ? theme.colorScheme.primary.withValues(alpha: 0.07)
                              : theme.colorScheme.surface,
                          helperText: _karatLockedByCategory
                              ? 'محدد من التصنيف'
                              : null,
                          helperStyle: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 11,
                          ),
                        ),
                        items: const [18, 21, 22, 24]
                            .map(
                              (k) => DropdownMenuItem<int>(
                                value: k,
                                child: Text('عيار $k'),
                              ),
                            )
                            .toList(),
                        onChanged: _karatLockedByCategory
                            ? null
                            : (v) => setState(
                                () => _selectedKarat = v ?? _selectedKarat,
                              ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _weightController,
                              focusNode: _weightFocusNode,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _focusAndSelect(
                                _wageFocusNode,
                                _wageController,
                              ),
                              onTap: () =>
                                  _weightController.selection = TextSelection(
                                    baseOffset: 0,
                                    extentOffset: _weightController.text.length,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'الوزن (جم)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.scale, size: 20),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                              validator: (v) {
                                final val = _tryParseDouble(v ?? '', 0);
                                if (val <= 0) return 'وزن غير صحيح';
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _wageController,
                              focusNode: _wageFocusNode,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _focusAndSelect(
                                _countFocusNode,
                                _countController,
                              ),
                              onTap: () =>
                                  _wageController.selection = TextSelection(
                                    baseOffset: 0,
                                    extentOffset: _wageController.text.length,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'المصنعية/جم',
                                hintText: '0',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.build, size: 20),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: _countController,
                              focusNode: _countFocusNode,
                              keyboardType: TextInputType.number,
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _focusAndSelect(
                                _amountFocusNode,
                                _amountController,
                              ),
                              onTap: () =>
                                  _countController.selection = TextSelection(
                                    baseOffset: 0,
                                    extentOffset: _countController.text.length,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'العدد',
                                hintText: '1',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.numbers, size: 20),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                              validator: (v) {
                                final val = int.tryParse(v?.trim() ?? '');
                                if (val == null || val < 1) return 'عدد ≥ 1';
                                return null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _amountController,
                        focusNode: _amountFocusNode,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        inputFormatters: const [
                          ArabicNumberTextInputFormatter(allowDecimal: true),
                        ],
                        onFieldSubmitted: (_) => _submit(),
                        onTap: () =>
                            _amountController.selection = TextSelection(
                              baseOffset: 0,
                              extentOffset: _amountController.text.length,
                            ),
                        decoration: InputDecoration(
                          labelText: 'المبلغ (اختياري)',
                          hintText: 'اتركه فارغاً للحساب التلقائي',
                          suffixText: widget.currencySymbol,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(
                            Icons.payments_outlined,
                            size: 20,
                          ),
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Actions
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.5),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(20),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('إلغاء'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.check, size: 20),
                      label: const Text('إضافة السطر'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4AF37),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
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
    );
  }
}
