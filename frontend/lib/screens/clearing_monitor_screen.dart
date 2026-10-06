import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart' as theme;
import 'clearing_settlement_screen.dart';
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
  String? _error;

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

      List<Map<String, dynamic>> pms = [];
      try {
        final raw = await _api.getActivePaymentMethods();
        pms = raw.whereType<Map<String, dynamic>>().toList();
      } catch (_) {}

      // Load pending tx and due_amount for each clearing safe in parallel
      final Map<int, List<Map<String, dynamic>>> pending = {};
      final Map<int, double> dueAmounts = {};
      await Future.wait(
        clearingBoxes.map((sb) async {
          if (sb.id == null) return;
          try {
            final res = await _api.getPendingSettlementTransactions(
              clearingSafeBoxId: sb.id!,
            );
            pending[sb.id!] =
                (res['transactions'] as List?)
                    ?.whereType<Map<String, dynamic>>()
                    .toList() ??
                [];
            final da = (res['due_amount'] as num?)?.toDouble();
            if (da != null) dueAmounts[sb.id!] = da;
          } catch (_) {
            pending[sb.id!] = [];
          }
        }),
      );

      if (!mounted) return;
      setState(() {
        _clearingSafes = clearingBoxes;
        _paymentMethods = pms;
        _pendingByBox.clear();
        _pendingByBox.addAll(pending);
        _dueAmountByBox.clear();
        _dueAmountByBox.addAll(dueAmounts);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(detail),
          backgroundColor: hasSkipped
              ? theme.AppColors.warning
              : theme.AppColors.success,
          duration: Duration(seconds: hasSkipped ? 6 : 4),
        ),
      );
      await _loadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ: $e'),
          backgroundColor: theme.AppColors.error,
        ),
      );
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

  Future<void> _openSettlementScreen(SafeBoxModel clearing, {List<int>? selectedIds}) async {
    int? bankSafeId;
    final pm = _matchedPm(clearing);
    if (pm != null) {
      final raw = pm['settlement_bank_safe_box_id'];
      bankSafeId = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    }

    // إذا كانت هناك عمليات محددة، استخدم مجموعها — وإلا استخدم المبلغ الكلي
    final dueAmount = (selectedIds != null && selectedIds.isNotEmpty && clearing.id != null)
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

  String _formatAmount(double v) => v.toStringAsFixed(2);
  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        appBar: AppBar(
          title: const Text('مراقبة تسوية المقاصة'),
          backgroundColor: theme.AppColors.primaryGold,
          foregroundColor: Colors.black,
          elevation: 0,
          actions: [
            if (_runningAutoSettle)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                ),
              )
            else
              Tooltip(
                message: 'تشغيل التسوية التلقائية الآن',
                child: IconButton(
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: _clearingSafes.isEmpty ? null : _runAutoSettle,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _loadData,
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _buildError()
            : _clearingSafes.isEmpty
            ? _buildEmpty()
            : RefreshIndicator(
                onRefresh: _loadData,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildSummaryRow(),
                    const SizedBox(height: 16),
                    ..._clearingSafes.map(_buildClearingCard),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildError() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.AppColors.error),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.AppColors.primaryGold,
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildEmpty() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
        const SizedBox(height: 12),
        Text(
          'لا توجد خزائن مستحقات تحصيل (clearing)',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
        ),
      ],
    ),
  );

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
            value:
                '${_formatAmount(totalDue)} ${context.read<SettingsProvider>().currencySymbolText}',
            icon: Icons.pending_actions,
            color: totalDue > 0
                ? theme.AppColors.warning
                : theme.AppColors.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryChip(
            label: 'دفعات غير مُسوّاة',
            value: '$totalTxCount دفعة',
            icon: Icons.receipt_long,
            color: totalTxCount > 0
                ? theme.AppColors.info
                : theme.AppColors.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _summaryChip(
            label: 'خزائن مقاصة',
            value: '${_clearingSafes.length}',
            icon: Icons.account_balance_wallet,
            color: theme.AppColors.primaryGold,
          ),
        ),
      ],
    );
  }

  Widget _summaryChip({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 6),
          cu.SarAwareText(
            value,
            isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
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

    Color statusColor;
    String statusLabel;
    if (dueAmount <= 0) {
      statusColor = theme.AppColors.success;
      statusLabel = dueAmount < 0 ? 'تسوية زائدة' : 'لا شيء معلّق';
    } else if (dueAmount < 100) {
      statusColor = theme.AppColors.info;
      statusLabel = 'مبلغ بسيط معلّق';
    } else {
      statusColor = theme.AppColors.warning;
      statusLabel = 'يحتاج تسوية';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // ─── Header ──────────────────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _expandedBox[sb.id!] = !(isExpanded)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: theme.AppColors.primaryGold.withValues(
                        alpha: 0.15,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.account_balance_wallet,
                      color: theme.AppColors.primaryGold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              sb.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (autoEnabled)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.AppColors.success.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'تلقائي',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.AppColors.success,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            _infoTag(
                              'رصيد الخزينة: ${_formatAmount(liveBalance)} ${context.read<SettingsProvider>().currencySymbolText}',
                              theme.AppColors.info,
                            ),
                            const SizedBox(width: 6),
                            _infoTag(statusLabel, statusColor),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Due amount badge
                  if (dueAmount > 0)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatAmount(dueAmount),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: theme.AppColors.warning,
                          ),
                        ),
                        cu.SarAwareText(
                          '${context.read<SettingsProvider>().currencySymbolText} مستحق',
              isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    )
                  else if (dueAmount < 0)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatAmount(dueAmount.abs()),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: theme.AppColors.error,
                          ),
                        ),
                        cu.SarAwareText(
                          '${context.read<SettingsProvider>().currencySymbolText} تسوية زائدة',
              isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(width: 8),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey.shade500,
                  ),
                ],
              ),
            ),
          ),

          // ─── Expanded Body ────────────────────────────────────────────────
          if (isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // PM info row
                  if (pm != null) _buildPmInfoRow(pm),
                  if (pm != null) const SizedBox(height: 12),

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
                                value: _selectionFor(sb.id!).length == txs.length && txs.isNotEmpty
                                    ? true
                                    : _selectionFor(sb.id!).isEmpty
                                        ? false
                                        : null,
                                tristate: true,
                                activeColor: theme.AppColors.primaryGold,
                                onChanged: (_) => _toggleSelectAll(sb.id!),
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            'دفعات غير مُسوّاة (${txs.length})',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          setState(() => _loadingBox[sb.id!] = true);
                          try {
                            final res = await _api
                                .getPendingSettlementTransactions(
                                  clearingSafeBoxId: sb.id!,
                                );
                            final updated =
                                (res['transactions'] as List?)
                                    ?.whereType<Map<String, dynamic>>()
                                    .toList() ??
                                [];
                            if (mounted) {
                              setState(() {
                                _pendingByBox[sb.id!] = updated;
                                final da = (res['due_amount'] as num?)
                                    ?.toDouble();
                                if (da != null) _dueAmountByBox[sb.id!] = da;
                              });
                            }
                          } catch (_) {
                          } finally {
                            if (mounted) {
                              setState(() => _loadingBox[sb.id!] = false);
                            }
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
                        label: const Text(
                          'تحديث',
                          style: TextStyle(fontSize: 12),
                        ),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (txs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: theme.AppColors.success,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'لا توجد دفعات معلّقة',
                            style: TextStyle(color: theme.AppColors.success),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: txs.take(20).toList().asMap().entries.map((e) {
                          final idx = e.key;
                          final tx = e.value;
                          final amt = (tx['amount'] as num?)?.toDouble() ?? 0.0;
                          final invNum = tx['invoice_number'] ?? '—';
                          final txDate = _formatDate(tx['date']?.toString());
                          final txId = tx['invoice_payment_id'] as int?;
                          final isSelected = txId != null && _selectionFor(sb.id!).contains(txId);
                          return InkWell(
                            onTap: txId != null ? () => _toggleTx(sb.id!, txId) : null,
                            child: Container(
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? theme.AppColors.primaryGold.withValues(alpha: 0.07)
                                    : idx.isEven ? Colors.grey.shade50 : Colors.white,
                                borderRadius: idx == 0
                                    ? const BorderRadius.vertical(top: Radius.circular(9))
                                    : idx == txs.length - 1
                                        ? const BorderRadius.vertical(bottom: Radius.circular(9))
                                        : null,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Checkbox(
                                        value: isSelected,
                                        activeColor: theme.AppColors.primaryGold,
                                        onChanged: txId != null ? (_) => _toggleTx(sb.id!, txId) : null,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'فاتورة: $invNum',
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                          ),
                                          Text(
                                            txDate,
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                                          ),
                                        ],
                                      ),
                                    ),
                                    cu.SarAwareText(
                                      '${_formatAmount(amt)} ${context.read<SettingsProvider>().currencySymbolText}',
                                      isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: isSelected
                                            ? theme.AppColors.primaryGold
                                            : theme.AppColors.warning,
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
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'و${txs.length - 20} دفعة أخرى...',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ),

                  // ── شريط ملخص التحديد ──────────────────────────────
                  if (_selectionFor(sb.id!).isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: theme.AppColors.primaryGold.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: theme.AppColors.primaryGold.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, color: theme.AppColors.primaryGold, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_selectionFor(sb.id!).length} عملية محددة',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: theme.AppColors.darkGold,
                              ),
                            ),
                          ),
                          cu.SarAwareText(
                            'الإجمالي: ${_formatAmount(_selectedAmount(sb.id!))} ${context.read<SettingsProvider>().currencySymbolText}',
                            isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: theme.AppColors.darkGold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // ── أزرار الإجراءات ─────────────────────────────────
                  Row(
                    children: [
                      if (txs.isNotEmpty) Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openSettlementScreen(sb),
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: const Text('تسوية الكل'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.AppColors.primaryGold,
                            side: BorderSide(color: theme.AppColors.primaryGold),
                          ),
                        ),
                      ),
                      if (_selectionFor(sb.id!).isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _openSettlementScreen(
                              sb,
                              selectedIds: _selectionFor(sb.id!).toList(),
                            ),
                            icon: const Icon(Icons.done_all, size: 18),
                            label: Text('تسوية ${_selectionFor(sb.id!).length} محددة'),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.AppColors.primaryGold,
                              foregroundColor: Colors.white,
                            ),
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
    final timing =
        pm['commission_timing']?.toString().trim().toLowerCase() == 'settlement'
        ? 'عند التسوية'
        : 'ضمن الفاتورة';
    final rate = (pm['commission_rate'] as num?)?.toDouble() ?? 0.0;
    final autoEnabled = pm['auto_settlement_enabled'] == true;
    // The schedule as the server reads it (ADR-037) -- not recomputed here.
    final summary = pm['schedule_summary']?.toString() ?? '';
    final scheduleLabel = autoEnabled && summary.isNotEmpty ? summary : '—';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.credit_card, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                'وسيلة الدفع: $name',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _infoTag('عمولة: $rate%', Colors.deepPurple),
              _infoTag('توقيت: $timing', theme.AppColors.info),
              if (autoEnabled)
                _infoTag('تلقائي: $scheduleLabel', theme.AppColors.success)
              else
                _infoTag('تسوية يدوية', Colors.grey),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: cu.SarAwareText(
        text,
        isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
