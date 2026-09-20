import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../app_events.dart';
import '../models/employee_model.dart';
import '../providers/auth_provider.dart';
import '../services/data_sync_bus.dart';
import '../utils/invoice_direct_print.dart';
import '../widgets/widgets.dart';
import 'add_return_invoice_screen.dart';
import 'purchase_invoice_screen.dart';
import 'sales_invoice_screen_v2.dart';
import 'scrap_purchase_invoice_screen.dart';
import 'scrap_sales_invoice_screen.dart';
import 'voucher_details_screen.dart';
// import 'add_invoice_screen.dart'; // TODO: Uncomment when implementing add invoice

// حالة سطر واحد عند تقسيم دفعة فاتورة على عدة وسائل دفع
// (انظر _showCorrectPaymentMethodDialog).
class _SplitRowState {
  int? paymentMethodId;
  final TextEditingController amountController = TextEditingController();
}

enum _InvoiceCreationTarget {
  sales,
  scrapSale,
  scrapPurchase,
  supplierPurchase,
  salesReturn,
  scrapReturn,
  supplierReturn,
}

enum _InvoiceListView { table, cards }

enum _InvoiceRowAction { view, editContent, print, changeEmployee, post, unpost, delete }

class _InvoiceTabConfig {
  final String labelAr;
  final String labelEn;
  final List<String> apiInvoiceTypes;
  final IconData icon;
  final bool supplierParty;

  const _InvoiceTabConfig({
    required this.labelAr,
    required this.labelEn,
    required this.apiInvoiceTypes,
    required this.icon,
    this.supplierParty = false,
  });
}

class InvoicesListScreen extends StatefulWidget {
  final bool isArabic;
  final bool embedded;

  const InvoicesListScreen({
    super.key,
    this.isArabic = true,
    this.embedded = false,
  });

  @override
  State<InvoicesListScreen> createState() => _InvoicesListScreenState();
}

class _InvoicesListScreenState extends State<InvoicesListScreen>
    with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final ScrollController _invoiceTableHorizontalController = ScrollController();
  final ScrollController _invoiceContentScrollController = ScrollController();
  final GlobalKey _invoiceFilterToolbarKey = GlobalKey();
  static const Duration _tabSwitchAnimationDuration = Duration(
    milliseconds: 160,
  );
  List<dynamic> _invoices = [];
  List<dynamic> _filteredInvoices = [];
  bool _isLoading = false;
  List<Map<String, dynamic>>? _cachedCustomers;
  List<Map<String, dynamic>>? _cachedSuppliers;
  List<Map<String, dynamic>> _availableEmployees = const [];
  List<Map<String, dynamic>>? _cachedItems;
  int _itemsRevisionSnapshot = 0;
  VoidCallback? _itemsRevisionListener;

  // Tab controller
  late TabController _tabController;
  static const List<_InvoiceTabConfig> _invoiceTabs = [
    _InvoiceTabConfig(
      labelAr: 'بيع',
      labelEn: 'Sales',
      apiInvoiceTypes: ['بيع'],
      icon: Icons.point_of_sale,
    ),
    _InvoiceTabConfig(
      labelAr: 'شراء من عميل',
      labelEn: 'Customer Buyback',
      apiInvoiceTypes: ['شراء من عميل'],
      icon: Icons.person_search,
    ),
    _InvoiceTabConfig(
      labelAr: 'شراء مورد',
      labelEn: 'Supplier Purchase',
      apiInvoiceTypes: ['شراء', 'شراء من مورد'],
      icon: Icons.local_shipping,
      supplierParty: true,
    ),
    _InvoiceTabConfig(
      labelAr: 'مرتجع بيع',
      labelEn: 'Sales Return',
      apiInvoiceTypes: ['مرتجع بيع'],
      icon: Icons.undo,
    ),
    _InvoiceTabConfig(
      labelAr: 'مرتجع شراء عميل',
      labelEn: 'Customer Return',
      apiInvoiceTypes: ['مرتجع شراء', 'مرتجع شراء من عميل'],
      icon: Icons.assignment_return,
    ),
    _InvoiceTabConfig(
      labelAr: 'مرتجع شراء مورد',
      labelEn: 'Supplier Return',
      apiInvoiceTypes: ['مرتجع شراء (مورد)', 'مرتجع شراء من مورد'],
      icon: Icons.assignment_returned,
      supplierParty: true,
    ),
  ];

  // Per-tab filter state
  late final List<TextEditingController> _searchControllers;
  final List<String> _tabSearchType = [
    'all',
    'all',
    'all',
    'all',
    'all',
    'all',
  ];
  final List<String> _tabStatus = ['all', 'all', 'all', 'all', 'all', 'all'];
  final List<String> _tabGoldType = ['all', 'all', 'all', 'all', 'all', 'all'];
  final List<String?> _tabKarat = [null, null, null, null, null, null];
  final List<String?> _tabParty = [null, null, null, null, null, null];
  final List<String?> _tabCreator = [null, null, null, null, null, null];
  final List<DateTimeRange?> _tabDateRange = [
    null,
    null,
    null,
    null,
    null,
    null,
  ];
  final List<String> _tabSort = [
    'date',
    'date',
    'date',
    'date',
    'date',
    'date',
  ];
  final List<bool> _tabSortAsc = [false, false, false, false, false, false];
  _InvoiceListView _viewMode = _InvoiceListView.table;
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalInvoices = 0;
  int _perPage = 25;
  Map<String, dynamic>? _currentSummary;
  final Map<String, Map<String, dynamic>> _invoiceQueryCache = {};
  Timer? _searchDebounce;
  double _filterToolbarHeight = 84;

  static const Map<String, String> _invoicePrefixLookup = {
    'بيع': 'SELL',
    'sell': 'SELL',
    'sale': 'SELL',
    'شراء من عميل': 'BUY',
    // Supplier purchase (worked gold)
    'شراء': 'SUPP',
    'buy': 'BUY',
    'purchase': 'BUY',
    'مرتجع بيع': 'RETSELL',
    'sales return': 'RETSELL',
    'مرتجع شراء': 'RETBUY',
    'purchase return': 'RETBUY',
    'supplier purchase': 'SUPP',
    'مرتجع شراء (مورد)': 'RETSUPP',
    'supplier purchase return': 'RETSUPP',
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _invoiceTabs.length,
      vsync: this,
      animationDuration: _tabSwitchAnimationDuration,
    );
    _searchControllers = List.generate(
      _invoiceTabs.length,
      (_) => TextEditingController(),
    );
    for (final ctrl in _searchControllers) {
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
    }
    _itemsRevisionSnapshot = DataSyncBus.itemsRevision.value;
    _itemsRevisionListener = () {
      _cachedItems = null;
      _itemsRevisionSnapshot = DataSyncBus.itemsRevision.value;
    };
    DataSyncBus.itemsRevision.addListener(_itemsRevisionListener!);
    _loadInvoices();
    _warmFilterLookups();
  }

  @override
  void dispose() {
    _invoiceTableHorizontalController.dispose();
    _invoiceContentScrollController.dispose();
    _tabController.dispose();
    _searchDebounce?.cancel();
    for (final c in _searchControllers) {
      c.dispose();
    }
    if (_itemsRevisionListener != null) {
      DataSyncBus.itemsRevision.removeListener(_itemsRevisionListener!);
    }
    super.dispose();
  }

  void _measureFilterToolbarHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _invoiceFilterToolbarKey.currentContext;
      if (context == null) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox) return;
      final measuredHeight = renderObject.size.height;
      if (measuredHeight <= 0) return;
      if ((measuredHeight - _filterToolbarHeight).abs() < 0.5) return;
      setState(() {
        _filterToolbarHeight = measuredHeight;
      });
    });
  }

  String _buildInvoiceQueryCacheKey(int idx, int targetPage) {
    final dateRange = _tabDateRange[idx];
    return json.encode({
      'tab': idx,
      'page': targetPage,
      'perPage': _perPage,
      'sortBy': _tabSort[idx],
      'sortAsc': _tabSortAsc[idx],
      'status': _tabStatus[idx],
      'goldType': _tabGoldType[idx],
      'karat': _tabKarat[idx],
      'party': _tabParty[idx],
      'creator': _tabCreator[idx],
      'searchType': _tabSearchType[idx],
      'search': _searchControllers[idx].text.trim(),
      'dateFrom': dateRange?.start.toIso8601String(),
      'dateTo': dateRange == null
          ? null
          : DateTime(dateRange.end.year, dateRange.end.month, dateRange.end.day, 23, 59, 59, 999)
              .toIso8601String(),
      'invoiceTypes': _invoiceTabs[idx].apiInvoiceTypes,
    });
  }

  void _applyInvoiceResponse(Map<String, dynamic> data, int targetPage) {
    final invoices = data['invoices'] ?? [];
    final total = _tryParseInt(data['total']) ?? invoices.length;
    final pages = _tryParseInt(data['pages']) ?? 1;
    final currentPage = _tryParseInt(data['current_page']) ?? targetPage;
    final meta = data['meta'] as Map<String, dynamic>?;
    final currentSummary = meta?['current_summary'] as Map<String, dynamic>?;
    final availableCreatorsRaw =
        (meta?['available_creators'] as List<dynamic>?) ??
        (meta?['available_employees'] as List<dynamic>?) ??
        const [];
    final availableCreators = availableCreatorsRaw
        .whereType<Map>()
        .map(
          (entry) => entry.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();

    _invoices = invoices;
    _totalInvoices = total;
    _totalPages = pages < 1 ? 1 : pages;
    _currentPage = currentPage < 1 ? 1 : currentPage;
    _currentSummary = currentSummary;
    _availableEmployees = availableCreators;
    _applyFilters();
  }

  void _invalidateInvoiceCache() {
    _invoiceQueryCache.clear();
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      setState(() {
        _currentPage = 1;
      });
      _loadInvoices(page: 1);
    });
  }

  void _handleTabTap(int index) {
    _currentPage = 1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadInvoices(page: 1, tabIndex: index);
    });
  }

  Future<void> _loadInvoices({
    int? page,
    int? tabIndex,
    bool forceRefresh = false,
  }) async {
    if (!mounted) return;
    final targetPage = page ?? _currentPage;
    final idx = tabIndex ?? _tabController.index;
    final cacheKey = _buildInvoiceQueryCacheKey(idx, targetPage);

    if (!forceRefresh) {
      final cached = _invoiceQueryCache[cacheKey];
      if (cached != null) {
        setState(() {
          _applyInvoiceResponse(cached, targetPage);
        });
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      final statusForApi = _tabStatus[idx];
      final dateRange = _tabDateRange[idx];
      final goldType = _tabGoldType[idx];
      final karat = _tabKarat[idx];
      final party = _tabParty[idx];
      final creator = _tabCreator[idx];
      final searchType = _tabSearchType[idx];
      final search = _searchControllers[idx].text.trim();
      final tabConfig = _invoiceTabs[idx];

      final data = await _apiService.getInvoices(
        page: targetPage,
        perPage: _perPage,
        sortBy: _tabSort[idx],
        sortOrder: _tabSortAsc[idx] ? 'asc' : 'desc',
        search: search,
        searchType: searchType,
        status: statusForApi,
        invoiceType: null,
        invoiceTypes: tabConfig.apiInvoiceTypes,
        dateFrom: dateRange?.start,
        dateTo: dateRange?.end,
        goldType: goldType == 'all' ? null : goldType,
        karat: karat,
        party: party,
        creator: creator,
      );

      if (!mounted) return;
      _invoiceQueryCache[cacheKey] = Map<String, dynamic>.from(data);

      setState(() {
        _applyInvoiceResponse(data, targetPage);
      });
    } catch (e) {
      if (mounted) {
        _showSnackBar('خطأ في تحميل الفواتير: ${e.toString()}', isError: true);
      }
      debugPrint('❌ Error loading invoices: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _warmFilterLookups() async {
    try {
      final customers = await _getCachedCustomers();
      final suppliers = await _getCachedSuppliers();
      if (!mounted) return;
      setState(() {
        _cachedCustomers = customers;
        _cachedSuppliers = suppliers;
      });
    } catch (_) {
      // Best-effort only; filters can still work without lookup lists.
    }
  }

  Future<List<Map<String, dynamic>>> _getCachedCustomers() async {
    if (_cachedCustomers != null) {
      return _cachedCustomers!;
    }

    final customers = await _apiService.getCustomers();
    _cachedCustomers = _normalizeDynamicList(customers);
    return _cachedCustomers!;
  }

  Future<List<Map<String, dynamic>>> _getCachedSuppliers() async {
    if (_cachedSuppliers != null) {
      return _cachedSuppliers!;
    }

    final suppliers = await _apiService.getSuppliers();
    _cachedSuppliers = _normalizeDynamicList(suppliers);
    return _cachedSuppliers!;
  }

  Future<List<Map<String, dynamic>>> _getCachedItems() async {
    if (_itemsRevisionSnapshot != DataSyncBus.itemsRevision.value) {
      _cachedItems = null;
      _itemsRevisionSnapshot = DataSyncBus.itemsRevision.value;
    }
    if (_cachedItems != null) {
      return _cachedItems!;
    }

    final items = await _apiService.getItems();
    _cachedItems = _normalizeDynamicList(items);
    return _cachedItems!;
  }

  List<String> _currentPartyOptions() {
    final idx = _tabController.index;
    final seen = <String>{};
    final result = <String>[];
    final isSupplierTab = _invoiceTabs[idx].supplierParty;

    void collect(List<Map<String, dynamic>>? source) {
      if (source == null) return;
      for (final entry in source) {
        final name =
            (entry['name'] ?? entry['customer_name'] ?? entry['supplier_name'])
                ?.toString()
                .trim();
        if (name == null || name.isEmpty || seen.contains(name)) continue;
        seen.add(name);
        result.add(name);
      }
    }

    if (isSupplierTab) {
      collect(_cachedSuppliers);
    } else {
      collect(_cachedCustomers);
    }

    result.sort();
    return result;
  }

  String _partyFilterLabel(bool isAr) {
    final isSupplier = _invoiceTabs[_tabController.index].supplierParty;
    return isSupplier
        ? (isAr ? 'المورد' : 'Supplier')
        : (isAr ? 'العميل' : 'Customer');
  }

  List<Map<String, dynamic>> _normalizeDynamicList(List<dynamic> source) {
    final normalized = <Map<String, dynamic>>[];
    for (final entry in source) {
      if (entry is Map<String, dynamic>) {
        normalized.add(Map<String, dynamic>.from(entry));
      } else if (entry is Map) {
        normalized.add(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
    }
    return normalized;
  }

  List<Map<String, dynamic>> _cloneDataList(List<Map<String, dynamic>> source) {
    return source.map((entry) => Map<String, dynamic>.from(entry)).toList();
  }

  double _parseStock(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value) ?? 0.0;
    }
    return 0.0;
  }

  List<Map<String, dynamic>> _filterSaleReadyItems(
    List<Map<String, dynamic>> source,
  ) {
    // 🔥 في تجارة الذهب: stock >= 1 تعني القطعة متاحة
    return source
        .where((item) => _parseStock(item['stock']) >= 1)
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  void _applyFilters() {
    _filteredInvoices = List.from(_invoices);
  }

  /// Returns the filtered+sorted invoice list for a specific tab.
  List<dynamic> _getTabFilteredInvoices(int tabIndex, String tabType) {
    if (tabIndex != _tabController.index) {
      return const [];
    }
    return List<dynamic>.from(_filteredInvoices);
  }

  String _normalizeStatus(String? rawStatus) {
    if (rawStatus == null) {
      return 'unknown';
    }

    final trimmed = rawStatus.trim();
    if (trimmed.isEmpty) {
      return 'unknown';
    }

    final lower = trimmed.toLowerCase();

    if (lower == 'paid' || trimmed == 'مدفوعة') {
      return 'paid';
    }
    if (lower == 'unpaid' || trimmed == 'غير مدفوعة') {
      return 'unpaid';
    }
    if (lower == 'partially_paid' ||
        lower == 'partially paid' ||
        trimmed == 'مدفوعة جزئياً') {
      return 'partially_paid';
    }
    // Invoice drafts are not supported.
    if (lower == 'cancelled' || lower == 'canceled' || trimmed == 'ملغاة') {
      return 'cancelled';
    }

    return lower;
  }

  int? _tryParseInt(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    return int.tryParse(value.toString());
  }

  double _tryParseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  /// الوزن المعادل بالعيار الرئيسي — يُستخدم للعرض الرئيسي ويتطابق مع تقرير المبيعات.
  double _extractInvoiceTotalWeight(Map<String, dynamic> invoice) {
    // الأولوية: total_weight_main_karat الذي يُرسله الـ backend مباشرة
    final mk = _tryParseDouble(invoice['total_weight_main_karat']);
    if (mk > 0) return mk;

    // احتياط: احسب يدوياً من karat_lines إن وُجدت (عيار رئيسي افتراضي 21)
    final karatLines = invoice['karat_lines'];
    if (karatLines is List && karatLines.isNotEmpty) {
      var sum = 0.0;
      const mainK = 21.0;
      for (final kl in karatLines) {
        if (kl is Map) {
          final lw = _tryParseDouble(kl['weight_grams'] ?? kl['weight']);
          final lk = _tryParseDouble(kl['karat']) > 0
              ? _tryParseDouble(kl['karat'])
              : mainK;
          sum += lw * lk / mainK;
        }
      }
      if (sum > 0) return sum;
    }

    // احتياط نهائي: الوزن الخام من البنود أو total_weight
    return _extractInvoiceRawWeight(invoice);
  }

  /// الوزن الخام الفعلي بالجرام — يُعرض ثانوياً.
  double _extractInvoiceRawWeight(Map<String, dynamic> invoice) {
    final items = invoice['items'];
    if (items is List && items.isNotEmpty) {
      var sum = 0.0;
      for (final entry in items) {
        if (entry is Map) {
          sum += _tryParseDouble(
            entry['weight'] ??
                entry['weight_grams'] ??
                entry['gold_weight'] ??
                entry['total_weight'],
          );
        }
      }
      if (sum > 0) return sum;
    }
    return _tryParseDouble(invoice['total_weight']);
  }

  String? _extractInvoiceKaratLabel(Map<String, dynamic> invoice) {
    final direct =
        invoice['karat'] ?? invoice['gold_karat'] ?? invoice['karat_value'];
    final directStr = direct?.toString().trim();
    if (directStr != null && directStr.isNotEmpty) {
      return directStr;
    }

    final items = invoice['items'];
    if (items is List) {
      final karats = <String>{};
      for (final entry in items) {
        if (entry is Map) {
          final v =
              (entry['karat'] ?? entry['gold_karat'] ?? entry['karat_value'])
                  ?.toString()
                  .trim();
          if (v != null && v.isNotEmpty) {
            karats.add(v);
          }
        }
      }
      if (karats.isEmpty) return null;
      final list = karats.toList()..sort();
      return list.join('/');
    }

    return null;
  }

  String? _extractInvoiceGoldTypeLabel(Map<String, dynamic> invoice) {
    final direct =
        invoice['gold_type'] ??
        invoice['goldType'] ??
        invoice['gold_type_name'];
    final directStr = direct?.toString().trim();
    if (directStr != null && directStr.isNotEmpty) {
      return directStr;
    }

    final items = invoice['items'];
    if (items is List) {
      final types = <String>{};
      for (final entry in items) {
        if (entry is Map) {
          final v =
              (entry['gold_type'] ??
                      entry['goldType'] ??
                      entry['gold_type_name'] ??
                      entry['type'])
                  ?.toString()
                  .trim();
          if (v != null && v.isNotEmpty) {
            types.add(v);
          }
        }
      }
      if (types.isEmpty) return null;
      final list = types.toList()..sort();
      return list.join('/');
    }

    return null;
  }

  String? _extractInvoiceEmployeeName(Map<String, dynamic> invoice) {
    final candidates = [
      invoice['employee_name'],
      invoice['seller_name'],
      invoice['created_by_name'],
      invoice['created_by'],
      invoice['posted_by_name'],
      invoice['posted_by'],
      invoice['user_name'],
      invoice['cashier_name'],
      invoice['cashier'],
    ];

    for (final v in candidates) {
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) {
        return s;
      }
    }
    return null;
  }

  String _getInvoiceDisplayNumber(Map<String, dynamic> invoice) {
    final String? trimmedNumber = invoice['invoice_number']?.toString().trim();
    if (trimmedNumber?.isNotEmpty ?? false) {
      return trimmedNumber!;
    }

    final fallback = _buildFallbackInvoiceNumber(invoice);
    if (fallback != null) {
      return fallback;
    }

    final legacyId = invoice['id'];
    return legacyId != null ? '#${legacyId.toString()}' : '#---';
  }

  String? _buildFallbackInvoiceNumber(Map<String, dynamic> invoice) {
    try {
      final invoiceType = (invoice['invoice_type'] ?? '').toString().trim();
      if (invoiceType.isEmpty) {
        return null;
      }

      final int? sequence = _tryParseInt(invoice['invoice_type_id']);
      if (sequence == null || sequence <= 0) {
        return null;
      }

      final prefix = _resolveInvoicePrefix(invoiceType);
      final String? rawDate = invoice['date']?.toString();
      final parsedDate = rawDate != null ? DateTime.tryParse(rawDate) : null;
      final year = parsedDate?.year ?? DateTime.now().year;

      final digits = sequence >= 1000 ? 4 : 3;
      final sequenceStr = sequence.toString().padLeft(digits, '0');

      return '$prefix-$year-$sequenceStr';
    } catch (e) {
      debugPrint('⚠️ فشل بناء رقم فاتورة بديل: $e');
      return null;
    }
  }

  String _resolveInvoicePrefix(String invoiceType) {
    final trimmed = invoiceType.trim();
    if (trimmed.isEmpty) {
      return 'INV';
    }

    final lower = trimmed.toLowerCase();
    if (_invoicePrefixLookup.containsKey(trimmed)) {
      return _invoicePrefixLookup[trimmed]!;
    }
    if (_invoicePrefixLookup.containsKey(lower)) {
      return _invoicePrefixLookup[lower]!;
    }

    return 'INV';
  }

  String _translateStatus(String? status, bool isArabic) {
    if (status == null || status.isEmpty) {
      return isArabic ? 'غير محدد' : 'N/A';
    }

    final normalized = _normalizeStatus(status);
    switch (normalized) {
      case 'paid':
        return isArabic ? 'مدفوعة' : 'Paid';
      case 'unpaid':
        return isArabic ? 'غير مدفوعة' : 'Unpaid';
      case 'partially_paid':
        return isArabic ? 'مدفوعة جزئياً' : 'Partially Paid';
      case 'cancelled':
        return isArabic ? 'ملغاة' : 'Cancelled';
      default:
        return status;
    }
  }

  Map<String, dynamic> _calculateStatsFromInvoices(List<dynamic> tabInvoices) {
    final stats = <String, dynamic>{
      'total_invoices': 0,
      'total_amount': 0.0,
      'paid_amount': 0.0,
      'unpaid_amount': 0.0,
      'vat_total': 0.0,
      'sold_weight_total': 0.0,
    };

    if (tabInvoices.isEmpty) return stats;

    try {
      stats['total_invoices'] = tabInvoices.length;

      stats['total_amount'] = tabInvoices.fold(0.0, (sum, invoice) {
        try {
          final normalized = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalized == 'cancelled') return sum;
          return sum + ((invoice['total'] ?? 0) as num).toDouble();
        } catch (e) {
          return sum;
        }
      });

      stats['paid_amount'] = tabInvoices.fold(0.0, (sum, invoice) {
        try {
          final normalized = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalized == 'cancelled') return sum;

          final total = _tryParseDouble(invoice['total']);
          final paidCash = _tryParseDouble(
            invoice['amount_paid'] ?? invoice['total_payments_amount'],
          );
          final barterTotal = _tryParseDouble(invoice['barter_total']);
          final hasTotalSettledKey = invoice.containsKey(
            'total_settled_amount',
          );
          final totalSettled = hasTotalSettledKey
              ? _tryParseDouble(invoice['total_settled_amount'])
              : (paidCash + barterTotal);
          final paidClamped = totalSettled.clamp(0.0, total);
          return sum + paidClamped;
        } catch (e) {
          return sum;
        }
      });

      stats['unpaid_amount'] = tabInvoices.fold(0.0, (sum, invoice) {
        try {
          final normalized = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalized == 'cancelled') return sum;

          final total = _tryParseDouble(invoice['total']);
          final paidCash = _tryParseDouble(
            invoice['amount_paid'] ?? invoice['total_payments_amount'],
          );
          final barterTotal = _tryParseDouble(invoice['barter_total']);
          final hasTotalSettledKey = invoice.containsKey(
            'total_settled_amount',
          );
          final totalSettled = hasTotalSettledKey
              ? _tryParseDouble(invoice['total_settled_amount'])
              : (paidCash + barterTotal);
          final remaining = (total - totalSettled).clamp(0.0, double.infinity);
          return sum + remaining;
        } catch (e) {
          return sum;
        }
      });

      stats['vat_total'] = tabInvoices.fold(0.0, (sum, invoice) {
        try {
          final normalized = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalized == 'cancelled') return sum;
          return sum + _tryParseDouble(invoice['total_tax']);
        } catch (e) {
          return sum;
        }
      });

      stats['sold_weight_total'] = tabInvoices.fold(0.0, (sum, invoice) {
        try {
          final normalized = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalized == 'cancelled') return sum;
          return sum + _extractInvoiceTotalWeight(invoice);
        } catch (e) {
          return sum;
        }
      });
    } catch (e) {
      debugPrint('❌ خطأ في حساب إحصائيات التبويب: $e');
    }

    return stats;
  }

  // Calculate stats for the current tab (respects active filters)
  Map<String, dynamic> _getTabStatistics() {
    final summary = _currentSummary;
    if (summary != null) {
      return {
        'total_invoices': _tryParseInt(summary['total_invoices']) ?? 0,
        'total_amount': _tryParseDouble(summary['total_amount']),
        'paid_amount': _tryParseDouble(summary['paid_amount']),
        'unpaid_amount': _tryParseDouble(summary['unpaid_amount']),
        'vat_total': _tryParseDouble(summary['vat_total']),
        'sold_weight_total': _tryParseDouble(summary['sold_weight_total']),
      };
    }

    return _calculateStatsFromInvoices(_filteredInvoices);
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _clearFilters() {
    final idx = _tabController.index;
    setState(() {
      _searchControllers[idx].clear();
      _tabSearchType[idx] = 'all';
      _tabStatus[idx] = 'all';
      _tabGoldType[idx] = 'all';
      _tabKarat[idx] = null;
      _tabParty[idx] = null;
      _tabCreator[idx] = null;
      _tabDateRange[idx] = null;
      _tabSort[idx] = 'date';
      _tabSortAsc[idx] = false;
      _currentPage = 1;
    });
    _loadInvoices(page: 1);
  }

  int get _activeFiltersCount {
    final idx = _tabController.index;
    int count = 0;
    if (_searchControllers[idx].text.isNotEmpty) count++;
    if (_tabSearchType[idx] != 'all') count++;
    if (_tabStatus[idx] != 'all') count++;
    if (_tabGoldType[idx] != 'all') count++;
    if (_tabKarat[idx] != null) count++;
    if (_tabParty[idx] != null) count++;
    if (_tabCreator[idx] != null) count++;
    if (_tabDateRange[idx] != null) count++;
    if (_tabSort[idx] != 'date' && _tabSort[idx] != 'recent') count++;
    return count;
  }

  /// Returns the page numbers to display as buttons (int = page, -1 = ellipsis).
  List<int> _buildPageNumbers() {
    if (_totalPages <= 7) {
      return List.generate(_totalPages, (i) => i + 1);
    }
    final pages = <int>[];
    pages.add(1);
    final start = (_currentPage - 2).clamp(2, _totalPages - 1);
    final end = (_currentPage + 2).clamp(2, _totalPages - 1);
    if (start > 2) pages.add(-1); // leading ellipsis
    for (int p = start; p <= end; p++) {
      pages.add(p);
    }
    if (end < _totalPages - 1) pages.add(-1); // trailing ellipsis
    pages.add(_totalPages);
    return pages;
  }

  Widget _buildPaginationStrip({bool compact = false}) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (_totalInvoices == 0 || _totalPages <= 1) return const SizedBox.shrink();

    final primary = colorScheme.primary;
    final pageNums = _buildPageNumbers();
    final start = ((_currentPage - 1) * _perPage) + 1;
    final end = (_currentPage * _perPage) > _totalInvoices
        ? _totalInvoices
        : (_currentPage * _perPage);

    Widget prevBtn = SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.chevron_left, size: 18),
        tooltip: isAr ? 'السابق' : 'Previous',
        onPressed: (_isLoading || _currentPage <= 1)
            ? null
            : () => _loadInvoices(page: _currentPage - 1),
      ),
    );
    Widget nextBtn = SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.chevron_right, size: 18),
        tooltip: isAr ? 'التالي' : 'Next',
        onPressed: (_isLoading || _currentPage >= _totalPages)
            ? null
            : () => _loadInvoices(page: _currentPage + 1),
      ),
    );

    final pageButtons = pageNums.map<Widget>((p) {
      if (p == -1) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        );
      }
      final isActive = p == _currentPage;
      return GestureDetector(
        onTap: (_isLoading || isActive) ? null : () => _loadInvoices(page: p),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 30,
          height: 28,
          decoration: BoxDecoration(
            color: isActive ? primary : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: isActive
                ? null
                : Border.all(
                    color: colorScheme.outline.withValues(alpha: 0.35),
                    width: 1,
                  ),
          ),
          alignment: Alignment.center,
          child: Text(
            '$p',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive
                  ? colorScheme.onPrimary
                  : colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }).toList();

    return Padding(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
          : const EdgeInsetsDirectional.fromSTEB(8, 2, 8, 4),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text(
                '${isAr ? 'عرض' : 'Showing'} $start-$end ${isAr ? 'من' : 'of'} $_totalInvoices',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                isAr ? 'الصفوف:' : 'Rows:',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 6),
              DropdownButton<int>(
                value: _perPage,
                underline: const SizedBox.shrink(),
                items: const [10, 25, 50, 100]
                    .map(
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value'),
                      ),
                    )
                    .toList(),
                onChanged: (value) async {
                  if (value == null || value == _perPage) return;
                  setState(() {
                    _perPage = value;
                    _currentPage = 1;
                  });
                  await _loadInvoices(page: 1);
                },
              ),
              const SizedBox(width: 10),
              prevBtn,
              const SizedBox(width: 2),
              ...pageButtons,
              const SizedBox(width: 2),
              nextBtn,
            ],
          ),
        ),
      ),
    );
  }

  void _showFiltersBottomSheet() {
    final isAr = widget.isArabic;
    final idx = _tabController.index;
    String tempStatus = _tabStatus[idx];
    String tempSort = _tabSort[idx];
    bool tempAsc = _tabSortAsc[idx];
    DateTimeRange? tempDate = _tabDateRange[idx];
    final tabConfig = _invoiceTabs[idx];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSS) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;
          final textTheme = theme.textTheme;
          final bdRadius = BorderRadius.circular(12);

          Widget sheetDropdown({
            required String value,
            required List<Map<String, String>> items,
            required ValueChanged<String?> onChanged,
          }) {
            final hasMatch = items.any((i) => i['value'] == value);
            final eff = hasMatch
                ? value
                : (items.isNotEmpty ? items.first['value']! : value);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: bdRadius,
                border: Border.all(
                  color: colorScheme.outline.withValues(alpha: 0.25),
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: eff,
                  isExpanded: true,
                  dropdownColor: colorScheme.surface,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  items: items
                      .map(
                        (i) => DropdownMenuItem(
                          value: i['value']!,
                          child: Text(i['label']!, style: textTheme.bodyMedium),
                        ),
                      )
                      .toList(),
                  onChanged: onChanged,
                ),
              ),
            );
          }

          return Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: Padding(
              padding: EdgeInsets.only(
                top: 16,
                left: 16,
                right: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: colorScheme.onSurface.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Header
                  Row(
                    children: [
                      Icon(Icons.tune, color: colorScheme.primary, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isAr
                              ? 'تصفية: ${tabConfig.labelAr}'
                              : 'Filter: ${tabConfig.labelEn}',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _clearFilters();
                        },
                        child: Text(
                          isAr ? 'مسح الكل' : 'Clear All',
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Date range
                  OutlinedButton.icon(
                    icon: Icon(
                      Icons.date_range,
                      size: 18,
                      color: tempDate != null
                          ? colorScheme.primary
                          : colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    label: Text(
                      tempDate == null
                          ? (isAr ? 'اختر نطاق تاريخ' : 'Select date range')
                          : '${DateFormat('dd/MM/yy').format(tempDate!.start)}  →  ${DateFormat('dd/MM/yy').format(tempDate!.end)}',
                      style: textTheme.bodySmall?.copyWith(
                        color: tempDate != null ? colorScheme.primary : null,
                        fontWeight: tempDate != null ? FontWeight.w600 : null,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      alignment: AlignmentDirectional.centerStart,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      side: BorderSide(
                        color: tempDate != null
                            ? colorScheme.primary.withValues(alpha: 0.5)
                            : colorScheme.outline.withValues(alpha: 0.3),
                      ),
                      shape: RoundedRectangleBorder(borderRadius: bdRadius),
                    ),
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        initialDateRange: tempDate,
                      );
                      if (picked != null) setSS(() => tempDate = picked);
                    },
                  ),
                  if (tempDate != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: () => setSS(() => tempDate = null),
                        icon: const Icon(Icons.close, size: 14),
                        label: Text(isAr ? 'مسح التاريخ' : 'Clear date'),
                        style: TextButton.styleFrom(
                          foregroundColor: colorScheme.onSurface.withValues(
                            alpha: 0.55,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: sheetDropdown(
                          value: tempStatus,
                          items: _buildStatusItems(isAr),
                          onChanged: (v) {
                            if (v != null) setSS(() => tempStatus = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Sort
                  Row(
                    children: [
                      Expanded(
                        child: sheetDropdown(
                          value: tempSort,
                          items: [
                            {
                              'value': 'recent',
                              'label': isAr ? 'الأحدث' : 'Most Recent',
                            },
                            {
                              'value': 'date',
                              'label': isAr ? 'التاريخ' : 'Date',
                            },
                            {
                              'value': 'customer',
                              'label': isAr ? 'العميل' : 'Customer',
                            },
                            {
                              'value': 'amount',
                              'label': isAr ? 'المبلغ' : 'Amount',
                            },
                            {
                              'value': 'number',
                              'label': isAr ? 'الرقم' : 'Number',
                            },
                          ],
                          onChanged: (v) {
                            if (v != null) setSS(() => tempSort = v);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: Icon(
                          tempAsc ? Icons.arrow_upward : Icons.arrow_downward,
                          size: 16,
                        ),
                        label: Text(
                          tempAsc
                              ? (isAr ? 'تصاعدي' : 'Asc')
                              : (isAr ? 'تنازلي' : 'Desc'),
                          style: textTheme.bodySmall,
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(borderRadius: bdRadius),
                        ),
                        onPressed: () => setSS(() => tempAsc = !tempAsc),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  // Apply
                  FilledButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(
                      isAr ? 'تطبيق الفلاتر' : 'Apply Filters',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _tabStatus[idx] = tempStatus;
                        _tabSort[idx] = tempSort;
                        _tabSortAsc[idx] = tempAsc;
                        _tabDateRange[idx] = tempDate;
                        _currentPage = 1;
                      });
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primary = colorScheme.primary;
    final scaffoldBackground = theme.scaffoldBackgroundColor;
    final tabLabels = _invoiceTabs
        .map((tab) => isAr ? tab.labelAr : tab.labelEn)
        .toList();

    final actions = <Widget>[
      IconButton(
        icon: Icon(Icons.add, color: primary),
        onPressed: _navigateToAddInvoice,
        tooltip: isAr ? 'فاتورة جديدة' : 'New Invoice',
      ),
      IconButton(
        icon: Icon(
          _viewMode == _InvoiceListView.table
              ? Icons.view_module_outlined
              : Icons.table_rows_outlined,
          color: primary,
        ),
        onPressed: () {
          setState(() {
            _viewMode = _viewMode == _InvoiceListView.table
                ? _InvoiceListView.cards
                : _InvoiceListView.table;
          });
        },
        tooltip: _viewMode == _InvoiceListView.table
            ? (isAr ? 'عرض البطاقات' : 'Card View')
            : (isAr ? 'عرض الجدول' : 'Table View'),
      ),
      IconButton(
        icon: Icon(Icons.tune, color: primary),
        onPressed: _showFiltersBottomSheet,
        tooltip: isAr ? 'فلاتر متقدمة' : 'Advanced Filters',
      ),
      IconButton(
        icon: Icon(Icons.refresh, color: primary),
        onPressed: () => _loadInvoices(forceRefresh: true),
        tooltip: isAr ? 'تحديث' : 'Refresh',
      ),
    ];

    final body = NestedScrollView(
      controller: _invoiceContentScrollController,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(
          child: Column(
            children: [
              Container(
                color: theme.appBarTheme.backgroundColor ?? primary,
                child: _buildTabBar(),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 8, 0),
                child: _buildStatisticsSection(),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 8, 0),
                child: _buildStatusChipsRow(),
              ),
            ],
          ),
        ),
        _buildPinnedFilterToolbarSliver(),
      ],
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(primary),
              ),
            )
          : _buildTabContent(
              _getTabFilteredInvoices(
                _tabController.index,
                tabLabels[_tabController.index],
              ),
            ),
    );

    if (widget.embedded) {
      // Embedded inside the home shell's own AppBar — skip a second full
      // AppBar/title bar. The tab switcher itself moved into the
      // collapsible top chrome so it shrinks away with the rest of the
      // header on scroll, leaving the table the vertical space instead.
      return Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: Material(
          color: scaffoldBackground,
          child: Column(
            children: [
              Container(
                color: theme.appBarTheme.backgroundColor ?? primary,
                child: SafeArea(
                  bottom: false,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 16),
                        child: Text(
                          isAr ? 'الفواتير' : 'Invoices',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const Spacer(),
                      ...actions,
                    ],
                  ),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: scaffoldBackground,
        appBar: AppBar(
          title: Text(isAr ? 'قائمة الفواتير' : 'Invoices List'),
          actions: actions,
        ),
        body: body,
      ),
    );
  }

  // Build content for each tab
  Widget _buildTabContent(List<dynamic> tabInvoices) {
    if (tabInvoices.isEmpty) {
      return _buildEmptyState();
    }

    if (_viewMode == _InvoiceListView.table) {
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: _buildInvoiceTable(tabInvoices),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: _buildPaginationStrip(compact: true),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: _loadInvoices,
      color: Theme.of(context).colorScheme.primary,
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: ListView(
        primary: true,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        children: [
          ...tabInvoices.map<Widget>((entry) {
            try {
              return _buildInvoiceCard(Map<String, dynamic>.from(entry));
            } catch (e, stackTrace) {
              debugPrint('❌ خطأ في بناء بطاقة الفاتورة: $e');
              debugPrint('Stack: $stackTrace');
              return const SizedBox.shrink();
            }
          }),
          const SizedBox(height: 12),
          _buildPaginationStrip(compact: true),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    final isAr = widget.isArabic;
    final tabLabels = _invoiceTabs
        .map((tab) => isAr ? tab.labelAr : tab.labelEn)
        .toList();
    return TabBar(
      controller: _tabController,
      onTap: _handleTabTap,
      isScrollable: true,
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white.withValues(alpha: 0.65),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      indicator: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      tabs: List.generate(tabLabels.length, (index) {
        return Tab(
          icon: Icon(_invoiceTabs[index].icon),
          text: tabLabels[index],
        );
      }),
    );
  }

  Widget _buildStatusChipsRow() {
    final isAr = widget.isArabic;
    final idx = _tabController.index;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isCompact = MediaQuery.sizeOf(context).width < 700;

    Widget quickStatusChip({
      required String value,
      required String label,
      required Color color,
    }) {
      final selected = _tabStatus[idx] == value;
      return ChoiceChip(
        label: Text(label),
        selected: selected,
        labelStyle: textTheme.bodySmall?.copyWith(
          color: selected ? colorScheme.onPrimary : color,
          fontWeight: FontWeight.w700,
        ),
        backgroundColor: color.withValues(alpha: 0.08),
        selectedColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.25)),
        onSelected: (_) async {
          setState(() {
            _tabStatus[idx] = value;
            _currentPage = 1;
          });
          await _loadInvoices(page: 1);
        },
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildFilterRow(
              isCompact: isCompact,
              children: [
                quickStatusChip(
                  value: 'all',
                  label: isAr ? 'الكل' : 'All',
                  color: colorScheme.primary,
                ),
                quickStatusChip(
                  value: 'paid',
                  label: isAr ? 'مدفوعة' : 'Paid',
                  color: Colors.green,
                ),
                quickStatusChip(
                  value: 'remaining',
                  label: isAr ? 'متبقي' : 'Remaining',
                  color: Colors.redAccent,
                ),
                quickStatusChip(
                  value: 'partially_paid',
                  label: isAr ? 'جزئي' : 'Partial',
                  color: Colors.orange,
                ),
              ],
            ),
          ),
          if (_activeFiltersCount > 0)
            TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.close, size: 16),
              label: Text(isAr ? 'مسح الفلاتر' : 'Clear Filters'),
            ),
        ],
      ),
    );
  }

  Widget _buildPinnedFilterToolbarSliver() {
    _measureFilterToolbarHeight();
    final theme = Theme.of(context);
    return AnimatedPinnedHeader(
      height: _filterToolbarHeight,
      backgroundColor: theme.scaffoldBackgroundColor,
      child: KeyedSubtree(
        key: _invoiceFilterToolbarKey,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 8, 8),
          child: _buildFilterToolbar(),
        ),
      ),
    );
  }

  Widget _buildFilterToolbar() {
    final isAr = widget.isArabic;
    final idx = _tabController.index;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isCompact = MediaQuery.sizeOf(context).width < 700;
    final searchController = _searchControllers[idx];
    final searchType = _tabSearchType[idx];
    final partyOptions = _currentPartyOptions();
    final employeeOptions = _availableEmployees;
    final dateRange = _tabDateRange[idx];

    String searchTypeLabel(String value) {
      switch (value) {
        case 'number':
          return isAr ? 'رقم الفاتورة' : 'Invoice No.';
        case 'name':
          return isAr ? 'الاسم' : 'Name';
        case 'weight':
          return isAr ? 'الوزن' : 'Weight';
        case 'amount':
          return isAr ? 'المبلغ' : 'Amount';
        default:
          return isAr ? 'الكل' : 'All';
      }
    }

    String searchHint() {
      switch (searchType) {
        case 'number':
          return isAr ? 'رقم الفاتورة...' : 'Invoice number...';
        case 'name':
          return isAr
              ? 'اسم العميل أو المورد...'
              : 'Customer or supplier name...';
        case 'weight':
          return isAr ? 'الوزن...' : 'Weight...';
        case 'amount':
          return isAr ? 'المبلغ...' : 'Amount...';
        default:
          return isAr ? 'بحث...' : 'Search...';
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.14)),
      ),
      child: _buildFilterRow(
            isCompact: isCompact,
            children: [
              SizedBox(
                width: 470,
                child: TextField(
                  controller: searchController,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => _scheduleSearch(),
                  onSubmitted: (_) {
                    _searchDebounce?.cancel();
                    setState(() {
                      _currentPage = 1;
                    });
                    _loadInvoices(page: 1);
                  },
                  decoration: InputDecoration(
                    hintText: searchHint(),
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.42),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 156),
                    prefixIcon: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 8,
                        end: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.search,
                            size: 18,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          const SizedBox(width: 6),
                          PopupMenuButton<String>(
                            tooltip: isAr ? 'نوع البحث' : 'Search Type',
                            initialValue: searchType,
                            onSelected: (value) async {
                              setState(() {
                                _tabSearchType[idx] = value;
                                _currentPage = 1;
                              });
                              await _loadInvoices(page: 1);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem<String>(
                                value: 'all',
                                child: Text(isAr ? 'الكل' : 'All'),
                              ),
                              PopupMenuItem<String>(
                                value: 'number',
                                child: Text(isAr ? 'رقم' : 'Number'),
                              ),
                              PopupMenuItem<String>(
                                value: 'name',
                                child: Text(isAr ? 'الاسم' : 'Name'),
                              ),
                              PopupMenuItem<String>(
                                value: 'weight',
                                child: Text(isAr ? 'الوزن' : 'Weight'),
                              ),
                              PopupMenuItem<String>(
                                value: 'amount',
                                child: Text(isAr ? 'المبلغ' : 'Amount'),
                              ),
                            ],
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: colorScheme.outline.withValues(
                                    alpha: 0.16,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    searchTypeLabel(searchType),
                                    style: textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.onSurface.withValues(
                                        alpha: 0.78,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.arrow_drop_down,
                                    size: 18,
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    suffixIcon: searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: isAr ? 'مسح' : 'Clear',
                            onPressed: () {
                              setState(() {
                                searchController.clear();
                                _currentPage = 1;
                              });
                              _searchDebounce?.cancel();
                              _loadInvoices(page: 1);
                            },
                            icon: const Icon(Icons.close, size: 18),
                          ),
                  ),
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _tabParty[idx] ?? '',
                  decoration: InputDecoration(
                    labelText: _partyFilterLabel(isAr),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: '',
                      child: Text(isAr ? 'الكل' : 'All'),
                    ),
                    ...partyOptions.map(
                      (party) => DropdownMenuItem<String>(
                        value: party,
                        child: SizedBox(
                          width: 180,
                          child: Text(
                            party,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _tabParty[idx] = (value == null || value.isEmpty)
                          ? null
                          : value;
                      _currentPage = 1;
                    });
                    await _loadInvoices(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  value: _tabCreator[idx],
                  decoration: InputDecoration(
                    labelText: isAr ? 'المنشئ' : 'Creator',
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(isAr ? 'الكل' : 'All'),
                    ),
                    ...employeeOptions.map(
                      (employee) => DropdownMenuItem<String?>(
                        value: (employee['name'] ?? '').toString(),
                        child: SizedBox(
                          width: 190,
                          child: Text(
                            (employee['name'] ?? '').toString(),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _tabCreator[idx] = value;
                      _currentPage = 1;
                    });
                    await _loadInvoices(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _tabKarat[idx] ?? '',
                  decoration: InputDecoration(
                    labelText: isAr ? 'العيار' : 'Karat',
                  ),
                  items: const [
                    DropdownMenuItem<String>(value: '', child: Text('الكل')),
                    DropdownMenuItem<String>(value: '18', child: Text('18')),
                    DropdownMenuItem<String>(value: '21', child: Text('21')),
                    DropdownMenuItem<String>(value: '22', child: Text('22')),
                    DropdownMenuItem<String>(value: '24', child: Text('24')),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _tabKarat[idx] = (value == null || value.isEmpty)
                          ? null
                          : value;
                      _currentPage = 1;
                    });
                    await _loadInvoices(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  value: _tabGoldType[idx],
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: isAr ? 'نوع الذهب' : 'Gold Type',
                    prefixIcon: const Icon(Icons.auto_awesome),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: 'all',
                      child: Text(isAr ? 'الكل' : 'All'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'new',
                      child: Text(isAr ? 'جديد' : 'New'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'scrap',
                      child: Text(isAr ? 'كسر' : 'Scrap'),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() {
                      _tabGoldType[idx] = value;
                      _currentPage = 1;
                    });
                    await _loadInvoices(page: 1);
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDateRange: dateRange,
                  );
                  if (picked == null) return;
                  setState(() {
                    _tabDateRange[idx] = picked;
                    _currentPage = 1;
                  });
                  await _loadInvoices(page: 1);
                },
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(
                  dateRange == null
                      ? (isAr ? 'من - إلى' : 'From - To')
                      : '${DateFormat('dd/MM/yyyy').format(dateRange.start)} - ${DateFormat('dd/MM/yyyy').format(dateRange.end)}',
                ),
              ),
              if (dateRange != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _tabDateRange[idx] = null;
                      _currentPage = 1;
                    });
                    await _loadInvoices(page: 1);
                  },
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(isAr ? 'مسح التاريخ' : 'Clear Date'),
                ),
            ],
          ),
    );
  }

  Widget _buildFilterRow({
    required bool isCompact,
    required List<Widget> children,
  }) {
    if (!isCompact) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _buildInvoiceTable(List<dynamic> invoices) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final idx = _tabController.index;
    final viewportWidth = MediaQuery.sizeOf(context).width - 36;
    const tableContentWidth = 1168.0;
    final tableMinWidth = math.max(viewportWidth, tableContentWidth);
    final extraWidth = math.max(0.0, tableMinWidth - tableContentWidth);
    final widths = <String, double>{
      'number': 118,
      'customer': 172 + (extraWidth * 0.40),
      'creator': 110 + (extraWidth * 0.12),
      'date': 110 + (extraWidth * 0.08),
      'type': 104 + (extraWidth * 0.08),
      'karat': 70,
      'weight': 124 + (extraWidth * 0.06),
      'amount': 168 + (extraWidth * 0.14),
      'status': 140 + (extraWidth * 0.12),
      'actions': 52,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 480.0;

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.12),
            ),
          ),
          child: SingleChildScrollView(
            controller: _invoiceTableHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableMinWidth,
              height: tableHeight,
              child: Column(
                children: [
                  _buildInvoiceStickyHeader(theme, isAr, idx, widths),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () => _loadInvoices(page: _currentPage),
                      color: theme.colorScheme.primary,
                      backgroundColor: theme.colorScheme.surface,
                      child: ListView.builder(
                        primary: true,
                        padding: EdgeInsets.zero,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: invoices.length,
                        itemBuilder: (context, rowIndex) {
                          final invoice = Map<String, dynamic>.from(
                            invoices[rowIndex],
                          );
                          return _buildInvoiceStickyRow(
                            invoice: invoice,
                            rowIndex: rowIndex,
                            isAr: isAr,
                            theme: theme,
                            colorScheme: colorScheme,
                            widths: widths,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInvoiceStickyHeader(
    ThemeData theme,
    bool isAr,
    int idx,
    Map<String, double> widths,
  ) {
    return Container(
      height: 66,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Row(
        children: [
          _buildStickyHeaderCell(
            label: isAr ? 'رقم' : 'No.',
            width: widths['number']!,
            onTap: () => _changeSort(
              'number',
              !(_tabSort[idx] == 'number' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'number',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'العميل' : 'Customer',
            width: widths['customer']!,
            onTap: () => _changeSort(
              'customer',
              !(_tabSort[idx] == 'customer' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'customer',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'المنشئ' : 'Creator',
            width: widths['creator']!,
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'التاريخ' : 'Date',
            width: widths['date']!,
            onTap: () => _changeSort(
              'date',
              !(_tabSort[idx] == 'date' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'date',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'نوع الذهب' : 'Gold Type',
            width: widths['type']!,
            onTap: () => _changeSort(
              'type',
              !(_tabSort[idx] == 'type' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'type',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'العيار' : 'Karat',
            width: widths['karat']!,
          ),
          _buildInvoiceMetricHeaderCell(
            label: isAr ? 'الوزن' : 'Weight',
            unit: isAr ? 'غ' : 'g',
            width: widths['weight']!,
            icon: Icons.scale_outlined,
            color: const Color(0xFFD4A017),
            onTap: () => _changeSort(
              'weight',
              !(_tabSort[idx] == 'weight' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'weight',
            ascending: _tabSortAsc[idx],
          ),
          _buildInvoiceMetricHeaderCell(
            label: isAr ? 'المبلغ' : 'Amount',
            unit: isAr ? 'ر.س' : 'SAR',
            width: widths['amount']!,
            icon: Icons.payments_outlined,
            color: const Color(0xFF2F80ED),
            onTap: () => _changeSort(
              'amount',
              !(_tabSort[idx] == 'amount' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'amount',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: isAr ? 'الحالة' : 'Status',
            width: widths['status']!,
            onTap: () => _changeSort(
              'status',
              !(_tabSort[idx] == 'status' && _tabSortAsc[idx]),
            ),
            isActive: _tabSort[idx] == 'status',
            ascending: _tabSortAsc[idx],
          ),
          _buildStickyHeaderCell(
            label: '⋮',
            width: widths['actions']!,
            alignment: Alignment.center,
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceStickyRow({
    required Map<String, dynamic> invoice,
    required int rowIndex,
    required bool isAr,
    required ThemeData theme,
    required ColorScheme colorScheme,
    required Map<String, double> widths,
  }) {
    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
    final partyName =
        (invoice['customer_name'] ?? invoice['supplier_name'])
            ?.toString()
            .trim() ??
        (isAr ? 'غير محدد' : 'N/A');
    final totalWeight = _extractInvoiceTotalWeight(invoice);
    final rawWeight = _extractInvoiceRawWeight(invoice);
    final showRaw = (rawWeight - totalWeight).abs() > 0.001;
    final amount = _tryParseDouble(invoice['total']);
    final karat = _extractInvoiceKaratLabel(invoice) ?? '—';
    final employeeName = _extractInvoiceEmployeeName(invoice) ?? '—';
    final normalizedStatus = _normalizeStatus(
      (invoice['status'] ?? '').toString(),
    );

    return Material(
      color: rowIndex.isEven
          ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.14)
          : colorScheme.surface,
      child: InkWell(
        onTap: () => _openInvoicePreview(invoice),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            children: [
              _buildStickyBodyCell(
                width: widths['number']!,
                child: Tooltip(
                  message: invoiceDisplayNumber,
                  child: Text(
                    invoiceDisplayNumber,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ),
              _buildStickyBodyCell(
                width: widths['customer']!,
                child: Tooltip(
                  message: partyName,
                  child: Text(
                    partyName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              _buildStickyBodyCell(
                width: widths['creator']!,
                child: Text(
                  employeeName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              _buildStickyBodyCell(
                width: widths['date']!,
                child: Text(_formatDate(invoice['date'], isAr)),
              ),
              _buildStickyBodyCell(
                width: widths['type']!,
                child: _buildTypeBadge(invoice),
              ),
              _buildStickyBodyCell(width: widths['karat']!, child: Text(karat)),
              _buildInvoiceMetricValueCell(
                width: widths['weight']!,
                value: NumberFormat(
                  '#,##0.###',
                  isAr ? 'ar' : 'en',
                ).format(totalWeight),
                sub: showRaw
                    ? NumberFormat('#,##0.###', isAr ? 'ar' : 'en').format(rawWeight)
                    : null,
                icon: Icons.scale_outlined,
                color: const Color(0xFFD4A017),
                emphasize: true,
              ),
              _buildInvoiceMetricValueCell(
                width: widths['amount']!,
                value:
                    '${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(amount)} ${isAr ? 'ر.س' : 'SAR'}',
                icon: Icons.payments_outlined,
                color: const Color(0xFF2F80ED),
                emphasize: false,
              ),
              _buildStickyBodyCell(
                width: widths['status']!,
                child: _buildStatusBadge(normalizedStatus),
              ),
              _buildStickyBodyCell(
                width: widths['actions']!,
                alignment: Alignment.center,
                child: _buildInvoiceActionsMenu(invoice),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStickyHeaderCell({
    required String label,
    required double width,
    AlignmentGeometry alignment = Alignment.center,
    VoidCallback? onTap,
    bool isActive = false,
    bool ascending = false,
  }) {
    final theme = Theme.of(context);
    final child = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: isActive ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 4),
            Icon(
              ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }

  Widget _buildInvoiceMetricHeaderCell({
    required String label,
    required String unit,
    required double width,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool isActive = false,
    bool ascending = false,
  }) {
    final theme = Theme.of(context);
    final child = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: isActive ? 0.30 : 0.18),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isActive ? color : Colors.grey.shade800,
                      height: 1.0,
                    ),
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 4),
                  Icon(
                    ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 13,
                    color: color,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              unit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.92),
                fontWeight: FontWeight.w700,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );

    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }

  Widget _buildStickyBodyCell({
    required double width,
    required Widget child,
    AlignmentGeometry alignment = Alignment.center,
  }) {
    return Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: child,
    );
  }

  Widget _buildInvoiceMetricValueCell({
    required double width,
    required String value,
    required IconData icon,
    required Color color,
    required bool emphasize,
    String? sub,
  }) {
    return _buildStickyBodyCell(
      width: width,
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasize ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: emphasize ? 0.26 : 0.14),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
                      color: emphasize ? color.withValues(alpha: 0.98) : color,
                    ),
                  ),
                  if (sub != null)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.grey.shade500,
                        fontSize: 9,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeSort(String sortBy, bool asc) async {
    final idx = _tabController.index;
    setState(() {
      _tabSort[idx] = sortBy;
      _tabSortAsc[idx] = asc;
      _currentPage = 1;
    });
    await _loadInvoices(page: 1);
  }

  Widget _buildTypeBadge(Map<String, dynamic> invoice) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final rawType = (invoice['gold_type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final isScrap = rawType == 'scrap';
    final label = isScrap ? (isAr ? 'كسر' : 'Scrap') : (isAr ? 'جديد' : 'New');
    final color = isScrap ? Colors.blueGrey : const Color(0xFFD4A017);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    Color color;
    IconData icon;

    switch (status) {
      case 'paid':
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case 'partially_paid':
        color = Colors.orange;
        icon = Icons.timelapse;
        break;
      case 'cancelled':
        color = theme.colorScheme.onSurfaceVariant;
        icon = Icons.block;
        break;
      default:
        color = Colors.redAccent;
        icon = Icons.pending_actions;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _translateStatus(status, isAr),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoiceActionsMenu(Map<String, dynamic> invoice) {
    final isAr = widget.isArabic;
    final isCancelled =
        _normalizeStatus((invoice['status'] ?? '').toString()) == 'cancelled';
    final canEditContent = invoice['is_posted'] != true && !isCancelled;
    final isPosted = invoice['is_posted'] == true;
    final isManager = Provider.of<AuthProvider>(context, listen: false).isManager;

    PopupMenuItem<_InvoiceRowAction> item({
      required _InvoiceRowAction value,
      required IconData icon,
      required String label,
      bool enabled = true,
    }) {
      return PopupMenuItem<_InvoiceRowAction>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 10),
            Text(label),
          ],
        ),
      );
    }

    return PopupMenuButton<_InvoiceRowAction>(
      tooltip: isAr ? 'الإجراءات' : 'Actions',
      onSelected: (action) => _handleInvoiceAction(invoice, action),
      itemBuilder: (context) => [
        item(
          value: _InvoiceRowAction.view,
          icon: Icons.visibility_outlined,
          label: isAr ? 'عرض' : 'View',
        ),
        item(
          value: _InvoiceRowAction.editContent,
          icon: Icons.edit_outlined,
          label: isAr ? 'تعديل' : 'Edit',
          enabled: canEditContent,
        ),
        item(
          value: _InvoiceRowAction.print,
          icon: Icons.print_outlined,
          label: isAr ? 'طباعة' : 'Print',
        ),
        if (canEditContent &&
            Provider.of<AuthProvider>(context, listen: false).isManager)
          item(
            value: _InvoiceRowAction.changeEmployee,
            icon: Icons.person_outlined,
            label: isAr ? 'تغيير المنشئ' : 'Change Creator',
          ),
        if (!isPosted && !isCancelled && isManager)
          item(
            value: _InvoiceRowAction.post,
            icon: Icons.check_circle_outline,
            label: isAr ? 'ترحيل' : 'Post',
          ),
        if (isPosted && isManager)
          item(
            value: _InvoiceRowAction.unpost,
            icon: Icons.cancel_outlined,
            label: isAr ? 'إلغاء الترحيل' : 'Unpost',
          ),
        item(
          value: _InvoiceRowAction.delete,
          icon: Icons.delete_outline,
          label: isAr ? 'حذف' : 'Delete',
          enabled: !isCancelled,
        ),
      ],
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.more_horiz, size: 18),
      ),
    );
  }

  Future<void> _handleInvoiceAction(
    Map<String, dynamic> invoice,
    _InvoiceRowAction action,
  ) async {
    switch (action) {
      case _InvoiceRowAction.view:
        await _openInvoicePreview(invoice);
        break;
      case _InvoiceRowAction.editContent:
        await _editInvoiceContent(invoice);
        break;
      case _InvoiceRowAction.print:
        await _viewInvoiceDetails(invoice, autoPrint: true);
        break;
      case _InvoiceRowAction.changeEmployee:
        await _changeInvoiceEmployee(invoice);
        break;
      case _InvoiceRowAction.post:
        await _postInvoiceAction(invoice);
        break;
      case _InvoiceRowAction.unpost:
        await _unpostInvoiceAction(invoice);
        break;
      case _InvoiceRowAction.delete:
        await _deleteInvoice(invoice);
        break;
    }
  }


  Future<void> _postInvoiceAction(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final invoiceId = invoice['id'] as int?;
    if (invoiceId == null) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final postedBy = authProvider.currentUser?.username ?? 'admin';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.green),
          const SizedBox(width: 8),
          Text(isAr ? 'تأكيد الترحيل' : 'Confirm Post'),
        ]),
        content: Text(
          isAr
              ? 'هل تريد ترحيل الفاتورة رقم ${invoice['invoice_number'] ?? invoiceId}؟'
              : 'Post invoice ${invoice['invoice_number'] ?? invoiceId}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: Text(isAr ? 'ترحيل' : 'Post',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _apiService.postInvoice(invoiceId, postedBy);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isAr ? 'تم الترحيل بنجاح' : 'Invoice posted successfully'),
        backgroundColor: Colors.green,
      ));
      AppEvents.notifyVaultChanged();
      _loadInvoices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isAr ? 'فشل الترحيل: ${e.toString()}' : 'Post failed: ${e.toString()}'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _unpostInvoiceAction(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final invoiceId = invoice['id'] as int?;
    if (invoiceId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.cancel_outlined, color: Colors.orange),
          const SizedBox(width: 8),
          Text(isAr ? 'تأكيد إلغاء الترحيل' : 'Confirm Unpost'),
        ]),
        content: Text(
          isAr
              ? 'هل تريد إلغاء ترحيل الفاتورة رقم ${invoice['invoice_number'] ?? invoiceId}؟\nسيتم عكس جميع حركات الخزائن والقيود المرتبطة.'
              : 'Unpost invoice ${invoice['invoice_number'] ?? invoiceId}?\nAll vault movements and related entries will be reversed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(isAr ? 'إلغاء الترحيل' : 'Unpost',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _apiService.unpostInvoice(invoiceId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isAr ? 'تم إلغاء الترحيل بنجاح' : 'Invoice unposted successfully'),
        backgroundColor: Colors.orange,
      ));
      AppEvents.notifyVaultChanged();
      _loadInvoices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          isAr ? 'فشل إلغاء الترحيل: ${e.toString()}' : 'Unpost failed: ${e.toString()}'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _changeInvoiceEmployee(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final invoiceId = invoice['id'] as int?;
    if (invoiceId == null) return;

    List<EmployeeModel> empList = [];
    try {
      final res = await _apiService.getEmployees(perPage: 200, isActive: true);
      empList = res['employees'] as List<EmployeeModel>? ?? [];
    } catch (_) {}

    if (!mounted) return;
    if (empList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isAr ? 'لا يوجد موظفون' : 'No employees')),
      );
      return;
    }

    int? selectedId = invoice['employee_id'] is int
        ? invoice['employee_id'] as int
        : null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Row(children: [
            const Icon(Icons.person_outlined, color: Colors.orange),
            const SizedBox(width: 8),
            Text(isAr ? 'تغيير المنشئ' : 'Change Creator'),
          ]),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isAr ? 'الفاتورة' : 'Invoice'}: ${invoice['invoice_number'] ?? invoiceId}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${isAr ? 'المنشئ الحالي' : 'Current'}: ${invoice['employee_name'] ?? invoice['posted_by'] ?? '—'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  value: selectedId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الموظف الجديد' : 'New Employee',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: empList
                      .where((e) => e.id != null)
                      .map((e) => DropdownMenuItem(
                            value: e.id!,
                            child: Text(e.name, style: const TextStyle(fontSize: 13)),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => selectedId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton.icon(
              onPressed: selectedId == null ? null : () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check, size: 16),
              label: Text(isAr ? 'تأكيد' : 'Confirm'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || selectedId == null || !mounted) return;

    try {
      await _apiService.reassignInvoiceEmployee(invoiceId, selectedId!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(isAr ? 'تم تغيير المنشئ' : 'Creator updated'),
        backgroundColor: Colors.green,
      ));
      _loadInvoices(page: _currentPage);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${isAr ? 'خطأ' : 'Error'}: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Widget _buildStatisticsSection() {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final statsBackground = colorScheme.surfaceContainerHighest.withValues(
      alpha: isDark ? 0.35 : 0.2,
    );

    // Get statistics for current tab
    final tabStats = _getTabStatistics();

    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: statsBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Icons.receipt_long,
                  title: isAr ? 'إجمالي الفواتير' : 'Total Invoices',
                  value: tabStats['total_invoices'].toString(),
                  highlightColor: Colors.blue,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.attach_money,
                  title: isAr ? 'المبلغ الكلي' : 'Total Amount',
                  value: NumberFormat(
                    '#,##0',
                    isAr ? 'ar' : 'en',
                  ).format(tabStats['total_amount']),
                  highlightColor: const Color(0xFF2F80ED),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.scale,
                  title: isAr ? 'إجمالي الوزن' : 'Total Weight',
                  value: NumberFormat(
                    '#,##0.###',
                    isAr ? 'ar' : 'en',
                  ).format(tabStats['sold_weight_total']),
                  sub: isAr ? 'جم (عيار رئيسي مكافئ)' : 'g (main karat equiv.)',
                  highlightColor: colorScheme.secondary,
                  emphasize: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color highlightColor,
    bool emphasize = false,
    String? sub,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      elevation: theme.cardTheme.elevation ?? 2,
      color: emphasize ? null : theme.cardTheme.color ?? colorScheme.surface,
      shape:
          theme.cardTheme.shape ??
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Ink(
          decoration: BoxDecoration(
            gradient: emphasize
                ? LinearGradient(
                    colors: [
                      highlightColor.withValues(alpha: 0.14),
                      colorScheme.surface,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: highlightColor.withValues(alpha: emphasize ? 0.26 : 0.10),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: highlightColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: highlightColor, size: 14),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: textTheme.titleLarge?.copyWith(
                    color: highlightColor,
                    fontWeight: emphasize ? FontWeight.w900 : FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                if (sub != null)
                  Text(
                    sub,
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.45),
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Map<String, String>> _buildStatusItems(bool isArabic) {
    return [
      {'value': 'all', 'label': isArabic ? 'الكل' : 'All'},
      {
        'value': 'paid_full',
        'label': isArabic ? 'مدفوعة بالكامل' : 'Paid (Full)',
      },
      {'value': 'remaining', 'label': isArabic ? 'المتبقي/الآجل' : 'Remaining'},
      {'value': 'paid', 'label': isArabic ? 'مدفوعة' : 'Paid'},
      {
        'value': 'partially_paid',
        'label': isArabic ? 'مدفوعة جزئياً' : 'Partially Paid',
      },
      {'value': 'unpaid', 'label': isArabic ? 'غير مدفوعة' : 'Unpaid'},
      // Invoice drafts are not supported.
      {'value': 'cancelled', 'label': isArabic ? 'ملغاة' : 'Cancelled'},
    ];
  }

  Widget _buildInvoiceCard(Map<String, dynamic> invoice) {
    try {
      final isAr = widget.isArabic;
      final normalizedStatus = _normalizeStatus(
        (invoice['status'] ?? '').toString(),
      );
      final bool isPaid = normalizedStatus == 'paid';
      final bool isCancelled = normalizedStatus == 'cancelled';
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      final textTheme = theme.textTheme;
      final statusColor = isCancelled
          ? colorScheme.onSurfaceVariant.withValues(alpha: 0.8)
          : (isPaid ? Colors.green : Colors.orange);
      final invoiceType = (invoice['invoice_type'] ?? '').toString();
      final bool isPurchase =
          invoiceType.contains('شراء') || invoiceType.toLowerCase() == 'buy';
      final Color typeColor = isPurchase ? Colors.blue : colorScheme.primary;
      final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);

      final employeeName = _extractInvoiceEmployeeName(invoice);

      final karatLabel = _extractInvoiceKaratLabel(invoice);
      final goldTypeLabel = _extractInvoiceGoldTypeLabel(invoice);
      final totalWeight = _extractInvoiceTotalWeight(invoice);

      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: theme.cardTheme.color ?? colorScheme.surface,
        shape:
            theme.cardTheme.shape ??
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: () => _openInvoicePreview(invoice),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        invoiceDisplayNumber,
                        style: textTheme.titleSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        invoiceType,
                        style: textTheme.bodySmall?.copyWith(
                          color: typeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isPaid ? Icons.check_circle : Icons.pending,
                            color: statusColor,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _translateStatus(normalizedStatus, isAr),
                            style: textTheme.bodySmall?.copyWith(
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildInvoiceActionsMenu(invoice),
                  ],
                ),
                const SizedBox(height: 12),

                // Customer and Date
                Row(
                  children: [
                    Icon(
                      Icons.person,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (invoice['customer_name'] ??
                                        invoice['supplier_name'])
                                    ?.toString() ??
                                (isAr ? 'غير محدد' : 'N/A'),
                            style: textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                            ),
                          ),
                          if (employeeName != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              isAr
                                  ? 'الموظف: $employeeName'
                                  : 'Employee: $employeeName',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      Icons.calendar_today,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDate(invoice['date'], isAr),
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Gold tags (karat + total weight)
                if (karatLabel != null ||
                    goldTypeLabel != null ||
                    totalWeight > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (goldTypeLabel != null)
                          _buildInfoChip(
                            label: isAr
                                ? 'النوع: $goldTypeLabel'
                                : 'Type: $goldTypeLabel',
                            colorScheme: colorScheme,
                          ),
                        if (karatLabel != null)
                          _buildInfoChip(
                            label: isAr
                                ? 'عيار: $karatLabel'
                                : 'Karat: $karatLabel',
                            colorScheme: colorScheme,
                          ),
                        if (totalWeight > 0)
                          _buildInfoChip(
                            label: isAr
                                ? 'وزن: ${NumberFormat('#,##0.###', isAr ? 'ar' : 'en').format(totalWeight)} جم'
                                : 'Weight: ${NumberFormat('#,##0.###', isAr ? 'ar' : 'en').format(totalWeight)} g',
                            colorScheme: colorScheme,
                          ),
                        if (isCancelled)
                          _buildInfoChip(
                            label: isAr ? 'ملغاة' : 'Cancelled',
                            colorScheme: colorScheme,
                          ),
                      ],
                    ),
                  ),

                // Amount
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: theme.brightness == Brightness.dark ? 0.35 : 0.8,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isAr ? 'الإجمالي:' : 'Total:',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      Text(
                        '${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(((invoice['total'] ?? 0) as num).toDouble())} ${isAr ? 'ريال' : 'SAR'}',
                        style: textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF2F80ED),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 16,
                      color: colorScheme.onSurface.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isAr
                            ? 'اضغط على البطاقة لعرض الفاتورة، واستخدم القائمة للمزيد'
                            : 'Tap the card to view, or use the menu for actions',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('❌ خطأ في بناء بطاقة الفاتورة: $e');
      debugPrint('Stack: $stackTrace');
      final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
      // Return simple error card
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: Colors.red.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'خطأ في عرض الفاتورة $invoiceDisplayNumber',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.red),
          ),
        ),
      );
    }
  }

  String _formatDate(dynamic date, bool isAr) {
    try {
      if (date == null) return isAr ? 'غير محدد' : 'N/A';
      final dateTime = DateTime.parse(date.toString());
      return DateFormat('yyyy-MM-dd').format(dateTime);
    } catch (e) {
      return isAr ? 'غير محدد' : 'N/A';
    }
  }

  Widget _buildInfoChip({
    required String label,
    required ColorScheme colorScheme,
  }) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final bg = colorScheme.surfaceContainerHighest.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.35 : 0.7,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.12)),
      ),
      child: Text(
        label,
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final isAr = widget.isArabic;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long,
            size: 80,
            color: colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            isAr ? 'لا توجد فواتير' : 'No Invoices',
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isAr ? 'ابدأ بإضافة فاتورة جديدة' : 'Start by adding a new invoice',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _viewInvoiceDetails(
    Map<String, dynamic> invoice, {
    bool autoPrint = false,
    bool autoSharePdf = false,
    bool autoDownloadPdf = false,
    bool autoWhatsApp = false,
  }) async {
    final invoiceIdValue = invoice['id'];
    final invoiceId = invoiceIdValue is int
        ? invoiceIdValue
        : int.tryParse(invoiceIdValue?.toString() ?? '');

    if (invoiceId == null) {
      _showSnackBar(
        widget.isArabic ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
        isError: true,
      );
      return;
    }

    var loaderVisible = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => loaderVisible = false);

    try {
      final details = await _apiService.getInvoiceById(invoiceId);
      if (!mounted) return;
      if (loaderVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderVisible = false;
      }

      final mergedInvoice = {...invoice, ...details};

      String filename() {
        final numStr = (mergedInvoice['invoice_type_id'] ?? '')
            .toString()
            .trim();
        final idStr = (mergedInvoice['id'] ?? '').toString().trim();
        final base = numStr.isNotEmpty
            ? 'invoice_$numStr'
            : (idStr.isNotEmpty ? 'invoice_$idStr' : 'invoice');
        return '$base.pdf';
      }

      final wantsWhatsApp = autoWhatsApp;
      final wantsShare = autoSharePdf || autoDownloadPdf;
      final wantsPrint = autoPrint || (!wantsShare && !wantsWhatsApp);

      if (wantsWhatsApp) {
        await shareInvoiceWhatsApp(
          context: context,
          invoice: mergedInvoice,
          isArabic: widget.isArabic,
        );
      }

      if (wantsShare) {
        final bytes = await buildInvoicePdfBytes(
          context: context,
          invoice: mergedInvoice,
          format: PdfPageFormat.a4,
          isArabic: widget.isArabic,
        );
        await Printing.sharePdf(bytes: bytes, filename: filename());
      }

      if (wantsPrint) {
        await printInvoiceDirect(
          context: context,
          invoice: mergedInvoice,
          isArabic: widget.isArabic,
        );
      }
    } catch (e) {
      if (loaderVisible && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderVisible = false;
      }
      if (mounted) {
        _showSnackBar(
          widget.isArabic
              ? 'فشل طباعة/تصدير الفاتورة: $e'
              : 'Failed to print/export invoice: $e',
          isError: true,
        );
      }
    }
  }

  Future<void> _openInvoicePreview(Map<String, dynamic> invoice) async {
    final invoiceIdValue = invoice['id'];
    final invoiceId = invoiceIdValue is int
        ? invoiceIdValue
        : int.tryParse(invoiceIdValue?.toString() ?? '');

    if (invoiceId == null) {
      _showSnackBar(
        widget.isArabic ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
        isError: true,
      );
      return;
    }

    var loaderVisible = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => loaderVisible = false);

    try {
      final details = await _apiService.getInvoiceById(invoiceId);
      if (!mounted) return;
      if (loaderVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderVisible = false;
      }

      final mergedInvoice = {...invoice, ...details};
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        // Wider than Material 3's default (~640) so the item chip row (qty,
        // karat, weight, wage, price, total) fits on one line instead of
        // wrapping to a second row on desktop-width screens.
        constraints: const BoxConstraints(maxWidth: 820),
        builder: (sheetContext) {
          return _buildInvoicePreviewSheet(sheetContext, mergedInvoice);
        },
      );
    } catch (e) {
      if (loaderVisible && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderVisible = false;
      }
      if (mounted) {
        _showSnackBar(
          widget.isArabic
              ? 'فشل تحميل تفاصيل الفاتورة: $e'
              : 'Failed to load invoice details: $e',
          isError: true,
        );
      }
    }
  }

  Widget _buildInvoicePreviewSheet(
    BuildContext sheetContext,
    Map<String, dynamic> invoice,
  ) {
    final isAr = widget.isArabic;
    final theme = Theme.of(sheetContext);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final normalizedStatus = _normalizeStatus(
      (invoice['status'] ?? '').toString(),
    );
    final isCancelled = normalizedStatus == 'cancelled';

    final total = _tryParseDouble(invoice['total']);
    final tax = _tryParseDouble(invoice['total_tax']);
    final subtotal = (total - tax).clamp(0.0, double.infinity);

    final paidCash = _tryParseDouble(
      invoice['amount_paid'] ?? invoice['total_payments_amount'],
    );
    final barterTotal = _tryParseDouble(invoice['barter_total']);
    final hasTotalSettledKey = invoice.containsKey('total_settled_amount');
    final totalSettled = hasTotalSettledKey
        ? _tryParseDouble(invoice['total_settled_amount'])
        : (paidCash + barterTotal);
    final paid = totalSettled;
    final remaining = (total - totalSettled).clamp(0.0, double.infinity);
    final canSettle = !isCancelled && remaining > 0.01;

    final invoiceNumber = _getInvoiceDisplayNumber(invoice);
    final customerName =
        invoice['customer_name']?.toString() ?? (isAr ? 'غير محدد' : 'N/A');
    final invoiceType = (invoice['invoice_type'] ?? '').toString();

    final items = (invoice['items'] is List)
        ? (invoice['items'] as List)
        : const [];

    final karatLines = (invoice['karat_lines'] is List)
        ? (invoice['karat_lines'] as List)
        : const [];

    final payments = (invoice['payments'] is List)
        ? (invoice['payments'] as List)
        : const [];

    final auth = Provider.of<AuthProvider>(sheetContext, listen: false);
    final canSeeLogs = auth.isManager;

    final invoiceDate = _tryParseDateTime(invoice['date']);
    final minutesSince = invoiceDate == null
        ? null
        : DateTime.now().difference(invoiceDate).inMinutes;
    const editWindowMinutes = 15;
    final withinEditWindow =
        minutesSince != null && minutesSince <= editWindowMinutes;
    final canDirectEdit = auth.isManager || withinEditWindow;

    final returnType = _returnTypeForInvoice(invoiceType);
    final canReturn = returnType != null;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.98,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 10),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            invoiceNumber,
                            style: textTheme.titleLarge?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$invoiceType • $customerName',
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.75,
                              ),
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: isAr ? 'إغلاق' : 'Close',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Action bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _viewInvoiceDetails(invoice, autoPrint: true);
                        },
                        icon: const Icon(Icons.print, size: 18),
                        label: Text(isAr ? 'طباعة' : 'Print'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _viewInvoiceDetails(invoice, autoDownloadPdf: true);
                        },
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(isAr ? 'تحميل PDF' : 'Download PDF'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          _viewInvoiceDetails(invoice, autoSharePdf: true);
                        },
                        icon: const Icon(Icons.share, size: 18),
                        label: Text(isAr ? 'مشاركة' : 'Share'),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    // Status + date
                    Row(
                      children: [
                        _buildInfoChip(
                          label: isAr
                              ? 'الحالة: ${_translateStatus(normalizedStatus, isAr)}'
                              : 'Status: ${_translateStatus(normalizedStatus, isAr)}',
                          colorScheme: colorScheme,
                        ),
                        const SizedBox(width: 8),
                        _buildInfoChip(
                          label: isAr
                              ? 'التاريخ: ${_formatDate(invoice['date'], isAr)}'
                              : 'Date: ${_formatDate(invoice['date'], isAr)}',
                          colorScheme: colorScheme,
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Items table preview
                    Text(
                      isAr ? 'الأصناف' : 'Items',
                      style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),

                    if (items.isEmpty && karatLines.isNotEmpty)
                      ...karatLines.map((raw) {
                        final kl = raw is Map
                            ? raw.map((k, v) => MapEntry(k.toString(), v))
                            : <String, dynamic>{};
                        final karat = kl['karat']?.toString() ?? '';
                        final weight = (kl['weight_grams'] as num?)?.toDouble() ?? 0.0;
                        final pricePerGram = (kl['price_per_gram'] as num?)?.toDouble() ?? 0.0;
                        final goldValue = (kl['gold_value'] as num?)?.toDouble() ?? 0.0;
                        final fmt = NumberFormat('#,##0.###', 'en');
                        final fmtCash = NumberFormat('#,##0.00', 'en');
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          elevation: 0,
                          color: colorScheme.surfaceContainerHighest.withValues(
                            alpha: theme.brightness == Brightness.dark ? 0.35 : 0.6,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  karat == '24'
                                      ? (isAr ? 'ذهب صافي — عيار 24' : 'Pure Gold — 24k')
                                      : (isAr ? 'ذهب كسر — عيار $karat' : 'Scrap Gold — ${karat}k'),
                                  style: textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (karat.isNotEmpty)
                                      _buildInfoChip(label: isAr ? 'عيار: $karat' : 'Karat: $karat', colorScheme: colorScheme),
                                    if (weight > 0)
                                      _buildInfoChip(label: isAr ? 'وزن: ${fmt.format(weight)} جم' : 'Weight: ${fmt.format(weight)} g', colorScheme: colorScheme),
                                    if (pricePerGram > 0)
                                      _buildInfoChip(label: isAr ? 'سعر/جم: ${fmtCash.format(pricePerGram)}' : 'Price/g: ${fmtCash.format(pricePerGram)}', colorScheme: colorScheme),
                                    if (goldValue > 0)
                                      _buildInfoChip(label: isAr ? 'القيمة: ${fmtCash.format(goldValue)}' : 'Value: ${fmtCash.format(goldValue)}', colorScheme: colorScheme),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      })
                    else if (items.isEmpty)
                      Text(
                        isAr ? 'لا توجد أصناف' : 'No items',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      )
                    else
                      ...items.map((raw) {
                        final item = raw is Map
                            ? raw.map((k, v) => MapEntry(k.toString(), v))
                            : <String, dynamic>{};

                        final name = (item['name'] ?? '').toString();
                        final qty = _tryParseInt(item['quantity']) ?? 1;
                        final weight = _tryParseDouble(item['weight']);
                        final karat = item['karat']?.toString();
                        final wage = _tryParseDouble(item['wage']);
                        final itemTax = _tryParseDouble(item['tax']);
                        final itemTotal = _tryParseDouble(
                          item['price'] ?? item['total'],
                        );

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          elevation: 0,
                          color: colorScheme.surfaceContainerHighest.withValues(
                            alpha: theme.brightness == Brightness.dark
                                ? 0.35
                                : 0.6,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name.isNotEmpty
                                      ? name
                                      : (isAr ? 'صنف' : 'Item'),
                                  style: textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _buildInfoChip(
                                      label: isAr
                                          ? 'الكمية: $qty'
                                          : 'Qty: $qty',
                                      colorScheme: colorScheme,
                                    ),
                                    if (karat != null &&
                                        karat.trim().isNotEmpty)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'عيار: $karat'
                                            : 'Karat: $karat',
                                        colorScheme: colorScheme,
                                      ),
                                    if (weight > 0)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'وزن: ${NumberFormat('#,##0.###', isAr ? 'ar' : 'en').format(weight)} جم'
                                            : 'Weight: ${NumberFormat('#,##0.###', isAr ? 'ar' : 'en').format(weight)} g',
                                        colorScheme: colorScheme,
                                      ),
                                    if (wage > 0)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'أجور: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(wage)}'
                                            : 'Wage: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(wage)}',
                                        colorScheme: colorScheme,
                                      ),
                                    if (weight > 0)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'السعر: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format((itemTotal - wage - itemTax) / weight)}'
                                            : 'Price: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format((itemTotal - wage - itemTax) / weight)}',
                                        colorScheme: colorScheme,
                                      ),
                                    if (itemTax > 0)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'ضريبة: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(itemTax)}'
                                            : 'Tax: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(itemTax)}',
                                        colorScheme: colorScheme,
                                      ),
                                    if (itemTotal > 0)
                                      _buildInfoChip(
                                        label: isAr
                                            ? 'الإجمالي: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(itemTotal)}'
                                            : 'Total: ${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(itemTotal)}',
                                        colorScheme: colorScheme,
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }),

                    const SizedBox(height: 12),

                    // Summary
                    Text(
                      isAr ? 'الملخص المالي' : 'Summary',
                      style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      elevation: 0,
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: theme.brightness == Brightness.dark ? 0.35 : 0.6,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            _buildSummaryRow(
                              label: isAr ? 'قبل الضريبة' : 'Subtotal',
                              value: subtotal,
                              isAr: isAr,
                              colorScheme: colorScheme,
                            ),
                            const SizedBox(height: 8),
                            _buildSummaryRow(
                              label: isAr ? 'الضريبة' : 'VAT',
                              value: tax,
                              isAr: isAr,
                              colorScheme: colorScheme,
                            ),
                            const Divider(height: 18),
                            _buildSummaryRow(
                              label: isAr ? 'الإجمالي' : 'Total',
                              value: total,
                              isAr: isAr,
                              colorScheme: colorScheme,
                              emphasize: true,
                            ),
                            const SizedBox(height: 8),
                            _buildSummaryRow(
                              label: isAr ? 'المدفوع' : 'Paid',
                              value: paid,
                              isAr: isAr,
                              colorScheme: colorScheme,
                            ),
                            if (barterTotal > 0.01) ...[
                              const SizedBox(height: 8),
                              _buildSummaryRow(
                                label: isAr
                                    ? 'المقايضة (قيمة)'
                                    : 'Barter (Value)',
                                value: barterTotal,
                                isAr: isAr,
                                colorScheme: colorScheme,
                              ),
                            ],
                            const SizedBox(height: 8),
                            _buildSummaryRow(
                              label: isAr ? 'المتبقي' : 'Remaining',
                              value: remaining,
                              isAr: isAr,
                              colorScheme: colorScheme,
                            ),
                          ],
                        ),
                      ),
                    ),

                    if (payments.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        isAr ? 'الدفعات' : 'Payments',
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        elevation: 0,
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.35
                              : 0.6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: payments.map<Widget>((raw) {
                              final Map<String, dynamic> payment = raw is Map
                                  ? raw.map((k, v) => MapEntry(k.toString(), v))
                                  : <String, dynamic>{};

                              final paymentId = _tryParseInt(payment['id']);
                              final amount = _tryParseDouble(payment['amount']);
                              final currentMethodId = _tryParseInt(payment['payment_method_id']);
                              final methodName =
                                  (payment['payment_method_name'] ?? '')
                                      .toString();
                              final createdAt = (payment['created_at'] ?? '')
                                  .toString();
                              final notes = (payment['notes'] ?? '')
                                  .toString()
                                  .trim();

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.payments_outlined,
                                                size: 18,
                                                color: colorScheme.primary,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  methodName.isNotEmpty
                                                      ? methodName
                                                      : (isAr
                                                            ? 'وسيلة دفع'
                                                            : 'Payment method'),
                                                  style: textTheme.bodyMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w800,
                                                      ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              Text(
                                                NumberFormat(
                                                  '#,##0.00',
                                                  isAr ? 'ar' : 'en',
                                                ).format(amount),
                                                style: textTheme.bodyMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color:
                                                          colorScheme.primary,
                                                    ),
                                              ),
                                            ],
                                          ),
                                          if (createdAt.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              isAr
                                                  ? 'تاريخ: ${_formatDate(createdAt, isAr)}'
                                                  : 'Date: ${_formatDate(createdAt, isAr)}',
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme.onSurface
                                                        .withValues(alpha: 0.7),
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                          if (notes.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              notes,
                                              style: textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: colorScheme.onSurface
                                                        .withValues(alpha: 0.7),
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    IconButton(
                                      onPressed: paymentId == null
                                          ? null
                                          : () => _openLinkedVoucherForPayment(
                                              sheetContext: sheetContext,
                                              invoice: invoice,
                                              invoicePaymentId: paymentId,
                                            ),
                                      tooltip: isAr
                                          ? 'عرض السند المرتبط'
                                          : 'View linked voucher',
                                      icon: Icon(
                                        Icons.receipt_long,
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    if (auth.isManager && paymentId != null)
                                      IconButton(
                                        onPressed: () =>
                                            _showCorrectPaymentMethodDialog(
                                          sheetContext: sheetContext,
                                          invoice: invoice,
                                          paymentId: paymentId,
                                          currentMethodName: methodName,
                                          currentAmount: amount,
                                          currentMethodId: currentMethodId,
                                        ),
                                        tooltip: isAr
                                            ? 'تصحيح وسيلة الدفع'
                                            : 'Correct payment method',
                                        icon: Icon(
                                          Icons.edit_outlined,
                                          size: 20,
                                          color: colorScheme.secondary,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ],

                    if (canSettle) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final didPay = await _showSettleRemainingDialog(
                              sheetContext: sheetContext,
                              invoice: invoice,
                              remaining: remaining,
                            );
                            if (didPay == true && mounted) {
                              Navigator.of(sheetContext).pop();
                              _invalidateInvoiceCache();
                              await _loadInvoices(forceRefresh: true);
                            }
                          },
                          icon: const Icon(Icons.payments),
                          label: Text(isAr ? 'سداد متبقي' : 'Settle Remaining'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ],

                    if (canReturn) ...[
                      const SizedBox(height: 12),
                      Card(
                        elevation: 0,
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.35
                              : 0.6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr ? 'التعديل الآمن' : 'Safe Editing',
                                style: textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                canDirectEdit
                                    ? (isAr
                                          ? 'يفضل استخدام المرتجع بدلاً من تعديل الفاتورة الأصلية للحفاظ على دقة المخزون والحسابات.'
                                          : 'Prefer using returns instead of editing the original invoice to preserve inventory/accounting integrity.')
                                    : (isAr
                                          ? 'انتهت مدة التعديل ($editWindowMinutes دقيقة). يلزم صلاحية مدير أو استخدم مرتجع.'
                                          : 'Edit window expired ($editWindowMinutes min). Manager permission required or use a return.'),
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(
                                    alpha: 0.75,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Navigator.of(sheetContext).pop();
                                    _openReturnForInvoice(invoice, returnType);
                                  },
                                  icon: const Icon(Icons.keyboard_return),
                                  label: Text(
                                    isAr ? 'إنشاء مرتجع' : 'Create Return',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    if (canSeeLogs) ...[
                      const SizedBox(height: 16),
                      Text(
                        isAr ? 'سجل الأحداث' : 'Logs',
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Card(
                        elevation: 0,
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.35
                              : 0.6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'ID: ${invoice['id'] ?? '-'}',
                                style: textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                isAr
                                    ? 'ترحيل: ${invoice['is_posted'] == true ? 'نعم' : 'لا'}'
                                    : 'Posted: ${invoice['is_posted'] == true ? 'Yes' : 'No'}',
                                style: textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 6),
                              if ((invoice['posted_at'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                Text(
                                  isAr
                                      ? 'تاريخ الترحيل: ${invoice['posted_at']}'
                                      : 'Posted at: ${invoice['posted_at']}',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                ),
                              if ((invoice['posted_by'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                Text(
                                  isAr
                                      ? 'مرحل بواسطة: ${invoice['posted_by']}'
                                      : 'Posted by: ${invoice['posted_by']}',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.75,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showCorrectPaymentMethodDialog({
    required BuildContext sheetContext,
    required Map<String, dynamic> invoice,
    required int paymentId,
    required String currentMethodName,
    double? currentAmount,
    int? currentMethodId,
  }) async {
    final isAr = Localizations.localeOf(sheetContext).languageCode == 'ar';
    final invoiceId = _tryParseInt(invoice['id']);
    if (invoiceId == null) return;

    List<dynamic> allMethods = [];
    try {
      allMethods = await _apiService.getActivePaymentMethods();
    } catch (_) {}
    // الوسيلة الحالية لا تظهر كهدف تصحيح/تقسيم (تصحيح إلى نفسها بلا معنى).
    final methods = currentMethodId == null
        ? allMethods
        : allMethods
            .where((m) => _tryParseInt(m['id']) != currentMethodId)
            .toList();

    int? selectedMethodId; // used only when NOT splitting
    final reasonController = TextEditingController();
    bool isSplit = false;
    final List<_SplitRowState> splitRows = [_SplitRowState()];

    await showDialog<void>(
      context: sheetContext,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          double sumOfSplits() => splitRows.fold<double>(
                0.0,
                (sum, r) => sum + (double.tryParse(r.amountController.text.trim()) ?? 0.0),
              );

          List<String?> rowErrors() {
            final seenMethods = <int>{};
            return splitRows.map((r) {
              if (r.paymentMethodId == null) {
                return isAr ? 'اختر وسيلة الدفع' : 'Select a payment method';
              }
              if (seenMethods.contains(r.paymentMethodId)) {
                return isAr ? 'وسيلة مكرّرة' : 'Duplicate method';
              }
              seenMethods.add(r.paymentMethodId!);
              final amt = double.tryParse(r.amountController.text.trim());
              if (amt == null || amt <= 0) {
                return isAr ? 'مبلغ غير صحيح' : 'Invalid amount';
              }
              return null;
            }).toList();
          }

          String? overallSplitError() {
            if (!isSplit) return null;
            if (currentAmount == null) {
              return isAr
                  ? 'مبلغ الدفعة الأصلي غير معروف، لا يمكن التقسيم'
                  : 'Original payment amount unknown, cannot split';
            }
            if (rowErrors().any((e) => e != null)) {
              return isAr ? 'راجع الحقول أعلاه' : 'Check the fields above';
            }
            if (sumOfSplits() > currentAmount + 0.005) {
              return isAr
                  ? 'إجمالي التقسيم أكبر من إجمالي الدفعة (${currentAmount.toStringAsFixed(2)})'
                  : 'Total split exceeds the full payment (${currentAmount.toStringAsFixed(2)})';
            }
            return null;
          }

          final remaining = (isSplit && currentAmount != null)
              ? (currentAmount - sumOfSplits())
              : null;
          final canSubmit = isSplit
              ? overallSplitError() == null
              : selectedMethodId != null;

          return AlertDialog(
            title: Text(isAr ? 'تصحيح وسيلة الدفع' : 'Correct Payment Method'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAr
                        ? 'الوسيلة الحالية: $currentMethodName${currentAmount != null ? ' (${currentAmount.toStringAsFixed(2)})' : ''}'
                        : 'Current method: $currentMethodName${currentAmount != null ? ' (${currentAmount.toStringAsFixed(2)})' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: isSplit,
                    title: Text(
                      isAr
                          ? 'هذه دفعة مدمجة، أريد تقسيمها بين عدة وسائل'
                          : 'This payment is merged, I want to split it between multiple methods',
                    ),
                    onChanged: (v) => setState(() => isSplit = v ?? false),
                  ),
                  const SizedBox(height: 4),
                  if (!isSplit)
                    DropdownButtonFormField<int>(
                      decoration: InputDecoration(
                        labelText: isAr ? 'وسيلة الدفع الصحيحة' : 'Correct method',
                        border: const OutlineInputBorder(),
                      ),
                      value: selectedMethodId,
                      items: methods.map<DropdownMenuItem<int>>((m) {
                        final id = _tryParseInt(m['id']);
                        final name = m['name']?.toString() ?? '';
                        return DropdownMenuItem(value: id, child: Text(name));
                      }).toList(),
                      onChanged: (v) => setState(() => selectedMethodId = v),
                    )
                  else ...[
                    for (var i = 0; i < splitRows.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<int>(
                                decoration: InputDecoration(
                                  labelText: isAr ? 'وسيلة' : 'Method',
                                  border: const OutlineInputBorder(),
                                  errorText: rowErrors()[i],
                                ),
                                value: splitRows[i].paymentMethodId,
                                items: methods.map<DropdownMenuItem<int>>((m) {
                                  final id = _tryParseInt(m['id']);
                                  final name = m['name']?.toString() ?? '';
                                  return DropdownMenuItem(value: id, child: Text(name));
                                }).toList(),
                                onChanged: (v) => setState(() => splitRows[i].paymentMethodId = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: splitRows[i].amountController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  labelText: isAr ? 'المبلغ' : 'Amount',
                                  border: const OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            if (splitRows.length > 1)
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                tooltip: isAr ? 'حذف' : 'Remove',
                                onPressed: () => setState(() => splitRows.removeAt(i)),
                              ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => splitRows.add(_SplitRowState())),
                        icon: const Icon(Icons.add),
                        label: Text(isAr ? 'إضافة وسيلة أخرى' : 'Add another method'),
                      ),
                    ),
                    if (remaining != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        remaining.abs() < 0.005
                            ? (isAr
                                  ? 'لن يتبقى شيء تحت $currentMethodName — الدفعة بالكامل تُنقَل لوسائل أخرى'
                                  : 'Nothing stays under $currentMethodName — fully moved to other methods')
                            : (isAr
                                  ? 'سيبقى ${remaining.toStringAsFixed(2)} تحت $currentMethodName'
                                  : '${remaining.toStringAsFixed(2)} stays under $currentMethodName'),
                        style: TextStyle(
                          color: remaining < 0
                              ? Colors.red
                              : Theme.of(ctx).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (overallSplitError() != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        overallSplitError()!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonController,
                    decoration: InputDecoration(
                      labelText: isAr ? 'سبب التصحيح' : 'Reason',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(isAr ? 'إلغاء' : 'Cancel'),
              ),
              ElevatedButton(
                onPressed: !canSubmit
                    ? null
                    : () async {
                        Navigator.pop(ctx);
                        final reason = reasonController.text.trim().isNotEmpty
                            ? reasonController.text.trim()
                            : (isAr ? 'تصحيح وسيلة الدفع' : 'Correct payment method');
                        try {
                          Map<String, dynamic> result;
                          if (isSplit) {
                            result = await _apiService.splitInvoicePaymentMethod(
                              invoiceId: invoiceId,
                              paymentId: paymentId,
                              reason: reason,
                              splits: splitRows
                                  .map((r) => {
                                        'payment_method_id': r.paymentMethodId,
                                        'amount': double.parse(r.amountController.text.trim()),
                                      })
                                  .toList(),
                            );
                          } else {
                            result = await _apiService.correctInvoicePaymentMethod(
                              invoiceId: invoiceId,
                              paymentId: paymentId,
                              newPaymentMethodId: selectedMethodId!,
                              reason: reason,
                            );
                          }
                          final wasPartial = result['is_partial'] == true;
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isAr
                                      ? (wasPartial
                                            ? 'تم تقسيم الدفعة وتصحيحها بنجاح'
                                            : 'تم تصحيح وسيلة الدفع بنجاح')
                                      : (wasPartial
                                            ? 'Payment split and corrected successfully'
                                            : 'Payment method corrected successfully'),
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                            _loadInvoices();
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  isAr ? 'خطأ: $e' : 'Error: $e',
                                ),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                child: Text(isAr ? 'تصحيح' : 'Correct'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openLinkedVoucherForPayment({
    required BuildContext sheetContext,
    required Map<String, dynamic> invoice,
    required int invoicePaymentId,
  }) async {
    final isAr = widget.isArabic;

    final invoiceIdValue = invoice['id'];
    final invoiceId = invoiceIdValue is int
        ? invoiceIdValue
        : int.tryParse(invoiceIdValue?.toString() ?? '');
    if (invoiceId == null) {
      _showSnackBar(
        isAr ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
        isError: true,
      );
      return;
    }

    var loaderVisible = true;
    showDialog(
      context: sheetContext,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => loaderVisible = false);

    try {
      final vouchers = await _apiService.getVouchersForInvoice(
        invoiceId,
        perPage: 100,
      );

      int? linkedVoucherId;
      for (final v in vouchers) {
        final notesRaw = (v['notes'] ?? '').toString().trim();
        if (!notesRaw.startsWith('{')) continue;
        try {
          final parsed = json.decode(notesRaw);
          if (parsed is Map) {
            final pid = parsed['invoice_payment_id'];
            final parsedPid = pid is int
                ? pid
                : int.tryParse(pid?.toString() ?? '');
            if (parsedPid == invoicePaymentId) {
              final vid = v['id'];
              linkedVoucherId = vid is int
                  ? vid
                  : int.tryParse(vid?.toString() ?? '');
              if (linkedVoucherId != null) break;
            }
          }
        } catch (_) {
          // ignore
        }
      }

      // Fallback: open latest linked voucher for this invoice
      linkedVoucherId ??= (() {
        if (vouchers.isEmpty) return null;
        final vid = vouchers.first['id'];
        return vid is int ? vid : int.tryParse(vid?.toString() ?? '');
      })();

      if (loaderVisible && mounted) {
        Navigator.of(sheetContext, rootNavigator: true).pop();
        loaderVisible = false;
      }

      if (linkedVoucherId == null) {
        _showSnackBar(
          isAr ? 'لا يوجد سند مرتبط بهذه الدفعة' : 'No linked voucher found',
          isError: true,
        );
        return;
      }

      if (!mounted) return;
      await showVoucherDetailsSheet(context, voucherId: linkedVoucherId);
    } catch (e) {
      if (loaderVisible && mounted) {
        Navigator.of(sheetContext, rootNavigator: true).pop();
        loaderVisible = false;
      }
      if (mounted) {
        _showSnackBar(
          isAr ? 'فشل فتح السند: $e' : 'Failed to open voucher: $e',
          isError: true,
        );
      }
    }
  }

  DateTime? _tryParseDateTime(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.parse(value.toString());
    } catch (_) {
      return null;
    }
  }

  String? _returnTypeForInvoice(String invoiceType) {
    final t = invoiceType.trim();
    if (t.isEmpty) return null;
    if (t.contains('مرتجع')) return null;
    if (t == 'بيع' || t.toLowerCase() == 'sell') return 'مرتجع بيع';
    if (t == 'شراء من عميل') return 'مرتجع شراء';
    if (t == 'شراء') return 'مرتجع شراء (مورد)';
    return null;
  }

  Future<void> _openReturnForInvoice(
    Map<String, dynamic> invoice,
    String returnType,
  ) async {
    if (!mounted) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddReturnInvoiceScreen(
          api: _apiService,
          returnType: returnType,
          prefilledOriginalInvoice: invoice,
        ),
      ),
    );

    if (result == true && mounted) {
      _invalidateInvoiceCache();
      await _loadInvoices(forceRefresh: true);
    }
  }

  Widget _buildSummaryRow({
    required String label,
    required double value,
    required bool isAr,
    required ColorScheme colorScheme,
    bool emphasize = false,
  }) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurface.withValues(alpha: 0.75),
            fontWeight: emphasize ? FontWeight.bold : FontWeight.w600,
          ),
        ),
        Text(
          NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(value),
          style: textTheme.bodyLarge?.copyWith(
            color: emphasize ? colorScheme.primary : colorScheme.onSurface,
            fontWeight: emphasize ? FontWeight.bold : FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Future<bool?> _showSettleRemainingDialog({
    required BuildContext sheetContext,
    required Map<String, dynamic> invoice,
    required double remaining,
  }) async {
    final isAr = widget.isArabic;
    final theme = Theme.of(sheetContext);
    final colorScheme = theme.colorScheme;

    final invoiceIdValue = invoice['id'];
    final invoiceId = invoiceIdValue is int
        ? invoiceIdValue
        : int.tryParse(invoiceIdValue?.toString() ?? '');
    if (invoiceId == null) {
      _showSnackBar(
        isAr ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
        isError: true,
      );
      return false;
    }

    final methodsRaw = await _apiService.getActivePaymentMethods();
    final methods = methodsRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    int? selectedMethodId;
    if (methods.isNotEmpty) {
      selectedMethodId = _tryParseInt(methods.first['id']);
    }

    final amountController = TextEditingController(
      text: remaining.toStringAsFixed(2),
    );
    final notesController = TextEditingController();

    return showDialog<bool>(
      context: sheetContext,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isAr ? 'سداد متبقي' : 'Settle Remaining'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isAr
                      ? 'المتبقي: ${remaining.toStringAsFixed(2)}'
                      : 'Remaining: ${remaining.toStringAsFixed(2)}',
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: selectedMethodId,
                  decoration: InputDecoration(
                    labelText: isAr ? 'وسيلة الدفع' : 'Payment Method',
                  ),
                  items: methods
                      .map((m) {
                        final id = _tryParseInt(m['id']);
                        final name = (m['name'] ?? '').toString();
                        if (id == null) return null;
                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text(name.isNotEmpty ? name : id.toString()),
                        );
                      })
                      .whereType<DropdownMenuItem<int>>()
                      .toList(),
                  onChanged: (v) => selectedMethodId = v,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: isAr ? 'المبلغ' : 'Amount',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: InputDecoration(
                    labelText: isAr ? 'ملاحظات (اختياري)' : 'Notes (optional)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
              ),
              onPressed: () async {
                if (selectedMethodId == null) {
                  Navigator.of(ctx).pop(false);
                  _showSnackBar(
                    isAr ? 'اختر وسيلة دفع' : 'Select a payment method',
                    isError: true,
                  );
                  return;
                }
                final amount =
                    double.tryParse(amountController.text.trim()) ?? 0.0;
                if (amount <= 0) {
                  _showSnackBar(
                    isAr ? 'أدخل مبلغاً صحيحاً' : 'Enter a valid amount',
                    isError: true,
                  );
                  return;
                }
                if (amount > remaining + 0.01) {
                  _showSnackBar(
                    isAr
                        ? 'المبلغ أكبر من المتبقي'
                        : 'Amount exceeds remaining',
                    isError: true,
                  );
                  return;
                }
                try {
                  await _apiService.addInvoicePayment(
                    invoiceId: invoiceId,
                    paymentMethodId: selectedMethodId!,
                    amount: amount,
                    notes: notesController.text,
                  );
                  if (!mounted) return;
                  _showSnackBar(
                    isAr ? 'تم تسجيل الدفعة' : 'Payment recorded',
                    isError: false,
                  );
                  Navigator.of(ctx).pop(true);
                } catch (e) {
                  _showSnackBar(
                    isAr
                        ? 'فشل تسجيل الدفعة: $e'
                        : 'Failed to record payment: $e',
                    isError: true,
                  );
                }
              },
              child: Text(isAr ? 'تأكيد' : 'Confirm'),
            ),
          ],
        );
      },
    );
  }

  /// Open the sales invoice screen in **edit mode** for an unposted invoice.
  Future<void> _editInvoiceContent(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final invoiceIdValue = invoice['id'];
    final invoiceId = invoiceIdValue is int
        ? invoiceIdValue
        : int.tryParse(invoiceIdValue?.toString() ?? '');

    if (invoiceId == null) {
      _showSnackBar(
        isAr ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
        isError: true,
      );
      return;
    }

    // If posted, reject — edit is only for unposted invoices.
    if (invoice['is_posted'] == true) {
      _showSnackBar(
        isAr ? 'لا يمكن تعديل فاتورة مرحّلة' : 'Cannot edit a posted invoice',
        isError: true,
      );
      return;
    }

    // Fetch full invoice data from backend
    try {
      final fullInvoice = await _apiService.getInvoiceById(invoiceId);

      if (!mounted) return;

      final invoiceType = (fullInvoice['invoice_type'] ?? '').toString();

      Widget? screen;

      if (invoiceType == 'بيع') {
        final items = _cloneDataList(await _getCachedItems());
        final saleItems = _filterSaleReadyItems(items);
        final customers = _cloneDataList(await _getCachedCustomers());
        screen = SalesInvoiceScreenV2(
          items: saleItems,
          customers: customers,
          editInvoiceId: invoiceId,
          editInvoiceData: fullInvoice,
        );
      } else if (invoiceType == 'شراء') {
        screen = PurchaseInvoiceScreen(
          editInvoiceId: invoiceId,
          editInvoiceData: fullInvoice,
        );
      } else if (invoiceType == 'مرتجع شراء (مورد)') {
        screen = PurchaseInvoiceScreen(
          supplierReturnMode: true,
          editInvoiceId: invoiceId,
          editInvoiceData: fullInvoice,
        );
      } else if (invoiceType == 'مرتجع بيع' ||
          invoiceType == 'مرتجع شراء' ||
          invoiceType == 'مرتجع شراء من عميل') {
        screen = AddReturnInvoiceScreen(
          api: _apiService,
          returnType: invoiceType,
          editInvoiceId: invoiceId,
          editInvoiceData: fullInvoice,
        );
      } else {
        _showSnackBar(
          isAr
              ? 'التعديل غير متاح لهذا النوع من الفواتير'
              : 'Edit is not supported for this invoice type',
          isError: true,
        );
        return;
      }

      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => screen!),
      );

      if (result == true && mounted) {
        _invalidateInvoiceCache();
        await _loadInvoices(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar(
          isAr
              ? 'فشل تحميل بيانات الفاتورة: $e'
              : 'Failed to load invoice data: $e',
          isError: true,
        );
      }
    }
  }

  Future<void> _deleteInvoice(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Text(
              isAr ? 'تأكيد الحذف' : 'Confirm Delete',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
        content: Text(
          isAr
              ? 'هل أنت متأكد من حذف الفاتورة رقم $invoiceDisplayNumber؟'
              : 'Are you sure you want to delete invoice $invoiceDisplayNumber?',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              isAr ? 'إلغاء' : 'Cancel',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isAr ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final invoiceIdValue = invoice['id'];
        final invoiceId = invoiceIdValue is int
            ? invoiceIdValue
            : int.tryParse(invoiceIdValue?.toString() ?? '');

        if (invoiceId == null) {
          _showSnackBar(
            isAr ? 'معرف الفاتورة غير صالح' : 'Invalid invoice id',
            isError: true,
          );
          return;
        }

        await _apiService.deleteInvoice(invoiceId);
        _showSnackBar(
          isAr ? 'تم حذف الفاتورة بنجاح' : 'Invoice deleted successfully',
          isError: false,
        );
        _invalidateInvoiceCache();
        await _loadInvoices(forceRefresh: true);
      } catch (e) {
        _showSnackBar(
          isAr
              ? 'فشل حذف الفاتورة: ${e.toString()}'
              : 'Failed to delete: ${e.toString()}',
          isError: true,
        );
      }
    }
  }

  Future<void> _navigateToAddInvoice() async {
    final isAr = widget.isArabic;
    final selection = await showModalBottomSheet<_InvoiceCreationTarget>(
      context: context,
      builder: (sheetContext) {
        final options = [
          {
            'target': _InvoiceCreationTarget.sales,
            'icon': Icons.point_of_sale,
            'color': Colors.green,
            'title': isAr ? 'فاتورة بيع' : 'Sales Invoice',
            'subtitle': isAr
                ? 'بيع ذهب جديد أو مستعمل'
                : 'Sell new or used gold',
          },
          {
            'target': _InvoiceCreationTarget.scrapSale,
            'icon': Icons.recycling,
            'color': Colors.orange,
            'title': isAr ? 'بيع ذهب كسر' : 'Scrap Gold Sale',
            'subtitle': isAr
                ? 'تصفية الذهب المستعمل'
                : 'Liquidate scrap inventory',
          },
          {
            'target': _InvoiceCreationTarget.scrapPurchase,
            'icon': Icons.shopping_basket,
            'color': Colors.blue,
            'title': isAr ? 'شراء كسر من عميل' : 'Buy Scrap from Customer',
            'subtitle': isAr
                ? 'استلام ذهب من عملاء'
                : 'Accept client scrap gold',
          },
          {
            'target': _InvoiceCreationTarget.supplierPurchase,
            'icon': Icons.business_center,
            'color': Colors.purple,
            'title': isAr ? 'شراء' : 'Supplier Purchase',
            'subtitle': isAr ? 'توريدات من التجار' : 'Bulk supplier orders',
          },
          {
            'target': _InvoiceCreationTarget.salesReturn,
            'icon': Icons.keyboard_return,
            'color': Colors.red.shade300,
            'title': isAr ? 'مرتجع بيع' : 'Sales Return',
            'subtitle': isAr ? 'استرجاع مبيعات' : 'Return sold items',
          },
          {
            'target': _InvoiceCreationTarget.scrapReturn,
            'icon': Icons.undo,
            'color': Colors.deepOrange.shade300,
            'title': isAr ? 'مرتجع شراء كسر' : 'Scrap Purchase Return',
            'subtitle': isAr ? 'إرجاع مشتريات الكسر' : 'Return scrap purchases',
          },
          {
            'target': _InvoiceCreationTarget.supplierReturn,
            'icon': Icons.assignment_return,
            'color': Colors.teal,
            'title': isAr ? 'مرتجع شراء (مورد)' : 'Supplier Purchase Return',
            'subtitle': isAr ? 'إرجاع مورد' : 'Supplier returns',
          },
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isAr ? 'اختر نوع الفاتورة' : 'Choose invoice type',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                for (final option in options)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: (option['color'] as Color).withValues(
                          alpha: 0.15,
                        ),
                        child: Icon(
                          option['icon'] as IconData,
                          color: option['color'] as Color,
                        ),
                      ),
                      title: Text(option['title'] as String),
                      subtitle: Text(option['subtitle'] as String),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        option['target'] as _InvoiceCreationTarget,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (selection != null) {
      await _openInvoiceCreation(selection);
    }
  }

  Future<void> _openInvoiceCreation(_InvoiceCreationTarget target) async {
    switch (target) {
      case _InvoiceCreationTarget.sales:
        final items = _cloneDataList(await _getCachedItems());
        final saleItems = _filterSaleReadyItems(items);
        final customers = _cloneDataList(await _getCachedCustomers());
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                SalesInvoiceScreenV2(items: saleItems, customers: customers),
          ),
        );
        break;
      case _InvoiceCreationTarget.scrapSale:
        final customers = _cloneDataList(await _getCachedCustomers());
        final items = _cloneDataList(await _getCachedItems());
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ScrapSalesInvoiceScreen(customers: customers, items: items),
          ),
        );
        break;
      case _InvoiceCreationTarget.scrapPurchase:
        final customers = _cloneDataList(await _getCachedCustomers());
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScrapPurchaseInvoiceScreen(customers: customers),
          ),
        );
        break;
      case _InvoiceCreationTarget.supplierPurchase:
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PurchaseInvoiceScreen()),
        );
        break;
      case _InvoiceCreationTarget.salesReturn:
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(
              api: _apiService,
              returnType: 'مرتجع بيع',
            ),
          ),
        );
        break;
      case _InvoiceCreationTarget.scrapReturn:
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(
              api: _apiService,
              returnType: 'مرتجع شراء',
            ),
          ),
        );
        break;
      case _InvoiceCreationTarget.supplierReturn:
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const PurchaseInvoiceScreen(supplierReturnMode: true),
          ),
        );
        break;
    }

    if (mounted) {
      _invalidateInvoiceCache();
      await _loadInvoices(forceRefresh: true);
    }
  }
}
