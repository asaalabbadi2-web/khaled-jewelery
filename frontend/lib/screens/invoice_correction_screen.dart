import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

String _grams(num v) => '${ltrIsolate(formatGrams(v))} جم';

/// «تصحيح فاتورة» (ADR-056): a posted line whose karat, weight or price was
/// entered wrong, put right by one document -- the line corrected in place,
/// its difference one entry the server builds, previews, and posts. The gold
/// is corrected in the safe it is in now (the purchase's is suggested), with
/// a reason. Returns `true` when a correction was posted.
class InvoiceCorrectionScreen extends StatefulWidget {
  const InvoiceCorrectionScreen({
    super.key,
    required this.api,
    required this.invoiceId,
  });

  final ApiService api;
  final int invoiceId;

  @override
  State<InvoiceCorrectionScreen> createState() =>
      _InvoiceCorrectionScreenState();
}

/// A number as it is typed back: no grouping, no trailing zeros.
String _plain(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var text = v.toString();
  while (text.contains('.') && text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

class _RightLine {
  _RightLine({required this.karat, required double weight, required double price})
    : weight = TextEditingController(text: weight > 0 ? _plain(weight) : ''),
      price = TextEditingController(text: price > 0 ? _plain(price) : '');

  int karat;
  int? categoryId;
  final TextEditingController weight;
  final TextEditingController price;

  double get weightValue => double.tryParse(weight.text.trim()) ?? 0.0;
  double get priceValue => double.tryParse(price.text.trim()) ?? 0.0;

  void dispose() {
    weight.dispose();
    price.dispose();
  }
}

class _InvoiceCorrectionScreenState extends State<InvoiceCorrectionScreen> {
  static const _karats = [18, 21, 22, 24];

  Map<String, dynamic>? _invoice;
  List<SafeBoxModel> _safes = const [];
  List<Map<String, dynamic>> _categories = const [];
  List<Map<String, dynamic>> _corrections = const [];
  Object? _error;
  bool _loading = true;
  bool _busy = false;

  Map<String, dynamic>? _line;
  final List<_RightLine> _right = [];
  int? _safeId;
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _right) {
      l.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invoice = await widget.api.getInvoiceById(widget.invoiceId);
      final listed = await widget.api.invoiceCorrections(widget.invoiceId);
      final safes = await widget.api.getSafeBoxBalances(type: 'gold');
      final categories = await widget.api.getCategories();
      if (!mounted) return;
      setState(() {
        _invoice = invoice;
        _categories = [
          for (final c in categories) Map<String, dynamic>.from(c as Map),
        ];
        _corrections = [
          for (final c in (listed['corrections'] as List? ?? const []))
            Map<String, dynamic>.from(c as Map),
        ];
        _safes = safes.where((s) => (s.stockLocation ?? '').isNotEmpty).toList();
        final suggested = listed['suggested_safe_box_id'];
        _safeId = _safes.any((s) => s.id == suggested) ? suggested as int : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _lines => [
    for (final l in (_invoice?['items'] as List? ?? const []))
      Map<String, dynamic>.from(l as Map),
  ];

  // A number from the server: a number, or its text (a category's karat is '21').
  double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

  double _priceOf(Map<String, dynamic> line) =>
      _num(line['net'] ?? line['price']);

  void _choose(Map<String, dynamic> line) {
    setState(() {
      for (final l in _right) {
        l.dispose();
      }
      _right
        ..clear()
        ..add(
          _RightLine(
              karat: _num(line['karat']).round(),
              weight: _num(line['weight']),
              price: _priceOf(line),
            )
            ..categoryId = (line['category_id'] as num?)?.toInt(),
        );
      _line = line;
    });
  }

  double get _cashDelta => _line == null
      ? 0.0
      : _right.fold<double>(0.0, (sum, l) => sum + l.priceValue) - _priceOf(_line!);

  String? get _missing {
    if (_line == null) return 'اختر السطر الذي يُصحَّح';
    if (_right.isEmpty || _right.any((l) => l.weightValue <= 0)) {
      return 'وزن كل سطر صحيح أكبر من صفر';
    }
    if (_right.any((l) => l.priceValue < 0)) return 'السعر صفر أو أكثر';
    if (_safeId == null) return 'اختر خزينة الذهب التي فيها ذهب السطر الآن';
    if (_reason.text.trim().isEmpty) return 'سبب التصحيح مطلوب';
    return null;
  }

  Map<String, dynamic> get _body => {
    'line_id': _line!['id'],
    'safe_box_id': _safeId,
    'reason': _reason.text.trim(),
    'lines': [
      for (final l in _right)
        {
          'karat': l.karat,
          'weight': l.weightValue,
          'price': l.priceValue,
          'category_id': ?l.categoryId,
        },
    ],
  };

  Future<void> _submit() async {
    final missing = _missing;
    if (missing != null) {
      AppFeedback.warning(context, missing);
      return;
    }
    setState(() => _busy = true);
    final Map<String, dynamic> preview;
    try {
      preview = await widget.api.previewInvoiceCorrection(widget.invoiceId, _body);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        AppFeedback.error(context, e, title: 'لم يُعرض قيد التصحيح');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final confirmed = await _confirm(preview);
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final done = await widget.api.correctInvoice(widget.invoiceId, _body);
      if (!mounted) return;
      final number = (done['entry_number'] ?? '').toString();
      AppFeedback.success(
        context,
        number.isEmpty ? 'سُجِّل التصحيح' : 'سُجِّل التصحيح: ${ltrIsolate(number)}',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم يُسجَّل التصحيح');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(Map<String, dynamic> preview) {
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final delta = _num(preview['cash_delta']);
    String amountOf(Map<String, dynamic> l) {
      final amount = _num(l['amount']);
      if (l['amount_type'] == 'gold') {
        final karat = (l['karat'] as num?)?.round();
        return '${_grams(amount)}${karat == null ? '' : ' · ${karat}k'}';
      }
      return '${ltrIsolate(formatAmount(amount))} $currency';
    }

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد التصحيح'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('السبب', _reason.text.trim()),
              _row(
                'فرق المال',
                delta.abs() < 0.005
                    ? 'لا شيء'
                    : '${ltrIsolate(formatAmount(delta))} $currency '
                          '${delta > 0 ? '(يُستحق للعميل)' : '(يُستحق على العميل)'}',
              ),
              const Divider(),
              Text('القيد', style: Theme.of(ctx).textTheme.titleSmall),
              for (final raw in (preview['lines'] as List? ?? const []))
                Builder(
                  builder: (_) {
                    final l = Map<String, dynamic>.from(raw as Map);
                    return _row(
                      '${l['side'] == 'debit' ? 'مدين' : 'دائن'} · '
                      '${ltrIsolate('${l['account_number'] ?? ''}')} ${l['account_name'] ?? ''}',
                      amountOf(l),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد التصحيح'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs / 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: AppSpace.md),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('تصحيح فاتورة #${widget.invoiceId}')),
      body: _loading
          ? const AppLoadingView()
          : _error != null
          ? AppErrorView(title: 'تعذّر فتح الفاتورة', error: _error, onRetry: _load)
          : _form(context),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final currency = context.watch<SettingsProvider>().currencySymbolText;
    final invoice = _invoice!;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text(
          '${invoice['invoice_type'] ?? ''} · '
          '${ltrIsolate(formatAmount(_num(invoice['total'])))} $currency',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          'يُصحَّح السطر في مكانه، ويُرحَّل الفرق قيدًا واحدًا بتاريخ اليوم. '
          'الربح المصروف لا يتغير، وفرقه في نقاط هذه الفترة.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpace.lg),
        Text('السطر الذي يُصحَّح', style: theme.textTheme.titleSmall),
        for (final line in _lines)
          RadioListTile<int>(
            value: (line['id'] as num).toInt(),
            groupValue: (_line?['id'] as num?)?.toInt(),
            onChanged: (_) => _choose(line),
            title: Text('${line['name'] ?? ''}'),
            subtitle: Text(
              '${_num(line['karat']).round()}k · ${_grams(_num(line['weight']))} · '
              '${ltrIsolate(formatAmount(_priceOf(line)))} $currency',
            ),
          ),
        if (_line != null) ...[
          const SizedBox(height: AppSpace.lg),
          Text('الصحيح', style: theme.textTheme.titleSmall),
          for (final (i, l) in _right.indexed) _rightRow(i, l),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(
                () => _right.add(_RightLine(karat: _right.last.karat, weight: 0, price: 0)),
              ),
              icon: const Icon(Icons.call_split),
              label: const Text('إضافة سطر (جزء من السطر بعيار آخر)'),
            ),
          ),
          _row(
            'فرق المال',
            '${ltrIsolate(formatAmount(_cashDelta))} $currency',
          ),
          const SizedBox(height: AppSpace.lg),
          DropdownButtonFormField<int>(
            initialValue: _safeId,
            decoration: const InputDecoration(
              labelText: 'الخزينة التي فيها ذهب السطر الآن',
            ),
            items: [
              for (final s in _safes)
                DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (v) => setState(() => _safeId = v),
          ),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _reason,
            decoration: const InputDecoration(labelText: 'سبب التصحيح'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpace.xl),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('معاينة القيد ثم التصحيح'),
          ),
        ],
        if (_corrections.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xl),
          Text('تصحيحات سابقة', style: theme.textTheme.titleSmall),
          for (final c in _corrections)
            ListTile(
              dense: true,
              title: Text('${c['reason'] ?? ''}'),
              subtitle: Text(
                '${ltrIsolate('${c['entry_number'] ?? ''}')} · ${c['created_by'] ?? ''}',
              ),
            ),
        ],
      ],
    );
  }

  bool get _isSale => (_invoice?['invoice_type'] ?? '').toString() == 'بيع';

  /// The categories a right line of [karat] may take: a sale's pieces, a
  /// purchase's scrap.
  List<Map<String, dynamic>> _categoriesOf(int karat) => [
    for (final c in _categories)
      if (_num(c['karat']).round() == karat && (c['is_scrap'] == true) != _isSale) c,
  ];

  Widget _rightRow(int i, _RightLine l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Row(
      children: [
        SizedBox(
          width: 96,
          child: DropdownButtonFormField<int>(
            initialValue: l.karat,
            decoration: const InputDecoration(labelText: 'العيار'),
            items: [
              for (final k in _karats) DropdownMenuItem(value: k, child: Text('$k')),
            ],
            onChanged: (v) => setState(() {
              l.karat = v ?? l.karat;
              if (!_categoriesOf(l.karat).any((c) => c['id'] == l.categoryId)) {
                l.categoryId = null;
              }
            }),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        SizedBox(
          width: 160,
          child: DropdownButtonFormField<int>(
            key: ValueKey('category-$i-${l.karat}'),
            initialValue: l.categoryId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'التصنيف'),
            items: [
              for (final c in _categoriesOf(l.karat))
                DropdownMenuItem(
                  value: (c['id'] as num).toInt(),
                  child: Text('${c['name'] ?? ''}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => l.categoryId = v),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: TextField(
            controller: l.weight,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'الوزن (جم)'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: TextField(
            controller: l.price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'السعر'),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (_right.length > 1)
          IconButton(
            tooltip: 'حذف السطر',
            onPressed: () => setState(() => _right.removeAt(i).dispose()),
            icon: const Icon(Icons.close),
          ),
      ],
    ),
  );
}
