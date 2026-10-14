import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/inventory_models.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bucket_balance_card.dart';
import 'inventory_count_screen.dart';
import '../theme/app_semantic_colors.dart';

/// The theme's colours (ADR-038): the scheme and the semantic tones.
ColorScheme _cs(BuildContext context) => Theme.of(context).colorScheme;
AppSemanticColors _tn(BuildContext context) => AppSemanticColors.of(context);

class InventoryBalanceScreen extends StatefulWidget {
  const InventoryBalanceScreen({super.key});

  @override
  State<InventoryBalanceScreen> createState() => _InventoryBalanceScreenState();
}

class _InventoryBalanceScreenState extends State<InventoryBalanceScreen> {
  final _svc = InventoryService(ApiService());

  InventoryBalanceSummary? _summary;
  List<InventoryBucket> _buckets = [];
  CountSession? _activeSession; // freeze banner
  bool _loading = true;
  String? _error;

  // Filters
  int? _filterSafeBoxId;
  double? _filterKarat;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _svc.getBalanceSummary(),
        _svc.getBalance(safeBoxId: _filterSafeBoxId, karat: _filterKarat),
        _loadActiveSession(),
      ]);
      setState(() {
        _summary = results[0] as InventoryBalanceSummary;
        _buckets = results[1] as List<InventoryBucket>;
        _loading = false;
      });
    } on InventoryApiException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadActiveSession() async {
    try {
      // Open, then counting, then awaiting approval -- a closed count was
      // reachable from no screen (ADR-045 C2).
      List<CountSession> sessions = await _svc.listSessions(status: 'open');
      if (sessions.isEmpty) {
        sessions = await _svc.listSessions(status: 'counting');
      }
      if (sessions.isEmpty) {
        sessions = await _svc.listSessions(status: 'closed');
      }
      if (mounted) {
        setState(() => _activeSession = sessions.isNotEmpty ? sessions.first : null);
      }
    } catch (_) {
      // Non-fatal — banner simply won't show
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('الجرد الفعلي'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: _cs(context).primary))
            : _error != null
                ? _ErrorView(message: _error!, onRetry: _load)
                : RefreshIndicator(
                    onRefresh: _load,
                    color: _cs(context).primary,
                    child: CustomScrollView(
                      slivers: [
                        // ── Freeze Banner ─────────────────────────────────
                        if (_activeSession != null)
                          SliverToBoxAdapter(
                            child: _FreezeBanner(
                              session: _activeSession!,
                              onResume: _resumeSession,
                            ),
                          ),
                        SliverToBoxAdapter(child: _SummaryHeader(summary: _summary!)),
                        SliverToBoxAdapter(child: _KaratFilterBar(
                          karats: _summary!.byKarat.map((k) => k.karat).toList(),
                          selected: _filterKarat,
                          onSelected: (k) {
                            setState(() => _filterKarat = k);
                            _load();
                          },
                        )),
                        SliverToBoxAdapter(child: _LocationFilterBar(
                          locations: _summary!.byLocation,
                          selected: _filterSafeBoxId,
                          onSelected: (id) {
                            setState(() => _filterSafeBoxId = id);
                            _load();
                          },
                        )),
                        if (_buckets.isEmpty)
                          const SliverFillRemaining(
                            child: Center(child: Text('لا توجد أرصدة مسجّلة')),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (_, i) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: BucketBalanceCard.fromBucket(_buckets[i]),
                                ),
                                childCount: _buckets.length,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
        // Hide "بدء جرد" FAB when a session is already active — banner handles it
        floatingActionButton: _activeSession == null
            ? FloatingActionButton.extended(
                onPressed: _openCountSession,
                backgroundColor: _cs(context).primary,
                foregroundColor: _cs(context).onPrimary,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('بدء جرد'),
              )
            : null,
      ),
    );
  }

  void _openCountSession() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const InventoryCountScreen()),
    ).then((_) => _load());
  }

  void _resumeSession() {
    final s = _activeSession;
    if (s == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InventoryCountScreen(sessionId: s.id),
      ),
    ).then((_) => _load());
  }
}

// ── Freeze Banner ─────────────────────────────────────────────────────────────

class _FreezeBanner extends StatelessWidget {
  const _FreezeBanner({required this.session, required this.onResume});
  final CountSession session;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final counted = session.linesCounted ?? session.lines.where((l) => l.isCounted).length;
    final total = session.linesTotal ?? session.lines.length;
    final awaitingApproval = session.status == 'closed';
    final progress = total == 0 ? 0.0 : counted / total;
    final elapsed = _elapsed(session.openedAt);

    // Branch name from lines if available, else ID
    final branchLabel = session.safeBoxName ?? 'كل المواقع';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      decoration: BoxDecoration(
        color: _tn(context).warning.container,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _tn(context).warning.fg, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: _tn(context).warning.fg.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _tn(context).warning.fg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
            ),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, size: 16, color: _cs(context).surface),
                const SizedBox(width: 6),
                Text(
                  awaitingApproval ? 'جرد بانتظار الاعتماد' : 'جلسة جرد قيد التنفيذ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: _cs(context).surface,
                  ),
                ),
                const Spacer(),
                Text(
                  session.isOpening ? 'افتتاحي' : 'دوري',
                  style: TextStyle(fontSize: 11, color: _cs(context).surface),
                ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.store_outlined, size: 16, color: _tn(context).warning.onContainer),
                    const SizedBox(width: 6),
                    Text(branchLabel,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: _tn(context).warning.onContainer)),
                    const Spacer(),
                    if (elapsed.isNotEmpty)
                      Text(
                        'بدأت $elapsed',
                        style: TextStyle(fontSize: 12, color: _tn(context).warning.onContainer),
                      ),
                  ],
                ),
                if (total > 0) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor:
                                _tn(context).warning.fg.withValues(alpha: 0.25),
                            color: _tn(context).warning.fg,
                            minHeight: 6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$counted / $total',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: _tn(context).warning.onContainer),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(awaitingApproval ? 'مراجعة واعتماد' : 'متابعة الجرد'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _tn(context).warning.fg,
                      foregroundColor: _cs(context).surface,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _elapsed(DateTime? openedAt) {
    if (openedAt == null) return '';
    final diff = DateTime.now().difference(openedAt);
    if (diff.inMinutes < 1) return 'للتو';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }
}

// ── Summary Header ────────────────────────────────────────────────────────────

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.summary});
  final InventoryBalanceSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_cs(context).primary, _cs(context).primary],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _cs(context).primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'إجمالي الذهب (بالعيار الرئيسي)',
            style: TextStyle(color: _cs(context).onPrimary, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${formatWeight(summary.grandTotalWeight)} جم',
            style: TextStyle(
              color: _cs(context).onPrimary,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (summary.unclassifiedWeight.abs() > 0.0005)
            Text(
              'منه بلا تصنيف: ${formatWeight(summary.unclassifiedWeight)} جم — يُصنَّف بالجرد',
              style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12),
            ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: summary.byKarat.map((k) => _KaratChip(k)).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _KaratChip extends StatelessWidget {
  const _KaratChip(this.k);
  final KaratTotal k;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _cs(context).shadow.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _cs(context).onPrimary.withValues(alpha: 0.3)),
      ),
      child: Text(
        'عيار ${k.karat.toStringAsFixed(0)}  ${formatWeight(k.totalWeight)} جم',
        style: TextStyle(
            color: _cs(context).onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Filter Bars ───────────────────────────────────────────────────────────────

class _KaratFilterBar extends StatelessWidget {
  const _KaratFilterBar({
    required this.karats,
    required this.selected,
    required this.onSelected,
  });
  final List<double> karats;
  final double? selected;
  final ValueChanged<double?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _FilterChip(
            label: 'كل العيارات',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          ...karats.map((k) => _FilterChip(
                label: 'عيار ${k.toStringAsFixed(0)}',
                selected: selected == k,
                color: _tn(context).karat(((k) as num).round()).fg,
                onTap: () => onSelected(selected == k ? null : k),
              )),
        ],
      ),
    );
  }
}

class _LocationFilterBar extends StatelessWidget {
  const _LocationFilterBar({
    required this.locations,
    required this.selected,
    required this.onSelected,
  });
  final List<LocationTotal> locations;
  final int? selected;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (locations.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _FilterChip(
            label: 'كل المواقع',
            selected: selected == null,
            onTap: () => onSelected(null),
          ),
          ...locations.map((l) => _FilterChip(
                label: l.safeBoxName,
                selected: selected == l.safeBoxId,
                onTap: () => onSelected(
                    selected == l.safeBoxId ? null : l.safeBoxId),
              )),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? _cs(context).primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c : _cs(context).outlineVariant),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _cs(context).onPrimary : _cs(context).onSurfaceVariant,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

// ── Error View ────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: _tn(context).warning.fg),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _cs(context).primary,
                foregroundColor: _cs(context).onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
