
import 'package:flutter/material.dart';
import 'income_statement_report_screen.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../utils/bidi.dart';
import 'package:provider/provider.dart';

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
import 'gold_by_place_report_screen.dart';
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
  /// The theme's type scale: every size on this screen is one of its steps
  /// (15 Nov 2026: 34 sizes were written as numbers; tests/…type_scale holds it).
  TextTheme get _type => Theme.of(context).textTheme;

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
  /// Each period's gram profit as last read: a period read once shows at once
  /// when chosen again, and is read anew behind it (the owner, 16 Nov 2026:
  /// «تبديل الفترات صار يأخذ وقت اطول» -- the card emptied on every switch).
  final Map<_TimeRange, Map<String, dynamic>> _gramProfitByPeriod = {};
  Map<String, dynamic>? get _gramProfitData => _gramProfitByPeriod[_timeRange];
  // The month's race, by points -- its own reading (DASH-9).
  List<Map<String, dynamic>> _leaders = const [];
  /// The gram profit's one request in flight, and its period: a new period ends it.
  ApiCancelToken? _gramProfitRequest;
  _TimeRange? _gramProfitRequestPeriod;
  bool get _gramProfitLoading => _gramProfitRequest != null && _gramProfitRequestPeriod == _timeRange;

  /// The safes holding nothing, shown on a tap (15 Nov 2026: 20 safes, more
  /// than half of them empty, pushed the ones that hold something aside).
  bool _showEmptyVaults = false;

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
    _gramProfitRequest?.cancel();
    super.dispose();
  }

  /// The safes in one order, the same every time (the owner, 15 Nov 2026:
  /// «احذف وطبق الترتيب التلقائي» -- the grid shows them all; a hand-kept
  /// order, and one that moved a safe opened lately to the front, are gone):
  /// the cash first -- the safes, then the banks -- the largest balance
  /// first; then the gold, the most grams first; the name breaks a tie.
  List<Map<String, dynamic>> _sortedVaults(List<dynamic> raw) {
    const kinds = {'cash': 0, 'bank': 1, 'gold': 2};
    double size(Map<String, dynamic> sb) => sb['safe_type'] == 'gold'
        ? _asDouble(sb['total_weight_main_karat'])
        : _asDouble(sb['balance_cash']);
    return raw.whereType<Map<String, dynamic>>().toList()
      ..sort((a, b) {
        final kind = (kinds[a['safe_type']] ?? 3).compareTo(kinds[b['safe_type']] ?? 3);
        if (kind != 0) return kind;
        final bySize = size(b).compareTo(size(a));
        if (bySize != 0) return bySize;
        return '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}');
      });
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
  DateTimeRange _gramProfitRange([_TimeRange? period]) {
    final now = DateTime.now();
    final start = switch (period ?? _timeRange) {
      _TimeRange.today => DateTime(now.year, now.month, now.day),
      _TimeRange.month => DateTime(now.year, now.month, 1),
      _TimeRange.year => DateTime(now.year, 1, 1),
    };
    return DateTimeRange(start: start, end: now);
  }

  /// Reads [period]'s gram profit -- the period shown when none is named. One
  /// request at a time: a new one ends the last at once (the owner, 15 Nov
  /// 2026: «ينهي طلب الفترة السابقة فورا ويبدا بمهمته»); a late answer of a
  /// request ended changes nothing. Once answered, the periods not read yet
  /// follow, one after another, so a switch finds its figures there.
  Future<void> _loadGramProfit([_TimeRange? period]) async {
    final p = period ?? _timeRange;
    _gramProfitRequest?.cancel();
    final request = ApiCancelToken();
    _gramProfitRequest = request;
    _gramProfitRequestPeriod = p;
    if (mounted) setState(() {});
    var answered = false;
    try {
      final range = _gramProfitRange(p);
      final data = await widget.api.getGramProfitReport(
        startDate: range.start,
        endDate: range.end,
        cancel: request,
      );
      if (mounted && identical(request, _gramProfitRequest)) {
        setState(() => _gramProfitByPeriod[p] = data);
        answered = true;
      }
    } catch (e) {
      if (!request.isCancelled) debugPrint('❌ Gram profit load error: $e');
    } finally {
      if (identical(request, _gramProfitRequest)) {
        _gramProfitRequest = null;
        _gramProfitRequestPeriod = null;
        request.cancel(); // its connection, closed
        if (mounted) setState(() {});
      }
    }
    if (!answered || !mounted || _gramProfitRequest != null) return;
    for (final next in _TimeRange.values) {
      if (!_gramProfitByPeriod.containsKey(next)) {
        _loadGramProfit(next);
        return;
      }
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
            style: TextStyle(fontSize: _type.headlineSmall?.fontSize, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: hintColor, fontSize: _type.bodySmall?.fontSize),
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
    // null: the safes could not be read -- said so, not «لا يوجد ذهب» (15 Nov 2026)
    final goldByKarat = kpis['gold_by_karat'] as Map<String, dynamic>?;

    // Where the business stands (DASH-10): each panel its grey shape while
    // its reading is on the way, and nothing where the reading has nothing.
    final standing = _standing;
    Map<String, dynamic> part(String key) => (standing?[key] as Map<String, dynamic>?) ?? {};
    final waiting = standing == null && _standingLoading;
    final positions = part('positions');
    final clearing = part('clearing');
    final vat = part('vat');
    final deficits = part('deficits');

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
      if (waiting)
        const DashboardPanelSkeleton(lines: 3)
      else
        _buildLiquidityPanel(),
      // what is about to leave, beside what is held (15 Nov 2026)
      if (waiting)
        const DashboardPanelSkeleton(lines: 4)
      else if (standing != null)
        DashboardUpcomingPanel(
            upcoming: standing['upcoming'] as Map<String, dynamic>?, isArabic: isArabic, money: _money),
      if (!waiting && standing != null)
        DashboardHealthPanel(health: standing['health'] as Map<String, dynamic>?, isArabic: isArabic),
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
                  if (((_response?['series'] as Map?)?['daily'] as List?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: AppSpace.md),
                    DashboardWeek(
                      days: [
                        for (final d in ((_response!['series'] as Map)['daily'] as List).whereType<Map>())
                          Map<String, dynamic>.from(d),
                      ],
                      money: _money,
                      isArabic: isArabic,
                    ),
                  ],
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
    // The selector beside the title, at its side (the owner, 15 Nov 2026:
    // «ازرار فترات الاداء اليس من الافضل ان تكون جهة العنوان وليس بالمنتصف»;
    // on 30 Oct it had been drawn to the middle). On a phone, under it.
    if (!isNarrow) {
      return DashboardSection(
        title: isArabic ? 'الأداء' : 'Performance',
        subtitle: isArabic ? 'ما تغيّره الفترة' : 'What the period changes',
        beside: selector,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [head, const SizedBox(height: AppSpace.sm), selector],
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

    // What the shop has less what it owes (the owner, 15 Nov 2026: «اودع وابني») --
    // the standing's, beside the dashboard: «…» while it is on its way.
    final standingNet = _standing?['net_position'] as Map<String, dynamic>?;
    final net = standingNet?['net'];
    final netPosition = net is num ? net.toDouble() : null;
    final netWaiting = _standing == null && _standingLoading;
    final breakdown = standingNet == null
        ? null
        : (isArabic ? 'نملك ' : 'Has ') +
            ltrIsolate(_formatCurrency(_asDouble(standingNet['has']))) +
            (isArabic ? ' · علينا ' : ' · owes ') +
            ltrIsolate(_formatCurrency(_asDouble(standingNet['owes'])));
    // The price the gold is valued at, and when it was saved: a weekend's
    // position stands on Friday's price, and says so.
    final price = standingNet?['price'];
    final priceAt = DateTime.tryParse('${standingNet?['price_at'] ?? ''}');
    final valuedAt = price is num
        ? (isArabic ? 'الذهب بسعر عيار ${standingNet!['main_karat']}: ' : 'Gold at ${standingNet!['main_karat']}K: ') +
            ltrIsolate(_formatCurrency(price.toDouble())) +
            (priceAt == null ? '' : ' · ${ltrIsolate(DateFormat('dd/MM HH:mm').format(priceAt))}')
        : null;
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
        builder: (_) => GoldPriceHistoryReportScreen(api: widget.api),
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
                isArabic ? 'لوحة التحكم' : 'Dashboard',
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
                  _buildNetPositionCard(theme, isArabic, netPosition, valuedAt,
                      breakdown: breakdown, waiting: netWaiting, isWide: constraints.maxWidth >= 500),
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
                    child: _buildNetPositionCard(theme, isArabic, netPosition, valuedAt,
                        breakdown: breakdown, waiting: netWaiting, isWide: netWidth >= 500),
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
    double? netPosition,
    String? valuedAt, {
    String? breakdown,
    bool waiting = false,
    required bool isWide,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final isPositive = (netPosition ?? 0) >= 0;
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
                        fontSize: _type.bodySmall?.fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: _currencyAwareText(
                        netPosition != null
                            ? _formatCurrency(netPosition)
                            : waiting
                                ? '…'
                                : (isArabic ? 'غير متاح' : 'Not available'),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                          fontSize: _type.headlineMedium?.fontSize,
                        ),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      isArabic ? 'ما نملك − ما علينا' : 'What we have − what we owe',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                    if (breakdown != null)
                      Text(
                        breakdown,
                        key: const Key('dashboard-net-breakdown'),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                      ),
                    if (valuedAt != null)
                      Text(
                        valuedAt,
                        key: const Key('dashboard-net-valued-at'),
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
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
                  value: _liquidityText,
                  color: _tones.invoiceSaleScrap.fg,
                ),
                SizedBox(width: 20),
                _buildSnapshotMiniStat(
                  theme: theme,
                  icon: Icons.auto_awesome,
                  label: isArabic ? 'وزن الذهب' : 'Gold Weight',
                  value: switch ((_response?['kpis'] as Map?)?['gold_equivalent_main_karat']) {
                    final num grams => _formatWeight(grams.toDouble()),
                    _ => isArabic ? 'غير متاح' : 'Not available',
                  },
                  color: _scheme.primary,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The liquidity, one reading for every place that says «السيولة» (the
  /// owner, 14 Nov 2026: «في الطريق يكون صافي وطابق السيوله في الرأس»): the
  /// safes, the banks, and what the card companies are bringing net of their
  /// commissions. A part is null while not read -- the standing on its way, or
  /// a reading that failed.
  (double?, double?, double?) get _liquidityParts {
    final liquidity = (_response?['liquidity'] as Map?) ?? const {};
    double? read(dynamic v) => v is num ? v.toDouble() : null;
    final standing = _standing;
    final transit = standing == null ? null : read(((standing['clearing'] as Map?) ?? const {})['total_net']);
    return (read(liquidity['cash_in_hand']), read(liquidity['cash_in_banks']), transit);
  }

  double? get _liquidityWhole {
    final (safes, banks, transit) = _liquidityParts;
    return safes == null || banks == null || transit == null ? null : safes + banks + transit;
  }

  /// The whole as said where it is a figure: «…» while the standing is on its
  /// way, «غير متاح» when a part could not be read.
  String get _liquidityText {
    final whole = _liquidityWhole;
    if (whole != null) return _formatCurrency(whole);
    final (safes, banks, _) = _liquidityParts;
    final onItsWay = _standing == null && _standingLoading && safes != null && banks != null;
    return onItsWay ? '…' : (widget.isArabic ? 'غير متاح' : 'Not available');
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
                fontSize: _type.labelSmall?.fontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        _currencyAwareText(
          value,
          style: TextStyle(
            fontSize: _type.titleMedium?.fontSize,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  /// The karats held, a bar each; a tap opens «الذهب حسب مكانه» -- where
  /// each karat is (15 Nov 2026: it led nowhere). *goldByKarat* null: the
  /// safes could not be read.
  Widget _buildKaratDistributionCard(Map<String, dynamic>? goldByKarat) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;
    final read = goldByKarat != null;

    final k18 = _asDouble(goldByKarat?['18k']);
    final k21 = _asDouble(goldByKarat?['21k']);
    final k22 = _asDouble(goldByKarat?['22k']);
    final k24 = _asDouble(goldByKarat?['24k']);
    final total = k18 + k21 + k22 + k24;
    final karats = [(24, k24), (22, k22), (21, k21), (18, k18)];

    return _buildKpiCardWrapper(
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => GoldByPlaceReportScreen(api: widget.api))),
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
                  fontSize: _type.bodySmall?.fontSize,
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          if (!read || total == 0)
            Center(
              child: Text(
                !read ? (isArabic ? 'غير متاح' : 'Not available') : (isArabic ? 'لا يوجد ذهب' : 'No gold'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            )
          else
            // A bar a karat, the largest first: a length compares where an angle
            // does not, and a karat held a sliver is a whole line still (the
            // owner, 14 Nov 2026: «ابنها»).
            KaratBars(
              key: const Key('karat-mix-chart'),
              shares: [for (final (karat, grams) in karats) KaratShare(karat, grams, _tones.karat(karat).fg)],
              weight: (grams) => _weightFormat.format(grams),
            ),
        ],
      ),
    );
  }

  /// «مركز السيولة» (the owner, 14 Nov 2026: «مالها وما عليها؟» -- «طبق
  /// توصيتك»): the riyals the shop holds now -- its safes, its banks, and what
  /// the card companies are bringing (its *clearing*, null when the standing
  /// could not be read) -- the whole on its head, a bar each, a tap to the
  /// safes. A part not read says «غير متاح», and the whole with it: never a
  /// quiet zero. The customers' debts are «لنا وعلينا»'s, not money in hand.
  Widget _buildLiquidityPanel() {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;
    final (safes, banks, transit) = _liquidityParts;
    final whole = _liquidityWhole;
    final label = theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    ShareLine line(String id, String name, double? value, Color tone) => ShareLine(
          id: id,
          label: Text(name, style: label),
          value: value,
          color: dashboardMark(context, tone),
          figure: _money.text(value ?? 0),
        );
    return DashboardPanel(
      key: const Key('dashboard-liquidity'),
      icon: Icons.water_drop_outlined,
      accent: _tones.info.fg,
      title: isArabic ? 'مركز السيولة' : 'Liquidity',
      figure: whole == null
          ? Text(isArabic ? 'غير متاح' : 'Not available',
              style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))
          : _money.text(whole, style: dashboardFigure(theme.textTheme.titleSmall, weight: FontWeight.w800)),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SafeBoxesScreen(api: widget.api))),
      child: DashboardShareBars(
        keyPrefix: 'liquidity',
        labelWidth: 112,
        figureWidth: 130,
        lines: [
          line('safes', isArabic ? 'الصناديق' : 'Safes', safes, _tones.cash.fg),
          line('banks', isArabic ? 'البنوك' : 'Banks', banks, _tones.info.fg),
          line('transit', isArabic ? 'في الطريق (صافٍ)' : 'In transit (net)', transit, _tones.sectionTeal.fg),
        ],
      ),
    );
  }

  /// A layer of the gram profit: its name, and its grams signed -- the
  /// figures LTR and tabular inside the RTL card.
  Widget _gramLayer(String key, String label, double grams, {bool total = false}) {
    final color = grams.abs() < 0.0005
        ? Theme.of(context).hintColor
        : (grams > 0 ? _tones.ready.fg : _scheme.error);
    final sign = grams > 0.0005 ? '+' : (grams < -0.0005 ? '−' : '');
    final size = total ? _type.bodyMedium?.fontSize : _type.bodySmall?.fontSize;
    return Padding(
      key: ValueKey('gram-layer-$key'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: size,
                fontWeight: total ? FontWeight.w800 : FontWeight.w600,
                color: total ? _scheme.onSurface : _scheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '$sign${_weightFormat.format(grams.abs())} جم',
            key: const ValueKey('value'),
            textDirection: TextDirection.ltr,
            style: TextStyle(
              fontSize: size,
              fontWeight: total ? FontWeight.w900 : FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
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
    final label = switch (_timeRange) {
      _TimeRange.today => isArabic ? 'اليوم' : 'Today',
      _TimeRange.month => isArabic ? 'الشهر' : 'Month',
      _TimeRange.year => isArabic ? 'السنة' : 'Year',
    };

    // The period before it, to the same point (15 Nov 2026): yesterday to this
    // hour, last month to this day, last year to this date -- the server's.
    final previous = (period['previous'] as Map<String, dynamic>?) ?? const {};
    final before = switch (_timeRange) {
      _TimeRange.today => isArabic ? 'أمس' : 'yesterday',
      _TimeRange.month => isArabic ? 'الشهر الماضي' : 'last month',
      _TimeRange.year => isArabic ? 'السنة الماضية' : 'last year',
    };
    String? against(String key, double amount) {
      final was = previous[key];
      if (was is! Map) return null;
      final then = _asDouble(was['total_value']);
      if (then.abs() < 0.005) return amount.abs() < 0.005 ? null : (isArabic ? 'لا شيء $before' : 'none $before');
      final change = (amount - then) / then.abs() * 100;
      final arrow = change >= 0 ? '▲' : '▼';
      final pct = NumberFormat('0', 'en').format(change.abs());
      return '${ltrIsolate('$arrow $pct%')} ${isArabic ? 'عن $before' : 'vs $before'}';
    }
    final unread = period.isEmpty &&
        ((_response?['unavailable'] as List?) ?? const []).contains('summary_$_summaryPeriod');

    // Its weight beside its amount, set apart, in columns (the owner, 30-31 Oct 2026).
    DashboardAmountRow row(String name, double amount, Color color, [double grams = 0, String? key]) {
      final change = key == null ? null : against(key, amount);
      return DashboardAmountRow(
          label: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              if (change != null)
                Text(change,
                    key: Key('dashboard-against-$key'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
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
    }

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
          if (unread || (sales == 0 && purchases == 0 && scrap == 0 && settlements == 0 && expenses == 0))
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  unread
                      ? (isArabic ? 'غير متاح: تعذّرت قراءة الفترة' : 'Not available: the period could not be read')
                      : (isArabic ? 'لا توجد عمليات بعد' : 'No activity yet'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: DashboardAmountTable(
                rowPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                rows: [
                  row(isArabic ? 'المبيعات' : 'Sales', sales, tones.ready.fg, weight('sales'), 'sales'),
                  row(isArabic ? 'شراء جديد (موردون)' : 'New gold (suppliers)', purchases, tones.cash.fg,
                      weight('purchases'), 'purchases'),
                  row(isArabic ? 'شراء كسر (عملاء)' : 'Scrap (customers)', scrap, tones.cash.fg,
                      weight('scrap_customers'), 'scrap_customers'),
                  row(isArabic ? 'تسكيرات (مكاتب)' : 'Settlements (offices)', settlements, tones.cash.fg,
                      weight('office_settlements'), 'office_settlements'),
                  row(isArabic ? 'المصروفات التشغيلية' : 'Operating expenses', expenses, tones.warning.fg,
                      weight('expenses'), 'expenses'),
                ],
              ),
            ),
          Divider(height: 20, color: scheme.outlineVariant),
          DashboardAmountTable(
            rowPadding: EdgeInsets.zero,
            rows: [
              DashboardAmountRow(
                label: Text(isArabic ? 'السيولة الآن' : 'Cash now',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                amount: _currencyAwareText(
                  _liquidityText,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface),
                ),
              ),
            ],
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
                          fontSize: _type.bodyMedium?.fontSize,
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
                            fontSize: _type.labelSmall?.fontSize,
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
                      fontSize: _type.labelSmall?.fontSize,
                      color: _tones.warning.fg,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    isArabic
                        ? '$wSold جم مباعة  •  $salesStr مبيعات'
                        : '$wSold g sold  •  $salesStr sales',
                    style: TextStyle(
                      fontSize: _type.labelSmall?.fontSize,
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
                          fontSize: _type.bodyMedium?.fontSize,
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
                            fontSize: _type.labelSmall?.fontSize,
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
                            fontSize: _type.labelSmall?.fontSize,
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
                    fontSize: _type.labelSmall?.fontSize,
                    color: theme.hintColor,
                  ),
                ),
                _currencyAwareText(
                  '0 $_currencySymbol',
                  style: TextStyle(
                    fontSize: _type.titleMedium?.fontSize,
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
    // ⑤ of it: what still waits, in two -- its sales' own profit and the
    // price's move since (ADR-048; the owner, 2 Nov 2026).
    final waitingSales = gd('price_effect_waiting_sales_weight');
    final priceMove = gd('price_effect_price_weight');

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
                    fontSize: _type.bodyMedium?.fontSize,
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
                    fontSize: _type.labelSmall?.fontSize,
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
                          fontSize: _type.headlineMedium?.fontSize,
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
                            fontSize: _type.bodySmall?.fontSize,
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
                    fontSize: _type.bodySmall?.fontSize,
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
                    fontSize: _type.bodySmall?.fontSize,
                    fontWeight: FontWeight.bold,
                    color: profitColor,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10),

          // The layers the headline is, their sum it (ADR-048; the owner,
          // 15 Nov 2026): the old averages -- sell, buy and margin a gram, the
          // weight sold -- added up to nothing the card said.
          _gramLayer('trading', isArabic ? 'ربح التداول' : 'Trading', gd('trading_profit_weight')),
          _gramLayer('revenue', isArabic ? 'الإيرادات' : 'Revenue', gd('total_extra_revenue_weight')),
          _gramLayer('expenses', isArabic ? 'المصروفات' : 'Expenses',
              -(gd('expense_weight_direct') + gd('expense_cash_as_weight'))),
          _gramLayer('price_effect', isArabic ? 'ما لم يُسكَّر بعد' : 'Not closed yet', gd('price_effect_weight')),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: AppSpace.md, bottom: AppSpace.xs),
            child: Text(
              isArabic
                  ? 'منه ربح مبيعات تنتظر ${_formatWeight(waitingSales)}، وأثر السعر ${_formatWeight(priceMove)}'
                  : 'Of which its sales ${_formatWeight(waitingSales)}, the price ${_formatWeight(priceMove)}',
              key: const ValueKey('gram-profit-price-effect'),
              style: TextStyle(fontSize: _type.labelSmall?.fontSize, color: theme.hintColor),
            ),
          ),
          Divider(height: AppSpace.md, color: _scheme.outlineVariant),
          _gramLayer('net', isArabic ? 'الصافي' : 'Net', netProfitWeight, total: true),
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
                  fontSize: _type.bodySmall?.fontSize,
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
              fontSize: _type.headlineMedium?.fontSize,
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
                  fontSize: _type.labelSmall?.fontSize,
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

    final sorted = _sortedVaults(safeBoxes);
    bool holds(dynamic sb) {
      final m = (sb as Map?) ?? const {};
      return _asDouble(m['balance_cash']).abs() >= 0.005 || _asDouble(m['total_weight_main_karat']).abs() >= 0.0005;
    }
    final empty = sorted.where((sb) => !holds(sb)).length;
    final shown = _showEmptyVaults ? sorted : sorted.where(holds).toList();

    Widget buildCard(int index, Map<String, dynamic> sb) {
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
        onTap: () {
          if (sbId == null) return;
          setState(() {
            _expandedVaultSafeBoxId = isExpanded ? null : sbId;
          });
        },
        onOpenDetails: () {
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
              if (empty > 0)
                TextButton(
                  key: const Key('dashboard-vaults-empty-toggle'),
                  onPressed: () => setState(() => _showEmptyVaults = !_showEmptyVaults),
                  child: Text(_showEmptyVaults
                      ? (isArabic ? 'إخفاء الفارغة' : 'Hide empty')
                      : (isArabic ? 'إظهار الفارغة ($empty)' : 'Show empty ($empty)')),
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
        // Within the screen's width, a line after a line (the owner, 15 Nov
        // 2026: «يفضل ان تكون ذي اطار الشاشه وليس تمرير افقي»).
        Padding(
            key: const Key('dashboard-vaults-grid'),
            padding: const EdgeInsetsDirectional.only(start: 4, end: 16),
            child: AnimationLimiter(
              child: Wrap(
                runSpacing: 12,
                children: [
                  for (final (index, sb) in shown.indexed)
                    AnimationConfiguration.staggeredGrid(
                      position: index,
                      columnCount: 4,
                      duration: const Duration(milliseconds: 420),
                      child: FadeInAnimation(
                        child: SizedBox(
                          // the card's own height, as the strip gave it: a Spacer needs one
                          height: _expandedVaultSafeBoxId != null && sb['id'] == _expandedVaultSafeBoxId
                              ? 260
                              : 168,
                          child: buildCard(index, sb),
                        ),
                      ),
                    ),
                ],
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
            fontSize: _type.labelSmall?.fontSize,
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
                              fontSize: _type.labelSmall?.fontSize,
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
                                  fontSize: _type.bodySmall?.fontSize,
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
                                fontSize: _type.labelSmall?.fontSize,
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
                              fontSize: _type.titleMedium?.fontSize,
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
