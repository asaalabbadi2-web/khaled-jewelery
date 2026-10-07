import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 🆕 للـ FilteringTextInputFormatter
import 'dart:convert';
import 'dart:math' as math;
import 'package:mobile_scanner/mobile_scanner.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../models/safe_box_model.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/sales_race_refresh_provider.dart';
import 'add_customer_screen.dart';
import '../widgets/inline_number_cell.dart';
import '../widgets/invoice_settings_sheet.dart';
import '../widgets/sales_category_entry_row.dart';
import '../widgets/adaptive_invoice_summary_dialog.dart';
import '../widgets/party_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';
import 'settings_screen_enhanced.dart';
import '../utils.dart';
import '../utils/arabic_number_formatter.dart';
import '../utils/invoice_direct_print.dart';
import '../utils/currency_utils.dart' as cu;
import '../utils/sales_readiness.dart';

/// شاشة فاتورة البيع - النسخة الهجينة المحسّنة
/// تجمع بين Smart Input (Progressive) و DataTable (Professional)
/// The walk-in customer, by the names the server knows it by
/// (models.CASH_CUSTOMER_NAMES).
const _cashCustomerNames = {'عميل نقدي', 'نقدي', 'عميل كاش'};

String _foldSpaces(Object? value) =>
    (value ?? '').toString().trim().split(RegExp(r'\s+')).join(' ');

class SalesInvoiceScreenV2 extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> customers;

  /// When non-null the screen is in **edit mode** for an existing unposted invoice.
  final int? editInvoiceId;
  final Map<String, dynamic>? editInvoiceData;

  /// The server; a test hands its own.
  final ApiService? apiService;

  const SalesInvoiceScreenV2({
    super.key,
    required this.items,
    required this.customers,
    this.editInvoiceId,
    this.editInvoiceData,
    this.apiService,
  });

  @override
  State<SalesInvoiceScreenV2> createState() => _SalesInvoiceScreenV2State();
}

class _SalesInvoiceScreenV2State extends State<SalesInvoiceScreenV2> {
  late final ApiService _api = widget.apiService ?? ApiService();

  // Where each readiness reason is fixed, to bring it into view.
  final _customerSectionKey = GlobalKey();
  final _itemsSectionKey = GlobalKey();
  final _paymentSectionKey = GlobalKey();

  // ==================== Edit Mode ====================
  bool get _isEditMode => widget.editInvoiceId != null;

  // ==================== State Variables ====================
  final _smartInputController = TextEditingController();
  final _smartInputFocus = FocusNode();
  final _customAmountController = TextEditingController(); // 🆕 للمبلغ المخصص

  bool _checkedLocalDraft = false;

  // Customer
  int? _selectedCustomerId;

  // Office / Branch (Dimensions)
  List<Map<String, dynamic>> _branches = [];
  bool _isLoadingBranches = false;
  String? _branchesLoadingError;
  int? _selectedBranchId;

  // Items List
  final List<InvoiceItem> _items = [];
  List<Map<String, dynamic>> _availableItems = [];
  bool _isLoadingItems = false;
  String? _itemsLoadingError;

  // Categories (for category-only invoice lines)
  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingCategories = false;
  String? _categoriesLoadingError;

  // Gold Price & Settings
  double _goldPrice24k = 0.0;

  // Settings - accessible throughout the class
  late SettingsProvider _settingsProvider;

  bool _uiLockPriceEdits = false;
  /// VAT on sales is the company's setting (SALES-VAT-1), read from the
  /// server -- no longer a switch kept on this device.
  bool get _uiDisableVat =>
      !context.read<SettingsProvider>().salesVatEnabled;
  bool _uiAutoOpenPrintAfterSave = false;
  String _uiPaperSize = 'A4';

  double get _effectiveVatRate =>
      _uiDisableVat ? 0.0 : _settingsProvider.taxRate;

  // Payment - 🆕 وسائل دفع متعددة
  List<Map<String, dynamic>> _paymentMethods = [];
  final List<PaymentEntry> _payments = []; // 🆕 قائمة الدفعات المadded
  int? _selectedPaymentMethodId; // للـ Dropdown

  // 🆕 Gold barter (scrap) inside payments
  bool _enableBarter = false;
  final List<_BarterLine> _barterLines = [];
  // 🆕 Barter gold deposit safe (when employee has no linked gold safe)
  List<SafeBoxModel> _barterGoldDepositSafeBoxes = [];
  int? _selectedBarterGoldDepositSafeBoxId;
  bool _isLoadingBarterGoldDepositSafeBoxes = false;

  /// The name of each safe seen, for the payment lines.
  final Map<int, String> _safeNames = {};

  // Safe Boxes - 🆕 الخزائن المتاحة للدفع
  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId; // الخزينة المختارة للدفعة الحالية
  bool _showAdvancedPaymentOptions = false; // 🎯 للتحكم في إظهار الخزائن

  // Gold Costing Snapshot (Moving Average)
  bool _didBootstrapCosting = false;
  double _avgGoldCostPerMainGram = 0.0;
  double _avgManufacturingCostPerMainGram = 0.0;


  void _resetAfterSave() {
    setState(() {
      _selectedCustomerId = null;
      _items.clear();
      _payments.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _showAdvancedPaymentOptions = false;
      _smartInputController.clear();
      _customAmountController.clear();

      _enableBarter = false;
      for (final line in _barterLines) {
        line.dispose();
      }
      _barterLines.clear();
      _barterGoldDepositSafeBoxes = [];
      _selectedBarterGoldDepositSafeBoxId = null;
      _isLoadingBarterGoldDepositSafeBoxes = false;
    });
    _smartInputFocus.requestFocus();
  }

  String _localDraftKey() => 'yasargold_sales_invoice_complete_later_v2';

  Map<String, dynamic> _buildLocalDraftPayload() {
    return {
      'version': 1,
      'customer_id': _selectedCustomerId,
      'branch_id': _selectedBranchId,
      'custom_amount': _customAmountController.text,
      'ui_lock_price_edits': _uiLockPriceEdits,
      'ui_auto_print': _uiAutoOpenPrintAfterSave,
      'ui_paper_size': _uiPaperSize,
      'selected_payment_method_id': _selectedPaymentMethodId,
      'selected_safe_box_id': _selectedSafeBoxId,
      'show_advanced_payment_options': _showAdvancedPaymentOptions,
      'payments': _payments
          .map(
            (p) => {
              'payment_method_id': p.paymentMethodId,
              'payment_method_name': p.paymentMethodName,
              'amount': p.amount,
              'commission_rate': p.commissionRate,
              'commission_amount': p.commissionAmount,
              'commission_vat': p.commissionVat,
              'net_amount': p.netAmount,
              'settlement_days': p.settlementDays,
              'notes': p.notes,
              'safe_box_id': p.safeBoxId,
            },
          )
          .toList(),
      'items': _items
          .map(
            (i) => {
              'item_id': i.id,
              'name': i.name,
              'barcode': i.barcode,
              'karat': i.karat,
              'weight': i.weight,
              'wage': i.wage,
              'category_id': i.categoryId,
              'category_name': i.categoryName,
              'count': i.count,
              'profit': i.profit,
              'tax_rate': i.taxRate,
              'has_manual_total': i.hasManualTotal,
              'manual_total': i.manualTargetTotal,
            },
          )
          .toList(),
      'enable_barter': _enableBarter,
      'barter_gold_deposit_safe_box_id': _selectedBarterGoldDepositSafeBoxId,
      'barter_lines': _barterLines
          .map(
            (l) => {
              'karat': l.karat,
              'standing': l.standingController.text,
              'stones': l.stonesController.text,
              'price_per_gram': l.pricePerGramController.text,
              'total_amount': l.totalAmountController.text,
            },
          )
          .toList(),
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
          'يوجد نموذج فاتورة محفوظ لإكماله لاحقاً. هل تريد استعادته؟',
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

    try {
      final items =
          (decoded['items'] as List?)?.whereType<Map>().toList() ?? [];
      final payments =
          (decoded['payments'] as List?)?.whereType<Map>().toList() ?? [];
      final barterLines =
          (decoded['barter_lines'] as List?)?.whereType<Map>().toList() ?? [];

      for (final l in _barterLines) {
        l.dispose();
      }

      final restoredItems = <InvoiceItem>[];
      for (final rawItem in items) {
        final map = Map<String, dynamic>.from(rawItem);
        final item = InvoiceItem(
          id: toInt(map['item_id']),
          name: (map['name'] ?? '').toString(),
          barcode: (map['barcode'] ?? '').toString(),
          karat: toDouble(map['karat']),
          weight: toDouble(map['weight']),
          wage: toDouble(map['wage']),
          categoryId: toInt(map['category_id']),
          categoryName: map['category_name']?.toString(),
          count: toInt(map['count']) ?? 1,
          goldPrice24k: _goldPrice24k,
          mainKarat: _settingsProvider.mainKarat,
          taxRate: toDouble(map['tax_rate']),
          avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
          avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
        );
        item.profit = toDouble(map['profit']);
        final hasManual = map['has_manual_total'] == true;
        final manualTotal = map['manual_total'];
        if (hasManual && manualTotal != null) {
          final mt = toDouble(manualTotal);
          if (mt > 0) item.setManualTotal(mt);
        }
        restoredItems.add(item);
      }

      final restoredPayments = <PaymentEntry>[];
      for (final rawPay in payments) {
        final map = Map<String, dynamic>.from(rawPay);
        restoredPayments.add(
          PaymentEntry(
            paymentMethodId: toInt(map['payment_method_id']) ?? 0,
            paymentMethodName: (map['payment_method_name'] ?? '').toString(),
            amount: toDouble(map['amount']),
            commissionRate: toDouble(map['commission_rate']),
            commissionAmount: toDouble(map['commission_amount']),
            commissionVat: toDouble(map['commission_vat']),
            netAmount: toDouble(map['net_amount']),
            settlementDays: toInt(map['settlement_days']) ?? 0,
            notes: map['notes']?.toString(),
            safeBoxId: toInt(map['safe_box_id']),
          ),
        );
      }

      final restoredBarter = <_BarterLine>[];
      for (final rawLine in barterLines) {
        final map = Map<String, dynamic>.from(rawLine);
        final k = toInt(map['karat']) ?? _settingsProvider.mainKarat;
        final l = _BarterLine(karat: k);
        l.standingController.text = (map['standing'] ?? '').toString();
        l.stonesController.text = (map['stones'] ?? '').toString();
        l.pricePerGramController.text = (map['price_per_gram'] ?? '')
            .toString();
        l.totalAmountController.text = (map['total_amount'] ?? '').toString();
        restoredBarter.add(l);
      }

      setState(() {
        _selectedCustomerId = toInt(decoded?['customer_id']);
        _selectedBranchId = toInt(decoded?['branch_id']);
        _customAmountController.text = (decoded?['custom_amount'] ?? '')
            .toString();
        _uiLockPriceEdits = decoded?['ui_lock_price_edits'] == true;
        _uiAutoOpenPrintAfterSave = decoded?['ui_auto_print'] == true;
        _uiPaperSize = (decoded?['ui_paper_size'] ?? _uiPaperSize).toString();
        _selectedPaymentMethodId = toInt(
          decoded?['selected_payment_method_id'],
        );
        _selectedSafeBoxId = toInt(decoded?['selected_safe_box_id']);
        _showAdvancedPaymentOptions =
            decoded?['show_advanced_payment_options'] == true;

        _items
          ..clear()
          ..addAll(restoredItems);
        _payments
          ..clear()
          ..addAll(restoredPayments);

        _enableBarter = decoded?['enable_barter'] == true;
        _selectedBarterGoldDepositSafeBoxId = toInt(
          decoded?['barter_gold_deposit_safe_box_id'],
        );
        _barterLines
          ..clear()
          ..addAll(restoredBarter);

        if (_uiDisableVat) {
          for (final item in _items) {
            item.taxRate = 0.0;
          }
        }
      });

      if (_enableBarter) {
        await _loadBarterGoldDepositSafeBoxesIfNeeded();
      }
    } catch (_) {
      await _clearLocalDraft();
    }
  }

  Future<void> _completeLater() async {
    await _saveLocalDraft(showToast: true);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _loadBarterGoldDepositSafeBoxesIfNeeded() async {
    if (_isLoadingBarterGoldDepositSafeBoxes) return;

    final employeeGoldSafesEnabled =
        _settingsProvider.settings['employee_gold_safes_enabled'] == true;
    if (!employeeGoldSafesEnabled) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final employeeGoldSafeId =
        authProvider.currentUser?.employee?.goldSafeBoxId;

    // If the employee has a linked gold safe, backend will deposit there.
    if (employeeGoldSafeId != null) return;

    setState(() {
      _isLoadingBarterGoldDepositSafeBoxes = true;
    });

    try {
      final apiService = _api;
      final all = await apiService.getSafeBoxes();
      final goldBoxes = all
          .where((b) => b.safeType == 'gold' && b.id != null && b.isActive)
          .toList();

      int? picked = _selectedBarterGoldDepositSafeBoxId;
      if (picked != null && goldBoxes.any((b) => b.id == picked)) {
        // keep
      } else {
        final mainScrapIdRaw =
            _settingsProvider.settings['main_scrap_gold_safe_box_id'];
        final mainScrapId = mainScrapIdRaw is int
            ? mainScrapIdRaw
            : int.tryParse(mainScrapIdRaw?.toString() ?? '');
        if (mainScrapId != null && goldBoxes.any((b) => b.id == mainScrapId)) {
          picked = mainScrapId;
        } else {
          picked = goldBoxes.isNotEmpty ? goldBoxes.first.id : null;
        }
      }

      if (!mounted) return;
      setState(() {
        _barterGoldDepositSafeBoxes = goldBoxes;
        _selectedBarterGoldDepositSafeBoxId = picked;
        _isLoadingBarterGoldDepositSafeBoxes = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingBarterGoldDepositSafeBoxes = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _availableItems = widget.items
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (_availableItems.isEmpty) {
      _loadAvailableItems();
    }
    _loadInvoiceUiSettingsFromPrefs();
    _loadSettings();
    _loadBranches();
    _ensureCategoriesLoaded();
    _loadPaymentMethods(); // 🆕 جلب وسائل الدفع
    _smartInputFocus.requestFocus();
    if (_isEditMode) {
      // In edit mode, prefill after data loads
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prefillFromExistingInvoice();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybePromptRestoreLocalDraft();
      });
    }
  }

  // ==================== Edit Mode Prefill ====================
  void _prefillFromExistingInvoice() {
    final data = widget.editInvoiceData;
    if (data == null) return;

    setState(() {
      // Customer & Branch
      _selectedCustomerId = _parseInt(data['customer_id']);
      _selectedBranchId = _parseInt(data['branch_id']);

      // Items
      final rawItems = data['items'];
      if (rawItems is List) {
        for (final rawItem in rawItems) {
          if (rawItem is! Map) continue;
          final m = Map<String, dynamic>.from(rawItem);
          final karat = _parseDouble(m['karat']);
          final weight = _parseDouble(m['weight']);
          final wage = _parseDouble(m['wage']);
          final net = _parseDouble(m['net']);
          final tax = _parseDouble(m['tax']);
          final taxRate = (net > 0) ? (tax / net) : _effectiveVatRate;
          final count = _parseInt(m['quantity']) ?? 1;

          final item = InvoiceItem(
            id: _parseInt(m['item_id']),
            name: (m['name'] ?? '').toString(),
            barcode: '',
            karat: karat,
            weight: weight,
            wage: wage,
            categoryId: _parseInt(m['category_id']),
            categoryName: (m['category_name'] ?? '').toString(),
            count: count,
            goldPrice24k: _goldPrice24k,
            mainKarat: _settingsProvider.mainKarat,
            taxRate: taxRate,
            avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
            avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
          );
          // Restore profit so the totals match the original invoice
          final cost = item.cost;
          item.profit = net - cost;
          _items.add(item);
        }
      }

      // Payments
      final rawPayments = data['payments'];
      if (rawPayments is List) {
        for (final rawPay in rawPayments) {
          if (rawPay is! Map) continue;
          final m = Map<String, dynamic>.from(rawPay);
          _payments.add(
            PaymentEntry(
              paymentMethodId: _parseInt(m['payment_method_id']) ?? 0,
              paymentMethodName: (m['payment_method_name'] ?? '').toString(),
              amount: _parseDouble(m['amount']),
              commissionRate: _parseDouble(m['commission_rate']),
              commissionAmount: _parseDouble(m['commission_amount']),
              commissionVat: _parseDouble(m['commission_vat']),
              netAmount: _parseDouble(m['net_amount']),
              settlementDays: _parseInt(m['settlement_days']) ?? 0,
              notes: m['notes']?.toString(),
              safeBoxId: _parseInt(m['safe_box_id']),
            ),
          );
        }
      }
    });
  }

  Future<void> _loadInvoiceUiSettingsFromPrefs() async {
    try {
      final loaded = await InvoiceUiSettings.load(InvoiceUiContext.saleNew);
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

  @override
  void didUpdateWidget(covariant SalesInvoiceScreenV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.items, oldWidget.items)) {
      _availableItems = widget.items
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (_availableItems.isEmpty && !_isLoadingItems) {
        _loadAvailableItems();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settingsProvider = Provider.of<SettingsProvider>(context, listen: false);
    if (!_didBootstrapCosting) {
      _didBootstrapCosting = true;
      // The cost is costing.view's (ADR-036, the owner 2 Oct 2026): the seller
      // sells without it; the server still holds a sale under cost for approval.
      if (_seesCost) _loadGoldCostingSnapshot();
    }
  }

  @override
  void dispose() {
    _smartInputController.dispose();
    _smartInputFocus.dispose();
    _customAmountController.dispose(); // 🆕
    for (final line in _barterLines) {
      line.dispose();
    }
    super.dispose();
  }

  // ==================== Data Loading ====================
  Future<void> _loadSettings() async {
    try {
      final apiService = _api;
      final priceData = await apiService.getGoldPrice();
      if (!mounted) return;
      setState(() {
        _goldPrice24k = _parseDouble(priceData['price_24k']);
      });
      _applyGoldPriceToItems();
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
      if (mounted) {
        setState(() {
          _isLoadingBranches = false;
        });
      }
    }
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  String? _selectedCustomerDisplay() {
    final selectedId = _selectedCustomerId;
    if (selectedId == null) return null;

    for (final c in widget.customers) {
      final id = _parseInt(c['id']);
      if (id != selectedId) continue;
      final name = (c['name'] ?? c['customer_name'] ?? '').toString().trim();
      final phone =
          (c['phone'] ?? c['phone_number'] ?? c['customer_phone'] ?? '')
              .toString()
              .trim();
      if (name.isEmpty) return null;
      if (phone.isEmpty) return name;
      return '$name • $phone';
    }
    return null;
  }

  Future<void> _pickCustomer() async {
    if (widget.customers.isEmpty) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => PartyPickerDialog(
        title: 'اختيار عميل',
        items: widget.customers,
        selectedId: _selectedCustomerId,
        emptyText: 'لا يوجد عميل مطابق',
      ),
    );

    if (selected == null) return;
    final id = _parseInt(selected['id']);
    if (id == null) return;
    setState(() => _selectedCustomerId = id);
  }

  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(normalizeNumber(value.toString()).trim()) ?? 0.0;
  }

  /// An amount as the cashier typed it: Arabic digits, «٫», and a comma as
  /// the thousands separator. Null when it is not a number -- never «the
  /// remainder» (an unread amount was recorded as all that was due).
  double? _readAmount(String text) => double.tryParse(
    normalizeNumber(text).replaceAll(',', '').replaceAll('،', '').trim(),
  );

  /// A number typed in a line's field (weight, wage, total, karat).
  double? _readNumber(String text) =>
      double.tryParse(normalizeNumber(text).replaceAll(',', '.').trim());

  Future<void> _loadAvailableItems() async {
    if (_isLoadingItems) return;
    setState(() {
      _isLoadingItems = true;
      _itemsLoadingError = null;
    });

    try {
      final apiService = _api;
      final fetched = await apiService.getItems(inStockOnly: true);
      final normalized = fetched
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (mounted) {
        setState(() {
          _availableItems = normalized;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _itemsLoadingError = 'فشل تحميل الأصناف: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingItems = false;
        });
      }
    }
  }

  // 🆕 جلب وسائل الدفع النشطة
  Future<void> _loadPaymentMethods() async {
    try {
      final apiService = _api;
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
        _selectedPaymentMethodId =
            null; // لا توجد وسيلة دفع افتراضية — يجب على الموظف الاختيار يدوياً
      });
    } catch (e) {
      _showError('فشل تحميل وسائل الدفع: $e');
    }
  }

  // 🆕 تحميل الخزائن بناءً على طريقة الدفع
  Future<void> _loadSafeBoxesForPaymentMethod(int paymentMethodId) async {
    try {
      final method = _paymentMethods.firstWhere(
        (m) => m['id'] == paymentMethodId,
        orElse: () => {},
      );

      if (method.isEmpty) return;

      final paymentType = method['payment_type'] as String?;
      if (paymentType == null) return;

      // Receivable methods represent on-account settlement; no safe box should be required.
      if (paymentType == 'receivable') {
        if (!mounted) return;
        setState(() {
          _safeBoxes = [];
          _selectedSafeBoxId = null;
          _showAdvancedPaymentOptions = false;
        });
        return;
      }

      final defaultSafeBoxId = method['default_safe_box_id'];

      final apiService = _api;
      final allBoxes = await apiService.getSafeBoxes();
      for (final b in allBoxes) {
        if (b.id != null) _safeNames[b.id!] = b.name;
      }

      // Discard this response if the user has since switched to a different
      // payment method while we were waiting on the network -- otherwise an
      // earlier, slower-to-resolve call can overwrite the safe box chosen for
      // whatever method is now actually selected (e.g. مدى's safe box gets
      // silently replaced by نقداً's because the نقداً request happened to
      // resolve last), routing the GL entry to the wrong account.
      if (!mounted || _selectedPaymentMethodId != paymentMethodId) return;

      List<SafeBoxModel> boxes;

      // ✅ قواعد التوافق (الأفضل والمعمول به غالباً):
      // - cash => خزائن نقدية فقط
      // - باقي الأنواع (بطاقات/BNPL/محافظ/تحويل) => خزائن بنكية (وأحياناً شيكات)
      final isCash = paymentType == 'cash';
      final isCheck = paymentType == 'check';
      final isBankLike = !isCash;

      switch (paymentType) {
        case 'cash':
          boxes = allBoxes.where((box) => box.safeType == 'cash').toList();
          break;
        default:
          if (isCheck) {
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'bank' || box.safeType == 'check',
                )
                .toList();
          } else if (isBankLike) {
            // Cards/BNPL/wallets commonly settle later => allow clearing + bank.
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'bank' || box.safeType == 'clearing',
                )
                .toList();
          } else {
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'cash' || box.safeType == 'bank',
                )
                .toList();
          }
      }

      if (!mounted) return;

      setState(() {
        _safeBoxes = boxes;
        // اختيار الخزينة الافتراضية
        if (_safeBoxes.isNotEmpty) {
          SafeBoxModel? picked;

          // If employee cash safes are enabled, default cash payments to the
          // logged-in employee cash safe (when available).
          if (isCash) {
            try {
              final employeeCashSafesEnabled =
                  _settingsProvider.settings['employee_cash_safes_enabled'] ==
                  true;
              if (employeeCashSafesEnabled) {
                final authProvider = Provider.of<AuthProvider>(
                  context,
                  listen: false,
                );
                final employeeCashSafeId =
                    authProvider.currentUser?.employee?.cashSafeBoxId;
                if (employeeCashSafeId != null) {
                  picked = _safeBoxes.firstWhere(
                    (box) => box.id == employeeCashSafeId,
                    orElse: () => _safeBoxes.first,
                  );
                }
              }
            } catch (_) {
              // ignore and fall back to the standard selection logic
            }
          }

          final defId = defaultSafeBoxId is int
              ? defaultSafeBoxId
              : int.tryParse(defaultSafeBoxId?.toString() ?? '');

          if (picked == null && defId != null) {
            picked = _safeBoxes.firstWhere(
              (box) => box.id == defId,
              orElse: () => _safeBoxes.first,
            );
          } else if (picked == null) {
            // Prefer clearing safes when available for non-cash methods.
            final clearingBoxes = _safeBoxes
                .where((box) => (box.safeType).toLowerCase() == 'clearing')
                .toList();
            if (clearingBoxes.isNotEmpty) {
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
          }

          _selectedSafeBoxId = picked.id;
        } else {
          _selectedSafeBoxId = null;
        }
      });
    } catch (e) {
      _showError('فشل تحميل الخزائن: $e');
    }
  }

  // ==================== Gold Costing Snapshot ====================
  /// The moving averages the items' cost is held to (costing.view only,
  /// ADR-036). The server still holds a sale under cost for approval whatever
  /// the screen knows.
  Future<void> _loadGoldCostingSnapshot() async {
    if (!mounted) return;
    try {
      final response = await _api.getGoldCostingSnapshot();
      final snapshot = Map<String, dynamic>.from(response['snapshot'] ?? {});
      if (!mounted) return;
      setState(() {
        _avgGoldCostPerMainGram = _parseDouble(snapshot['avg_gold']);
        _avgManufacturingCostPerMainGram = _parseDouble(
          snapshot['avg_manufacturing'],
        );
      });
      _applySnapshotToItems();
    } catch (_) {
      // Without the averages an item's cost is the gold price's.
    }
  }

  void _applySnapshotToItems() {
    if (_items.isEmpty) return;
    setState(() {
      for (final item in _items) {
        item.updateCostingSnapshot(
          avgGoldPerMainGram: _avgGoldCostPerMainGram,
          avgManufacturingPerMainGram: _avgManufacturingCostPerMainGram,
        );
      }
    });
  }

  void _applyGoldPriceToItems() {
    if (_items.isEmpty) return;
    setState(() {
      for (final item in _items) {
        item.updateGoldPrice(_goldPrice24k);
      }
    });
  }

  String _formatCurrency(double amount) {
    return '${amount.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}';
  }

  // ignore: unused_element
  Widget _buildCostingMetricTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
    Color? accentColor,
  }) {
    final colorScheme = theme.colorScheme;
    final accent = accentColor ?? colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        color: accent.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.15 : 0.1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.08 : 0.85,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
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
    final barterTotal = _barterTotal;
    if (barterTotal > total + 0.01) {
      _showError('قيمة المقايضة أكبر من إجمالي الفاتورة');
      return;
    }
    final alreadyPaid = _payments.fold<double>(0, (sum, p) => sum + p.amount);
    final remaining = double.parse(
      (total - alreadyPaid - barterTotal).toStringAsFixed(2),
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
          safeBoxId: _selectedSafeBoxId, // 🆕 إضافة معرف الخزينة
        ),
      );

      // إعادة تعيين الحقول
      _customAmountController.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null; // 🆕 إعادة تعيين الخزينة
      _safeBoxes = []; // 🆕 مسح قائمة الخزائن
    });
  }

  /// The chosen method takes the amount typed, or what remains when none is.
  void _addTypedPayment() {
    if (_safeBoxes.isNotEmpty && _selectedSafeBoxId == null) {
      _showError('اختر الخزينة أولاً');
      return;
    }

    // Empty pays what remains; anything else must read.
    final typed = _customAmountController.text.trim();
    final customAmount = typed.isEmpty ? null : _readAmount(typed);
    if (typed.isNotEmpty && customAmount == null) {
      _showError('لم يُقرأ المبلغ «$typed»؛ اكتبه أرقامًا فقط');
      return;
    }
    _addPayment(customAmount: customAmount);
  }

  /// One press: the method, its default safe, and the amount typed or what
  /// remains -- 806 of the 827 sales since June are paid by one or two.
  Future<void> _payWith(int methodId) async {
    setState(() => _selectedPaymentMethodId = methodId);
    await _loadSafeBoxesForPaymentMethod(methodId);
    if (!mounted) return;
    _addTypedPayment();
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
  double get _totalNet =>
      _payments.fold<double>(0, (sum, p) => sum + p.netAmount);

  /// The barter's «شراء من عميل» invoice -- saved with the sale in one
  /// transaction (BARTER-001; the owner: a barter is a purchase and a sale).
  Map<String, dynamic> _barterPurchasePayload({
    required int customerId,
    required String sellerName,
    required int? sellerEmployeeId,
    required double barterTotal,
  }) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final barterItems = _barterLines
        .map((line) {
          final standing = line.standingWeight(_parseDouble);
          final stones = line.stonesWeight(_parseDouble);
          final net = line.netWeight(_parseDouble);
          final pricePerGram = line.effectivePricePerGram(
            _parseDouble,
            _goldPrice24k,
          );
          final value = line.value(_parseDouble, _goldPrice24k);
          if (net <= 0 || pricePerGram <= 0) return null;
          return <String, dynamic>{
            'name': 'ذهب كسر (مقايضة)',
            'karat': line.karat,
            // weight should be NET weight to keep downstream totals consistent
            'weight': net,
            'standing_weight': standing,
            'stones_weight': stones,
            'direct_purchase_price_per_gram': pricePerGram,
            // price per item = cash-equivalent value of this line
            'price': value,
            'tax': 0.0,
            'wage': 0.0,
            'quantity': 1,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    final barterWeightNet = _barterTotalWeightNet;

    // الحصول على خزينة الذهب للموظف الحالي
    final employeeGoldSafeId =
        authProvider.currentUser?.employee?.goldSafeBoxId;

    final scrapInvoiceData = {
      'customer_id': customerId,
      'branch_id': _selectedBranchId,
      'invoice_type': 'شراء من عميل',
      'gold_type': 'scrap',
      'transaction_type': 'buy',
      if (sellerName.isNotEmpty) 'posted_by': sellerName,
      if (sellerEmployeeId != null) 'employee_id': sellerEmployeeId,
      if (sellerEmployeeId != null)
        'scrap_holder_employee_id': sellerEmployeeId,
      if (employeeGoldSafeId != null)
        'safe_box_id': employeeGoldSafeId
      else if (_selectedBarterGoldDepositSafeBoxId != null)
        'safe_box_id': _selectedBarterGoldDepositSafeBoxId,
      'date': DateTime.now().toIso8601String(),
      'total': barterTotal,
      'total_weight': barterWeightNet,
      'total_cost': barterTotal,
      'total_tax': 0.0,
      'payments': <Map<String, dynamic>>[],
      'amount_paid': 0.0,
      'settlement_method': 'offset',
      'items': barterItems,
    };
    return scrapInvoiceData;
  }

  double get _barterTotal {
    if (!_enableBarter) return 0.0;
    final total = _barterLines.fold<double>(
      0.0,
      (sum, line) => sum + line.value(_parseDouble, _goldPrice24k),
    );
    return double.parse(total.toStringAsFixed(2));
  }

  double get _barterTotalWeightNet {
    if (!_enableBarter) return 0.0;
    return _barterLines.fold<double>(
      0.0,
      (sum, line) => sum + line.netWeight(_parseDouble),
    );
  }

  void _ensureAtLeastOneBarterLine() {
    if (_barterLines.isNotEmpty) return;
    _barterLines.add(_BarterLine(karat: 21));
  }

  void _addBarterLine() {
    setState(() {
      _barterLines.add(_BarterLine(karat: 21));
    });
  }

  void _removeBarterLine(int index) {
    setState(() {
      final line = _barterLines.removeAt(index);
      line.dispose();
      if (_barterLines.isEmpty) {
        _enableBarter = false;
      }
    });
  }

  double get _remainingAmount {
    final remaining = _calculateGrandTotal() - _totalPayments - _barterTotal;
    // تجاهل الفروقات الصغيرة (أقل من 0.01 ${context.read<SettingsProvider>().currencySymbolText})
    return remaining.abs() < 0.01 ? 0.0 : remaining;
  }

  // ==================== Smart Input Processing ====================
  /// The piece a barcode or an item code names exactly.
  Map<String, dynamic>? _findItemByCode(String input) {
    final code = input.toLowerCase();
    for (final key in ['barcode', 'item_code']) {
      for (final item in _availableItems) {
        if (item[key]?.toString().toLowerCase() == code) return item;
      }
    }
    return null;
  }

  /// The pieces whose name holds [input]. Each piece is unique: when several
  /// share it, the seller chooses -- the first was added unseen.
  List<Map<String, dynamic>> _findItemsByName(String input) {
    final part = input.toLowerCase();
    return _availableItems
        .where(
          (item) =>
              item['name']?.toString().toLowerCase().contains(part) ?? false,
        )
        .toList();
  }

  Future<void> _processSmartInput(String input) async {
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty) return;

    if (_availableItems.isEmpty) {
      await _loadAvailableItems();
      if (_availableItems.isEmpty) {
        final message =
            _itemsLoadingError ??
            'قائمة الأصناف غير متاحة حالياً. حاول مجدداً.';
        _showError(message);
        return;
      }
    }

    try {
      var foundItem = _findItemByCode(normalizedInput);
      if (foundItem == null) {
        final byName = _findItemsByName(normalizedInput);
        if (byName.length > 1) {
          await _showItemSelectionDialog(initialQuery: normalizedInput);
          return;
        }
        if (byName.length == 1) foundItem = byName.single;
      }

      if (foundItem != null && foundItem.isNotEmpty) {
        final added = await _addItemFromData(foundItem);
        _smartInputController.clear();
        _smartInputFocus.requestFocus();

        if (added && mounted) {
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

  /// Whether the piece went into the invoice.
  Future<bool> _addItemFromData(Map<String, dynamic> itemData) async {
    if (!mounted) return false;

    final pieceName = (itemData['name'] ?? '').toString();
    final pieceId = _parseInt(itemData['id']);
    if (pieceId != null && _items.any((i) => i.id == pieceId)) {
      _showError('«$pieceName» مضافة في الفاتورة؛ كل قطعة تُباع مرة');
      return false;
    }
    // A piece is sold at its recorded weight; 10 g was put in its place.
    if (_parseDouble(itemData['weight']) <= 0) {
      _showError('«$pieceName» بلا وزن مسجّل؛ صحّح وزنها في شاشة الأصناف');
      return false;
    }

    // الحصول على الإعدادات بشكل آمن
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // تحديث سعر الذهب قبل إضافة الصنف
    try {
      final apiService = _api;
      final priceData = await apiService.getGoldPrice();
      final newPrice = _parseDouble(priceData['price_24k']);
      if (newPrice > 0) {
        if (mounted) {
          setState(() {
            _goldPrice24k = newPrice;
          });
        }
      }
    } catch (_) {
      // الاستمرار باستخدام السعر الحالي في حال فشل التحديث
    }

    // 🆕 محاولة جلب العيار من التصنيف إذا كان موجوداً
    double karat = _parseDouble(itemData['karat']);
    final categoryId = _parseInt(itemData['category_id']);
    if (karat <= 0) {
      // إذا لم يكن للصنف عيار، نحاول استخدام عيار التصنيف
      if (categoryId != null) {
        try {
          await _ensureCategoriesLoaded();
          final category = _categories.firstWhere(
            (c) => _parseInt(c['id']) == categoryId,
            orElse: () => <String, dynamic>{},
          );
          if (category.isNotEmpty && category['karat'] != null) {
            karat = _parseDouble(category['karat']);
          }
        } catch (_) {
          // في حالة الفشل، نستخدم العيار الافتراضي
        }
      }
      // إذا لم ينجح أي من ما سبق، استخدم العيار الافتراضي
      if (karat <= 0) karat = settings.mainKarat.toDouble();
    }

    double wage = _parseDouble(itemData['wage']);
    bool wageLocked = false;

    final weight = _parseDouble(itemData['weight']);

    if (!mounted) return false;

    final itemId = _parseInt(itemData['id']);
    String? categoryName = itemData['category_name'] as String?;
    if (categoryId != null) {
      try {
        await _ensureCategoriesLoaded();
        final category = _categories.firstWhere(
          (c) => _parseInt(c['id']) == categoryId,
          orElse: () => <String, dynamic>{},
        );
        if (category.isNotEmpty) {
          if (categoryName == null || categoryName.trim().isEmpty) {
            final resolvedName = (category['name'] ?? '').toString().trim();
            if (resolvedName.isNotEmpty) categoryName = resolvedName;
          }
          // إذا كان التصنيف يملك أجراً افتراضياً، يُطبَّق تلقائياً بغض النظر عن أجر الصنف
          final rawCatWage = category['default_wage'];
          final catWage = rawCatWage is num
              ? rawCatWage.toDouble()
              : double.tryParse('${rawCatWage ?? ''}');
          if (catWage != null && catWage > 0) {
            wage = catWage;
            wageLocked = true;
          }
        }
      } catch (_) {
        // ignore
      }
    }

    setState(() {
      _items.add(
        InvoiceItem(
          id: itemId,
          name: itemData['name'] ?? '',
          barcode: itemData['barcode'] ?? '',
          karat: karat,
          weight: weight,
          wage: wage,
          wageLocked: wageLocked,
          categoryId: categoryId,
          categoryName: categoryName,
          goldPrice24k: _goldPrice24k,
          mainKarat: settings.mainKarat,
          taxRate: _uiDisableVat ? 0.0 : settings.taxRateForKarat(karat),
          avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
          avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
        ),
      );
    });

    return true;
  }

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
    final countController = TextEditingController(text: '1'); // 🆕 عدد القطع
    final weightController = TextEditingController(text: '1.0');
    final wageController = TextEditingController(text: '0');
    final totalController = TextEditingController();
    final barcodeFocusNode = FocusNode();
    final countFocusNode = FocusNode();
    final weightFocusNode = FocusNode();
    final wageFocusNode = FocusNode();
    final totalFocusNode = FocusNode();

    weightController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: weightController.text.length,
    );
    wageController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageController.text.length,
    );
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

    Map<String, dynamic>? manualData;

    if (!mounted) {
      nameController.dispose();
      barcodeController.dispose();
      weightController.dispose();
      wageController.dispose();
      totalController.dispose();
      return;
    }

    manualData = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              if (!(formKey.currentState?.validate() ?? false)) {
                return;
              }

              final weight = tryParseOptionalDouble(weightController.text) ?? 0;
              final wage = tryParseOptionalDouble(wageController.text) ?? 0;
              final count = int.tryParse(countController.text) ?? 1;
              final manualTotal = tryParseOptionalDouble(totalController.text);
              // weight = الوزن الكلي للسطر كما أدخله المستخدم
              // العدد (count) توضيحي فقط ولا يُضرب بالوزن

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
                          labelText: 'العدد',
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
                          labelText: 'الوزن الكلي للسطر (جم)',
                          prefixIcon: Icon(Icons.scale),
                        ),
                        validator: (value) {
                          final parsed = tryParseOptionalDouble(value ?? '');
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
                        onFieldSubmitted: (_) => submit(),
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

    // نتجنب التخلص المباشر من المتحكمات لأن عناصر الحوار قد تستدعي إطاراً إضافياً
    // بعد الإغلاق. تركها لجمع القمامة آمن للاستخدام المؤقت هنا.
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
      count: manualData['count'] as int? ?? 1, // 🆕
      goldPrice24k: _goldPrice24k,
      mainKarat: _settingsProvider.mainKarat,
      taxRate: _uiDisableVat
          ? 0.0
          : _settingsProvider.taxRateForKarat(
              _parseDouble(manualData['karat']),
            ),
      avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
      avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
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
        SnackBar(
          content: const Text('✅ تمت إضافة صنف يدوي إلى الفاتورة'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  Future<void> _ensureCategoriesLoaded() async {
    if (_isLoadingCategories) return;
    if (_categories.isNotEmpty) return;

    setState(() {
      _isLoadingCategories = true;
      _categoriesLoadingError = null;
    });

    try {
      final api = _api;
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

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) => _CategoryLineDialog(
        categories: _categories,
        mainKarat: _settingsProvider.mainKarat,
        currencySymbol: _settingsProvider.currencySymbolText,
      ),
    );

    if (result == null || !mounted) return;

    _addCategoryLine(
      categoryId: result['categoryId'] as int?,
      categoryName: result['categoryName'] as String? ?? '',
      karat: result['karat'] as int? ?? _settingsProvider.mainKarat,
      weight: result['weight'] as double? ?? 0,
      wage: result['wage'] as double? ?? 0,
      count: (result['count'] as int?) ?? 1,
      amount: result['amount'] as double? ?? 0,
    );
  }

  /// A category line of the sale: the weight is the line's, the count a note,
  /// and the category's wage holds when it has one.
  void _addCategoryLine({
    required int? categoryId,
    required String categoryName,
    required int karat,
    required double weight,
    required double wage,
    required int count,
    required double amount,
  }) {
    if (categoryId == null || weight <= 0) return;

    final selectedCat = _categories
        .where((c) => _parseInt(c['id']) == categoryId)
        .firstOrNull;
    final catWage = selectedCat == null
        ? null
        : _parseDouble(selectedCat['default_wage']);
    final wageIsLocked = catWage != null && catWage > 0;

    setState(() {
      final item = InvoiceItem(
        id: null,
        name: categoryName.isNotEmpty ? categoryName : 'تصنيف',
        barcode: '',
        karat: karat.toDouble(),
        weight: weight,
        wage: wage,
        wageLocked: wageIsLocked,
        count: count,
        goldPrice24k: _goldPrice24k,
        mainKarat: _settingsProvider.mainKarat,
        taxRate: _uiDisableVat
            ? 0.0
            : _settingsProvider.taxRateForKarat(karat.toDouble()),
        avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
        avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
        categoryId: categoryId,
        categoryName: categoryName,
      );
      if (amount > 0) item.setManualTotal(amount);
      _items.add(item);
    });

  }

  void _addEnteredCategory(SalesCategoryEntry e) => _addCategoryLine(
    categoryId: _parseInt(e.category['id']),
    categoryName: '${e.category['name'] ?? ''}',
    karat: e.karat,
    weight: e.weight,
    wage: e.wage,
    count: e.count,
    amount: e.amount ?? 0,
  );

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
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
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
      bool requiresManualTargetRecalculation = false;

      switch (field) {
        case 'karat':
          item.karat = value;
          item.taxRate = _uiDisableVat
              ? 0.0
              : _settingsProvider.taxRateForKarat(value);
          requiresManualTargetRecalculation = true;
          break;
        case 'weight':
          item.weight = value;
          requiresManualTargetRecalculation = true;
          break;
        case 'wage':
          item.wage = value;
          requiresManualTargetRecalculation = true;
          break;
        case 'total':
          item.setManualTotal(value);
          break;
      }

      if (requiresManualTargetRecalculation) {
        _recalculateManualTargetIfNeeded(item);
      }
    });

  }

  void _recalculateManualTargetIfNeeded(InvoiceItem item) {
    if (item.hasManualTotal) {
      _recalculateFieldsForTarget(item);
    }
  }

  // إعادة حساب الحقول للوصول للإجمالي المستهدف
  void _recalculateFieldsForTarget(InvoiceItem item) {
    final manualTarget = item.manualTargetTotal;
    if (!item.hasManualTotal || manualTarget == null) return;

    final targetNet = manualTarget / (1 + item.taxRate);
    final requiredProfit = targetNet - item.cost;
    item.profit = requiredProfit;
  }

  void _removeItem(int index) {
    final removed = _items[index];
    setState(() {
      _items.removeAt(index);
    });

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('حُذف «${removed.name}»'),
        action: SnackBarAction(
          label: 'تراجع',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              _items.insert(math.min(index, _items.length), removed);
            });
          },
        ),
      ),
    );
  }

  // ==================== Auto Distribution ====================
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

  // ==================== Submit Invoice ====================
  Future<bool> _showPreSaveInvoiceSummary({
    required String customerLabel,
    required int itemsCount,
    required double total,
    required double totalWeight,
    required double totalTax,
    required double totalCost,
    required double paidCash,
    required double barterTotal,
    required double remaining,
    required bool allowPartialPayments,
  }) async {
    final currency = _settingsProvider.currencySymbolText;
    final warnings = <String>[
      if (remaining > 0.01)
        'يبقى ${remaining.toStringAsFixed(2)} $currency آجلًا على «$customerLabel»',
    ];
    final priceWarnings = salesPriceWarnings(
      lines: [
        for (final i in _items)
          SalesLineFacts(weight: i.weight, karat: i.karat),
      ],
      net: total - totalTax,
      goldPrice24k: _goldPrice24k,
      formatCash: (v) => '${v.toStringAsFixed(2)} $currency',
    );
    warnings.addAll(priceWarnings);
    if (priceWarnings.isEmpty && totalCost > 0 && total + 0.01 < totalCost) {
      warnings.add(
        'سعر البيع أقل من التكلفة وقد تحتاج الفاتورة إلى اعتماد مدير.',
      );
    }
    final lineDetails = [
      for (final item in _items)
        InvoiceSummaryMetricDetail(
          label:
              '${item.name} • ${item.karat.toStringAsFixed(0)}k • ${item.weight.toStringAsFixed(3)} جم',
          value: '${item.totalWithTax.toStringAsFixed(2)} $currency',
          accentColor: AppSemanticColors.of(context).karat(item.karat.round()).fg,
        ),
    ];
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
              : 'تمت التسوية بالكامل',
          statusTone: remaining > 0.01
              ? InvoiceSummaryStatusTone.due
              : InvoiceSummaryStatusTone.success,
          metrics: [
            InvoiceSummaryMetric(
              label: 'الإجمالي',
              value: '${total.toStringAsFixed(2)} $currency',
              icon: Icons.payments_outlined,
              accentColor: AppColors.primaryGold,
              emphasize: true,
            ),
            InvoiceSummaryMetric(
              label: 'الأصناف',
              value: '$itemsCount',
              icon: Icons.inventory_2_outlined,
              accentColor: AppColors.info,
              fullWidth: true,
              details: lineDetails,
            ),
            if (remaining > 0.01)
              InvoiceSummaryMetric(
                label: 'المتبقي',
                value: '${remaining.toStringAsFixed(2)} $currency',
                icon: Icons.pending_outlined,
                accentColor: AppColors.error,
              ),
            if (_payments.isNotEmpty)
              InvoiceSummaryMetric(
                label: 'طريقة السداد',
                value: _payments.length == 1
                    ? _payments.first.paymentMethodName
                    : '${_payments.length} وسائل دفع',
                icon: Icons.credit_card_outlined,
                accentColor: AppColors.info,
                fullWidth: true,
                highlightCard: true,
                details: [
                  for (final p in _payments)
                    InvoiceSummaryMetricDetail(
                      label: p.paymentMethodName,
                      value: '${p.amount.toStringAsFixed(2)} $currency',
                      accentColor: AppColors.info,
                    ),
                ],
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
            // ── تفاصيل ثانوية (تظهر بعد الثلاثة الأساسية عند التمرير) ──
            if (customerLabel.trim().isNotEmpty)
              InvoiceSummaryMetric(
                label: 'العميل',
                value: customerLabel.trim(),
                icon: Icons.person_outline_rounded,
                accentColor: AppColors.info,
              ),
            if (totalTax > 0)
              InvoiceSummaryMetric(
                label: 'الضريبة',
                value: '${totalTax.toStringAsFixed(2)} $currency',
                icon: Icons.receipt_long_outlined,
                accentColor: AppColors.warning,
              ),
            InvoiceSummaryMetric(
              label: 'المدفوع (نقدي)',
              value: '${paidCash.toStringAsFixed(2)} $currency',
              icon: Icons.account_balance_wallet_outlined,
              accentColor: AppColors.success,
            ),
            if (barterTotal > 0.01)
              InvoiceSummaryMetric(
                label: 'المقايضة',
                value: '${barterTotal.toStringAsFixed(2)} $currency',
                icon: Icons.swap_horiz_rounded,
                accentColor: AppColors.info,
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

  /// From the press to the server's answer, including the review: a second
  /// press saved a second invoice while the first was in flight.
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
      _showError('يرجى إضافة أصناف للفاتورة');
      return;
    }

    if (_selectedBranchId == null) {
      _showError('يرجى اختيار الفرع لإكمال الفاتورة.');
      return;
    }

    final allowPartialPayments = _settingsProvider.allowPartialInvoicePayments;

    final total = _calculateGrandTotal();
    final barterTotal = _barterTotal;
    if (barterTotal > total + 0.01) {
      _showError('قيمة المقايضة أكبر من إجمالي الفاتورة');
      return;
    }

    final totalPaidCash = _totalPayments;
    final totalPaid = totalPaidCash + barterTotal;
    final remaining = total - totalPaid;

    final totalCost = _items.fold<double>(0.0, (sum, item) => sum + item.cost);

    // منع الدفع الزائد
    if (remaining < -0.01) {
      _showError('مجموع الدفعات أكبر من إجمالي الفاتورة');
      return;
    }

    // سياسة الدفعات الجزئية
    final hasAnySettlement = _payments.isNotEmpty || barterTotal > 0.01;
    if (!hasAnySettlement && !allowPartialPayments) {
      _showError('يرجى إضافة وسيلة دفع واحدة على الأقل');
      return;
    }

    if (remaining > 0.01 && !allowPartialPayments) {
      _showError(
        'المبلغ المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}\nيرجى إكمال الدفع',
      );
      return;
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

    final totalWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );
    final totalTax = _items.fold<double>(0.0, (sum, item) => sum + item.tax);

    final proceed = await _showPreSaveInvoiceSummary(
      customerLabel: customerLabel,
      itemsCount: _items.length,
      total: total,
      totalWeight: totalWeight,
      totalTax: totalTax,
      totalCost: totalCost,
      paidCash: totalPaidCash,
      barterTotal: barterTotal,
      remaining: remaining,
      allowPartialPayments: allowPartialPayments,
    );
    if (!proceed) return;

    final suppressPostSaveApprovalWarning = false;

    try {
      final apiService = _api;

      // إذا لم يتم اختيار عميل، استخدم عميل "نقدي" (ID = 1)
      int customerId = _selectedCustomerId ?? 1;

      Map<String, dynamic>? cashCustomer = _findCashCustomer();

      if (_selectedCustomerId == null) {
        // The server keeps one: asked to create it, it returns the one there.
        cashCustomer ??= await _createCashCustomerRecord();
        if (cashCustomer == null || cashCustomer['id'] == null) {
          _showError(
            'لا يوجد عميل نقدي متاح. يرجى إنشاء عميل نقدي أو اختيار عميل محدد للمتابعة.',
          );
          return;
        }

        customerId = cashCustomer['id'];
        if (mounted) {
          setState(() {
            _selectedCustomerId = customerId;
          });
        }
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

      if (!mounted) return;

      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final sellerName = authProvider.fullName;
      final sellerEmployeeId = authProvider.currentUser?.employeeId;

      final invoiceData = {
        'customer_id': customerId,
        'branch_id': _selectedBranchId,
        'invoice_type': 'بيع',
        'transaction_type': 'sell',
        if (sellerName.isNotEmpty) 'posted_by': sellerName,
        if (sellerEmployeeId != null) 'employee_id': sellerEmployeeId,
        'date': DateTime.now().toIso8601String(),
        'total': totalAmount,
        'total_weight': totalWeight,
        'total_cost': totalCost,
        'total_tax': totalTax,
        if (_enableBarter && barterTotal > 0.01) 'barter_total': barterTotal,
        'payments': _payments.map((p) => p.toJson()).toList(),
        'amount_paid': _totalPayments,
        'items': _items.map((item) => item.toJson()).toList(),
      };

      // A barter is a sale and a purchase, saved together or not at all
      // (BARTER-001, the owner 2 Oct 2026).
      final barterPurchase = (!_isEditMode && _enableBarter && barterTotal > 0.01)
          ? _barterPurchasePayload(
              customerId: customerId,
              sellerName: sellerName,
              sellerEmployeeId: sellerEmployeeId,
              barterTotal: barterTotal,
            )
          : null;

      final response = _isEditMode
          ? await apiService.updateUnpostedInvoice(
              widget.editInvoiceId!,
              invoiceData,
            )
          : barterPurchase != null
              ? Map<String, dynamic>.from(
                  (await apiService.addBarterSale(invoiceData, barterPurchase))['sale'] as Map,
                )
              : await apiService.addInvoice(invoiceData);

      if (mounted) {
        context.read<SalesRaceRefreshProvider>().notifySaleInvoiceSaved();
      }

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

      // Editing a barter sale keeps the old two requests (a new sale is saved
      // with its purchase in one transaction above -- BARTER-001).
      if (_isEditMode && _enableBarter && barterTotal > 0.01) {
        final saleInvoiceId = response['id'];
        final scrapInvoiceData = _barterPurchasePayload(
          customerId: customerId,
          sellerName: sellerName,
          sellerEmployeeId: sellerEmployeeId,
          barterTotal: barterTotal,
        )..['barter_sale_invoice_id'] = saleInvoiceId;
        try {
          await apiService.addInvoice(scrapInvoiceData);
        } catch (e) {
          if (mounted) {
            _showError(
              'تم حفظ فاتورة البيع، لكن فشل إنشاء فاتورة شراء الكسر للمقايضة: $e',
            );
          }
        }
      }

      if (!mounted) return;

      final invoiceForPrint = Map<String, dynamic>.from(response);
      // Best-effort enrichment for print header.
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
      await _clearLocalDraft();
      if (_isEditMode) {
        // In edit mode, navigate back with success result
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('تم تعديل الفاتورة بنجاح'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.of(context).pop(true);
        }
      } else if (shouldPrint == 'new_invoice') {
        _resetAfterSave();
      } else {
        // 'done' or null → return to home
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  /// The company's one cash customer, as the server picks it (routes/
  /// customers.py): the name exactly, the active first, the oldest. A name
  /// that merely contains «نقد» is a customer, not the cash customer -- and
  /// 21 «عميل نقدي» rows on the 6 Oct copy are not 21 cash customers.
  Map<String, dynamic>? _findCashCustomer() {
    Map<String, dynamic>? best;
    int? bestId;
    var bestActive = false;
    for (final customer in widget.customers) {
      final name = (customer['name'] ?? '').toString().trim().split(
        RegExp(r'\s+'),
      ).join(' ');
      if (!_cashCustomerNames.contains(name)) continue;
      final id = _parseInt(customer['id']);
      if (id == null) continue;
      final active = customer['active'] != false;
      final better = best == null ||
          (active && !bestActive) ||
          (active == bestActive && id < bestId!);
      if (better) {
        best = {...customer, 'id': id};
        bestId = id;
        bestActive = active;
      }
    }
    return best;
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
          : 'يمكنك الطباعة أو المشاركة أو الإغلاق من هنا.',
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

  // Open AddCustomerScreen for adding a new customer (no identity enforcement for standard sales)
  Future<void> _addNewCustomer() async {
    final result = await Navigator.push<bool?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddCustomerScreen(
          api: _api,
          enforceIdentityFields: false,
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
      debugPrint('Customer added via AddCustomerScreen (sales)');
    }
  }

  Future<void> _openCameraScanner() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => _BarcodeScannerPlaceholder()),
    );

    if (barcode != null && barcode.isNotEmpty && mounted) {
      _smartInputController.text = barcode;
      await _processSmartInput(barcode);
      _smartInputFocus.requestFocus(); // إعادة التركيز للإدخال
    }
  }

  Future<void> _showItemSelectionDialog({String initialQuery = ''}) async {
    if (_availableItems.isEmpty && !_isLoadingItems) {
      await _loadAvailableItems();
    }

    if (!mounted) return;

    if (_isLoadingItems) {
      _showError('جاري تحميل قائمة الأصناف، يرجى المحاولة بعد لحظات.');
      return;
    }

    if (_availableItems.isEmpty) {
      _showError(
        _itemsLoadingError ?? 'لا توجد أصناف متاحة حالياً، حدث البيانات أولاً.',
      );
      return;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String searchQuery = initialQuery;
    final searchController = TextEditingController(text: initialQuery);
    String? karatFilter;
    String sortMode = 'weight_desc';

    String? normalizeKarat(dynamic value) {
      if (value == null) return null;
      if (value is num) {
        return value.round().toString();
      }
      final parsed = double.tryParse(value.toString());
      if (parsed == null) return null;
      return parsed.round().toString();
    }

    bool matchesSearch(Map<String, dynamic> item, String query) {
      if (query.isEmpty) return true;
      final normalized = query.toLowerCase();
      final fields = [
        item['name'],
        item['barcode'],
        item['item_code'],
        item['category_name'],
      ];
      for (final field in fields) {
        final text = field?.toString().toLowerCase();
        if (text != null && text.contains(normalized)) {
          return true;
        }
      }
      return false;
    }

    List<Map<String, dynamic>> buildFilteredItems() {
      final filtered = _availableItems.where((item) {
        final matches = matchesSearch(item, searchQuery);
        final itemKarat = normalizeKarat(item['karat']);
        final karatMatches = karatFilter == null || karatFilter == itemKarat;
        return matches && karatMatches;
      }).toList();

      int compareByWeight(Map<String, dynamic> a, Map<String, dynamic> b) {
        final weightA = _parseDouble(a['weight']);
        final weightB = _parseDouble(b['weight']);
        return weightA.compareTo(weightB);
      }

      int compareByName(Map<String, dynamic> a, Map<String, dynamic> b) {
        final nameA = (a['name'] ?? '').toString();
        final nameB = (b['name'] ?? '').toString();
        return nameA.compareTo(nameB);
      }

      switch (sortMode) {
        case 'weight_asc':
          filtered.sort(compareByWeight);
          break;
        case 'name':
          filtered.sort(compareByName);
          break;
        case 'weight_desc':
        default:
          filtered.sort((a, b) => compareByWeight(b, a));
          break;
      }

      return filtered;
    }

    final availableKarats =
        _availableItems
            .map((item) => normalizeKarat(item['karat']))
            .where((value) => value != null)
            .cast<String>()
            .toSet()
          ..removeWhere((element) => element.trim().isEmpty);
    final sortedKarats = availableKarats.toList()
      ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredItems = buildFilteredItems();
            return AlertDialog(
              title: Text(
                'اختر صنف',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 460,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        labelText: 'بحث بالاسم، الكود أو الباركود',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  searchController.clear();
                                  setDialogState(() => searchQuery = '');
                                },
                              )
                            : null,
                      ),
                      onChanged: (value) =>
                          setDialogState(() => searchQuery = value.trim()),
                    ),
                    const SizedBox(height: 12),
                    if (availableKarats.isNotEmpty) ...[
                      Text(
                        'تصفية حسب العيار',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            FilterChip(
                              label: const Text('الكل'),
                              selected: karatFilter == null,
                              onSelected: (_) =>
                                  setDialogState(() => karatFilter = null),
                            ),
                            const SizedBox(width: 8),
                            ...sortedKarats.map(
                              (karat) => Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: 8,
                                ),
                                child: FilterChip(
                                  label: Text('عيار $karat'),
                                  selected: karatFilter == karat,
                                  onSelected: (_) =>
                                      setDialogState(() => karatFilter = karat),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      'ترتيب النتائج',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('وزن أعلى'),
                          selected: sortMode == 'weight_desc',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'weight_desc'),
                        ),
                        ChoiceChip(
                          label: const Text('وزن أقل'),
                          selected: sortMode == 'weight_asc',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'weight_asc'),
                        ),
                        ChoiceChip(
                          label: const Text('أبجدي'),
                          selected: sortMode == 'name',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'name'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filteredItems.isEmpty
                          ? Center(
                              child: Text(
                                'لا توجد أصناف مطابقة لخيارات البحث الحالية',
                                style: theme.textTheme.bodySmall,
                              ),
                            )
                          : ListView.builder(
                              itemCount: filteredItems.length,
                              itemBuilder: (context, index) {
                                final item = filteredItems[index];
                                final weight = _parseDouble(item['weight']);
                                final karatLabel =
                                    item['karat']?.toString() ?? '-';
                                final barcode =
                                    item['barcode']?.toString() ?? '';
                                final code =
                                    item['item_code']?.toString() ?? '';

                                return Card(
                                  elevation: 0,
                                  color: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.4),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: colorScheme.primary
                                          .withValues(alpha: 0.12),
                                      child: Text(
                                        karatLabel,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: colorScheme.primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                    ),
                                    title: Text(
                                      item['name']?.toString() ?? 'بدون اسم',
                                    ),
                                    subtitle: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (code.isNotEmpty)
                                          Text(
                                            'الكود: $code',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        if (barcode.isNotEmpty)
                                          Text(
                                            'الباركود: $barcode',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                      ],
                                    ),
                                    trailing: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${weight.toStringAsFixed(3)} جم',
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _addItemFromData(item);
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==================== UI Build ====================
  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        final theme = Theme.of(context);
        final size = MediaQuery.of(context).size;
        final isWideLayout = size.width >= 1100;

        final bodyContent = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeyedSubtree(
              key: _customerSectionKey,
              child: _buildCustomerSection(theme),
            ),
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
                        KeyedSubtree(
                          key: _itemsSectionKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildSmartInputSection(),
                              const SizedBox(height: 24),
                              _buildDataTable(),
                            ],
                          ),
                        ),
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
                        KeyedSubtree(
                          key: _paymentSectionKey,
                          child: _buildPaymentSection(),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              KeyedSubtree(
                key: _itemsSectionKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSmartInputSection(),
                    const SizedBox(height: 24),
                    _buildDataTable(),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildSummaryCard(),
              const SizedBox(height: 24),
              KeyedSubtree(
                key: _paymentSectionKey,
                child: _buildPaymentSection(),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 32),
          ],
        );

        final readiness = _readiness();
        final scaffold = Scaffold(
          bottomNavigationBar: _buildFooter(theme, readiness),
          appBar: AppBar(
            backgroundColor: AppColors.invoiceSaleNew,
            foregroundColor: Colors.white,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(_isEditMode ? 'تعديل فاتورة البيع' : 'فاتورة البيع '),
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
                            cu.SarAwareText(
                              '${context.read<SettingsProvider>().currencySymbolText}/جم',
              isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
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
                tooltip: 'إكمال لاحقاً',
                onPressed: _completeLater,
                icon: const Icon(Icons.schedule),
              ),
              IconButton(
                tooltip: 'تحديث سعر الذهب',
                onPressed: _loadSettings,
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: 'إعدادات الفاتورة',
                onPressed: () async {
                  await InvoiceSettingsSheet.show(
                    context,
                    contextType: InvoiceUiContext.saleNew,
                    supportsVatToggle: false,
                    supportsLockEdits: true,
                    supportsAutoOpenPrint: true,
                    onChanged: (s) {
                      if (!mounted) return;
                      setState(() {
                        _uiLockPriceEdits = s.lockPriceEdits;
                        _uiAutoOpenPrintAfterSave = s.autoOpenPrintAfterSave;
                        _uiPaperSize = s.paperSize;

                        if (_uiDisableVat) {
                          for (final item in _items) {
                            item.taxRate = 0.0;
                          }
                        } else {
                          for (final item in _items) {
                            item.taxRate = _settingsProvider.taxRateForKarat(
                              item.karat,
                            );
                          }
                        }
                      });
                    },
                  );
                },
                icon: const Icon(Icons.settings),
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
                  _saveOrExplain,
              const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
                  _saveOrExplain,
              for (var n = 1; n <= 9; n++)
                SingleActivator(
                  LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + n),
                  alt: true,
                ): () => _payWithShortcut(n),
            },
            // A scope, so a field left with Enter hands focus back under
            // the shortcuts -- not to the route, where Ctrl+S is not heard.
            child: FocusScope(autofocus: true, child: scaffold),
          ),
        );
      },
    );
  }

  /// The one answer the footer and the save button read: ready only when the
  /// server would take the sale as it stands (utils/sales_readiness.dart).
  SalesReadiness _readiness() {
    final customerId = _selectedCustomerId;
    Map<String, dynamic>? customer;
    if (customerId != null) {
      for (final c in widget.customers) {
        if (_parseInt(c['id']) == customerId) customer = c;
      }
    }
    final named =
        customer != null &&
        !_cashCustomerNames.contains(_foldSpaces(customer['name']));
    return salesReadiness(
      SalesReadinessFacts(
        branchChosen: _selectedBranchId != null,
        lines: [
          for (final i in _items)
            SalesLineFacts(weight: i.weight, karat: i.karat),
        ],
        total: _calculateGrandTotal(),
        paid: _totalPayments,
        barter: _barterTotal,
        partialAllowed: _settingsProvider.allowPartialInvoicePayments,
        namedCustomer: named,
      ),
      formatCash: _formatCurrency,
    );
  }

  void _saveOrExplain() {
    if (_saving) return;
    final readiness = _readiness();
    if (readiness.isReady) {
      _submitInvoice();
    } else {
      _revealProblem(readiness);
    }
  }

  /// Brings the section holding the reason into view.
  void _revealProblem(SalesReadiness readiness) {
    final key = switch (readiness.target) {
      SalesReadinessTarget.branch ||
      SalesReadinessTarget.customer => _customerSectionKey,
      SalesReadinessTarget.items => _itemsSectionKey,
      SalesReadinessTarget.payment => _paymentSectionKey,
      SalesReadinessTarget.goldPrice || SalesReadinessTarget.none => null,
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

  /// Anything entered that leaving would lose.
  bool get _hasUnsavedWork =>
      _items.isNotEmpty || _payments.isNotEmpty || _barterLines.isNotEmpty;

  /// Back, the system gesture, the app bar arrow: leave at once when nothing
  /// was entered, otherwise ask -- the invoice is lost with the screen.
  Future<void> _confirmLeave() async {
    if (_saving) return;
    if (!_hasUnsavedWork) {
      Navigator.of(context).pop();
      return;
    }
    final canKeepForLater = !_isEditMode;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('فاتورة غير محفوظة'),
        content: const Text(
          'في الفاتورة أصناف أو مبالغ لم تُحفظ. ماذا تريد أن تفعل؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('stay'),
            child: const Text('متابعة التحرير'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text('خروج دون حفظ'),
          ),
          if (canKeepForLater)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('later'),
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

  /// What stands between the seller and a saved sale, and the button that
  /// saves it -- always in view, never a message that passes.
  Widget _buildFooter(ThemeData theme, SalesReadiness readiness) {
    final colorScheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final ready = readiness.isReady;
    final empty = readiness.kind == SalesReadinessKind.empty;
    final tone = ready ? tones.ready : (empty ? tones.info : tones.blocked);
    final remaining = _remainingAmount;
    final onCredit = ready && remaining > 0.01;
    final text = _saving
        ? 'جارٍ الحفظ…'
        : ready
        ? (onCredit
              ? 'جاهز للحفظ — يبقى ${_formatCurrency(remaining)} آجلًا'
              : 'جاهز للحفظ')
        : empty
        ? readiness.message
        : 'غير جاهز للحفظ — ${readiness.message}';
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: ready ? null : () => _revealProblem(readiness),
                  child: Row(
                    children: [
                      Icon(
                        ready
                            ? Icons.check_circle
                            : (empty
                                  ? Icons.info_outline
                                  : Icons.error_outline),
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

  bool get _seesCost => context.read<AuthProvider>().hasPermission('costing.view');

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
              SearchablePickerField(
                labelText: 'اختر العميل',
                valueText: _selectedCustomerDisplay(),
                hintText: 'اضغط للبحث والاختيار',
                prefixIcon: Icons.people,
                enabled: widget.customers.isNotEmpty,
                onTap: _pickCustomer,
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
          ],
        ),
      ),
    );
  }

  // ==================== Smart Input Section ====================
  Widget _buildSmartInputSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final allowManualItems = _settingsProvider.allowManualInvoiceItems;

    final entryRow = allowManualItems && _categories.isNotEmpty
        ? Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'سطر تصنيف',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'اختر التصنيف واكتب وزنه الكلي: Enter يضيف السطر.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    SalesCategoryEntryRow(
                      categories: _categories,
                      mainKarat: _settingsProvider.mainKarat,
                      onAdd: _addEnteredCategory,
                    ),
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [entryRow, _buildSmartInputBox(theme, colorScheme, allowManualItems)],
    );
  }

  Widget _buildSmartInputBox(
    ThemeData theme,
    ColorScheme colorScheme,
    bool allowManualItems,
  ) {
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
                allowManualItems ? AppColors.warning : theme.disabledColor,
                allowManualItems
                    ? 'إضافة صنف يدوي'
                    : 'فعّل من الإعدادات لإضافة صنف يدوي',
                allowManualItems
                    ? _showManualItemDialog
                    : _showManualItemFeatureGuide,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.category,
                allowManualItems ? AppColors.primaryGold : theme.disabledColor,
                allowManualItems
                    ? 'سطر تصنيف'
                    : 'فعّل من الإعدادات لإضافة سطر تصنيف',
                allowManualItems
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
          if (_isLoadingItems)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'جاري تحميل قائمة الأصناف...',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            )
          else if (_itemsLoadingError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _itemsLoadingError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
          DataColumn(label: Text('العدد', style: headerStyle)),
          DataColumn(label: Text('العيار', style: headerStyle)),
          DataColumn(label: Text('الوزن (جم)', style: headerStyle)),
          DataColumn(label: Text('المصنعية', style: headerStyle)),
          DataColumn(label: Text('السعر/جم', style: headerStyle)),
          // The cost is costing.view's (ADR-036): the seller sells without it.
          if (_seesCost) DataColumn(label: Text('التكلفة', style: headerStyle)),
          // With VAT off for the company (SALES-VAT-1) net is the total and
          // tax is zero: two columns saying nothing, that pushed the actions
          // out of view.
          if (!_uiDisableVat) ...[
            DataColumn(label: Text('الصافي', style: headerStyle)),
            DataColumn(label: Text('الضريبة', style: headerStyle)),
          ],
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
              DataCell(Text('${item.count}', style: cellStyle)),
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
                _uiLockPriceEdits
                    ? Text(item.weight.toStringAsFixed(3), style: cellStyle)
                    : InlineNumberCell(
                        key: ObjectKey(item),
                        value: item.weight,
                        fractionDigits: 3,
                        allowZero: false,
                        label: 'الوزن',
                        onChanged: (v) => _updateItem(index, 'weight', v),
                      ),
              ),
              DataCell(
                (item.wageLocked || _uiLockPriceEdits)
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.wageLocked)
                            const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.lock, size: 11),
                            ),
                          Text(item.wage.toStringAsFixed(2), style: cellStyle),
                        ],
                      )
                    : InlineNumberCell(
                        key: ObjectKey(item),
                        value: item.wage,
                        fractionDigits: 2,
                        label: 'المصنعية',
                        onChanged: (v) => _updateItem(index, 'wage', v),
                      ),
              ),
              DataCell(
                Text(
                  item.calculateSellingPricePerGram().toStringAsFixed(2),
                  style: cellStyle,
                ),
              ),
              if (_seesCost)
                DataCell(Text(item.cost.toStringAsFixed(2), style: cellStyle)),
              if (!_uiDisableVat) ...[
                DataCell(Text(item.net.toStringAsFixed(2), style: cellStyle)),
                DataCell(Text(item.tax.toStringAsFixed(2), style: cellStyle)),
              ],
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
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.delete,
                        size: 22,
                        color: AppColors.error,
                      ),
                      onPressed: () => _removeItem(index),
                      tooltip: 'حذف',
                    ),
                  ],
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

    /// Why the typed value is not taken, or null when it is.
    String? refusal(double? value) {
      if (value == null) return 'اكتب رقمًا';
      switch (field) {
        case 'karat':
          return const [18.0, 21.0, 22.0, 24.0].contains(value)
              ? null
              : 'العيار 18 أو 21 أو 22 أو 24';
        case 'weight':
        case 'total':
          return value > 0 ? null : 'أكبر من صفر';
        default:
          return value >= 0 ? null : 'لا يكون سالبًا';
      }
    }

    String? error;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void take() {
            final value = _readNumber(controller.text);
            final why = refusal(value);
            if (why != null) {
              setDialogState(() => error = why);
              return;
            }
            _updateItem(index, field, value!);
            Navigator.pop(context);
          }

          return AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [NormalizeNumberFormatter()],
              onTap: () => controller.selection = TextSelection(
                baseOffset: 0,
                extentOffset: controller.text.length,
              ),
              decoration: InputDecoration(
                labelText: label,
                errorText: error,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onSubmitted: (_) => take(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
              ElevatedButton(
                onPressed: take,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                ),
                child: const Text('حفظ'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ==================== Summary ====================
  /// The total, what is paid and what remains, said once -- they were three
  /// cards and two headers. The target amount spreads a price over the lines.
  Widget _buildSummaryCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currency = _settingsProvider.currencySymbolText;
    final tones = AppSemanticColors.of(context);
    final total = _calculateGrandTotal();
    final remaining = _remainingAmount;
    final weight = _items.fold<double>(0.0, (sum, i) => sum + i.weight);
    final weight24 = _items.fold<double>(
      0.0,
      (sum, i) => sum + (i.weight * (i.karat / 24.0)),
    );

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
              '${_items.length} صنف • الوزن ${weight.toStringAsFixed(3)} جم • معادل 24: ${weight24.toStringAsFixed(3)} جم',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (!_uiDisableVat)
              row(
                'ضريبة القيمة المضافة',
                '${_calculateTotalVAT().toStringAsFixed(2)} $currency',
              ),
            row(
              'المدفوع',
              '${_totalPayments.toStringAsFixed(2)} $currency',
            ),
            if (_barterTotal > 0.01)
              row(
                'المقايضة',
                '${_barterTotal.toStringAsFixed(2)} $currency',
              ),
            if (_totalCommission > 0) ...[
              row(
                'إجمالي العمولات',
                '${_totalCommission.toStringAsFixed(2)} $currency',
                color: tones.warning.fg,
              ),
              row(
                'صافي المستلم',
                '${_totalNet.toStringAsFixed(2)} $currency',
                color: tones.ready.fg,
              ),
            ],
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

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final employeeGoldSafesEnabled =
        _settingsProvider.settings['employee_gold_safes_enabled'] == true;
    final employeeGoldSafeId =
        authProvider.currentUser?.employee?.goldSafeBoxId;
    final hideBarterGoldDepositSafe =
        employeeGoldSafesEnabled && employeeGoldSafeId != null;
    final showBarterGoldDepositSafeDropdown =
        employeeGoldSafesEnabled && employeeGoldSafeId == null;

    final mainScrapIdRaw =
        _settingsProvider.settings['main_scrap_gold_safe_box_id'];
    final mainScrapGoldSafeBoxId = mainScrapIdRaw is int
        ? mainScrapIdRaw
        : int.tryParse(mainScrapIdRaw?.toString() ?? '');

    String? safeNameById(int? id) {
      if (id == null) return null;
      for (final b in _barterGoldDepositSafeBoxes) {
        if (b.id == id) return b.name;
      }
      return null;
    }

    final selectedDepositSafeName = safeNameById(
      _selectedBarterGoldDepositSafeBoxId,
    );
    final mainScrapSafeName = safeNameById(mainScrapGoldSafeBoxId);
    final resolvedDepositSafeName =
        selectedDepositSafeName ?? mainScrapSafeName ?? 'الخزنة الرئيسية للكسر';

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
            if (_items.isNotEmpty && _remainingAmount > 0.01) ...[
              const SizedBox(height: 12),
              _buildPayBox(theme),
            ],
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
                                  if (payment.safeBoxId != null)
                                    InkWell(
                                      onTap: () => _changePaymentSafe(index),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              _safeNames[payment.safeBoxId] ??
                                                  'خزينة ${payment.safeBoxId}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    decoration: TextDecoration
                                                        .underline,
                                                  ),
                                            ),
                                          ),
                                          const Icon(Icons.edit, size: 12),
                                        ],
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

            // 🆕 مقايضة ذهب كسر داخل وسائل الدفع
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primaryGold.withValues(
                  alpha: isDark ? 0.12 : 0.10,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primaryGold.withValues(alpha: 0.35),
                  width: 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.swap_horiz,
                            color: AppColors.primaryGold,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'مقايضة ذهب كسر',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: _enableBarter,
                        onChanged: (value) {
                          setState(() {
                            _enableBarter = value;
                            if (value) {
                              _ensureAtLeastOneBarterLine();
                            } else {
                              for (final line in _barterLines) {
                                line.dispose();
                              }
                              _barterLines.clear();
                            }
                          });

                          if (value) {
                            _loadBarterGoldDepositSafeBoxesIfNeeded();
                          }
                        },
                      ),
                    ],
                  ),
                  if (_enableBarter) ...[
                    const SizedBox(height: 12),
                    if (hideBarterGoldDepositSafe)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: isDark ? 0.25 : 0.35,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'سيتم إيداع الذهب في خزنتك الشخصية تلقائياً',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (showBarterGoldDepositSafeDropdown) ...[
                      if (!hideBarterGoldDepositSafe)
                        const SizedBox(height: 10),
                      if (_isLoadingBarterGoldDepositSafeBoxes)
                        const LinearProgressIndicator(minHeight: 3),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                        value: _selectedBarterGoldDepositSafeBoxId,
                        decoration: const InputDecoration(
                          labelText: 'خزينة إيداع ذهب المقايضة',
                          border: OutlineInputBorder(),
                        ),
                        items: _barterGoldDepositSafeBoxes
                            .where((b) => b.id != null)
                            .map(
                              (box) => DropdownMenuItem<int>(
                                value: box.id!,
                                child: Text(box.name),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedBarterGoldDepositSafeBoxId = value;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(
                            alpha: isDark ? 0.18 : 0.12,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'سيتم الإيداع في: $resolvedDepositSafeName لعدم وجود خزنة ذهب خاصة بك.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _addBarterLine,
                        icon: const Icon(Icons.add),
                        label: const Text('إضافة ذهب مقايضة'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...List.generate(_barterLines.length, (index) {
                      final line = _barterLines[index];
                      final net = line.netWeight(_parseDouble);
                      final value = line.value(_parseDouble, _goldPrice24k);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.primaryGold.withValues(
                              alpha: 0.25,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: line.karat,
                                    decoration: const InputDecoration(
                                      labelText: 'العيار',
                                    ),
                                    items: const [18, 21, 22, 24]
                                        .map(
                                          (k) => DropdownMenuItem<int>(
                                            value: k,
                                            child: Text('$k'),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(() {
                                        line.karat = value;
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                IconButton(
                                  tooltip: 'حذف',
                                  onPressed: _barterLines.length <= 1
                                      ? null
                                      : () => _removeBarterLine(index),
                                  icon: const Icon(Icons.delete_outline),
                                  color: AppColors.error,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: line.standingController,
                                    decoration: const InputDecoration(
                                      labelText: 'الوزن القائم (جم)',
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: line.stonesController,
                                    decoration: const InputDecoration(
                                      labelText: 'وزن الفصوص (جم)',
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: line.pricePerGramController,
                                    decoration: InputDecoration(
                                      labelText: 'سعر الشراء/جرام',
                                      suffixText:
                                          _settingsProvider.currencySymbolText,
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (value) {
                                      setState(() {
                                        // حساب المبلغ الإجمالي من السعر/جرام
                                        final price = _parseDouble(value);
                                        if (price > 0 && net > 0) {
                                          line.totalAmountController.text =
                                              (price * net).toStringAsFixed(2);
                                        }
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: line.totalAmountController,
                                    decoration: InputDecoration(
                                      labelText: 'المبلغ الإجمالي',
                                      suffixText:
                                          _settingsProvider.currencySymbolText,
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (value) {
                                      setState(() {
                                        // حساب السعر/جرام من المبلغ الإجمالي
                                        final total = _parseDouble(value);
                                        if (total > 0 && net > 0) {
                                          line.pricePerGramController.text =
                                              (total / net).toStringAsFixed(2);
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'الصافي: ${net.toStringAsFixed(3)} جم',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                _settingsProvider.buildText(
                                  'القيمة: ${value.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryGold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'إجمالي المقايضة:',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        _settingsProvider.buildText(
                          '${_barterTotal.toStringAsFixed(2)} ${_settingsProvider.currencySymbolText}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryGold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

          ],
        ),
      ),
    );
  }

  /// One way to pay (SALES-UX-4): type an amount -- or leave it, for what
  /// remains -- and press the method. Two typed, the last presses for the
  /// rest: any number of methods, one press each. 806 of the 827 sales since
  /// June are paid by one or two; «نقداً + مدى» is the common pair.
  Widget _buildPayBox(ThemeData theme) {
    final tones = AppSemanticColors.of(context);
    final currency = _settingsProvider.currencySymbolText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _customAmountController,
          inputFormatters: [
            NormalizeNumberFormatter(),
            FilteringTextInputFormatter.deny(RegExp('[,،]')),
            FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$')),
          ],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'المبلغ',
            hintText: _remainingAmount.toStringAsFixed(2),
            helperText: 'فارغًا يُدفع المتبقي كله',
            suffixText: currency,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _paymentMethods.length; i++)
              _payButton(_paymentMethods[i], prominent: i < 2, shortcut: i + 1),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: tones.warning.container,
            borderRadius: BorderRadius.circular(6),
          ),
          child: _settingsProvider.buildText(
            'المتبقي: ${_remainingAmount.toStringAsFixed(2)} $currency',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tones.warning.onContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  /// A method's button; the first two in the settings' order stand out.
  Widget _payButton(
    Map<String, dynamic> method, {
    required bool prominent,
    required int shortcut,
  }) {
    final rate = method['commission_rate'] ?? 0;
    final label = Text(
      // The rate isolated left-to-right: «(0.8%)», not «(%0.8)».
      '${method['name'] ?? ''}${rate > 0 ? ' (\u2066$rate%\u2069)' : ''}',
    );
    final icon = Icon(_getPaymentIcon(method['payment_type'] ?? ''), size: 18);
    final key = Key('quick-pay-${method['id']}');
    void press() => _payWith(method['id'] as int);
    final button = prominent
        ? FilledButton.icon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
          );
    return shortcut <= 9
        ? Tooltip(message: 'Alt+$shortcut', child: button)
        : button;
  }

  /// Alt+1 … Alt+9: the methods in the settings' order.
  void _payWithShortcut(int n) {
    if (n > _paymentMethods.length) return;
    if (_items.isEmpty || _remainingAmount <= 0.01) return;
    _payWith(_paymentMethods[n - 1]['id'] as int);
  }

  /// The safes a method's payment may go to: cash to cash, others to the
  /// bank or a clearing safe (cheques to the bank or the cheques safe).
  List<SafeBoxModel> _compatibleSafes(
    String paymentType,
    List<SafeBoxModel> all,
  ) {
    switch (paymentType) {
      case 'cash':
        return all.where((b) => b.safeType == 'cash').toList();
      case 'check':
        return all
            .where((b) => b.safeType == 'bank' || b.safeType == 'check')
            .toList();
      default:
        return all
            .where((b) => b.safeType == 'bank' || b.safeType == 'clearing')
            .toList();
    }
  }

  /// A payment's safe, changed on its line after it is added.
  Future<void> _changePaymentSafe(int index) async {
    final payment = _payments[index];
    final method = _paymentMethods.firstWhere(
      (m) => m['id'] == payment.paymentMethodId,
      orElse: () => const {},
    );
    final all = await _api.getSafeBoxes();
    if (!mounted) return;
    final options = _compatibleSafes(
      (method['payment_type'] ?? '').toString(),
      all,
    ).where((b) => b.id != null && b.isActive).toList();
    for (final b in options) {
      _safeNames[b.id!] = b.name;
    }
    if (options.isEmpty) {
      _showError('لا خزائن أخرى لهذه الوسيلة');
      return;
    }
    final chosen = await showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('خزينة الدفعة'),
        children: [
          for (final b in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(b.id),
              child: Row(
                children: [
                  Icon(
                    b.id == payment.safeBoxId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(b.name),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => payment.safeBoxId = chosen);
  }
}

// ==================== Invoice Item Model ====================
class InvoiceItem {
  final int? id;
  final String name;
  final String barcode;
  double karat;
  double weight;
  double wage; // أجور المصنعية للجرام الواحد
  final bool wageLocked; // محدد من التصنيف — غير قابل للتعديل
  final int? categoryId;
  final String? categoryName;
  double goldPrice24k;
  final int mainKarat;
  double taxRate;
  int count; // 🆕 عدد القطع لهذا الصنف
  double _avgGoldCostPerMainGram;
  double _avgManufacturingCostPerMainGram;

  // الربح الموزع (يتم حسابه في _distributeAmount)
  double profit = 0.0;

  // علامة لتتبع إذا تم تحديد الإجمالي يدوياً
  bool _hasManualTotal = false;
  double? _targetTotal;

  bool get hasManualTotal => _hasManualTotal && _targetTotal != null;
  double? get manualTargetTotal => _targetTotal;

  InvoiceItem({
    this.id,
    required this.name,
    required this.barcode,
    required this.karat,
    required this.weight,
    required this.wage,
    this.wageLocked = false,
    this.categoryId,
    this.categoryName,
    this.count = 1,
    required this.goldPrice24k,
    required this.mainKarat,
    required this.taxRate,
    required double avgGoldCostPerMainGram,
    required double avgManufacturingCostPerMainGram,
  }) : _avgGoldCostPerMainGram = avgGoldCostPerMainGram,
       _avgManufacturingCostPerMainGram = avgManufacturingCostPerMainGram;

  // حساب سعر الجرام الخام (سعر الذهب فقط حسب العيار)
  double calculatePricePerGram() {
    return goldPrice24k * (karat / 24.0);
  }

  double get weightInMainKarat {
    if (mainKarat <= 0) return weight;
    return weight * (karat / mainKarat);
  }

  // التكلفة = تكلفة الذهب + تكلفة التصنيع
  // تكلفة الذهب: إما من المتوسط المتحرك أو من سعر الذهب الحالي
  // تكلفة التصنيع: دائماً من المصنعية الفعلية للسطر (wage)
  double get cost {
    final goldCost = _avgGoldCostPerMainGram > 0
        ? weightInMainKarat * _avgGoldCostPerMainGram
        : weight * calculatePricePerGram();
    return goldCost + weight * wage;
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

  void updateCostingSnapshot({
    required double avgGoldPerMainGram,
    required double avgManufacturingPerMainGram,
  }) {
    _avgGoldCostPerMainGram = avgGoldPerMainGram;
    _avgManufacturingCostPerMainGram = avgManufacturingPerMainGram;
  }

  void updateGoldPrice(double newPrice) {
    goldPrice24k = newPrice;
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'item_id': id,
      'name': name,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      if (categoryId != null) 'category_id': categoryId,
      'cost': cost,
      'profit': profit,
      'net': net,
      'tax': tax,
      'price': totalWithTax, // الـ backend يتوقع 'price' بدلاً من 'total'
      'quantity': count, // 🆕 عدد فعلي
      'calculated_selling_price_per_gram': calculateSellingPricePerGram(),
      'avg_manufacturing_cost_per_gram': _avgManufacturingCostPerMainGram,
    };
  }
}

// ==================== Category Line Dialog Widget ====================
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
  String _searchQuery = '';
  bool _wageLockedByCategory = false;
  bool _karatLockedByCategory = false;

  @override
  void initState() {
    super.initState();
    _selectedKarat = widget.mainKarat;
    // pre-select all text so typing immediately replaces the default
    for (final c in [_weightController, _wageController, _countController]) {
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
    }
  }

  void _applyCategoryDefaults(Map<String, dynamic> category) {
    final rawWage = category['default_wage'];
    final wage = rawWage is num ? rawWage.toDouble() : double.tryParse('${rawWage ?? ''}');
    if (wage != null && wage > 0) {
      _wageController.text = wage.toStringAsFixed(wage.truncateToDouble() == wage ? 0 : 2);
      _wageLockedByCategory = true;
    } else {
      _wageLockedByCategory = false;
    }
    final categoryKarat = _tryParseCategoryKarat(category);
    if (categoryKarat != null) {
      _selectedKarat = categoryKarat;
      _karatLockedByCategory = true;
    } else {
      _karatLockedByCategory = false;
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
    setState(() {
      _selectedCategory = first;
      _applyCategoryDefaults(first);
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final categoryId = (_selectedCategory?['id'] is num)
        ? (_selectedCategory?['id'] as num).toInt()
        : int.tryParse('${_selectedCategory?['id']}');
    final categoryName = (_selectedCategory?['name'] ?? '').toString().trim();
    final weight = _tryParseDouble(_weightController.text, 0);
    final wage = _tryParseDouble(_wageController.text, 0);
    final count = int.tryParse(_countController.text.trim()) ?? 0;
    final amount = _tryParseDouble(_amountController.text, 0);

    if (count < 1) {
      _countFocusNode.requestFocus();
      _countController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _countController.text.length,
      );
      return;
    }

    if (categoryId == null || weight <= 0) return;

    Navigator.pop(context, {
      'categoryId': categoryId,
      'categoryName': categoryName,
      'karat': _selectedKarat,
      'weight': weight,
      'wage': wage,
      'count': count,
      'amount': amount,
    });
  }

  int? _tryParseCategoryKarat(Map<String, dynamic> category) {
    final raw = category['karat'];
    final parsed = int.tryParse('${raw ?? ''}');
    if (parsed == null) return null;
    if (const [18, 21, 22, 24].contains(parsed)) return parsed;
    return null;
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
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFFD4AF37,
                            ).withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
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
                      // Search field
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        onChanged: (v) {
                          setState(() {
                            _searchQuery = v.trim().toLowerCase();
                          });
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
                      // Categories list
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
                                            const SizedBox(height: 4),
                                            Text(
                                              'جرب البحث بكلمة أخرى',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: theme.disabledColor,
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
                                              ((_selectedCategory?['id'] is num)
                                                  ? (_selectedCategory?['id']
                                                                as num)
                                                            .toInt() ==
                                                        id
                                                  : int.tryParse(
                                                          '${_selectedCategory?['id']}',
                                                        ) ==
                                                        id);

                                          return Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 6,
                                            ),
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                onTap: () {
                                                  setState(() {
                                                    _selectedCategory = opt;
                                                    _applyCategoryDefaults(opt);
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
                                                          ).withValues(
                                                            alpha: 0.2,
                                                          )
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
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.all(
                                                              6,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: isSelected
                                                              ? const Color(
                                                                  0xFFD4AF37,
                                                                ).withValues(
                                                                  alpha: 0.3,
                                                                )
                                                              : theme
                                                                    .colorScheme
                                                                    .surface,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                6,
                                                              ),
                                                        ),
                                                        child: Icon(
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
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          name,
                                                          style: TextStyle(
                                                            fontSize: 15,
                                                            fontWeight:
                                                                isSelected
                                                                ? FontWeight
                                                                      .bold
                                                                : FontWeight
                                                                      .w500,
                                                            color: isSelected
                                                                ? theme
                                                                      .colorScheme
                                                                      .onSurface
                                                                : null,
                                                          ),
                                                        ),
                                                      ),
                                                      if (isSelected)
                                                        Container(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                2,
                                                              ),
                                                          decoration:
                                                              const BoxDecoration(
                                                                color: Color(
                                                                  0xFFD4AF37,
                                                                ),
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                          child: const Icon(
                                                            Icons.check,
                                                            color: Colors.white,
                                                            size: 18,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
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
                      // Karat, Weight, Wage in a grid
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
                            : (v) => setState(() {
                                _selectedKarat = v ?? _selectedKarat;
                              }),
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
                                labelText: 'الوزن الكلي للسطر (جم)',
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
                              focusNode: _wageLockedByCategory ? null : _wageFocusNode,
                              readOnly: _wageLockedByCategory,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _focusAndSelect(
                                _countFocusNode,
                                _countController,
                              ),
                              onTap: _wageLockedByCategory
                                  ? null
                                  : () => _wageController.selection =
                                        TextSelection(
                                          baseOffset: 0,
                                          extentOffset:
                                              _wageController.text.length,
                                        ),
                              style: TextStyle(
                                color: _wageLockedByCategory
                                    ? theme.colorScheme.primary
                                    : null,
                                fontWeight: _wageLockedByCategory
                                    ? FontWeight.bold
                                    : null,
                              ),
                              decoration: InputDecoration(
                                labelText: 'المصنعية/جم',
                                hintText: '0',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: Icon(
                                  _wageLockedByCategory
                                      ? Icons.lock
                                      : Icons.build,
                                  size: 20,
                                  color: _wageLockedByCategory
                                      ? theme.colorScheme.primary
                                      : null,
                                ),
                                filled: true,
                                fillColor: _wageLockedByCategory
                                    ? theme.colorScheme.primary.withValues(alpha: 0.07)
                                    : theme.colorScheme.surface,
                                helperText: _wageLockedByCategory
                                    ? 'محدد من التصنيف'
                                    : null,
                                helperStyle: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontSize: 11,
                                ),
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
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFD4AF37,
                          ).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(
                              0xFFD4AF37,
                            ).withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFD4AF37,
                                ).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Color(0xFFD4AF37),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'لا يتطلب باركود • يُستخدم للتتبع حسب التصنيف فقط',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                  height: 1.4,
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
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
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
                        elevation: 2,
                        shadowColor: const Color(
                          0xFFD4AF37,
                        ).withValues(alpha: 0.4),
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
                if (code != null && code.isNotEmpty) {
                  _isProcessing = true; // تعليم كـ "قيد المعالجة"
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
  int? safeBoxId; // 🆕 معرف الخزينة

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
    this.safeBoxId, // 🆕
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
      if (safeBoxId != null) 'safe_box_id': safeBoxId, // 🆕
    };
  }
}

class _BarterLine {
  int karat;
  final TextEditingController standingController = TextEditingController();
  final TextEditingController stonesController = TextEditingController();
  final TextEditingController pricePerGramController = TextEditingController();
  final TextEditingController totalAmountController = TextEditingController();

  _BarterLine({required this.karat});

  double standingWeight(double Function(dynamic) parseDouble) =>
      parseDouble(standingController.text);

  double stonesWeight(double Function(dynamic) parseDouble) =>
      parseDouble(stonesController.text);

  double netWeight(double Function(dynamic) parseDouble) {
    final standing = standingWeight(parseDouble);
    final stones = stonesWeight(parseDouble);
    final net = standing - stones;
    return net < 0 ? 0.0 : net;
  }

  double pricePerGram(double Function(dynamic) parseDouble) =>
      parseDouble(pricePerGramController.text);

  double effectivePricePerGram(
    double Function(dynamic) parseDouble,
    double goldPrice24k,
  ) {
    final entered = pricePerGram(parseDouble);
    if (entered > 0) return entered;
    if (goldPrice24k <= 0) return 0.0;
    return goldPrice24k * (karat / 24.0);
  }

  double value(double Function(dynamic) parseDouble, double goldPrice24k) {
    final v =
        netWeight(parseDouble) *
        effectivePricePerGram(parseDouble, goldPrice24k);
    return double.tryParse(v.toStringAsFixed(2)) ?? 0.0;
  }

  void dispose() {
    standingController.dispose();
    stonesController.dispose();
    pricePerGramController.dispose();
    totalAmountController.dispose();
  }
}
