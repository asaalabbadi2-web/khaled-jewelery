import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart' as theme;
import '../utils/bidi.dart';
import 'clearing_settlement_screen.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../utils/currency_utils.dart' as cu;

/// شاشة مراقبة تسوية المقاصة
/// تعرض لكل خزينة clearing: الرصيد المعلّق، دفعات الفواتير غير المُسوّاة،
/// وتتيح تشغيل التسوية يدوياً أو الانتقال لشاشة الإنشاء.
class ClearingMonitorScreen extends StatefulWidget {
  const ClearingMonitorScreen({super.key});

  @override
  State<ClearingMonitorScreen> createState() => _ClearingMonitorScreenState();
}

class _ClearingMonitorScreenState extends State<ClearingMonitorScreen> {
  final ApiService _api = ApiService();

  bool _loading = true;
  bool _runningAutoSettle = false;
  Object? _error;

  /// The boxes whose pending payments did not load: shown as not loaded, never
  /// as «لا شيء معلّق» -- a failed load read as nothing pending, in green.
  final Set<int> _failedBoxes = {};

  /// The payment methods did not load: whether a box settles itself is not
  /// known, and is said so, not shown as «not automatic».
  bool _methodsFailed = false;

  List<SafeBoxModel> _clearingSafes = [];
  // safe_box_id -> pending transactions list
  final Map<int, List<Map<String, dynamic>>> _pendingByBox = {};
  // safe_box_id -> due_amount from API (payments - settled)
  final Map<int, double> _dueAmountByBox = {};
  // safe_box_id -> expanded state
  final Map<int, bool> _expandedBox = {};
  // safe_box_id -> loading more
  final Map<int, bool> _loadingBox = {};
  // safe_box_id -> set of selected invoice_payment_ids
  final Map<int, Set<int>> _selectedByBox = {};

  List<Map<String, dynamic>> _paymentMethods = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final allBoxes = await _api.getPaymentSafeBoxes();
      final clearingBoxes = allBoxes
          .where((sb) => sb.safeType.trim().toLowerCase() == 'clearing')
          .toList();

      var pms = <Map<String, dynamic>>[];
      var methodsFailed = false;
      try {
        final raw = await _api.getActivePaymentMethods();
        pms = raw.whereType<Map<String, dynamic>>().toList();
      } catch (_) {
        methodsFailed = true;
      }

      if (!mounted) return;
      setState(() {
        _clearingSafes = clearingBoxes;
        _paymentMethods = pms;
        _methodsFailed = methodsFailed;
        _pendingByBox.clear();
        _dueAmountByBox.clear();
        _failedBoxes.clear();
      });
      // Each box's pending payments and due amount, in parallel.
      await Future.wait([
        for (final sb in clearingBoxes)
          if (sb.id != null) _loadBox(sb.id!),
      ]);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// One box's pending payments and due amount, from the server; a failure
  /// marks the box as not loaded.
  Future<void> _loadBox(int id) async {
    try {
      final res = await _api.getPendingSettlementTransactions(
        clearingSafeBoxId: id,
      );
      if (!mounted) return;
      setState(() {
        _pendingByBox[id] =
            (res['transactions'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            [];
        final da = (res['due_amount'] as num?)?.toDouble();
        if (da != null) {
          _dueAmountByBox[id] = da;
        } else {
          _dueAmountByBox.remove(id);
        }
        _failedBoxes.remove(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pendingByBox.remove(id);
        _dueAmountByBox.remove(id);
        _failedBoxes.add(id);
      });
    }
  }

  Map<String, dynamic>? _matchedPm(SafeBoxModel sb) {
    if (sb.id == null) return null;
    try {
      return _paymentMethods.firstWhere((pm) {
        final raw = pm['default_safe_box_id'];
        final id = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
        return id != null && id == sb.id;
      });
    } catch (_) {
      return null;
    }
  }

  Future<void> _runAutoSettle() async {
    // It posts a settlement voucher for every box due today: asked first
    // (ADR-050, خ١) -- it was one tap of an icon.
    final go = await confirmFinancialAction(
      context,
      title: 'تشغيل التسوية التلقائية الآن؟',
      effect:
          'تُنشأ الآن سندات تسوية معتمدة ومرحَّلة لوسائل الدفع المفعَّلة للتسوية التلقائية التي حلّ موعد مستحقاتها، كما يفعل الجدول.',
      confirmLabel: 'تشغيل التسوية',
      facts: [
        (
          'وسائل مفعَّلة للتسوية التلقائية',
          _methodsFailed
              ? 'غير معروف'
              : '${_paymentMethods.where((pm) => pm['auto_settlement_enabled'] == true).length}',
        ),
      ],
      destructive: false,
    );
    if (go == null || !mounted) return;
    setState(() => _runningAutoSettle = true);
    try {
      final res = await _api.runAutoClearingSettlementsNow();
      if (!mounted) return;
      final msg = res['message']?.toString() ?? 'تمت التسوية التلقائية';
      final skipped = res['skipped'] as List? ?? [];
      final hasSkipped = skipped.isNotEmpty;
      // Build a short reason summary for skipped items
      String detail = msg;
      if (hasSkipped) {
        final reasons = skipped
            .take(3)
            .map((s) => '${s['name']}: ${s['reason']}')
            .join(' — ');
        detail =
            '$msg\nتجاوز: $reasons${skipped.length > 3 ? ' (و${skipped.length - 3} أخرى)' : ''}';
      }
      // Skipped methods are a thing to heed, not a failure.
      (hasSkipped ? AppFeedback.warning : AppFeedback.success)(context, detail);
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'لم تُشغَّل التسوية التلقائية');
    } finally {
      if (mounted) setState(() => _runningAutoSettle = false);
    }
  }

  // ── Selection helpers ────────────────────────────────────────────────────

  Set<int> _selectionFor(int safeId) =>
      _selectedByBox.putIfAbsent(safeId, () => {});

  void _toggleTx(int safeId, int txId) {
    setState(() {
      final sel = _selectionFor(safeId);
      if (sel.contains(txId)) {
        sel.remove(txId);
      } else {
        sel.add(txId);
      }
    });
  }

  void _toggleSelectAll(int safeId) {
    final txs = _pendingByBox[safeId] ?? [];
    final allIds = txs
        .map((t) => t['invoice_payment_id'] as int?)
        .whereType<int>()
        .toSet();
    setState(() {
      final sel = _selectionFor(safeId);
      if (sel.containsAll(allIds) && allIds.isNotEmpty) {
        sel.clear(); // إلغاء تحديد الكل
      } else {
        sel.addAll(allIds); // تحديد الكل
      }
    });
  }

  double _selectedAmount(int safeId) {
    final sel = _selectionFor(safeId);
    final txs = _pendingByBox[safeId] ?? [];
    return txs
        .where((t) => sel.contains(t['invoice_payment_id'] as int?))
        .fold(0.0, (sum, t) => sum + ((t['amount'] as num?)?.toDouble() ?? 0));
  }

  // ── Open settlement screen with optional selected IDs ────────────────────

  Future<void> _openSettlementScreen(
    SafeBoxModel clearing, {
    List<int>? selectedIds,
  }) async {
    int? bankSafeId;
    final pm = _matchedPm(clearing);
    if (pm != null) {
      final raw = pm['settlement_bank_safe_box_id'];
      bankSafeId = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    }

    // إذا كانت هناك عمليات محددة، استخدم مجموعها — وإلا استخدم المبلغ الكلي
    final dueAmount =
        (selectedIds != null && selectedIds.isNotEmpty && clearing.id != null)
        ? _selectedAmount(clearing.id!)
        : (clearing.id != null ? _dueAmountByBox[clearing.id!] : null);

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ClearingSettlementScreen(
          initialClearingSafeBoxId: clearing.id,
          initialBankSafeBoxId: bankSafeId,
          initialDueAmount: dueAmount,
          initialInvoicePaymentIds: selectedIds,
          // عدد العمليات المحددة لحساب عمولة "رسوم ثابتة × عدد"
          initialTxCount: selectedIds?.length,
        ),
      ),
    );
    if (changed == true) {
      // مسح التحديد بعد نجاح التسوية
      if (clearing.id != null) _selectedByBox.remove(clearing.id);
      await _loadData();
    }
  }

  /// Money as the app writes it: thousands, and a minus Arabic keeps whole.
  String _formatAmount(double v) => cu.formatAmount(v);
  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  // خ٣ (ADR-050): colours and type from the theme, so the screen reads in
  // both modes -- its background, cards and text were written light.
  ColorScheme get _cs => Theme.of(context).colorScheme;
  TextTheme get _text => Theme.of(context).textTheme;
  AppSemanticColors get _tone => AppSemanticColors.of(context);
  String get _currency => context.read<SettingsProvider>().currencySymbolText;
  bool get _newSar => context.read<SettingsProvider>().currencyIsNewSar;

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    // Arabic only, right-to-left in either language of the app.
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تسوية المقاصة'),
          actions: [
            if (_runningAutoSettle)
              const Padding(
                padding: EdgeInsets.all(theme.AppSpace.md),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'تشغيل التسوية التلقائية الآن',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: _clearingSafes.isEmpty ? null : _runAutoSettle,
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _loadData,
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: _loading && _clearingSafes.isEmpty
            ? const AppLoadingView()
            : _error != null
            ? AppErrorView(
                title: 'تعذّر تحميل خزائن المقاصة',
                error: _error,
                onRetry: _loadData,
              )
            : _clearingSafes.isEmpty
            ? const AppEmptyView(
                title: 'لا توجد خزائن مستحقات تحصيل',
                hint: 'أضف خزينة من نوع «مقاصة» في إدارة الخزائن.',
              )
            : RefreshIndicator(
                onRefresh: _loadData,
                child: ListView(
                  padding: const EdgeInsets.all(theme.AppSpace.lg),
                  children: [
                    if (_loading) const LinearProgressIndicator(),
                    if (_failedBoxes.isNotEmpty)
                      _notice(
                        key: const Key('clearing-boxes-failed'),
                        text:
                            'تعذّر تحميل المعلّق في ${_failedBoxes.length} من الخزائن — المجاميع أدناه بدونها.',
                      ),
                    if (_methodsFailed)
                      _notice(
                        key: const Key('clearing-methods-failed'),
                        text:
                            'تعذّر تحميل وسائل الدفع — لا يُعرف أيّ الخزائن تُسوّى تلقائيًا.',
                      ),
                    _buildSummaryRow(),
                    const SizedBox(height: theme.AppSpace.lg),
                    ..._clearingSafes.map(_buildClearingCard),
                  ],
                ),
              ),
      ),
    );
  }

  /// A load that did not complete, said above the totals, with a retry.
  Widget _notice({required Key key, required String text}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: theme.AppSpace.md),
      child: Material(
        color: _cs.errorContainer,
        borderRadius: BorderRadius.circular(theme.AppRadius.control),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: theme.AppSpace.md,
            vertical: theme.AppSpace.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined, color: _cs.onErrorContainer),
              const SizedBox(width: theme.AppSpace.sm),
              Expanded(
                child: Text(
                  text,
                  style: _text.bodyMedium?.copyWith(
                    color: _cs.onErrorContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: _loading ? null : _loadData,
                style: TextButton.styleFrom(
                  foregroundColor: _cs.onErrorContainer,
                ),
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryRow() {
    double totalDue = 0;
    int totalTxCount = 0;
    for (final sb in _clearingSafes) {
      if (sb.id == null) continue;
      // Use the authoritative due_amount from the API
      final due = _dueAmountByBox[sb.id!] ?? 0.0;
      totalDue += due;
      totalTxCount += (_pendingByBox[sb.id!] ?? []).length;
    }

    return Row(
      children: [
        Expanded(
          child: _summaryChip(
            label: 'إجمالي المستحق',
            value: '${_formatAmount(totalDue)} $_currency',
            icon: Icons.pending_actions,
            tone: totalDue > 0 ? _tone.warning : _tone.ready,
          ),
        ),
        const SizedBox(width: theme.AppSpace.md),
        Expanded(
          child: _summaryChip(
            label: 'دفعات غير مُسوّاة',
            value: '$totalTxCount دفعة',
            icon: Icons.receipt_long,
            tone: totalTxCount > 0 ? _tone.info : _tone.ready,
          ),
        ),
        const SizedBox(width: theme.AppSpace.md),
        Expanded(
          child: _summaryChip(
            label: 'خزائن مقاصة',
            value: '${_clearingSafes.length}',
            icon: Icons.account_balance_wallet,
            tone: _tone.gold,
          ),
        ),
      ],
    );
  }

  Widget _summaryChip({
    required String label,
    required String value,
    required IconData icon,
    required SemanticTone tone,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: theme.AppSpace.md,
        vertical: theme.AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(theme.AppRadius.card),
        border: Border.all(color: _cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: tone.fg),
          const SizedBox(height: theme.AppSpace.xs),
          cu.SarAwareText(
            value,
            isNewSar: _newSar,
            style: _text.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: tone.fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            style: _text.labelMedium?.copyWith(color: _cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildClearingCard(SafeBoxModel sb) {
    if (sb.id == null) return const SizedBox.shrink();

    final txs = _pendingByBox[sb.id!] ?? [];
    // Use authoritative due_amount from API
    final dueAmount = _dueAmountByBox[sb.id!] ?? 0.0;
    final isExpanded = _expandedBox[sb.id!] ?? false;
    final pm = _matchedPm(sb);
    final autoEnabled = pm?['auto_settlement_enabled'] == true;
    final liveBalance = sb.cashBalance;

    // The server's due amount, said as it is: owed, over-settled, or nothing.
    // («مبلغ بسيط معلّق» under 100 was a rule of this screen alone; ADR-050.)
    final failed = _failedBoxes.contains(sb.id!);
    final SemanticTone status;
    final String statusLabel;
    if (failed) {
      status = _tone.blocked;
      statusLabel = 'تعذّر تحميل المعلّق';
    } else if (dueAmount > 0) {
      status = _tone.warning;
      statusLabel = 'يحتاج تسوية';
    } else if (dueAmount < 0) {
      status = _tone.blocked;
      statusLabel = 'تسوية زائدة';
    } else {
      status = _tone.ready;
      statusLabel = 'لا شيء معلّق';
    }
    final selection = _selectionFor(sb.id!);

    return Card.outlined(
      margin: const EdgeInsets.only(bottom: theme.AppSpace.md),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ─── Header ──────────────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expandedBox[sb.id!] = !(isExpanded)),
            child: Padding(
              padding: const EdgeInsets.all(theme.AppSpace.lg),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _tone.gold.container,
                      borderRadius: BorderRadius.circular(
                        theme.AppRadius.control,
                      ),
                    ),
                    child: Icon(
                      Icons.account_balance_wallet,
                      color: _tone.gold.onContainer,
                    ),
                  ),
                  const SizedBox(width: theme.AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              sb.name,
                              style: _text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: theme.AppSpace.sm),
                            if (autoEnabled) _infoTag('تلقائي', _tone.ready),
                          ],
                        ),
                        const SizedBox(height: theme.AppSpace.xs),
                        Wrap(
                          spacing: theme.AppSpace.xs,
                          runSpacing: theme.AppSpace.xs,
                          children: [
                            _infoTag(
                              'رصيد الخزينة: ${_formatAmount(liveBalance)} $_currency',
                              _tone.info,
                            ),
                            _infoTag(statusLabel, status),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Due amount badge
                  if (dueAmount != 0)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatAmount(dueAmount.abs()),
                          style: _text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: dueAmount > 0 ? _tone.warning.fg : _cs.error,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        cu.SarAwareText(
                          '$_currency ${dueAmount > 0 ? 'مستحق' : 'تسوية زائدة'}',
                          isNewSar: _newSar,
                          style: _text.labelSmall?.copyWith(
                            color: _cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(width: theme.AppSpace.sm),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: _cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // ─── Expanded Body ────────────────────────────────────────────────
          if (isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(theme.AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // PM info row
                  if (pm != null) _buildPmInfoRow(pm),
                  if (pm != null) const SizedBox(height: theme.AppSpace.md),

                  // Pending transactions list
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // عنوان + زر تحديد الكل
                      Row(
                        children: [
                          if (txs.isNotEmpty) ...[
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value:
                                    selection.length == txs.length &&
                                        txs.isNotEmpty
                                    ? true
                                    : selection.isEmpty
                                    ? false
                                    : null,
                                tristate: true,
                                onChanged: (_) => _toggleSelectAll(sb.id!),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: theme.AppSpace.sm),
                          ],
                          Text(
                            'دفعات غير مُسوّاة (${txs.length})',
                            style: _text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          setState(() => _loadingBox[sb.id!] = true);
                          await _loadBox(sb.id!);
                          if (mounted) {
                            setState(() => _loadingBox[sb.id!] = false);
                          }
                        },
                        icon: (_loadingBox[sb.id!] == true)
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, size: 16),
                        label: const Text('تحديث'),
                      ),
                    ],
                  ),
                  const SizedBox(height: theme.AppSpace.sm),

                  if (failed)
                    Padding(
                      key: Key('clearing-box-failed-${sb.id}'),
                      padding: const EdgeInsets.symmetric(
                        vertical: theme.AppSpace.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            color: _cs.error,
                            size: 18,
                          ),
                          const SizedBox(width: theme.AppSpace.sm),
                          Expanded(
                            child: Text(
                              'تعذّر تحميل الدفعات المعلّقة لهذه الخزينة — اضغط «تحديث»',
                              style: _text.bodyMedium?.copyWith(
                                color: _cs.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (txs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: theme.AppSpace.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: _tone.ready.fg,
                            size: 18,
                          ),
                          const SizedBox(width: theme.AppSpace.sm),
                          Text(
                            'لا توجد دفعات معلّقة',
                            style: _text.bodyMedium?.copyWith(
                              color: _tone.ready.fg,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        border: Border.all(color: _cs.outlineVariant),
                        borderRadius: BorderRadius.circular(
                          theme.AppRadius.control,
                        ),
                      ),
                      child: Column(
                        children: txs.take(20).toList().asMap().entries.map((
                          e,
                        ) {
                          final idx = e.key;
                          final tx = e.value;
                          final amt = (tx['amount'] as num?)?.toDouble() ?? 0.0;
                          final invNum = tx['invoice_number'] ?? '—';
                          final txDate = _formatDate(tx['date']?.toString());
                          final txId = tx['invoice_payment_id'] as int?;
                          final isSelected =
                              txId != null && selection.contains(txId);
                          return Material(
                            color: isSelected
                                ? _tone.gold.container
                                : idx.isEven
                                ? _cs.surfaceContainerLow
                                : _cs.surface,
                            child: InkWell(
                              onTap: txId != null
                                  ? () => _toggleTx(sb.id!, txId)
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: theme.AppSpace.sm,
                                  vertical: theme.AppSpace.sm,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Checkbox(
                                        value: isSelected,
                                        onChanged: txId != null
                                            ? (_) => _toggleTx(sb.id!, txId)
                                            : null,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                    const SizedBox(width: theme.AppSpace.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'فاتورة: $invNum',
                                            style: _text.bodyMedium?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: isSelected
                                                  ? _tone.gold.onContainer
                                                  : null,
                                            ),
                                          ),
                                          Text(
                                            txDate,
                                            style: _text.bodySmall?.copyWith(
                                              color: isSelected
                                                  ? _tone.gold.onContainer
                                                  : _cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    cu.SarAwareText(
                                      '${_formatAmount(amt)} $_currency',
                                      isNewSar: _newSar,
                                      style: _text.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: isSelected
                                            ? _tone.gold.onContainer
                                            : _tone.warning.fg,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                  if (txs.length > 20)
                    Padding(
                      padding: const EdgeInsets.only(top: theme.AppSpace.xs),
                      child: Text(
                        'و${txs.length - 20} دفعة أخرى...',
                        style: _text.bodySmall?.copyWith(
                          color: _cs.onSurfaceVariant,
                        ),
                      ),
                    ),

                  // ── شريط ملخص التحديد ──────────────────────────────
                  if (selection.isNotEmpty) ...[
                    const SizedBox(height: theme.AppSpace.md),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: theme.AppSpace.md,
                        vertical: theme.AppSpace.sm,
                      ),
                      decoration: BoxDecoration(
                        color: _tone.gold.container,
                        borderRadius: BorderRadius.circular(
                          theme.AppRadius.control,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: _tone.gold.onContainer,
                            size: 18,
                          ),
                          const SizedBox(width: theme.AppSpace.sm),
                          Expanded(
                            child: Text(
                              '${selection.length} عملية محددة',
                              style: _text.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: _tone.gold.onContainer,
                              ),
                            ),
                          ),
                          cu.SarAwareText(
                            'الإجمالي: ${_formatAmount(_selectedAmount(sb.id!))} $_currency',
                            isNewSar: _newSar,
                            style: _text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: _tone.gold.onContainer,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: theme.AppSpace.md),

                  // ── أزرار الإجراءات ─────────────────────────────────
                  Row(
                    children: [
                      if (txs.isNotEmpty)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _openSettlementScreen(sb),
                            icon: const Icon(Icons.swap_horiz, size: 18),
                            label: const Text('تسوية الكل'),
                          ),
                        ),
                      if (selection.isNotEmpty) ...[
                        const SizedBox(width: theme.AppSpace.sm),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _openSettlementScreen(
                              sb,
                              selectedIds: selection.toList(),
                            ),
                            icon: const Icon(Icons.done_all, size: 18),
                            label: Text('تسوية ${selection.length} محددة'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPmInfoRow(Map<String, dynamic> pm) {
    final name = pm['name']?.toString() ?? '—';
    final rate = (pm['commission_rate'] as num?)?.toDouble() ?? 0.0;
    final autoEnabled = pm['auto_settlement_enabled'] == true;
    // The schedule as the server reads it (ADR-037) -- not recomputed here.
    final summary = pm['schedule_summary']?.toString() ?? '';
    final scheduleLabel = autoEnabled && summary.isNotEmpty ? summary : '—';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: theme.AppSpace.md,
        vertical: theme.AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: _cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(theme.AppRadius.control),
        border: Border.all(color: _cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.credit_card, size: 16, color: _cs.onSurfaceVariant),
              const SizedBox(width: theme.AppSpace.sm),
              Text(
                'وسيلة الدفع: $name',
                style: _text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: theme.AppSpace.xs),
          Wrap(
            spacing: theme.AppSpace.sm,
            runSpacing: theme.AppSpace.xs,
            children: [
              // The rate kept whole, left-to-right: «0.8%», not «%0.8».
              _infoTag('عمولة: ${ltrIsolate('$rate%')}', _tone.info),
              if (autoEnabled)
                _infoTag('تلقائي: $scheduleLabel', _tone.ready)
              else
                _infoTag(
                  'تسوية يدوية',
                  SemanticTone(
                    _cs.onSurfaceVariant,
                    _cs.surfaceContainerHighest,
                    _cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoTag(String text, SemanticTone tone) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: theme.AppSpace.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(theme.AppRadius.pill),
      ),
      child: cu.SarAwareText(
        text,
        isNewSar: _newSar,
        style: _text.labelMedium?.copyWith(
          color: tone.onContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
