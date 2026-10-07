import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../providers/quick_actions_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/sales_race_refresh_provider.dart';
import '../models/quick_action_item.dart';
import '../widgets/gold_price_bar.dart';
import '../widgets/gold_price_ticker_bar.dart';
import '../widgets/app_logo.dart';
import '../app_route_observer.dart';
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
import 'scrap_purchase_invoice_screen.dart'; // 🆕 فاتورة شراء الكسر المحسّنة
import 'employees_screen.dart';
import 'users_screen.dart';
import 'payroll_screen.dart';
import 'attendance_screen.dart';
import 'payroll_report_screen.dart';
import 'bonus_management_screen.dart';
import 'safe_boxes_screen.dart';
import 'clearing_monitor_screen.dart';
import 'payment_methods_screen_enhanced.dart';
import 'melting_renewal_screen.dart';
import 'gold_reservation_screen.dart';
import 'offices_screen.dart';
import 'posting_management_screen.dart';
import 'audit_log_screen.dart';
import 'shift_closing_screen.dart';
import 'weight_closing_execute_screen.dart';
import 'import_documents_screen.dart';
import 'reports/gold_price_history_report_screen.dart';
import 'reports/reports_main_screen.dart';
import 'reports/admin_dashboard_screen.dart';
import 'printing_center_screen.dart';
import 'security_sessions_screen.dart';
import 'change_password_screen.dart';
import 'user_profile_screen.dart';
import 'sales_race_management_screen.dart';

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

class _HomeScreenEnhancedState extends State<HomeScreenEnhanced>
    with RouteAware, WidgetsBindingObserver {
  final ApiService api = ApiService();

  // Isolate LTR runs (dates/numbers) inside Arabic sentences to avoid
  // bidi reordering artifacts like swapped punctuation or digit shaping.
  String _ltrIsolate(String text) => '\u2066$text\u2069';

  // Data
  double? goldPrice;
  DateTime? goldPriceDate;
  double? goldPriceOpening;
  DateTime? goldPriceOpeningDate;
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

  // Gold display toggle: true = persistent bar under AppBar, false = scrolling ticker
  bool _goldBarMode = true;

  bool _isGoldPriceUpdatingNow = false;

  Timer? _goldPriceAutoRefreshTimer;
  String _goldPriceAutoRefreshFingerprint = '';

  // Operations badge (invoice approvals)
  int _pendingApprovalsCount = 0;
  Timer? _approvalsAutoRefreshTimer;

  // Gamification: leaderboard (today/week)
  Map<String, dynamic>? _leaderboardData;
  bool _leaderboardLoading = false;
  String? _leaderboardError;
  String _leaderboardPeriod = 'today';
  DateTime? _leaderboardFetchedAt;
  bool _showAllLeaderboardEmployees = false;
  int _lastHandledSalesRaceRefreshToken = 0;
  bool _pendingLeaderboardRefresh = false;
  String _salesRaceSettingsFingerprint = '';

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
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _goldPriceAutoRefreshTimer?.cancel();
    _goldPriceAutoRefreshTimer = null;

    _approvalsAutoRefreshTimer?.cancel();
    _approvalsAutoRefreshTimer = null;
    super.dispose();
  }

  void _syncGoldPriceAutoRefresh(SettingsProvider settings) {
    final interval = settings.goldPriceTickerRefreshInterval;
    final fingerprint = '${interval?.inSeconds ?? 0}';
    if (_goldPriceAutoRefreshFingerprint == fingerprint) return;
    _goldPriceAutoRefreshFingerprint = fingerprint;

    _goldPriceAutoRefreshTimer?.cancel();
    _goldPriceAutoRefreshTimer = null;

    if (interval == null) return;

    _goldPriceAutoRefreshTimer = Timer.periodic(interval, (_) async {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (!auth.isAuthenticated) return;
      await _loadGoldPrice();
    });
  }

  String _buildSalesRaceSettingsFingerprint(SettingsProvider settings) {
    final raceSettings =
        (settings.settings['sales_race_settings'] as Map?) ?? const {};
    final enabled = raceSettings['enabled'] != false;
    final period =
        (raceSettings['default_period']?.toString().trim().toLowerCase() ??
        'today');
    final pointsPerGram = raceSettings['points_per_gram'];
    final allowFallback =
        raceSettings['allow_fallback_to_latest_period'] != false;
    final showInvoiceCount = raceSettings['show_invoice_count'] != false;
    final showChampion = raceSettings['show_champion'] != false;
    final weeklyTarget = settings.settings['weekly_sales_target_weight'];

    return [
      enabled,
      period,
      pointsPerGram,
      allowFallback,
      showInvoiceCount,
      showChampion,
      weeklyTarget,
    ].join('|');
  }

  void _syncSalesRaceSettingsRefresh(SettingsProvider settings) {
    final nextFingerprint = _buildSalesRaceSettingsFingerprint(settings);
    if (_salesRaceSettingsFingerprint == nextFingerprint) return;

    final hadPreviousFingerprint = _salesRaceSettingsFingerprint.isNotEmpty;
    _salesRaceSettingsFingerprint = nextFingerprint;
    if (!hadPreviousFingerprint) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final auth = context.read<AuthProvider>();
      final quickActions = context.read<QuickActionsProvider>();
      if (!auth.isAuthenticated || !quickActions.showSalesRaceCard) return;

      if (_leaderboardLoading) {
        _pendingLeaderboardRefresh = true;
        return;
      }

      await _loadLeaderboard(period: _leaderboardPeriod);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAllData();
  }

  // ── RouteAware: fires when a pushed screen pops back to here ──
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)! as PageRoute);
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
    _syncSalesRaceSettingsRefresh(settings);
  }

  @override
  void didPopNext() {
    // Returned from a sub-screen — refresh leaderboard but only if data is stale (>30s).
    final last = _leaderboardFetchedAt;
    if (last == null || DateTime.now().difference(last) > const Duration(seconds: 30)) {
      _loadLeaderboard(period: _leaderboardPeriod);
    }
  }

  // ── WidgetsBindingObserver: fires when app resumes from background ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only refresh when the app resumes AND data is at least 2 minutes old.
    // On web, "resumed" fires on every window-focus event, so without this
    // guard every click-back into the browser would spam API calls and cause
    // unnecessary full-tree rebuilds (BackdropFilter is GPU-expensive).
    if (state == AppLifecycleState.resumed) {
      final last = _leaderboardFetchedAt;
      if (last == null || DateTime.now().difference(last) > const Duration(minutes: 2)) {
        _loadLeaderboard(period: _leaderboardPeriod);
      }
    }
  }

  // Unused WidgetsBindingObserver stubs
  @override void didChangeAccessibilityFeatures() {}
  @override void didChangeLocales(List<Locale>? locales) {}
  @override void didChangeMetrics() {}
  @override void didChangePlatformBrightness() {}
  @override void didChangeTextScaleFactor() {}
  @override void didHaveMemoryPressure() {}

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
      final quickActions = context.read<QuickActionsProvider>();
      if (auth.isAuthenticated && quickActions.showSalesRaceCard) {
        futures.add(_loadLeaderboard());
      }
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

  Future<void> _loadLeaderboard({String? period}) async {
    try {
      final auth = context.read<AuthProvider>();
      final settings = context.read<SettingsProvider>();
      if (!auth.isAuthenticated) return;

      final rawRaceSettings = settings.settings['sales_race_settings'];
      Map<String, dynamic> raceSettings = const <String, dynamic>{};
      if (rawRaceSettings is Map<String, dynamic>) {
        raceSettings = rawRaceSettings;
      } else if (rawRaceSettings is Map) {
        raceSettings = rawRaceSettings.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      } else if (rawRaceSettings is String &&
          rawRaceSettings.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(rawRaceSettings);
          if (decoded is Map<String, dynamic>) {
            raceSettings = decoded;
          } else if (decoded is Map) {
            raceSettings = decoded.map(
              (key, value) => MapEntry(key.toString(), value),
            );
          }
        } catch (_) {
          raceSettings = const <String, dynamic>{};
        }
      }
      final configuredDefaultPeriod =
          raceSettings['default_period']?.toString().trim().toLowerCase() ==
              'week'
          ? 'week'
          : 'today';
      final selectedPeriod =
          (period ??
                  (_leaderboardData == null
                      ? configuredDefaultPeriod
                      : _leaderboardPeriod))
              .trim()
              .toLowerCase();

      if (mounted) {
        setState(() {
          _leaderboardLoading = true;
          _leaderboardError = null;
          _leaderboardPeriod = selectedPeriod;
        });
      }

      final data = await api.getHomeLeaderboard(
        period: selectedPeriod,
        metric: 'points',
      );
      if (!mounted) return;
      setState(() {
        _leaderboardData = data;
        _leaderboardFetchedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _leaderboardError = e.toString();
        _leaderboardData = null;
        _leaderboardFetchedAt = null;
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _leaderboardLoading = false;
      });
      if (_pendingLeaderboardRefresh) {
        _pendingLeaderboardRefresh = false;
        await _loadLeaderboard(period: _leaderboardPeriod);
      }
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
      // Use the public endpoint for reading so the UI stays consistent with
      // the ticker and doesn't get stuck if the auth token expires.
      final response = await api.getGoldPricePublic();
      if (response['price_usd_per_oz'] != null) {
        setState(() {
          goldPrice = (response['price_usd_per_oz'] is String)
              ? double.tryParse(response['price_usd_per_oz'])
              : (response['price_usd_per_oz'] as num?)?.toDouble();

          if (response['date'] != null) {
            goldPriceDate = DateTime.parse(response['date']);
          }

          if (response['opening_price_usd_per_oz'] != null) {
            goldPriceOpening = (response['opening_price_usd_per_oz'] is String)
                ? double.tryParse(response['opening_price_usd_per_oz'])
                : (response['opening_price_usd_per_oz'] as num?)?.toDouble();
          } else {
            goldPriceOpening = goldPrice;
          }

          if (response['opening_date'] != null) {
            goldPriceOpeningDate = DateTime.tryParse(
              response['opening_date'].toString(),
            );
          } else {
            goldPriceOpeningDate = goldPriceDate;
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
                                  builder: (_) =>
                                      const SecuritySessionsScreen(),
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
            builder: (_) => SalesInvoiceScreenV2(
        scrap: true,
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
            builder: (_) =>
                const PurchaseInvoiceScreen(supplierReturnMode: true),
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
      icon: Icons.emoji_events_rounded,
      title: isAr ? 'سباق الأداء' : 'Performance Race',
      color: AppColors.primaryGold,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SalesRaceManagementScreen(api: api, isArabic: isAr),
          ),
        );
        _loadLeaderboard(period: _leaderboardPeriod);
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
          MaterialPageRoute(
            builder: (_) => SafeBoxesScreen(balancesView: true),
          ),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.swap_horiz,
      title: isAr ? 'مراقبة تسوية المقاصة' : 'Clearing Settlement',
      color: Colors.teal.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ClearingMonitorScreen()),
        );
        await _loadAllData();
      },
    );
    addDestination(
      icon: Icons.credit_card,
      title: isAr ? 'إدارة وسائل الدفع' : 'Payment Methods',
      color: Colors.amber.shade600,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const PaymentMethodsScreenEnhanced(),
          ),
        );
        await _loadAllData();
      },
    );

    if (auth.isSystemAdmin) {
      addDestination(
        icon: Icons.upload_file,
        title: isAr ? 'استيراد المستندات (Excel)' : 'Import Documents (Excel)',
        color: Colors.amber.shade600,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ImportDocumentsScreen(isArabic: isAr),
            ),
          );
          await _loadAllData();
        },
      );
    }
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
    final salesRaceRefreshToken = context
        .watch<SalesRaceRefreshProvider>()
        .refreshToken;

    if (salesRaceRefreshToken != _lastHandledSalesRaceRefreshToken) {
      _lastHandledSalesRaceRefreshToken = salesRaceRefreshToken;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final auth = context.read<AuthProvider>();
        final quickActions = context.read<QuickActionsProvider>();
        if (!auth.isAuthenticated || !quickActions.showSalesRaceCard) return;
        if (_leaderboardLoading) {
          _pendingLeaderboardRefresh = true;
          return;
        }
        await _loadLeaderboard(period: _leaderboardPeriod);
      });
    }

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
            // زر تبديل عرض سعر الذهب (شريط ثابت / شريط متحرك)
            IconButton(
              icon: Icon(
                _goldBarMode
                    ? Icons.view_stream_outlined
                    : Icons.horizontal_rule_rounded,
              ),
              tooltip: _goldBarMode
                  ? 'تبديل إلى الشريط المتحرك'
                  : 'تبديل إلى الشريط الثابت',
              onPressed: () => setState(() => _goldBarMode = !_goldBarMode),
            ),
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
            // زر تبديل المستخدم - ظاهر مباشرة في الشريط
            Consumer<AuthProvider>(
              builder: (context, auth, _) => IconButton(
                icon: const Icon(Icons.switch_account),
                tooltip: isAr ? 'تبديل المستخدم' : 'Switch User',
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(isAr ? 'تبديل المستخدم' : 'Switch User'),
                      content: Text(
                        isAr
                            ? 'سيتم تسجيل خروج المستخدم الحالي.\nهل تريد المتابعة؟'
                            : 'The current user will be signed out.\nDo you want to continue?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(isAr ? 'إلغاء' : 'Cancel'),
                        ),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.switch_account, size: 18),
                          label: Text(isAr ? 'تبديل' : 'Switch'),
                          onPressed: () => Navigator.pop(ctx, true),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await auth.logout();
                  }
                },
              ),
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
                            radius: 17,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.25,
                            ),
                            child: Text(
                              displayName.isNotEmpty
                                  ? displayName[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
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
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                shadows: [
                                  Shadow(
                                    color: Colors.black26,
                                    blurRadius: 4,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
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
    final isHomeTab = navKey == 'home';

    Widget tab;
    switch (navKey) {
      case 'home':
        tab = _buildHomeTabContent(isAr);
      case 'invoices':
        tab = InvoicesListScreen(isArabic: isAr);
      case 'customers':
        tab = CustomersScreen(api: api, isArabic: isAr);
      case 'items':
        tab = ItemsScreenEnhanced(api: api);
      case 'settings':
        tab = SettingsScreenEnhanced();
      default:
        tab = _buildHomeTabContent(isAr);
    }

    // Show the enhanced gold bar only on the home tab.
    if (_goldBarMode && isHomeTab) {
      return Column(
        children: [
          GoldPriceBar(
            goldPrice: goldPrice,
            goldPriceOpening: goldPriceOpening,
            goldPriceDate: goldPriceDate,
            exchangeRate: exchangeRate,
            mainKarat: mainKarat,
            isUpdating: _isGoldPriceUpdatingNow,
            onRefresh: _updateGoldPriceNow,
          ),
          Expanded(child: tab),
        ],
      );
    }
    return tab;
  }

  // Original home screen content
  Widget _buildHomeTabContent(bool isAr) {
    final showSalesRaceCard = context
        .watch<QuickActionsProvider>()
        .showSalesRaceCard;
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

                    // Operations Center (with badge)
                    _buildOperationsCenterCard(),

                    const SizedBox(height: 24),

                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 1100;

                        if (isWide && showSalesRaceCard) {
                          // Large screens: show Sales Race beside invoice buttons.
                          // RTL: first child appears on the right, so put Quick Actions first.
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _buildQuickActions()),
                              const SizedBox(width: 16),
                              Expanded(child: _buildLeaderboardCard(isAr)),
                            ],
                          );
                        }

                        // Small/medium screens: stacked layout.
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showSalesRaceCard) ...[
                              _buildLeaderboardCard(isAr),
                              const SizedBox(height: 24),
                            ],
                            _buildQuickActions(),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!_goldBarMode) _buildMarketTickerBar(),
      ],
    );
  }

  Widget _buildLeaderboardCard(bool isAr) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final data = _leaderboardData;
    final config = data?['config'] as Map?;
    final period = (data?['period'] ?? _leaderboardPeriod).toString();
    final isWeek = period == 'week';
    final isMonth = period == 'month';
    final ranking = (data?['ranking'] as List?) ?? const [];
    final champion = data?['champion'] as Map?;
    final adminSummary = data?['admin_summary'] as Map?;
    final raceEnabled = config?['enabled'] != false;
    final showInvoiceCount = config?['show_invoice_count'] != false;
    // مبلغ المبيعات يظهر دائماً لجميع الموظفين
    const showSalesAmountPerEmployee = true;
    final showChampion = config?['show_champion'] != false;
    final isFallback = data?['is_fallback'] == true;
    final effectiveStartDate = DateTime.tryParse(
      (data?['effective_start_date'] ?? '').toString(),
    );
    final fetchedAt = _leaderboardFetchedAt;

    final weeklyTarget = (data?['weekly_target_weight_g'] as num?)?.toDouble();
    final teamWeight = (data?['team_weight_g'] as num?)?.toDouble();
    final remainingWeight = (data?['remaining_weight_g'] as num?)?.toDouble();
    final metric = (data?['metric'] ?? 'weight_g').toString();

    final weeklyTargetPoints = (data?['weekly_target_points'] as num?)?.toInt();
    final teamPoints = (data?['team_points'] as num?)?.toInt();
    final remainingPoints = (data?['remaining_points'] as num?)?.toInt();
    final targetProgress =
      (data?['target_progress'] as num?)?.toDouble() ?? 0.0;
    final usePointsGoal = metric == 'points';
    final goalCurrentValue = usePointsGoal
      ? (teamPoints?.toDouble())
      : teamWeight;
    final goalTargetValue = usePointsGoal
      ? (weeklyTargetPoints?.toDouble())
      : weeklyTarget;
    final goalRemainingValue = usePointsGoal
      ? (remainingPoints?.toDouble())
      : remainingWeight;
    final effectiveTargetProgress =
      (goalCurrentValue != null &&
        goalTargetValue != null &&
        goalTargetValue > 0)
      ? (goalCurrentValue / goalTargetValue).clamp(0.0, 1.0)
      : targetProgress.clamp(0.0, 1.0);
    final isGoalAchieved =
      (goalCurrentValue != null &&
        goalTargetValue != null &&
        goalTargetValue > 0 &&
        goalCurrentValue >= goalTargetValue) ||
      targetProgress >= 0.9999;
    final Color goalColor = isGoalAchieved
        ? AppColors.success
      : (effectiveTargetProgress < 0.5 ? AppColors.warning : AppColors.info);
    final goalPercentText =
      '${(effectiveTargetProgress * 100).round()}%';
    final goalCurrentText = usePointsGoal
      ? '${(goalCurrentValue ?? 0).toStringAsFixed(0)} ${isAr ? 'نقطة' : 'pts'}'
      : '${(goalCurrentValue ?? 0).toStringAsFixed(1)} ${isAr ? 'جم' : 'g'}';
    final goalTargetText = usePointsGoal
      ? '${(goalTargetValue ?? 0).toStringAsFixed(0)} ${isAr ? 'نقطة' : 'pts'}'
      : '${(goalTargetValue ?? 0).toStringAsFixed(0)} ${isAr ? 'جم' : 'g'}';
    final goalRemainingText = goalRemainingValue == null
      ? null
      : (usePointsGoal
          ? '${goalRemainingValue.toStringAsFixed(0)} ${isAr ? 'نقطة' : 'pts'}'
          : '${goalRemainingValue.toStringAsFixed(0)} ${isAr ? 'جم' : 'g'}');

    final microcopy = isMonth
        ? (isAr ? 'سباق الشهر: من يتصدر نهاية الشهر؟' : 'Monthly race: who tops the board?')
        : isWeek
        ? (isGoalAchieved
          ? (isAr ? 'إنجاز جماعي واضح هذا الأسبوع' : 'A strong team achievement this week')
              : (isAr
            ? 'تقدم متدرج نحو إغلاق هدف الأسبوع'
            : 'Steady progress toward closing the weekly goal'))
        : (isAr ? 'هدف اليوم: اجعل العميل بطلاً في قصتك، وليس مجرد رقم في مبيعاتك.' : 'Today\'s goal: speed + accuracy');

    String? fallbackText() {
      if (!isFallback || effectiveStartDate == null) return null;
      final formatted = DateFormat(
        'dd/MM/yyyy',
        'en',
      ).format(effectiveStartDate);
      final date = _ltrIsolate(formatted);
      if (isMonth) {
        return isAr
            ? 'لا توجد مبيعات هذا الشهر — يتم عرض آخر شهر بدأ في $date'
            : 'No sales this month — showing the latest month starting $date';
      }
      if (isWeek) {
        return isAr
            ? 'لا توجد مبيعات هذا الأسبوع — يتم عرض آخر أسبوع بدأ في $date'
            : 'No sales this week — showing the latest week starting $date';
      }
      return isAr
          ? 'لا توجد مبيعات اليوم — يتم عرض آخر يوم مبيعات بتاريخ $date'
          : 'No sales today — showing the latest sales day on $date';
    }

    final fallbackMessage = fallbackText();

    String? effectivePeriodText() {
      if (effectiveStartDate == null) return null;
      if (isMonth) {
        final monthName = DateFormat('MMMM yyyy', isAr ? 'ar' : 'en').format(effectiveStartDate);
        return isAr ? 'بيانات الشهر: $monthName' : 'Month: $monthName';
      }
      if (isWeek) {
        final weekEnd = effectiveStartDate.add(const Duration(days: 6));
        final startText = _ltrIsolate(
          DateFormat('dd/MM/yyyy', 'en').format(effectiveStartDate),
        );
        final endText = _ltrIsolate(
          DateFormat('dd/MM/yyyy', 'en').format(weekEnd),
        );
        return isAr
            ? 'فترة البيانات: $startText - $endText'
            : 'Data range: $startText - $endText';
      }

      final todayText = _ltrIsolate(
        DateFormat('dd/MM/yyyy', 'en').format(effectiveStartDate),
      );
      return isAr ? 'بيانات اليوم: $todayText' : 'Today data: $todayText';
    }

    String? lastUpdatedText() {
      if (fetchedAt == null) return null;
      final formatted = DateFormat('dd/MM/yyyy HH:mm', 'en').format(fetchedAt);
      final stamp = _ltrIsolate(formatted);
      return isAr ? 'آخر تحديث: $stamp' : 'Last update: $stamp';
    }

    final effectivePeriodLabel = effectivePeriodText();
    final updateLabel = lastUpdatedText();
    final allRanking = ranking.whereType<Map>().toList(growable: false);
    final topRanking = allRanking.take(3).toList(growable: false);
    final extraRanking = allRanking.skip(3).toList(growable: false);
    final remainingEmployeesCount = allRanking.length > topRanking.length
        ? allRanking.length - topRanking.length
        : 0;
    final championName = (champion?['name'] ?? '').toString().trim();
    final metricPillText = switch (metric) {
      'count' => isAr ? 'عرض حسب الفواتير' : 'Invoice View',
      'points' => isAr ? 'عرض حسب النقاط' : 'Points View',
      _ => isAr ? 'عرض حسب الوزن' : 'Weight View',
    };

    String rankRoleLabel(int index) {
      if (index == 0) return isAr ? 'المتصدر' : 'Leader';
      if (index == 1) return isAr ? 'الثاني' : 'Second';
      if (index == 2) return isAr ? 'الثالث' : 'Third';
      return isAr ? 'مشارك' : 'Ranked';
    }

    Widget buildRow(Map row, int index) {
      final name = (row['name'] ?? '').toString();
      final score = (row['score'] as num?)?.toDouble() ?? 0.0;
      final share = (row['share'] as num?)?.toDouble() ?? 0.0;
      final count = (row['count'] as num?)?.toInt() ?? 0;
      final salesAmount = (row['sales_amount'] as num?)?.toDouble() ?? 0.0;
      final purchaseAmount = (row['purchase_amount'] as num?)?.toDouble() ?? 0.0;

      final isLeader = index == 0;
      final valueColor = isLeader ? colorScheme.primary : colorScheme.secondary;
      final progressColor = switch (index) {
        1 => const Color(0xFF98A2B3),
        2 => const Color(0xFFCD7F32),
        _ => valueColor,
      };
      final medalAccent = switch (index) {
        0 => AppColors.primaryGold,
        1 => const Color(0xFF98A2B3),
        2 => const Color(0xFFCD7F32),
        _ => valueColor,
      };
      final roleBadgeColor = index == 0
          ? AppColors.darkGold
          : colorScheme.onSurface.withValues(alpha: 0.62);
      final invoiceLabelEn = count == 1 ? 'invoice' : 'invoices';
      final invoiceLabelAr = count == 1 ? 'فاتورة بيع' : 'فواتير بيع';
      final invoiceSummary = showInvoiceCount
          ? (metric == 'points'
            ? (isAr ? '$count فاتورة' : '$count transactions')
            : (isAr ? '$count $invoiceLabelAr' : '$count sales $invoiceLabelEn'))
          : (metric == 'points'
            ? (isAr ? 'فواتير مبيعات ومشتريات' : 'Sales and purchases activity')
            : (isAr ? 'فواتير بيع' : 'Sales activity'));
      final scoreValueText = switch (metric) {
        'count' => count.toString(),
        'points' => score.toStringAsFixed(0),
        _ => score.toStringAsFixed(1),
      };
      final scoreUnitText = switch (metric) {
        'count' => isAr ? 'فاتورة' : 'Invoices',
        'points' => isAr ? 'نقطة' : 'Points',
        _ => isAr ? 'جم' : 'g',
      };
      final amountSummary = isAr
          ? 'مبيعات ${salesAmount.toStringAsFixed(currencyDecimalPlaces)} $currencySymbol • مشتريات ${purchaseAmount.toStringAsFixed(currencyDecimalPlaces)} $currencySymbol'
          : 'Sales ${salesAmount.toStringAsFixed(currencyDecimalPlaces)} $currencySymbol • Purchases ${purchaseAmount.toStringAsFixed(currencyDecimalPlaces)} $currencySymbol';
      final avatarText = name.trim().isEmpty
          ? '?'
          : name
                .trim()
                .split(RegExp(r'\s+'))
                .where((part) => part.isNotEmpty)
                .take(2)
                .map((part) => part.characters.first)
                .join();

      return Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: index < 3 ? 10 : 4,
              sigmaY: index < 3 ? 10 : 4,
            ),
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 14, 12),
              decoration: BoxDecoration(
                color: isDark
                    ? colorScheme.surfaceContainerHighest
                        .withValues(alpha: index < 3 ? 0.65 : 0.50)
                    : Colors.white.withValues(alpha: index < 3 ? 0.52 : 0.40),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: index < 3
                      ? medalAccent.withValues(alpha: index == 0 ? 0.38 : 0.18)
                      : colorScheme.onSurface.withValues(alpha: 0.07),
                ),
                boxShadow: index < 3
                    ? [
                        BoxShadow(
                          color: medalAccent.withValues(
                            alpha: index == 0 ? 0.12 : 0.06,
                          ),
                          blurRadius: index == 0 ? 18 : 10,
                          offset: Offset(0, index == 0 ? 6 : 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: index < 3
                            ? medalAccent.withValues(alpha: 0.82)
                            : colorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: medalAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: medalAccent.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        avatarText,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: medalAccent,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: roleBadgeColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                rankRoleLabel(index),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: roleBadgeColor,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          invoiceSummary,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.58),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (showSalesAmountPerEmployee) ...[
                          const SizedBox(height: 3),
                          Text(
                            amountSummary,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppColors.darkGold,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            height: 5,
                            color: colorScheme.onSurface.withValues(alpha: 0.07),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(
                                begin: 0,
                                end: share.clamp(0.0, 1.0),
                              ),
                              duration: Duration(milliseconds: 650 + (index * 120)),
                              curve: Curves.easeOutCubic,
                              builder: (context, value, child) {
                                return Stack(
                                  children: [
                                    FractionallySizedBox(
                                      alignment: AlignmentDirectional.centerStart,
                                      widthFactor: value,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: AlignmentDirectional.centerStart,
                                            end: AlignmentDirectional.centerEnd,
                                            colors: [
                                              progressColor.withValues(alpha: 0.72),
                                              medalAccent,
                                            ],
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: medalAccent.withValues(
                                                alpha: 0.18,
                                              ),
                                              blurRadius: 6,
                                              offset: const Offset(0, 1),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 72),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: index == 0
                            ? AppColors.primaryGold.withValues(alpha: 0.14)
                            : medalAccent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: index == 0
                              ? AppColors.primaryGold.withValues(alpha: 0.28)
                              : medalAccent.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            scoreValueText,
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: medalAccent,
                              fontWeight: FontWeight.w800,
                              fontSize: index == 0 ? 23 : null,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            scoreUnitText,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.46,
                              ),
                              fontWeight: FontWeight.w600,
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
        ),
      );
    }

    return _buildGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: AlignmentDirectional.topStart,
                  end: AlignmentDirectional.bottomEnd,
                  colors: [
                    AppColors.primaryGold.withValues(alpha: 0.18),
                    AppColors.lightGold.withValues(alpha: 0.10),
                    isDark
                        ? Colors.black.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.60),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppColors.primaryGold.withValues(alpha: 0.22),
                              AppColors.darkGold.withValues(alpha: 0.10),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppColors.primaryGold.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Icon(
                          Icons.emoji_events_rounded,
                          color: AppColors.darkGold,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr
                                  ? (_leaderboardPeriod == 'week'
                                        ? 'سباق الأداء — الأسبوع'
                                        : _leaderboardPeriod == 'month'
                                            ? 'سباق الأداء — الشهر'
                                            : 'سباق الأداء — اليوم')
                                  : (_leaderboardPeriod == 'week'
                                        ? 'Sales Race — Week'
                                        : _leaderboardPeriod == 'month'
                                            ? 'Sales Race — Month'
                                            : 'Sales Race — Today'),  
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: AppColors.deepGold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (showChampion && championName.isNotEmpty) ...[
                              Row(
                                children: [
                                  Icon(
                                    Icons.star_rounded,
                                    size: 14,
                                    color: AppColors.primaryGold,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      isAr
                                          ? 'المتصدر الآن: $championName'
                                          : 'Current leader: $championName',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: AppColors.darkGold,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              Text(
                                microcopy,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(
                                    alpha: 0.58,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SegmentedButton<String>(
                        segments: <ButtonSegment<String>>[
                          ButtonSegment<String>(
                            value: 'today',
                            label: Text(isAr ? 'اليوم' : 'Today'),
                          ),
                          ButtonSegment<String>(
                            value: 'week',
                            label: Text(isAr ? 'الأسبوع' : 'Week'),
                          ),
                          ButtonSegment<String>(
                            value: 'month',
                            label: Text(isAr ? 'الشهر' : 'Month'),
                          ),
                        ],
                        selected: <String>{_leaderboardPeriod},
                        onSelectionChanged: _leaderboardLoading
                            ? null
                            : (selection) {
                                final next = selection.isNotEmpty
                                    ? selection.first
                                    : _leaderboardPeriod;
                                if (next == _leaderboardPeriod) return;
                                setState(() {
                                  _leaderboardPeriod = next;
                                  _showAllLeaderboardEmployees = false;
                                });
                                _loadLeaderboard(period: next);
                              },
                        showSelectedIcon: false,
                        style: _leaderboardSegmentedButtonStyle(theme),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            if (effectivePeriodLabel != null || updateLabel != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.lightGold.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.primaryGold.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Text(
                      metricPillText,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.deepGold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (topRanking.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _showAllLeaderboardEmployees
                            ? (isAr ? 'عرض كامل الفريق' : 'Full team view')
                            : (isAr
                                  ? 'أفضل ${topRanking.length} موظفين'
                                  : 'Top ${topRanking.length} staff'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (effectivePeriodLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        effectivePeriodLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (updateLabel != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: colorScheme.primary.withValues(alpha: 0.16),
                        ),
                      ),
                      child: Text(
                        updateLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (fallbackMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.history_toggle_off_rounded,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fallbackMessage,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (!raceEnabled)
              Text(
                isAr
                    ? 'تم إيقاف سباق الأداء من الإعدادات.'
                    : 'Sales race is disabled from settings.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              )
            else if (_leaderboardLoading)
              LinearProgressIndicator(
                minHeight: 6,
                backgroundColor: colorScheme.onSurface.withValues(alpha: 0.08),
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              )
            else if (_leaderboardError != null)
              Text(
                isAr ? 'تعذر تحميل لوحة الصدارة' : 'Could not load leaderboard',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
              )
            else ...[
              if ((isWeek || isMonth) &&
                  ((metric == 'points' &&
                          weeklyTargetPoints != null &&
                          teamPoints != null) ||
                      (metric != 'points' &&
                          weeklyTarget != null &&
                          teamWeight != null))) ...[
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [
                        isDark
                            ? colorScheme.surfaceContainerHighest
                            : Colors.white,
                        goalColor.withValues(alpha: 0.06),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: goalColor.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isAr ? 'هدف الفريق الأسبوعي' : 'Weekly Team Goal',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: goalColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isGoalAchieved
                                      ? (isAr
                                            ? 'أداء جماعي مكتمل بإيقاع قوي'
                                            : 'A completed team push with strong momentum')
                                      : (isAr
                                            ? 'قراءة سريعة لما تحقق هذا الأسبوع'
                                            : 'A quick view of what the team achieved this week'),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.68,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: goalColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: goalColor.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  goalPercentText,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: goalColor,
                                  ),
                                ),
                                Text(
                                  isAr ? 'إنجاز' : 'Progress',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurface.withValues(
                                      alpha: 0.55,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isDark
                              ? colorScheme.surface.withValues(alpha: 0.35)
                              : Colors.white.withValues(alpha: 0.82),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: colorScheme.onSurface.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isAr ? 'المحقق حتى الآن' : 'Achieved so far',
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      color: colorScheme.onSurface.withValues(alpha: 0.56),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    goalCurrentText,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      color: goalColor,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 42,
                              color: colorScheme.onSurface.withValues(alpha: 0.08),
                            ),
                            const SizedBox(width: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isAr ? 'الهدف' : 'Target',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: colorScheme.onSurface.withValues(alpha: 0.56),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  goalTargetText,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: AppColors.primaryGold,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (!isGoalAchieved && goalRemainingText != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.warning.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: AppColors.warning.withValues(alpha: 0.16),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.timelapse_rounded,
                                  size: 15,
                                  color: AppColors.warning,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isAr
                                      ? 'المتبقي: $goalRemainingText'
                                      : 'Remaining: $goalRemainingText',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: AppColors.warning,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: effectiveTargetProgress,
                          ),
                          duration: const Duration(milliseconds: 700),
                          builder: (context, value, child) =>
                              LinearProgressIndicator(
                                value: value,
                                minHeight: 8,
                                backgroundColor: colorScheme.onSurface
                                    .withValues(alpha: 0.08),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  goalColor,
                                ),
                              ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                                isGoalAchieved
                                    ? (isAr
                                          ? 'استمروا بهذا النسق، الفريق أنهى الهدف وبقيت فرصة لتوسيع الفارق.'
                                          : 'Keep this tempo, the team has closed the goal and can widen the lead.')
                                        : (isAr
                                          ? 'المؤشر يتحرك بوضوح، والهدف ما زال في المتناول هذا الأسبوع.'
                                          : 'The indicator is moving clearly, and the goal remains within reach this week.'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(alpha: 0.76),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (allRanking.isEmpty)
                Text(
                  isAr
                      ? (isMonth
                            ? 'لم يبدأ التحدي هذا الشهر بعد.'
                            : isWeek
                                ? 'لم يبدأ التحدي هذا الأسبوع بعد.'
                                : 'لا توجد مبيعات مسجلة اليوم بعد.')
                      : (isMonth
                            ? 'The monthly challenge hasn\'t started yet.'
                            : isWeek
                                ? 'The weekly challenge hasn\'t started yet.'
                                : 'No sales recorded today yet.'),
                  style: theme.textTheme.bodySmall,
                )
              else ...[
                for (int i = 0; i < topRanking.length; i++)
                  buildRow(topRanking[i], i),
                if (extraRanking.isNotEmpty)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeInOutCubic,
                    alignment: AlignmentDirectional.topCenter,
                    child: ClipRect(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        opacity: _showAllLeaderboardEmployees ? 1 : 0,
                        child: _showAllLeaderboardEmployees
                            ? Column(
                                children: [
                                  const SizedBox(height: 4),
                                  for (int i = 0; i < extraRanking.length; i++)
                                    buildRow(extraRanking[i], i + topRanking.length),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                if (remainingEmployeesCount > 0 || _showAllLeaderboardEmployees)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          setState(() {
                            _showAllLeaderboardEmployees =
                                !_showAllLeaderboardEmployees;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primaryGold.withValues(
                              alpha: _showAllLeaderboardEmployees ? 0.14 : 0.08,
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: AppColors.primaryGold.withValues(alpha: 0.16),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedRotation(
                                duration: const Duration(milliseconds: 220),
                                turns: _showAllLeaderboardEmployees ? 0.5 : 0,
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: AppColors.darkGold,
                                ),
                              ),
                              const SizedBox(width: 6),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                transitionBuilder: (child, animation) =>
                                    FadeTransition(opacity: animation, child: child),
                                child: Text(
                                  _showAllLeaderboardEmployees
                                      ? (isAr
                                            ? 'إخفاء بقية الموظفين'
                                            : 'Hide remaining staff')
                                      : (isAr
                                            ? 'عرض تقدم $remainingEmployeesCount موظفين آخرين'
                                            : 'Show progress for $remainingEmployeesCount more staff'),
                                  key: ValueKey<bool>(_showAllLeaderboardEmployees),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.darkGold,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
            if (raceEnabled &&
                adminSummary != null &&
                ((adminSummary['total_sales_amount'] != null) ||
                    (adminSummary['total_purchase_amount'] != null) ||
                    (adminSummary['total_points'] != null))) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (adminSummary['total_sales_amount'] != null) ...[
                    Expanded(
                      child: _buildLeaderboardSummaryTile(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.point_of_sale_rounded,
                        label: isAr ? 'مبلغ المبيعات' : 'Sales',
                        value:
                            '${(adminSummary['total_sales_amount'] ?? 0).toString()} ${adminSummary['currency'] ?? 'SAR'}',
                        accent: AppColors.primaryGold,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (adminSummary['total_purchase_amount'] != null) ...[
                    Expanded(
                      child: _buildLeaderboardSummaryTile(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.shopping_bag_rounded,
                        label: isAr ? 'مبلغ المشتريات' : 'Purchases',
                        value:
                            '${(adminSummary['total_purchase_amount'] ?? 0).toString()} ${adminSummary['currency'] ?? 'SAR'}',
                        accent: AppColors.darkGold,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (adminSummary['total_points'] != null)
                    Expanded(
                      child: _buildLeaderboardSummaryTile(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.stars_rounded,
                        label: isAr ? 'إجمالي النقاط' : 'Points',
                        value: isAr
                            ? '${(adminSummary['total_points'] ?? 0).toString()} نقطة'
                            : '${(adminSummary['total_points'] ?? 0).toString()} pts',
                        accent: AppColors.deepGold,
                      ),
                    ),
                ],
              ),
            ],
                ],
              ),
            ),
          ],
        ),
    );
  }

  Widget _buildLeaderboardSummaryTile({
    required ThemeData theme,
    required ColorScheme colorScheme,
    required IconData icon,
    required String label,
    required String value,
    required Color accent,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.12)),
                ),
                child: Icon(icon, size: 18, color: accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accent.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: accent,
                        fontSize: 18,
                        letterSpacing: -0.3,
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

  ButtonStyle _leaderboardSegmentedButtonStyle(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return ButtonStyle(
      side: WidgetStateProperty.all(BorderSide.none),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      padding: WidgetStateProperty.all(
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textStyle: WidgetStateProperty.all(
        theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.deepGold;
        }
        return colorScheme.onSurface.withValues(alpha: 0.72);
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.primaryGold.withValues(alpha: 0.9);
        }
        return Colors.white.withValues(alpha: 0.82);
      }),
      overlayColor: WidgetStateProperty.all(
        AppColors.primaryGold.withValues(alpha: 0.08),
      ),
      elevation: WidgetStateProperty.all(0),
    );
  }

  Widget _buildMarketTickerBar() {
    final settings = context.watch<SettingsProvider>();
    return GoldPriceTickerBar(
      isArabic: widget.isArabic,
      ouncePriceUsd: goldPrice,
      openingOuncePriceUsd: goldPriceOpening,
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
                  'لوحة التحكم',
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
            builder: (_) => SalesInvoiceScreenV2(
        scrap: true,
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
      case 'journal_entries_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JournalEntriesListScreen(isArabic: widget.isArabic),
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
      case 'offices':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OfficesScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'gold_reservation':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                GoldReservationScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'shift_closing':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ShiftClosingScreen(api: api, isArabic: widget.isArabic),
          ),
        );
        break;
      case 'audit_log':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AuditLogScreen()),
        );
        break;
      case 'weight_closing_execute':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WeightClosingExecuteScreen()),
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
