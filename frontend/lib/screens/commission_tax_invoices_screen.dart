import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../utils/display_date.dart';
import '../utils/month_names.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/app_table.dart';
import '../widgets/date_field.dart';
import '../widgets/inline_number_cell.dart' show readTypedNumber;

/// A commission's VAT waits for its monthly tax invoice (ADR-101, the owner
/// 25 Nov 2026): the months of a method that issues them, each its orders and
/// what they compute to by the server, its invoice entered or that it waits;
/// the invoice entered here is claimed on its date. Every figure is the
/// server's; the screen computes none.
class CommissionTaxInvoicesScreen extends StatefulWidget {
  const CommissionTaxInvoicesScreen({super.key, required this.api, required this.method});

  final ApiService api;
  final Map<String, dynamic> method;

  @override
  State<CommissionTaxInvoicesScreen> createState() => _CommissionTaxInvoicesScreenState();
}

/// '2026-10' said as its month's name and its year: «أكتوبر 2026».
String monthLabel(String month) {
  final parts = month.split('-');
  if (parts.length < 2) return month;
  final m = int.tryParse(parts[1]) ?? 0;
  return '${monthName(m)} ${parts[0]}';
}

String _money(Object? v) => ltrIsolate(formatAmount((v as num?)?.toDouble() ?? 0));

class _CommissionTaxInvoicesScreenState extends State<CommissionTaxInvoicesScreen> {
  Map<String, dynamic>? _data;
  Object? _error;

  int get _methodId => widget.method['id'] as int;

  List<Map<String, dynamic>> get _months =>
      ((_data?['months'] as List?) ?? const []).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.getCommissionTaxInvoices(_methodId);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// The company's VAT number as its last invoice said it, to start from.
  String? get _lastTaxNumber {
    for (final m in _months) {
      final inv = m['invoice'];
      if (inv is Map && '${inv['supplier_tax_number'] ?? ''}'.isNotEmpty) return '${inv['supplier_tax_number']}';
    }
    return null;
  }

  Future<void> _enter(Map<String, dynamic> month) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => CommissionTaxInvoiceDialog(
        api: widget.api,
        method: widget.method,
        month: '${month['month']}',
        taxNumber: _lastTaxNumber,
      ),
    );
    if (done == true) _load();
  }

  Future<void> _cancel(Map<String, dynamic> month) async {
    final inv = (month['invoice'] as Map).cast<String, dynamic>();
    final why = await showDialog<String>(
      context: context,
      builder: (_) => _CancelInvoiceDialog(month: '${month['month']}', vat: inv['vat_amount']),
    );
    if (why == null || !mounted) return;
    try {
      final voucherId = inv['voucher_id'];
      if (voucherId is int) {
        await widget.api.cancelVoucher(voucherId, why.isEmpty ? 'إلغاء فاتورة عمولات ضريبية' : why);
      } else {
        await widget.api.undoCommissionTaxInvoice(inv['id'] as int);
      }
      if (!mounted) return;
      AppFeedback.success(context, 'أُلغيت الفاتورة');
      _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُلغَ الفاتورة');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      appBar: AppBar(title: Text('الفواتير الضريبية — ${widget.method['name'] ?? ''}')),
      body: _data == null && _error != null
          ? AppErrorView(title: 'تعذّر تحميل الفواتير الضريبية', error: _error!, onRetry: _load)
          : _data == null
          ? const AppLoadingView(summaryBlocks: 2, rows: 4)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _summary(wide),
                Expanded(child: _listOrEmpty(wide)),
              ],
            ),
    );
  }

  Widget _summary(bool wide) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final from = '${_data?['tax_invoice_from'] ?? ''}';
    Widget block(String key, String label, Object? value, SemanticTone tone, String hint) => Container(
      key: Key(key),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge?.copyWith(color: tone.onContainer)),
          Text(_money(value),
              style: theme.textTheme.titleLarge?.copyWith(
                  color: tone.onContainer, fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: tone.onContainer)),
        ],
      ),
    );
    final blocks = [
      block('tax-invoices-pending', 'ضريبة تنتظر فاتورتها', _data?['pending_vat'], tones.warning,
          'خارج الإقرار حتى تُدخل فاتورة شهرها'),
      block('tax-invoices-waiting', 'منها لطلبات شهور لم تُفوتر', _data?['still_waiting'], tones.info,
          'والباقي فرق تقريب يذهب إلى العمولة مع الفاتورة التالية'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (from.length >= 7)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'تُصدر الشركة فاتورة ضريبية شهرية بعمولات طلبات الشهر منذ ${monthLabel(from.substring(0, 7))}. '
                'تُدخل كل فاتورة برقمها وتاريخها، فتُطالَب بضريبتها في إقرار يومها.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          wide
              ? Row(children: [
                  for (final b in blocks) ...[Expanded(child: b), if (b != blocks.last) const SizedBox(width: 12)],
                ])
              : Column(children: [
                  for (final b in blocks) ...[b, if (b != blocks.last) const SizedBox(height: 8)],
                ]),
        ],
      ),
    );
  }

  Widget _listOrEmpty(bool wide) {
    if (_months.isEmpty) {
      return const AppEmptyView(
        title: 'لا شهور بعد',
        hint: 'اضبط في إعدادات وسيلة الدفع الشهر الذي تبدأ منه فواتيرها الضريبية.',
        icon: Icons.receipt_long_outlined,
      );
    }
    return wide ? _table() : _cards();
  }

  Widget _state(Map<String, dynamic> m) {
    final tones = AppSemanticColors.of(context);
    final (label, tone) = switch ('${m['state']}') {
      'invoiced' => ('مُدخلة', tones.ready),
      'waiting' => ('تنتظر فاتورتها', tones.warning),
      _ => ('الشهر جارٍ', tones.info),
    };
    return Container(
      key: Key('tax-invoice-state-${m['month']}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text(label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700)),
    );
  }

  Widget _action(Map<String, dynamic> m) {
    if (m['invoice'] is Map) {
      return TextButton(
        key: Key('tax-invoice-cancel-${m['month']}'),
        onPressed: () => _cancel(m),
        child: const Text('إلغاء'),
      );
    }
    return FilledButton.tonal(
      key: Key('tax-invoice-enter-${m['month']}'),
      onPressed: () => _enter(m),
      child: const Text('إدخال الفاتورة'),
    );
  }

  String _difference(Map<String, dynamic> m) {
    final d = (m['vat_difference'] as num?)?.toDouble();
    if (d == null) return '—';
    if (d.abs() < 0.005) return 'مطابقة';
    return d > 0 ? 'أكثر ${_money(d)}' : 'أقل ${_money(d.abs())}';
  }

  static const _columns = {
    'month': AppTableColumn(140, grow: 1),
    'orders': AppTableColumn(80),
    'computed': AppTableColumn(170),
    'invoice': AppTableColumn(190, grow: 1),
    'vat': AppTableColumn(120),
    'difference': AppTableColumn(120),
    'state': AppTableColumn(130),
    'action': AppTableColumn(140),
  };

  Widget _table() {
    return AppTableFrame(
      columns: _columns,
      onRefresh: _load,
      rowCount: _months.length,
      header: (widths) {
        final theme = Theme.of(context);
        final style = theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        );
        Widget cell(String key, String label) => SizedBox(
          width: widths[key],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
        );
        return Container(
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          child: Row(children: [
            cell('month', 'الشهر'),
            cell('orders', 'الطلبات'),
            cell('computed', 'العمولة المحسوبة وضريبتها'),
            cell('invoice', 'الفاتورة'),
            cell('vat', 'ضريبة الفاتورة'),
            cell('difference', 'عن المحسوبة'),
            cell('state', 'الحالة'),
            cell('action', ''),
          ]),
        );
      },
      row: (context, i, widths) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final m = _months[i];
        final inv = m['invoice'] is Map ? (m['invoice'] as Map).cast<String, dynamic>() : null;
        final figures = theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
        Widget pad(String key, Widget child) => SizedBox(
          width: widths[key],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(alignment: AlignmentDirectional.centerStart, child: child),
          ),
        );
        return Container(
          key: Key('tax-invoice-row-${m['month']}'),
          height: 60,
          decoration: BoxDecoration(
            color: i.isOdd ? cs.surfaceContainerLowest : cs.surface,
            border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Row(children: [
            pad('month', Text(monthLabel('${m['month']}'),
                style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700))),
            pad('orders', Text('${m['orders'] ?? 0}', style: figures)),
            pad('computed', Text('${_money(m['computed_fee'])} + ${_money(m['computed_vat'])}', style: figures)),
            pad('invoice', inv == null
                ? Text('—', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ltrIsolate('${inv['invoice_number']}'), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(displayDate(inv['invoice_date']),
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  )),
            pad('vat', Text(inv == null ? '—' : _money(inv['vat_amount']), style: figures)),
            pad('difference', Text(_difference(m), style: theme.textTheme.bodyMedium)),
            pad('state', _state(m)),
            pad('action', _action(m)),
          ]),
        );
      },
    );
  }

  Widget _cards() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _months.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final m = _months[i];
          final inv = m['invoice'] is Map ? (m['invoice'] as Map).cast<String, dynamic>() : null;
          final muted = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
          return Material(
            key: Key('tax-invoice-card-${m['month']}'),
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: cs.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(monthLabel('${m['month']}'),
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                    _state(m),
                  ]),
                  const SizedBox(height: 6),
                  Text('${m['orders'] ?? 0} طلب — المحسوبة ${_money(m['computed_fee'])} وضريبتها ${_money(m['computed_vat'])}',
                      style: muted),
                  if (inv != null) ...[
                    Text('الفاتورة ${ltrIsolate('${inv['invoice_number']}')} بتاريخ ${displayDate(inv['invoice_date'])}',
                        style: theme.textTheme.bodyMedium),
                    Text('ضريبتها ${_money(inv['vat_amount'])} — ${_difference(m)}', style: theme.textTheme.bodyMedium),
                  ],
                  const SizedBox(height: 6),
                  Align(alignment: AlignmentDirectional.centerEnd, child: _action(m)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Why an invoice is cancelled -- its VAT back to wait, the month entered again.
class _CancelInvoiceDialog extends StatefulWidget {
  const _CancelInvoiceDialog({required this.month, required this.vat});

  final String month;
  final Object? vat;

  @override
  State<_CancelInvoiceDialog> createState() => _CancelInvoiceDialogState();
}

class _CancelInvoiceDialogState extends State<_CancelInvoiceDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('إلغاء فاتورة ${monthLabel(widget.month)}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('تعود ضريبتها ${_money(widget.vat)} إلى الانتظار، ويُدخل الشهر من جديد.'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('tax-invoice-cancel-reason'),
            controller: _reason,
            decoration: const InputDecoration(labelText: 'السبب', isDense: true),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('تراجع')),
        FilledButton(
          key: const Key('tax-invoice-cancel-confirm'),
          onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
          child: const Text('إلغاء الفاتورة'),
        ),
      ],
    );
  }
}

/// A month's commission tax invoice entered (ADR-101): its number, date, the
/// company's VAT number, its fee and VAT as printed. The server checks it and
/// says what its month's orders compute to and what it moves; the dialog
/// computes nothing.
class CommissionTaxInvoiceDialog extends StatefulWidget {
  const CommissionTaxInvoiceDialog({
    super.key,
    required this.api,
    required this.method,
    required this.month,
    this.taxNumber,
  });

  final ApiService api;
  final Map<String, dynamic> method;
  final String month;
  final String? taxNumber;

  @override
  State<CommissionTaxInvoiceDialog> createState() => _CommissionTaxInvoiceDialogState();
}

class _CommissionTaxInvoiceDialogState extends State<CommissionTaxInvoiceDialog> {
  final _number = TextEditingController();
  final _date = TextEditingController();
  late final _taxNumber = TextEditingController(text: widget.taxNumber ?? '');
  final _fee = TextEditingController();
  final _vat = TextEditingController();
  final _note = TextEditingController();
  Map<String, dynamic>? _preview;
  Object? _previewError;
  int _seq = 0;
  bool _saving = false;

  String _lastDate = '';

  @override
  void initState() {
    super.initState();
    // The date is typed or picked: either way the preview follows it.
    _date.addListener(() {
      if (_date.text == _lastDate) return;
      _lastDate = _date.text;
      _refresh();
    });
  }

  @override
  void dispose() {
    for (final c in [_number, _date, _taxNumber, _fee, _vat, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? get _body {
    final fee = readTypedNumber(_fee.text.trim());
    final vat = readTypedNumber(_vat.text.trim());
    if (_number.text.trim().isEmpty || _date.text.trim().isEmpty || fee == null || vat == null) return null;
    return {
      'payment_method_id': widget.method['id'],
      'month': widget.month,
      'invoice_number': _number.text.trim(),
      'invoice_date': _date.text.trim(),
      'supplier_tax_number': normalizeNumber(_taxNumber.text).trim(),
      'fee_amount': fee,
      'vat_amount': vat,
      if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
    };
  }

  Future<void> _refresh() async {
    final seq = ++_seq;
    final body = _body;
    if (body == null) {
      setState(() {
        _preview = null;
        _previewError = null;
      });
      return;
    }
    try {
      final p = await widget.api.previewCommissionTaxInvoice(body);
      if (!mounted || seq != _seq) return;
      setState(() {
        _preview = p;
        _previewError = null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _preview = null;
        _previewError = e;
      });
    }
  }

  Future<void> _save() async {
    final body = _body;
    if (body == null) return;
    setState(() => _saving = true);
    try {
      await widget.api.enterCommissionTaxInvoice(body);
      if (!mounted) return;
      AppFeedback.success(context, 'أُدخلت فاتورة ${monthLabel(widget.month)}');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, e, title: 'لم تُدخل الفاتورة');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final p = _preview;
    final digits = [NormalizeNumberFormatter(), FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$'))];
    final rounding = (p?['rounding_moved'] as num?)?.toDouble() ?? 0;
    return AlertDialog(
      title: Text('فاتورة ${widget.method['name'] ?? ''} عن ${monthLabel(widget.month)}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'اكتب ما في الفاتورة كما هو: الرسوم قبل الضريبة، وضريبتها.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('tax-invoice-number'),
                controller: _number,
                decoration: const InputDecoration(labelText: 'رقم الفاتورة', isDense: true),
                onChanged: (_) => _refresh(),
              ),
              const SizedBox(height: 8),
              DateField(controller: _date, label: 'تاريخ الفاتورة', pickerKey: const Key('tax-invoice-date-picker')),
              const SizedBox(height: 8),
              TextField(
                key: const Key('tax-invoice-tax-number'),
                controller: _taxNumber,
                inputFormatters: [NormalizeNumberFormatter(), FilteringTextInputFormatter.digitsOnly],
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'الرقم الضريبي للشركة', isDense: true),
                onChanged: (_) => _refresh(),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    key: const Key('tax-invoice-fee'),
                    controller: _fee,
                    inputFormatters: digits,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'الرسوم قبل الضريبة', isDense: true),
                    onChanged: (_) => _refresh(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('tax-invoice-vat'),
                    controller: _vat,
                    inputFormatters: digits,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'ضريبة القيمة المضافة', isDense: true),
                    onChanged: (_) => _refresh(),
                  ),
                ),
              ]),
              if (p != null) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('tax-invoice-preview'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: tones.info.container, borderRadius: BorderRadius.circular(8)),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: tones.info.onContainer),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('طلبات الشهر ${p['orders'] ?? 0}: عمولتها المحسوبة ${_money(p['computed_fee'])} '
                            'وضريبتها ${_money(p['computed_vat'])}'),
                        Text('الفاتورة عنها: الرسوم ${_signed(p['fee_difference'])}، والضريبة ${_signed(p['vat_difference'])}'),
                        Text('يُطالَب بـ ${_money(p['vat_amount'])} في ضريبة المدخلات بتاريخ ${displayDate(p['invoice_date'])}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (rounding.abs() >= 0.005)
                          Text(rounding > 0
                              ? 'وفرق تقريب ${_money(rounding)} من الانتظار إلى العمولة'
                              : 'وفرق تقريب ${_money(rounding.abs())} من العمولة إلى الضريبة'),
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
                key: const Key('tax-invoice-note'),
                controller: _note,
                decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', isDense: true),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('إلغاء')),
        FilledButton(
          key: const Key('tax-invoice-save'),
          onPressed: !_saving && p != null ? _save : null,
          child: const Text('إدخال الفاتورة'),
        ),
      ],
    );
  }

  String _signed(Object? v) {
    final d = (v as num?)?.toDouble() ?? 0;
    if (d.abs() < 0.005) return 'مطابقة';
    return d > 0 ? 'أكثر ${_money(d)}' : 'أقل ${_money(d.abs())}';
  }
}
