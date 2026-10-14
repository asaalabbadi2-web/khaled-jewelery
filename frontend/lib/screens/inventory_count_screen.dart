import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../models/inventory_models.dart';
import '../models/safe_box_model.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bucket_balance_card.dart' show formatWeight;
import '../theme/app_semantic_colors.dart';

/// The theme's colours (ADR-038): the scheme and the semantic tones.
ColorScheme _cs(BuildContext context) => Theme.of(context).colorScheme;
AppSemanticColors _tn(BuildContext context) => AppSemanticColors.of(context);

/// Screen 2 — Count Session Workspace.
///
/// Two roles, two modes:
///   Employee (counting): simple weight-entry table, no expected values shown.
///   Manager (review):    variance table + approve with coded reason.
///
/// Design invariants:
///   • Blind count enforced server-side; UI only hides/shows based on flag.
///   • Save on blur/Enter only — never on keystroke.
///   • Pull-to-refresh for multi-device awareness without websockets.
/// A count line's name: its category -- «بلا تصنيف» without one, a line counted
/// like any other (ADR-045) -- and its location when it has one.
String countLineLabel(CountLine line) {
  final category = (line.categoryName != null && line.categoryName!.isNotEmpty)
      ? line.categoryName!
      : 'بلا تصنيف';
  return line.safeBoxName != null ? '$category — ${line.safeBoxName}' : category;
}

class InventoryCountScreen extends StatefulWidget {
  final int? sessionId;
  const InventoryCountScreen({super.key, this.sessionId});

  @override
  State<InventoryCountScreen> createState() => _InventoryCountScreenState();
}

class _InventoryCountScreenState extends State<InventoryCountScreen> {
  final _svc = InventoryService(ApiService());

  CountSession? _session;
  bool _loading = true;
  String? _error;
  late List<_LineState> _lineStates;

  int _currentIndex = 0;
  final _navScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _lineStates = [];
    if (widget.sessionId != null) {
      _loadSession(widget.sessionId!);
    } else {
      _showOpenSessionSheet();
    }
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _loadSession(int id) async {
    setState(() { _loading = true; _error = null; });
    try {
      final s = await _svc.getSession(id);
      _applySession(s);
    } on InventoryApiException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  void dispose() {
    _navScrollController.dispose();
    super.dispose();
  }

  void _applySession(CountSession s) {
    setState(() {
      _session = s;
      _lineStates = s.lines.map((l) => _LineState(line: l)).toList();
      _loading = false;
      final firstUncounted = _lineStates.indexWhere((ls) => !ls.line.isCounted);
      _currentIndex = firstUncounted == -1 ? 0 : firstUncounted;
    });
  }

  Future<void> _refresh() async {
    if (_session == null) return;
    await _loadSession(_session!.id);
  }

  // ── Open session sheet ────────────────────────────────────────────────────

  void _showOpenSessionSheet() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _OpenSessionSheet(
          svc: _svc,
          onOpened: (s) {
            Navigator.pop(context);
            _applySession(s);
          },
          onCancelled: () {
            Navigator.pop(context);
            Navigator.pop(context);
          },
          onNavigateToSession: (id) {
            Navigator.pop(context);
            _loadSession(id);
          },
        ),
      );
    });
  }

  // ── Save entry ────────────────────────────────────────────────────────────

  Future<void> _saveEntry(_LineState ls, double value) async {
    // «بلا تصنيف» (no category) is counted like any line (ADR-045).
    if (_session == null) return;
    setState(() => ls.status = CountLineStatus.saving);
    try {
      final updated = await _svc.recordEntry(
        sessionId: _session!.id,
        categoryId: ls.line.categoryId,
        karat: ls.line.karat,
        countedWeight: value,
        safeBoxId: ls.line.safeBoxId ?? _session!.safeBoxId,
      );
      final refreshed = await _svc.getSession(_session!.id);
      setState(() {
        ls.line = updated.copyWith(uiStatus: CountLineStatus.saved);
        ls.status = CountLineStatus.saved;
        ls.savedAt = DateTime.now();
        _session = refreshed;
      });
    } on InventoryApiException catch (e) {
      setState(() => ls.status = CountLineStatus.failed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: _cs(context).error),
        );
      }
    }
  }

  // ── Focused mode navigation ───────────────────────────────────────────────

  void _advanceFromIndex(int from) {
    for (int i = from + 1; i < _lineStates.length; i++) {
      if (!_lineStates[i].line.isCounted) {
        setState(() => _currentIndex = i);
        _scrollNavTo(i);
        return;
      }
    }
    for (int i = 0; i < from; i++) {
      if (!_lineStates[i].line.isCounted) {
        setState(() => _currentIndex = i);
        _scrollNavTo(i);
        return;
      }
    }
    // All counted — stay in place
  }

  void _scrollNavTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_navScrollController.hasClients) {
        final target = (index * 88.0).clamp(
          0.0,
          _navScrollController.position.maxScrollExtent,
        );
        _navScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _saveAndAdvance(int index, double value) async {
    final ls = _lineStates[index];
    if (ls.status == CountLineStatus.saving) return;
    // Advance immediately — don't block on network for scale-paced rhythm
    _advanceFromIndex(index);
    // Save in background; errors surface via SnackBar in _saveEntry
    _saveEntry(ls, value);
  }

  String _itemLabel(CountLine line) =>
      '${countLineLabel(line)} ${line.karat.toStringAsFixed(0)}K';

  // ── Add item (opening sessions) ───────────────────────────────────────────

  void _showAddItemSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AddItemSheet(
        fixedLocationId: _session!.safeBoxId,
        onAdd: (safeBoxId, safeBoxName, categoryId, categoryName, karat, weight) async {
          Navigator.pop(context);
          // Create a temporary _LineState so the row appears immediately
          final tempLine = CountLine(
            id: -DateTime.now().millisecondsSinceEpoch,
            sessionId: _session!.id,
            branchId: _session!.branchId,
            safeBoxId: safeBoxId,
            safeBoxName: safeBoxName,
            categoryId: categoryId,
            categoryName: categoryName,
            karat: karat,
            countedWeight: weight,
          );
          final ls = _LineState(line: tempLine);
          setState(() => _lineStates.add(ls));
          await _saveEntry(ls, weight);
        },
      ),
    );
  }

  // ── Close session ─────────────────────────────────────────────────────────

  Future<void> _closeSession() async {
    final counted = _lineStates.where((l) => l.line.isCounted).length;
    final uncountedCount = _lineStates.length - counted;
    final hasUncounted = uncountedCount > 0;
    final isOpening = _session?.isOpening ?? false;

    // result: (confirmed, force, zeroUncounted)
    final result = await showDialog<({bool confirmed, bool force, bool zeroUncounted})>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('إنهاء العدّ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hasUncounted
                ? 'تم عدّ $counted من ${_lineStates.length} صنف.'
                : 'تم عدّ جميع الأصناف بنجاح.'),
            if (hasUncounted) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _tn(context).warning.fg.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _tn(context).warning.fg.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: _tn(context).warning.fg, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isOpening
                            ? '$uncountedCount صنف لم يُدخَل وزنه.'
                            : '$uncountedCount صنف لم يُعدّ — قد تكون خارج المحل.',
                        style: TextStyle(
                            fontSize: 12, color: _tn(context).warning.fg),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('تراجع'),
          ),
          // Periodic: allow force-close leaving uncounted lines as NULL
          if (hasUncounted && !isOpening)
            TextButton(
              onPressed: () => Navigator.pop(
                  context, (confirmed: true, force: true, zeroUncounted: false)),
              child: Text('إغلاق مع تحذير',
                  style: TextStyle(color: _tn(context).warning.fg)),
            ),
          // Opening: set uncounted lines to 0 automatically
          if (hasUncounted && isOpening)
            TextButton(
              onPressed: () => Navigator.pop(
                  context, (confirmed: true, force: false, zeroUncounted: true)),
              child: Text('سجّل الباقي كصفر وأغلق',
                  style: TextStyle(color: _tn(context).sectionTeal.fg)),
            ),
          ElevatedButton(
            onPressed: hasUncounted
                ? null
                : () => Navigator.pop(
                    context, (confirmed: true, force: false, zeroUncounted: false)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _cs(context).primary,
              foregroundColor: _cs(context).onPrimary,
              disabledBackgroundColor: _cs(context).outlineVariant,
            ),
            child: const Text('إنهاء العدّ'),
          ),
        ],
      ),
    );

    if (result == null || !result.confirmed || !mounted) return;

    setState(() => _loading = true);
    try {
      final r = await _svc.closeSession(
        _session!.id,
        force: result.force,
        zeroUncounted: result.zeroUncounted,
      );
      _applySession(r.session);
      if (r.uncountedLines > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${r.uncountedLines} صنف غير معدود — ستظهر في تقرير المطابقة'),
          backgroundColor: _tn(context).warning.fg,
          duration: const Duration(seconds: 4),
        ));
      }
    } on InventoryApiException catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: _cs(context).error),
        );
      }
    }
  }

  // ── Cancel session ────────────────────────────────────────────────────────

  Future<void> _cancelSession() async {
    final readingCount = _lineStates.where((l) => l.line.isCounted).length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('إلغاء الجرد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              readingCount > 0
                  ? 'سيتم إبطال جميع القراءات المسجلة في هذه الجلسة ($readingCount قراءة).'
                  : 'سيتم إبطال هذه الجلسة.',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            _InfoChip(
              icon: Icons.shield_outlined,
              label: 'لن تؤثر على المخزون أو التسويات.',
              color: _tn(context).info.fg,
            ),
            const SizedBox(height: 6),
            _InfoChip(
              icon: Icons.warning_amber_rounded,
              label: 'لا يمكن التراجع.',
              color: _tn(context).warning.fg,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _cs(context).error,
              foregroundColor: _cs(context).onError,
            ),
            child: const Text('إلغاء الجرد'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _loading = true);
    try {
      await _svc.cancelSession(_session!.id);
      if (mounted) Navigator.pop(context);
    } on InventoryApiException catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: _cs(context).error),
        );
      }
    }
  }

  // ── Approve ───────────────────────────────────────────────────────────────

  Future<bool> _showOpeningApproveConfirm() async {
    final total = _lineStates.length;
    final counted = _lineStates.where((l) => l.line.isCounted).length;
    final totalWeight = _lineStates
        .where((l) => l.line.countedWeight != null)
        .fold(0.0, (s, l) => s + l.line.countedWeight!);

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.lock_outlined, color: _cs(context).primary),
                  SizedBox(width: 8),
                  Text('اعتماد الرصيد الافتتاحي'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _WillDo('تسجيل $counted بند كرصيد افتتاحي'),
                  _WillDo('إجمالي ${formatWeight(totalWeight)} جم في الدفاتر'),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _tn(context).warning.fg.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _tn(context).warning.fg.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: _tn(context).warning.fg, size: 16),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'هذا الإجراء لا يمكن التراجع عنه.\nالجرد الافتتاحي يُنفَّذ مرة واحدة فقط.',
                            style: TextStyle(
                                fontSize: 12, color: _tn(context).warning.fg),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (counted < total) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${total - counted} صنف لم يُدخَل وزنه — سيُسجَّل كصفر.',
                      style: TextStyle(
                          fontSize: 12, color: _cs(context).onSurfaceVariant),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('تراجع'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _tn(context).ready.fg,
                    foregroundColor: _cs(context).surface,
                  ),
                  child: const Text('اعتماد الرصيد'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _approveSession() async {
    if (_session == null) return;

    // Opening sessions: simplified confirm — no variance, no reason code
    if (_session!.isOpening) {
      final ok = await _showOpeningApproveConfirm();
      if (!ok || !mounted) return;
      setState(() => _loading = true);
      try {
        final result = await _svc.approveSession(_session!.id);
        _applySession(result.session);
        if (mounted) await _showSuccessDialog(result.session, entryNumber: result.entryNumber);
      } on InventoryApiException catch (e) {
        setState(() => _loading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.message), backgroundColor: _cs(context).error),
          );
        }
      }
      return;
    }

    // Periodic sessions: full dialog with reason codes
    final totalLines = _lineStates.length;
    final netDelta = _lineStates
        .where((l) => l.line.variance != null)
        .fold(0.0, (sum, l) => sum + l.line.variance!);
    final varLines = _lineStates
        .where((l) => l.line.variance != null && l.line.variance != 0)
        .toList()
      ..sort((a, b) => b.line.variance!.abs().compareTo(a.line.variance!.abs()));

    final approved = await showDialog<({String code, String note})?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ApproveDialog(
        varLines: varLines,
        session: _session!,
        svc: _svc,
        totalLines: totalLines,
        netDelta: netDelta,
      ),
    );
    if (approved == null || !mounted) return;

    setState(() => _loading = true);
    try {
      final result = await _svc.approveSession(
        _session!.id,
        reasonCode: approved.code,
        note: approved.note,
      );
      _applySession(result.session);
      if (mounted) {
        await _showSuccessDialog(
          result.session,
          entryNumber: result.entryNumber,
        );
      }
    } on InventoryApiException catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: _cs(context).error),
        );
      }
    }
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes < 1) return 'أقل من دقيقة';
    if (d.inHours < 1) return '${d.inMinutes} دقيقة';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return m > 0 ? '$h ساعة و$m دقيقة' : '$h ساعة';
  }

  /// [entryNumber]: the differences' posted entry in the books (ADR-045) --
  /// null when nothing differed.
  Future<void> _showSuccessDialog(CountSession approved, {String? entryNumber}) async {
    final totalLines = _lineStates.length;
    final varCount = _lineStates
        .where((l) => l.line.variance != null && l.line.variance != 0)
        .length;
    final netDelta = _lineStates
        .where((l) => l.line.variance != null)
        .fold(0.0, (sum, l) => sum + l.line.variance!);

    Duration? elapsed;
    if (approved.openedAt != null && approved.approvedAt != null) {
      elapsed = approved.approvedAt!.difference(approved.openedAt!);
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_rounded,
                  size: 64, color: _tn(context).ready.fg),
              const SizedBox(height: 12),
              const Text(
                'تم اعتماد الجرد',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              _SuccessStat(label: 'بنداً', value: '$totalLines'),
              if (varCount > 0)
                _SuccessStat(
                  label: 'فروقات',
                  value: varCount.toString(),
                  sub: '${netDelta >= 0 ? '+' : ''}${formatWeight(netDelta)} جم',
                  subColor: netDelta >= 0 ? _tn(context).ready.fg : _cs(context).error,
                ),
              if (elapsed != null)
                _SuccessStat(
                    label: 'استغرق', value: _formatDuration(elapsed)),
              if (approved.openedBy != null)
                _SuccessStat(label: 'بدأه', value: approved.openedBy!),
              if (approved.approvedBy != null)
                _SuccessStat(label: 'اعتمده', value: approved.approvedBy!),
              _SuccessStat(
                label: 'قيد الفروق',
                value: entryNumber ?? 'لا فروق — لا قيد',
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: _tn(context).ready.fg,
                foregroundColor: _cs(context).surface,
                minimumSize: const Size(120, 44),
              ),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final isOpening = s?.isOpening ?? false;
    final isActive = s?.isActive ?? false;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: s == null
              ? const Text('جلسة جرد جديدة')
              : Text(isOpening ? 'الجرد الافتتاحي' : 'جرد دوري'),
          actions: [
            if (s != null && isActive) ...[
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
                tooltip: 'تحديث',
              ),
              PopupMenuButton<String>(
                onSelected: (v) { if (v == 'cancel') _cancelSession(); },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'cancel',
                    child: Row(children: [
                      Icon(Icons.cancel_outlined, color: _cs(context).error, size: 18),
                      SizedBox(width: 8),
                      Text('إلغاء الجلسة',
                          style: TextStyle(color: _cs(context).error)),
                    ]),
                  ),
                ],
              ),
            ],
          ],
        ),
        body: _loading
            ? Center(
                child: CircularProgressIndicator(color: _cs(context).primary))
            : _error != null
                ? _ErrorRetry(
                    message: _error!,
                    onRetry: s != null
                        ? () => _loadSession(s.id)
                        : _showOpenSessionSheet,
                  )
                : s == null
                    ? const SizedBox.shrink()
                    : _buildBody(s),
        floatingActionButton: (s != null && isActive)
            ? FloatingActionButton.extended(
                onPressed: _showAddItemSheet,
                backgroundColor: _cs(context).primary,
                foregroundColor: _cs(context).onPrimary,
                icon: const Icon(Icons.add),
                label: const Text('إضافة صنف'),
              )
            : null,
        bottomNavigationBar:
            s == null || _loading ? null : _buildBottomBar(s),
      ),
    );
  }

  Widget _buildBody(CountSession s) {
    if (s.isActive) return _buildFocusedBody(s);
    return _buildReviewBody(s);
  }

  Widget _buildReviewBody(CountSession s) {
    final counted = _lineStates.where((l) => l.line.isCounted).length;
    final total = _lineStates.length;
    return Column(
      children: [
        _ProgressBanner(counted: counted, total: total, session: s),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            color: _cs(context).primary,
            child: _lineStates.isEmpty
                ? _EmptyCountState(
                    isOpening: s.isOpening,
                    isActive: false,
                    onAdd: null,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                    itemCount: _lineStates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _CountLineRow(
                      key: ValueKey(_lineStates[i].line.id),
                      ls: _lineStates[i],
                      session: s,
                      onSave: (val) => _saveEntry(_lineStates[i], val),
                      onRetry: (ls) {
                        if (ls.line.countedWeight != null) {
                          _saveEntry(ls, ls.line.countedWeight!);
                        }
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildFocusedBody(CountSession s) {
    if (_lineStates.isEmpty) {
      return Column(
        children: [
          _ProgressBanner(counted: 0, total: 0, session: s),
          Expanded(
            child: _EmptyCountState(
              isOpening: s.isOpening,
              isActive: true,
              onAdd: _showAddItemSheet,
            ),
          ),
        ],
      );
    }

    final idx = _currentIndex.clamp(0, _lineStates.length - 1);
    final current = _lineStates[idx];
    final counted = _lineStates.where((l) => l.line.isCounted).length;
    final total = _lineStates.length;

    String? nextLabel;
    for (int i = idx + 1; i < _lineStates.length; i++) {
      if (!_lineStates[i].line.isCounted) {
        nextLabel = _itemLabel(_lineStates[i].line);
        break;
      }
    }

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final wide = constraints.maxWidth > 640;
        if (wide) {
          return _buildWideFocusedBody(s, idx, current, counted, total, nextLabel);
        }
        return _buildNarrowFocusedBody(s, idx, current, counted, total, nextLabel);
      },
    );
  }

  Widget _buildNarrowFocusedBody(
    CountSession s, int idx, _LineState current,
    int counted, int total, String? nextLabel,
  ) {
    return Column(
      children: [
        _ProgressBanner(
          counted: counted,
          total: total,
          session: s,
          currentLabel: _itemLabel(current.line),
          nextLabel: nextLabel,
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _FocusedCard(
                key: ValueKey(idx),
                ls: current,
                session: s,
                onSaveAndAdvance: (v) => _saveAndAdvance(idx, v),
                onRetry: () {
                  if (current.line.countedWeight != null) {
                    _saveAndAdvance(idx, current.line.countedWeight!);
                  }
                },
                onPrev: idx > 0 ? () => setState(() => _currentIndex = idx - 1) : null,
                onNext: idx < _lineStates.length - 1
                    ? () => setState(() => _currentIndex = idx + 1)
                    : null,
              ),
            ),
          ),
        ),
        _NavStrip(
          lineStates: _lineStates,
          currentIndex: idx,
          scrollController: _navScrollController,
          onTap: (i) => setState(() => _currentIndex = i),
        ),
      ],
    );
  }

  Widget _buildWideFocusedBody(
    CountSession s, int idx, _LineState current,
    int counted, int total, String? nextLabel,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 260,
          child: _NavList(
            lineStates: _lineStates,
            currentIndex: idx,
            onTap: (i) => setState(() => _currentIndex = i),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              _ProgressBanner(
                counted: counted,
                total: total,
                session: s,
                currentLabel: _itemLabel(current.line),
                nextLabel: nextLabel,
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _FocusedCard(
                      key: ValueKey(idx),
                      ls: current,
                      session: s,
                      onSaveAndAdvance: (v) => _saveAndAdvance(idx, v),
                      onRetry: () {
                        if (current.line.countedWeight != null) {
                          _saveAndAdvance(idx, current.line.countedWeight!);
                        }
                      },
                      onPrev: idx > 0 ? () => setState(() => _currentIndex = idx - 1) : null,
                      onNext: idx < _lineStates.length - 1
                          ? () => setState(() => _currentIndex = idx + 1)
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(CountSession s) {
    final counted = _lineStates.where((l) => l.line.isCounted).length;
    final total = _lineStates.length;
    final allDone = counted == total && total > 0;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
            BoxShadow(color: _cs(context).shadow.withValues(alpha: 0.08), blurRadius: 8)
          ],
        ),
        child: Row(
          children: [
            if (s.status == 'open' || s.status == 'counting') ...[
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: counted > 0 ? _closeSession : null,
                  icon: Icon(allDone
                      ? Icons.check_circle_outline
                      : Icons.lock_clock),
                  label: Text(allDone
                      ? 'انتهيت — إنهاء العدّ'
                      : 'إنهاء العدّ ($counted/$total)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        allDone ? _tn(context).ready.fg : _cs(context).primary,
                    foregroundColor: _cs(context).onPrimary,
                    disabledBackgroundColor: _cs(context).outlineVariant,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
            if (s.status == 'closed')
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _approveSession,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('اعتماد الجرد'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _tn(context).ready.fg,
                    foregroundColor: _cs(context).surface,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            if (s.status == 'approved')
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: _tn(context).ready.fg.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _tn(context).ready.fg.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle,
                          color: _tn(context).ready.fg, size: 20),
                      SizedBox(width: 8),
                      Text('تم الاعتماد بنجاح',
                          style: TextStyle(
                              color: _tn(context).ready.fg,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Progress Banner ───────────────────────────────────────────────────────────

class _ProgressBanner extends StatelessWidget {
  const _ProgressBanner({
    required this.counted,
    required this.total,
    required this.session,
    this.currentLabel,
    this.nextLabel,
  });
  final int counted;
  final int total;
  final CountSession session;
  final String? currentLabel;
  final String? nextLabel;

  @override
  Widget build(BuildContext context) {
    final isActive = session.isActive;
    final isApproved = session.status == 'approved';
    final isClosed = session.status == 'closed';
    final progress = total == 0 ? 0.0 : counted / total;

    Color barColor;
    String label;

    if (isApproved) {
      barColor = _tn(context).ready.fg;
      label = 'معتمد — تم تحديث الأرصدة';
    } else if (isClosed) {
      barColor = _cs(context).primary;
      label = 'بانتظار اعتماد المدير';
    } else if (total == 0) {
      barColor = _cs(context).onSurfaceVariant;
      label = session.isOpening
          ? 'اضغط + لإضافة الأصناف'
          : 'لا توجد أصناف في هذا الفرع';
    } else if (counted == total) {
      barColor = _tn(context).ready.fg;
      label = 'تم عدّ جميع الأصناف ✓';
    } else {
      barColor = _cs(context).primary;
      label = 'تم عدّ $counted من $total صنف';
    }

    // primaryGold (#D4AF37) fails contrast on near-white bg — use darkGold for text
    final labelColor = barColor == _cs(context).primary
        ? _cs(context).primary
        : barColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: barColor.withValues(alpha: 0.05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Label row ────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
              ),
              if (session.blindCount && isActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _tn(context).info.fg.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_off, size: 12, color: _tn(context).info.fg),
                      SizedBox(width: 4),
                      Text('أعمى',
                          style: TextStyle(fontSize: 11, color: _tn(context).info.fg)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // ── Progress bar + counter ────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : progress,
                    backgroundColor: _cs(context).outlineVariant,
                    color: barColor,
                    minHeight: 10,
                  ),
                ),
              ),
              if (total > 0) ...[
                const SizedBox(width: 10),
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '$counted',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: labelColor,
                        ),
                      ),
                      TextSpan(
                        text: ' / $total',
                        style: TextStyle(
                          fontSize: 13,
                          color: _cs(context).onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          // ── Current / next hint (focused mode only) ──────────────────
          if (currentLabel != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.my_location, size: 11, color: labelColor.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  currentLabel!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: labelColor,
                  ),
                ),
                if (nextLabel != null) ...[
                  Text('  ←  ',
                      style: TextStyle(fontSize: 11, color: _cs(context).outline)),
                  Icon(Icons.navigate_next, size: 13, color: _cs(context).outline),
                  const SizedBox(width: 2),
                  Text(
                    nextLabel!,
                    style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Empty count state ─────────────────────────────────────────────────────────

class _EmptyCountState extends StatelessWidget {
  const _EmptyCountState({
    required this.isOpening,
    required this.isActive,
    this.onAdd,
  });
  final bool isOpening;
  final bool isActive;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final String message;
    final IconData icon;

    if (isOpening) {
      icon = Icons.add_box_outlined;
      message = 'لا توجد أصناف بعد\nاضغط + لإضافة أول صنف';
    } else if (isActive) {
      icon = Icons.inventory_2_outlined;
      message = 'لا يوجد رصيد مسجّل لهذا الفرع\n'
          'إذا كانت هذه أول جلسة، أغلقها\n'
          'وافتح جرداً افتتاحياً بدلاً منها';
    } else {
      icon = Icons.inventory_2_outlined;
      message = 'لا توجد أصناف مسجّلة في هذا الفرع';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: _cs(context).outlineVariant),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: _cs(context).onSurfaceVariant, fontSize: 15, height: 1.6),
            ),
            if (isActive && onAdd != null) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('إضافة صنف يدوياً'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cs(context).primary,
                  foregroundColor: _cs(context).onPrimary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Focused Card ─────────────────────────────────────────────────────────────

class _FocusedCard extends StatefulWidget {
  const _FocusedCard({
    super.key,
    required this.ls,
    required this.session,
    required this.onSaveAndAdvance,
    required this.onRetry,
    this.onPrev,
    this.onNext,
  });
  final _LineState ls;
  final CountSession session;
  final ValueChanged<double> onSaveAndAdvance;
  final VoidCallback onRetry;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  State<_FocusedCard> createState() => _FocusedCardState();
}

class _FocusedCardState extends State<_FocusedCard> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.ls.line.countedWeight?.toStringAsFixed(3) ?? '',
    );
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text.endsWith('.')) return;
    final val = double.tryParse(text);
    if (val == null) return;
    widget.onSaveAndAdvance(val);
  }

  @override
  Widget build(BuildContext context) {
    final ls = widget.ls;
    final line = ls.line;
    final karat = line.karat;
    final karatColor = _tn(context).karat(((karat) as num).round()).fg;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final badgeTextColor =
        isDark ? karatColor : _tn(context).karat(((karat) as num).round()).onContainer;
    final categoryLabel = countLineLabel(line);
    final saved = ls.status == CountLineStatus.saved || line.isCounted;
    final saving = ls.status == CountLineStatus.saving;
    final failed = ls.status == CountLineStatus.failed;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: saved
                ? _tn(context).ready.fg.withValues(alpha: 0.04)
                : Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: failed
                  ? _cs(context).error.withValues(alpha: 0.5)
                  : saved
                      ? _tn(context).ready.fg.withValues(alpha: 0.4)
                      : karatColor.withValues(alpha: 0.2),
              width: saved || failed ? 1.5 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: (saved ? _tn(context).ready.fg : karatColor).withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Category name
              Text(
                categoryLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // Karat badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: karatColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'عيار ${karat.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: badgeTextColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              // Weight input — oversized for scale reading
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  suffixText: 'جم',
                  suffixStyle: TextStyle(fontSize: 18, color: _cs(context).onSurfaceVariant),
                  hintText: '0.000',
                  hintStyle: TextStyle(
                    fontSize: 36,
                    color: _cs(context).outlineVariant,
                    fontWeight: FontWeight.bold,
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: karatColor, width: 2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: saved
                          ? _tn(context).ready.fg.withValues(alpha: 0.4)
                          : _cs(context).outlineVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Status row
              SizedBox(
                height: 24,
                child: saving
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _cs(context).primary),
                      )
                    : ls.savedAt != null && !failed
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle,
                                  size: 14, color: _tn(context).ready.fg),
                              const SizedBox(width: 5),
                              Text(
                                'حُفظ ${_savedAgo(ls.savedAt!)}',
                                style: TextStyle(
                                    fontSize: 12, color: _cs(context).onSurfaceVariant),
                              ),
                            ],
                          )
                        : failed
                            ? GestureDetector(
                                onTap: widget.onRetry,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.replay,
                                        size: 14, color: _cs(context).error),
                                    SizedBox(width: 4),
                                    Text('فشل الحفظ — اضغط للمحاولة',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: _cs(context).error)),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink(),
              ),
              const SizedBox(height: 20),
              // Action buttons
              Row(
                children: [
                  // حفظ + التالي — primary action
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.save_alt_outlined, size: 16),
                      label: const Text('حفظ + التالي'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _cs(context).primary,
                        foregroundColor: _cs(context).onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // السابق — secondary
                  OutlinedButton.icon(
                    onPressed: widget.onPrev,
                    icon: const Icon(Icons.arrow_forward_ios, size: 13),
                    label: const Text('السابق'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _cs(context).onSurfaceVariant,
                      side: BorderSide(color: _cs(context).outlineVariant),
                      padding: const EdgeInsets.symmetric(
                          vertical: 13, horizontal: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  'أو Enter من لوحة المفاتيح',
                  style: TextStyle(fontSize: 11, color: _cs(context).outline),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _savedAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'قبل ${diff.inSeconds} ث';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    return 'قبل ${diff.inHours} س';
  }
}

// ── Nav Strip (narrow) ────────────────────────────────────────────────────────

class _NavStrip extends StatelessWidget {
  const _NavStrip({
    required this.lineStates,
    required this.currentIndex,
    required this.scrollController,
    required this.onTap,
  });
  final List<_LineState> lineStates;
  final int currentIndex;
  final ScrollController scrollController;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(top: BorderSide(color: _cs(context).outlineVariant)),
      ),
      child: ListView.builder(
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: lineStates.length,
        itemBuilder: (_, i) {
          final ls = lineStates[i];
          final isCurrent = i == currentIndex;
          final isDone = ls.line.isCounted;
          final karatColor = _tn(context).karat(((ls.line.karat) as num).round()).fg;

          return GestureDetector(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isCurrent
                    ? _cs(context).primary
                    : isDone
                        ? _tn(context).ready.fg.withValues(alpha: 0.1)
                        : _cs(context).surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isCurrent
                      ? _cs(context).primary
                      : isDone
                          ? _tn(context).ready.fg.withValues(alpha: 0.35)
                          : _cs(context).outlineVariant,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isCurrent
                          ? _cs(context).onPrimary
                          : isDone
                              ? _tn(context).ready.fg
                              : karatColor.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${i + 1}  ${ls.line.karat.toStringAsFixed(0)}K',
                    style: TextStyle(
                      fontSize: 12,
                      color: isCurrent ? _cs(context).onPrimary : null,
                      fontWeight: isCurrent ? FontWeight.bold : null,
                    ),
                  ),
                  if (isDone && !isCurrent) ...[
                    const SizedBox(width: 3),
                    Icon(Icons.check, size: 10, color: _tn(context).ready.fg),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Nav List (wide layout) ────────────────────────────────────────────────────

class _NavList extends StatelessWidget {
  const _NavList({
    required this.lineStates,
    required this.currentIndex,
    required this.onTap,
  });
  final List<_LineState> lineStates;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: lineStates.length,
        itemBuilder: (_, i) {
          final ls = lineStates[i];
          final isCurrent = i == currentIndex;
          final isDone = ls.line.isCounted;
          final karatColor = _tn(context).karat(((ls.line.karat) as num).round()).fg;
          final label = countLineLabel(ls.line);

          return InkWell(
            onTap: () => onTap(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isCurrent
                    ? _cs(context).primary.withValues(alpha: 0.1)
                    : Colors.transparent,
                border: Border(
                  right: BorderSide(
                    color: isCurrent ? _cs(context).primary : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDone ? _tn(context).ready.fg : karatColor.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isCurrent
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'عيار ${ls.line.karat.toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 11, color: _cs(context).onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (isDone)
                    Icon(Icons.check_circle,
                        size: 16, color: _tn(context).ready.fg)
                  else
                    Text(
                      '${i + 1}',
                      style: TextStyle(
                          fontSize: 11, color: _cs(context).outline),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Count Line Row ────────────────────────────────────────────────────────────

class _CountLineRow extends StatefulWidget {
  const _CountLineRow({
    super.key,
    required this.ls,
    required this.session,
    required this.onSave,
    required this.onRetry,
  });
  final _LineState ls;
  final CountSession session;
  final ValueChanged<double> onSave;
  final ValueChanged<_LineState> onRetry;

  @override
  State<_CountLineRow> createState() => _CountLineRowState();
}

class _CountLineRowState extends State<_CountLineRow> {
  late final TextEditingController _ctrl;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.ls.line.countedWeight?.toStringAsFixed(2) ?? '',
    );
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_CountLineRow old) {
    super.didUpdateWidget(old);
    final newWeight = widget.ls.line.countedWeight;
    final oldWeight = old.ls.line.countedWeight;
    if (newWeight != oldWeight && !_focus.hasFocus) {
      _ctrl.text = newWeight?.toStringAsFixed(2) ?? '';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final val = double.tryParse(_ctrl.text.trim());
    if (val == null) return;
    if (val == widget.ls.line.countedWeight) return;
    widget.onSave(val);
  }

  bool get _editable =>
      widget.session.status == 'open' || widget.session.status == 'counting';

  bool get _isBlind =>
      widget.session.blindCount && widget.session.isActive;

  @override
  Widget build(BuildContext context) {
    final ls = widget.ls;
    final line = ls.line;
    final karat = line.karat;
    final karatColor = _tn(context).karat(((karat) as num).round()).fg;
    final categoryLabel = countLineLabel(line);

    // ── Counting mode (employee view) ─────────────────────────────────────
    if (_editable || (_isBlind && !_editable)) {
      return _buildCountingCard(ls, line, karat, karatColor, categoryLabel);
    }

    // ── Review mode (manager view after close) ────────────────────────────
    return _buildReviewCard(ls, line, karat, karatColor, categoryLabel);
  }

  Widget _buildCountingCard(
    _LineState ls,
    CountLine line,
    double karat,
    Color karatColor,
    String categoryLabel,
  ) {
    final saved = ls.status == CountLineStatus.saved || line.isCounted;
    final saving = ls.status == CountLineStatus.saving;
    final failed = ls.status == CountLineStatus.failed;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final badgeTextColor =
        isDark ? karatColor : _tn(context).karat(((karat) as num).round()).onContainer;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: saved
            ? _tn(context).ready.fg.withValues(alpha: 0.04)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: failed
              ? _cs(context).error.withValues(alpha: 0.5)
              : saved
                  ? _tn(context).ready.fg.withValues(alpha: 0.25)
                  : _cs(context).outlineVariant,
          width: saved ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: category + karat + save indicator
          Row(
            children: [
              Expanded(
                child: Text(
                  categoryLabel,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: karatColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'عيار ${karat.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: badgeTextColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 20,
                height: 20,
                child: saving
                    ? CircularProgressIndicator(
                        strokeWidth: 2, color: _cs(context).primary)
                    : saved
                        ? Icon(Icons.check_circle,
                            size: 20, color: _tn(context).ready.fg)
                        : failed
                            ? Icon(Icons.error_outline,
                                size: 20, color: _cs(context).error)
                            : const SizedBox(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Weight input
          _editable
              ? TextField(
                  controller: _ctrl,
                  focusNode: _focus,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _commit(),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    suffixText: 'جم',
                    suffixStyle: TextStyle(
                        fontSize: 14, color: _cs(context).onSurfaceVariant),
                    hintText: '0.000',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: karatColor, width: 2),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: saved
                            ? _tn(context).ready.fg.withValues(alpha: 0.4)
                            : _cs(context).outlineVariant,
                      ),
                    ),
                  ),
                )
              : Text(
                  line.countedWeight != null
                      ? '${formatWeight(line.countedWeight!)} جم'
                      : '—',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
          if (ls.savedAt != null && !failed) ...[
            const SizedBox(height: 5),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check, size: 12, color: _tn(context).ready.fg),
                const SizedBox(width: 3),
                Text(
                  'حُفظ ${_savedAgo(ls.savedAt!)}',
                  style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant),
                ),
              ],
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => widget.onRetry(ls),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.replay, size: 14, color: _cs(context).error),
                  SizedBox(width: 4),
                  Text('فشل الحفظ — اضغط للمحاولة مجدداً',
                      style:
                          TextStyle(fontSize: 11, color: _cs(context).error)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _savedAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return 'قبل ${diff.inSeconds} ث';
    if (diff.inMinutes < 60) return 'قبل ${diff.inMinutes} د';
    return 'قبل ${diff.inHours} س';
  }

  Widget _buildReviewCard(
    _LineState ls,
    CountLine line,
    double karat,
    Color karatColor,
    String categoryLabel,
  ) {
    final variance = line.variance;
    final hasVariance = variance != null && variance != 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final badgeTextColor =
        isDark ? karatColor : _tn(context).karat(((karat) as num).round()).onContainer;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: hasVariance
            ? _tn(context).warning.fg.withValues(alpha: 0.05)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasVariance
              ? _tn(context).warning.fg.withValues(alpha: 0.35)
              : _cs(context).outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Text(
                  categoryLabel,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: karatColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'عيار ${karat.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: badgeTextColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Opening session: only show counted weight — no expected/variance
          if (widget.session.isOpening)
            _ReviewCell(
              label: 'الوزن المعدود',
              value: line.countedWeight != null
                  ? '${formatWeight(line.countedWeight!)} جم'
                  : '—',
            )
          else
          // Periodic: comparison row: expected | counted | variance
          Row(
            children: [
              _ReviewCell(
                label: 'المتوقع',
                value: line.expectedWeight != null
                    ? '${formatWeight(line.expectedWeight!)} جم'
                    : '—',
              ),
              const SizedBox(width: 12),
              _ReviewCell(
                label: 'المعدود',
                value: line.countedWeight != null
                    ? '${formatWeight(line.countedWeight!)} جم'
                    : '—',
              ),
              if (variance != null) ...[
                const SizedBox(width: 12),
                _ReviewCell(
                  label: 'الفرق',
                  value: '${variance >= 0 ? '+' : ''}${formatWeight(variance)} جم',
                  valueColor: variance > 0
                      ? _tn(context).ready.fg
                      : variance < 0
                          ? _cs(context).error
                          : _cs(context).onSurfaceVariant,
                  bold: hasVariance,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ReviewCell extends StatelessWidget {
  const _ReviewCell({
    required this.label,
    required this.value,
    this.valueColor,
    this.bold = false,
  });
  final String label;
  final String value;
  final Color? valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style:
                    TextStyle(fontSize: 10, color: _cs(context).onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    bold ? FontWeight.bold : FontWeight.w600,
                color: valueColor,
              ),
            ),
          ],
        ),
      );
}

// ── Approve Dialog ────────────────────────────────────────────────────────────

class _ApproveDialog extends StatefulWidget {
  const _ApproveDialog({
    required this.varLines,
    required this.session,
    required this.svc,
    required this.totalLines,
    required this.netDelta,
  });
  final List<_LineState> varLines;
  final CountSession session;
  final InventoryService svc;
  final int totalLines;
  final double netDelta;

  @override
  State<_ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends State<_ApproveDialog> {
  List<AdjustmentReason> _reasons = [];
  AdjustmentReason? _selectedReason;
  final _noteCtrl = TextEditingController();
  bool _loadingReasons = true;
  bool _confirming = false;

  bool get _needsNote => _selectedReason?.requiresNote ?? false;
  bool get _noteOk => !_needsNote || _noteCtrl.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadReasons();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReasons() async {
    try {
      final reasons = await widget.svc.getAdjustmentReasons();
      if (mounted) {
        setState(() {
          _reasons = reasons.isNotEmpty ? reasons : AdjustmentReason.fallback;
          _selectedReason = _reasons.first;
          _loadingReasons = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _reasons = AdjustmentReason.fallback;
          _selectedReason = _reasons.first;
          _loadingReasons = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _confirming ? _buildConfirmStep() : _buildSummaryStep();
  }

  // ── Step 1: Summary + variances + reason ─────────────────────────────────

  Widget _buildSummaryStep() {
    final hasVariance = widget.varLines.isNotEmpty;
    final canProceed =
        !_loadingReasons && (!hasVariance || _selectedReason != null) && _noteOk;
    final delta = widget.netDelta;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('اعتماد جلسة الجرد'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Big summary strip
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      vertical: 16, horizontal: 12),
                  decoration: BoxDecoration(
                    color: hasVariance
                        ? _tn(context).warning.fg.withValues(alpha: 0.06)
                        : _tn(context).ready.fg.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasVariance
                          ? _tn(context).warning.fg.withValues(alpha: 0.3)
                          : _tn(context).ready.fg.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _BigStat(
                          value: '${widget.totalLines}',
                          label: 'بنداً'),
                      _BigStat(
                          value: '${widget.varLines.length}',
                          label: 'فروقات',
                          color: hasVariance
                              ? _tn(context).warning.fg
                              : _tn(context).ready.fg),
                      _BigStat(
                          value:
                              '${delta >= 0 ? '+' : ''}${formatWeight(delta)} جم',
                          label: 'صافي الفرق',
                          color: delta > 0.001
                              ? _tn(context).ready.fg
                              : delta < -0.001
                                  ? _cs(context).error
                                  : _cs(context).onSurfaceVariant),
                    ],
                  ),
                ),
                // Variance list (sorted descending by absolute value)
                if (hasVariance) ...[
                  const SizedBox(height: 14),
                  Text('الفروقات',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _cs(context).onSurfaceVariant)),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: ListView(
                      shrinkWrap: true,
                      children: widget.varLines.map((ls) {
                        final v = ls.line.variance!;
                        final label = ls.line.categoryName != null
                            ? '${ls.line.categoryName} ${ls.line.karat.toStringAsFixed(0)}K'
                            : 'عيار ${ls.line.karat.toStringAsFixed(0)}';
                        return Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            Icon(
                              v > 0
                                  ? Icons.arrow_upward
                                  : Icons.arrow_downward,
                              size: 14,
                              color: v > 0
                                  ? _tn(context).ready.fg
                                  : _cs(context).error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                                child: Text(label,
                                    style:
                                        const TextStyle(fontSize: 13))),
                            Text(
                              '${v >= 0 ? '+' : ''}${formatWeight(v)} جم',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: v > 0
                                    ? _tn(context).ready.fg
                                    : _cs(context).error,
                              ),
                            ),
                          ]),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Reason dropdown
                  if (_loadingReasons)
                    Center(
                        child: SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _cs(context).primary)))
                  else if (_reasons.isEmpty)
                    _InfoChip(
                        icon: Icons.warning_amber_rounded,
                        label: 'تعذّر تحميل أسباب التسوية',
                        color: _tn(context).warning.fg)
                  else
                    DropdownButtonFormField<AdjustmentReason>(
                      value: _selectedReason,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'سبب التسوية',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                      ),
                      items: _reasons
                          .map((r) => DropdownMenuItem(
                              value: r, child: Text(r.label)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _selectedReason = v),
                    ),
                  // Note field — shown only when requires_note = true
                  if (_needsNote) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _noteCtrl,
                      onChanged: (_) => setState(() {}),
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: 'ملاحظة توضيحية (مطلوبة)',
                        hintText: 'اذكر سبب الفرق بالتفصيل...',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                      ),
                    ),
                  ],
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _InfoChip(
                      icon: Icons.check_circle_outline,
                      label: 'الجرد مطابق تماماً — لا توجد فروقات',
                      color: _tn(context).ready.fg,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: canProceed
                ? () => setState(() => _confirming = true)
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _cs(context).primary,
              foregroundColor: _cs(context).onPrimary,
              disabledBackgroundColor: _cs(context).outlineVariant,
            ),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  }

  // ── Step 2: What-will-happen confirmation ────────────────────────────────

  Widget _buildConfirmStep() {
    final hasVariance = widget.varLines.isNotEmpty;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('تأكيد الاعتماد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('سيتم:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 12),
            // One entry in the books (ADR-045): only the net of a location
            // and karat is a loss or a gain; the rest moves between categories.
            if (hasVariance)
              _WillDo('قيد فروق جرد في الدفاتر — الصافي إلى «خسارة الوزن» أو «زيادة جرد»'),
            _WillDo('رصيد كل تصنيف وموقع يصير ما عُدّ'),
            const SizedBox(height: 14),
            _InfoChip(
              icon: Icons.warning_amber_rounded,
              label: 'هذه العملية لا يمكن التراجع عنها.',
              color: _tn(context).warning.fg,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _confirming = false),
            child: const Text('رجوع'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, (
              code: _selectedReason?.code ?? 'OTHER',
              note: _noteCtrl.text.trim(),
            )),
            icon: const Icon(Icons.verified_outlined),
            label: Text(hasVariance ? 'اعتماد وترحيل' : 'اعتماد'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _tn(context).ready.fg,
              foregroundColor: _cs(context).surface,
            ),
          ),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat(
      {required this.value, required this.label, this.color});
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant)),
        ],
      );
}

class _WillDo extends StatelessWidget {
  const _WillDo(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(Icons.check_circle_outline,
              size: 16, color: _tn(context).ready.fg),
          const SizedBox(width: 8),
          Expanded(
              child:
                  Text(text, style: const TextStyle(fontSize: 13))),
        ]),
      );
}

class _SuccessStat extends StatelessWidget {
  const _SuccessStat(
      {required this.label,
      required this.value,
      this.sub,
      this.subColor});
  final String label;
  final String value;
  final String? sub;
  final Color? subColor;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13, color: _cs(context).onSurfaceVariant)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14)),
                if (sub != null)
                  Text(sub!,
                      style: TextStyle(
                          fontSize: 12, color: subColor)),
              ],
            ),
          ],
        ),
      );
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: color))),
        ]),
      );
}

// ── Open Session Sheet ────────────────────────────────────────────────────────

class _OpenSessionSheet extends StatefulWidget {
  const _OpenSessionSheet({
    required this.svc,
    required this.onOpened,
    required this.onCancelled,
    required this.onNavigateToSession,
  });
  final InventoryService svc;
  final ValueChanged<CountSession> onOpened;
  final VoidCallback onCancelled;
  final ValueChanged<int> onNavigateToSession;

  @override
  State<_OpenSessionSheet> createState() => _OpenSessionSheetState();
}

class _OpenSessionSheetState extends State<_OpenSessionSheet> {
  /// The stock locations (gold safes with a stock_location, ADR-045).
  List<SafeBoxModel> _locations = [];
  /// The location to count: 0 -- every one.
  int _selectedLocation = 0;
  bool _blindCount = true;
  bool _isOpening = false;
  bool _loadingBranches = true;
  bool _submitting = false;
  String? _error;
  int? _existingSessionId; // parsed from "مفتوحة بالفعل (#N)" errors

  static int? _parseExistingSessionId(String message) {
    final m = RegExp(r'#(\d+)').firstMatch(message);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final safes = await ApiService().getSafeBoxes(safeType: 'gold', isActive: true);
      setState(() {
        _locations = safes.where((s) => s.stockLocation != null && s.id != null).toList();
        _loadingBranches = false;
      });
    } catch (_) {
      setState(() {
        _loadingBranches = false;
        _error = 'تعذّر تحميل مواقع المخزون';
      });
    }
  }

  Future<void> _open() async {
    setState(() { _submitting = true; _error = null; });
    try {
      final s = await widget.svc.openSession(
        safeBoxId: _selectedLocation == 0 ? null : _selectedLocation,
        blindCount: _isOpening ? false : _blindCount,
        sessionType: _isOpening ? 'opening' : 'periodic',
      );
      widget.onOpened(s);
    } on InventoryApiException catch (e) {
      final existingId = _parseExistingSessionId(e.message);
      setState(() {
        _error = e.message;
        _existingSessionId = existingId;
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _existingSessionId = null;
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          top: 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _cs(context).outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'فتح جلسة جرد',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            // Branch selector
            if (_loadingBranches)
              Center(
                child: SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _cs(context).primary),
                ),
              )
            else if (_locations.isEmpty)
              _InfoChip(
                icon: Icons.warning_amber_rounded,
                label: 'لا توجد مواقع مخزون — حدّد نوع الموقع للخزائن من إدارة الخزائن',
                color: _tn(context).warning.fg,
              )
            else
              DropdownButtonFormField<int>(
                value: _selectedLocation,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'الموقع',
                  prefixIcon: const Icon(Icons.inventory_2_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('كل المواقع')),
                  ..._locations.map((s) => DropdownMenuItem(
                        value: s.id!,
                        child: Text(s.name),
                      )),
                ],
                onChanged: (v) => setState(() {
                  _selectedLocation = v ?? 0;
                  _error = null;
                  _existingSessionId = null;
                }),
              ),
            const SizedBox(height: 14),
            // Session type
            SwitchListTile(
              value: _isOpening,
              onChanged: (v) => setState(() {
                _isOpening = v;
                if (v) _blindCount = false;
                _error = null;
                _existingSessionId = null;
              }),
              title: const Text('جرد افتتاحي (أول مرة)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'لتسجيل أرصدة البداية — بقيد فروق في الدفاتر',
                style: TextStyle(fontSize: 12),
              ),
              activeColor: _tn(context).sectionTeal.fg,
              contentPadding: EdgeInsets.zero,
            ),
            if (!_isOpening)
              SwitchListTile(
                value: _blindCount,
                onChanged: (v) =>
                    setState(() => _blindCount = v),
                title: const Text('جرد أعمى',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  'الرصيد المتوقع مخفي أثناء العدّ — موصى به',
                  style: TextStyle(fontSize: 12),
                ),
                activeColor: _cs(context).primary,
                contentPadding: EdgeInsets.zero,
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              _InfoChip(
                  icon: Icons.error_outline,
                  label: _error!,
                  color: _cs(context).error),
            ],
            const SizedBox(height: 16),
            if (_existingSessionId != null) ...[
              // Existing session — offer navigation instead of retry
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () =>
                      widget.onNavigateToSession(_existingSessionId!),
                  icon: const Icon(Icons.arrow_forward),
                  label: Text('الانتقال إلى الجلسة #$_existingSessionId'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _cs(context).primary,
                    foregroundColor: _cs(context).onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_submitting ||
                          _loadingBranches ||
                          _locations.isEmpty)
                      ? null
                      : _open,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _cs(context).primary,
                    foregroundColor: _cs(context).onPrimary,
                    disabledBackgroundColor: _cs(context).outlineVariant,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _submitting
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _cs(context).onPrimary),
                        )
                      : const Text('بدء الجرد',
                          style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
            TextButton(
              onPressed: widget.onCancelled,
              child: Text('إلغاء',
                  style: TextStyle(color: _cs(context).onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Add Item Sheet (opening sessions) ────────────────────────────────────────

class _AddItemSheet extends StatefulWidget {
  const _AddItemSheet({required this.onAdd, this.fixedLocationId});
  /// The session's location -- null: it counts every location, and the line's
  /// is chosen here (ADR-045).
  final int? fixedLocationId;
  final void Function(int? safeBoxId, String? safeBoxName, int categoryId,
      String categoryName, double karat, double weight) onAdd;

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  List<SafeBoxModel> _locations = [];
  SafeBoxModel? _location;
  List<Map<String, dynamic>> _allCategories = [];
  List<Map<String, dynamic>> _filtered = [];
  Map<String, dynamic>? _selectedCategory;
  double _selectedKarat = 21.0;

  final _searchCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _weightFocus = FocusNode();

  bool _loadingCats = true;
  bool _creatingCat = false;
  bool _submitting = false;
  String? _error;

  static const _karats = [18.0, 21.0, 22.0, 24.0];

  @override
  void initState() {
    super.initState();
    _loadCategories();
    if (widget.fixedLocationId == null) _loadLocations();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _weightCtrl.dispose();
    _weightFocus.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    try {
      final safes = await ApiService().getSafeBoxes(safeType: 'gold', isActive: true);
      if (!mounted) return;
      setState(() => _locations =
          safes.where((s) => s.stockLocation != null && s.id != null).toList());
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذّر تحميل مواقع المخزون');
    }
  }

  Future<void> _loadCategories() async {
    try {
      final cats = (await ApiService().getCategories())
          .cast<Map<String, dynamic>>();
      setState(() {
        _allCategories = cats;
        _filtered = cats;
        _loadingCats = false;
      });
    } catch (_) {
      setState(() { _loadingCats = false; _error = 'تعذّر تحميل الأصناف'; });
    }
  }

  void _onSearchChanged() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _allCategories
          : _allCategories
              .where((c) =>
                  (c['name'] as String? ?? '').toLowerCase().contains(q))
              .toList();
      // Clear selection if it no longer matches
      if (_selectedCategory != null) {
        final name =
            (_selectedCategory!['name'] as String? ?? '').toLowerCase();
        if (!name.contains(q)) _selectedCategory = null;
      }
    });
  }

  String get _searchQuery => _searchCtrl.text.trim();

  bool get _canCreateNew {
    if (_searchQuery.isEmpty) return false;
    return !_allCategories.any(
        (c) => (c['name'] as String? ?? '').toLowerCase() ==
            _searchQuery.toLowerCase());
  }

  Future<void> _createAndSelect(String name) async {
    setState(() { _creatingCat = true; _error = null; });
    try {
      final created = await ApiService().addCategory({'name': name});
      final cat = created.cast<String, dynamic>();
      setState(() {
        _allCategories.add(cat);
        _filtered = [cat];
        _selectedCategory = cat;
        _searchCtrl.text = name;
        _creatingCat = false;
      });
      _weightFocus.requestFocus();
    } catch (e) {
      setState(() {
        _error = 'تعذّر إنشاء الصنف: $e';
        _creatingCat = false;
      });
    }
  }

  void _select(Map<String, dynamic> cat) {
    setState(() {
      _selectedCategory = cat;
      _searchCtrl.text = cat['name'] as String? ?? '';
      _filtered = [cat];
    });
    _weightFocus.requestFocus();
  }

  Future<void> _submit() async {
    if (_selectedCategory == null) {
      setState(() => _error = 'اختر الصنف أولاً');
      return;
    }
    if (widget.fixedLocationId == null && _location == null) {
      setState(() => _error = 'اختر الموقع أولاً');
      return;
    }
    final weight = double.tryParse(_weightCtrl.text.trim());
    if (weight == null || weight < 0) {
      setState(() => _error = 'أدخل وزناً صحيحاً (يمكن أن يكون صفراً)');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    widget.onAdd(
      widget.fixedLocationId ?? _location?.id,
      _location?.name,
      _selectedCategory!['id'] as int,
      _selectedCategory!['name'] as String? ?? '—',
      _selectedKarat,
      weight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final showList = _selectedCategory == null && !_loadingCats;
    final canAdd =
        _selectedCategory != null && !_submitting && !_creatingCat;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          top: 24,
          left: 24,
          right: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _cs(context).outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('إضافة صنف',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            if (widget.fixedLocationId == null) ...[
              DropdownButtonFormField<SafeBoxModel>(
                value: _location,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'الموقع',
                  prefixIcon: const Icon(Icons.inventory_2_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                items: _locations
                    .map((s) => DropdownMenuItem(value: s, child: Text(s.name)))
                    .toList(),
                onChanged: (v) => setState(() { _location = v; _error = null; }),
              ),
              const SizedBox(height: 12),
            ],

            // ── Category search/select ─────────────────────────────────────
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'الصنف',
                hintText: 'ابحث أو اكتب اسماً جديداً...',
                prefixIcon: _loadingCats
                    ? Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _cs(context).primary),
                        ),
                      )
                    : const Icon(Icons.search),
                suffixIcon: _selectedCategory != null
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _selectedCategory = null;
                          _searchCtrl.clear();
                          _filtered = _allCategories;
                        }),
                      )
                    : null,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                // Green border when selected
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: _selectedCategory != null
                        ? _tn(context).ready.fg
                        : _cs(context).outline,
                    width: _selectedCategory != null ? 1.5 : 1.0,
                  ),
                ),
              ),
              readOnly: _selectedCategory != null,
            ),

            // Dropdown list
            if (showList && (_filtered.isNotEmpty || _canCreateNew)) ...[
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                decoration: BoxDecoration(
                  border: Border.all(color: _cs(context).outlineVariant),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // Existing matches
                    ..._filtered.map((cat) => ListTile(
                          dense: true,
                          title: Text(cat['name'] as String? ?? '—'),
                          leading: const Icon(Icons.label_outline, size: 18),
                          onTap: () => _select(cat),
                        )),
                    // Create new option
                    if (_canCreateNew)
                      ListTile(
                        dense: true,
                        leading: _creatingCat
                            ? SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _cs(context).primary))
                            : Icon(Icons.add_circle_outline,
                                size: 18, color: _cs(context).primary),
                        title: Text.rich(TextSpan(children: [
                          TextSpan(
                              text: 'إنشاء صنف جديد: ',
                              style: TextStyle(color: _cs(context).primary)),
                          TextSpan(
                              text: '"$_searchQuery"',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _cs(context).primary)),
                        ])),
                        onTap: _creatingCat
                            ? null
                            : () => _createAndSelect(_searchQuery),
                      ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),

            // ── Karat chips ───────────────────────────────────────────────
            Text('العيار',
                style: TextStyle(fontSize: 13, color: _cs(context).onSurfaceVariant)),
            const SizedBox(height: 8),
            Row(
              children: _karats.map((k) {
                final selected = _selectedKarat == k;
                final color = _tn(context).karat(((k) as num).round()).fg;
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    label: Text(k.toStringAsFixed(0)),
                    selected: selected,
                    onSelected: (_) =>
                        setState(() => _selectedKarat = k),
                    selectedColor: color.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                        color: selected ? color : null,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 14),

            // ── Weight ────────────────────────────────────────────────────
            TextField(
              controller: _weightCtrl,
              focusNode: _weightFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'الوزن',
                hintText: '0.000',
                suffixText: 'جم',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              onSubmitted: (_) => _submit(),
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              _InfoChip(
                  icon: Icons.error_outline,
                  label: _error!,
                  color: _cs(context).error),
            ],

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canAdd ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cs(context).primary,
                  foregroundColor: _cs(context).onPrimary,
                  disabledBackgroundColor: _cs(context).outlineVariant,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _cs(context).onPrimary))
                    : const Text('إضافة', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _LineState {
  CountLine line;
  CountLineStatus status = CountLineStatus.idle;
  DateTime? savedAt;
  _LineState({required this.line});
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: _cs(context).error),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _cs(context).primary,
                    foregroundColor: _cs(context).onPrimary),
              ),
            ],
          ),
        ),
      );
}
