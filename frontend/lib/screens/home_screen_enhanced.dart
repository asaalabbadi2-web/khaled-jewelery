import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../providers/quick_actions_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../models/quick_action_item.dart';
import 'items_screen_enhanced.dart';
import 'add_customer_screen.dart';
import 'add_item_screen_enhanced.dart';
import 'sales_invoice_screen_v2.dart';
import 'purchase_invoice_screen.dart';
import 'invoices_list_screen.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'add_return_invoice_screen.dart';
import 'vouchers_list_screen.dart';
import 'add_voucher_screen.dart';
import 'accounts_screen.dart';
import 'journal_entries_list_screen.dart';
import 'journal_entry_form.dart';
import 'recurring_templates_screen.dart';
import 'general_ledger_screen_v2.dart';
import 'trial_balance_screen_v2.dart';
import 'chart_of_accounts_screen.dart';
import 'settings_screen_enhanced.dart';
import 'customize_quick_actions_screen.dart';
import 'scrap_sales_invoice_screen.dart';
import 'scrap_purchase_invoice_screen.dart'; // 🆕 فاتورة شراء الكسر المحسّنة
import 'employees_screen.dart';
import 'users_screen.dart';
import 'payroll_screen.dart';
import 'attendance_screen.dart';
import 'payroll_report_screen.dart';
import 'safe_boxes_screen.dart';
import 'melting_renewal_screen.dart';
import 'gold_reservation_screen.dart';
import 'offices_screen.dart';
import 'posting_management_screen.dart';
import 'reports/gold_price_history_report_screen.dart';
import 'reports/reports_main_screen.dart';
import 'printing_center_screen.dart';

class HomeScreenEnhanced extends StatefulWidget {
  final VoidCallback? onToggleLocale;
  final bool isArabic;

  const HomeScreenEnhanced({
    super.key,
    this.onToggleLocale,
    this.isArabic = true,
  });

  @override
  State<HomeScreenEnhanced> createState() => _HomeScreenEnhancedState();
}

class _HomeScreenEnhancedState extends State<HomeScreenEnhanced> {
  final ApiService api = ApiService();

  // Data
  double? goldPrice;
  DateTime? goldPriceDate;
  List customers = [];
  List items = [];
  List invoices = [];
  List suppliers = [];

  // Currency data
  double exchangeRate = 3.75; // سعر الصرف الافتراضي (دولار -> ريال سعودي)
  String currencySymbol = 'ر.س';
  int currencyDecimalPlaces = 2;
  int mainKarat = 21;

  // Gold price card expansion state
  bool _isGoldPriceExpanded = false;

  // Summary data
  Map<String, dynamic> salesSummary = {};
  Map<String, dynamic> purchaseSummary = {};
  Map<String, dynamic> inventorySummary = {};

  // Summary period filter
  String _summaryPeriod = 'daily'; // 'daily', 'monthly', 'yearly', 'all'

  // Bottom Navigation
  int _selectedNavIndex = 0;
  List<String> _bottomNavItems = [
    'home',
    'invoices',
    'customers',
    'items',
    'settings',
  ];

  bool isLoading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
    final newDecimals = settings.decimalPlaces;
    final newMainKarat = settings.mainKarat;

    if (newSymbol != currencySymbol ||
        newDecimals != currencyDecimalPlaces ||
        newMainKarat != mainKarat) {
      setState(() {
        currencySymbol = newSymbol;
        currencyDecimalPlaces = newDecimals;
        mainKarat = newMainKarat;
      });
    }
  }

  double _parseDouble(dynamic value, {double fallback = 0}) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  int _parseInt(dynamic value, {int fallback = 0}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Map<String, double> _ensureKaratEntry(
    Map<int, Map<String, double>> target,
    int karat,
  ) {
    if (!target.containsKey(karat)) {
      target[karat] = {'weight': 0, 'amount': 0};
    }
    return target[karat]!;
  }

  // تصفية الفواتير حسب الفترة المحددة
  List _filterInvoicesByPeriod(List allInvoices) {
    if (_summaryPeriod == 'all') return allInvoices;

    final now = DateTime.now();
    DateTime startDate;

    switch (_summaryPeriod) {
      case 'daily':
        startDate = DateTime(now.year, now.month, now.day);
        break;
      case 'monthly':
        startDate = DateTime(now.year, now.month, 1);
        break;
      case 'yearly':
        startDate = DateTime(now.year, 1, 1);
        break;
      default:
        return allInvoices;
    }

    return allInvoices.where((inv) {
      if (inv['date'] == null && inv['created_at'] == null) return false;
      try {
        final dateStr = inv['date'] ?? inv['created_at'];
        final invDate = DateTime.parse(dateStr.toString());
        return invDate.isAfter(startDate.subtract(const Duration(seconds: 1)));
      } catch (e) {
        return false;
      }
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    setState(() => isLoading = true);

    try {
      debugPrint('🔄 بدء تحميل البيانات...');
      await Future.wait([
        _loadGoldPrice(),
        _loadCustomers(),
        _loadItems(),
        _loadInvoices(),
        _loadSuppliers(),
      ]);

      debugPrint(
        '✅ تم تحميل البيانات - العملاء: ${customers.length}, الأصناف: ${items.length}, الفواتير: ${invoices.length}',
      );
      await _calculateSummaries();
      debugPrint(
        '✅ تم حساب الملخصات - مبيعات: ${salesSummary['count']}, مشتريات: ${purchaseSummary['count']}, مخزون: ${inventorySummary['count']}',
      );
    } catch (e) {
      debugPrint('❌ خطأ في تحميل البيانات: $e');
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _loadGoldPrice() async {
    try {
      final response = await api.getGoldPrice();
      if (response['price_usd_per_oz'] != null) {
        setState(() {
          goldPrice = (response['price_usd_per_oz'] is String)
              ? double.tryParse(response['price_usd_per_oz'])
              : (response['price_usd_per_oz'] as num?)?.toDouble();

          if (response['date'] != null) {
            goldPriceDate = DateTime.parse(response['date']);
          }
        });
      }
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل سعر الذهب: $e');
    }
  }

  Future<void> _loadCustomers() async {
    try {
      final data = await api.getCustomers();
      setState(() => customers = data);
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل العملاء: $e');
    }
  }

  Future<void> _loadItems() async {
    try {
      final data = await api.getItems();
      setState(() => items = data);
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل الأصناف: $e');
    }
  }

  Future<void> _loadInvoices() async {
    try {
      final data = await api.getInvoices();
      setState(() {
        invoices = data is List ? data : (data['invoices'] ?? []);
      });
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل الفواتير: $e');
    }
  }

  Future<void> _loadSuppliers() async {
    try {
      final data = await api.getSuppliers();
      setState(() => suppliers = data);
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل الموردين: $e');
    }
  }

  Future<void> _calculateSummaries() async {
    // تصفية الفواتير حسب الفترة المحددة
    final filteredInvoices = _filterInvoicesByPeriod(invoices);

    // حساب ملخص المبيعات مع التفصيل حسب العيار
    final salesInvoices = filteredInvoices.where((inv) {
      final invType = (inv['invoice_type'] ?? inv['transaction_type'] ?? '')
          .toString()
          .toLowerCase();
      return invType == 'sell' || invType == 'بيع' || invType.contains('بيع');
    }).toList();

    debugPrint(
      '📊 عدد فواتير المبيعات: ${salesInvoices.length} من أصل ${filteredInvoices.length}',
    );

    double totalSalesAmount = 0;
    double totalSalesWeight = 0;
    Map<int, Map<String, double>> salesByKarat = {
      18: {'weight': 0, 'amount': 0},
      21: {'weight': 0, 'amount': 0},
      22: {'weight': 0, 'amount': 0},
      24: {'weight': 0, 'amount': 0},
    };

    for (var inv in salesInvoices) {
      final invoiceTotal = _parseDouble(
        inv['total'] ??
            inv['total_net'] ??
            inv['net_amount'] ??
            inv['amount_paid'],
      );
      final invoiceWeight = _parseDouble(inv['total_weight']);

      totalSalesAmount += invoiceTotal;
      totalSalesWeight += invoiceWeight;

      // تفصيل حسب العيار من بنود الفاتورة
      if (inv['items'] != null && inv['items'] is List) {
        for (var item in inv['items']) {
          final karat = _parseInt(item['karat'], fallback: 21);
          final quantity = _parseDouble(item['quantity'], fallback: 1);
          final itemWeight = _parseDouble(item['weight']);

          final unitPrice = _parseDouble(item['price']);
          final net = _parseDouble(item['net']);
          final tax = _parseDouble(item['tax']);
          final itemAmount =
              (unitPrice > 0 ? unitPrice : net + tax) *
              (quantity == 0 ? 1 : quantity);

          final bucket = _ensureKaratEntry(salesByKarat, karat);
          bucket['weight'] = (bucket['weight'] ?? 0) + itemWeight;
          bucket['amount'] = (bucket['amount'] ?? 0) + itemAmount;
        }
      }
    }

    // حساب ملخص المشتريات مع التفصيل حسب العيار
    final purchaseInvoices = filteredInvoices.where((inv) {
      final invType = (inv['invoice_type'] ?? inv['transaction_type'] ?? '')
          .toString()
          .toLowerCase();
      return invType == 'buy' ||
          invType == 'شراء' ||
          invType == 'شراء من عميل' ||
          invType.contains('شراء');
    }).toList();

    debugPrint(
      '📊 عدد فواتير المشتريات: ${purchaseInvoices.length} من أصل ${filteredInvoices.length}',
    );

    double totalPurchaseAmount = 0;
    double totalPurchaseWeight = 0;
    Map<int, Map<String, double>> purchaseByKarat = {
      18: {'weight': 0, 'amount': 0},
      21: {'weight': 0, 'amount': 0},
      22: {'weight': 0, 'amount': 0},
      24: {'weight': 0, 'amount': 0},
    };

    for (var inv in purchaseInvoices) {
      final invoiceTotal = _parseDouble(
        inv['total'] ??
            inv['total_net'] ??
            inv['net_amount'] ??
            inv['amount_paid'],
      );
      final invoiceWeight = _parseDouble(inv['total_weight']);

      totalPurchaseAmount += invoiceTotal;
      totalPurchaseWeight += invoiceWeight;

      // تفصيل حسب العيار من بنود الفاتورة
      if (inv['items'] != null && inv['items'] is List) {
        for (var item in inv['items']) {
          final karat = _parseInt(item['karat'], fallback: 21);
          final quantity = _parseDouble(item['quantity'], fallback: 1);
          final itemWeight = _parseDouble(item['weight']);

          final unitPrice = _parseDouble(item['price']);
          final net = _parseDouble(item['net']);
          final tax = _parseDouble(item['tax']);
          final itemAmount =
              (unitPrice > 0 ? unitPrice : net + tax) *
              (quantity == 0 ? 1 : quantity);

          final bucket = _ensureKaratEntry(purchaseByKarat, karat);
          bucket['weight'] = (bucket['weight'] ?? 0) + itemWeight;
          bucket['amount'] = (bucket['amount'] ?? 0) + itemAmount;
        }
      }
    }

    // حساب ملخص المخزون مع التفصيل حسب العيار
    double totalInventoryWeight = 0;
    int activeItems = 0;
    Map<int, Map<String, double>> inventoryByKarat = {
      18: {'weight': 0, 'count': 0},
      21: {'weight': 0, 'count': 0},
      22: {'weight': 0, 'count': 0},
      24: {'weight': 0, 'count': 0},
    };

    for (var item in items) {
      final karat = _parseInt(item['karat'], fallback: 21);
      final weight = _parseDouble(item['weight']);
      final stock = _parseDouble(item['stock']);
      final isAvailable = stock > 0 ? stock : 1;

      if (weight > 0) {
        totalInventoryWeight += weight * isAvailable;
      }

      activeItems += 1;

      final bucket = _ensureKaratEntry(inventoryByKarat, karat);
      bucket['weight'] =
          (bucket['weight'] ?? 0) + (weight > 0 ? weight * isAvailable : 0);
      bucket['count'] = (bucket['count'] ?? 0) + isAvailable;
    }

    setState(() {
      salesSummary = {
        'count': salesInvoices.length,
        'amount': totalSalesAmount,
        'weight': totalSalesWeight,
        'byKarat': salesByKarat,
      };

      purchaseSummary = {
        'count': purchaseInvoices.length,
        'amount': totalPurchaseAmount,
        'weight': totalPurchaseWeight,
        'byKarat': purchaseByKarat,
      };

      inventorySummary = {
        'count': activeItems,
        'weight': totalInventoryWeight,
        'byKarat': inventoryByKarat,
      };
    });
  }

  // Drawer Builder
  Widget _buildDrawer(bool isAr, Color gold) {
    final theme = Theme.of(context);
    final TextStyle baseLabelStyle =
        theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: theme.colorScheme.onSurface,
        ) ??
        const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: Colors.white70,
        );
    final TextStyle sectionStyle = baseLabelStyle.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.bold,
    );

    final List<Widget> drawerChildren = [];
    final List<Future<void> Function()> actions = [];

    drawerChildren.add(
      Container(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [gold.withValues(alpha: 0.85), gold.withValues(alpha: 0.45)],
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: theme.colorScheme.surface,
              child: Icon(Icons.workspace_premium, color: gold, size: 36),
            ),
            const SizedBox(height: 16),
            Text(
              isAr ? 'ياسار للذهب' : 'Yasar Gold',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isAr ? 'نظام إدارة متكامل' : 'Integrated POS Platform',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );

    void addDivider() {
      drawerChildren.add(
        Divider(
          indent: 24,
          endIndent: 24,
          height: 24,
          color: theme.dividerColor,
        ),
      );
    }

    void addSection(String title, Color color) {
      drawerChildren.add(
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(24, 16, 24, 8),
          child: Text(title, style: sectionStyle.copyWith(color: color)),
        ),
      );
    }

    void addDestination({
      required IconData icon,
      required String title,
      required Future<void> Function() onSelected,
      Color? color,
    }) {
      final iconColor = color ?? theme.iconTheme.color ?? Colors.white70;
      drawerChildren.add(
        NavigationDrawerDestination(
          icon: Icon(icon, color: iconColor),
          selectedIcon: Icon(
            icon,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          label: Text(title, style: baseLabelStyle),
        ),
      );
      actions.add(onSelected);
    }

    drawerChildren.add(const SizedBox(height: 12));
    addDestination(
      icon: Icons.home_outlined,
      title: isAr ? 'الرئيسية' : 'Home',
      color: gold,
      onSelected: () async {
        setState(() => _selectedNavIndex = 0);
      },
    );

    addDivider();
    addSection(isAr ? 'الفواتير' : 'Invoices', gold);
    addDestination(
      icon: Icons.point_of_sale,
      title: isAr ? 'فاتورة بيع' : 'Sales Invoice',
      color: Colors.green,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SalesInvoiceScreenV2(
              items: items.cast<Map<String, dynamic>>(),
              customers: customers.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.recycling_outlined,
      title: isAr ? 'فاتورة بيع ذهب كسر' : 'Scrap Gold Sale',
      color: Colors.orangeAccent,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScrapSalesInvoiceScreen(
              customers: customers.cast<Map<String, dynamic>>(),
              items: items.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.shopping_basket,
      title: isAr ? 'شراء كسر من عميل' : 'Buy Scrap from Customer',
      color: Colors.blue,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScrapPurchaseInvoiceScreen(
              customers: customers.cast<Map<String, dynamic>>(),
              items: items.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.business,
      title: isAr ? 'شراء من مورد' : 'Purchase from Supplier',
      color: Colors.purple,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PurchaseInvoiceScreen()),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.receipt_long,
      title: isAr ? 'عرض جميع الفواتير' : 'All Invoices',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => InvoicesListScreen(isArabic: isAr)),
        );
      },
    );

    addDivider();
    addSection(isAr ? 'المرتجعات' : 'Returns', Colors.red.shade300);
    addDestination(
      icon: Icons.keyboard_return,
      title: isAr ? 'مرتجع بيع' : 'Sales Return',
      color: Colors.red.shade300,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AddReturnInvoiceScreen(api: api, returnType: 'مرتجع بيع'),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.undo,
      title: isAr ? 'مرتجع شراء كسر' : 'Scrap Purchase Return',
      color: Colors.orange.shade300,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AddReturnInvoiceScreen(api: api, returnType: 'مرتجع شراء'),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.assignment_return,
      title: isAr ? 'مرتجع شراء من مورد' : 'Supplier Purchase Return',
      color: Colors.deepOrange.shade300,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(
              api: api,
              returnType: 'مرتجع شراء من مورد',
            ),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );

    addDivider();
    addSection(isAr ? 'العملاء' : 'Customers', Colors.blue.shade300);
    addDestination(
      icon: Icons.people,
      title: isAr ? 'قائمة العملاء' : 'Customers List',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CustomersScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.person_add,
      title: isAr ? 'إضافة عميل جديد' : 'Add Customer',
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddCustomerScreen(api: api)),
        );
        if (result == true) await _loadAllData();
      },
    );

    addDivider();
    addSection(isAr ? 'الأصناف' : 'Items', Colors.orange.shade300);
    addDestination(
      icon: Icons.inventory_2,
      title: isAr ? 'قائمة الأصناف' : 'Items List',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemsScreenEnhanced(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.add_box,
      title: isAr ? 'إضافة صنف جديد' : 'Add Item',
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddItemScreenEnhanced(api: api)),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.autorenew,
      title: isAr ? 'التجديد والتكسير' : 'Renewal & Melting',
      color: Colors.amber.shade600,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MeltingRenewalScreen(api: api, isArabic: isAr),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );

    addDivider();
    addSection(isAr ? 'الموردين' : 'Suppliers', Colors.purple.shade300);
    addDestination(
      icon: Icons.store,
      title: isAr ? 'قائمة الموردين' : 'Suppliers List',
      color: Colors.purple.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SuppliersScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );

    addDivider();
    addSection(isAr ? 'التسكير' : 'Gold Reservation', AppColors.deepGold);
    addDestination(
      icon: Icons.business,
      title: isAr ? 'قائمة المكاتب' : 'Offices List',
      color: AppColors.darkGold,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OfficesScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.lock_clock,
      title: isAr ? 'التسكير - حجز ذهب خام' : 'Gold Reservation',
      color: AppColors.primaryGold,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GoldReservationScreen(api: api, isArabic: isAr),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );

    addDivider();
    addSection(
      isAr ? '� الموارد البشرية' : '👔 Human Resources',
      Colors.blueGrey.shade400,
    );
    addDestination(
      icon: Icons.badge,
      title: isAr ? 'الموظفين' : 'Employees',
      color: Colors.blueGrey.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => EmployeesScreen(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.manage_accounts,
      title: isAr ? 'المستخدمين' : 'Users',
      color: Colors.blueGrey.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => UsersScreen(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.payments_rounded,
      title: isAr ? 'الرواتب' : 'Payroll',
      color: Colors.blueGrey.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PayrollScreen(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.event_available,
      title: isAr ? 'الحضور والانصراف' : 'Attendance',
      color: Colors.blueGrey.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AttendanceScreen(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.analytics,
      title: isAr ? 'تقارير الرواتب' : 'Payroll Reports',
      color: Colors.blueGrey.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => PayrollReportScreen(api: api)),
        );
      },
    );

    addDivider();
    addSection(isAr ? 'المحاسبة' : 'Accounting', gold);
    addDestination(
      icon: Icons.receipt_long,
      title: isAr ? 'السندات' : 'Vouchers',
      color: Colors.cyan,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VouchersListScreen()),
        );
      },
    );
    addDestination(
      icon: Icons.south,
      title: isAr ? 'سند قبض' : 'Receipt Voucher',
      color: Colors.green,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddVoucherScreen(voucherType: 'receipt'),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.north,
      title: isAr ? 'سند صرف' : 'Payment Voucher',
      color: Colors.red,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddVoucherScreen(voucherType: 'payment'),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.assessment,
      title: isAr ? 'كشوفات الحسابات' : 'Account Statements',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AccountsScreen()),
        );
      },
    );
    addDestination(
      icon: Icons.book,
      title: isAr ? 'قيود اليومية' : 'Journal Entries',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JournalEntriesListScreen(isArabic: isAr),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.edit_note,
      title: isAr ? 'إضافة قيد' : 'Add Entry',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddEditJournalEntryScreen()),
        );
      },
    );
    addDestination(
      icon: Icons.repeat,
      title: isAr ? 'القيود الدورية' : 'Recurring Entries',
      color: Colors.purple.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RecurringTemplatesScreen(isArabic: isAr),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.menu_book,
      title: isAr ? 'دفتر الأستاذ العام' : 'General Ledger',
      color: Colors.amber.shade700,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => GeneralLedgerScreenV2()),
        );
      },
    );
    addDestination(
      icon: Icons.account_balance_wallet,
      title: isAr ? 'ميزان المراجعة' : 'Trial Balance',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TrialBalanceScreenV2()),
        );
      },
    );
    addDestination(
      icon: Icons.account_tree,
      title: isAr ? 'شجرة الحسابات' : 'Chart of Accounts',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChartOfAccountsScreen()),
        );
      },
    );

    addDivider();
    addSection(
      isAr ? '⚙️ الإعدادات والأدوات' : '⚙️ Settings & Tools',
      theme.hintColor,
    );
    addDestination(
      icon: Icons.account_balance_wallet,
      title: isAr ? 'إدارة الخزائن' : 'Safe Boxes',
      color: Colors.amber.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SafeBoxesScreen()),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.monetization_on,
      title: isAr ? 'تحديث سعر الذهب' : 'Update Gold Price',
      color: gold,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreenEnhanced(
              initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
              focusEntry: SettingsEntry.goldPrice,
            ),
          ),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.restore,
      title: isAr ? 'إعادة تهيئة النظام' : 'System Reset',
      color: Colors.red.shade400,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreenEnhanced(
              initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
              focusEntry: SettingsEntry.systemReset,
            ),
          ),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.print,
      title: isAr ? 'إعدادات الطابعة' : 'Printer Settings',
      color: Colors.purple.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreenEnhanced(
              initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
              focusEntry: SettingsEntry.printerSettings,
            ),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.info_outline,
      title: isAr ? 'حول التطبيق' : 'About',
      color: Colors.teal.shade300,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreenEnhanced(
              initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
              focusEntry: SettingsEntry.about,
            ),
          ),
        );
      },
    );

    drawerChildren.add(const SizedBox(height: 24));

    return NavigationDrawer(
      backgroundColor:
          theme.drawerTheme.backgroundColor ?? const Color(0xFF161616),
      indicatorColor: gold.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      selectedIndex: null,
      onDestinationSelected: (index) async {
        if (index < 0 || index >= actions.length) {
          return;
        }
        Navigator.of(context).pop();
        await actions[index]();
      },
      children: drawerChildren,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        drawer: _buildDrawer(isAr, AppColors.primaryGold),
        appBar: AppBar(
          title: Row(
            children: [
              Icon(Icons.workspace_premium, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text('ياسار للذهب')),
            ],
          ),
          actions: [
            // زر تبديل الوضع (فاتح/داكن)
            IconButton(
              icon: Icon(
                Provider.of<ThemeProvider>(context).isDarkMode
                    ? Icons.light_mode
                    : Icons.dark_mode,
              ),
              tooltip: isAr ? 'تبديل الوضع' : 'Toggle Theme',
              onPressed: () {
                Provider.of<ThemeProvider>(
                  context,
                  listen: false,
                ).toggleTheme();
              },
            ),
            // زر تبديل اللغة
            IconButton(
              icon: Icon(Icons.language),
              tooltip: isAr ? 'English' : 'العربية',
              onPressed: widget.onToggleLocale,
            ),
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                final displayName = auth.username.isEmpty
                    ? (isAr ? 'حساب المستخدم' : 'Account')
                    : auth.username;
                return PopupMenuButton<String>(
                  tooltip: displayName,
                  offset: const Offset(0, 48),
                  // show avatar + username inline so the name is visible on the app bar
                  // constrain the widget height to the toolbar to avoid increasing AppBar height
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: AppColors.primaryGold.withValues(alpha: 
                              0.2,
                            ),
                            child: Icon(
                              Icons.person,
                              color: AppColors.primaryGold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // username label (falls back to localized account label)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ),
                    ),
                  ),
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'info',
                      enabled: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isAr ? 'الدور: ${auth.role}' : 'Role: ${auth.role}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: 'logout',
                      child: Row(
                        children: [
                          const Icon(Icons.logout, size: 18),
                          const SizedBox(width: 8),
                          Text(isAr ? 'تسجيل الخروج' : 'Sign out'),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) async {
                    if (value == 'logout') {
                      await auth.logout();
                    }
                  },
                );
              },
            ),
          ],
        ),
        body: isLoading
            ? Center(
                child: CircularProgressIndicator(
                  color: AppColors.primaryGold,
                  strokeWidth: 3,
                ),
              )
            : _buildSelectedTabContent(isAr),
        bottomNavigationBar: _buildBottomNavigationBar(
          isAr,
          AppColors.primaryGold,
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar(bool isAr, Color gold) {
    final theme = Theme.of(context);

    return BottomNavigationBar(
      backgroundColor: theme.bottomNavigationBarTheme.backgroundColor,
      selectedItemColor: AppColors.primaryGold,
      unselectedItemColor: theme.unselectedWidgetColor,
      currentIndex: _selectedNavIndex,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
      selectedLabelStyle: TextStyle(
        fontFamily: 'Cairo',
        fontWeight: FontWeight.bold,
      ),
      unselectedLabelStyle: TextStyle(fontFamily: 'Cairo'),
      onTap: _onBottomNavTap,
      items: _getBottomNavItems(isAr),
    );
  }

  List<BottomNavigationBarItem> _getBottomNavItems(bool isAr) {
    final Map<String, Map<String, dynamic>> availableItems = {
      'home': {'icon': Icons.home, 'label_ar': 'الرئيسية', 'label_en': 'Home'},
      'invoices': {
        'icon': Icons.receipt_long,
        'label_ar': 'الفواتير',
        'label_en': 'Invoices',
      },
      'customers': {
        'icon': Icons.people,
        'label_ar': 'العملاء',
        'label_en': 'Customers',
      },
      'items': {
        'icon': Icons.inventory_2,
        'label_ar': 'المخزون',
        'label_en': 'Items',
      },
      'settings': {
        'icon': Icons.settings,
        'label_ar': 'الإعدادات',
        'label_en': 'Settings',
      },
    };

    return _bottomNavItems.map((key) {
      final item = availableItems[key]!;
      return BottomNavigationBarItem(
        icon: Icon(item['icon']),
        label: isAr ? item['label_ar'] : item['label_en'],
      );
    }).toList();
  }

  void _onBottomNavTap(int index) {
    setState(() => _selectedNavIndex = index);
    // Bottom nav now switches between different views in the home screen
    // No navigation to separate screens
  }

  // Build content based on selected bottom nav tab
  Widget _buildSelectedTabContent(bool isAr) {
    final navKey = _bottomNavItems[_selectedNavIndex];

    switch (navKey) {
      case 'home':
        return _buildHomeTabContent(isAr);
      case 'invoices':
        return InvoicesListScreen(isArabic: isAr);
      case 'customers':
        return CustomersScreen(api: api, isArabic: isAr);
      case 'items':
        return ItemsScreenEnhanced(api: api);
      case 'settings':
        return SettingsScreenEnhanced();
      default:
        return _buildHomeTabContent(isAr);
    }
  }

  // Original home screen content
  Widget _buildHomeTabContent(bool isAr) {
    return RefreshIndicator(
      onRefresh: _loadAllData,
      color: AppColors.primaryGold,
      child: SingleChildScrollView(
        physics: AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 8),

              // Gold Price Card
              _buildGoldPriceCard(),

              SizedBox(height: 24),

              // Quick Actions
              _buildQuickActions(),

              SizedBox(height: 24),

              // Summary Cards Section Header with Period Selector
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    'ملخص العمليات الرئيسية',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).textTheme.titleLarge?.color,
                      fontFamily: 'Cairo',
                    ),
                  ),
                  _buildPeriodSelector(),
                ],
              ),
              SizedBox(height: 16),

              // Sales Summary
              _buildSalesSummaryCard(),

              SizedBox(height: 16),

              // Purchase Summary
              _buildPurchaseSummaryCard(),

              SizedBox(height: 16),

              // Inventory Summary
              _buildInventorySummaryCard(),

              SizedBox(height: 16),

              // Statistics Row
              _buildStatisticsRow(),

              SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoldPriceCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // Helper to calculate price per gram for a given karat
    double calculateKaratPrice(double ouncePrice, int karat) {
      return (ouncePrice / 31.1035) * (karat / 24);
    }

    // Calculate purchase price (what we buy from customers - lower than market)
    double calculatePurchasePrice(double basePrice) {
      return basePrice * 0.98; // 2% less than market price
    }

    // Sell price is the actual market price (base price)
    double calculateSellPrice(double basePrice) {
      return basePrice; // Actual world market price
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  colorScheme.primary.withValues(alpha: 0.6),
                  colorScheme.primary.withValues(alpha: 0.4),
                ]
              : [colorScheme.primary, colorScheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: isDark ? 0.25 : 0.35),
            blurRadius: 15,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() {
              _isGoldPriceExpanded = !_isGoldPriceExpanded;
            });
          },
          onLongPress: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreenEnhanced(
                  initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
                  focusEntry: SettingsEntry.goldPrice,
                ),
              ),
            );
            await _loadAllData();
          },
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Compact header section with main karat (21)
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.onPrimary.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.trending_up,
                        color: colorScheme.onPrimary,
                        size: 24,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'سعر الأونصة',
                                style: TextStyle(
                                  color: colorScheme.onPrimary.withValues(alpha: 
                                    0.95,
                                  ),
                                  fontSize: 11,
                                  fontFamily: 'Cairo',
                                ),
                              ),
                              SizedBox(width: 8),
                              if (goldPriceDate != null)
                                Text(
                                  '(${DateFormat('dd/MM').format(goldPriceDate!)})',
                                  style: TextStyle(
                                    color: colorScheme.onPrimary.withValues(alpha: 
                                      0.75,
                                    ),
                                    fontSize: 9,
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: 2),
                          Text(
                            goldPrice != null
                                ? '\$${goldPrice!.toStringAsFixed(2)}'
                                : 'غير متوفر',
                            style: TextStyle(
                              color: colorScheme.onPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (goldPrice != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'عيار $mainKarat',
                            style: TextStyle(
                              color: colorScheme.onPrimary.withValues(alpha: 0.85),
                              fontSize: 10,
                              fontFamily: 'Cairo',
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            _formatCash(
                              calculateSellPrice(
                                    calculateKaratPrice(goldPrice!, mainKarat),
                                  ) *
                                  exchangeRate,
                              includeSymbol: false,
                            ),
                            style: TextStyle(
                              color: Colors.greenAccent.shade100,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Cairo',
                            ),
                          ),
                          Text(
                            _formatCash(
                              calculatePurchasePrice(
                                    calculateKaratPrice(goldPrice!, mainKarat),
                                  ) *
                                  exchangeRate,
                              includeSymbol: false,
                            ),
                            style: TextStyle(
                              color: Colors.amber.shade200,
                              fontSize: 12,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ],
                      ),
                    SizedBox(width: 8),
                    Icon(
                      _isGoldPriceExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: colorScheme.onPrimary,
                      size: 24,
                    ),
                  ],
                ),

                // Expandable price table
                AnimatedCrossFade(
                  firstChild: SizedBox.shrink(),
                  secondChild: Column(
                    children: [
                      SizedBox(height: 12),
                      Divider(
                        color: colorScheme.onPrimary.withValues(alpha: 0.3),
                        thickness: 0.5,
                        height: 1,
                      ),
                      SizedBox(height: 10),
                      if (goldPrice != null)
                        _buildKaratPriceTable(
                          colorScheme,
                          calculateKaratPrice,
                          calculatePurchasePrice,
                          calculateSellPrice,
                        ),
                    ],
                  ),
                  crossFadeState: _isGoldPriceExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: Duration(milliseconds: 300),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKaratPriceTable(
    ColorScheme colorScheme,
    double Function(double, int) calculateKaratPrice,
    double Function(double) calculatePurchasePrice,
    double Function(double) calculateSellPrice,
  ) {
    final karats = [24, 22, 21, 18];

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.0),
        1: FlexColumnWidth(2.0),
        2: FlexColumnWidth(2.0),
      },
      border: TableBorder(
        horizontalInside: BorderSide(
          color: colorScheme.onPrimary.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      children: [
        // Header row
        TableRow(
          decoration: BoxDecoration(
            color: colorScheme.onPrimary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
          ),
          children: [
            _buildTableCell(
              'العيار',
              colorScheme.onPrimary,
              false,
              isHeader: true,
            ),
            _buildTableCell(
              'شراء',
              colorScheme.onPrimary,
              true,
              isHeader: true,
            ),
            _buildTableCell('بيع', colorScheme.onPrimary, true, isHeader: true),
          ],
        ),
        // Data rows
        ...karats.map((karat) {
          final basePrice = calculateKaratPrice(goldPrice!, karat);
          final purchasePrice = calculatePurchasePrice(basePrice);
          final sellPrice = calculateSellPrice(basePrice);

          return TableRow(
            children: [
              _buildTableCell(
                '$karat',
                colorScheme.onPrimary.withValues(alpha: 0.95),
                false,
              ),
              _buildTableCell(
                _formatCash(purchasePrice * exchangeRate, includeSymbol: false),
                Colors.amber.shade200,
                false,
              ),
              _buildTableCell(
                _formatCash(sellPrice * exchangeRate, includeSymbol: false),
                Colors.greenAccent.shade100,
                false,
              ),
            ],
          );
        }).toList(),
      ],
    );
  }

  Widget _buildTableCell(
    String text,
    Color color,
    bool isNumeric, {
    bool isHeader = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 4.0),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: isHeader ? 10 : 11,
          fontWeight: isHeader ? FontWeight.bold : FontWeight.w600,
          fontFamily: 'Cairo',
        ),
      ),
    );
  }

  Widget _buildQuickActions() {
    final theme = Theme.of(context);

    return Consumer<QuickActionsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return Center(
            child: CircularProgressIndicator(color: AppColors.primaryGold),
          );
        }

        final activeActions = provider.activeActions;

        if (activeActions.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Column(
              children: [
                Icon(Icons.info_outline, color: AppColors.info, size: 40),
                const SizedBox(height: 12),
                Text(
                  'لا توجد أزرار وصول سريع مفعّلة',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'اذهب إلى الإعدادات لتخصيص الأزرار',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'الوصول السريع',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.settings, color: AppColors.primaryGold),
                  tooltip: 'تخصيص الأزرار',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CustomizeQuickActionsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // عرض الأزرار في صفوف (2 أزرار في كل صف)
            ...List.generate((activeActions.length / 2).ceil(), (rowIndex) {
              final startIndex = rowIndex * 2;
              final endIndex = (startIndex + 2 > activeActions.length)
                  ? activeActions.length
                  : startIndex + 2;

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    for (int i = startIndex; i < endIndex; i++) ...[
                      Expanded(
                        child: _buildQuickActionButton(
                          action: activeActions[i],
                          theme: theme,
                        ),
                      ),
                      if (i < endIndex - 1) const SizedBox(width: 12),
                    ],
                    // إذا كان هناك زر واحد فقط في الصف، أضف مساحة فارغة
                    if (endIndex - startIndex == 1)
                      const Expanded(child: SizedBox()),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildQuickActionButton({
    required QuickActionItem action,
    required ThemeData theme,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _handleQuickActionTap(action.route),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: action.getColor().withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(action.icon, color: action.getColor(), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    action.label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // معالجة النقر على أزرار الوصول السريع
  Future<void> _handleQuickActionTap(String route) async {
    dynamic result;

    switch (route) {
      case 'sales_invoice':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SalesInvoiceScreenV2(
              items: items.cast<Map<String, dynamic>>(),
              customers: customers.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        break;
      case 'scrap_sales':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScrapSalesInvoiceScreen(
              customers: customers.cast<Map<String, dynamic>>(),
              items: items.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        break;
      case 'scrap_purchase':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ScrapPurchaseInvoiceScreen(
              customers: customers.cast<Map<String, dynamic>>(),
              items: items.cast<Map<String, dynamic>>(),
            ),
          ),
        );
        break;
      case 'purchase_invoice':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PurchaseInvoiceScreen()),
        );
        break;
      case 'return_invoice':
        // فاتورة مرتجع تحتاج نوع (بيع أو شراء) - سنتركها للمستخدم لاختيارها من القائمة
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => InvoicesListScreen()),
        );
        break;
      case 'return_sales':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(api: api, returnType: 'مرتجع بيع'),
          ),
        );
        break;
      case 'return_purchase':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(api: api, returnType: 'مرتجع شراء'),
          ),
        );
        break;
      case 'add_customer':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddCustomerScreen(api: api)),
        );
        break;
      case 'customers_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CustomersScreen(api: api, isArabic: true),
          ),
        );
        break;
      case 'suppliers_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SuppliersScreen(api: api)),
        );
        break;
      case 'add_item':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddItemScreenEnhanced(api: api)),
        );
        break;
      case 'items_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemsScreenEnhanced(api: api)),
        );
        break;
      case 'receipt_voucher':
      case 'payment_voucher':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VouchersListScreen()),
        );
        break;
      case 'vouchers_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VouchersListScreen()),
        );
        break;
      case 'journal_entry':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddEditJournalEntryScreen(),
          ),
        );
        break;
      case 'accounts':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AccountsScreen()),
        );
        break;
      case 'reports_center':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReportsMainScreen(
              api: api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'gold_price_history':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GoldPriceHistoryReportScreen(
              api: api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'printing_center':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PrintingCenterScreen(
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'employees':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                EmployeesScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'users':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => UsersScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'payroll':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PayrollScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'attendance':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AttendanceScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'melting_renewal':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                MeltingRenewalScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'posting_management':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PostingManagementScreen(
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'gold_price':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsScreenEnhanced(
              initialTabIndex: SettingsScreenEnhanced.systemTabIndex,
              focusEntry: SettingsEntry.goldPrice,
            ),
          ),
        );
        result = true;
        break;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('هذه الميزة غير متوفرة حالياً'),
            backgroundColor: AppColors.warning,
          ),
        );
    }

    if (result == true) {
      _loadAllData();
    }
  }

  Widget _buildSalesSummaryCard() {
    final count = salesSummary['count'] ?? 0;
    final amount = salesSummary['amount'] ?? 0.0;
    final weight = salesSummary['weight'] ?? 0.0;
    final byKarat =
        salesSummary['byKarat'] as Map<int, Map<String, double>>? ?? {};

    return _buildSummaryCardWithKarat(
      title: 'ملخص المبيعات',
      icon: Icons.trending_up,
      color: AppColors.success,
      totalStats: [
        {
          'label': 'عدد الفواتير',
          'value': count.toString(),
          'icon': Icons.receipt,
        },
        {
          'label': 'إجمالي المبلغ',
          'value': _formatCash(amount),
          'icon': Icons.attach_money,
        },
        {
          'label': 'إجمالي الوزن',
          'value': _formatWeight(weight, decimals: 3),
          'icon': Icons.scale,
        },
      ],
      karatBreakdown: byKarat,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => InvoicesListScreen(isArabic: true)),
        );
      },
    );
  }

  Widget _buildPurchaseSummaryCard() {
    final count = purchaseSummary['count'] ?? 0;
    final amount = purchaseSummary['amount'] ?? 0.0;
    final weight = purchaseSummary['weight'] ?? 0.0;
    final byKarat =
        purchaseSummary['byKarat'] as Map<int, Map<String, double>>? ?? {};

    return _buildSummaryCardWithKarat(
      title: 'ملخص المشتريات',
      icon: Icons.shopping_bag,
      color: Color(0xFF9A7D0A), // ذهبي عميق
      totalStats: [
        {
          'label': 'عدد الفواتير',
          'value': count.toString(),
          'icon': Icons.receipt_long,
        },
        {
          'label': 'إجمالي المبلغ',
          'value': _formatCash(amount),
          'icon': Icons.payments,
        },
        {
          'label': 'إجمالي الوزن',
          'value': _formatWeight(weight, decimals: 3),
          'icon': Icons.scale,
        },
      ],
      karatBreakdown: byKarat,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => InvoicesListScreen(isArabic: true)),
        );
      },
    );
  }

  // بناء محدد الفترة (يومي/شهري/سنوي/الكل)
  Widget _buildPeriodSelector() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primaryGold.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPeriodButton('يومي', 'daily', Icons.today),
          _buildPeriodButton('شهري', 'monthly', Icons.calendar_month),
          _buildPeriodButton('سنوي', 'yearly', Icons.calendar_today),
          _buildPeriodButton('الكل', 'all', Icons.all_inclusive),
        ],
      ),
    );
  }

  Widget _buildPeriodButton(String label, String period, IconData icon) {
    final isSelected = _summaryPeriod == period;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        setState(() {
          _summaryPeriod = period;
        });
        _calculateSummaries();
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryGold.withValues(alpha: isDark ? 0.3 : 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isSelected
              ? Border.all(color: AppColors.primaryGold, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? AppColors.primaryGold
                  : (isDark ? Colors.grey[400] : Colors.grey[600]),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? AppColors.primaryGold
                    : (isDark ? Colors.grey[400] : Colors.grey[700]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInventorySummaryCard() {
    final count = inventorySummary['count'] ?? 0;
    final weight = inventorySummary['weight'] ?? 0.0;
    final byKarat =
        inventorySummary['byKarat'] as Map<int, Map<String, double>>? ?? {};

    return _buildSummaryCardWithKarat(
      title: 'ملخص المخزون',
      icon: Icons.inventory_2,
      color: AppColors.warning,
      totalStats: [
        {
          'label': 'عدد الأصناف',
          'value': count.toString(),
          'icon': Icons.category,
        },
        {
          'label': 'إجمالي الوزن',
          'value': _formatWeight(weight, decimals: 3),
          'icon': Icons.scale,
        },
      ],
      karatBreakdown: byKarat,
      isInventory: true,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemsScreenEnhanced(api: api)),
        );
      },
    );
  }

  Widget _buildSummaryCardWithKarat({
    required String title,
    required IconData icon,
    required Color color,
    required List<Map<String, dynamic>> totalStats,
    required Map<int, Map<String, double>> karatBreakdown,
    bool isInventory = false,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 15,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: isDark ? 0.2 : 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: color, size: 28),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Cairo',
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(Icons.chevron_left, color: theme.hintColor),
                  ],
                ),

                SizedBox(height: 16),

                // إجمالي
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isDark ? 0.1 : 0.05),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.summarize, color: color, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'الإجمالي العام',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: color,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      ...totalStats
                          .map(
                            (stat) => Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: Row(
                                children: [
                                  Icon(
                                    stat['icon'],
                                    color: theme.hintColor,
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      stat['label'],
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontSize: 13,
                                            fontFamily: 'Cairo',
                                          ),
                                    ),
                                  ),
                                  Text(
                                    stat['value'],
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: color,
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ],
                  ),
                ),

                SizedBox(height: 16),

                // تفصيل حسب العيار
                Row(
                  children: [
                    Icon(Icons.diamond, color: theme.iconTheme.color, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'التفصيل حسب العيار',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Cairo',
                      ),
                    ),
                  ],
                ),

                SizedBox(height: 12),

                // بطاقات العيارات
                ...karatBreakdown.entries.map((entry) {
                  final karat = entry.key;
                  final data = entry.value;
                  final weight = data['weight'] ?? 0.0;
                  final amount = data['amount'];
                  final count = data['count'];

                  // تجاهل العيارات بدون بيانات
                  if (weight == 0) return SizedBox.shrink();

                  return Container(
                    margin: EdgeInsets.only(bottom: 8),
                    padding: EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 
                        isDark ? 0.5 : 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _getKaratColor(karat),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'عيار $karat',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              fontFamily: 'Cairo',
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isInventory && count != null) ...[
                                Row(
                                  children: [
                                    Icon(
                                      Icons.inventory_2,
                                      size: 14,
                                      color: theme.hintColor,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '${count.toInt()}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            fontFamily: 'Cairo',
                                          ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 2),
                              ],
                              if (!isInventory && amount != null) ...[
                                Row(
                                  children: [
                                    Icon(
                                      Icons.payments,
                                      size: 14,
                                      color: theme.hintColor,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '${amount.toStringAsFixed(2)} ر.س',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: 'Cairo',
                                          ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 2),
                              ],
                              Row(
                                children: [
                                  Icon(
                                    Icons.scale,
                                    size: 14,
                                    color: theme.hintColor,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    '${weight.toStringAsFixed(3)} جم',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontSize: 11,
                                      fontWeight: FontWeight.normal,
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getKaratColor(int karat) {
    switch (karat) {
      case 18:
        return Color(0xFFFF6B6B); // أحمر فاتح
      case 21:
        return Color(0xFFD4AF37); // ذهبي كلاسيكي
      case 22:
        return Color(0xFF4ECDC4); // تركواز
      case 24:
        return Color(0xFF9B59B6); // بنفسجي
      default:
        return Colors.grey;
    }
  }

  Widget _buildStatisticsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            icon: Icons.people,
            label: 'العملاء',
            value: customers.length.toString(),
            color: AppColors.info,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CustomersScreen(api: api, isArabic: true),
                ),
              );
            },
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            icon: Icons.business,
            label: 'الموردين',
            value: suppliers.length.toString(),
            color: AppColors.success,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => SuppliersScreen(api: api)),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isDark ? 0.2 : 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                SizedBox(height: 12),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: color,
                    fontFamily: 'Cairo',
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontFamily: 'Cairo',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatCash(double amount, {bool includeSymbol = true}) {
    final formatter = NumberFormat.currency(
      symbol: includeSymbol ? currencySymbol : '',
      decimalDigits: currencyDecimalPlaces,
    );
    final formatted = formatter.format(amount).replaceAll('\u00A0', ' ');
    return includeSymbol ? formatted : formatted.trim();
  }

  String _formatWeight(
    double amount, {
    int? decimals,
    bool includeUnit = true,
  }) {
    final effectiveDecimals = decimals ?? (amount.abs() < 1 ? 3 : 2);
    final formatted = amount.toStringAsFixed(effectiveDecimals);
    return includeUnit ? '$formatted جم' : formatted;
  }
}
