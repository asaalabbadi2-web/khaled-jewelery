import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' as cu;
import '../providers/quick_actions_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/sales_race_refresh_provider.dart';
import '../models/quick_action_item.dart';
import '../widgets/gold_price_bar.dart';
import '../widgets/user_avatar_widget.dart';
import '../widgets/gold_price_ticker_bar.dart';
import '../widgets/gold_sparkline_enhanced.dart';
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
import 'scrap_purchase_invoice_screen.dart';
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
import 'reports/admin_dashboard_screen.dart';
import 'reports/gold_price_history_report_screen.dart';
import 'reports/gold_position_report_screen.dart';
import 'reports/reports_main_screen.dart';
import 'system_reset_screen.dart';
import 'printing_center_screen.dart';
import 'security_sessions_screen.dart';
import 'change_password_screen.dart';
import 'user_profile_screen.dart';
import 'sales_race_management_screen.dart';
import '../features/invoice/widgets/barcode_scanner_screen.dart';
import '../widgets/pending_approvals_dialog.dart';
import '../widgets/goal_achievement_celebration.dart';
import '../widgets/goal_progress_ring.dart';
import 'inventory_balance_screen.dart';
import 'inventory_audit_screen.dart';

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
    with RouteAware, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // الألوان من الثيم لا من قيم مكتوبة هنا (ثيم-٠): تتبع الوضعين.
  ColorScheme get _cs => Theme.of(context).colorScheme;
  AppSemanticColors get _tone => AppSemanticColors.of(context);

  /// لون ما يُكتب على الشريط العلوي: الذهب في الداكن، ولون النص على الذهب في الفاتح.
  Color get _onBar => Theme.of(context).brightness == Brightness.dark ? _cs.primary : _cs.onPrimary;

  /// ميدالية الترتيب: الذهب والفضة والبرونز.
  SemanticTone _medal(int index) => switch (index) { 0 => _tone.gold, 1 => _tone.silver, _ => _tone.bronze };

  final ApiService api = ApiService();

  // Sun pulse animation for empty leaderboard banner
  late final AnimationController _sunController;
  late final Animation<double> _sunScale;

  // Isolate LTR runs (dates/numbers) inside Arabic sentences to avoid
  // bidi reordering artifacts like swapped punctuation or digit shaping.
  String _ltrIsolate(String text) => '\u2066$text\u2069';

  // Data
  double? goldPrice;
  DateTime? goldPriceDate;
  double? goldPriceOpening;
  DateTime? goldPriceOpeningDate;
  List<SparklinePoint> _sparklinePoints = [];
  int _sparklineTickCounter = 0;
  List customers = [];
  List items = [];
  List safeBoxes = [];

  // Currency data
  double exchangeRate = 3.75; // سعر الصرف الافتراضي (دولار -> ريال سعودي)
  String currencySymbol = 'ر.س';
  int currencyDecimalPlaces = 2;
  int mainKarat = 21;

  // Gold display toggle: true = persistent bar under AppBar, false = scrolling ticker
  final bool _goldBarMode = true;

  bool _isGoldPriceUpdatingNow = false;

  Timer? _goldPriceAutoRefreshTimer;
  String _goldPriceAutoRefreshFingerprint = '';

  // Operations badge (invoice approvals)
  int _pendingApprovalsCount = 0;

  /// A silent scheduler (SCHED-004): its own chip, never mixed into the count
  /// of things awaiting a decision -- it is a fault to fix on the server.
  int _systemAlertsCount = 0;
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

  // Groups expanded in-place on the home screen quick-access panel
  final Set<QuickActionGroup> _expandedGroups = {};

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

  // 🎉 Achievement celebration
  Timer? _achievementCheckTimer;
  bool _isShowingAchievement = false;
  bool _isCheckingAchievements = false;
  final Set<int> _shownAchievementIds = {};

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _sunController.dispose();
    _goldPriceAutoRefreshTimer?.cancel();
    _goldPriceAutoRefreshTimer = null;

    _approvalsAutoRefreshTimer?.cancel();
    _approvalsAutoRefreshTimer = null;

    _achievementCheckTimer?.cancel();
    _achievementCheckTimer = null;
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

      // sparkline يتحدّث كل 15 دقيقة فقط
      _sparklineTickCounter++;
      if (_sparklineTickCounter >= 15) {
        _sparklineTickCounter = 0;
        await _loadSparklineData();
      }
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
    _sunController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _sunScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _sunController, curve: Curves.easeInOut),
    );
    _loadAllData();

    // Check for unseen achievements after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForAchievements();
      _startAchievementTimer();
    });
  }

  void _startAchievementTimer() {
    _achievementCheckTimer?.cancel();
    _achievementCheckTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        if (!mounted) return;
        _checkForAchievements();
      },
    );
  }

  void _startApprovalsTimer() {
    _approvalsAutoRefreshTimer?.cancel();
    _approvalsAutoRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) async {
        if (!mounted) return;
        final auth = context.read<AuthProvider>();
        if (!auth.isAuthenticated) return;
        await _loadPendingApprovalsCount();
      },
    );
  }

  // ── RouteAware: fires when a pushed screen pops back to here ──
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)! as PageRoute);
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbolText;
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
    // Refresh pending approvals badge whenever we return from any sub-screen.
    _loadPendingApprovalsCount();
    // بطاقة سباق الأداء: تحديث فوري عند كل عودة للشاشة الرئيسية.
    _loadLeaderboard(period: _leaderboardPeriod);
    // فحص الأهداف الشخصية — تأخير 600ms لإفساح المجال لـ animation الـ navigation
    // حتى لا تظهر الاحتفالية فوق ديالوج الشاشة السابقة.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _checkForAchievements();
    });
    // Collapse any expanded quick-action groups so the home screen
    // always opens in its compact default state after navigation.
    if (_expandedGroups.isNotEmpty) {
      setState(() => _expandedGroups.clear());
    }
  }

  // ── WidgetsBindingObserver: fires when app resumes from background ──
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // تعليق الـ animation والـ timers لتخفيف الحمل على المعالج
      _sunController.stop();
      _goldPriceAutoRefreshTimer?.cancel();
      _goldPriceAutoRefreshTimer = null;
      _goldPriceAutoRefreshFingerprint = '';
      _achievementCheckTimer?.cancel();
      _achievementCheckTimer = null;
      _approvalsAutoRefreshTimer?.cancel();
      _approvalsAutoRefreshTimer = null;
    } else if (state == AppLifecycleState.resumed) {
      // استئناف الـ animation والـ timers
      _sunController.repeat(reverse: true);
      final settings = context.read<SettingsProvider>();
      _syncGoldPriceAutoRefresh(settings);
      _startAchievementTimer();
      _startApprovalsTimer();
      // تحديث البيانات إذا مضى على آخر تحديث أكثر من دقيقتين
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
        if (!auth.hasPermission('customers.view')) customers = [];
        if (!auth.hasPermission('items.view')) items = [];
        if (!auth.hasPermission('safe_boxes.view')) safeBoxes = [];
      });

      // Phase 1: essential data that the home screen displays — show UI as soon as these finish.
      final essentialFutures = <Future<void>>[];
      if (auth.isAuthenticated) essentialFutures.add(_loadGoldPrice());
      if (auth.isAuthenticated) essentialFutures.add(_loadSparklineData());
      if (auth.isAuthenticated) essentialFutures.add(_loadPendingApprovalsCount(startTimer: true));
      if (auth.hasPermission('safe_boxes.view')) essentialFutures.add(_loadSafeBoxes());
      final quickActions = context.read<QuickActionsProvider>();
      if (auth.isAuthenticated && quickActions.showSalesRaceCard) {
        essentialFutures.add(_loadLeaderboard());
      }

      await Future.wait(essentialFutures);
    } catch (e) {
      debugPrint('❌ خطأ في تحميل البيانات الأساسية: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
      _checkPersonalGoalAchievements();
    }

    // Phase 2: background data (customers/items) used only when opening invoice screens.
    // Does not block the home screen UI.
    _loadBackgroundData();
  }

  Future<void> _loadBackgroundData() async {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated) return;

    final futures = <Future<void>>[];
    if (auth.hasPermission('customers.view')) futures.add(_loadCustomers());
    if (auth.hasPermission('items.view')) futures.add(_loadItems());

    await Future.wait(futures);
  }

  Future<void> _checkPersonalGoalAchievements() async {
    // يُحوَّل إلى _checkForAchievements لضمان مسار موحّد ومدار بشكل صحيح
    await _checkForAchievements();
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

  // ───────────────────────────────────────────────────
  // 🎉 Achievement celebration helpers
  // ───────────────────────────────────────────────────

  Future<void> _checkForAchievements() async {
    if (_isShowingAchievement || _isCheckingAchievements || !mounted) return;
    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated) return;

    _isCheckingAchievements = true;
    try {
      final freshlyAchieved = await api.checkGoalProgress();
      final unseen = await api.getUnseenAchievements();

      final seen = <int>{};
      final combined = <Map<String, dynamic>>[];
      for (final a in [...freshlyAchieved, ...unseen]) {
        final id = a['id'] as int?;
        if (id != null && !_shownAchievementIds.contains(id) && seen.add(id)) {
          combined.add(a);
        }
      }

      for (final data in combined) {
        if (!mounted) break;
        await _showAchievement(GoalAchievement.fromJson(data));
      }
    } catch (e) {
      debugPrint('❌ Achievement check failed: $e');
    } finally {
      _isCheckingAchievements = false;
    }
  }

  Future<void> _showAchievement(GoalAchievement achievement) async {
    if (!mounted) return;
    _isShowingAchievement = true;
    if (achievement.id != null) _shownAchievementIds.add(achievement.id!);

    try {
      await GoalAchievementOverlay.show(
        context,
        achievement: achievement,
        isArabic: widget.isArabic,
        onViewDetails: () {
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BonusManagementScreen(
                api: api,
                isArabic: widget.isArabic,
              ),
            ),
          );
        },
      );
    } finally {
      _isShowingAchievement = false;
      // Mark as seen regardless of how the dialog was dismissed (button, barrier tap, etc.)
      if (achievement.id != null) {
        api.markAchievementSeen(achievement.id!);
      }
    }
  }

  Future<void> _loadPendingApprovalsCount({bool startTimer = false}) async {
    try {
      final auth = context.read<AuthProvider>();
      if (!auth.isAuthenticated) return;

      final result = await api.getPendingActions();
      final count = ((result['total_pending_reservations'] as num?)?.toInt() ?? 0) +
          ((result['total_pending_invoices'] as num?)?.toInt() ?? 0);
      final systemCount = (result['total_system_alerts'] as num?)?.toInt() ?? 0;

      if (!mounted) return;
      setState(() {
        _pendingApprovalsCount = count;
        _systemAlertsCount = systemCount;
      });

      // يُنشأ الـ timer مرة واحدة فقط عند أول تحميل
      if (startTimer) _startApprovalsTimer();
    } catch (e) {
      debugPrint('⚠️ Failed to load approvals badge: $e');
    }
  }

  /// One chip in the app bar; every chip opens the pending-actions dialog.
  Widget _pendingChip({required bool isAr, required Widget leading, required String label}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => PendingApprovalsDialog.show(
          context: context,
          api: api,
          isArabic: isAr,
          onCountChanged: _loadPendingApprovalsCount,
        ),
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 12, 6),
          decoration: BoxDecoration(
            color: _tone.blocked.fg.withValues(alpha: 0.16),
            border: Border.all(color: _tone.blocked.fg.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: _tone.blocked.fg, shape: BoxShape.circle),
                child: Center(child: leading),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: _onBar.withValues(alpha: 0.9),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
            // Sent marked UTC ('Z', 2 Oct 2026): shown in the device's time.
            goldPriceDate = DateTime.parse(response['date']).toLocal();
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
            )?.toLocal();
          } else {
            goldPriceOpeningDate = goldPriceDate;
          }
        });
      }
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل سعر الذهب: $e');
    }
  }

  Future<void> _loadSparklineData() async {
    try {
      final auth = context.read<AuthProvider>();
      if (!auth.isAuthenticated) return;

      final raw = await api.getGoldPrice24h();
      if (!mounted) return;

      final points = <SparklinePoint>[];
      for (final row in raw) {
        final ts = row['timestamp']?.toString();
        final price = row['price_usd_per_oz'];
        if (ts == null || price == null) continue;
        // The server marks each time UTC ('Z'); no zone is guessed here.
        final time = DateTime.tryParse(ts)?.toLocal();
        final p = price is num
            ? price.toDouble()
            : double.tryParse(price.toString());
        if (time == null || p == null) continue;
        points.add(SparklinePoint(time: time, price: p));
      }

      setState(() => _sparklinePoints = points);
    } catch (e) {
      debugPrint('⚠️ خطأ في تحميل بيانات الـ Sparkline: $e');
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
        const TextStyle(fontFamily: 'Cairo', fontSize: 14);
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
    // ════════════════════════════════════════════════════════════════════════
    // 1. الفواتير
    // ════════════════════════════════════════════════════════════════════════
    addSection(isAr ? 'الفواتير' : 'Invoices', gold);
    addDestination(
      icon: Icons.point_of_sale,
      title: isAr ? 'فاتورة بيع' : 'Sales Invoice',
      color: _tone.sectionGreen.fg,
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
      title: isAr ? 'بيع ذهب كسر' : 'Scrap Gold Sale',
      color: _tone.sectionOrange.fg,
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
      color: _tone.sectionAmber.fg,
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
      title: isAr ? 'فاتورة شراء' : 'Purchase Invoice',
      color: _tone.sectionBlue.fg,
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
      title: isAr ? 'جميع الفواتير' : 'All Invoices',
      color: _tone.sectionSlate.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => InvoicesListScreen(isArabic: isAr)),
        );
      },
    );
    addDestination(
      icon: Icons.check_circle_outline,
      title: isAr ? 'اعتماد الترحيل' : 'Posting Management',
      color: _tone.sectionTeal.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PostingManagementScreen(isArabic: isAr),
          ),
        );
      },
    );

    // ════════════════════════════════════════════════════════════════════════
    // 2. المرتجعات
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'المرتجعات' : 'Returns', _tone.sectionRed.fg);
    addDestination(
      icon: Icons.keyboard_return,
      title: isAr ? 'مرتجع بيع' : 'Sales Return',
      color: _tone.sectionRed.fg,
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
      color: _tone.sectionRed.fg,
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
      title: isAr ? 'مرتجع شراء (مورد)' : 'Supplier Return',
      color: _tone.sectionRed.fg,
      onSelected: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AddReturnInvoiceScreen(api: api, returnType: 'مرتجع شراء (مورد)'),
          ),
        );
        if (result == true) await _loadAllData();
      },
    );

    // ════════════════════════════════════════════════════════════════════════
    // 3. العملاء والموردين
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'العملاء والموردين' : 'Customers & Suppliers', _tone.sectionBlue.fg);
    addDestination(
      icon: Icons.people,
      title: isAr ? 'قائمة العملاء' : 'Customers',
      color: _tone.sectionBlue.fg,
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
      title: isAr ? 'إضافة عميل' : 'Add Customer',
      color: _tone.sectionBlue.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AddCustomerScreen(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.store,
      title: isAr ? 'قائمة الموردين' : 'Suppliers',
      color: _tone.sectionPurple.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SuppliersScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );

    // ════════════════════════════════════════════════════════════════════════
    // 4. الأصناف
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'الأصناف' : 'Items', _tone.sectionOrange.fg);
    addDestination(
      icon: Icons.inventory_2,
      title: isAr ? 'قائمة الأصناف' : 'Items List',
      color: _tone.sectionOrange.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ItemsScreenEnhanced(api: api)),
        );
      },
    );
    addDestination(
      icon: Icons.add_box,
      title: isAr ? 'إضافة صنف' : 'Add Item',
      color: _tone.sectionOrange.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddItemScreenEnhanced(api: api),
          ),
        );
      },
    );
    addDestination(
      icon: Icons.autorenew,
      title: isAr ? 'التجديد والتكسير' : 'Melting & Renewal',
      color: _tone.sectionOrange.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                MeltingRenewalScreen(api: api, isArabic: isAr),
          ),
        );
      },
    );

    // ════════════════════════════════════════════════════════════════════════
    // 5. التسكير والذهب الخام
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(
      isAr ? 'التسكير والذهب الخام' : 'Gold & Closing',
      _cs.primary,
    );
    addDestination(
      icon: Icons.lock_clock,
      title: isAr ? 'حجز ذهب خام' : 'Gold Reservation',
      color: _cs.primary,
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
    addDestination(
      icon: Icons.business,
      title: isAr ? 'مكاتب التسكير' : 'Closing Offices',
      color: _tone.gold.fg,
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
      icon: Icons.scale,
      title: isAr ? 'تنفيذ التسكير الوزني' : 'Weight Closing',
      color: _cs.primary,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WeightClosingExecuteScreen()),
        );
      },
    );

    // ════════════════════════════════════════════════════════════════════════
    // 6. الموارد البشرية (حسب الصلاحيات)
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'الموارد البشرية' : 'Human Resources', _tone.sectionSlate.fg);
    if (auth.hasPermission('employees.view')) {
      addDestination(
        icon: Icons.badge,
        title: isAr ? 'الموظفين' : 'Employees',
        color: _tone.sectionSlate.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => EmployeesScreen(api: api)),
          );
        },
      );
    }
    if (auth.hasPermission('employees.bonuses')) {
      addDestination(
        icon: Icons.card_giftcard,
        title: isAr ? 'المكافآت' : 'Bonuses',
        color: _tone.sectionSlate.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  BonusManagementScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }
    if (auth.hasPermission('employees.payroll')) {
      addDestination(
        icon: Icons.payments_rounded,
        title: isAr ? 'الرواتب' : 'Payroll',
        color: _tone.sectionSlate.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PayrollScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }
    if (auth.hasPermission('employees.view')) {
      addDestination(
        icon: Icons.event_available,
        title: isAr ? 'الحضور والانصراف' : 'Attendance',
        color: _tone.sectionSlate.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  AttendanceScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }
    addDestination(
      icon: Icons.emoji_events_rounded,
      title: isAr ? 'سباق الأداء' : 'Sales Race',
      color: _cs.primary,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                SalesRaceManagementScreen(api: api, isArabic: isAr),
          ),
        );
        _loadLeaderboard(period: _leaderboardPeriod);
      },
    );
    if (auth.isSystemAdmin) {
      addDestination(
        icon: Icons.manage_accounts,
        title: isAr ? 'المستخدمين' : 'Users',
        color: _tone.sectionSlate.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => UsersScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. المحاسبة (حسب الصلاحيات)
    // ════════════════════════════════════════════════════════════════════════
    if (auth.hasPermission('accounts.view') ||
        auth.hasPermission('vouchers.view') ||
        auth.hasPermission('journal.view')) {
      addDivider();
      addSection(isAr ? 'المحاسبة' : 'Accounting', gold);
    }
    if (auth.hasPermission('vouchers.view')) {
      addDestination(
        icon: Icons.receipt_long,
        title: isAr ? 'السندات' : 'Vouchers',
        color: _tone.sectionCyan.fg,
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
        color: _tone.sectionGreen.fg,
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
        color: _tone.sectionRed.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddVoucherScreen(voucherType: 'payment'),
            ),
          );
        },
      );
    }
    if (auth.hasPermission('accounts.view')) {
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
    }
    if (auth.hasPermission('journal.view')) {
      addDestination(
        icon: Icons.book,
        title: isAr ? 'قيود اليومية' : 'Journal Entries',
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  JournalEntriesListScreen(isArabic: isAr),
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
            MaterialPageRoute(
              builder: (_) => AddEditJournalEntryScreen(),
            ),
          );
        },
      );
      addDestination(
        icon: Icons.repeat,
        title: isAr ? 'القيود الدورية' : 'Recurring Entries',
        color: _tone.sectionPurple.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  RecurringTemplatesScreen(isArabic: isAr),
            ),
          );
        },
      );
    }
    if (auth.hasPermission('accounts.view')) {
      addDestination(
        icon: Icons.menu_book,
        title: isAr ? 'دفتر الأستاذ العام' : 'General Ledger',
        color: _tone.sectionAmber.fg,
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
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. التقارير
    // ════════════════════════════════════════════════════════════════════════
    if (_holdsAnyReport(auth)) {
      addDivider();
      addSection(isAr ? 'التقارير' : 'Reports', _tone.sectionIndigo.fg);
      addDestination(
        icon: Icons.insights,
        title: isAr ? 'مركز التقارير' : 'Reports Center',
        color: _tone.sectionIndigo.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  ReportsMainScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
      addDestination(
        icon: Icons.auto_graph,
        title: isAr ? 'سعر الذهب - تاريخي' : 'Gold Price History',
        color: _tone.sectionAmber.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GoldPriceHistoryReportScreen(
                api: api,
                isArabic: isAr,
              ),
            ),
          );
        },
      );
      if (auth.hasPermission('employees.payroll')) {
        addDestination(
          icon: Icons.analytics,
          title: isAr ? 'تقارير الرواتب' : 'Payroll Reports',
          color: _tone.sectionSlate.fg,
          onSelected: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PayrollReportScreen(api: api),
              ),
            );
          },
        );
      }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 9. الجرد الفعلي
    // ════════════════════════════════════════════════════════════════════════
    if (auth.hasPermission('inventory.view')) {
      addDivider();
      addSection(isAr ? 'الجرد الفعلي' : 'Inventory', _tone.sectionTeal.fg);
      addDestination(
        icon: Icons.scale_outlined,
        title: isAr ? 'أرصدة الجرد' : 'Inventory Balance',
        color: _tone.sectionTeal.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const InventoryBalanceScreen()),
          );
        },
      );
      if (auth.hasPermission('inventory.approve')) {
        addDestination(
          icon: Icons.fact_check_outlined,
          title: isAr ? 'مركز التدقيق' : 'Audit Center',
          color: _tone.sectionTeal.fg,
          onSelected: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const InventoryAuditScreen()),
            );
          },
        );
      }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 10. الأدوات التشغيلية
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'الأدوات' : 'Tools', _tone.sectionTeal.fg);
    // The safes' balances and the shift closing are not the seller's: they
    // hold safe_boxes.view only to pick a safe in an invoice (ADR-036).
    if (auth.hasPermission('safe_boxes.transfer')) {
      addDestination(
        icon: Icons.savings,
        title: isAr ? 'إدارة الخزائن' : 'Safe Boxes',
        color: _tone.sectionAmber.fg,
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
    }
    if (auth.hasPermission('safe_boxes.edit')) {
      addDestination(
        icon: Icons.fact_check,
        title: isAr ? 'إغلاق اليومية' : 'Shift Closing',
        color: _tone.sectionTeal.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  ShiftClosingScreen(api: api, isArabic: isAr),
            ),
          );
        },
      );
    }
    if (auth.isManager) {
      addDestination(
        icon: Icons.swap_horiz,
        title: isAr ? 'تسوية المقاصة' : 'Clearing Settlement',
        color: _tone.sectionTeal.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ClearingMonitorScreen()),
          );
          await _loadAllData();
        },
      );
    }
    // Payment methods: the accountant sets them up, the manager sees them (ADR-036).
    if (auth.isManager || auth.hasPermission('business.setup')) {
      addDestination(
        icon: Icons.credit_card,
        title: isAr ? 'وسائل الدفع' : 'Payment Methods',
        color: _tone.sectionAmber.fg,
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
    }
    addDestination(
      icon: Icons.print,
      title: isAr ? 'مركز الطباعة' : 'Printing Center',
      color: _tone.sectionPurple.fg,
      onSelected: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PrintingCenterScreen(isArabic: isAr),
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
              backgroundColor: _tone.warning.fg,
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

    // ════════════════════════════════════════════════════════════════════════
    // 10. الإعدادات والنظام (مدير فأعلى)
    // ════════════════════════════════════════════════════════════════════════
    addDivider();
    addSection(isAr ? 'الإعدادات والنظام' : 'Settings & System', theme.hintColor);
    if (auth.isManager) {
      addDestination(
        icon: Icons.domain,
        title: isAr ? 'إدارة الفروع' : 'Branches',
        color: _tone.sectionAmber.fg,
        onSelected: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  BranchesManagementScreen(isArabic: isAr),
            ),
          );
        },
      );
    }
    if (auth.isManager) {
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
      addDestination(
        icon: Icons.print,
        title: isAr ? 'إعدادات الطابعة' : 'Printer Settings',
        color: _tone.sectionPurple.fg,
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
    }
    if (auth.isSystemAdmin) {
      addDestination(
        icon: Icons.upload_file,
        title: isAr ? 'استيراد Excel' : 'Import Excel',
        color: _tone.sectionGreen.fg,
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
      addDestination(
        icon: Icons.restore,
        title: isAr ? 'إعادة تهيئة النظام' : 'System Reset',
        color: _tone.sectionRed.fg,
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
    }
    addDestination(
      icon: Icons.info_outline,
      title: isAr ? 'حول التطبيق' : 'About',
      color: _tone.sectionTeal.fg,
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
        drawer: _buildDrawer(isAr, _cs.primary),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: 56,
          elevation: 0,
          shadowColor: _cs.shadow.withValues(alpha: 0.14),
          surfaceTintColor: Colors.transparent,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? _cs.surfaceContainerHigh
              : _tone.gold.fg,
          foregroundColor: _onBar,
          leadingWidth: 52,
          leading: Builder(
            builder: (context) => IconButton(
              tooltip: isAr ? 'القائمة' : 'Menu',
              icon: const Icon(Icons.menu_rounded, size: 24),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              AppLogo.matchTextColor(
                _onBar,
                width: 32,
                height: 32,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isAr ? 'مجوهرات خالد' : 'Khaled Jewelery',
                  style: TextStyle(
                    color: _onBar,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Cairo',
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            if (_systemAlertsCount > 0)
              _pendingChip(
                isAr: isAr,
                leading: Icon(Icons.power_off_rounded, size: 18, color: _onBar),
                label: isAr ? 'المجدول متوقف' : 'Scheduler down',
              ),
            if (_pendingApprovalsCount > 0)
              _pendingChip(
                isAr: isAr,
                leading: Text(
                  '$_pendingApprovalsCount',
                  style: TextStyle(
                    color: _onBar,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'Cairo',
                  ),
                ),
                label: isAr ? 'بانتظار الإجراء' : 'Pending Actions',
              ),
            IconButton(
              icon: Icon(
                Provider.of<ThemeProvider>(context).isDarkMode
                    ? Icons.light_mode
                    : Icons.dark_mode,
              ),
              tooltip: isAr ? 'تبديل الوضع' : 'Toggle Theme',
              onPressed: () => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
            ),
            IconButton(
              icon: const Icon(Icons.language),
              tooltip: isAr ? 'English' : 'العربية',
              onPressed: widget.onToggleLocale,
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner_outlined),
              tooltip: isAr ? 'قارئ الباركود' : 'Barcode Scanner',
              onPressed: () => _handleQuickActionTap('barcode_scan'),
            ),
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                // يفضل الاسم الكامل على اسم المستخدم للعرض
                final fullName = auth.fullName;
                final username = auth.username;
                final displayName = fullName.isNotEmpty
                    ? fullName
                    : (username.isNotEmpty
                        ? username
                        : (isAr ? 'حساب المستخدم' : 'Account'));
                final isDark = Theme.of(context).brightness == Brightness.dark;
                final photoBase64 = auth.userPhoto;

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 4),
                    // ─── الأفاتار: مستقل تماماً عن الـ PopupMenuButton ───
                    SizedBox(
                      height: kToolbarHeight,
                      child: Center(
                        child: UserAvatarWidget(
                          displayName: displayName,
                          photoBase64: photoBase64,
                          radius: 16,
                          backgroundColor: _onBar,
                          foregroundColor: isDark ? _cs.onPrimary : _tone.gold.fg,
                          editable: true,
                          onUpload: (base64) => auth.updateUserPhoto(api, base64),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // ─── الـ PopupMenuButton: يحتوي فقط على الاسم ───
                    PopupMenuButton<String>(
                  tooltip: '',
                  offset: const Offset(0, 48),
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // اسم العرض (الاسم الكامل) + اسم المستخدم أصغر
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _onBar,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                                if (username.isNotEmpty && username != displayName)
                                  Text(
                                    '@$username',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: _onBar.withValues(alpha: 0.65),
                                      fontSize: 10,
                                      fontFamily: 'Cairo',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_drop_down,
                            color: _onBar.withValues(alpha: 0.7),
                            size: 18,
                          ),
                          const SizedBox(width: 4),
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
                          Icon(Icons.person_outline, size: 18, color: Theme.of(context).colorScheme.onSurface),
                          const SizedBox(width: 8),
                          Text(isAr ? 'ملف المستخدم' : 'User Profile'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'password',
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 18, color: Theme.of(context).colorScheme.onSurface),
                          const SizedBox(width: 8),
                          Text(isAr ? 'تغيير كلمة المرور' : 'Change Password'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'sessions',
                      child: Row(
                        children: [
                          Icon(Icons.security, size: 18, color: Theme.of(context).colorScheme.onSurface),
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
                            Icon(Icons.group, size: 18, color: Theme.of(context).colorScheme.onSurface),
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
                          Icon(Icons.logout, size: 18, color: Theme.of(context).colorScheme.error),
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
                            backgroundColor: _tone.warning.fg,
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
                ),   // PopupMenuButton
                  ],  // Row children
                );    // Row
              },
            ),
          ],
        ),
        body: isLoading
            ? Center(
                child: CircularProgressIndicator(
                  color: _cs.primary,
                  strokeWidth: 3,
                ),
              )
            : _buildSelectedTabContent(isAr),
        bottomNavigationBar: _buildBottomNavigationBar(
          isAr,
          _cs.primary,
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar(bool isAr, Color gold) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? _cs.surfaceContainerLow : _cs.surfaceContainerLowest;
    final items = _getBottomNavItems(isAr);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        boxShadow: [
          BoxShadow(
            color: _cs.shadow.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(items.length, (i) {
              final selected = i == _selectedNavIndex;
              final item = items[i];
              return Expanded(
                child: InkWell(
                  onTap: () => _onBottomNavTap(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // مؤشر علوي للعنصر المختار
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 3,
                        width: selected ? 28 : 0,
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: _cs.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      IconTheme(
                        data: IconThemeData(
                          color: selected
                              ? _cs.primary
                              : theme.unselectedWidgetColor,
                          size: 22,
                        ),
                        child: item.icon,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label ?? '',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: selected
                              ? _cs.primary
                              : theme.unselectedWidgetColor,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
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
        tab = InvoicesListScreen(isArabic: isAr, embedded: true);
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
            sparklinePoints: _sparklinePoints,
            isArabic: widget.isArabic,
            onSparklineTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GoldPriceHistoryReportScreen(
                    api: api,
                    isArabic: widget.isArabic,
                  ),
                ),
              );
            },
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
            color: _cs.primary,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),

                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isWide = constraints.maxWidth >= 900;

                        if (isWide && showSalesRaceCard) {
                          // Source HTML layout in RTL:
                          // first child renders on the right => Sales Race on right, Quick Access on left.
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 9, child: _buildLeaderboardCard(isAr)),
                              const SizedBox(width: 20),
                              Expanded(flex: 11, child: _buildQuickActions()),
                            ],
                          );
                        }

                        // Source responsive layout: quick access above race panel.
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildQuickActions(),
                            if (showSalesRaceCard) ...[
                              const SizedBox(height: 16),
                              _buildLeaderboardCard(isAr),
                            ],
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
    final showChampion = config?['show_champion'] != false;
    final showAmounts = config?['amounts_visible'] as bool? ?? true;
    final showPoints = config?['points_visible'] as bool? ?? true;
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
    final isGoalAchieved = effectiveTargetProgress >= 0.9999;
    final Color goalColor = isGoalAchieved
        ? _tone.ready.fg
      : (effectiveTargetProgress < 0.5 ? _tone.warning.fg : _tone.info.fg);
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

    // Current user position for "me card"
    final meEmpId = context.read<AuthProvider>().currentUser?.employeeId;
    final meIsInTop = meEmpId != null &&
        topRanking.any((r) => (r['id'] as num?)?.toInt() == meEmpId);
    final meRankIndex = meEmpId == null
        ? -1
        : allRanking.indexWhere((r) => (r['id'] as num?)?.toInt() == meEmpId);

    String rankRoleLabel(int index) {
      if (index == 0) return isAr ? 'المتصدر' : 'Leader';
      if (index == 1) return isAr ? 'الثاني' : 'Second';
      if (index == 2) return isAr ? 'الثالث' : 'Third';
      return isAr ? 'مشارك' : 'Ranked';
    }

    Widget buildRow(Map row, int index) {
      final name = (row['name'] ?? '').toString();
      final photo = row['photo'] as String?;
      final score = (row['score'] as num?)?.toDouble() ?? 0.0;
      final share = (row['share'] as num?)?.toDouble() ?? 0.0;
      final count = (row['count'] as num?)?.toInt() ?? 0;
      final salesAmount = (row['sales_amount'] as num?)?.toDouble() ?? 0.0;
      final purchaseAmount = (row['purchase_amount'] as num?)?.toDouble() ?? 0.0;
      final pointsSales = (row['points_sales'] as num?)?.toInt() ?? 0;
      final pointsPurchase = (row['points_purchase'] as num?)?.toInt() ?? 0;
      // تقدم الهدف الشخصي للموظف (null = لم يُضبط هدف)
      final goalProgress = (row['goal_progress'] as num?)?.toDouble();

      final isLeader = index == 0;
      final valueColor = isLeader ? colorScheme.primary : colorScheme.secondary;
      final progressColor = switch (index) {
        1 => _tone.silver.fg,
        2 => _tone.bronze.fg,
        _ => valueColor,
      };
      final medalAccent = switch (index) {
        0 => _cs.primary,
        1 => _tone.silver.fg,
        2 => _tone.bronze.fg,
        _ => valueColor,
      };
      final roleBadgeColor = index == 0
          ? _tone.gold.fg
          : colorScheme.onSurface.withValues(alpha: 0.62);
      final invoiceLabelEn = count == 1 ? 'invoice' : 'invoices';
      final invoiceLabelAr = count == 1 ? 'فاتورة بيع' : 'فواتير بيع';
      final invoiceLabelPointsAr = count == 1 ? 'فاتورة' : 'فواتير';
      final invoiceSummary = showInvoiceCount
          ? (metric == 'points'
            ? (isAr ? '$count $invoiceLabelPointsAr' : '$count transactions')
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
      final numberFormat = NumberFormat('#,##0', 'en');
      final pointsUnitAr = isAr ? 'نقطة' : 'pts';
      final currencySymbolText = context.read<SettingsProvider>().currencySymbolText;
      final isNewSar = context.read<SettingsProvider>().currencyIsNewSar;

      bool hovered = false;
      return StatefulBuilder(
        builder: (context, setHover) {
          return Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 8),
        child: MouseRegion(
          onEnter: (_) => setHover(() => hovered = true),
          onExit: (_) => setHover(() => hovered = false),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            scale: hovered ? 1.015 : 1.0,
            child: AnimatedContainer(
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, hovered ? -2.0 : 0, 0),
            decoration: BoxDecoration(
              color: hovered
                  ? (index == 0
                      ? (isDark ? colorScheme.surfaceContainerHigh : Color.alphaBlend(_tone.gold.container.withValues(alpha: 0.30), _cs.surfaceContainerLowest))
                      : (isDark ? colorScheme.surfaceContainerHigh : _cs.surfaceContainerLowest))
                  : (isDark
                      ? colorScheme.surfaceContainerHigh
                      : (index == 0 ? Color.alphaBlend(_tone.gold.container.withValues(alpha: 0.30), _cs.surfaceContainerLowest) : _cs.surfaceContainerLowest)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: hovered
                    ? _cs.primary.withValues(alpha: 0.42)
                    : (index == 0
                        ? _cs.primary.withValues(alpha: 0.22)
                        : index == 1
                            ? _tone.silver.fg.withValues(alpha: 0.20)
                            : index == 2
                                ? _tone.bronze.fg.withValues(alpha: 0.18)
                                : colorScheme.onSurface.withValues(alpha: 0.07)),
                width: hovered ? 1.2 : (index == 0 ? 1.1 : 1.0),
              ),
              boxShadow: hovered
                  ? [
                      BoxShadow(
                        color: _cs.primary.withValues(alpha: 0.11),
                        blurRadius: 14,
                        spreadRadius: 0,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: _cs.shadow.withValues(alpha: isDark ? 0.13 : 0.07),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : (index == 0
                      ? [BoxShadow(color: _cs.primary.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3))]
                      : null),
            ),
            child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Medal rank badge with crown for rank 1
                _buildRankBadge(index, medalAccent),
                const SizedBox(width: 8),
                // Avatar + حلقة تقدم الهدف الشخصي
                GoalProgressRing(
                  progress: goalProgress,
                  avatarRadius: 19,
                  strokeWidth: 3.0,
                  child: EmployeeAvatarWidget(
                    name: name,
                    photoBase64: photo,
                    radius: 19,
                  ),
                ),
                const SizedBox(width: 10),
                // Employee info
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
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: colorScheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: roleBadgeColor.withValues(alpha: 0.09),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              rankRoleLabel(index),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontWeight: FontWeight.w700,
                                fontSize: 10,
                                color: roleBadgeColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _buildStatChip(
                            icon: Icons.receipt_long_rounded,
                            value: invoiceSummary,
                            label: '',
                            valueColor: colorScheme.onSurface.withValues(alpha: 0.55),
                          ),
                          _buildCategoryChip(
                            dotColor: _tone.ready.fg,
                            valueColor: _tone.ready.fg,
                            label: isAr ? 'مبيعات' : 'Sales',
                            amount: showAmounts ? salesAmount : null,
                            points: showPoints && metric == 'points' ? pointsSales : null,
                            pointsUnit: pointsUnitAr,
                            currencySymbolText: currencySymbolText,
                            isNewSar: isNewSar,
                            numberFormat: numberFormat,
                          ),
                          _buildCategoryChip(
                            dotColor: _tone.invoicePurchase.fg,
                            valueColor: _tone.invoicePurchase.fg,
                            label: isAr ? 'مشتريات' : 'Purch',
                            amount: showAmounts ? purchaseAmount : null,
                            points: showPoints && metric == 'points' ? pointsPurchase : null,
                            pointsUnit: pointsUnitAr,
                            currencySymbolText: currencySymbolText,
                            isNewSar: isNewSar,
                            numberFormat: numberFormat,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          height: 4,
                          color: colorScheme.onSurface.withValues(alpha: 0.07),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                                begin: 0, end: share.clamp(0.0, 1.0)),
                            duration:
                                Duration(milliseconds: 600 + (index * 100)),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) =>
                                FractionallySizedBox(
                              alignment: AlignmentDirectional.centerStart,
                              widthFactor: value,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: AlignmentDirectional.centerStart,
                                    end: AlignmentDirectional.centerEnd,
                                    colors: [
                                      progressColor.withValues(alpha: 0.65),
                                      medalAccent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showPoints || metric != 'points') ...[
                const SizedBox(width: 10),
                // Score box
                Container(
                  constraints: const BoxConstraints(minWidth: 52),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: index == 0
                        ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              _cs.primary.withValues(alpha: 0.18),
                              _cs.primary.withValues(alpha: 0.07),
                            ],
                          )
                        : null,
                    color: index != 0 ? medalAccent.withValues(alpha: 0.07) : null,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: index == 0
                          ? _cs.primary.withValues(alpha: 0.30)
                          : medalAccent.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        scoreValueText,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w900,
                          fontSize: index == 0 ? 22 : 18,
                          color: index == 0 ? _tone.gold.fg : medalAccent,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        scoreUnitText,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9,
                          color: colorScheme.onSurface.withValues(alpha: 0.44),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                ],
              ],
            ),
          ),
        ),
        ),
        ),
        );
        },
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
                    _cs.primary.withValues(alpha: 0.18),
                    _tone.gold.container.withValues(alpha: 0.10),
                    isDark
                        ? _cs.shadow.withValues(alpha: 0.15)
                        : _cs.surfaceContainerLowest.withValues(alpha: 0.60),
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
                              _cs.primary.withValues(alpha: 0.22),
                              _tone.gold.fg.withValues(alpha: 0.10),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _cs.primary.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Icon(
                          Icons.emoji_events_rounded,
                          color: _tone.gold.fg,
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
                                color: _tone.gold.fg,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            if (showChampion &&
                                championName.isNotEmpty &&
                                topRanking.isNotEmpty &&
                                !isFallback) ...[
                              Row(
                                children: [
                                  Icon(
                                    Icons.star_rounded,
                                    size: 14,
                                    color: _cs.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      isAr
                                          ? 'المتصدر الآن: $championName'
                                          : 'Current leader: $championName',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: _tone.gold.fg,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
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
                                _checkForAchievements();
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
            // ── إذا لم يكن هناك بيانات للفترة الحالية: اعرض البانر فقط ──
            if (isFallback) ...[
              _buildNewDayBanner(isAr, isMonth, isWeek),
            ] else ...[
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
                      color: _tone.gold.container.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _cs.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Text(
                      metricPillText,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _tone.gold.fg,
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
                            : _cs.surfaceContainerLowest,
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
                      // ── عنوان + نسبة الإنجاز ──
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isAr
                                  ? (isMonth ? 'هدف الفريق الشهري' : 'هدف الفريق الأسبوعي')
                                  : (isMonth ? 'Monthly Team Goal' : 'Weekly Team Goal'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: goalColor,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: goalColor.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: goalColor.withValues(alpha: 0.18)),
                            ),
                            child: Text(
                              goalPercentText,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: goalColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // ── المحقق / الهدف / المتبقي في سطر واحد ──
                      Row(
                        children: [
                          Text(
                            goalCurrentText,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: goalColor,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '  /  ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface.withValues(alpha: 0.35),
                            ),
                          ),
                          Text(
                            goalTargetText,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: _cs.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!isGoalAchieved && goalRemainingText != null) ...[
                            const Spacer(),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.timelapse_rounded, size: 13, color: _tone.warning.fg),
                                const SizedBox(width: 4),
                                Text(
                                  goalRemainingText,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: _tone.warning.fg,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      // ── شريط التقدم ──
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: effectiveTargetProgress),
                          duration: const Duration(milliseconds: 700),
                          builder: (context, value, child) => LinearProgressIndicator(
                            value: value,
                            minHeight: 6,
                            backgroundColor: colorScheme.onSurface.withValues(alpha: 0.08),
                            valueColor: AlwaysStoppedAnimation<Color>(goalColor),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (allRanking.isEmpty || (isFallback && !isWeek && !isMonth))
                _buildNewDayBanner(isAr, isMonth, isWeek)
              else ...[              
                // ───────── Me card (only when user not in top 3) ─────────
                if (meEmpId != null && !meIsInTop) ...[
                  () {
                    final meRow = allRanking.firstWhere(
                      (r) => (r['id'] as num?)?.toInt() == meEmpId,
                      orElse: () => const {},
                    );
                    final meScore = (meRow['score'] as num?)?.toDouble() ?? 0.0;
                    final meScoreText = switch (metric) {
                      'count' => (meRow['count'] as num?)?.toInt().toString() ?? '0',
                      'points' => meScore.toStringAsFixed(0),
                      _ => meScore.toStringAsFixed(1),
                    };
                    final meScoreUnit = switch (metric) {
                      'count' => isAr ? 'فاتورة' : 'Invoice',
                      'points' => isAr ? 'نقطة' : 'pts',
                      _ => isAr ? 'جم' : 'g',
                    };
                    final auth = context.read<AuthProvider>();
                    final meFullName = auth.fullName.trim();
                    final meAvatarText = meFullName.isEmpty
                        ? '?'
                        : meFullName
                              .split(RegExp(r'\s+'))
                              .where((p) => p.isNotEmpty)
                              .take(2)
                              .map((p) => p.characters.first)
                              .join();
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: isDark
                              ? _tone.info.container
                              : _tone.info.fg.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _tone.info.fg.withValues(alpha: 0.28),
                            strokeAlign: BorderSide.strokeAlignInside,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Avatar + حلقة تقدم الهدف (أنا)
                            GoalProgressRing(
                              progress: (meRow['goal_progress'] as num?)?.toDouble(),
                              avatarRadius: 21,
                              strokeWidth: 3.2,
                              child: Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: _tone.info.fg.withValues(alpha: 0.13),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: _tone.info.fg.withValues(alpha: 0.28)),
                                ),
                                child: Center(
                                  child: Text(
                                    meAvatarText,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      color: _tone.info.fg,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Info column (middle)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isAr ? 'أنت الآن' : 'Your Position',
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 11,
                                      color: _tone.info.fg,
                                    ),
                                  ),
                                  Text(
                                    meFullName.isEmpty ? (isAr ? 'مستخدم' : 'User') : meFullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    meRankIndex >= 0
                                        ? (isAr ? 'المركز: #${meRankIndex + 1}' : 'Rank: #${meRankIndex + 1}')
                                        : (isAr ? 'خارج الترتيب • ابدأ بتسجيل أول فاتورة' : 'Outside ranking • Record first invoice'),
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 10.5,
                                      color: _tone.info.fg.withValues(alpha: 0.60),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Score box (RTL: shows on LEFT)
                            Container(
                              constraints: const BoxConstraints(minWidth: 48),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: _tone.info.fg.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _tone.info.fg.withValues(alpha: 0.22)),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    meScoreText,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontWeight: FontWeight.w900,
                                      fontSize: 20,
                                      color: _tone.info.fg,
                                      height: 1.1,
                                    ),
                                  ),
                                  Text(
                                    meScoreUnit,
                                    style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 9,
                                      color: _tone.info.fg.withValues(alpha: 0.55),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }(),
                  const SizedBox(height: 4),
                ],
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
                    padding: const EdgeInsetsDirectional.only(top: 6, bottom: 2),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        setState(() {
                          _showAllLeaderboardEmployees =
                              !_showAllLeaderboardEmployees;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _cs.primary.withValues(
                            alpha: _showAllLeaderboardEmployees ? 0.10 : 0.05,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _cs.primary.withValues(alpha: 0.18),
                          ),
                        ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedRotation(
                                duration: const Duration(milliseconds: 220),
                                turns: _showAllLeaderboardEmployees ? 0.5 : 0,
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: _tone.gold.fg,
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
                                    color: _tone.gold.fg,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ),
                    ),
                  ),
                ],
            ],
            if (raceEnabled &&
                adminSummary != null &&
                !(isFallback && !isWeek && !isMonth) &&
                ((adminSummary['total_sales_amount'] != null) ||
                    (adminSummary['total_purchase_amount'] != null) ||
                    (adminSummary['total_points'] != null))) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  if (adminSummary['total_sales_amount'] != null) ...[
                    Expanded(
                      child: _buildSummaryTileWithBorder(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.north_rounded,
                        label: isAr ? 'مبلغ المبيعات' : 'Sales',
                        value:
                            '${NumberFormat('#,##0', 'en').format(
                              ((adminSummary['total_sales_amount'] as num?) ?? 0).round(),
                            )} ${context.read<SettingsProvider>().currencySymbolText}',
                        accent: _tone.ready.fg,
                        borderBottomColor: _tone.ready.fg,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (adminSummary['total_purchase_amount'] != null) ...[
                    Expanded(
                      child: _buildSummaryTileWithBorder(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.south_rounded,
                        label: isAr ? 'إجمالي المشتريات' : 'Purchases',
                        value:
                            '${NumberFormat('#,##0', 'en').format(
                              ((adminSummary['total_purchase_amount'] as num?) ?? 0).round(),
                            )} ${context.read<SettingsProvider>().currencySymbolText}',
                        accent: _tone.invoicePurchase.fg,
                        borderBottomColor: _tone.invoicePurchase.fg,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (adminSummary['total_points'] != null)
                    Expanded(
                      child: _buildSummaryTileWithBorder(
                        theme: theme,
                        colorScheme: colorScheme,
                        icon: Icons.grade_rounded,
                        label: isAr ? 'إجمالي النقاط' : 'Points',
                        value: isAr
                            ? '${adminSummary['total_points']} نقطة'
                            : '${adminSummary['total_points']} pts',
                        accent: _tone.gold.fg,
                        borderBottomColor: _cs.primary,
                      ),
                    ),
                ],
              ),
            ],
            ], // end else (not today-fallback)
                ],
              ),
            ),
          ],
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
          return _cs.onPrimary;
        }
        return colorScheme.onSurface.withValues(alpha: 0.68);
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _cs.primary;
        }
        return _cs.surfaceContainerHighest;
      }),
      overlayColor: WidgetStateProperty.all(
        _cs.primary.withValues(alpha: 0.08),
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
      currencySymbol: settings.currencySymbolText,
      exchangeRate: exchangeRate,
      refreshInterval: settings.goldPriceTickerRefreshInterval,
    );
  }

  Widget _buildGlassCard({required Widget child, VoidCallback? onTap}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isDark ? theme.colorScheme.surfaceContainer : _cs.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _cs.shadow.withValues(alpha: isDark ? 0.18 : 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  /// PATCH 2: بانر "يوم جديد" بتصميم نظيف — حد أيمن فقط + dark mode
  Widget _buildNewDayBanner(bool isAr, bool isMonth, bool isWeek) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = isAr
        ? (isMonth ? 'شهر جديد بدأ' : isWeek ? 'أسبوع جديد بدأ' : 'يوم جديد بدأ')
        : (isMonth ? 'New Month Begins' : isWeek ? 'New Week Begins' : 'New Day Begins');
    final description = isAr
        ? (isMonth
            ? ' — ستظهر النتائج بمجرد تسجيل أول فاتورة هذا الشهر.'
            : isWeek
                ? ' — ستظهر النتائج بمجرد تسجيل أول فاتورة هذا الأسبوع.'
                : ' — ستظهر النتائج بمجرد تسجيل أول فاتورة اليوم.')
        : (isMonth
            ? ' — Results appear after the first invoice this month.'
            : isWeek
                ? ' — Results appear after the first invoice this week.'
                : ' — Results appear after recording the first invoice today.');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _cs.primary.withValues(alpha: 0.10),
            _cs.primary.withValues(alpha: 0.03),
          ],
          begin: AlignmentDirectional.centerEnd,
          end: AlignmentDirectional.centerStart,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(8),
          bottomLeft: Radius.circular(8),
        ),
        border: BorderDirectional(
          end: BorderSide(color: _cs.primary, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _sunScale,
            builder: (context, child) => Transform.scale(
              scale: _sunScale.value,
              child: child,
            ),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_tone.gold.container, _cs.primary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _cs.primary.withValues(alpha: 0.40),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Icon(Icons.wb_sunny_rounded, color: _cs.onPrimary, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'Cairo',
                  height: 1.5,
                  color: _cs.onSurface,
                ),
                children: [
                  TextSpan(
                    text: title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: isDark ? _cs.primary : _tone.gold.fg,
                    ),
                  ),
                  TextSpan(text: description),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// PATCH 4: شارة الترتيب — 50×50 مع تاج للمتصدر
  Widget _buildRankBadge(int index, Color medalAccent) {
    final medal = _medal(index);
    final gradientColors = index < 3
        ? [medal.fg, Color.lerp(medal.fg, medal.onContainer, 0.5)!]
        : [medalAccent.withValues(alpha: 0.18), medalAccent.withValues(alpha: 0.08)];
    final shadowColor = index < 3 ? medal.fg : medalAccent;

    final Widget badge = CustomPaint(
      painter: _RankBadgeNotchPainter(
        gradientColors: gradientColors,
        shadowColor: index < 3 ? shadowColor : Colors.transparent,
        notchRadius: 0,
      ),
      child: SizedBox(
        width: 54,
        height: 54,
        child: Align(
          alignment: Alignment.center,
          child: Text(
            '${index + 1}',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w900,
              fontSize: 20,
              color: index < 3 ? _cs.onPrimary : medalAccent,
              shadows: index < 3
                  ? [Shadow(color: _cs.shadow.withValues(alpha: 0.45), blurRadius: 5)]
                  : null,
            ),
          ),
        ),
      ),
    );

    if (index != 0) return badge;

    // Rank-1: التاج يطفو فوق الـ badge بدون إضافة ارتفاع للبطاقة.
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        badge,
        Positioned(
          top: -26,
          child: Text(
            '👑',
            style: TextStyle(
              fontSize: 26,
              height: 1.0,
              shadows: [
                Shadow(color: _cs.shadow.withValues(alpha: 0.38), blurRadius: 5, offset: const Offset(0, 3)),
                Shadow(color: _tone.gold.fg, blurRadius: 20),
                Shadow(color: _tone.gold.container, blurRadius: 10),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// PATCH 5: stat chip — dot/icon + value + label
  Widget _buildStatChip({
    IconData? icon,
    Color? dotColor,
    required String value,
    required String label,
    required Color valueColor,
  }) {
    final isNewSar = context.read<SettingsProvider>().currencyIsNewSar;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 3),
            child: Icon(icon, size: 12, color: valueColor),
          )
        else if (dotColor != null)
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsetsDirectional.only(end: 3),
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 11.5, fontFamily: 'Cairo'),
            children: [
              ...cu.sarAwareSpans(
                value,
                isNewSar: isNewSar,
                style: TextStyle(fontWeight: FontWeight.w800, color: valueColor),
              ),
              if (label.isNotEmpty)
                TextSpan(
                  text: ' $label',
                  style: TextStyle(color: _cs.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Sales/purchase stat chip — label first ("مبيعات: "), then points in a
  /// color unified across both chips (not the category color, so the points
  /// figure is recognizable at a glance regardless of sales vs purchase),
  /// then the amount with its currency symbol rendered a notch smaller than
  /// the amount digits themselves.
  Widget _buildCategoryChip({
    required Color dotColor,
    required Color valueColor,
    required String label,
    required String currencySymbolText,
    required bool isNewSar,
    required NumberFormat numberFormat,
    double? amount,
    int? points,
    String? pointsUnit,
  }) {
    if (amount == null && points == null) return const SizedBox.shrink();
    final pointsColor = _tone.gold.fg;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsetsDirectional.only(end: 4),
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 11.5, fontFamily: 'Cairo'),
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  color: _cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (points != null) ...[
                TextSpan(
                  text: '$points ',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: pointsColor,
                  ),
                ),
                TextSpan(
                  text: pointsUnit,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: pointsColor,
                    fontSize: 9.5,
                  ),
                ),
                if (amount != null)
                  TextSpan(
                    text: '  •  ',
                    style: TextStyle(color: _cs.onSurfaceVariant),
                  ),
              ],
              if (amount != null) ...[
                TextSpan(
                  text: numberFormat.format(amount.round()),
                  style: TextStyle(fontWeight: FontWeight.w800, color: valueColor),
                ),
                const TextSpan(text: ' '),
                ...cu.sarAwareSpans(
                  currencySymbolText,
                  isNewSar: isNewSar,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: valueColor,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// PATCH 6: بطاقة إجمالي مع حد سفلي ملوّن
  // ignore: unused_element
  Widget _buildTotalCard({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required Color borderBottomColor,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        decoration: BoxDecoration(
          color: _cs.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _cs.outlineVariant,
          ),
          boxShadow: [
            BoxShadow(
              color: borderBottomColor.withValues(alpha: 0.50),
              blurRadius: 0,
              spreadRadius: 0,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 14, color: iconColor),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w600,
                color: _cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
                color: _cs.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  /// بطاقة إجمالي مع حد سفلي ملوّن + hover animation كامل
  Widget _buildSummaryTileWithBorder({
    required ThemeData theme,
    required ColorScheme colorScheme,
    required IconData icon,
    required String label,
    required String value,
    required Color accent,
    required Color borderBottomColor,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    var hovered = false;

    return StatefulBuilder(
      builder: (context, setTileState) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setTileState(() => hovered = true),
        onExit: (_) => setTileState(() => hovered = false),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          scale: hovered ? 1.025 : 1.0,
          child: Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 170),
                curve: Curves.easeOutCubic,
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
                decoration: BoxDecoration(
                  color: isDark
                      ? colorScheme.surfaceContainerHigh
                      : (hovered ? _cs.surfaceContainerLow : _cs.surfaceContainerLowest),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: hovered
                        ? accent.withValues(alpha: 0.35)
                        : Colors.transparent,
                    width: 1.2,
                  ),
                  boxShadow: hovered
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.14),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: _cs.shadow.withValues(alpha: 0.07),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: _cs.shadow.withValues(
                              alpha: isDark ? 0.18 : 0.08,
                            ),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 170),
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: hovered ? 0.16 : 0.10),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 170),
                        scale: hovered ? 1.08 : 1.0,
                        child: Icon(icon, size: 16, color: accent),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface.withValues(alpha: 0.52),
                      ),
                    ),
                    const SizedBox(height: 4),
                    cu.SarAwareText(
                      value,
                      isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: accent,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
              // الحد السفلي الملوّن — يتسع عند hover
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 170),
                  height: hovered ? 4 : 3,
                  decoration: BoxDecoration(
                    color: borderBottomColor,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// عنوان قسم مع شريط ذهبي جانبي
  Widget _buildSectionTitleBar(String title, ThemeData theme) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: _cs.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  /// بطاقة قسم بيضاء مع رأس (أيقونة + عنوان)
  Widget _buildActionsCard({
    required ThemeData theme,
    required IconData icon,
    required Color iconColor,
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHighest
            : _cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _cs.shadow.withValues(alpha: isDark ? 0.18 : 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // رأس البطاقة الفرعية
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: iconColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, size: 16, color: iconColor),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 1,
              color: theme.dividerColor.withValues(alpha: 0.18),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  /// شبكة البلاطات السريعة — 3 أعمدة مطابقة للمصدر.
  Widget _buildTwoColumnGrid(
    List<QuickActionItem> items,
    ThemeData theme, {
    bool animated = true,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        const cols = 3;
        const spacing = 8.0;
        final tileWidth =
            (constraints.maxWidth - spacing * (cols - 1)) / cols;

        // ارتفاع ثابت يكفي المحتوى: أيقونة 36 + مسافة 6 + نص سطرين 11*1.3*2 = ~71
        // نضيف هامشاً للـ padding الداخلي
        const tileHeight = 82.0;
        final ratio = tileWidth / tileHeight;

        final grid = GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            childAspectRatio: ratio,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final tile = _buildQuickActionTile(
              action: items[index],
              theme: theme,
              compact: tileWidth < 100,
            );
            if (!animated) return tile;
            return AnimationConfiguration.staggeredGrid(
              position: index,
              columnCount: cols,
              duration: const Duration(milliseconds: 260),
              child: FadeInAnimation(child: tile),
            );
          },
        );
        return animated ? AnimationLimiter(child: grid) : grid;
      },
    );
  }

  Widget _buildCustomizeTrailing(ThemeData theme, QuickActionGroup group) {
    return IconButton(
      icon: Icon(
        Icons.edit_outlined,
        size: 15,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
      ),
      tooltip: widget.isArabic ? 'تخصيص' : 'Customize',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CustomizeQuickActionsScreen(initialGroup: group),
          ),
        );
      },
    );
  }

  /// شبكة قابلة للتوسيع — بدون stagger animation على الـ tiles
  Widget _buildExpandableGrid({
    required List<QuickActionItem> items,
    required bool expanded,
    required ThemeData theme,
  }) {
    return _AnimatedExpandSection(
      expanded: expanded,
      child: _buildTwoColumnGrid(items, theme, animated: false),
    );
  }

  Widget _buildQuickGroupFooter({
    required ThemeData theme,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    final arrowColor = theme.colorScheme.onSurface.withValues(alpha: 0.28);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
              width: 1,
            ),
          ),
        ),
        child: Center(
          child: AnimatedRotation(
            turns: expanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeInOutCubic,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: arrowColor,
            ),
          ),
        ),
      ),
    );
  }

  /// نص فرعي مرتبط بمسار الزر
  String? _getActionSubtitle(String route) {
    final isAr = widget.isArabic;
    switch (route) {
      case 'purchase_invoice':
        return isAr ? 'من مورد' : 'From supplier';
      case 'scrap_sales':
        return isAr ? 'من العميل' : 'From customer';
      case 'scrap_purchase':
        return isAr ? 'من عميل' : 'From customer';
      case 'return_sales':
        return isAr ? 'مرتجع بيع' : 'Sales return';
      case 'return_purchase':
        return isAr ? 'مرتجع شراء' : 'Purchase return';
      case 'return_purchase_supplier':
        return isAr ? 'من مورد' : 'From supplier';
      case 'invoices_list':
        return isAr ? 'جميع الفواتير' : 'All invoices';
      case 'add_customer':
        return isAr ? 'عميل جديد' : 'New customer';
      case 'customers_list':
        return isAr ? 'إدارة العملاء' : 'Manage customers';
      case 'suppliers_list':
        return isAr ? 'إدارة المورّدين' : 'Manage suppliers';
      case 'journal_entry':
        return isAr ? 'قيد جديد' : 'New entry';
      case 'journal_entries_list':
        return isAr ? 'قيود محاسبية' : 'Accounting entries';
      case 'vouchers':
      case 'vouchers_list':
        return isAr ? 'قبض / صرف' : 'Receipt / Payment';
      case 'receipt_voucher':
        return isAr ? 'قبض نقدي' : 'Cash receipt';
      case 'payment_voucher':
        return isAr ? 'صرف نقدي' : 'Cash payment';
      case 'accounts':
        return isAr ? 'شجرة الحسابات' : 'Chart of accounts';
      case 'general_ledger':
        return isAr ? 'دفتر الأستاذ' : 'Ledger book';
      case 'trial_balance':
        return isAr ? 'ميزان المراجعة' : 'Trial balance';
      case 'reports_center':
        return isAr ? '22 تقرير' : '22 reports';
      case 'chart_of_accounts':
        return isAr ? 'هيكل الحسابات' : 'Account structure';
      case 'melting_renewal':
        return isAr ? 'تكسير وتجديد' : 'Melt & renew';
      case 'add_item':
        return isAr ? 'صنف جديد' : 'New item';
      case 'items_list':
        return isAr ? 'إدارة المخزون' : 'Manage stock';
      case 'printing_center':
        return isAr ? 'طباعة المستندات' : 'Print documents';
      case 'posting_management':
        return isAr ? 'اعتماد الفواتير' : 'Invoice approvals';
      case 'shift_closing':
        return isAr ? 'نهاية اليوم' : 'End of day';
      case 'safe_boxes':
        return isAr ? 'إدارة الخزائن' : 'Manage safes';
      default:
        return null;
    }
  }

  Widget _buildQuickActions() {
    final theme = Theme.of(context);
    final isAr = widget.isArabic;

    return Consumer<QuickActionsProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return Center(
            child: CircularProgressIndicator(color: _cs.primary),
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
                Icon(Icons.info_outline, color: _tone.info.fg, size: 40),
                const SizedBox(height: 12),
                Text(
                  isAr ? 'لا توجد أزرار وصول سريع مفعّلة' : 'No quick actions enabled',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  isAr ? 'اذهب إلى الإعدادات لتخصيص الأزرار' : 'Go to settings to customize buttons',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        }

        final primaryAction = activeActions.firstWhere(
          (a) => a.route == 'sales_invoice',
          orElse: () => activeActions.first,
        );

        // Filter by group field (set in catalog — no hardcoded route lists needed).
        final salesActions = activeActions
            .where((a) => a.id != 'sales_invoice' && a.group == QuickActionGroup.sales)
            .toList();
        final accountingActions = activeActions
            .where((a) => a.group == QuickActionGroup.accounting)
            .toList();
        final adminActions = activeActions
            .where((a) => a.group == QuickActionGroup.admin)
            .toList();

        final compact = MediaQuery.sizeOf(context).width < 640;
        final defaultVisible = compact ? 2 : 3;

        final salesExpanded    = _expandedGroups.contains(QuickActionGroup.sales);
        final accountingExpanded = _expandedGroups.contains(QuickActionGroup.accounting);
        final adminExpanded    = _expandedGroups.contains(QuickActionGroup.admin);

        final shownSales       = salesActions.take(defaultVisible).toList();
        final hiddenSales      = salesActions.skip(defaultVisible).toList();
        final shownAccounting  = accountingActions.take(defaultVisible).toList();
        final hiddenAccounting = accountingActions.skip(defaultVisible).toList();
        final shownAdmin       = adminActions.take(defaultVisible).toList();
        final hiddenAdmin      = adminActions.skip(defaultVisible).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitleBar(
              isAr ? 'الوصول السريع' : 'Quick Access',
              theme,
            ),
            const SizedBox(height: 12),
            _buildActionsCard(
              theme: theme,
              icon: Icons.receipt_long_rounded,
              iconColor: _tone.ready.fg,
              title: isAr ? 'المبيعات والمشتريات' : 'Sales & Purchases',
              trailing: _buildCustomizeTrailing(theme, QuickActionGroup.sales),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPrimaryActionButton(action: primaryAction, theme: theme),
                  if (shownSales.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _buildTwoColumnGrid(shownSales, theme),
                  ],
                  if (hiddenSales.isNotEmpty) ...[
                    _buildExpandableGrid(
                      items: hiddenSales,
                      expanded: salesExpanded,
                      theme: theme,
                    ),
                    _buildQuickGroupFooter(
                      theme: theme,
                      expanded: salesExpanded,
                      onTap: () => setState(() => salesExpanded
                          ? _expandedGroups.remove(QuickActionGroup.sales)
                          : _expandedGroups.add(QuickActionGroup.sales)),
                    ),
                  ],
                ],
              ),
            ),
            if (shownAccounting.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildActionsCard(
                theme: theme,
                icon: Icons.menu_book_rounded,
                iconColor: _tone.info.fg,
                title: isAr ? 'المحاسبة والتقارير' : 'Accounting & Reports',
                trailing: _buildCustomizeTrailing(theme, QuickActionGroup.accounting),
                child: Column(
                  children: [
                    _buildTwoColumnGrid(shownAccounting, theme),
                    if (hiddenAccounting.isNotEmpty) ...[
                      _buildExpandableGrid(
                        items: hiddenAccounting,
                        expanded: accountingExpanded,
                        theme: theme,
                      ),
                      _buildQuickGroupFooter(
                        theme: theme,
                        expanded: accountingExpanded,
                        onTap: () => setState(() => accountingExpanded
                            ? _expandedGroups.remove(QuickActionGroup.accounting)
                            : _expandedGroups.add(QuickActionGroup.accounting)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (shownAdmin.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildActionsCard(
                theme: theme,
                icon: Icons.settings_rounded,
                iconColor: _tone.gold.fg,
                title: isAr ? 'الإدارة' : 'Administration',
                trailing: _buildCustomizeTrailing(theme, QuickActionGroup.admin),
                child: Column(
                  children: [
                    _buildTwoColumnGrid(shownAdmin, theme),
                    if (hiddenAdmin.isNotEmpty) ...[
                      _buildExpandableGrid(
                        items: hiddenAdmin,
                        expanded: adminExpanded,
                        theme: theme,
                      ),
                      _buildQuickGroupFooter(
                        theme: theme,
                        expanded: adminExpanded,
                        onTap: () => setState(() => adminExpanded
                            ? _expandedGroups.remove(QuickActionGroup.admin)
                            : _expandedGroups.add(QuickActionGroup.admin)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// زر رئيسي ممتد بعرض البطاقة كما في المصدر
  Widget _buildPrimaryActionButton({
    required QuickActionItem action,
    required ThemeData theme,
  }) {
    final isAr = widget.isArabic;
    var hovered = false;
    return StatefulBuilder(
      builder: (context, setState) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit:  (_) => setState(() => hovered = false),
        child: GestureDetector(
          onTap: () => _handleQuickActionTap(action.route),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            scale: hovered ? 1.018 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(
                hovered ? -1.0 : 0.0,
                hovered ? -1.0 : 0.0,
                0,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_cs.primary, Color.lerp(_cs.primary, _cs.shadow, 0.25)!],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: hovered
                    ? [
                        // ظل محيطي ذهبي فاتح متلاشٍ
                        BoxShadow(
                          color: _cs.primary.withValues(alpha: 0.35),
                          blurRadius: 22,
                          spreadRadius: 2,
                          offset: const Offset(0, 4),
                        ),
                        BoxShadow(
                          color: _tone.gold.fg.withValues(alpha: 0.22),
                          blurRadius: 10,
                          offset: const Offset(0, 6),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: _tone.gold.fg.withValues(alpha: 0.28),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: Row(
                  children: [
                    // زر + في اليسار (RTL: يمين)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 170),
                      curve: Curves.easeOutCubic,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: _cs.onPrimary.withValues(alpha: hovered ? 0.30 : 0.20),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.add_rounded, color: _cs.onPrimary, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isAr ? 'فاتورة بيع جديدة' : 'New Sales Invoice',
                            style: TextStyle(
                              color: _cs.onPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              fontFamily: 'Cairo',
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isAr ? 'السريع · الأكثر استخداماً' : 'Quick · Most used',
                            style: TextStyle(
                              color: _cs.onPrimary.withValues(alpha: 0.80),
                              fontSize: 11,
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w500,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedSlide(
                      duration: const Duration(milliseconds: 170),
                      curve: Curves.easeOutCubic,
                      offset: Offset(hovered ? -0.22 : 0, 0),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 170),
                        opacity: hovered ? 1.0 : 0.70,
                        child: Icon(
                          Icons.arrow_back_rounded,
                          color: _cs.onPrimary,
                          size: 22,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// بلاطة سريعة: تصميم عامودي (أيقونة فوق + نص تحت) مطابق للمصدر.
  Widget _buildQuickActionTile({
    required QuickActionItem action,
    required ThemeData theme,
    bool compact = false,
  }) {
    final color = action.getColor();
    final isDark = theme.brightness == Brightness.dark;
    final subtitle = compact ? null : _getActionSubtitle(action.route);
    final iconBoxSize = compact ? 32.0 : 38.0;
    final iconSize = compact ? 18.0 : 20.0;
    final labelSize = compact ? 10.0 : 11.0;
    var hovered = false;

    return StatefulBuilder(
      builder: (context, setState) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit:  (_) => setState(() => hovered = false),
        child: GestureDetector(
          onTap: () => _handleQuickActionTap(action.route),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            scale: hovered ? 1.04 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: hovered
                    ? (isDark ? theme.colorScheme.surface : _cs.surfaceContainerLowest)
                    : (isDark
                        ? theme.colorScheme.surfaceContainerHigh
                        : _cs.surfaceContainerLow),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hovered
                      ? color.withValues(alpha: 0.40)
                      : Colors.transparent,
                  width: 1.2,
                ),
                boxShadow: hovered
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.13),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                        BoxShadow(
                          color: _cs.shadow.withValues(alpha: isDark ? 0.13 : 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: _cs.shadow.withValues(alpha: isDark ? 0.04 : 0.02),
                          blurRadius: 2,
                          offset: const Offset(0, 1),
                        ),
                      ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── أيقونة ملوّنة مع خلفية مستطيل مدوّر ──
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 170),
                    curve: Curves.easeOutCubic,
                    width: iconBoxSize,
                    height: iconBoxSize,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: hovered ? 0.20 : 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 170),
                      curve: Curves.easeOutCubic,
                      scale: hovered ? 1.08 : 1.0,
                      child: Icon(action.icon, color: color, size: iconSize),
                    ),
                  ),
                  const SizedBox(height: 5),
                  // ── اسم الإجراء ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      action.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                        fontSize: labelSize,
                        height: 1.25,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  // ── النص الفرعي (اختياري) ──
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 9,
                          fontFamily: 'Cairo',
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }


  // ─── خريطة الصلاحيات: كل مسار → الصلاحية المطلوبة ───────────────────────
  // null  = مسموح لجميع المستخدمين المسجّلين
  // 'ADMIN_ONLY' = مسؤول النظام فقط
  static const Map<String, String?> _routePermissions = {
    // فواتير
    'invoices_list':           'invoices.view',
    'return_invoice':          'invoices.view',
    'return_sales':            'invoices.view',
    'return_purchase':         'invoices.view',
    'return_purchase_supplier':'invoices.view',
    'posting_management':      'invoices.approve',
    // محاسبة
    'accounts':                'accounts.view',
    'chart_of_accounts':       'accounts.view',
    'general_ledger':          'accounts.view',
    'trial_balance':           'accounts.view',
    'journal_entry':           'journal.view',
    'journal_entries_list':    'journal.view',
    'vouchers':                'vouchers.view',
    'vouchers_list':           'vouchers.view',
    'receipt_voucher':         'vouchers.view',
    'payment_voucher':         'vouchers.view',
    // خزائن
    'safe_boxes':              'safe_boxes.transfer',
    'shift_closing':           'safe_boxes.edit',
    // الموظفون والرواتب
    'employees':               'employees.view',
    'payroll':                 'employees.payroll',
    'payroll_report':          'employees.payroll',
    'attendance':              'employees.view',
    'bonus_rules':             'employees.bonuses',
    'calculate_bonuses':       'employees.bonuses',
    'bonuses':                 'employees.bonuses',
    // تقارير
    'reports_center':          'ANY_REPORT',
    'gold_price_history':      'reports.financial',
    // أدوات تشغيلية
    'clearing_settlement':     'MANAGER_ONLY',
    // مستخدمون وإعدادات النظام
    'users':                   'ADMIN_ONLY',
    'system_reset':            'ADMIN_ONLY',
    'backup_restore':          'ADMIN_ONLY',
    'import_documents':        'ADMIN_ONLY',
    // بضاعة / عملاء — مسموح لعموم الموظفين (null)
    'sales_invoice':           null,
    'scrap_sales':             null,
    'scrap_purchase':          null,
    'purchase_invoice':        null,
    'add_customer':            null,
    'customers_list':          null,
    'suppliers_list':          null,
    'add_item':                null,
    'items_list':              null,
    'printing_center':         null,
    'melting_renewal':         null,
  };

  /// The reports centre opens for whoever holds any report (ADR-036).
  static bool _holdsAnyReport(AuthProvider auth) => const [
        'reports.financial', 'reports.inventory', 'reports.sales', 'reports.purchases',
        'reports.customers', 'reports.employees', 'reports.gold_position',
      ].any(auth.hasPermission);

  /// يتحقق من صلاحية الوصول — يعرض رسالة واضحة ويعيد false إن لم يكن مسموحاً
  bool _checkRoutePermission(String route) {
    final auth = context.read<AuthProvider>();
    final required = _routePermissions[route];
    // المسارات غير المدرجة أو التي لا تحتاج صلاحية خاصة → مسموح
    if (required == null) return true;
    final allowed = required == 'ADMIN_ONLY'
        ? auth.isSystemAdmin
        : required == 'MANAGER_ONLY'
            ? auth.isManager
            : required == 'ANY_REPORT'
                ? _holdsAnyReport(auth)
                : auth.hasPermission(required);
    if (!allowed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            Icon(Icons.lock_outline, color: _cs.onError, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(
              widget.isArabic
                  ? 'ليس لديك صلاحية لاستعراض هذا القسم'
                  : 'You do not have permission to access this section',
              style: TextStyle(fontWeight: FontWeight.w600, color: _cs.onError),
            )),
          ]),
          backgroundColor: _cs.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }
    return true;
  }

  // معالجة النقر على أزرار الوصول السريع
  Future<void> _handleQuickActionTap(String route) async {
    if (!_checkRoutePermission(route)) return;
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
      case 'admin_dashboard':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AdminDashboardScreen(api: api, isArabic: widget.isArabic),
          ),
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
      case 'clearing_settlement':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ClearingMonitorScreen()),
        );
        if (result == true || result == null) await _loadAllData();
        break;
      case 'import_documents':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImportDocumentsScreen(isArabic: widget.isArabic),
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
                backgroundColor: _tone.warning.fg,
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
      case 'vouchers':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => VouchersListScreen()),
        );
        break;
      case 'invoices_list':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => InvoicesListScreen(isArabic: widget.isArabic),
          ),
        );
        break;
      case 'return_purchase_supplier':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const PurchaseInvoiceScreen(supplierReturnMode: true),
          ),
        );
        break;
      case 'recurring_entries':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RecurringTemplatesScreen(isArabic: widget.isArabic),
          ),
        );
        break;
      case 'general_ledger':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => GeneralLedgerScreenV2()),
        );
        break;
      case 'trial_balance':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TrialBalanceScreenV2()),
        );
        break;
      case 'chart_of_accounts':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChartOfAccountsScreen()),
        );
        break;
      case 'gold_position':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GoldPositionReportScreen(
              api: api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'payroll_report':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PayrollReportScreen(api: api),
          ),
        );
        break;
      case 'safe_boxes':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SafeBoxesScreen(api: api)),
        );
        break;
      case 'bonuses':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BonusManagementScreen(
              api: api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'branches_management':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BranchesManagementScreen(
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;
      case 'system_reset':
        result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SystemResetScreen()),
        );
        break;
      case 'printer_settings':
      case 'about':
        result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const SettingsScreenEnhanced(),
          ),
        );
        break;
      case 'barcode_scan':
        {
          final scanned = await Navigator.push<String>(
            context,
            MaterialPageRoute(
              builder: (_) => const BarcodeScannerScreen(),
            ),
          );
          if (scanned != null && scanned.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  widget.isArabic
                      ? 'تم المسح: $scanned'
                      : 'Scanned: $scanned',
                ),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }
        break;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('هذه الميزة غير متوفرة حالياً'),
            backgroundColor: _tone.warning.fg,
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


class _AnimatedExpandSection extends StatefulWidget {
  final bool expanded;
  final Widget child;

  const _AnimatedExpandSection({required this.expanded, required this.child});

  @override
  State<_AnimatedExpandSection> createState() => _AnimatedExpandSectionState();
}

class _AnimatedExpandSectionState extends State<_AnimatedExpandSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _opacity;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
      value: widget.expanded ? 1.0 : 0.0,
    );
    _sizeFactor = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
    _opacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.08, 1.0, curve: Curves.easeIn),
    );
    _ctrl.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    final running = status == AnimationStatus.forward ||
        status == AnimationStatus.reverse;
    if (running != _animating) setState(() => _animating = running);
  }

  @override
  void didUpdateWidget(_AnimatedExpandSection old) {
    super.didUpdateWidget(old);
    if (widget.expanded != old.expanded) {
      setState(() => _animating = true);
      widget.expanded ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.removeStatusListener(_onStatus);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animating) {
      if (widget.expanded) {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: widget.child,
        );
      }
      return const SizedBox.shrink();
    }
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _sizeFactor,
        axisAlignment: -1.0,
        child: FadeTransition(
          opacity: _opacity,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Paints a rounded-rectangle badge with an optional concave notch
/// cut from the top-center edge — used for rank-1 in the leaderboard.
class _RankBadgeNotchPainter extends CustomPainter {
  final List<Color> gradientColors;
  final Color shadowColor;
  final double notchRadius;

  const _RankBadgeNotchPainter({
    required this.gradientColors,
    required this.shadowColor,
    this.notchRadius = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const r = 14.0;
    final nx = size.width / 2;
    final nr = notchRadius;

    final path = Path();
    path.moveTo(r, 0);

    if (nr > 0) {
      // Flatten the sides of the notch so it looks like a smooth scallop
      path.lineTo(nx - nr * 1.4, 0);
      path.arcToPoint(
        Offset(nx + nr * 1.4, 0),
        radius: Radius.circular(nr),
        clockwise: false,
      );
    }

    path.lineTo(size.width - r, 0);
    path.arcToPoint(Offset(size.width, r), radius: Radius.circular(r));
    path.lineTo(size.width, size.height - r);
    path.arcToPoint(Offset(size.width - r, size.height), radius: Radius.circular(r));
    path.lineTo(r, size.height);
    path.arcToPoint(Offset(0, size.height - r), radius: Radius.circular(r));
    path.lineTo(0, r);
    path.arcToPoint(Offset(r, 0), radius: Radius.circular(r));
    path.close();

    // Shadow
    canvas.drawShadow(path, shadowColor, 8, false);

    // Gradient fill
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradientColors,
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _RankBadgeNotchPainter old) =>
      old.gradientColors != gradientColors ||
      old.notchRadius != notchRadius;
}
