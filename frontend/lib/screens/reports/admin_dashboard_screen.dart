
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../api_service.dart';
import '../../app_events.dart';
import '../../providers/settings_provider.dart';
import '../../utils/currency_utils.dart' as cu;
import '../../theme/app_semantic_colors.dart';
import '../../theme/app_theme.dart';
import '../safe_boxes_screen.dart';
import 'gold_price_history_report_screen.dart';
import 'safe_box_hero_details_screen.dart';
import 'widgets/dashboard_summary_tabs_card.dart';

enum _TimeRange { today, month, year }

class AdminDashboardScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const AdminDashboardScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  // The theme's colours only (DASH-2): the fixed AppColors did not follow the
  // dark theme -- the text and the cards lost each other.
  ColorScheme get _scheme => Theme.of(context).colorScheme;
  AppSemanticColors get _tones => AppSemanticColors.of(context);

  Map<String, dynamic>? _response;
  bool _isLoading = false;
  String? _error;

  int? _expandedVaultSafeBoxId;
  int? _pressedVaultSafeBoxId;

  _TimeRange _timeRange = _TimeRange.today;

  // ── Gram Profit KPI ─────────────────────────────────────────────────────
  Map<String, dynamic>? _gramProfitData;
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
    AppEvents.vaultRefreshSignal.addListener(_onVaultRefresh);
  }

  void _onVaultRefresh() {
    if (mounted) _loadData();
  }

  @override
  void dispose() {
    AppEvents.vaultRefreshSignal.removeListener(_onVaultRefresh);
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
    });

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


  Future<void> _loadGramProfit() async {
    try {
      setState(() => _gramProfitLoading = true);
      final now = DateTime.now();
      final DateTime start;
      switch (_timeRange) {
        case _TimeRange.today:
          start = DateTime(now.year, now.month, now.day);
          break;
        case _TimeRange.month:
          start = DateTime(now.year, now.month, 1);
          break;
        case _TimeRange.year:
          start = DateTime(now.year, 1, 1);
          break;
      }
      final data = await widget.api.getGramProfitReport(
        startDate: start,
        endDate: now,
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
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _buildErrorState()
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
    final rangeSelectorHeight =
      MediaQuery.sizeOf(context).width < 760 ? 96.0 : 56.0;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // === 1. Global Snapshot Header ===
          SliverToBoxAdapter(
            child: _buildGlobalSnapshotHeader(
              globalSnapshot,
              valuation,
              series,
            ),
          ),

          // === 2. Time Range Selector (TOP) ===
          SliverPersistentHeader(
            pinned: true,
            delegate: _StickyRangeSelectorDelegate(
              child: _buildRangeSelector(),
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              height: rangeSelectorHeight,
              horizontalPadding: 16,
              verticalPadding: 8,
            ),
          ),

          // === 3. Time-range-dependent content ===
          SliverToBoxAdapter(
            child: Column(
              children: [
                // Gram Profit KPI + Cash Profit Card (side-by-side on wide, stacked on mobile)
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 760;
                      final gramKpi = _buildGramProfitKpi();
                      final heroProfit = _buildPeriodMovementCard(liquidity, salesPurchasesSummary);
                      if (isWide) {
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: gramKpi),
                              SizedBox(width: 12),
                              Expanded(child: heroProfit),
                            ],
                          ),
                        );
                      }
                      return Column(
                        children: [
                          gramKpi,
                          SizedBox(height: 12),
                          heroProfit,
                        ],
                      );
                    },
                  ),
                ),

                // KPI Grid
                Padding(
                  padding: EdgeInsets.all(16),
                  child: _buildKpiGrid(
                    goldByKarat: goldByKarat,
                    liquidity: liquidity,
                  ),
                ),
                // Sales / Purchases / Expenses Summary
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: DashboardSummaryTabsCard(
                    periodData: (salesPurchasesSummary[_summaryPeriod] as Map<String, dynamic>?) ?? {},
                    isArabic: widget.isArabic,
                    currencyFormat: _currencyFormat,
                    currencySymbol: _currencySymbol,
                    currencyIsNewSar: _currencyIsNewSar,
                    weightFormat: _weightFormat,
                  ),
                ),
              ],
            ),
          ),

          // === 4. Vaults & Custody (Horizontal List) ===
          SliverToBoxAdapter(child: _buildVaultsSection(safeBoxes)),

          SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
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
    final goldPrice = _asDouble(snapshot['gold_price_24k']);
    final goldChange = snapshot['gold_price_change_pct'];

    final changeValue = goldChange is num ? goldChange.toDouble() : null;
    final isPositive = (changeValue ?? 0) >= 0;

    final goldPriceSeries = _extractSeries(series, const [
      'gold_price',
      'gold_price_24k',
      'gold_price_series',
      'gold_price_trend',
    ]);

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
                onPressed: () => Navigator.of(context).pop(),
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
          if (isCompact)
            Column(
              children: [
                _buildNetPositionCard(theme, isArabic, netPosition),
                SizedBox(height: 12),
                _buildGoldPriceCard(
                  theme,
                  isPositive,
                  goldPrice,
                  changeValue,
                  goldPriceSeries: goldPriceSeries,
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildNetPositionCard(theme, isArabic, netPosition),
                ),
                SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _buildGoldPriceCard(
                    theme,
                    isPositive,
                    goldPrice,
                    changeValue,
                    goldPriceSeries: goldPriceSeries,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRangeSelector() {
    final isArabic = widget.isArabic;

    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(isArabic ? 'اليوم' : 'Today'),
                selected: _timeRange == _TimeRange.today,
                onSelected: (_) {
                  setState(() => _timeRange = _TimeRange.today);
                  _loadGramProfit();
                },
              ),
              ChoiceChip(
                label: Text(isArabic ? 'هذا الشهر' : 'This Month'),
                selected: _timeRange == _TimeRange.month,
                onSelected: (_) {
                  setState(() => _timeRange = _TimeRange.month);
                  _loadGramProfit();
                },
              ),
              ChoiceChip(
                label: Text(isArabic ? 'هذه السنة' : 'This Year'),
                selected: _timeRange == _TimeRange.year,
                onSelected: (_) {
                  setState(() => _timeRange = _TimeRange.year);
                  _loadGramProfit();
                },
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: _isLoading ? null : _loadData,
          icon: Icon(Icons.refresh, size: 20),
          label: Text(isArabic ? 'تحديث' : 'Refresh'),
        ),
      ],
    );
  }

  Widget _buildKpiGrid({
    required Map<String, dynamic> goldByKarat,
    required Map<String, dynamic> liquidity,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;
        if (isWide) {
          return Row(
            children: [
              Expanded(child: _buildKaratDistributionCard(goldByKarat)),
              SizedBox(width: 12),
              Expanded(child: _buildLiquidityBreakdownCard(liquidity)),
            ],
          );
        }

        return Column(
          children: [
            _buildKaratDistributionCard(goldByKarat),
            SizedBox(height: 12),
            _buildLiquidityBreakdownCard(liquidity),
          ],
        );
      },
    );
  }

  Widget _buildNetPositionCard(
    ThemeData theme,
    bool isArabic,
    double netPosition,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    final isPositive = netPosition >= 0;
    final accentColor = isPositive ? _scheme.primary : _scheme.error;
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: isDark ? 0.30 : 0.50),
          width: 1.2,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 500;

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

  Widget _buildGoldPriceCard(
    ThemeData theme,
    bool isPositive,
    double goldPrice,
    double? changeValue, {
    List<double>? goldPriceSeries,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GoldPriceHistoryReportScreen(
              api: widget.api,
              isArabic: widget.isArabic,
            ),
          ),
        );
      },
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: (isPositive ? _tones.ready.fg : _scheme.error).withValues(
              alpha: theme.brightness == Brightness.dark ? 0.40 : 0.55,
            ),
            width: 1.2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (isPositive ? _tones.ready.fg : _scheme.error)
                        .withValues(alpha: 0.12),
                  ),
                  child: Icon(
                    Icons.show_chart,
                    color: isPositive ? _tones.ready.fg : _scheme.error,
                    size: 20,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '24K',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (changeValue != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isPositive
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 13,
                        color: isPositive
                            ? _tones.ready.fg
                            : _scheme.error,
                      ),
                      Text(
                        '${changeValue.abs().toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isPositive
                              ? _tones.ready.fg
                              : _scheme.error,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            SizedBox(height: 6),
            _currencyAwareText(
              goldPrice > 0
                  ? '${goldPrice.toStringAsFixed(0)} $_currencySymbol'
                  : '-',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            if ((goldPriceSeries ?? const []).isNotEmpty) ...[
              SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _toSpots(
                          goldPriceSeries!.take(24).toList(),
                          goldPriceSeries.take(24).length,
                        ),
                        isCurved: true,
                        color: isPositive ? _tones.ready.fg : _scheme.error,
                        barWidth: 2,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: (isPositive ? _tones.ready.fg : _scheme.error)
                              .withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            SizedBox(height: 8),
            Text(
              widget.isArabic ? 'اضغط للتفاصيل' : 'Tap for details',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<double> _extractSeries(
    Map<String, dynamic> series,
    List<String> directKeys,
  ) {
    // 1) direct keys
    for (final key in directKeys) {
      final list = _castNumberList(series[key]);
      if (list.isNotEmpty) return list;
    }

    // 2) common composite container
    final composite = series['sales_vs_purchases'];
    if (composite is Map<String, dynamic>) {
      final list = _extractSeries(composite, directKeys);
      if (list.isNotEmpty) return list;
    }

    // 3) range keyed containers
    for (final rangeKey in _rangeKeyCandidates(_timeRange)) {
      final ranged = series[rangeKey];
      if (ranged is Map<String, dynamic>) {
        final list = _extractSeries(ranged, directKeys);
        if (list.isNotEmpty) return list;
      }
    }

    return const [];
  }

  List<String> _rangeKeyCandidates(_TimeRange range) {
    switch (range) {
      case _TimeRange.today:
        return const ['today', '1d', 'day', 'last_1_day', 'last_24_hours'];
      case _TimeRange.month:
        return const ['month', '30d', 'last_30_days', 'last30', 'last_month'];
      case _TimeRange.year:
        return const ['year', '12m', 'last_year', 'ytd', 'annual'];
    }
  }

  List<double> _castNumberList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e is num ? e.toDouble() : null)
          .whereType<double>()
          .toList();
    }
    return const [];
  }

  List<FlSpot> _toSpots(List<double> series, int length) {
    if (series.isEmpty) return const [];
    final spots = <FlSpot>[];
    for (var i = 0; i < length; i++) {
      final value = i < series.length ? series[i] : series.last;
      spots.add(FlSpot(i.toDouble(), value));
    }
    return spots;
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
  Widget _buildLiquidityBreakdownCard(Map<String, dynamic> liquidity) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final cashInHand = _asDouble(liquidity['cash_in_hand']);
    final cashInBanks = _asDouble(liquidity['cash_in_banks']);
    final receivables = _asDouble(liquidity['receivables']);
    final total = cashInHand + cashInBanks + receivables;

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
          SizedBox(height: 4),
          _buildLiquidityRow(
            isArabic ? 'ذمم' : 'Receiv.',
            receivables,
            _tones.warning.fg,
            total,
          ),
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
    final sales = value('sales');
    final purchases = value('purchases');
    final expenses = value('expenses');
    final cash = _asDouble(liquidity['cash_available']);
    final label = switch (_timeRange) {
      _TimeRange.today => isArabic ? 'اليوم' : 'Today',
      _TimeRange.month => isArabic ? 'الشهر' : 'Month',
      _TimeRange.year => isArabic ? 'السنة' : 'Year',
    };

    Widget row(String name, double amount, Color color) => Padding(
          padding: EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(child: Text(name, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))),
              _currencyAwareText(
                _formatCurrency(amount),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
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
          if (sales == 0 && purchases == 0 && expenses == 0)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(isArabic ? 'لا توجد عمليات بعد' : 'No activity yet',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            )
          else ...[
            row(isArabic ? 'المبيعات' : 'Sales', sales, tones.ready.fg),
            row(isArabic ? 'المشتريات' : 'Purchases', purchases, tones.cash.fg),
            row(isArabic ? 'المصروفات التشغيلية' : 'Operating expenses', expenses, tones.warning.fg),
          ],
          Divider(height: 20, color: scheme.outlineVariant),
          row(isArabic ? 'السيولة الآن' : 'Cash now', cash, scheme.onSurface),
        ],
      ),
    );
  }

  Widget _buildGramProfitKpi() {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    if (_gramProfitLoading && _gramProfitData == null) {
      return Container(
        height: 100,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: theme.cardColor,
        ),
        child: Center(
          child: CircularProgressIndicator(color: _scheme.primary),
        ),
      );
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

    final mainKarat = g['main_karat']?.toString() ?? '21';
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

    return Container(
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
        ],
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: isDark
              ? Border.all(
                  color: _scheme.primary.withValues(alpha: 0.22),
                  width: 1,
                )
              : Border.all(
                  color: _scheme.primary.withValues(alpha: 0.45),
                  width: 1.2,
                ),
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
    final displayMainKarat = mainKaratFromApi > 0 ? mainKaratFromApi : 21;

    double totalMainFallback() {
      final mk = displayMainKarat <= 0 ? 21.0 : displayMainKarat.toDouble();
      return (w18 * (18.0 / mk)) + w21 + (w22 * (22.0 / mk)) + (w24 * (24.0 / mk));
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
