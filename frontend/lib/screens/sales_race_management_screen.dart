import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../providers/sales_race_refresh_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' as cu;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../widgets/race_rank_row.dart';
import '../widgets/goal_ring_tile.dart';
import '../widgets/app_bar_tab_bar.dart';

/// نظام إدارة سباق المبيعات المتكامل.
/// Tab 1 – لوحة المتابعة (متاح للجميع): الترتيب، هدف الأسبوع، بطل اليوم.
/// Tab 2 – الإعدادات (system.settings): تفعيل، فترة افتراضية، نقاط، هدف، خيارات عرض.
class SalesRaceManagementScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SalesRaceManagementScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SalesRaceManagementScreen> createState() =>
      _SalesRaceManagementScreenState();
}

class _SalesRaceManagementScreenState extends State<SalesRaceManagementScreen> {
  // ── Leaderboard ──────────────────────────────────────────────────────────
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;
  String _period = 'today';
  String _metric = 'weight';
  DateTime? _fetchedAt;

  // ── Config ────────────────────────────────────────────────────────────────
  bool _configLoading = false;
  String? _configError;
  bool _configSaving = false;

  // Config form state
  bool _enabled = true;
  String _defaultPeriod = 'today';
  List<String> _enabledPeriods = ['today', 'week', 'month'];
  double _pointsPerGram = 10.0;
  String _pointsSource = 'gold_weight';
  double _cashAmountPerPoint = 100.0;
  double _pointsPerInvoice = 1.0;

  /// The points settings as saved: a change of them is previewed before it
  /// is saved (bonus study م3د).
  Map<String, Object> _savedPoints = const {};

  // The colours are the theme's, as on the home screen's race (bonus study م3).
  ColorScheme get _cs => Theme.of(context).colorScheme;
  AppSemanticColors get _tones => AppSemanticColors.of(context);

  static String _typed(double v) => v == v.truncateToDouble() ? '${v.toInt()}' : '$v';
  bool _allowFallback = true;
  bool _showInvoiceCount = true;
  bool _showChampion = true;
  final Map<String, Map<String, String>> _periodVisibility = {
    'today': {'amounts': 'all', 'points': 'all', 'share': 'all', 'team_summary': 'all'},
    'week':  {'amounts': 'all', 'points': 'all', 'share': 'all', 'team_summary': 'all'},
    'month': {'amounts': 'all', 'points': 'all', 'share': 'all', 'team_summary': 'all'},
  };
  String _selectedVisibilityPeriod = 'today';

  final TextEditingController _pointsCtrl = TextEditingController();
  final TextEditingController _cashAmountCtrl = TextEditingController();
  final TextEditingController _pointsPerInvoiceCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadLeaderboard();
    _loadConfig();
  }

  @override
  void dispose() {
    _pointsCtrl.dispose();
    _cashAmountCtrl.dispose();
    _pointsPerInvoiceCtrl.dispose();
    super.dispose();
  }

  // ── Data loaders ──────────────────────────────────────────────────────────

  Future<void> _loadLeaderboard() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getHomeLeaderboard(
        period: _period,
        metric: _metric,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _fetchedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadConfig() async {
    if (!mounted) return;
    setState(() {
      _configLoading = true;
      _configError = null;
    });
    try {
      final cfg = await widget.api.getSalesRaceConfig();
      if (!mounted) return;
      _applyConfig(cfg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _configError = e.toString());
    } finally {
      if (mounted) setState(() => _configLoading = false);
    }
  }

  void _applyConfig(Map<String, dynamic> cfg) {
    _enabled = cfg['enabled'] as bool? ?? true;
    final dp = (cfg['default_period'] as String?)?.trim().toLowerCase();
    _defaultPeriod = dp == 'week' ? 'week' : dp == 'month' ? 'month' : 'today';
    final rawPeriods = cfg['enabled_periods'];
    if (rawPeriods is List) {
      final valid = rawPeriods
          .whereType<String>()
          .where((p) => ['today', 'week', 'month'].contains(p))
          .toList();
      _enabledPeriods = valid.isNotEmpty ? valid : ['today'];
    }
    _pointsPerGram = (cfg['points_per_gram'] as num?)?.toDouble() ?? 10.0;
    final rawSource = (cfg['points_source'] as String?)?.trim() ?? 'gold_weight';
    _pointsSource = const ['gold_weight', 'profit_cash', 'sales_amount', 'invoice_count', 'sold_weight']
        .contains(rawSource) ? rawSource : 'gold_weight';
    _cashAmountPerPoint = (cfg['cash_amount_per_point'] as num?)?.toDouble() ?? 100.0;
    _pointsPerInvoice = (cfg['points_per_invoice'] as num?)?.toDouble() ?? 1.0;
    _savedPoints = {
      'points_source': _pointsSource,
      'cash_amount_per_point': _cashAmountPerPoint,
      'points_per_gram': _pointsPerGram,
      'points_per_invoice': _pointsPerInvoice,
    };
    _allowFallback = cfg['allow_fallback_to_latest_period'] as bool? ?? true;
    _showInvoiceCount = cfg['show_invoice_count'] as bool? ?? true;
    _showChampion = cfg['show_champion'] as bool? ?? true;
    final rawPV = cfg['period_visibility'];
    if (rawPV is Map) {
      for (final p in ['today', 'week', 'month']) {
        final pData = rawPV[p];
        if (pData is Map) {
          _periodVisibility[p] = {
            'amounts':      pData['amounts']      as String? ?? 'all',
            'points':       pData['points']       as String? ?? 'all',
            'share':        pData['share']        as String? ?? 'all',
            'team_summary': pData['team_summary'] as String? ?? 'all',
          };
        }
      }
    }
    _pointsCtrl.text = _typed(_pointsPerGram);
    _cashAmountCtrl.text = _typed(_cashAmountPerPoint);
    _pointsPerInvoiceCtrl.text = _typed(_pointsPerInvoice);
  }

  Future<void> _saveConfig() async {
    if (!mounted) return;
    final isAr = widget.isArabic;

    // Validate points_per_gram (used by gold_weight and sold_weight)
    final parsedPoints = double.tryParse(_pointsCtrl.text.trim());
    if (parsedPoints == null || parsedPoints < 0) {
      _showSnack(isAr ? 'قيمة النقاط غير صالحة' : 'Invalid points value', isError: true);
      return;
    }

    // Validate cash_amount_per_point (used by profit_cash and sales_amount)
    final parsedCashAmount = double.tryParse(_cashAmountCtrl.text.trim());
    if (parsedCashAmount == null || parsedCashAmount <= 0) {
      _showSnack(
        isAr ? 'قيمة الريال لكل نقطة غير صالحة' : 'Invalid amount per point',
        isError: true,
      );
      return;
    }

    // Validate points_per_invoice (used by invoice_count)
    final parsedPointsPerInvoice = double.tryParse(_pointsPerInvoiceCtrl.text.trim());
    if (parsedPointsPerInvoice == null || parsedPointsPerInvoice < 0) {
      _showSnack(
        isAr ? 'قيمة النقاط لكل فاتورة غير صالحة' : 'Invalid points per invoice',
        isError: true,
      );
      return;
    }

    final points = <String, Object>{
      'points_source': _pointsSource,
      'cash_amount_per_point': parsedCashAmount,
      'points_per_gram': parsedPoints,
      'points_per_invoice': parsedPointsPerInvoice,
    };
    final changed = {
      for (final e in points.entries)
        if (_savedPoints[e.key] != e.value) e.key: e.value,
    };
    if (changed.isNotEmpty && !await _confirmPointsChange(changed)) return;
    if (!mounted) return;
    setState(() => _configSaving = true);
    try {
      final saved = await widget.api.updateSalesRaceConfig({
        'enabled': _enabled,
        'default_period': _defaultPeriod,
        'enabled_periods': _enabledPeriods,
        'points_per_gram': parsedPoints,
        'points_source': _pointsSource,
        'cash_amount_per_point': parsedCashAmount,
        'points_per_invoice': parsedPointsPerInvoice,
        'allow_fallback_to_latest_period': _allowFallback,
        'show_invoice_count': _showInvoiceCount,
        'show_champion': _showChampion,
        'period_visibility': _periodVisibility,
      });
      if (!mounted) return;
      _applyConfig(saved);
      // Notify home screen to refresh its leaderboard card.
      Provider.of<SalesRaceRefreshProvider>(
        context,
        listen: false,
      ).notifySettingsChanged();
      _showSnack(widget.isArabic ? 'تم حفظ الإعدادات بنجاح' : 'Settings saved');
    } catch (e) {
      if (!mounted) return;
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _configSaving = false);
    }
  }

  /// The settings are read live (the owner: «حيّ مع تحذير ومعاينة»): a
  /// change measures the whole open period by them. Before it is saved the
  /// page says it in figures, from the server's preview.
  Future<bool> _confirmPointsChange(Map<String, Object> changed) async {
    Map<String, dynamic> preview;
    try {
      preview = await widget.api.previewSalesRaceConfig(changed);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّرت معاينة الأثر، فلم يُحفظ شيء');
      return false;
    }
    if (!mounted) return false;
    final currency = context.read<SettingsProvider>().currencySymbolText;
    String n(num v) => cu.formatAmount(v, decimals: 0);
    final employees = ((preview['employees'] as List?) ?? const []).whereType<Map>().toList();
    final rules = ((preview['rules'] as List?) ?? const []).whereType<Map>().toList();
    num sum(String key) => rules.fold<num>(0, (s, r) => s + ((r[key] as num?) ?? 0));
    final moved = employees.where((e) => e['points_now'] != e['points_new']).toList();
    final go = await confirmFinancialAction(
      context,
      title: 'تغيير إعدادات النقاط',
      facts: [
        for (final e in moved.take(6))
          ('${e['employee']}', '${n(e['points_now'] as num)} ← ${n(e['points_new'] as num)} نقطة'),
        if (moved.length > 6) ('وغيرهم', '${moved.length - 6} موظف'),
        if (rules.isNotEmpty)
          ('قواعد النقاط المفتوحة', '${cu.formatAmount(sum('amount_now'))} ← ${cu.formatAmount(sum('amount_new'))} $currency'),
      ],
      effect: 'النقاط تُقرأ بالإعداد الجديد من لحظة الحفظ، للفترة الجارية كلها منذ '
          '${preview['period_start']}، لا مما بعد الحفظ فقط. والمكافآت المعلّقة تتغيّر '
          'بشرائحها حين يُعاد احتسابها، والمعتمدة والمدفوعة لا تُمس.'
          '${moved.isEmpty ? '\nلا تتغيّر نقاط أحد هذا الشهر.' : ''}',
      confirmLabel: 'احفظ التغيير',
      destructive: false,
    );
    return go != null;
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (isError) {
      AppFeedback.error(context, msg);
    } else {
      AppFeedback.success(context, msg);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final auth = context.read<AuthProvider>();
    context.watch<SettingsProvider>();
    final canManage = auth.hasPermission('system.settings');

    return DefaultTabController(
      length: canManage ? 2 : 1,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(isAr ? 'سباق الأداء' : 'Performance Race'),
          actions: [
            IconButton(
              icon: _loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).appBarTheme.foregroundColor,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
              tooltip: isAr ? 'تحديث' : 'Refresh',
              onPressed: _loading ? null : _loadLeaderboard,
            ),
          ],
          bottom: AppBarTabBar(
            tabs: [
              Tab(
                text: isAr ? 'لوحة المتابعة' : 'Live Board',
                icon: const Icon(Icons.leaderboard_rounded),
              ),
              if (canManage)
                Tab(
                  text: isAr ? 'الإعدادات' : 'Settings',
                  icon: const Icon(Icons.settings_rounded),
                ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildDashboardTab(isAr),
            if (canManage) _buildSettingsTab(isAr),
          ],
        ),
      ),
    );
  }

  // ── Tab 1: Dashboard ──────────────────────────────────────────────────────

  Widget _buildDashboardTab(bool isAr) {
    return RefreshIndicator(
      onRefresh: _loadLeaderboard,
      color: _cs.primary,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPeriodAndMetricSelectors(isAr),
            const SizedBox(height: 16),
            if (_loading)
              const SizedBox(height: 420, child: AppLoadingView(summaryBlocks: 2, rows: 4))
            else if (_error != null)
              _buildErrorCard(isAr)
            else if (_data == null)
              const SizedBox.shrink()
            else ...[
              _buildChampionAndSummaryRow(isAr),
              const SizedBox(height: 16),
              // The team's monthly goal (bonus study م3ح), whatever period
              // the board shows.
              if (_data!['team_goal'] is Map) ...[
                _card(
                  // Alone here: a line, not a ring (the owner, 24 Oct 2026).
                  child: GoalTileStyle(
                    linear: true,
                    boxed: false,
                    child: TeamGoalTile(
                      goal: _data!['team_goal'] as Map,
                      format: (v) => cu.formatAmount(v, decimals: v == v.truncate() ? 0 : 1),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              _buildRankingCard(isAr),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodAndMetricSelectors(bool isAr) {
    // Read live config from last response; fall back to settings state.
    final liveConfig = _data?['config'] as Map?;
    final enabledPeriods = liveConfig != null
        ? ((liveConfig['enabled_periods'] as List?)
                ?.whereType<String>()
                .toSet() ??
            _enabledPeriods.toSet())
        : _enabledPeriods.toSet();
    final pointsVisible = liveConfig?['points_visible'] as bool? ?? true;

    // Ensure selected period/metric are still valid after config change.
    if (!enabledPeriods.contains(_period) && enabledPeriods.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _period = enabledPeriods.first);
      });
    }
    if (_metric == 'points' && !pointsVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _metric = 'weight');
      });
    }

    final periodSegments = <ButtonSegment<String>>[
      if (enabledPeriods.contains('today'))
        ButtonSegment(value: 'today', label: Text(isAr ? 'اليوم' : 'Today')),
      if (enabledPeriods.contains('week'))
        ButtonSegment(value: 'week', label: Text(isAr ? 'الأسبوع' : 'Week')),
      if (enabledPeriods.contains('month'))
        ButtonSegment(value: 'month', label: Text(isAr ? 'الشهر' : 'Month')),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Period — only show enabled periods
        if (periodSegments.length >= 2)
          SegmentedButton<String>(
            segments: periodSegments,
            selected: {enabledPeriods.contains(_period) ? _period : enabledPeriods.first},
            onSelectionChanged: _loading
                ? null
                : (s) {
                    final next = s.isNotEmpty ? s.first : _period;
                    if (next == _period) return;
                    setState(() => _period = next);
                    _loadLeaderboard();
                  },
            showSelectedIcon: false,
            style: _segmentedControlStyle(),
          ),
        // Metric — hide points tab if restricted
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'weight', label: Text(isAr ? 'الوزن' : 'Weight')),
            ButtonSegment(value: 'count', label: Text(isAr ? 'الفواتير' : 'Count')),
            if (pointsVisible)
              ButtonSegment(value: 'points', label: Text(isAr ? 'النقاط' : 'Points')),
          ],
          selected: {(_metric == 'points' && !pointsVisible) ? 'weight' : _metric},
          onSelectionChanged: _loading
              ? null
              : (s) {
                  final next = s.isNotEmpty ? s.first : _metric;
                  if (next == _metric) return;
                  setState(() => _metric = next);
                  _loadLeaderboard();
                },
          showSelectedIcon: false,
          style: _segmentedControlStyle(),
        ),
      ],
    );
  }

  Widget _buildChampionAndSummaryRow(bool isAr) {
    final data = _data!;
    final champion = data['champion'] as Map?;
    final adminSummary = data['admin_summary'] as Map?;
    final isFallback = data['is_fallback'] == true;
    final effectiveStartStr = (data['effective_start_date'] ?? '').toString();
    final effectiveDate = DateTime.tryParse(effectiveStartStr);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fallback notice
        if (isFallback && effectiveDate != null)
          _buildNoticeCard(
            icon: Icons.history_toggle_off_rounded,
            message: _period == 'month'
                ? (isAr
                      ? 'لا توجد مبيعات هذا الشهر — يتم عرض آخر شهر بدأ في ${_fmt(effectiveDate)}'
                      : 'No sales this month — showing latest month starting ${_fmt(effectiveDate)}')
                : _period == 'week'
                ? (isAr
                      ? 'لا توجد مبيعات هذا الأسبوع — يتم عرض آخر أسبوع بدأ في ${_fmt(effectiveDate)}'
                      : 'No sales this week — showing latest week starting ${_fmt(effectiveDate)}')
                : (isAr
                      ? 'لا توجد مبيعات اليوم — يتم عرض آخر يوم بتاريخ ${_fmt(effectiveDate)}'
                      : 'No sales today — showing latest day on ${_fmt(effectiveDate)}'),
          ),
        if (isFallback && effectiveDate != null) const SizedBox(height: 12),

        // Champion card + admin summary in a row on wide screens
        if (champion != null || adminSummary != null)
          LayoutBuilder(
            builder: (ctx, constraints) {
              final isWide = constraints.maxWidth >= 600;
              final widgets = <Widget>[
                if (champion != null)
                  Expanded(child: _buildChampionCard(isAr, champion)),
                if (adminSummary != null) ...[
                  if (isWide) const SizedBox(width: 12),
                  if (!isWide) const SizedBox(height: 12),
                  Expanded(child: _buildAdminSummaryCard(isAr, adminSummary)),
                ],
              ];
              if (isWide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widgets,
                );
              }
              return Column(children: widgets);
            },
          ),
      ],
    );
  }

  Widget _buildChampionCard(bool isAr, Map champion) {
    final name = (champion['name'] ?? '').toString();
    return _card(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: _tones.gold.container,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _cs.primary.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Text('🥇', style: Theme.of(context).textTheme.headlineMedium),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAr ? 'بطل الفترة' : 'Champion',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _tones.gold.fg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminSummaryCard(bool isAr, Map summary) {
    final totalSalesAmount = (summary['total_sales_amount'] as num?)?.toDouble() ??
        (summary['total_cash'] as num?)?.toDouble();
    final totalPurchaseAmount =
        (summary['total_purchase_amount'] as num?)?.toDouble();
    final totalPoints = (summary['total_points'] as num?)?.toInt();
    final currency = context.read<SettingsProvider>().currencySymbolText;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bar_chart_rounded,
                size: 20,
                color: _cs.primary,
              ),
              const SizedBox(width: 8),
              Text(
                isAr ? 'ملخص السباق' : 'Race Summary',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (totalSalesAmount != null)
            _summaryRow(
              isAr ? 'مبلغ المبيعات' : 'Sales Amount',
              '${cu.formatAmount(totalSalesAmount)} $currency',
              color: _tones.invoiceSale.fg,
            ),
          if (totalPurchaseAmount != null) ...[
            const SizedBox(height: 6),
            _summaryRow(
              isAr ? 'مبلغ المشتريات' : 'Purchases Amount',
              '${cu.formatAmount(totalPurchaseAmount)} $currency',
              color: _tones.invoicePurchaseScrap.fg,
            ),
          ],
          if (totalPoints != null) ...[
            const SizedBox(height: 6),
            _summaryRow(
              isAr ? 'إجمالي النقاط' : 'Total Points',
              isAr ? '$totalPoints نقطة' : '$totalPoints pts',
              color: _tones.gold.fg,
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value, {Color? color}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildRankingCard(bool isAr) {
    final data = _data!;
    final ranking = (data['ranking'] as List?) ?? const [];
    final config = data['config'] as Map?;
    final metric = (data['metric'] ?? 'weight_g').toString();
    final champion = data['champion'] as Map?;
    final championName = (champion?['name'] ?? '').toString().trim();
    final showInvoiceCount = config?['show_invoice_count'] != false;
    final showAmounts = config?['amounts_visible'] as bool? ?? true;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final rankingRows = ranking.whereType<Map>().toList(growable: false);

    if (rankingRows.isEmpty) {
      return _card(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                Icon(
                  Icons.emoji_events_outlined,
                  size: 40,
                  color: colorScheme.onSurface.withValues(alpha: 0.35),
                ),
                const SizedBox(height: 8),
                Text(
                  isAr
                      ? 'لا توجد مبيعات في هذه الفترة'
                      : 'No sales in this period',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isAr ? 'ترتيب الموظفين' : 'Employee Rankings',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Icon(
                Icons.emoji_events_rounded,
                color: _cs.primary,
                size: 22,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _tones.gold.container,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _cs.primary.withValues(alpha: 0.18),
                  ),
                ),
                child: Text(
                  switch (metric) {
                    'count' => isAr ? 'عرض حسب الفواتير' : 'Invoice view',
                    'points' => isAr ? 'عرض حسب النقاط' : 'Points view',
                    _ => isAr ? 'عرض حسب الوزن' : 'Weight view',
                  },
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _tones.gold.fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
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
                  isAr
                      ? '${rankingRows.length} موظف في الترتيب'
                      : '${rankingRows.length} staff ranked',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (championName.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _cs.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _cs.primary.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Text(
                    isAr
                        ? 'المتصدر الآن: $championName'
                        : 'Current leader: $championName',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: _tones.gold.fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          if (_fetchedAt != null) ...[
            const SizedBox(height: 4),
            Text(
              isAr
                  ? 'آخر تحديث: ${DateFormat('dd/MM HH:mm', 'en').format(_fetchedAt!)}'
                  : 'Updated: ${DateFormat('dd/MM HH:mm', 'en').format(_fetchedAt!)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 16),
          // One row of the race, as the home card draws it (bonus study م3).
          for (final (i, row) in rankingRows.indexed)
            RaceRankRow(
              row: row,
              index: i,
              metric: metric,
              isAr: isAr,
              showInvoiceCount: showInvoiceCount,
              showAmounts: showAmounts,
              showPoints: config?['points_visible'] as bool? ?? true,
            ),
        ],
      ),
    );
  }


  Widget _buildErrorCard(bool isAr) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              Text(
                isAr ? 'تعذر تحميل البيانات' : 'Failed to load data',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _loadLeaderboard,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
          ),
        ],
      ),
    );
  }

  // ── Tab 2: Settings ───────────────────────────────────────────────────────

  Widget _buildSettingsTab(bool isAr) {
    if (_configLoading) {
      return const AppLoadingView(summaryBlocks: 1, rows: 6);
    }
    if (_configError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _configError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadConfig,
              child: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(
            isAr ? 'الحالة العامة' : 'General Status',
            Icons.toggle_on_rounded,
          ),
          const SizedBox(height: 8),
          _card(
            child: SwitchListTile(
              title: Text(
                isAr ? 'تفعيل سباق الأداء' : 'Enable Performance Race',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                isAr
                    ? 'يعرض لوحة الصدارة في الشاشة الرئيسية وهنا'
                    : 'Shows the leaderboard on home screen and here',
              ),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              activeColor: _cs.primary,
            ),
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            isAr ? 'الفترة الافتراضية' : 'Default Period',
            Icons.calendar_today_rounded,
          ),
          const SizedBox(height: 8),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr
                      ? 'الفترة المعروضة عند فتح لوحة الصدارة'
                      : 'Period shown when opening the leaderboard',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'today',
                      label: Text(isAr ? 'اليوم' : 'Today'),
                    ),
                    ButtonSegment(
                      value: 'week',
                      label: Text(isAr ? 'الأسبوع' : 'Week'),
                    ),
                    ButtonSegment(
                      value: 'month',
                      label: Text(isAr ? 'الشهر' : 'Month'),
                    ),
                  ],
                  selected: {_defaultPeriod},
                  onSelectionChanged: (s) {
                    if (s.isNotEmpty) setState(() => _defaultPeriod = s.first);
                  },
                  showSelectedIcon: false,
                  style: _segmentedControlStyle(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // The team's goal is no figure here: it is its employees'
          // monthly goals summed (bonus study م3ح).
          _buildNoticeCard(
            icon: Icons.flag_outlined,
            message: 'هدف الفريق الشهري مجموع أهداف الموظفين الشهرية، يُضبط من هدف كل موظف؛ '
                'والأسبوعي حصة الأسبوع منه.',
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            isAr ? 'مصدر النقاط' : 'Points Source',
            Icons.stars_rounded,
          ),
          const SizedBox(height: 8),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isAr
                      ? 'كيف تُحسب نقاط كل موظف؟'
                      : 'How are employee points calculated?',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _pointsSource,
                  decoration: InputDecoration(
                    labelText: isAr ? 'مصدر الحساب' : 'Calculation source',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.calculate_rounded),
                  ),
                  borderRadius: BorderRadius.circular(12),
                  items: [
                    DropdownMenuItem(
                      value: 'gold_weight',
                      child: Text(isAr ? 'الربح الوزني (جرام معادل)' : 'Gold profit weight'),
                    ),
                    DropdownMenuItem(
                      value: 'profit_cash',
                      child: Text(isAr ? 'الربح النقدي' : 'Cash profit'),
                    ),
                    DropdownMenuItem(
                      value: 'sales_amount',
                      child: Text(isAr ? 'حجم المبيعات (الإيراد)' : 'Sales amount'),
                    ),
                    DropdownMenuItem(
                      value: 'invoice_count',
                      child: Text(isAr ? 'عدد الفواتير' : 'Invoice count'),
                    ),
                    DropdownMenuItem(
                      value: 'sold_weight',
                      child: Text(isAr ? 'الوزن المباع (جرام)' : 'Sold weight'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _pointsSource = v);
                  },
                ),
                const SizedBox(height: 8),
                // Description chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _tones.gold.container,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _cs.primary.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    _pointsSourceDescription(isAr),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _tones.gold.fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Conditional value field
                if (_pointsSource == 'gold_weight' || _pointsSource == 'sold_weight')
                  TextField(
                    controller: _pointsCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: _pointsSource == 'sold_weight'
                          ? (isAr ? 'نقاط لكل جرام مباع' : 'Points per sold gram')
                          : (isAr ? 'نقاط لكل جرام ربح' : 'Points per profit gram'),
                      suffixText: isAr ? 'نقطة/جم' : 'pts/g',
                      border: const OutlineInputBorder(),
                    ),
                  )
                else if (_pointsSource == 'profit_cash' || _pointsSource == 'sales_amount')
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _cashAmountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: _pointsSource == 'sales_amount'
                              ? (isAr ? 'ريال مبيعات لكل نقطة' : 'Sales riyals per point')
                              : (isAr ? 'ريال ربح لكل نقطة (فواتير البيع)' : 'Profit riyals per point (sales)'),
                          suffixText: isAr ? 'ريال/نقطة' : 'SAR/pt',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (_pointsSource == 'profit_cash') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pointsCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(
                            labelText: isAr
                                ? 'نقاط لكل جرام ربح (شراء كسر)'
                                : 'Points per profit gram (customer purchases)',
                            suffixText: isAr ? 'نقطة/جم' : 'pts/g',
                            border: const OutlineInputBorder(),
                            helperText: isAr
                                ? 'فواتير الشراء ربحها بالذهب لا بالريال'
                                : 'Purchase invoices earn gold profit, not cash',
                          ),
                        ),
                      ],
                    ],
                  )
                else if (_pointsSource == 'invoice_count')
                  TextField(
                    controller: _pointsPerInvoiceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isAr ? 'نقاط لكل فاتورة' : 'Points per invoice',
                      suffixText: isAr ? 'نقطة/فاتورة' : 'pts/inv',
                      border: const OutlineInputBorder(),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            isAr ? 'خيارات العرض' : 'Display Options',
            Icons.visibility_rounded,
          ),
          const SizedBox(height: 8),
          _card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(
                    isAr ? 'إظهار بطل اليوم' : 'Show Champion',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  value: _showChampion,
                  onChanged: (v) => setState(() => _showChampion = v),
                  activeColor: _cs.primary,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: Text(
                    isAr
                        ? 'إظهار عدد الفواتير مع النقاط'
                        : 'Show Invoice Count with Score',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  value: _showInvoiceCount,
                  onChanged: (v) => setState(() => _showInvoiceCount = v),
                  activeColor: _cs.primary,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: Text(
                    isAr
                        ? 'عرض آخر فترة عند انعدام المبيعات'
                        : 'Show Last Period When No Sales',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    isAr
                        ? 'بدلاً من عرض لوحة فارغة'
                        : 'Instead of an empty leaderboard',
                  ),
                  value: _allowFallback,
                  onChanged: (v) => setState(() => _allowFallback = v),
                  activeColor: _cs.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _buildSectionHeader(
            isAr ? 'صلاحيات رؤية البيانات' : 'Data Visibility',
            Icons.lock_person_rounded,
          ),
          const SizedBox(height: 8),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Enabled periods
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'الفترات الظاهرة في اللوحة' : 'Visible Period Tabs',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isAr
                            ? 'يجب أن تكون فترة واحدة على الأقل مفعّلة'
                            : 'At least one period must remain enabled',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.55),
                            ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final entry in [
                            ('today', isAr ? 'اليوم' : 'Today'),
                            ('week',  isAr ? 'الأسبوع' : 'Week'),
                            ('month', isAr ? 'الشهر' : 'Month'),
                          ])
                            FilterChip(
                              label: Text(
                                entry.$2,
                                style: TextStyle(
                                  color: _enabledPeriods.contains(entry.$1)
                                      ? _cs.onPrimary
                                      : Theme.of(context).colorScheme.onSurface,
                                  fontWeight: _enabledPeriods.contains(entry.$1)
                                      ? FontWeight.w700
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: _enabledPeriods.contains(entry.$1),
                              selectedColor: _cs.primary,
                              backgroundColor: Colors.transparent,
                              checkmarkColor: _cs.onPrimary,
                              showCheckmark: true,
                              side: BorderSide(
                                color: _enabledPeriods.contains(entry.$1)
                                    ? _cs.primary
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.45),
                                width: 1.2,
                              ),
                              onSelected: (v) => setState(() {
                                if (v) {
                                  _enabledPeriods = [..._enabledPeriods, entry.$1];
                                } else if (_enabledPeriods.length > 1) {
                                  _enabledPeriods = _enabledPeriods
                                      .where((p) => p != entry.$1)
                                      .toList();
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr
                            ? 'اختر الفترة لضبط صلاحياتها'
                            : 'Select period to configure',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final entry in [
                            ('today', isAr ? 'اليوم'    : 'Today'),
                            ('week',  isAr ? 'الأسبوع'  : 'Week'),
                            ('month', isAr ? 'الشهر'    : 'Month'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: ChoiceChip(
                                label: Text(entry.$2),
                                selected: _selectedVisibilityPeriod == entry.$1,
                                selectedColor:
                                    _cs.primary.withValues(alpha: 0.2),
                                checkmarkColor: _tones.gold.fg,
                                onSelected: (_) => setState(
                                  () => _selectedVisibilityPeriod = entry.$1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                _buildVisibilityTile(
                  isAr ? 'المبالغ النقدية' : 'Cash Amounts',
                  isAr
                      ? 'مبالغ المبيعات والمشتريات لكل موظف'
                      : 'Per-employee sales & purchase amounts',
                  Icons.attach_money_rounded,
                  _periodVisibility[_selectedVisibilityPeriod]!['amounts']!,
                  (v) => setState(
                    () => _periodVisibility[_selectedVisibilityPeriod]!['amounts'] = v,
                  ),
                  isAr,
                ),
                const Divider(height: 1),
                _buildVisibilityTile(
                  isAr ? 'النقاط' : 'Points',
                  isAr
                      ? 'مقياس النقاط وإجماليها في ملخص الفريق'
                      : 'Points metric tab and totals',
                  Icons.stars_rounded,
                  _periodVisibility[_selectedVisibilityPeriod]!['points']!,
                  (v) => setState(
                    () => _periodVisibility[_selectedVisibilityPeriod]!['points'] = v,
                  ),
                  isAr,
                ),
                const Divider(height: 1),
                _buildVisibilityTile(
                  isAr ? 'نسبة المشاركة' : 'Share Percentage',
                  isAr
                      ? 'شريط نسبة مساهمة كل موظف من الإجمالي'
                      : 'Per-employee contribution bar',
                  Icons.bar_chart_rounded,
                  _periodVisibility[_selectedVisibilityPeriod]!['share']!,
                  (v) => setState(
                    () => _periodVisibility[_selectedVisibilityPeriod]!['share'] = v,
                  ),
                  isAr,
                ),
                const Divider(height: 1),
                _buildVisibilityTile(
                  isAr ? 'ملخص الفريق' : 'Team Summary',
                  isAr
                      ? 'بطاقة إجماليات المبيعات والنقاط للفترة'
                      : 'Total sales & points summary card',
                  Icons.summarize_rounded,
                  _periodVisibility[_selectedVisibilityPeriod]!['team_summary']!,
                  (v) => setState(
                    () => _periodVisibility[_selectedVisibilityPeriod]!['team_summary'] = v,
                  ),
                  isAr,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _configSaving ? null : _saveConfig,
              icon: _configSaving
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _cs.onPrimary),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(
                isAr ? 'حفظ الإعدادات' : 'Save Settings',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _cs.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: _cs.shadow.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  ButtonStyle _segmentedControlStyle() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ButtonStyle(
      side: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return BorderSide.none;
        }
        return BorderSide(color: colorScheme.outline.withValues(alpha: 0.35), width: 1);
      }),
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
        return colorScheme.onSurface.withValues(alpha: 0.72);
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _cs.primary;
        }
        return colorScheme.surfaceContainerHighest.withValues(alpha: 0.45);
      }),
      overlayColor: WidgetStateProperty.all(
        _cs.primary.withValues(alpha: 0.08),
      ),
      elevation: WidgetStateProperty.all(0),
    );
  }

  Widget _buildVisibilityTile(
    String title,
    String subtitle,
    IconData icon,
    String value,
    ValueChanged<String> onChanged,
    bool isAr,
  ) {
    return ListTile(
      leading: Icon(icon, color: _cs.primary, size: 22),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          borderRadius: BorderRadius.circular(12),
          items: [
            DropdownMenuItem(
              value: 'all',
              child: Text(
                isAr ? 'للجميع' : 'Everyone',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            DropdownMenuItem(
              value: 'admin_only',
              child: Text(
                isAr ? 'المسؤول فقط' : 'Admin only',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: _cs.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: _cs.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildNoticeCard({required IconData icon, required String message}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _pointsSourceDescription(bool isAr) {
    switch (_pointsSource) {
      case 'profit_cash':
        return isAr
            ? 'النقاط = الربح النقدي للفاتورة ÷ قيمة الريال لكل نقطة'
            : 'Points = invoice profit_cash ÷ riyals per point';
      case 'sales_amount':
        return isAr
            ? 'النقاط = إجمالي الفاتورة ÷ قيمة الريال لكل نقطة'
            : 'Points = invoice total ÷ riyals per point';
      case 'invoice_count':
        return isAr
            ? 'النقاط = عدد الفواتير × نقاط لكل فاتورة'
            : 'Points = invoice count × points per invoice';
      case 'sold_weight':
        return isAr
            ? 'النقاط = الوزن المباع (جرام) × نقاط لكل جرام'
            : 'Points = sold weight (g) × points per gram';
      default:
        return isAr
            ? 'النقاط = الربح الوزني المعادل بالعيار الأساسي × نقاط لكل جرام'
            : 'Points = main-karat-equivalent profit weight × points per gram';
    }
  }

  String _fmt(DateTime dt) => DateFormat('dd/MM/yyyy', 'en').format(dt);
}
