import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../api_service.dart';
import '../../utils.dart' show normalizeNumber;
import '../../utils/arabic_number_formatter.dart';

/// «إقرارات ضريبة القيمة المضافة» (ADR-043 rule 5). A period's preview, then
/// filing it: one entry at its last day closes output VAT against input VAT
/// into 2301 -- owed to the authority, or due back. The figures are the
/// server's; this screen computes none. Paying is a payment voucher on 2301
/// from the bank (a refund, a receipt): no expense.
///
/// As filed (ADR-089): the return's own output and input VAT may be typed --
/// required by the server while sales carry no VAT. What the books lack of
/// them the server books as «ضريبة القيمة المضافة غير القابلة للاسترداد»; the
/// preview shows it beside the books' own figures. What is filed is what was
/// previewed: a change to either figure asks for the preview again.
class VatReturnsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const VatReturnsScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<VatReturnsScreen> createState() => _VatReturnsScreenState();
}

class _VatReturnsScreenState extends State<VatReturnsScreen> {
  static final _money = NumberFormat('#,##0.00');
  static final _day = DateFormat('yyyy-MM-dd');

  late DateTimeRange _period = _lastQuarter(DateTime.now());
  late Future<List<Map<String, dynamic>>> _filed;
  Map<String, dynamic>? _preview;
  (num?, num?) _previewed = (null, null);
  bool _busy = false;
  final _filedOutput = TextEditingController();
  final _filedInput = TextEditingController();

  /// The last whole quarter before [today]: a return is filed for a period that is over.
  static DateTimeRange _lastQuarter(DateTime today) {
    final thisQuarterStart = DateTime(today.year, ((today.month - 1) ~/ 3) * 3 + 1, 1);
    final start = DateTime(thisQuarterStart.year, thisQuarterStart.month - 3, 1);
    return DateTimeRange(start: start, end: thisQuarterStart.subtract(const Duration(days: 1)));
  }

  @override
  void initState() {
    super.initState();
    _filed = widget.api.getVatReturns();
    for (final c in [_filedOutput, _filedInput]) {
      c.addListener(() {
        if (_preview != null) setState(() => _preview = null);   // what is filed is what was previewed
      });
    }
  }

  @override
  void dispose() {
    _filedOutput.dispose();
    _filedInput.dispose();
    super.dispose();
  }

  /// The typed figure, or null when left empty (the books' then).
  static num? _typed(TextEditingController c) {
    final t = normalizeNumber(c.text.trim()).replaceAll(',', '');
    return t.isEmpty ? null : num.tryParse(t);
  }

  String _amount(dynamic v) => _money.format(v is num ? v : 0);

  String _netLabel(num net) {
    if (net > 0.005) return 'مستحقة للهيئة';
    if (net < -0.005) return 'مستحقة لكم';
    return 'لا شيء';
  }

  void _say(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _pickPeriod() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _period,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => (_period = picked, _preview = null));
  }

  Future<void> _runPreview() async {
    setState(() => _busy = true);
    try {
      final figures = (_typed(_filedOutput), _typed(_filedInput));
      final out = await widget.api.previewVatReturn(_day.format(_period.start), _day.format(_period.end),
          filedOutputVat: figures.$1, filedInputVat: figures.$2);
      if (mounted) setState(() => (_preview = out, _previewed = figures));
    } catch (e) {
      if (mounted) _say(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _file() async {
    final preview = _preview;
    if (preview == null) return;
    final net = (preview['net'] as num?) ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تقديم الإقرار'),
        content: Text('يُكتب قيد الإقرار في ${preview['end']}: الصافي ${_amount(net.abs())} '
            '${_netLabel(net)}. لا يُقدَّم إقرار آخر لفترة تتداخل معها.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            key: const Key('vat-return-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تقديم'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final out = await widget.api.fileVatReturn(_day.format(_period.start), _day.format(_period.end),
          filedOutputVat: _previewed.$1, filedInputVat: _previewed.$2);
      if (!mounted) return;
      _say(out['entry_number'] != null ? 'قُدّم الإقرار: ${out['entry_number']}' : 'قُدّم الإقرار (صفري)');
      setState(() {
        _preview = null;
        _filed = widget.api.getVatReturns();
      });
      _filedOutput.clear();
      _filedInput.clear();
    } catch (e) {
      if (mounted) _say(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _figure(String label, String value, {Key? key}) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, key: key, textDirection: TextDirection.ltr,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  static bool _differs(Map<String, dynamic> p) {
    num at(String k) => (p[k] as num?) ?? 0;
    return (at('books_output_vat') - at('output_vat')).abs() > 0.005 ||
        (at('books_input_vat') - at('input_vat')).abs() > 0.005;
  }

  Widget _filedField(TextEditingController c, String label, Key key) => TextField(
        key: key,
        controller: c,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: const [ArabicNumberTextInputFormatter()],
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(labelText: label, hintText: 'اتركه فارغًا لأرقام الدفاتر', isDense: true,
            border: const OutlineInputBorder()),
      );

  Widget _previewCard(Map<String, dynamic> p) {
    final net = (p['net'] as num?) ?? 0;
    final lines = Map<String, dynamic>.from(p['lines'] as Map? ?? const {});
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              _figure('ضريبة المخرجات', _amount(p['output_vat'])),
              _figure('ضريبة المدخلات', _amount(p['input_vat'])),
              _figure('الصافي — ${_netLabel(net)}', _amount(net.abs()), key: const Key('vat-return-net')),
            ]),
            if (_differs(p)) ...[
              const SizedBox(height: 12),
              Text('في الدفاتر: مخرجات ${_amount(p['books_output_vat'])} · مدخلات ${_amount(p['books_input_vat'])}',
                  key: const Key('vat-return-books'), style: Theme.of(context).textTheme.bodySmall),
            ],
            if (((p['non_recoverable'] as num?) ?? 0) > 0.005) ...[
              const SizedBox(height: 4),
              Text('ضريبة غير قابلة للاسترداد (مصروف): ${_amount(p['non_recoverable'])}',
                  key: const Key('vat-return-non-recoverable'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            ],
            if (lines.isNotEmpty) ...[
              const Divider(height: 24),
              for (final e in lines.entries)
                Row(children: [
                  Expanded(child: Text('${(e.value as num) > 0 ? 'مدين' : 'دائن'} ${e.key}')),
                  Text(_amount((e.value as num).abs()), textDirection: TextDirection.ltr),
                ]),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('vat-return-file'),
              onPressed: _busy ? null : _file,
              icon: const Icon(Icons.assignment_turned_in_outlined),
              label: const Text('تقديم الإقرار'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(title: const Text('إقرارات ضريبة القيمة المضافة')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('vat-return-period'),
                  onPressed: _busy ? null : _pickPeriod,
                  icon: const Icon(Icons.date_range),
                  label: Text('${_day.format(_period.start)} — ${_day.format(_period.end)}',
                      textDirection: TextDirection.ltr),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('vat-return-preview'),
                onPressed: _busy ? null : _runPreview,
                child: const Text('عرض'),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: [
              for (final (c, label, key) in [
                (_filedOutput, 'ضريبة المخرجات كما في الإقرار', const Key('vat-return-filed-output')),
                (_filedInput, 'ضريبة المدخلات كما في الإقرار', const Key('vat-return-filed-input')),
              ])
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: _filedField(c, label, key)),
            ]),
            const SizedBox(height: 12),
            if (_preview != null) _previewCard(_preview!),
            const SizedBox(height: 8),
            Text('السداد سند صرف على حساب 2301 من البنك، والاسترداد سند قبض — لا يمرّ بمصروف.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            Text('الإقرارات المقدّمة', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _filed,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Text('تعذّر تحميل الإقرارات: ${snap.error}');
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) return const Text('لم يُقدَّم إقرار بعد.');
                return Column(children: [
                  for (final r in rows.reversed)
                    ListTile(
                      dense: true,
                      title: Text('${r['start']} — ${r['end']}', textDirection: TextDirection.ltr),
                      subtitle: Text('مخرجات ${_amount(r['output_vat'])} · مدخلات ${_amount(r['input_vat'])}'
                          '${r['entry_number'] != null ? ' · ${r['entry_number']}' : ' · صفري'}'),
                      trailing: Text('${_amount(((r['net'] as num?) ?? 0).abs())}\n'
                          '${_netLabel((r['net'] as num?) ?? 0)}', textAlign: TextAlign.end),
                    ),
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }
}
