
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'income_statement_report_screen.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_service.dart';
import '../../app_events.dart';
import '../../providers/settings_provider.dart';
import '../../utils/party_balance.dart';
import '../../utils/currency_utils.dart' as cu;
import '../../utils/live_gold_prices.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_state_views.dart';
import '../../widgets/weight_position_summary_card.dart';
import '../safe_boxes_screen.dart';
import 'gold_price_history_report_screen.dart';
import 'safe_box_hero_details_screen.dart';
import 'widgets/dashboard_attention_bar.dart';
import 'widgets/dashboard_gold_price_card.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/dashboard_period_panels.dart';
import 'widgets/dashboard_standing_panels.dart';
import 'widgets/dashboard_summary_tabs_card.dart';

enum _TimeRange { today, month, year }

class AdminDashboardScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  /// Where «رجوع» goes when the dashboard is a tab of the home screen -- the
  /// side menu's and the bottom bar's, with no screen behind it to pop back to
  /// (the owner, 31 Oct 2026: «زر العودة لا يقوم بدور صحيح أثناء الدخول من
  /// القائمة الجانبية والسفلية»). Opened as a screen of its own -- from the
  /// reports -- it is none, and «رجوع» closes it.
  final VoidCallback? onBack;

  const AdminDashboardScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.onBack,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> with LiveGoldPrices {
  // The theme's colours only (DASH-2): the fixed AppColors did not follow the
  // dark theme -- the text and the cards lost each other.
  ColorScheme get _scheme => Theme.of(context).colorScheme;
  AppSemanticColors get _tones => AppSemanticColors.of(context);

  Map<String, dynamic>? _response;
  int _positionEpoch = 0;
  bool _isLoading = false;
  // Where the business stands (DASH-10): its own request, beside the dashboard's.
  Map<String, dynamic>? _standing;
  bool _standingLoading = true;
  String? _error;

  int? _expandedVaultSafeBoxId;
  int? _pressedVaultSafeBoxId;

  _TimeRange _timeRange = _TimeRange.today;

  // ── Gram Profit KPI ─────────────────────────────────────────────────────
  Map<String, dynamic>? _gramProfitData;
  // The month's race, by points -- its own reading (DASH-9).
  List<Map<String, dynamic>> _leaders = const [];
  bool _gramProfitLoading = false;

  // ── Vault ordering ────────────────────────────────────────────────────────
  /// Local ordered list of safe-box ids (persisted in SharedPreferences).
  List<int> _vaultOrder = [];
  /// Safe-box ids that were opened in the current session ("recently used").
  final Set<int> _recentVaultIds = {};
  static const String _kVaultOrderKey = 'dashboard_vault_order';
  /// Horizontal scroll controller for the vault list (mouse wheel support).
  final ScrollController _vaultScrollController = ScrollController();
  /// When true the vault list becomes a drag-and-drop reorderable list.
  bool _isReorderingVaults = false;

  /// Maps the unified top-level time selector to the backend summary key.
  String get _summaryPeriod {
    switch (_timeRange) {
      case _TimeRange.today:
        return 'today';
      case _TimeRange.month:
        return 'month';
      case _TimeRange.year:
        return 'year';
    }
  }


  String _currencySymbol = 'ر.س';
  bool _currencyIsNewSar = false;
  int _currencyDecimals = 2;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

  @override
  void initState() {
    super.initState();
    _currencyFormat = NumberFormat(
      '#,##0${'.'}${'0' * _currencyDecimals}',
      widget.isArabic ? 'ar' : 'en',
    );
    _weightFormat = NumberFormat('#,##0.000');
    _loadVaultOrder();
    _loadData();
    _loadGramProfit();
    _loadLeaders();
    _loadGoldPrice();
    AppEvents.vaultRefreshSignal.addListener(_onVaultRefresh);
  }

  // The gold price card (DASH-11): the server's price, live at its interval --
  // the invoices' strip's own reading -- and the day's move, read with the page.
  Map<String, dynamic> _goldToday = const {};

  @override
  Future<Map<String, dynamic>> fetchLiveGoldPrice() => widget.api.getGoldPrice();

  Future<void> _loadGoldPrice() async {
    try {
      showLiveGoldPrice(await fetchLiveGoldPrice());
    } catch (e) {
      debugPrint('❌ Gold price load error: $e');
    }
    if (mounted) startLiveGoldPrices();
  }

  Future<void> _loadGoldToday() async {
    try {
      final data = await widget.api.getGoldPriceToday();
      if (mounted) setState(() => _goldToday = data);
    } catch (e) {
      debugPrint('❌ Gold price today load error: $e');
    }
  }

  void _onVaultRefresh() {
    if (mounted) _loadData();
  }

  @override
  void dispose() {
    AppEvents.vaultRefreshSignal.removeListener(_onVaultRefresh);
    stopLiveGoldPrices();
    _vaultScrollController.dispose();
    super.dispose();
  }

  // ── Vault order persistence ──────────────────────────────────────────────
  Future<void> _loadVaultOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kVaultOrderKey) ?? [];
      if (mounted) {
        setState(() {
          _vaultOrder = raw
              .map((s) => int.tryParse(s))
              .whereType<int>()
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveVaultOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kVaultOrderKey,
        _vaultOrder.map((id) => id.toString()).toList(),
      );
    } catch (_) {}
  }

  /// Returns safe-box list sorted: recently-used first, then user order.
  List<Map<String, dynamic>> _sortedVaults(List<dynamic> raw) {
    final maps = raw.whereType<Map<String, dynamic>>().toList();

    // Seed _vaultOrder with any new ids not yet stored
    final knownIds = _vaultOrder.toSet();
    for (final sb in maps) {
      final id = sb['id'];
      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
      if (sbId != null && !knownIds.contains(sbId)) {
        _vaultOrder.add(sbId);
        knownIds.add(sbId);
      }
    }

    maps.sort((a, b) {
      final aId = a['id'] is int ? a['id'] as int : int.tryParse(a['id']?.toString() ?? '') ?? -1;
      final bId = b['id'] is int ? b['id'] as int : int.tryParse(b['id']?.toString() ?? '') ?? -1;

      final aRecent = _recentVaultIds.contains(aId);
      final bRecent = _recentVaultIds.contains(bId);
      if (aRecent && !bRecent) return -1;
      if (!aRecent && bRecent) return 1;

      final aPos = _vaultOrder.indexOf(aId);
      final bPos = _vaultOrder.indexOf(bId);
      final aRank = aPos < 0 ? 9999 : aPos;
      final bRank = bPos < 0 ? 9999 : bPos;
      return aRank.compareTo(bRank);
    });

    return maps;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    final symbol = settings.currencySymbolText;
    final isNewSar = settings.currencyIsNewSar;
    final decimals = settings.decimalPlaces;

    if (symbol != _currencySymbol ||
        isNewSar != _currencyIsNewSar ||
        decimals != _currencyDecimals) {
      setState(() {
        _currencySymbol = symbol;
        _currencyIsNewSar = isNewSar;
        _currencyDecimals = decimals;
        _currencyFormat = NumberFormat(
          '#,##0${'.'}${'0' * decimals}',
          widget.isArabic ? 'ar' : 'en',
        );
      });
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _positionEpoch++;   // the «التسكير الآن» card reloads with the dashboard
    });
    _loadStanding();   // beside it, not after it (DASH-10)
    _loadGoldToday();

    try {
      final result = await widget.api.getAdminDashboard();
      if (!mounted) return;

      setState(() => _response = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }


  /// Where the business stands (DASH-10): the six readings DASH-4..9, their own
  /// request -- the screen draws without waiting for them, each panel in its
  /// grey shape until they come.
  Future<void> _loadStanding() async {
    setState(() => _standingLoading = true);
    try {
      final data = await widget.api.getAdminDashboardStanding();
      if (mounted) setState(() => _standing = data);
    } catch (e) {
      debugPrint('❌ Dashboard standing load error: $e');
    } finally {
      if (mounted) setState(() => _standingLoading = false);
    }
  }

  DashboardMoney get _money => DashboardMoney(
        format: _currencyFormat,
        symbol: _currencySymbol,
        isNewSar: _currencyIsNewSar,
        weight: _weightFormat,
      );

  /// Who leads the month (DASH-9): the race's own reading, its points with the
  /// losses already off them (POINTS-DEFICIT-1).
  Future<void> _loadLeaders() async {
    try {
      final data = await widget.api.getHomeLeaderboard(period: 'month', metric: 'points');
      final ranking = ((data['ranking'] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
      if (mounted) setState(() => _leaders = ranking);
    } catch (e) {
      debugPrint('❌ Leaderboard load error: $e');
    }
  }

  /// The period the gram profit card says, and its report opens on.
  DateTimeRange _gramProfitRange() {
    final now = DateTime.now();
    final start = switch (_timeRange) {
      _TimeRange.today => DateTime(now.year, now.month, now.day),
      _TimeRange.month => DateTime(now.year, now.month, 1),
      _TimeRange.year => DateTime(now.year, 1, 1),
    };
    return DateTimeRange(start: start, end: now);
  }

  Future<void> _loadGramProfit() async {
    try {
      setState(() => _gramProfitLoading = true);
      final range = _gramProfitRange();
      final data = await widget.api.getGramProfitReport(
        startDate: range.start,
        endDate: range.end,
      );
      if (mounted) setState(() => _gramProfitData = data);
    } catch (e) {
      debugPrint('❌ Gram profit load error: $e');
    } finally {
      if (mounted) setState(() => _gramProfitLoading = false);
    }
  }


  double _asDouble(dynamic value) => value is num ? value.toDouble() : 0.0;


  int _asInt(dynamic value) =>
      value is int ? value : (value is num ? value.toInt() : 0);

  String _formatCurrency(num value) => '${_currencyFormat.format(value)} $_currencySymbol';
  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  Widget _currencyAwareText(
    String text, {
    TextStyle? style,
    TextAlign textAlign = TextAlign.start,
    int? maxLines,
    TextOverflow? overflow,
  }) {
    return cu.SarAwareText(
      text,
      isNewSar: _currencyIsNewSar,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: SafeArea(
          // The first load is the page's shape in grey (ADR-057); a refresh
          // keeps what is shown, a thin line above it (DASH-10).
          child: _response == null
              ? (_error != null ? _buildErrorState() : const AppLoadingView(summaryBlocks: 3, rows: 5))
              : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final isArabic = widget.isArabic;
    final hintColor = Theme.of(context).hintColor;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 52, color: _scheme.error),
          SizedBox(height: 12),
          Text(
            isArabic ? 'تعذّر تحميل البيانات' : 'Failed to load data',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: hintColor, fontSize: 12),
            ),
          ),
          SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final globalSnapshot =
        (_response?['global_snapshot'] as Map<String, dynamic>?) ?? {};
    final kpis = (_response?['kpis'] as Map<String, dynamic>?) ?? {};
    final valuation = (_response?['valuation'] as Map<String, dynamic>?) ?? {};
    final liquidity = (_response?['liquidity'] as Map<String, dynamic>?) ?? {};
    final safeBoxes = (_response?['safe_boxes'] as List?) ?? [];
    final series = (_response?['series'] as Map<String, dynamic>?) ?? {};
    final salesPurchasesSummary =
        (_response?['sales_purchases_summary'] as Map<String, dynamic>?) ?? {};
    final goldByKarat = (kpis['gold_by_karat'] as Map<String, dynamic>?) ?? {};

    // Where the business stands (DASH-10): each panel its grey shape while
    // its reading is on the way, and nothing where the reading has nothing.
    final standing = _standing;
    Map<String, dynamic> part(String key) => (standing?[key] as Map<String, dynamic>?) ?? {};
    final waiting = standing == null && _standingLoading;
    final positions = part('positions');
    final clearing = part('clearing');
    final vat = part('vat');
    final deficits = part('deficits');
    final receivables = standing == null
        ? null
        : _asDouble(((positions['customers'] as Map?) ?? const {})['owe_us_cash']);

    final isArabic = widget.isArabic;
    final isNarrow = MediaQuery.sizeOf(context).width < 760;
    const gutter = EdgeInsets.symmetric(horizontal: AppSpace.lg);
    Widget sectionHead(String title, String subtitle) => Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.xl, AppSpace.lg, AppSpace.md),
          child: DashboardSection(title: title, subtitle: subtitle),
        );

    final nowTiles = <Widget>[
      WeightPositionSummaryCard(
        key: ValueKey('wps-$_positionEpoch'),
        api: widget.api,
        isArabic: isArabic,
      ),
      if (waiting)
        const DashboardPanelSkeleton(lines: 5)
      else if (positions.isNotEmpty)
        DashboardBalancePanel(positions: positions, isArabic: isArabic, money: _money),
      if (waiting)
        const DashboardPanelSkeleton(lines: 4)
      else if (((clearing['safes'] as List?) ?? const []).isNotEmpty)
        DashboardClearingPanel(clearing: clearing, isArabic: isArabic, money: _money),
      _buildKaratDistributionCard(goldByKarat),
      _buildLiquidityBreakdownCard(liquidity, receivables: receivables),
    ];

    final periodTiles = <Widget>[
      if (waiting)
        const DashboardPanelSkeleton(lines: 5)
      else if (_leaders.isNotEmpty || ((deficits['count'] as num?) ?? 0) > 0)
        DashboardEmployeesPanel(leaders: _leaders, deficits: deficits, isArabic: isArabic, money: _money),
      if (waiting)
        const DashboardPanelSkeleton(lines: 4)
      else if (vat.isNotEmpty)
        DashboardVatPanel(vat: vat, isArabic: isArabic, money: _money),
    ];

    return RefreshIndicator(
      onRefresh: _loadData,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // === The header: the net position and the gold price ===
          SliverToBoxAdapter(
            child: _buildGlobalSnapshotHeader(
              globalSnapshot,
              valuation,
              series,
            ),
          ),
          // A refresh keeps the page, a thin line says it is on its way.
          if (_isLoading)
            const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),

          // === What needs the manager: a line of pills (DASH-10) ===
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, 0),
              child: waiting
                  ? const _PillsSkeleton()
                  : standing == null
                      ? const SizedBox.shrink()
                      : DashboardAttentionBar(
                          wrongNow: part('wrong_now'),
                          approvals: part('approvals'),
                          isArabic: isArabic,
                          money: _money,
                        ),
            ),
          ),

          // === Now: what stands at this moment -- no period changes it; the
          // performance straight beneath it ===
          SliverToBoxAdapter(
            child: sectionHead(isArabic ? 'الآن' : 'Now',
                isArabic ? 'حالة اللحظة، لا تتغير بالفترة' : 'As it stands; no period changes it'),
          ),
          SliverToBoxAdapter(child: Padding(padding: gutter, child: DashboardGrid(children: nowTiles))),

          // === The performance: the period's, and its selector above it alone ===
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyRangeSelectorDelegate(
              child: _buildPerformanceHead(isNarrow),
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              height: isNarrow ? 96.0 : 60.0,
              horizontalPadding: AppSpace.lg,
              verticalPadding: AppSpace.sm,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: gutter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Gram profit beside the period's movement (stacked on a phone)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final gramKpi = _buildGramProfitKpi();
                      final heroProfit = _buildPeriodMovementCard(liquidity, salesPurchasesSummary);
                      if (constraints.maxWidth >= 760) {
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: gramKpi),
                              const SizedBox(width: AppSpace.md),
                              Expanded(child: heroProfit),
                            ],
                          ),
                        );
                      }
                      return Column(
                        children: [gramKpi, const SizedBox(height: AppSpace.md), heroProfit],
                      );
                    },
                  ),
                  const SizedBox(height: AppSpace.md),
                  DashboardSummaryTabsCard(
                    periodData: (salesPurchasesSummary[_summaryPeriod] as Map<String, dynamic>?) ?? {},
                    isArabic: isArabic,
                    currencyFormat: _currencyFormat,
                    currencySymbol: _currencySymbol,
                    currencyIsNewSar: _currencyIsNewSar,
                    weightFormat: _weightFormat,
                  ),
                ],
              ),
            ),
          ),

          // === The month's and the quarter's ===
          if (periodTiles.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: sectionHead(isArabic ? 'هذا الشهر وهذا الربع' : 'This month and quarter',
                  isArabic ? 'الموظفون والضريبة' : 'Employees and VAT'),
            ),
            SliverToBoxAdapter(
              child: Padding(padding: gutter, child: DashboardGrid(minTileWidth: 380, children: periodTiles)),
            ),
          ],

          // === The safes, at the page's foot (the owner, 30 Oct 2026: «الآن ثم بعده
          // مباشرة الأداء ثم البقية، والخزائن تكون أسفل الصفحة») ===
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpace.lg),
              child: _buildVaultsSection(safeBoxes),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: AppSpace.xl)),
        ],
      ),
    );
  }

  /// The performance section's heading, its period's selector beside it --
  /// above what the period changes, and nothing else (DASH-10).
  Widget _buildPerformanceHead(bool isNarrow) {
    final isArabic = widget.isArabic;
    void pick(_TimeRange range) {
      setState(() => _timeRange = range);
      _loadGramProfit();
    }

    final selector = SegmentedButton<_TimeRange>(
      key: const Key('dashboard-period'),
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        ButtonSegment(value: _TimeRange.today, label: Text(isArabic ? 'اليوم' : 'Today')),
        ButtonSegment(value: _TimeRange.month, label: Text(isArabic ? 'هذا الشهر' : 'This Month')),
        ButtonSegment(value: _TimeRange.year, label: Text(isArabic ? 'هذه السنة' : 'This Year')),
      ],
      selected: {_timeRange},
      onSelectionChanged: (s) => pick(s.first),
    );
    final head = DashboardSection(
      title: isArabic ? 'الأداء' : 'Performance',
      subtitle: isNarrow ? null : (isArabic ? 'ما تغيّره الفترة' : 'What the period changes'),
    );
    // The selector in the screen's middle, the title at its side (the owner,
    // 30 Oct 2026: «أزرار الفترات ليست في مركز الشاشة بل مسحوبة على اليسار»).
    if (!isNarrow) {
      return Stack(alignment: Alignment.center, children: [head, selector]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [head, const SizedBox(height: AppSpace.sm), Center(child: selector)],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 1. GLOBAL SNAPSHOT HEADER
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildGlobalSnapshotHeader(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> valuation,
    Map<String, dynamic> series,
  ) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final netPosition = _asDouble(snapshot['net_financial_position']);
    final goldCard = DashboardGoldPriceCard(
      sell: liveSell,
      buy: liveBuy,
      opening: liveOpening,
      mainKarat: liveMainKarat ?? context.read<SettingsProvider>().mainKarat,
      at: liveAt,
      market: liveMarket,
      today: _goldToday,
      isArabic: isArabic,
      money: _money,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GoldPriceHistoryReportScreen(api: widget.api, isArabic: isArabic),
      )),
    );

    final isCompact = MediaQuery.of(context).size.width < 700;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: _scheme.surface,
        border: Border(
          bottom: BorderSide(
            color: _scheme.primary.withValues(
              alpha: isDark ? 0.28 : 0.35,
            ),
            width: 1.5,
          ),
        ),
      ),
      child: Column(
        children: [
          // Top Row: Title + Actions
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_forward_ios, size: 20),
                key: const Key('dashboard-back'),
                onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              Text(
                isArabic ? 'لوحة تحكم المدير' : 'Admin Dashboard',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh, size: 22),
                onPressed: _isLoading ? null : _loadData,
              ),
            ],
          ),
          SizedBox(height: 16),

          // Main Snapshot Row
          LayoutBuilder(builder: (context, constraints) {
            if (isCompact) {
              return Column(
                children: [
                  _buildNetPositionCard(theme, isArabic, netPosition, isWide: constraints.maxWidth >= 500),
                  SizedBox(height: 12),
                  goldCard,
                ],
              );
            }
            // One height for both (the owner, 30 Oct 2026: the gold price card
            // stood taller than the financial position's).
            final netWidth = (constraints.maxWidth - 12) * 3 / 5;
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildNetPositionCard(theme, isArabic, netPosition, isWide: netWidth >= 500),
                  ),
                  SizedBox(width: 12),
                  Expanded(flex: 2, child: goldCard),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// [isWide]: the card's own width is 500 or more -- measured by the
  /// header's row, outside the one height the two cards share (an
  /// IntrinsicHeight cannot hold a LayoutBuilder).
  Widget _buildNetPositionCard(
    ThemeData theme,
    bool isArabic,
    double netPosition, {
    required bool isWide,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final isPositive = netPosition >= 0;
    final accentColor = isPositive ? _scheme.primary : _scheme.error;
    return Container(
      key: const Key('dashboard-net-position'),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: isDark ? 0.30 : 0.50),
          width: 1.2,
        ),
      ),
      child: Builder(
        builder: (context) {

          return Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  isPositive ? Icons.account_balance : Icons.account_balance_outlined,
                  color: accentColor,
                  size: 28,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isArabic ? 'صافي المركز المالي' : 'Net Position',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: _currencyAwareText(
                        _formatCurrency(netPosition),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                          fontSize: 22,
                        ),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      isArabic ? 'نقد + قيمة الذهب' : 'Cash + Gold Value',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isWide && _response != null) ...[
                SizedBox(width: 16),
                Container(
                  width: 1,
                  height: 60,
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
                SizedBox(width: 16),
                _buildSnapshotMiniStat(
                  theme: theme,
                  icon: Icons.water_drop_outlined,
                  label: isArabic ? 'السيولة' : 'Liquidity',
                  value: _formatCurrency(_asDouble(
                    (_response?['liquidity'] as Map?)?['cash_available'] ?? 0,
                  )),
                  color: _tones.invoiceSaleScrap.fg,
                ),
                SizedBox(width: 20),
                _buildSnapshotMiniStat(
                  theme: theme,
                  icon: Icons.auto_awesome,
                  label: isArabic ? 'وزن الذهب' : 'Gold Weight',
                  value: _formatWeight(_asDouble(
                    (_response?['kpis'] as Map?)?['gold_equivalent_main_karat'] ?? 0,
                  )),
                  color: _scheme.primary,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildSnapshotMiniStat({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 13, color: color),
            SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        _currencyAwareText(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  // Karat Distribution Donut Card
  Widget _buildKaratDistributionCard(Map<String, dynamic> goldByKarat) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final k18 = _asDouble(goldByKarat['18k']);
    final k21 = _asDouble(goldByKarat['21k']);
    final k22 = _asDouble(goldByKarat['22k']);
    final k24 = _asDouble(goldByKarat['24k']);
    final total = k18 + k21 + k22 + k24;

    return _buildKpiCardWrapper(
      onTap: () {
        // Navigate to inventory
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pie_chart, color: _scheme.primary, size: 20),
              SizedBox(width: 6),
              Text(
                isArabic ? 'توزيع العيارات' : 'Karat Mix',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          if (total == 0)
            Center(
              child: Text(
                isArabic ? 'لا يوجد ذهب' : 'No gold',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            )
          else
            Row(
              children: [
                // Mini Donut Chart
                SizedBox(
                  width: 70,
                  height: 70,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 1,
                      centerSpaceRadius: 18,
                      sections: [
                        PieChartSectionData(
                          value: k24,
                          color: _tones.karat24.fg,
                          radius: 15,
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k22,
                          color: _tones.karat22.fg,
                          radius: 15,
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k21,
                color: _tones.karat21.fg,
                          radius: 15,
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k18,
                          color: _tones.karat18.fg,
                          radius: 15,
                          showTitle: false,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildKaratLegendItem(
                        label: '24K',
                        value: k24,
                        color: _tones.karat24.fg,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '22K',
                        value: k22,
                        color: _tones.karat22.fg,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '21K',
                        value: k21,
                        color: _tones.karat21.fg,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '18K',
                        value: k18,
                        color: _tones.karat18.fg,
                        total: total,
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildKaratLegendItem({
    required String label,
    required double value,
    required Color color,
    required double total,
  }) {
    final pct = total > 0 ? (value / total * 100).toStringAsFixed(0) : '0';
    return Padding(
      padding: EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              '$label: ${_formatWeight(value)} • $pct%',
              style: TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // Liquidity Breakdown Card
  /// Cash, banks, and what the customers owe us -- from «لنا وعلينا»
  /// (DASH-4), said once its reading is here (DASH-10).
  Widget _buildLiquidityBreakdownCard(Map<String, dynamic> liquidity, {double? receivables}) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final cashInHand = _asDouble(liquidity['cash_in_hand']);
    final cashInBanks = _asDouble(liquidity['cash_in_banks']);
    final total = cashInHand + cashInBanks + (receivables ?? 0);

    return _buildKpiCardWrapper(
      onTap: () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.water_drop, color: _tones.info.fg, size: 20),
              SizedBox(width: 6),
              Text(
                isArabic ? 'مركز السيولة' : 'Liquidity',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          _buildLiquidityRow(
            isArabic ? 'نقدية' : 'Cash',
            cashInHand,
            _tones.ready.fg,
            total,
          ),
          SizedBox(height: 4),
          _buildLiquidityRow(
            isArabic ? 'بنوك' : 'Banks',
            cashInBanks,
            _tones.info.fg,
            total,
          ),
          if (receivables != null) ...[
            SizedBox(height: 4),
            _buildLiquidityRow(
              isArabic ? 'ذمم' : 'Receiv.',
              receivables,
              _tones.warning.fg,
              total,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLiquidityRow(
    String label,
    double value,
    Color color,
    double total,
  ) {
    final pct = total > 0 ? value / total : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: 11)),
            _currencyAwareText(
              _formatCurrency(value),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 4,
            backgroundColor: color.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _miniStatChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 11, color: color),
          SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 9, color: theme.hintColor),
                  overflow: TextOverflow.ellipsis,
                ),
                _currencyAwareText(
                  value,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: color,
                    letterSpacing: -0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The period's sales, purchases and operating expenses, and the cash on
  /// hand -- as the server says them, nothing subtracted. It was «صافي الربح»
  /// = sales - purchases - every 5-account: a loss of 21 million for 2026,
  /// stock counted twice (the owner, 11 Oct 2026: the gram profit beside it is
  /// the dashboard's profit).
  Widget _buildPeriodMovementCard(
    Map<String, dynamic> liquidity,
    Map<String, dynamic> salesPurchasesSummary,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final isArabic = widget.isArabic;
    final period = (salesPurchasesSummary[_summaryPeriod] as Map<String, dynamic>?) ?? {};
    double value(String key) => _asDouble(((period[key] as Map<String, dynamic>?) ?? {})['total_value']);
    double weight(String key) => _asDouble(((period[key] as Map<String, dynamic>?) ?? {})['total_weight']);
    final sales = value('sales');
    // Three purchases, apart (DASH-3, the owner 30 Oct 2026): a supplier's new
    // gold, a customer's scrap, an office's settlement.
    final purchases = value('purchases');
    final scrap = value('scrap_customers');
    final settlements = value('office_settlements');
    final expenses = value('expenses');
    final cash = _asDouble(liquidity['cash_available']);
    final label = switch (_timeRange) {
      _TimeRange.today => isArabic ? 'اليوم' : 'Today',
      _TimeRange.month => isArabic ? 'الشهر' : 'Month',
      _TimeRange.year => isArabic ? 'السنة' : 'Year',
    };

    // Its weight beside its amount, set apart, in columns (the owner, 30-31 Oct 2026).
    DashboardAmountRow row(String name, double amount, Color color, [double grams = 0]) => DashboardAmountRow(
          label: Text(name, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          amount: _currencyAwareText(
            _formatCurrency(amount),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          weight: grams.abs() >= 0.0005 ? _formatWeight(grams) : null,
        );

    return Container(
      key: const Key('dashboard-period-movement'),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isArabic ? 'حركة $label' : '$label activity',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          if (sales == 0 && purchases == 0 && scrap == 0 && settlements == 0 && expenses == 0)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(isArabic ? 'لا توجد عمليات بعد' : 'No activity yet',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: DashboardAmountTable(
                rowPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                rows: [
                  row(isArabic ? 'المبيعات' : 'Sales', sales, tones.ready.fg, weight('sales')),
                  row(isArabic ? 'شراء جديد (موردون)' : 'New gold (suppliers)', purchases, tones.cash.fg,
                      weight('purchases')),
                  row(isArabic ? 'شراء كسر (عملاء)' : 'Scrap (customers)', scrap, tones.cash.fg,
                      weight('scrap_customers')),
                  row(isArabic ? 'تسكيرات (مكاتب)' : 'Settlements (offices)', settlements, tones.cash.fg,
                      weight('office_settlements')),
                  row(isArabic ? 'المصروفات التشغيلية' : 'Operating expenses', expenses, tones.warning.fg,
                      weight('expenses')),
                ],
              ),
            ),
          Divider(height: 20, color: scheme.outlineVariant),
          DashboardAmountTable(
            rowPadding: EdgeInsets.zero,
            rows: [row(isArabic ? 'السيولة الآن' : 'Cash now', cash, scheme.onSurface)],
          ),
        ],
      ),
    );
  }

  Widget _buildGramProfitKpi() {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    if (_gramProfitLoading && _gramProfitData == null) {
      return const DashboardPanelSkeleton(lines: 3);
    }

    final g = _gramProfitData;
    if (g == null) return const SizedBox.shrink();

    double gd(String k) => (g[k] is num) ? (g[k] as num).toDouble() : 0.0;

    final netProfit = gd('net_profit');
    final netProfitWeight = gd('net_profit_weight');
    final avgSell = gd('avg_sell_per_gram');
    final avgBuy = gd('avg_buy_per_gram');
    final marginPerGram = gd('margin_per_gram');
    final netMarginPct = gd('net_margin_pct');
    final weightSold = gd('weight_sold');

    final mainKarat =
        '${g['main_karat'] ?? context.read<SettingsProvider>().mainKarat}';
    final isProfit = netProfitWeight >= 0;

    final isAllZero = netProfitWeight == 0 &&
        weightSold == 0 &&
        avgSell == 0 &&
        avgBuy == 0;

    // Dynamic period label
    final String periodLabel;
    switch (_timeRange) {
      case _TimeRange.today:
        periodLabel = isArabic ? 'اليوم' : 'Today';
        break;
      case _TimeRange.month:
        periodLabel = isArabic ? 'هذا الشهر' : 'This month';
        break;
      case _TimeRange.year:
        periodLabel = isArabic ? 'هذه السنة' : 'This year';
        break;
    }

    // unavailable_reason هو مصدر الحقيقة — يُفحص قبل isAllZero
    final unavailableReason = g['unavailable_reason'] as String?;
    if (unavailableReason != null) {
      final reasonText = {
        'no_cash_purchases': isArabic
            ? 'لا مشتريات نقدية في هذه الفترة'
            : 'No cash purchases in this period',
        'avg_buy_out_of_range': isArabic
            ? 'متوسط الشراء خارج النطاق المتوقع'
            : 'Avg buy out of expected range',
      }[unavailableReason] ??
          (isArabic ? 'بيانات غير كافية' : 'Insufficient data');
      final wSold = weightSold.toStringAsFixed(3);
      final salesStr = _formatCurrency(gd('total_sales_cash'));
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _scheme.primary.withValues(alpha: 0.20),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _tones.warning.container,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.warning_amber_rounded,
                color: _tones.warning.fg,
                size: 24,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        isArabic ? 'ربح الجرام الذهبي' : 'Gold Gram Profit',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: _scheme.primary,
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          periodLabel,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: _scheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 3),
                  Text(
                    isArabic
                        ? 'غير محسوب — $reasonText'
                        : 'Unavailable — $reasonText',
                    style: TextStyle(
                      fontSize: 11,
                      color: _tones.warning.fg,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    isArabic
                        ? '$wSold جم مباعة  •  $salesStr مبيعات'
                        : '$wSold g sold  •  $salesStr sales',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (isAllZero) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _scheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _scheme.primary.withValues(alpha: 0.20),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.auto_graph,
                color: _scheme.primary,
                size: 24,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        isArabic ? 'ربح الجرام الذهبي' : 'Gold Gram Profit',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: _scheme.primary,
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _scheme.primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          periodLabel,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            color: _scheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: theme.hintColor,
                      ),
                      SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          isArabic
                              ? 'في انتظار أول عملية بيع لحساب الربح'
                              : 'Awaiting first sale to calculate profit',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  isArabic ? 'الربح' : 'Profit',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.hintColor,
                  ),
                ),
                _currencyAwareText(
                  '0 $_currencySymbol',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: theme.hintColor.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final profitColor = isProfit ? _tones.ready.fg : _scheme.error;
    // ⑤ of it: how the riyals still waiting moved with the price (ADR-048).
    final priceEffect = gd('price_effect_weight');

    return InkWell(
      key: const ValueKey('gram-profit-card'),
      borderRadius: BorderRadius.circular(14),
      // Its details are the income statement's gram profit, on the same period --
      // the weight close has its own card (the owner, 30 Oct 2026).
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => IncomeStatementReportScreen(
              api: widget.api, isArabic: isArabic, initialRange: _gramProfitRange()))),
      child: Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _scheme.primary.withValues(alpha: 0.20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.auto_graph,
                  color: _scheme.primary,
                  size: 16,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  isArabic ? 'ربح الجرام الذهبي' : 'Gold Gram Profit',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _scheme.primary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  periodLabel,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: _scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          // Hero: Weight + karat + ≈Cash + Margin
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatWeight(netProfitWeight)
                            .replaceAll(' جم', '')
                            .replaceAll(' g', ''),
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: profitColor,
                          fontSize: 22,
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(width: 4),
                      Padding(
                        padding: EdgeInsets.only(bottom: 3),
                        child: Text(
                          isArabic
                              ? 'جم ($mainKarat)'
                              : 'g (k$mainKarat)',
                          style: TextStyle(
                            color: profitColor.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: profitColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _currencyAwareText(
                  '≈ ${_formatCurrency(netProfit)}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: profitColor,
                  ),
                ),
              ),
              SizedBox(width: 4),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: profitColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${netMarginPct.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: profitColor,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          // 4 chips
          Row(
            children: [
              Expanded(
                child: _miniStatChip(
                  icon: Icons.trending_up,
                  label: isArabic ? 'بيع/جم' : 'Sell/g',
                  value: _formatCurrency(avgSell)
                      .replaceAll(_currencySymbol, '')
                      .trim(),
                  color: _tones.ready.fg,
                ),
              ),
              SizedBox(width: 6),
              Expanded(
                child: _miniStatChip(
                  icon: Icons.trending_down,
                  label: isArabic ? 'شراء/جم' : 'Buy/g',
                  value: _formatCurrency(avgBuy)
                      .replaceAll(_currencySymbol, '')
                      .trim(),
                  color: _tones.warning.fg,
                ),
              ),
              SizedBox(width: 6),
              Expanded(
                child: _miniStatChip(
                  icon: Icons.swap_horiz,
                  label: isArabic ? 'فارق/جم' : 'Margin/g',
                  value: _formatCurrency(marginPerGram)
                      .replaceAll(_currencySymbol, '')
                      .trim(),
                  color: marginPerGram >= 0
                      ? _tones.ready.fg
                      : _scheme.error,
                ),
              ),
              SizedBox(width: 6),
              Expanded(
                child: _miniStatChip(
                  icon: Icons.monitor_weight_outlined,
                  label: isArabic ? 'المباع' : 'Sold',
                  value: _formatWeight(weightSold)
                      .replaceAll(' جم', '')
                      .replaceAll(' g', ''),
                  color: _tones.info.fg,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            isArabic
                ? 'منه أثر السعر على ما لم يُسكَّر: ${_formatWeight(priceEffect)} — اضغط لمركز التسكير'
                : 'Of which the price on what still waits: ${_formatWeight(priceEffect)} — tap for the position',
            key: const ValueKey('gram-profit-price-effect'),
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ],
      ),
    ),
    );
  }

  // _buildTodayProfitCard removed (unused).
  // ignore: unused_element
  Widget _buildTodayProfitCard(Map<String, dynamic> kpis) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final todayProfit = _asDouble(kpis['today_profit']);
    final profitMargin = kpis['today_profit_margin_pct'];
    final marginValue = profitMargin is num ? profitMargin.toDouble() : null;

    final isPositive = todayProfit >= 0;

    return _buildKpiCardWrapper(
      onTap: () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPositive ? Icons.trending_up : Icons.trending_down,
                color: isPositive ? _tones.ready.fg : _scheme.error,
                size: 20,
              ),
              SizedBox(width: 6),
              Text(
                isArabic ? 'هامش الربح اليوم' : 'Today Profit',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          _currencyAwareText(
            _formatCurrency(todayProfit),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: isPositive ? _tones.ready.fg : _scheme.error,
              fontSize: 20,
            ),
          ),
          if (marginValue != null)
            Container(
              margin: EdgeInsets.only(top: 4),
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: (isPositive ? _tones.ready.fg : _scheme.error).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${marginValue.toStringAsFixed(1)}% ${isArabic ? "هامش" : "margin"}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isPositive ? _tones.ready.fg : _scheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKpiCardWrapper({required Widget child, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      // The panels' look (DASH-10): the surface a step above the page, a hairline.
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: _scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: _scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: child,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 4. VAULTS & CUSTODY (Horizontal List)
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildVaultsSection(List<dynamic> safeBoxes) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    if (safeBoxes.isEmpty) return const SizedBox.shrink();

    final anyExpanded = _expandedVaultSafeBoxId != null;
    // Give cards enough vertical room to avoid RenderFlex overflow.
    final listHeight = anyExpanded ? 260.0 : 168.0;
    final sorted = _sortedVaults(safeBoxes);

    Widget buildCard(int index, Map<String, dynamic> sb, {bool reorderMode = false}) {
      final id = sb['id'];
      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
      final heroTag = sbId != null ? 'vault_safe_box_$sbId' : 'vault_safe_box_$index';
      final isExpanded = (sbId != null && sbId == _expandedVaultSafeBoxId);
      final isPressed = (sbId != null && sbId == _pressedVaultSafeBoxId);

      return _buildVaultCard(
        sb,
        heroTag: heroTag,
        isExpanded: isExpanded,
        isPressed: isPressed,
        reorderMode: reorderMode,
        onTap: () {
          if (sbId == null) return;
          setState(() {
            _expandedVaultSafeBoxId = isExpanded ? null : sbId;
          });
        },
        onOpenDetails: () {
          if (sbId != null) {
            setState(() => _recentVaultIds.add(sbId));
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SafeBoxHeroDetailsScreen(
                api: widget.api,
                isArabic: widget.isArabic,
                safeBox: sb,
                heroTag: heroTag,
              ),
            ),
          );
        },
        onPressChanged: (pressed) {
          if (sbId == null) return;
          setState(() {
            if (pressed) {
              _pressedVaultSafeBoxId = sbId;
            } else if (_pressedVaultSafeBoxId == sbId) {
              _pressedVaultSafeBoxId = null;
            }
          });
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(
                Icons.inventory_2,
                color: theme.colorScheme.primary,
                size: 22,
              ),
              SizedBox(width: 8),
              Text(
                isArabic ? 'توزيع العهد والخزائن' : 'Vaults & Custody',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // Reorder toggle
              Tooltip(
                message: _isReorderingVaults
                    ? (isArabic ? 'تم الترتيب' : 'Done')
                    : (isArabic ? 'إعادة ترتيب' : 'Reorder'),
                child: IconButton(
                  icon: Icon(
                    _isReorderingVaults ? Icons.check_circle_outline : Icons.swap_horiz,
                    size: 20,
                    color: _isReorderingVaults
                        ? theme.colorScheme.primary
                        : theme.hintColor,
                  ),
                  onPressed: () => setState(() => _isReorderingVaults = !_isReorderingVaults),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SafeBoxesScreen(
                        api: widget.api,
                      ),
                    ),
                  );
                },
                child: Text(isArabic ? 'عرض الكل' : 'View all'),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        SizedBox(
          height: listHeight,
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final offset = (_vaultScrollController.offset +
                    event.scrollDelta.dy * 1.5)
                    .clamp(0.0,
                        _vaultScrollController.position.maxScrollExtent);
                _vaultScrollController.jumpTo(offset);
              }
            },
            child: _isReorderingVaults
                ? ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    scrollController: _vaultScrollController,
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    itemCount: sorted.length,
                    onReorder: (oldIndex, newIndex) {
                      setState(() {
                        if (newIndex > oldIndex) newIndex--;
                        final item = sorted.removeAt(oldIndex);
                        sorted.insert(newIndex, item);
                        // Rebuild _vaultOrder from reordered list
                        _vaultOrder = sorted
                            .map((sb) {
                              final id = sb['id'];
                              return id is int
                                  ? id
                                  : int.tryParse(id?.toString() ?? '');
                            })
                            .whereType<int>()
                            .toList();
                      });
                      _saveVaultOrder();
                    },
                    itemBuilder: (context, index) {
                      final sb = sorted[index];
                      final id = sb['id'];
                      final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
                      return KeyedSubtree(
                        key: ValueKey(sbId ?? index),
                        child: buildCard(index, sb, reorderMode: true),
                      );
                    },
                  )
                : AnimationLimiter(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      controller: _vaultScrollController,
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      itemCount: sorted.length,
                      itemBuilder: (context, index) {
                        final sb = sorted[index];
                        return AnimationConfiguration.staggeredList(
                          position: index,
                          duration: const Duration(milliseconds: 420),
                          child: SlideAnimation(
                            verticalOffset: 18.0,
                            child: FadeInAnimation(
                              child: buildCard(index, sb),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  double _sbWeight(Map<String, dynamic> sb, String key) {
    final wb = sb['weight_balance'];
    if (wb is Map) {
      final raw = wb[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }
    return 0.0;
  }

  Widget _buildVaultCard(
    Map<String, dynamic> sb, {
    required String heroTag,
    required bool isExpanded,
    required bool isPressed,
    required VoidCallback onTap,
    required VoidCallback onOpenDetails,
    required ValueChanged<bool> onPressChanged,
    bool reorderMode = false,
  }) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final name = sb['name'] ?? '-';
    final safeType = sb['safe_type'] ?? 'cash';
    final cashBalance = _asDouble(sb['balance_cash']);
    final goldBalance = _asDouble(sb['balance_gold_21k']);
    final hasActivity = sb['has_recent_activity'] == true;

    final w18 = _sbWeight(sb, '18k');
    final w21 = _sbWeight(sb, '21k');
    final w22 = _sbWeight(sb, '22k');
    final w24 = _sbWeight(sb, '24k');
    final totalMain = _asDouble(sb['total_weight_main_karat']);
    final hasWeightBreakdown = sb['weight_balance'] is Map;
    final mainKaratFromApi = _asInt(sb['main_karat']);
    final displayMainKarat = mainKaratFromApi > 0
        ? mainKaratFromApi
        : context.read<SettingsProvider>().mainKarat;

    double totalMainFallback() {
      // Every karat by its fineness -- 21 too: it was added as it was, as if
      // the main karat were always 21.
      return goldInMainKarat({18: w18, 21: w21, 22: w22, 24: w24}, displayMainKarat);
    }

    final totalMainEffective = (totalMain > 0)
        ? totalMain
        : (hasWeightBreakdown ? totalMainFallback() : 0.0);

    final physicalTotal = hasWeightBreakdown ? (w18 + w21 + w22 + w24) : 0.0;

    IconData icon;
    Color color;
    String subtitle;
    double primaryValue;
    String Function(double) primaryFormatter;
    String? primaryCaption;

    switch (safeType) {
      case 'gold':
        icon = Icons.auto_awesome;
        color = _scheme.primary;
        // Collapsed: show main-karat equivalent (dynamic main karat).
        // Expanded: show physical total across all karats.
        primaryValue = isExpanded ? physicalTotal : totalMainEffective;
        primaryFormatter = _formatWeight;
        subtitle = isArabic ? 'ذهب' : 'Gold';
        primaryCaption = isExpanded
            ? (isArabic
                ? 'إجمالي فعلي (جميع العيارات)'
                : 'Physical total (all karats)')
            : (isArabic
                ? 'مكافئ العيار الرئيسي (${displayMainKarat}k)'
                : 'Main karat equivalent (${displayMainKarat}k)');
        break;
      case 'bank':
        icon = Icons.account_balance;
        color = _tones.info.fg;
        primaryValue = cashBalance;
        primaryFormatter = _formatCurrency;
        subtitle = isArabic ? 'بنك' : 'Bank';
        break;
      default:
        icon = Icons.account_balance_wallet;
        color = _tones.ready.fg;
        primaryValue = cashBalance;
        primaryFormatter = _formatCurrency;
        subtitle = isArabic ? 'نقد' : 'Cash';
    }

    final cardWidth = isExpanded ? 290.0 : 172.0;

    Widget buildDetailChip(String label, String value, {Color? chipColor}) {
      final c = chipColor ?? color;
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: _currencyAwareText(
          '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: _scheme.onSurface,
          ),
        ),
      );
    }

    final details = safeType == 'gold'
        ? (hasWeightBreakdown
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  buildDetailChip('24k', _formatWeight(w24), chipColor: _tones.karat24.fg),
                  buildDetailChip('22k', _formatWeight(w22), chipColor: _tones.karat22.fg),
                  buildDetailChip('21k', _formatWeight(w21), chipColor: _tones.karat21.fg),
                  buildDetailChip('18k', _formatWeight(w18), chipColor: _tones.karat18.fg),
                ],
              )
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  buildDetailChip('21k', _formatWeight(goldBalance), chipColor: _tones.karat21.fg),
                  buildDetailChip(
                    isArabic ? 'ملاحظة' : 'Note',
                    isArabic
                        ? 'تفصيل العيارات غير متوفر بعد'
                        : 'Karat breakdown not available yet',
                    chipColor: theme.hintColor,
                  ),
                ],
              ))
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              buildDetailChip(
                isArabic ? 'الرصيد' : 'Balance',
                _formatCurrency(cashBalance),
                chipColor: color,
              ),
            ],
          );

    final borderAccent = hasActivity ? _tones.ready.fg : theme.hintColor;
    final borderColor = borderAccent.withValues(alpha: hasActivity ? 0.55 : 0.25);

    final heroIconTag = '${heroTag}_icon';
    final heroNameTag = '${heroTag}_name';

    final cardBody = Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTapDown: (_) => onPressChanged(true),
            onTapCancel: () => onPressChanged(false),
            onTap: () {
              onPressChanged(false);
              onTap();
            },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              scale: isPressed ? 0.985 : 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                width: cardWidth,
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: borderColor,
                    width: isPressed ? 1.2 : 1.0,
                  ),
                  color: _scheme.surface,
                ),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      start: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 4,
                        decoration: BoxDecoration(
                          color: color.withValues(
                            alpha: hasActivity ? 0.85 : 0.55,
                          ),
                          borderRadius: BorderRadiusDirectional.horizontal(
                            start: Radius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.only(start: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Hero(
                                tag: heroIconTag,
                                createRectTween: (begin, end) =>
                                    MaterialRectArcTween(begin: begin, end: end),
                                child: Material(
                                  color: Colors.transparent,
                                  child: Icon(
                                    icon,
                                    color: color,
                                    size: 20,
                                  ),
                                ),
                              ),
                              SizedBox(width: 6),
                              if (hasActivity)
                                Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    color: _tones.ready.fg,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              const Spacer(),
                              InkResponse(
                                onTap: () {
                                  onPressChanged(false);
                                  onOpenDetails();
                                },
                                radius: 18,
                                child: Icon(
                                  Icons.open_in_new,
                                  color: theme.hintColor,
                                  size: 18,
                                ),
                              ),
                              SizedBox(width: 6),
                              AnimatedRotation(
                                turns: isExpanded ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: Icon(
                                  Icons.expand_more,
                                  color: theme.hintColor,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Hero(
                            tag: heroNameTag,
                            createRectTween: (begin, end) =>
                                MaterialRectArcTween(begin: begin, end: end),
                            child: Material(
                              color: Colors.transparent,
                              child: Text(
                                name,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (!isExpanded) const Spacer(),
                          SizedBox(height: 10),
                          if (primaryCaption != null) ...[
                            Text(
                              primaryCaption,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 10.5,
                                color: theme.hintColor,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            SizedBox(height: 6),
                          ],
                          _AnimatedValueText(
                            value: primaryValue,
                            formatter: primaryFormatter,
                            isNewSar: _currencyIsNewSar,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: color,
                              fontSize: 14,
                            ),
                          ),
                          AnimatedCrossFade(
                            firstChild: const SizedBox.shrink(),
                            secondChild: Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: details,
                            ),
                            crossFadeState: isExpanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 240),
                            firstCurve: Curves.easeOut,
                            secondCurve: Curves.easeOutCubic,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ),
    );

    return Container(
      margin: EdgeInsetsDirectional.only(start: 12),
      child: cardBody,
    );
  }
}

class _StickyRangeSelectorDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final Color backgroundColor;
  final double height;
  final double horizontalPadding;
  final double verticalPadding;

  _StickyRangeSelectorDelegate({
    required this.child,
    required this.backgroundColor,
    required this.height,
    required this.horizontalPadding,
    required this.verticalPadding,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final isScrolled = overlapsContent || shrinkOffset > 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        verticalPadding,
        horizontalPadding,
        verticalPadding,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: isScrolled
            ? Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
                ),
              )
            : null,
      ),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _StickyRangeSelectorDelegate oldDelegate) {
    return oldDelegate.child != child ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.height != height ||
        oldDelegate.horizontalPadding != horizontalPadding ||
        oldDelegate.verticalPadding != verticalPadding;
  }
}

class _AnimatedValueText extends StatefulWidget {
  final double value;
  final String Function(double) formatter;
  final bool isNewSar;
  final TextStyle? style;

  const _AnimatedValueText({
    required this.value,
    required this.formatter,
    this.isNewSar = false,
    this.style,
  });

  @override
  State<_AnimatedValueText> createState() => _AnimatedValueTextState();
}

class _AnimatedValueTextState extends State<_AnimatedValueText> {
  late double _from;
  late double _to;

  @override
  void initState() {
    super.initState();
    _from = 0.0;
    _to = widget.value;
  }

  @override
  void didUpdateWidget(covariant _AnimatedValueText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _from = _to;
      _to = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: _from, end: _to),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return cu.SarAwareText(
          widget.formatter(v),
          isNewSar: widget.isNewSar,
          style: widget.style,
        );
      },
      onEnd: () {
        _from = _to;
      },
    );
  }
}


/// The pills' shape while what needs the manager is on the way (DASH-10).
class _PillsSkeleton extends StatelessWidget {
  const _PillsSkeleton();

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7);
    Widget pill(double width) => Container(
          width: width,
          height: 32,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(AppRadius.pill)),
        );
    return Semantics(
      label: 'جارٍ التحميل',
      child: Wrap(spacing: AppSpace.sm, children: [pill(120), pill(150)]),
    );
  }
}
