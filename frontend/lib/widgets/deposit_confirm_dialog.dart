import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils.dart';
import 'inline_number_cell.dart' show readTypedNumber;
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../utils/display_date.dart';
import 'app_feedback.dart';
import 'date_field.dart';

/// A deposit confirmed by what reached the bank (ADR-100, the owner 24 Nov
/// 2026): the accountant chooses the settlements one bank credit carries and
/// types what came; the server says what was expected and posts the
/// difference -- the commission and its VAT -- dated the deposit's day. Every
/// figure is the server's (its preview); the dialog computes none.
Future<bool?> showDepositConfirmDialog(
  BuildContext context, {
  required ApiService api,
  required Map<String, dynamic> method,
}) => showDialog<bool>(
  context: context,
  builder: (_) => DepositConfirmDialog(api: api, method: method),
);

class DepositConfirmDialog extends StatefulWidget {
  const DepositConfirmDialog({super.key, required this.api, required this.method});

  final ApiService api;
  final Map<String, dynamic> method;

  @override
  State<DepositConfirmDialog> createState() => _DepositConfirmDialogState();
}

class _DepositConfirmDialogState extends State<DepositConfirmDialog> {
  List<Map<String, dynamic>>? _settlements;
  Object? _loadError;
  final Set<int> _chosen = {};
  final _amount = TextEditingController();
  final _date = TextEditingController();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  Map<String, dynamic>? _preview;
  Object? _previewError;
  int _previewSeq = 0;
  bool _saving = false;

  int get _methodId => widget.method['id'] as int;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _date.dispose();
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await widget.api.getUnconfirmedSettlements(_methodId);
      if (!mounted) return;
      setState(() => _settlements = ((res['settlements'] as List?) ?? []).cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  double? get _received => readTypedNumber(_amount.text.trim());

  Future<void> _refreshPreview() async {
    final seq = ++_previewSeq;
    final received = _received;
    if (_chosen.isEmpty || received == null || received <= 0) {
      setState(() {
        _preview = null;
        _previewError = null;
      });
      return;
    }
    try {
      final p = await widget.api.previewClearingDeposit(
        paymentMethodId: _methodId,
        voucherIds: _chosen.toList(),
        amountReceived: received,
      );
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = p;
        _previewError = null;
      });
    } catch (e) {
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _preview = null;
        _previewError = e;
      });
    }
  }

  void _toggle(Map<String, dynamic> s, bool on) {
    setState(() {
      on ? _chosen.add(s['voucher_id'] as int) : _chosen.remove(s['voucher_id']);
      // The deposit's day defaults to the latest settlement's.
      final days = _settlements!
          .where((x) => _chosen.contains(x['voucher_id']))
          .map((x) => '${x['date'] ?? ''}')
          .where((d) => d.isNotEmpty)
          .toList()
        ..sort();
      if (days.isNotEmpty && _date.text.trim().isEmpty) _date.text = days.last;
    });
    _refreshPreview();
  }

  Future<void> _confirm() async {
    final received = _received;
    if (_chosen.isEmpty || received == null || received <= 0 || _date.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.api.confirmClearingDeposit(
        paymentMethodId: _methodId,
        voucherIds: _chosen.toList(),
        amountReceived: received,
        depositDate: _date.text.trim(),
        bankReference: _reference.text,
        note: _note.text,
      );
      if (!mounted) return;
      AppFeedback.success(context, 'تم تأكيد الإيداع');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, e, title: 'لم يُؤكَّد الإيداع');
    }
  }

  String _money(Object? v) => ltrIsolate(formatAmount((v as num?)?.toDouble() ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final p = _preview;
    final noteRequired = p?['note_required'] == true;
    final canConfirm = !_saving &&
        p != null &&
        _date.text.trim().isNotEmpty &&
        (!noteRequired || _note.text.trim().isNotEmpty);
    return AlertDialog(
      title: Text('تأكيد إيداع ${widget.method['name'] ?? ''}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'اختر التسويات التي جاءت في حوالة واحدة من كشف البنك، واكتب ما وصل.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              if (_loadError != null)
                Text('تعذّر تحميل التسويات: ${AppFeedback.messageOf(_loadError!)}',
                    style: TextStyle(color: theme.colorScheme.error))
              else if (_settlements == null)
                const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
              else if (_settlements!.isEmpty)
                const Padding(padding: EdgeInsets.all(12), child: Text('لا تسويات تنتظر التأكيد'))
              else
                for (final s in _settlements!)
                  CheckboxListTile(
                    key: Key('deposit-settlement-${s['voucher_id']}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _chosen.contains(s['voucher_id']),
                    onChanged: (v) => _toggle(s, v ?? false),
                    title: Text('${s['voucher_number']} — ${displayDate(s['date'])}'),
                    subtitle: Text('الصافي المتوقع ${_money(s['net'])}'),
                  ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('deposit-amount-received'),
                controller: _amount,
                inputFormatters: [
                  NormalizeNumberFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$')),
                ],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'ما وصل البنك', isDense: true),
                onChanged: (_) => _refreshPreview(),
              ),
              const SizedBox(height: 8),
              DateField(controller: _date, label: 'تاريخ الإيداع في الكشف'),
              const SizedBox(height: 8),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(labelText: 'مرجع الحوالة (اختياري)', isDense: true),
              ),
              if (p != null) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('deposit-preview'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (noteRequired ? tones.warning : tones.info).container,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: (noteRequired ? tones.warning : tones.info).onContainer),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('المتوقع ${_money(p['expected_net'])} — الوارد ${_money(p['amount_received'])}'),
                        Text(
                          ((p['difference'] as num?) ?? 0) == 0
                              ? 'لا فرق: لا يُقيَّد شيء'
                              : ((p['difference'] as num) > 0
                                  ? 'نقص ${_money(p['difference'])}: عمولة ${_money(p['fee_difference'])} وضريبتها ${_money(p['vat_difference'])}'
                                  : 'زيادة ${_money((p['difference'] as num).abs())}: تُنقص العمولة ${_money((p['fee_difference'] as num).abs())} وضريبتها ${_money((p['vat_difference'] as num).abs())}'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (noteRequired)
                          Text('الفرق أكبر من المسموح (${_money(p['allowed_difference'])}): اكتب سببه'),
                      ],
                    ),
                  ),
                ),
              ],
              if (_previewError != null) ...[
                const SizedBox(height: 8),
                Text(AppFeedback.messageOf(_previewError!), style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 8),
              TextField(
                key: const Key('deposit-note'),
                controller: _note,
                decoration: InputDecoration(
                  labelText: noteRequired ? 'سبب الفرق' : 'ملاحظة (اختياري)',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('إلغاء')),
        FilledButton(
          key: const Key('deposit-confirm'),
          onPressed: canConfirm ? _confirm : null,
          child: const Text('تأكيد الإيداع'),
        ),
      ],
    );
  }
}
