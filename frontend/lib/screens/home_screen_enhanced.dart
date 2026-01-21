import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../providers/quick_actions_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../models/quick_action_item.dart';
import '../widgets/gold_price_ticker_bar.dart';
import '../widgets/app_logo.dart';
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
import 'branches_management_screen.dart';
import 'gold_price_manual_screen_enhanced.dart';
import 'customize_quick_actions_screen.dart';
import 'scrap_sales_invoice_screen.dart';
import 'scrap_purchase_invoice_screen.dart'; // 🆕 فاتورة شراء الكسر المحسّنة
import 'employees_screen.dart';
import 'users_screen.dart';
import 'payroll_screen.dart';
import 'attendance_screen.dart';
import 'payroll_report_screen.dart';
import 'bonus_management_screen.dart';
import 'safe_boxes_screen.dart';
import 'payment_methods_screen_enhanced.dart';
import 'melting_renewal_screen.dart';
import 'gold_reservation_screen.dart';
import 'offices_screen.dart';
import 'posting_management_screen.dart';
import 'audit_log_screen.dart';
import 'shift_closing_screen.dart';
import 'reports/gold_price_history_report_screen.dart';
import 'reports/reports_main_screen.dart';
import 'reports/admin_dashboard_screen.dart';
import 'printing_center_screen.dart';
import 'security_sessions_screen.dart';
import 'change_password_screen.dart';
import 'user_profile_screen.dart';

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
  List safeBoxes = []; // 🆕 خزائن الذهب

  // Currency data
  double exchangeRate = 3.75; // سعر الصرف الافتراضي (دولار -> ريال سعودي)
  String currencySymbol = 'ر.س';
  int currencyDecimalPlaces = 2;
  int mainKarat = 21;

  // Gold price card expansion state
  bool _isGoldPriceExpanded = false;

  bool _isGoldPriceUpdatingNow = false;

  Timer? _goldPriceAutoRefreshTimer;
  String _goldPriceAutoRefreshFingerprint = '';

  // Operations badge (invoice approvals)
  int _pendingApprovalsCount = 0;
  Timer? _approvalsAutoRefreshTimer;

  // Bottom Navigation
  int _selectedNavIndex = 0;
  final List<String> _bottomNavItems = [
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

    _syncGoldPriceAutoRefresh(settings);
  }

  @override
  void dispose() {
    _goldPriceAutoRefreshTimer?.cancel();
    _goldPriceAutoRefreshTimer = null;

    _approvalsAutoRefreshTimer?.cancel();
    _approvalsAutoRefreshTimer = null;
    super.dispose();
  }

  void _syncGoldPriceAutoRefresh(SettingsProvider settings) {
    final enabled = settings.settings['gold_price_auto_update_enabled'] == true;
    final minutesRaw =
        settings.settings['gold_price_auto_update_interval_minutes'];
    final minutes = (minutesRaw is num)
        ? minutesRaw.toInt()
        : int.tryParse(minutesRaw?.toString() ?? '') ?? 60;

    final safeMinutes = minutes < 1 ? 1 : minutes;
    final fingerprint = '$enabled:$safeMinutes';
    if (_goldPriceAutoRefreshFingerprint == fingerprint) return;
    _goldPriceAutoRefreshFingerprint = fingerprint;

    _goldPriceAutoRefreshTimer?.cancel();
    _goldPriceAutoRefreshTimer = null;

    if (!enabled) return;

    _goldPriceAutoRefreshTimer = Timer.periodic(
      Duration(minutes: safeMinutes),
      (_) async {
        if (!mounted) return;
        final auth = context.read<AuthProvider>();
        if (!auth.isAuthenticated) return;
        await _loadGoldPrice();
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<void> _loadAllData() async {
    try {
      final auth = context.read<AuthProvider>();

      setState(() {
        isLoading = true;

        // Prevent showing data from a previous session when switching users.
        if (!auth.hasPermission('customers.view')) customers = [];
        if (!auth.hasPermission('items.view')) items = [];
        if (!auth.hasPermission('invoices.view')) invoices = [];
        if (!auth.hasPermission('suppliers.view')) suppliers = [];
        if (!auth.hasPermission('safe_boxes.view')) safeBoxes = [];
      });

      debugPrint('🔄 بدء تحميل البيانات...');
      final futures = <Future<void>>[];
      if (auth.isAuthenticated) futures.add(_loadGoldPrice());
      if (auth.isAuthenticated) futures.add(_loadPendingApprovalsCount());
      if (auth.hasPermission('customers.view')) futures.add(_loadCustomers());
      if (auth.hasPermission('items.view')) futures.add(_loadItems());
      if (auth.hasPermission('invoices.view')) futures.add(_loadInvoices());
      if (auth.hasPermission('suppliers.view')) futures.add(_loadSuppliers());
      if (auth.hasPermission('safe_boxes.view')) futures.add(_loadSafeBoxes());

      await Future.wait(futures);

      debugPrint(
        '✅ تم تحميل البيانات - العملاء: ${customers.length}, الأصناف: ${items.length}, الفواتير: ${invoices.length}',
      );
    } catch (e) {
      debugPrint('❌ خطأ في تحميل البيانات: $e');
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> _loadPendingApprovalsCount() async {
    try {
      final auth = context.read<AuthProvider>();
      if (!auth.isAuthenticated) return;

      final result = await api.getSystemAlerts(reviewed: false);
      final rows = (result['alerts'] as List?) ?? const [];

      int count = 0;
      for (final row in rows) {
        if (row is Map) {
          final alertType = (row['alert_type'] ?? row['type'] ?? '').toString();
          final entityType = (row['entity_type'] ?? '').toString();
          if (alertType == 'invoice_approval' ||
              (entityType == 'Invoice' && alertType.contains('approval'))) {
            count++;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _pendingApprovalsCount = count;
      });

      // Refresh badge periodically while screen is alive.
      _approvalsAutoRefreshTimer?.cancel();
      _approvalsAutoRefreshTimer = Timer.periodic(const Duration(seconds: 60), (
        _,
      ) async {
        if (!mounted) return;
        final auth = context.read<AuthProvider>();
        if (!auth.isAuthenticated) return;
        await _loadPendingApprovalsCount();
      });
    } catch (e) {
      // Non-blocking: badge is optional.
      debugPrint('⚠️ Failed to load approvals badge: $e');
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

  Future<void> _updateGoldPriceNow() async {
    if (_isGoldPriceUpdatingNow) return;

    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يلزم تسجيل الدخول لتحديث السعر')),
      );
      return;
    }

    setState(() {
      _isGoldPriceUpdatingNow = true;
    });

    try {
      await api.updateGoldPrice();
      await _loadGoldPrice();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تحديث سعر الأونصة بنجاح')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('فشل تحديث السعر: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isGoldPriceUpdatingNow = false;
        });
      }
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

  Future<void> _loadSafeBoxes() async {
    try {
      final data = await api.getSafeBoxes();
      setState(() => safeBoxes = data.map((s) => s.toJson()).toList());
      debugPrint('✅ تم تحميل الخزائن: ${safeBoxes.length}');
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل الخزائن: $e');
    }
  }

  // Drawer Builder
  Widget _buildDrawer(bool isAr, Color gold) {
    final auth = context.read<AuthProvider>();
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

    drawerChildren.add(
      Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              gold.withValues(alpha: 0.85),
              gold.withValues(alpha: 0.45),
            ],
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: theme.colorScheme.surface,
                  child: const AppLogo.gold(width: 34, height: 34),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'مجوهرات خالد' : 'Khaled Jewelery',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAr ? 'نظام إدارة متكامل' : 'Integrated POS Platform',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.8,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            Icons.person,
                            size: 16,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.85,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              auth.username.isEmpty
                                  ? (isAr ? 'حساب المستخدم' : 'Account')
                                  : auth.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.9,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAr
                            ? 'الدور: ${auth.roleDisplayName}'
                            : 'Role: ${auth.role}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.person_outline, size: 16),
                            label: Text(isAr ? 'ملفي' : 'Profile'),
                            onPressed: () async {
                              final userId = auth.currentUser?.id;
                              Navigator.of(context).pop();
                              if (userId == null) return;
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => UserProfileScreen(
                                    api: api,
                                    userId: userId,
                                    isArabic: isAr,
                                  ),
                                ),
                              );
                              await _loadAllData();
                            },
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.lock_outline, size: 16),
                            label: Text(isAr ? 'كلمة المرور' : 'Password'),
                            onPressed: () async {
                              Navigator.of(context).pop();
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const ChangePasswordScreen(),
                                ),
                              );
                            },
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.security, size: 16),
                            label: Text(isAr ? 'الجلسات' : 'Sessions'),
                            onPressed: () async {
                              Navigator.of(context).pop();
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const SecuritySessionsScreen(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Sections collection: each section has a title, color and list of items
    final List<_DrawerSection> sections = [];
    _DrawerSection? currentSection;

    void addDivider() {
      // keep for readability in the builder below; visual separation happens
      // when rendering sections.
      currentSection = null;
    }

    void addSection(String title, Color color) {
      currentSection = _DrawerSection(title: title, color: color);
      sections.add(currentSection!);
    }

    void addDestination({
      required IconData icon,
      required String title,
      required Future<void> Function() onSelected,
      Color? color,
    }) {
      // Ensure every destination belongs to a titled section (collapsible).
      currentSection ??= _DrawerSection(
        title: isAr ? 'القائمة' : 'Menu',
        color: gold,
      );
      if (!sections.contains(currentSection)) {
        sections.add(currentSection!);
      }

      currentSection!.items.add(
        _DrawerSectionItem(
          icon: icon,
          title: title,
          onSelected: onSelected,
          color: color,
        ),
      );
    }

    drawerChildren.add(const SizedBox(height: 12));

    // Home as a fixed top action (not a collapsible section)
    final bool isHomeSelected = _selectedNavIndex == 0;
    drawerChildren.add(
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 10),
        child: Card(
          elevation: 0,
          color: isHomeSelected
              ? gold.withValues(alpha: 0.12)
              : theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.55)),
          ),
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsetsDirectional.fromSTEB(14, 4, 14, 4),
            leading: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.home_outlined, color: gold, size: 20),
            ),
            minLeadingWidth: 34,
            title: Text(
              isAr ? 'الرئيسية' : 'Home',
              style: isHomeSelected
                  ? baseLabelStyle.copyWith(fontWeight: FontWeight.bold)
                  : baseLabelStyle,
            ),
            onTap: () async {
              Navigator.of(context).pop();
              setState(() => _selectedNavIndex = 0);
            },
          ),
        ),
      ),
    );
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
            ),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.business,
      title: isAr ? 'شراء' : 'Purchase (Supplier)',
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
      title: isAr ? 'مرتجع شراء (مورد)' : 'Supplier Purchase Return',
      color: Colors.deepOrange.shade300,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddReturnInvoiceScreen(
              api: api,
              returnType: 'مرتجع شراء (مورد)',
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

    // مكاتب التسكير تصنّف ضمن الموردين (كيان مستقل عن الفروع)
    addDestination(
      icon: Icons.business,
      title: isAr ? 'قائمة مكاتب التسكير' : 'Closing Offices',
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
      isAr ? ' الموارد البشرية' : ' Human Resources',
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
    if (auth.hasPermission('employees.bonuses')) {
      addDestination(
        icon: Icons.card_giftcard,
        title: isAr ? 'المكافآت' : 'Bonuses',
        color: Colors.blueGrey.shade300,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BonusManagementScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }
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

    addDestination(
      icon: Icons.fact_check,
      title: isAr ? 'إغلاق اليومية' : 'Shift Closing',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ShiftClosingScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );

    addDestination(
      icon: Icons.history,
      title: isAr ? 'سجل التدقيق' : 'Audit Log',
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AuditLogScreen()),
        );
      },
    );

    addDivider();
    addSection(
      isAr ? ' الإعدادات والأدوات' : ' Settings & Tools',
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
      icon: Icons.credit_card,
      title: isAr ? 'إعداد وسائل الدفع' : 'Payment Methods',
      color: Colors.amber.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PaymentMethodsScreenEnhanced()),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.account_tree,
      title: isAr ? 'إدارة المكاتب والفروع' : 'Branches Management',
      color: Colors.amber.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BranchesManagementScreen(isArabic: isAr),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.monetization_on,
      title: isAr ? 'تحديث سعر الذهب' : 'Update Gold Price',
      color: gold,
      onSelected: () async {
        if (!auth.hasPermission('gold_price.update')) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isAr
                    ? 'ليس لديك صلاحية تحديث سعر الذهب'
                    : 'You do not have permission to update gold price',
              ),
              backgroundColor: AppColors.warning,
            ),
          );
          return;
        }

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const GoldPriceManualScreenEnhanced(),
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

    // Build section widgets as collapsible ExpansionTiles (card style)
    for (final sec in sections) {
      if (sec.items.isEmpty) continue;

      drawerChildren.add(
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 10),
          child: Card(
            elevation: 0,
            color: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.55),
              ),
            ),
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsetsDirectional.fromSTEB(14, 2, 14, 2),
                childrenPadding: const EdgeInsetsDirectional.fromSTEB(
                  10,
                  0,
                  10,
                  10,
                ),
                collapsedIconColor: theme.iconTheme.color,
                iconColor: theme.colorScheme.primary,
                title: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: sec.color.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sec.title,
                        style: sectionStyle.copyWith(color: sec.color),
                      ),
                    ),
                  ],
                ),
                children: sec.items.map((it) {
                  final iconColor = it.color ?? theme.iconTheme.color;
                  return Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: const EdgeInsetsDirectional.fromSTEB(
                        8,
                        0,
                        8,
                        0,
                      ),
                      leading: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color:
                              iconColor?.withValues(alpha: 0.12) ??
                              theme.colorScheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(it.icon, color: iconColor, size: 20),
                      ),
                      minLeadingWidth: 34,
                      title: Text(it.title, style: baseLabelStyle),
                      trailing: Icon(
                        isAr ? Icons.chevron_left : Icons.chevron_right,
                        color: theme.iconTheme.color?.withValues(alpha: 0.6),
                      ),
                      onTap: () async {
                        Navigator.of(context).pop();
                        await it.onSelected();
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      );
    }

    return Drawer(
      width: 360,
      child: Container(
        color: theme.drawerTheme.backgroundColor ?? theme.colorScheme.surface,
        child: ListView(padding: EdgeInsets.zero, children: drawerChildren),
      ),
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
              AppLogo.matchTextColor(
                (Theme.of(context).appBarTheme.foregroundColor ??
                    Theme.of(context).colorScheme.onPrimary),
                width: 28,
                height: 28,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(isAr ? 'مجوهرات خالد' : 'Khaled Jewelery')),
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
                final displayName = auth.fullName.isEmpty
                    ? (auth.username.isEmpty
                          ? (isAr ? 'حساب المستخدم' : 'Account')
                          : auth.username)
                    : auth.fullName;
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
                            backgroundColor: AppColors.primaryGold.withValues(
                              alpha: 0.2,
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
                            isAr
                                ? 'الدور: ${auth.roleDisplayName}'
                                : 'Role: ${auth.role}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem<String>(
                      value: 'profile',
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline, size: 18),
                          const SizedBox(width: 8),
                          Text(isAr ? 'ملف المستخدم' : 'User Profile'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'password',
                      child: Row(
                        children: [
                          const Icon(Icons.lock_outline, size: 18),
                          const SizedBox(width: 8),
                          Text(isAr ? 'تغيير كلمة المرور' : 'Change Password'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'sessions',
                      child: Row(
                        children: [
                          const Icon(Icons.security, size: 18),
                          const SizedBox(width: 8),
                          Text(isAr ? 'إدارة الجلسات' : 'Sessions'),
                        ],
                      ),
                    ),
                    if (auth.isSystemAdmin || auth.isManager)
                      PopupMenuItem<String>(
                        value: 'users',
                        child: Row(
                          children: [
                            const Icon(Icons.group, size: 18),
                            const SizedBox(width: 8),
                            Text(isAr ? 'إدارة المستخدمين' : 'Users'),
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
                      return;
                    }

                    if (value == 'password') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ChangePasswordScreen(),
                        ),
                      );
                      return;
                    }

                    if (value == 'sessions') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SecuritySessionsScreen(),
                        ),
                      );
                      return;
                    }

                    if (value == 'users') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UsersScreen(api: api, isArabic: isAr),
                        ),
                      );
                      return;
                    }

                    if (value == 'profile') {
                      final userId = auth.currentUser?.id;
                      if (userId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              isAr
                                  ? 'لا يمكن فتح الملف: رقم المستخدم غير متوفر'
                                  : 'Cannot open profile: missing user id',
                            ),
                            backgroundColor: AppColors.warning,
                          ),
                        );
                        return;
                      }
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => UserProfileScreen(
                            api: api,
                            userId: userId,
                            isArabic: isAr,
                          ),
                        ),
                      );
                      return;
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
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadAllData,
            color: AppColors.primaryGold,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),

                    // Gold Price Card
                    _buildGoldPriceCard(),

                    const SizedBox(height: 16),

                    // Operations Center (with badge)
                    _buildOperationsCenterCard(),

                    const SizedBox(height: 24),

                    // Quick Actions
                    _buildQuickActions(),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
        _buildMarketTickerBar(),
      ],
    );
  }

  Widget _buildMarketTickerBar() {
    final settings = context.watch<SettingsProvider>();
    return GoldPriceTickerBar(
      isArabic: widget.isArabic,
      currencySymbol: settings.currencySymbol,
      exchangeRate: exchangeRate,
      refreshInterval: settings.goldPriceTickerRefreshInterval,
    );
  }

  Widget _buildOperationsCenterCard() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return _buildGlassCard(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AdminDashboardScreen(api: api, isArabic: widget.isArabic),
          ),
        );
      },
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primaryGold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.primaryGold.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  Icons.dashboard_customize,
                  color: AppColors.primaryGold,
                  size: 26,
                ),
              ),
              if (_pendingApprovalsCount > 0)
                Positioned(
                  top: -6,
                  right: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade700,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: (isDark ? Colors.black : Colors.white)
                            .withValues(alpha: 0.9),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '$_pendingApprovalsCount',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'غرفة العمليات',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _pendingApprovalsCount > 0
                      ? '$_pendingApprovalsCount فاتورة بانتظار الاعتماد'
                      : 'متابعة التنبيهات والعمليات الحساسة',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_left,
            color: colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCard({required Widget child, VoidCallback? onTap}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surface = theme.colorScheme.surface;

    final tint = isDark
        ? surface.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.55);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.primaryGold.withValues(alpha: 0.25),
                  width: 0.9,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: child,
            ),
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
            final auth = context.read<AuthProvider>();
            if (!auth.hasPermission('gold_price.update')) return;

            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const GoldPriceManualScreenEnhanced(),
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
                                  color: colorScheme.onPrimary.withValues(
                                    alpha: 0.95,
                                  ),
                                  fontSize: 11,
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
                          if (goldPriceDate != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'آخر تحديث: ${DateFormat('dd/MM/yyyy HH:mm').format(goldPriceDate!)}',
                              style: TextStyle(
                                color: colorScheme.onPrimary.withValues(
                                  alpha: 0.75,
                                ),
                                fontSize: 9,
                                fontFamily: 'Cairo',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _isGoldPriceUpdatingNow
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colorScheme.onPrimary,
                              ),
                            ),
                          )
                        : IconButton(
                            tooltip: 'تحديث السعر الآن',
                            onPressed: _updateGoldPriceNow,
                            icon: Icon(
                              Icons.refresh,
                              color: colorScheme.onPrimary,
                              size: 20,
                            ),
                          ),
                    if (goldPrice != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'عيار $mainKarat',
                            style: TextStyle(
                              color: colorScheme.onPrimary.withValues(
                                alpha: 0.85,
                              ),
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
        }),
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
            AnimationLimiter(
              child: Column(
                children: [
                  // عرض الأزرار في صفوف (2 أزرار في كل صف)
                  ...List.generate((activeActions.length / 2).ceil(), (
                    rowIndex,
                  ) {
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
                              child: AnimationConfiguration.staggeredList(
                                position: i,
                                duration: const Duration(milliseconds: 420),
                                child: SlideAnimation(
                                  verticalOffset: 18.0,
                                  child: FadeInAnimation(
                                    child: _buildQuickActionButton(
                                      action: activeActions[i],
                                      theme: theme,
                                    ),
                                  ),
                                ),
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
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildQuickActionButton({
    required QuickActionItem action,
    required ThemeData theme,
  }) {
    return _buildGlassCard(
      onTap: () => _handleQuickActionTap(action.route),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: action.getColor().withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primaryGold.withValues(alpha: 0.18),
              ),
            ),
            child: Icon(action.icon, color: action.getColor(), size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              action.label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
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
            builder: (_) =>
                AddReturnInvoiceScreen(api: api, returnType: 'مرتجع بيع'),
          ),
        );
        break;
      case 'return_purchase':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AddReturnInvoiceScreen(api: api, returnType: 'مرتجع شراء'),
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
          MaterialPageRoute(builder: (_) => AddEditJournalEntryScreen()),
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
            builder: (_) =>
                ReportsMainScreen(api: api, isArabic: widget.isArabic),
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
            builder: (_) => PrintingCenterScreen(isArabic: widget.isArabic),
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
            builder: (_) => PostingManagementScreen(isArabic: widget.isArabic),
          ),
        );
        break;
      case 'gold_price':
        {
          final auth = context.read<AuthProvider>();
          if (!auth.hasPermission('gold_price.update')) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  widget.isArabic
                      ? 'ليس لديك صلاحية تحديث سعر الذهب'
                      : 'You do not have permission to update gold price',
                ),
                backgroundColor: AppColors.warning,
              ),
            );
            result = false;
            break;
          }

          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const GoldPriceManualScreenEnhanced(),
            ),
          );
          result = true;
        }
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

  String _formatCash(double amount, {bool includeSymbol = true}) {
    final formatter = NumberFormat.currency(
      symbol: includeSymbol ? currencySymbol : '',
      decimalDigits: currencyDecimalPlaces,
    );
    final formatted = formatter.format(amount).replaceAll('\u00A0', ' ');
    return includeSymbol ? formatted : formatted.trim();
  }
}

class _DrawerSection {
  final String title;
  final Color color;
  final List<_DrawerSectionItem> items;

  _DrawerSection({
    required this.title,
    required this.color,
    List<_DrawerSectionItem>? items,
  }) : items = items ?? <_DrawerSectionItem>[];
}

class _DrawerSectionItem {
  final IconData icon;
  final String title;
  final Future<void> Function() onSelected;
  final Color? color;

  _DrawerSectionItem({
    required this.icon,
    required this.title,
    required this.onSelected,
    this.color,
  });
}
