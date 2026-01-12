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
import 'add_supplier_screen.dart';
import 'invoice_print_screen.dart';
import '../utils.dart';

enum _PurchaseSettlementMode { credit, barter, partial }

class PurchaseInvoiceScreen extends StatefulWidget {
  final int? supplierId;

  const PurchaseInvoiceScreen({super.key, this.supplierId});

  @override
  State<PurchaseInvoiceScreen> createState() => _PurchaseInvoiceScreenState();
}

class _PurchaseInvoiceScreenState extends State<PurchaseInvoiceScreen> {
  static const _prefKeyPurchaseApplyVatOnGold =
      'purchase_invoice.apply_vat_on_gold';
  static const _prefKeyPurchaseWagePostingMode =
      'purchase_invoice.wage_posting_mode';

  final ApiService _api = ApiService();

  bool _manualPricing = false;
  bool _applyVatOnGold = false;
  String _wagePostingMode = 'inventory';
  bool _wagePostingModeFromPrefs = false;
  bool _isLoadingSuppliers = false;
  bool _isSavingInvoice = false;
  bool _showAdvancedPaymentOptions = false;

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
    setState(() {
      _selectedSupplierId = null;
      _karatLines = [];
      _inlineItems = [];
      _showAdvancedPaymentOptions = false;
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _supplierError = null;

      _settlementMode = _PurchaseSettlementMode.credit;
      _cashPaidController.clear();
      _goldPaidWeightController.clear();
      _selectedGoldSafeBoxId = null;
      _selectedGoldPaidKarat = _mainKaratFromSettings();
      _applyTotals(_KaratTotals.zero);
    });
  }

  double _vatRateFromSettings() {
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
    final normalized = normalizeNumber(_goldPaidWeightController.text).trim();
    return _round(_toDouble(normalized), 3);
  }

  double _goldPaidMainEquivalent() {
    final paidWeight = _goldPaidWeight();
    if (paidWeight <= 0) return 0.0;
    final karat = _selectedGoldPaidKarat;
    final mainKarat = _mainKaratFromSettings();
    if (karat <= 0 || mainKarat <= 0) return 0.0;
    return _round(paidWeight * (karat / mainKarat), 3);
  }

  Future<void> _loadGoldSafeBoxes() async {
    try {
      final allBoxes = await _api.getSafeBoxes();
      if (!mounted) return;

      final goldBoxes = allBoxes
          .where((box) => box.safeType == 'gold')
          .toList();
      setState(() {
        _goldSafeBoxes = goldBoxes;

        final mainKarat = _mainKaratFromSettings();
        if (_selectedGoldPaidKarat <= 0) {
          _selectedGoldPaidKarat = mainKarat;
        }

        if (_selectedGoldSafeBoxId == null && _goldSafeBoxes.isNotEmpty) {
          final defaultBox = _goldSafeBoxes.firstWhere(
            (box) => box.isDefault == true && box.id != null,
            orElse: () => _goldSafeBoxes.first,
          );
          _selectedGoldSafeBoxId = defaultBox.id;
        }
      });
    } catch (e) {
      debugPrint('فشل تحميل خزائن الذهب: $e');
    }
  }

  void _setSettlementMode(_PurchaseSettlementMode mode) {
    if (mode == _settlementMode) return;

    setState(() {
      _settlementMode = mode;

      final mainKarat = _mainKaratFromSettings();
      _selectedGoldPaidKarat = mainKarat;

      if (mode == _PurchaseSettlementMode.partial) {
        final dueCash = _cashDueForSupplier();
        _cashPaidController.text = dueCash > 0
            ? dueCash.toStringAsFixed(2)
            : '';
        _goldPaidWeightController.text = '';
      } else if (mode == _PurchaseSettlementMode.barter) {
        _cashPaidController.text = '';
        final dueGoldMain = _supplierMainEquivalentWeight();
        _goldPaidWeightController.text = dueGoldMain > 0
            ? dueGoldMain.toStringAsFixed(3)
            : '';
      } else {
        _cashPaidController.text = '';
        _goldPaidWeightController.text = '';
      }
    });

    if (mode != _PurchaseSettlementMode.credit && _goldSafeBoxes.isEmpty) {
      _loadGoldSafeBoxes();
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedSupplierId = widget.supplierId;
    _loadUiDefaultsFromPrefs();
    _loadBranches();
    _loadSuppliers();
    _loadCategories();
    _loadGoldPrice();
    _loadPaymentMethods();
    _loadGoldSafeBoxes();
    _loadSettings();
    _applyTotals(_KaratTotals.zero);
  }

  Future<void> _loadUiDefaultsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final applyVatPref = prefs.getBool(_prefKeyPurchaseApplyVatOnGold);
      final wageModePref = prefs.getString(_prefKeyPurchaseWagePostingMode);

      if (!mounted) return;
      setState(() {
        if (applyVatPref != null) {
          _applyVatOnGold = applyVatPref;
        }
        if (wageModePref != null &&
            (wageModePref == 'inventory' || wageModePref == 'expense')) {
          _wagePostingMode = wageModePref;
          _wagePostingModeFromPrefs = true;
        } else {
          // Keep the requested defaults for purchases and prevent server
          // settings from overriding them unless the user explicitly changes.
          _wagePostingModeFromPrefs = true;
        }
      });

      if (!mounted) return;
      _applyCombinedTotals();
    } catch (_) {
      // ignore preferences failures
    }
  }

  Future<void> _persistApplyVatOnGold(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyPurchaseApplyVatOnGold, value);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _persistWagePostingMode(String mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyPurchaseWagePostingMode, mode);
    } catch (_) {
      // ignore
    }
  }

  @override
  void dispose() {
    _cashPaidController.dispose();
    _goldPaidWeightController.dispose();
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
      if (auth.hasPermission('system.settings')) {
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

    final rawMode = settings['manufacturing_wage_mode'];
    final normalized = rawMode is String
        ? rawMode.toLowerCase().trim()
        : rawMode?.toString().toLowerCase().trim();

    if (normalized == 'inventory' || normalized == 'expense') {
      if (_wagePostingModeFromPrefs) return;
      setState(() {
        _wagePostingMode = normalized!;
      });
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
              .where((box) => box.safeType == 'cash' || box.safeType == 'bank')
              .toList();
      }

      if (!mounted) return;

      if (boxes.isEmpty) {
        await _loadDefaultSafeBox();
        return;
      }

      setState(() {
        _safeBoxes = boxes;
        final defaultBox = _safeBoxes.firstWhere(
          (box) => box.isDefault == true,
          orElse: () => _safeBoxes.first,
        );
        _selectedSafeBoxId = defaultBox.id;
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
            });
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

  _KaratLineSnapshot _snapshotFor(PurchaseKaratLine line) {
    final pricePerGram = _resolveGoldPrice(line.karat);
    final autoGoldValue = line.weightGrams * pricePerGram;
    final autoWageCash = line.weightGrams * line.wagePerGram;

    final vatRate = _vatRateFromSettings();
    final exemptKarats = _vatExemptKaratsFromSettings();
    final karatInt = line.karat.round();
    final isGoldVatExempt = exemptKarats.contains(karatInt);

    final autoGoldTax = (_applyVatOnGold && !isGoldVatExempt)
        ? autoGoldValue * vatRate
        : 0.0;
    final autoWageTax = autoWageCash * vatRate;

    final goldValue = _manualPricing
        ? (line.goldValueOverride ?? autoGoldValue)
        : autoGoldValue;
    final wageCash = _manualPricing
        ? (line.wageCashOverride ?? autoWageCash)
        : autoWageCash;
    var goldTax = _manualPricing
        ? (line.goldTaxOverride ?? autoGoldTax)
        : autoGoldTax;
    final wageTax = _manualPricing
        ? (line.wageTaxOverride ?? autoWageTax)
        : autoWageTax;

    // Enforce exemption even when manual overrides are present.
    if (isGoldVatExempt) {
      goldTax = 0.0;
    }

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
            description: result.description,
            itemCode: result.itemCode,
            barcode: result.barcode,
            category: result.category,
            categoryId: result.categoryId,
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

  Map<double, _InlineKaratAggregate> _inlineKaratAggregates() {
    final Map<double, _InlineKaratAggregate> aggregates = {};
    for (final item in _inlineItems) {
      final line = PurchaseKaratLine(
        karat: item.karat,
        weightGrams: item.weightGrams,
        wagePerGram: item.wagePerGram,
      );
      final snapshot = _snapshotFor(line);
      aggregates
          .putIfAbsent(line.karat, () => _InlineKaratAggregate())
          .add(snapshot);
    }
    return aggregates;
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
    if (_selectedBranchId == null) {
      setState(() {
        _branchError = 'يجب اختيار فرع';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى اختيار الفرع قبل الحفظ')),
      );
      return false;
    }

    if (_selectedSupplierId == null) {
      setState(() {
        _supplierError = 'يجب اختيار مورد';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى اختيار المورد قبل الحفظ')),
      );
      return false;
    }

    if (_karatLines.isEmpty && _inlineItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أضف أصنافاً أو قم بتعبئة بيانات العيارات قبل الحفظ'),
        ),
      );
      return false;
    }

    if (_totalWeight <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('إجمالي الوزن يجب أن يكون أكبر من صفر')),
      );
      return false;
    }

    final paidCash = _cashPaid();
    final paidGold = _goldPaidWeight();

    // Partial cash should not exceed cash due (no supplier advance credit in this screen).
    if (_settlementMode == _PurchaseSettlementMode.partial) {
      final dueCash = _cashDueForSupplier();
      if ((paidCash - dueCash) > 0.01) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'المدفوع النقدي لا يمكن أن يتجاوز النقد المستحق (${_formatCurrency(dueCash)})',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return false;
      }
    }

    // Require payment method only if we are actually paying cash.
    if (_settlementMode == _PurchaseSettlementMode.partial &&
        paidCash > 0 &&
        _paymentMethods.isNotEmpty &&
        _selectedPaymentMethodId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر وسيلة الدفع قبل الحفظ')),
      );
      return false;
    }

    if ((_settlementMode == _PurchaseSettlementMode.partial ||
            _settlementMode == _PurchaseSettlementMode.barter) &&
        paidGold > 0 &&
        _selectedGoldSafeBoxId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر خزينة الذهب قبل الحفظ')),
      );
      return false;
    }

    // Cash partial payments require backend setting allow_partial_invoice_payments.
    if (_settlementMode == _PurchaseSettlementMode.partial && paidCash > 0) {
      final allowPartial = context
          .read<SettingsProvider>()
          .allowPartialInvoicePayments;
      if (!allowPartial) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'لا يمكن تسجيل دفعة نقدية جزئية إلا بعد تفعيل السماح بالدفع الجزئي من الإعدادات',
            ),
          ),
        );
        return false;
      }
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

    final inlineAggregates = _inlineKaratAggregates();
    inlineAggregates.forEach((karat, aggregate) {
      linePayloads.add({
        'karat': karat,
        'weight_grams': _round(aggregate.weight, 3),
        'gold_value_cash': _round(aggregate.goldValue, 2),
        'manufacturing_wage_cash': _round(aggregate.wageCash, 2),
        'gold_tax': _round(aggregate.goldTax, 2),
        'wage_tax': _round(aggregate.wageTax, 2),
        'description': 'تفاصيل الأصناف المضافة داخل الفاتورة',
      });
    });

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
    final paidGoldWeight =
        (_settlementMode == _PurchaseSettlementMode.partial ||
            _settlementMode == _PurchaseSettlementMode.barter)
        ? _goldPaidWeight()
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
      'invoice_type': 'شراء',
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
      'wage_posting_mode': _wagePostingMode,
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

    // Gold settlement (مقايضة/جزئي): backend will post SafeBoxTransaction in gold safe.
    if (paidGoldWeight > 0) {
      payload['settled_gold_weight'] = _round(paidGoldWeight, 3);
      payload['settled_gold_karat'] = _selectedGoldPaidKarat;
      if (_selectedGoldSafeBoxId != null) {
        payload['settled_gold_safe_box_id'] = _selectedGoldSafeBoxId;
      }
    }

    // Invoice-level cash SafeBox preference (fallback server-side).
    // Only attach this when we're actually paying cash.
    if (_settlementMode == _PurchaseSettlementMode.partial &&
        paidCash > 0 &&
        _selectedSafeBoxId != null) {
      payload['safe_box_id'] = _selectedSafeBoxId;
    }

    return payload;
  }

  Future<void> _saveInvoice() async {
    if (_isSavingInvoice) return;
    if (!_validateBeforeSave()) return;

    setState(() {
      _isSavingInvoice = true;
    });

    try {
      final payload = _buildInvoicePayload();
      final response = await _api.addInvoice(payload);

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

      final shouldPrint = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('تم حفظ الفاتورة'),
            content: Text(
              '✅ تم حفظ فاتورة الشراء #${invoiceForPrint['id'] ?? ''}\nهل تريد طباعتها الآن؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('تم'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.print),
                label: const Text('طباعة'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      if (shouldPrint == true) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                InvoicePrintScreen(invoice: invoiceForPrint, isArabic: true),
          ),
        );
      }

      if (!mounted) return;
      _resetAfterSave();
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
    final size = MediaQuery.of(context).size;
    final isWideLayout = size.width >= 1100;

    final leftColumn = <Widget>[
      _buildSupplierSection(),
      const SizedBox(height: 24),
      _buildInlineItemsSection(),
      if (_karatLines.isNotEmpty) ...[
        const SizedBox(height: 24),
        _buildKaratLinesSection(),
      ],
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
      const SizedBox(height: 20),
      _buildSaveInvoiceButton(),
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
                onChanged: (value) {
                  setState(() {
                    _selectedBranchId = value;
                    _branchError = null;
                  });
                },
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _selectedSupplierId,
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
              onPressed: (index) {
                if (index == 0) {
                  _setSettlementMode(_PurchaseSettlementMode.credit);
                } else if (index == 1) {
                  _setSettlementMode(_PurchaseSettlementMode.barter);
                } else {
                  _setSettlementMode(_PurchaseSettlementMode.partial);
                }
              },
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
                  child: Text('جزئي'),
                ),
              ],
            ),

            if (_settlementMode == _PurchaseSettlementMode.partial) ...[
              const SizedBox(height: 16),
              // In جزئي: show cash payment method (and optionally cash safebox).
              if (_paymentMethods.isNotEmpty) ...[
                Builder(
                  builder: (context) {
                    final cashControlsEnabled = _cashPaid() > 0;

                    return Opacity(
                      opacity: cashControlsEnabled ? 1.0 : 0.55,
                      child: DropdownButtonFormField<int>(
                        initialValue: _selectedPaymentMethodId,
                        decoration: InputDecoration(
                          labelText: 'وسيلة الدفع',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.payment,
                            color: colorScheme.primary,
                          ),
                        ),
                        dropdownColor: theme.cardColor,
                        icon: Icon(
                          Icons.arrow_drop_down,
                          color: colorScheme.primary,
                        ),
                        items: _paymentMethods
                            .map(
                              (method) => DropdownMenuItem<int>(
                                value: method['id'] as int,
                                child: Text(
                                  method['name']?.toString() ?? 'بدون اسم',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: cashControlsEnabled
                            ? (value) {
                                setState(() {
                                  _selectedPaymentMethodId = value;
                                });
                                if (value != null) {
                                  _loadSafeBoxesForPaymentMethod(value);
                                }
                              }
                            : null,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
              ],
              _buildPartialSettlementMiniTable(),
            ],

            if (_settlementMode == _PurchaseSettlementMode.barter) ...[
              const SizedBox(height: 16),
              _buildBarterSettlementInputs(),
            ],

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
                if (_settlementMode == _PurchaseSettlementMode.partial &&
                    _safeBoxes.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: (_cashPaid() > 0)
                        ? () {
                            setState(() {
                              _showAdvancedPaymentOptions =
                                  !_showAdvancedPaymentOptions;

                              // Ensure the selected safebox exists in the list before
                              // rendering the dropdown; otherwise Flutter will throw
                              // repeatedly (appearing like an infinite loop).
                              if (_showAdvancedPaymentOptions &&
                                  _safeBoxes.isNotEmpty) {
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

                                final hasSelected =
                                    _selectedSafeBoxId != null &&
                                    uniqueSafeBoxesWithIds.any(
                                      (box) => box.id == _selectedSafeBoxId,
                                    );
                                if (!hasSelected) {
                                  final defaultBox = uniqueSafeBoxesWithIds
                                      .firstWhere(
                                        (box) =>
                                            box.isDefault == true &&
                                            box.id != null,
                                        orElse: () => _safeBoxes.firstWhere(
                                          (box) => box.id != null,
                                          orElse: () => _safeBoxes.first,
                                        ),
                                      );
                                  _selectedSafeBoxId = defaultBox.id;
                                }
                              }
                            });
                          }
                        : null,
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
            if (_settlementMode == _PurchaseSettlementMode.partial &&
                _safeBoxes.isNotEmpty &&
                _showAdvancedPaymentOptions &&
                _cashPaid() > 0) ...[
              const SizedBox(height: 20),
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

    final remainingCash = _round(math.max(0.0, dueCash - paidCash), 2);
    final remainingGold = _round(math.max(0.0, dueGoldMain - paidGoldMain), 3);

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
        child: Text(
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
          'تفاصيل السداد (جزئي)',
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
                  color: remainingCash > 0.01 ? remainingColor : null,
                  fontWeight: remainingCash > 0.01 ? FontWeight.w800 : null,
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
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            NormalizeNumberFormatter(),
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
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
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _selectedGoldPaidKarat,
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
                            _selectedGoldPaidKarat = value;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                valueCell(
                  _formatWeight(remainingGold),
                  color: remainingGold > 0.0005 ? remainingColor : null,
                  fontWeight: remainingGold > 0.0005 ? FontWeight.w800 : null,
                ),
              ],
            ),
          ],
        ),
        if (_goldPaidWeight() > 0) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _selectedGoldSafeBoxId,
            decoration: const InputDecoration(
              labelText: 'خزينة الذهب (مصدر المقايضة/السداد)',
              border: OutlineInputBorder(),
            ),
            items: _goldSafeBoxes
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
                _selectedGoldSafeBoxId = value;
              });
            },
          ),
        ],
      ],
    );
  }

  Widget _buildBarterSettlementInputs() {
    final dueGoldMain = _supplierMainEquivalentWeight();
    final paidGoldMain = _goldPaidMainEquivalent();
    final remainingGold = _round(math.max(0.0, dueGoldMain - paidGoldMain), 3);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'تفاصيل المقايضة (ذهب)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          initialValue: _selectedGoldSafeBoxId,
          decoration: const InputDecoration(
            labelText: 'خزينة الذهب (المصدر)',
            border: OutlineInputBorder(),
          ),
          items: _goldSafeBoxes
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
              _selectedGoldSafeBoxId = value;
            });
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _goldPaidWeightController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  NormalizeNumberFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'وزن الذهب المدفوع',
                  border: OutlineInputBorder(),
                  hintText: '0.000',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _selectedGoldPaidKarat,
              items: const [24, 22, 21, 18]
                  .map(
                    (k) =>
                        DropdownMenuItem<int>(value: k, child: Text('عيار $k')),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _selectedGoldPaidKarat = value;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'المستحق (مكافئ): ${_formatWeight(dueGoldMain)} | المدفوع (مكافئ): ${_formatWeight(paidGoldMain)} | المتبقي: ${_formatWeight(remainingGold)}',
          style: const TextStyle(color: Colors.black54),
        ),
      ],
    );
  }

  Widget _buildGoldPriceCard() {
    final theme = Theme.of(context);
    if (_goldPrice == null) {
      return Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
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

    final mainKarat = _mainKaratFromSettings();
    final supportedKarats = <int>[24, 22, 21, 18];
    final karatsToDisplay = <int>{...supportedKarats, mainKarat}.toList()
      ..sort((a, b) => b.compareTo(a));

    final chips = <Widget>[];
    for (final karat in karatsToDisplay) {
      dynamic priceValue;
      switch (karat) {
        case 24:
          priceValue = _goldPrice!['price_24k'];
          break;
        case 22:
          priceValue = _goldPrice!['price_22k'];
          break;
        case 21:
          priceValue = _goldPrice!['price_21k'];
          break;
        case 18:
          priceValue = _goldPrice!['price_18k'];
          break;
        default:
          priceValue = _resolveGoldPrice(karat.toDouble());
      }
      chips.add(
        _buildPriceChip('عيار $karat', priceValue, isMain: karat == mainKarat),
      );
    }

    return Card(
      elevation: theme.brightness == Brightness.dark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'سعر الذهب',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Icon(Icons.circle, size: 10, color: theme.colorScheme.primary),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: chips
                    .map(
                      (w) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 10),
                        child: w,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceChip(String label, dynamic value, {bool isMain = false}) {
    final theme = Theme.of(context);
    final price = _toDouble(value);
    final display = price > 0 ? price.toStringAsFixed(2) : '-';
    return Chip(
      label: Text(
        isMain ? '$label (الرئيسي): $display ر.س' : '$label: $display ر.س',
        style: isMain ? const TextStyle(fontWeight: FontWeight.bold) : null,
      ),
      backgroundColor:
          (isMain
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest)
              .withValues(alpha: isMain ? 0.65 : 1.0),
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
                  _applyCombinedTotals();
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      color: theme.colorScheme.surface,
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
                  _applyCombinedTotals();
                });
                _persistApplyVatOnGold(value);
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
                  _wagePostingModeFromPrefs = true;
                });
                _persistWagePostingMode(mode);
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
    final wageType = _selectedSupplierDefaultWageType();
    final cashDue = _round(
      (wageType == 'cash' ? _wageSubtotal : 0.0) +
          _goldTaxTotal +
          _wageTaxTotal,
      2,
    );

    final mainKarat = _mainKaratFromSettings().toDouble();
    double mainEquivalentWeight = 0.0;
    if (mainKarat > 0) {
      for (final entry in weightSummary.entries) {
        final karat = double.tryParse(entry.key) ?? 0.0;
        final weight = entry.value;
        if (karat <= 0 || weight <= 0) continue;
        mainEquivalentWeight += weight * (karat / mainKarat);
      }
    }

    // If supplier wages are settled in gold, convert wage cash value to gold weight (main karat)
    // and include it in the main-equivalent view.
    if (wageType == 'gold' && _wageSubtotal > 0) {
      final priceMain = _resolveGoldPrice(mainKarat);
      if (priceMain > 0) {
        mainEquivalentWeight += (_wageSubtotal / priceMain);
      }
    }
    mainEquivalentWeight = _round(mainEquivalentWeight, 3);

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final theme = Theme.of(context);
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
                  iconColor: theme.colorScheme.primary,
                ),
                _buildMetricTile(
                  icon: Icons.balance,
                  label: 'ذهب مكافئ (عيار ${mainKarat.toStringAsFixed(0)})',
                  value: mainEquivalentWeight > 0
                      ? _formatWeight(mainEquivalentWeight)
                      : '0.000 جم',
                  iconColor: theme.colorScheme.primary,
                ),
                _buildMetricTile(
                  icon: Icons.payments_outlined,
                  label: 'نقد مستحق',
                  value: _formatCurrency(cashDue),
                  iconColor: theme.colorScheme.tertiary,
                ),
                _buildMetricTile(
                  icon: Icons.design_services,
                  label: wageType == 'gold'
                      ? 'أجور مصنعية (ذهب)'
                      : 'أجور مصنعية',
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
                    backgroundColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.75),
                    label: Text(
                      'عيار $karatLabel: ${_formatWeight(weightValue)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
                Text(
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

  Widget _buildInlineItemsSection() {
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'الأصناف داخل الفاتورة',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'أدخل وزناً واحداً للصنف أو ألصق عدة أوزان لنفس الصنف دفعة واحدة.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
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

  Widget _buildSaveInvoiceButton() {
    final theme = Theme.of(context);
    return Card(
      elevation: theme.brightness == Brightness.dark ? 1 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isSavingInvoice ? null : _saveInvoice,
            icon: _isSavingInvoice
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onSecondary,
                    ),
                  )
                : const Icon(Icons.save_alt),
            label: Text(_isSavingInvoice ? 'جارٍ الحفظ...' : 'حفظ الفاتورة'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.secondary,
              foregroundColor: theme.colorScheme.onSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              textStyle: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
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
      children: entries
          .map(
            (entry) => Chip(
              backgroundColor: const Color(0xFFFAF5E4),
              label: Text('عيار ${entry.key}: ${_formatWeight(entry.value)}'),
            ),
          )
          .toList(),
    );
  }

  Widget _buildInlineItemsEmptyState() {
    return Column(
      children: const [
        SizedBox(height: 16),
        Icon(Icons.inventory_outlined, size: 64, color: Colors.grey),
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
              if (item.category?.isNotEmpty ?? false)
                Text(
                  'تصنيف: ${item.category}',
                  style: const TextStyle(fontSize: 12),
                ),
              if (item.itemCode?.isNotEmpty ?? false)
                Text(
                  'كود: ${item.itemCode}',
                  style: const TextStyle(fontSize: 12),
                ),
              if (item.barcode?.isNotEmpty ?? false)
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
    String? selectedCategoryName = (existing?.category?.isNotEmpty ?? false)
        ? existing!.category
        : null;

    final result = await showDialog<PurchaseInlineItem>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
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

            return AlertDialog(
              title: Text(existing == null ? 'إضافة صنف' : 'تعديل الصنف'),
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
                                    TextField(
                                      controller: nameController,
                                      decoration: const InputDecoration(
                                        labelText: 'اسم الصنف',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.title),
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
                                      decoration: const InputDecoration(
                                        labelText: 'الوزن (جرام)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.scale),
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
                                      maxLines: 2,
                                      decoration: const InputDecoration(
                                        labelText: 'ملاحظات (اختياري)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(
                                          Icons.sticky_note_2_outlined,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: itemCodeController,
                                      decoration: const InputDecoration(
                                        labelText: 'كود الصنف (اختياري)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.tag),
                                      ),
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
                                      decoration: _categoryDropdownDecoration(),
                                    ),
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
                                        decoration: const InputDecoration(
                                          labelText: 'قيمة الأحجار (ريال)',
                                          border: OutlineInputBorder(),
                                          prefixIcon: Icon(Icons.attach_money),
                                        ),
                                        onChanged: (_) => setDialogState(() {}),
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
                  onPressed: () {
                    final name = nameController.text.trim();
                    final parsedWeight =
                        double.tryParse(weightController.text) ?? 0;
                    final parsedWagePerGram =
                        double.tryParse(wageController.text) ?? 0;
                    final parsedWageTotal =
                        double.tryParse(wageTotalController.text) ?? 0;

                    final effectiveCategoryName = dropdownCategoryValue;
                    final effectiveCategoryId = _categoryIdForName(
                      effectiveCategoryName,
                    );

                    final resolvedWagePerGram = wageInputIsTotal
                        ? (parsedWeight > 0
                              ? (parsedWageTotal / parsedWeight)
                              : 0.0)
                        : parsedWagePerGram;

                    if (name.isEmpty || parsedWeight <= 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('الاسم والوزن مطلوبان لإضافة الصنف'),
                        ),
                      );
                      return;
                    }

                    Navigator.of(dialogContext).pop(
                      PurchaseInlineItem(
                        name: name,
                        karat: karat,
                        weightGrams: parsedWeight,
                        wagePerGram: resolvedWagePerGram,
                        description: descriptionController.text.trim().isEmpty
                            ? null
                            : descriptionController.text.trim(),
                        itemCode: itemCodeController.text.trim().isEmpty
                            ? null
                            : itemCodeController.text.trim(),
                        barcode: barcodeController.text.trim().isEmpty
                            ? null
                            : barcodeController.text.trim(),
                        category: effectiveCategoryName,
                        categoryId: effectiveCategoryId,
                        hasStones: hasStones,
                        stonesWeight: hasStones ? stonesWeight : 0,
                        stonesValue: hasStones ? stonesValue : 0,
                      ),
                    );
                  },
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

            return AlertDialog(
              title: const Text('إضافة عدة أوزان لنفس الصنف'),
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
                                    TextField(
                                      controller: nameController,
                                      decoration: const InputDecoration(
                                        labelText: 'اسم الصنف',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(
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
                                                  ? 'سيتم تحويلها إلى ${effectiveWagePerGram.toStringAsFixed(2)} ريال/جرام'
                                                  : 'أدخل الأوزان أولاً لحساب ريال/جرام')
                                            : (parsedWeights.isEmpty
                                                  ? null
                                                  : 'إجمالي الأجور: ${computedWageTotal.toStringAsFixed(2)} ريال'),
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
                                    TextField(
                                      controller: itemCodeController,
                                      decoration: const InputDecoration(
                                        labelText: 'كود الصنف (اختياري)',
                                        border: OutlineInputBorder(),
                                        prefixIcon: Icon(Icons.tag),
                                      ),
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
                                      decoration: _categoryDropdownDecoration(),
                                    ),
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
                                ),
                                _previewRow(
                                  'إجمالي الأجور',
                                  _formatCurrency(computedWageTotal),
                                ),
                                _previewRow(
                                  'الأجور/جرام',
                                  effectiveWagePerGram.toStringAsFixed(2),
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

                    if (name.isEmpty) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(content: Text('اسم الصنف مطلوب')),
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

                    Navigator.of(dialogContext).pop(
                      _InlineBulkResult(
                        name: name,
                        karat: karat,
                        wagePerGram: wagePerGram,
                        weights: weights,
                        description: descriptionController.text.trim().isEmpty
                            ? null
                            : descriptionController.text.trim(),
                        itemCode: itemCodeController.text.trim().isEmpty
                            ? null
                            : itemCodeController.text.trim(),
                        barcode: barcodeController.text.trim().isEmpty
                            ? null
                            : barcodeController.text.trim(),
                        category: effectiveCategoryName,
                        categoryId: effectiveCategoryId,
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
            const Text(
              'استخدم هذا القسم لإدخال أوزان مستلمة مباشرة بدون إنشاء صنف داخل الفاتورة.',
              style: TextStyle(color: Colors.black54),
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
      children: const [
        SizedBox(height: 16),
        Icon(Icons.balance, size: 64, color: Colors.grey),
        SizedBox(height: 12),
        Text('لم يتم إضافة أسطر عيار بعد.'),
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
            final vatRate = _vatRateFromSettings();
            final exemptKarats = _vatExemptKaratsFromSettings();
            final karatInt = karat.round();
            final isGoldVatExempt = exemptKarats.contains(karatInt);
            final autoGoldTax = (_applyVatOnGold && !isGoldVatExempt)
                ? autoGoldValue * vatRate
                : 0.0;
            final autoWageTax = autoWageCash * vatRate;

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
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: wagePerGramController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
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
                    ),
                    if (_manualPricing) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: goldValueController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          NormalizeNumberFormatter(),
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
                          NormalizeNumberFormatter(),
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
                                NormalizeNumberFormatter(),
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
                                NormalizeNumberFormatter(),
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
    goldTaxController.dispose();
    wageTaxController.dispose();
    notesController.dispose();

    return result;
  }

  Future<_BulkWeightEntry?> _showBulkWeightsDialog() async {
    final weightsController = TextEditingController();
    final wageController = TextEditingController(text: '0');
    final wageTotalController = TextEditingController(text: '0');
    final notesController = TextEditingController();
    double karat = 21;
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
                                  ? 'سيتم تحويلها إلى ${effectiveWagePerGram.toStringAsFixed(2)} ريال/جرام'
                                  : 'أدخل الأوزان أولاً لحساب ريال/جرام')
                            : (parsedWeights.isEmpty
                                  ? null
                                  : 'إجمالي الأجور: ${computedWageTotal.toStringAsFixed(2)} ريال'),
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

class _InlineKaratAggregate {
  double weight = 0;
  double goldValue = 0;
  double wageCash = 0;
  double goldTax = 0;
  double wageTax = 0;

  void add(_KaratLineSnapshot snapshot) {
    weight += snapshot.weight;
    goldValue += snapshot.goldValue;
    wageCash += snapshot.wageCash;
    goldTax += snapshot.goldTax;
    wageTax += snapshot.wageTax;
  }
}

class PurchaseInlineItem {
  final String name;
  final double karat;
  final double weightGrams;
  final double wagePerGram;
  final String? description;
  final bool hasStones;
  final double stonesWeight;
  final double stonesValue;
  final String? itemCode;
  final String? barcode;
  final String? category;
  final int? categoryId;

  const PurchaseInlineItem({
    required this.name,
    required this.karat,
    required this.weightGrams,
    required this.wagePerGram,
    this.description,
    this.hasStones = false,
    this.stonesWeight = 0,
    this.stonesValue = 0,
    this.itemCode,
    this.barcode,
    this.category,
    this.categoryId,
  });

  PurchaseInlineItem copyWith({
    String? name,
    double? karat,
    double? weightGrams,
    double? wagePerGram,
    String? description,
    bool? hasStones,
    double? stonesWeight,
    double? stonesValue,
    String? itemCode,
    String? barcode,
    String? category,
    int? categoryId,
  }) {
    return PurchaseInlineItem(
      name: name ?? this.name,
      karat: karat ?? this.karat,
      weightGrams: weightGrams ?? this.weightGrams,
      wagePerGram: wagePerGram ?? this.wagePerGram,
      description: description ?? this.description,
      hasStones: hasStones ?? this.hasStones,
      stonesWeight: stonesWeight ?? this.stonesWeight,
      stonesValue: stonesValue ?? this.stonesValue,
      itemCode: itemCode ?? this.itemCode,
      barcode: barcode ?? this.barcode,
      category: category ?? this.category,
      categoryId: categoryId ?? this.categoryId,
    );
  }

  Map<String, dynamic> toPayload() {
    return {
      'name': name,
      'karat': karat,
      'weight': weightGrams,
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
      'create_inline': true,
    }..removeWhere((key, value) => value == null);
  }
}

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
  });
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}
