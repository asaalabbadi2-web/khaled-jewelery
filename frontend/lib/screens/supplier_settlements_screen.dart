import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/supplier_settlement_model.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';

/// تسويات فروقات حساب المورد.
///
/// الشاشة **لا تحسب محاسبة**. لا تشتق اتجاه قيد، ولا رصيدًا، ولا تحويلًا
/// للعيار الرئيسي، ولا حدودًا. ترسل السبب والملاحظة، وتعرض ما يقرره الخادم.
class SupplierSettlementsScreen extends StatefulWidget {
  final ApiService api;
  final int supplierId;
  final String supplierName;
  final bool isArabic;

  const SupplierSettlementsScreen({
    super.key,
    required this.api,
    required this.supplierId,
    required this.supplierName,
    this.isArabic = true,
  });

  @override
  State<SupplierSettlementsScreen> createState() =>
      _SupplierSettlementsScreenState();
}

class _SupplierSettlementsScreenState extends State<SupplierSettlementsScreen> {
  bool _isLoading = false;
  bool _isBusy = false;
  String? _errorMessage;
  List<SupplierSettlementAdjustment> _adjustments = const [];

  late final NumberFormat _moneyFmt;
  late final NumberFormat _weightFmt;

  @override
  void initState() {
    super.initState();
    _moneyFmt = NumberFormat('#,##0.00');
    _weightFmt = NumberFormat('#,##0.000');
    _load();
  }

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  bool _can(String action) => context
      .read<AuthProvider>()
      .hasPermission('supplier_settlement_adjustments.$action');

  // ── تحميل ────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final rows = await widget.api
          .getSupplierSettlementAdjustments(widget.supplierId);
      if (!mounted) return;
      setState(() {
        _adjustments = rows
            .whereType<Map<String, dynamic>>()
            .map(SupplierSettlementAdjustment.fromJson)
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _messageOf(e);
        _isLoading = false;
      });
    }
  }

  // ── رسائل ────────────────────────────────────────────────────────────────

  String _messageOf(Object error) {
    if (error is ApiException) return error.message;
    return error.toString();
  }

  /// عنوان عربي مختصر لكل رمز خطأ يرسله الخادم. الرسالة التفصيلية تبقى كما هي.
  String _errorTitle(Object error) {
    final ar = widget.isArabic;
    if (error is! ApiException) return ar ? 'تعذّر إتمام العملية' : 'Failed';
    switch (error.code) {
      case 'not_eligible':
        return ar ? 'المورد غير مؤهل للتسوية' : 'Supplier not eligible';
      case 'supplier_account_review_required':
        return ar ? 'الرصيد يستلزم مراجعة حساب' : 'Account review required';
      case 'snapshot_mismatch':
        return ar ? 'تغيّر الرصيد منذ الإنشاء' : 'Balance changed';
      case 'manager_approval_required':
        return ar ? 'يلزم اعتماد مدير' : 'Manager approval required';
      case 'missing_accounting_mapping':
        return ar ? 'الربط المحاسبي ناقص' : 'Accounting mapping missing';
      case 'settlement_invariant_violation':
        return ar ? 'خرق ضمان التسوية — أُلغيت العملية' : 'Invariant violated';
      case 'client_controlled_field_rejected':
      case 'unsupported_field':
        return ar ? 'حقول غير مسموح بإرسالها' : 'Rejected fields';
      case 'reason_required':
        return ar ? 'السبب إلزامي' : 'Reason required';
      case 'permission_denied':
        return ar ? 'لا تملك الصلاحية' : 'Permission denied';
      case 'authentication_required':
      case 'session_expired':
        return ar ? 'انتهت الجلسة' : 'Session expired';
      case 'not_found':
        return ar ? 'غير موجود' : 'Not found';
      default:
        return ar ? 'تعذّر إتمام العملية' : 'Failed';
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final code = error is ApiException ? error.code : null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 8),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _errorTitle(error),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(_messageOf(error)),
            if (code != null) ...[
              const SizedBox(height: 4),
              Text(
                code,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  // ── إجراءات ──────────────────────────────────────────────────────────────

  Future<void> _run(Future<Map<String, dynamic>> Function() action,
      String successMessage) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final body = await action();
      if (!mounted) return;
      _showSuccess(successMessage);
      final adjustment = body['adjustment'];
      if (adjustment is Map<String, dynamic>) {
        await _showDetails(SupplierSettlementAdjustment.fromJson(adjustment));
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showError(e);
      await _load();
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _createDraft() async {
    final input = await _promptForReason();
    if (input == null) return;
    await _run(
      () => widget.api.createSupplierSettlementAdjustment(
        widget.supplierId,
        reasonCode: input.reasonCode,
        note: input.note,
      ),
      widget.isArabic ? 'تم إنشاء المسودة' : 'Draft created',
    );
  }

  Future<void> _recalculate(SupplierSettlementAdjustment a) => _run(
        () => widget.api.recalculateSupplierSettlementAdjustment(a.id),
        widget.isArabic ? 'تمت إعادة حساب الرصيد' : 'Recalculated',
      );

  Future<void> _approve(SupplierSettlementAdjustment a) => _run(
        () => widget.api.approveSupplierSettlementAdjustment(a.id),
        widget.isArabic ? 'تم الاعتماد' : 'Approved',
      );

  Future<void> _post(SupplierSettlementAdjustment a) async {
    final ok = await _confirm(
      title: widget.isArabic ? 'ترحيل التسوية' : 'Post settlement',
      body: widget.isArabic
          ? 'سيُنشأ سند وقيد محاسبي بالمبالغ التي يحددها النظام من رصيد المورد '
              'الحي. لا يمكن تعديل القيد بعد الترحيل — التصحيح يكون بعكسه.'
          : 'A voucher and journal entry will be created. Posted entries cannot '
              'be edited, only reversed.',
      confirmLabel: widget.isArabic ? 'ترحيل' : 'Post',
    );
    if (ok != true) return;
    await _run(
      () => widget.api.postSupplierSettlementAdjustment(a.id),
      widget.isArabic ? 'تم الترحيل' : 'Posted',
    );
  }

  Future<void> _reverse(SupplierSettlementAdjustment a) async {
    final reason = await _promptForText(
      title: widget.isArabic ? 'عكس التسوية' : 'Reverse settlement',
      hint: widget.isArabic ? 'سبب العكس (إلزامي)' : 'Reason (required)',
      body: widget.isArabic
          ? 'تُنشأ وثيقة عكس جديدة بأثر معاكس، ويُعلَّم الأصل كمعكوس. '
              'القيد الأصلي يبقى كما هو.'
          : 'A new reversing document is created; the original is untouched.',
    );
    if (reason == null) return;
    await _run(
      () => widget.api.reverseSupplierSettlementAdjustment(a.id, reason: reason),
      widget.isArabic ? 'تم عكس التسوية' : 'Reversed',
    );
  }

  Future<void> _cancel(SupplierSettlementAdjustment a) async {
    final reason = await _promptForText(
      title: widget.isArabic ? 'إلغاء المسودة' : 'Cancel draft',
      hint: widget.isArabic ? 'سبب الإلغاء (إلزامي)' : 'Reason (required)',
    );
    if (reason == null) return;
    await _run(
      () => widget.api.cancelSupplierSettlementAdjustment(a.id, reason: reason),
      widget.isArabic ? 'تم إلغاء المسودة' : 'Draft cancelled',
    );
  }

  // ── حوارات ───────────────────────────────────────────────────────────────

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptForText({
    required String title,
    required String hint,
    String? body,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body != null) ...[
              Text(body),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 2,
              decoration: InputDecoration(labelText: hint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.of(context).pop(value);
            },
            child: Text(widget.isArabic ? 'تأكيد' : 'Confirm'),
          ),
        ],
      ),
    );
  }

  Future<_ReasonInput?> _promptForReason() {
    String reason = kSettlementReasonRounding;
    final noteController = TextEditingController();
    return showDialog<_ReasonInput>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final needsNote = reason == kSettlementReasonRequiringNote;
          return AlertDialog(
            title: Text(widget.isArabic ? 'إنشاء تسوية' : 'New settlement'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isArabic
                      ? 'يحدد النظام المبالغ والأوزان والحسابات من رصيد المورد '
                          'الحي. اختر السبب فقط.'
                      : 'Amounts and accounts are derived by the server.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: reason,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'السبب' : 'Reason',
                  ),
                  items: [
                    for (final code in kSettlementReasonCodes)
                      DropdownMenuItem(
                        value: code,
                        child: Text(
                          settlementReasonLabel(code,
                              isArabic: widget.isArabic),
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => reason = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'ملاحظة' : 'Note',
                    helperText: needsNote
                        ? (widget.isArabic
                            ? 'إلزامية لسبب «أخرى»، ويلزم اعتماد مدير'
                            : 'Required for OTHER; needs manager approval')
                        : null,
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
              ),
              FilledButton(
                onPressed:
                    needsNote && noteController.text.trim().isEmpty
                        ? null
                        : () => Navigator.of(context).pop(
                              _ReasonInput(reason, noteController.text.trim()),
                            ),
                child: Text(widget.isArabic ? 'إنشاء' : 'Create'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// يعرض ما أرجعه الخادم للوثيقة. لا يُحتسب هنا شيء.
  Future<void> _showDetails(SupplierSettlementAdjustment a) {
    final ar = widget.isArabic;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(a.adjustmentNumber),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv(ar ? 'الحالة' : 'Status',
                  settlementStatusLabel(a.status, isArabic: ar)),
              _kv(ar ? 'السبب' : 'Reason',
                  settlementReasonLabel(a.reasonCode, isArabic: ar)),
              if (a.note != null && a.note!.isNotEmpty)
                _kv(ar ? 'ملاحظة' : 'Note', a.note!),
              const Divider(),
              Text(
                ar ? 'الرصيد قبل التسوية' : 'Balance before',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              _kv(ar ? 'النقد' : 'Cash',
                  '${_moneyFmt.format(a.balanceBeforeFinancial)} $_currencySymbol'),
              ..._weightRows(a.openBalanceWeights, ar),
              if (a.isPosted || a.isReversed) ...[
                const Divider(),
                Text(
                  ar ? 'ما رُحِّل' : 'Posted',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                _kv(ar ? 'النقد' : 'Cash',
                    '${_moneyFmt.format(a.postedAmountCash ?? 0)} $_currencySymbol'),
                ..._weightRows(a.settledWeights, ar),
                if (a.voucherId != null)
                  _kv(ar ? 'مرجع السند' : 'Voucher ref', '#${a.voucherId}'),
                if (a.journalEntryId != null)
                  _kv(ar ? 'مرجع القيد' : 'Journal ref', '#${a.journalEntryId}'),
              ],
              const Divider(),
              if (a.createdBy != null)
                _kv(ar ? 'أنشأها' : 'Created by', a.createdBy!),
              if (a.approvedBy != null)
                _kv(
                  ar ? 'اعتمدها' : 'Approved by',
                  a.approvedByManager
                      ? '${a.approvedBy} ${ar ? '(مدير)' : '(manager)'}'
                      : a.approvedBy!,
                ),
              if (a.postedBy != null)
                _kv(ar ? 'رحّلها' : 'Posted by', a.postedBy!),
              if (a.reversedBy != null)
                _kv(ar ? 'عكسها' : 'Reversed by', a.reversedBy!),
              if (a.reversalReason != null)
                _kv(ar ? 'سبب العكس' : 'Reversal reason', a.reversalReason!),
              if (a.cancellationReason != null)
                _kv(ar ? 'سبب الإلغاء' : 'Cancellation reason',
                    a.cancellationReason!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ar ? 'إغلاق' : 'Close'),
          ),
        ],
      ),
    );
  }

  /// يعرض ما سيقرره الترحيل الآن. كل رقم هنا وصل من `/preview` جاهزًا —
  /// المكافئ بالعيار الرئيسي والحدود والمستهلك والأهلية — ولا يُحسب هنا شيء.
  Future<void> _showReview(SupplierSettlementAdjustment a) async {
    final ar = widget.isArabic;
    setState(() => _isBusy = true);
    SettlementPreview? preview;
    Object? failure;
    try {
      final body = await widget.api.getSupplierSettlementPreview(a.id);
      preview = SettlementPreview.fromJson(
        (body['preview'] as Map).cast<String, dynamic>(),
      );
    } catch (error) {
      failure = error;
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }

    if (!mounted) return;
    if (failure != null) {
      _showError(failure);
      return;
    }

    final p = preview!;
    final policy = p.policy;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ar ? 'مراجعة ${a.adjustmentNumber}' : 'Review ${a.adjustmentNumber}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _verdictBanner(p, ar),
              const SizedBox(height: 8),
              Text(
                ar ? 'الرصيد الحالي' : 'Current balance',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              _kv(ar ? 'النقد' : 'Cash',
                  '${_moneyFmt.format(p.balanceBeforeFinancial)} $_currencySymbol'),
              // كل عيار على حدة — والمكافئ سطر مستقل يأتي من الخادم.
              ..._weightRows(p.openWeights, ar),
              _kv(
                ar ? 'المكافئ بالعيار الرئيسي' : 'Main-karat equivalent',
                _weightFmt.format(p.mainKaratEquivalent),
              ),
              if (!p.storedSnapshotMatches)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    ar
                        ? 'تغيّر الرصيد منذ إنشاء المسودة — أعد التحقق قبل الترحيل.'
                        : 'Balance moved since the draft was created — recalculate first.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              const Divider(),
              Text(
                ar ? 'حدود السياسة' : 'Policy limits',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (policy == null)
                _kv(ar ? 'السياسة' : 'Policy',
                    ar ? 'لا توجد سياسة نافذة' : 'No policy in effect')
              else ...[
                _kv(ar ? 'حد العملية — نقد' : 'Tolerance — cash',
                    _money(policy.toleranceCash)),
                _kv(ar ? 'حد العملية — وزن' : 'Tolerance — weight',
                    _weight(policy.toleranceWeight)),
                _kv(ar ? 'حد المراجعة' : 'Review threshold',
                    _money(policy.reviewThresholdCash)),
                const SizedBox(height: 6),
                _kv(
                  ar ? 'سقف الفترة — نقد' : 'Period cap — cash',
                  '${_money(policy.periodCapCash)}'
                  '${ar ? ' · المستهلك ' : ' · used '}${_money(policy.cashConsumed)}'
                  '${ar ? ' · المتبقي ' : ' · left '}${_money(policy.remainingCashCap)}',
                ),
                _kv(
                  ar ? 'سقف الفترة — وزن' : 'Period cap — weight',
                  '${_weight(policy.periodCapWeight)}'
                  '${ar ? ' · المستهلك ' : ' · used '}${_weight(policy.weightConsumed)}'
                  '${ar ? ' · المتبقي ' : ' · left '}${_weight(policy.remainingWeightCap)}',
                ),
                if (p.periodKey != null)
                  _kv(ar ? 'الفترة' : 'Period', p.periodKey!),
              ],
              if (p.failedChecks.isNotEmpty) ...[
                const Divider(),
                Text(
                  ar ? 'ما يمنع الترحيل' : 'Blockers',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                for (final c in p.failedChecks)
                  _kv(
                    settlementBlockingLabel(c.name, isArabic: ar),
                    c.detail.isEmpty ? c.name : c.detail,
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(ar ? 'إغلاق' : 'Close'),
          ),
        ],
      ),
    );
  }

  Widget _verdictBanner(SettlementPreview p, bool ar) {
    final scheme = Theme.of(context).colorScheme;
    final ok = p.eligible;
    final title = ok
        ? (ar ? 'مؤهلة للترحيل' : 'Eligible to post')
        : settlementBlockingLabel(p.blockingCode, isArabic: ar);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (ok ? Colors.green : scheme.error).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: ok ? Colors.green.shade800 : scheme.error,
            ),
          ),
          // رسالة الخادم ورمزه يبقيان ظاهرين للتشخيص، بلا إعادة صياغة.
          if (!ok && p.blockingMessage != null && p.blockingMessage!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(p.blockingMessage!, style: const TextStyle(fontSize: 12)),
            ),
          if (!ok && p.blockingCode != null)
            Text(
              p.blockingCode!,
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  String _money(double? value) =>
      value == null ? '—' : '${_moneyFmt.format(value)} $_currencySymbol';

  String _weight(double? value) =>
      value == null ? '—' : _weightFmt.format(value);

  List<Widget> _weightRows(Map<String, double> weights, bool ar) {
    if (weights.isEmpty) {
      return [_kv(ar ? 'الوزن' : 'Weight', ar ? 'لا يوجد' : 'None')];
    }
    // كل عيار مستقل — لا تُجمع الأوزان الخام.
    return [
      for (final entry in weights.entries)
        _kv(entry.key.toUpperCase(), _weightFmt.format(entry.value)),
    ];
  }

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              child: Text(label,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  // ── بناء ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    return Directionality(
      textDirection: ar ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            ar ? 'تسويات: ${widget.supplierName}' : 'Settlements: ${widget.supplierName}',
          ),
          actions: [
            IconButton(
              tooltip: ar ? 'تحديث' : 'Refresh',
              onPressed: _isLoading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        floatingActionButton: _can('create')
            ? FloatingActionButton.extended(
                onPressed: _isBusy ? null : _createDraft,
                icon: const Icon(Icons.add),
                label: Text(ar ? 'إنشاء تسوية' : 'New settlement'),
              )
            : null,
        body: _buildBody(ar),
      ),
    );
  }

  Widget _buildBody(bool ar) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 40, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_adjustments.isEmpty) {
      return Center(
        child: Text(ar ? 'لا توجد تسويات' : 'No settlements'),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _adjustments.length,
        itemBuilder: (context, index) => _buildCard(_adjustments[index], ar),
      ),
    );
  }

  Widget _buildCard(SupplierSettlementAdjustment a, bool ar) {
    final weights = a.isPosted || a.isReversed
        ? a.settledWeights
        : a.openBalanceWeights;
    final cash = a.isPosted || a.isReversed
        ? (a.postedAmountCash ?? 0)
        : a.balanceBeforeFinancial;
    final date = a.postedAt ?? a.createdAt;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _showDetails(a),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      a.adjustmentNumber,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  _statusChip(a.status, ar),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  Text(settlementReasonLabel(a.reasonCode, isArabic: ar)),
                  if (date != null)
                    Text(DateFormat('yyyy-MM-dd').format(date),
                        style: const TextStyle(color: Colors.grey)),
                  if (a.createdBy != null)
                    Text(a.createdBy!,
                        style: const TextStyle(color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 6),
              Text('${_moneyFmt.format(cash)} $_currencySymbol'),
              if (weights.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 12,
                    children: [
                      for (final e in weights.entries)
                        Text(
                          '${e.key.toUpperCase()}  ${_weightFmt.format(e.value)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              if (a.isPosted && a.journalEntryId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${ar ? 'قيد' : 'JE'} #${a.journalEntryId}'
                    '${a.voucherId != null ? '  ·  ${ar ? 'سند' : 'VCH'} #${a.voucherId}' : ''}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              if (a.isReversalDocument)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    ar
                        ? 'وثيقة عكس للتسوية #${a.reversalOfId}'
                        : 'Reversal of #${a.reversalOfId}',
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              _buildActions(a, ar),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(SupplierSettlementAdjustment a, bool ar) {
    final buttons = <Widget>[];

    // المراجعة قبل الاعتماد: ما الذي سيقرره الترحيل الآن، بحسب الخادم.
    if ((a.isDraft || a.isApproved) && _can('view')) {
      buttons.add(TextButton(
        onPressed: _isBusy ? null : () => _showReview(a),
        child: Text(ar ? 'مراجعة' : 'Review'),
      ));
    }
    if (a.isDraft && _can('create')) {
      buttons.add(TextButton(
        onPressed: _isBusy ? null : () => _recalculate(a),
        child: Text(ar ? 'إعادة التحقق' : 'Recalculate'),
      ));
    }
    if (a.isDraft && _can('approve')) {
      buttons.add(TextButton(
        onPressed: _isBusy ? null : () => _approve(a),
        child: Text(ar ? 'اعتماد' : 'Approve'),
      ));
    }
    if (a.isApproved && _can('post')) {
      buttons.add(FilledButton(
        onPressed: _isBusy ? null : () => _post(a),
        child: Text(ar ? 'ترحيل' : 'Post'),
      ));
    }
    if (a.isPosted && _can('reverse')) {
      buttons.add(TextButton(
        onPressed: _isBusy ? null : () => _reverse(a),
        child: Text(ar ? 'عكس التسوية' : 'Reverse'),
      ));
    }
    if ((a.isDraft || a.isApproved) && _can('cancel')) {
      buttons.add(TextButton(
        onPressed: _isBusy ? null : () => _cancel(a),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        child: Text(ar ? 'إلغاء المسودة' : 'Cancel'),
      ));
    }

    if (buttons.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Wrap(spacing: 4, children: buttons),
    );
  }

  Widget _statusChip(String status, bool ar) {
    Color color;
    switch (status) {
      case kSettlementStatusPosted:
        color = Colors.green;
        break;
      case kSettlementStatusApproved:
        color = Colors.blue;
        break;
      case kSettlementStatusReversed:
        color = Colors.orange;
        break;
      case kSettlementStatusCancelled:
        color = Colors.grey;
        break;
      default:
        color = Colors.blueGrey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        settlementStatusLabel(status, isArabic: ar),
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}

class _ReasonInput {
  final String reasonCode;
  final String note;
  const _ReasonInput(this.reasonCode, this.note);
}
