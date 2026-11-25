import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils.dart';
import '../utils/payment_fee.dart';

/// What a payment method's company takes beyond its rate (ADR-100, the owner
/// 24 Nov 2026: «اجعلها شاملة لمثل هكذا وسائل ويتم ضبطها في الإعدادات») --
/// POLICY, the owner's, for any method of the kind, no company named:
/// - its plans: a number of installments and its rate; a sale by it names one;
/// - its fee a deposit, before VAT (a «payout fee»);
/// - whether it computes each order on its own or one commission on the
///   settlement's total;
/// - its rounding, and the part of its rate refunded on a return, rounded
///   apart with each part's VAT;
/// - whether its deposits are confirmed by what reached the bank, and the
///   difference allowed without a reason.
class PaymentFeeTerms {
  PaymentFeeTerms({
    required this.plans,
    required this.depositFixedFee,
    required this.perOrder,
    this.confirmDeposits = false,
    this.differenceAllowed = 10.0,
    this.halfEven = false,
    this.refundableRate = 0.0,
    this.taxInvoices = false,
    this.taxInvoiceFrom = '',
  });

  factory PaymentFeeTerms.fromMethod(Map<String, dynamic>? method) {
    final plans = <(int, double)>[];
    final raw = method?['plans'];
    if (raw is List) {
      for (final p in raw) {
        if (p is! Map) continue;
        final n = int.tryParse('${p['installments']}');
        final r = double.tryParse('${p['commission_rate']}');
        if (n != null && r != null) plans.add((n, r));
      }
    }
    return PaymentFeeTerms(
      plans: plans,
      depositFixedFee: double.tryParse('${method?['deposit_fixed_fee'] ?? 0}') ?? 0.0,
      perOrder: method?['commission_per_order'] == true,
      confirmDeposits: method?['deposit_confirmation_required'] == true,
      differenceAllowed: double.tryParse('${method?['deposit_difference_allowed'] ?? 10}') ?? 10.0,
      halfEven: method?['commission_rounding'] == 'half_even',
      refundableRate: double.tryParse('${method?['commission_refundable_rate'] ?? 0}') ?? 0.0,
      taxInvoices: method?['tax_invoice_from'] != null,
      taxInvoiceFrom: '${method?['tax_invoice_from'] ?? ''}'.length >= 7
          ? '${method?['tax_invoice_from']}'.substring(0, 7)
          : '',
    );
  }

  final List<(int, double)> plans;
  final double depositFixedFee;
  final bool perOrder;
  final bool confirmDeposits;
  final double differenceAllowed;
  final bool halfEven;
  final double refundableRate;
  // ADR-101: the company issues a monthly tax invoice for its commissions,
  // from a month ('YYYY-MM').
  final bool taxInvoices;
  final String taxInvoiceFrom;

  static final _month = RegExp(r'^(\d{4})-(0[1-9]|1[0-2])$');

  String get rounding => halfEven ? 'half_even' : 'half_up';

  /// What the server is sent: the month's first day, or '' -- none.
  String get taxInvoiceFromJson => taxInvoices ? '$taxInvoiceFrom-01' : '';

  List<Map<String, dynamic>> get plansJson => [
    for (final (n, r) in plans) {'installments': n, 'commission_rate': r},
  ];

  /// Why the plans cannot be saved, or null.
  String? get error {
    final seen = <int>{};
    for (final (n, r) in plans) {
      if (n <= 0) return 'عدد الدفعات أكبر من صفر';
      if (r < 0) return 'النسبة لا تكون سالبة';
      if (!seen.add(n)) return 'خطة ${PaymentFee.installmentsLabel(n)} مكرّرة';
    }
    if (differenceAllowed < 0) return 'الفرق المسموح لا يكون سالبًا';
    if (refundableRate < 0) return 'الجزء المسترد لا يكون سالبًا';
    if (taxInvoices && !_month.hasMatch(taxInvoiceFrom)) {
      return 'شهر أول فاتورة ضريبية: سنة-شهر، مثل 2026-10';
    }
    return null;
  }
}

class PaymentPlansEditor extends StatefulWidget {
  const PaymentPlansEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.fieldFill,
  });

  final PaymentFeeTerms initial;
  final ValueChanged<PaymentFeeTerms> onChanged;
  final Color? fieldFill;

  @override
  State<PaymentPlansEditor> createState() => _PaymentPlansEditorState();
}

class _PlanRow {
  _PlanRow(int? n, double? r)
    : installments = TextEditingController(text: n?.toString() ?? ''),
      rate = TextEditingController(text: r?.toString() ?? '');
  final TextEditingController installments;
  final TextEditingController rate;
}

class _PaymentPlansEditorState extends State<PaymentPlansEditor> {
  late final List<_PlanRow> _rows = [
    for (final (n, r) in widget.initial.plans) _PlanRow(n, r),
  ];
  late final TextEditingController _depositFee = TextEditingController(
    text: widget.initial.depositFixedFee == 0 ? '' : '${widget.initial.depositFixedFee}',
  );
  late bool _perOrder = widget.initial.perOrder;
  late bool _confirmDeposits = widget.initial.confirmDeposits;
  late bool _halfEven = widget.initial.halfEven;
  late final TextEditingController _refundable = TextEditingController(
    text: widget.initial.refundableRate == 0 ? '' : '${widget.initial.refundableRate}',
  );
  late final TextEditingController _allowed = TextEditingController(
    text: '${widget.initial.differenceAllowed}',
  );
  late bool _taxInvoices = widget.initial.taxInvoices;
  late final TextEditingController _taxFrom = TextEditingController(text: widget.initial.taxInvoiceFrom);

  @override
  void dispose() {
    for (final r in _rows) {
      r.installments.dispose();
      r.rate.dispose();
    }
    _depositFee.dispose();
    _allowed.dispose();
    _refundable.dispose();
    _taxFrom.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(PaymentFeeTerms(
      plans: [
        for (final r in _rows)
          if (r.installments.text.trim().isNotEmpty || r.rate.text.trim().isNotEmpty)
            (
              int.tryParse(normalizeNumber(r.installments.text).trim()) ?? 0,
              double.tryParse(normalizeNumber(r.rate.text).trim()) ?? -1,
            ),
      ],
      depositFixedFee: double.tryParse(normalizeNumber(_depositFee.text).trim()) ?? 0.0,
      perOrder: _perOrder,
      confirmDeposits: _confirmDeposits,
      differenceAllowed: double.tryParse(normalizeNumber(_allowed.text).trim()) ?? -1,
      halfEven: _halfEven,
      refundableRate: _refundable.text.trim().isEmpty
          ? 0.0
          : double.tryParse(normalizeNumber(_refundable.text).trim()) ?? -1,
      taxInvoices: _taxInvoices,
      taxInvoiceFrom: normalizeNumber(_taxFrom.text).trim(),
    ));
  }

  InputDecoration _field(String label, {String? hint, String? suffix}) => InputDecoration(
    labelText: label,
    hintText: hint,
    suffixText: suffix,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    filled: widget.fieldFill != null,
    fillColor: widget.fieldFill,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digits = [NormalizeNumberFormatter(), FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$'))];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('payment-method-deposit-fee'),
          controller: _depositFee,
          inputFormatters: digits,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _field('رسم ثابت لكل إيداع (قبل الضريبة)', hint: '0', suffix: 'ريال'),
          onChanged: (_) => _emit(),
        ),
        SwitchListTile(
          key: const Key('payment-method-per-order'),
          contentPadding: EdgeInsets.zero,
          title: const Text('تُحسب العمولة لكل طلب وحده'),
          subtitle: const Text('شركات التقسيط تحسب عمولة كل طلب وضريبتها وحدهما؛ '
              'وشبكات البطاقات عمولة واحدة على مجموع التسوية.'),
          value: _perOrder,
          onChanged: (v) {
            setState(() => _perOrder = v);
            _emit();
          },
        ),
        SwitchListTile(
          key: const Key('payment-method-half-even'),
          contentPadding: EdgeInsets.zero,
          title: const Text('تقريب النصف إلى الزوجي'),
          subtitle: const Text('كما تقرّب الشركة في كشف تسويتها: معطّلًا تصير 150.285 '
              'إلى 150.29، ومفعّلًا إلى 150.28.'),
          value: _halfEven,
          onChanged: (v) {
            setState(() => _halfEven = v);
            _emit();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextFormField(
            key: const Key('payment-method-refundable-rate'),
            controller: _refundable,
            inputFormatters: digits,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _field('جزء النسبة المسترد عند المرتجع (اختياري)', hint: '0', suffix: '%'),
            onChanged: (_) => _emit(),
          ),
        ),
        Text(
          'إن ذكر كشف الشركة جزءًا مستردًا من النسبة (Refundable Commission) يُكتب هنا، فيُقرَّب كل جزء '
          'وضريبته وحده كما تفعل.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        SwitchListTile(
          key: const Key('payment-method-confirm-deposits'),
          contentPadding: EdgeInsets.zero,
          title: const Text('يُؤكَّد الإيداع بما وصل البنك'),
          subtitle: const Text('يُكتب ما وصل من كشف البنك، فيُقيَّد الفرق عمولةً وضريبتها، '
              'ويذكر الفحص الليلي كل تسوية لم تُؤكَّد.'),
          value: _confirmDeposits,
          onChanged: (v) {
            setState(() => _confirmDeposits = v);
            _emit();
          },
        ),
        if (_confirmDeposits)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              key: const Key('payment-method-difference-allowed'),
              controller: _allowed,
              inputFormatters: digits,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _field('الفرق المسموح بلا ذكر سببه', suffix: 'ريال'),
              onChanged: (_) => _emit(),
            ),
          ),
        const SizedBox(height: 4),
        Text('الخطط', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        Text(
          'إن وُجدت خطط اختار البائع خطة العميل في كل بيع، وأُخذت نسبتها بدل النسبة أعلاه. '
          'تغيير نسبة خطة لا يغيّر الدفعات السابقة.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('payment-plan-installments-$i'),
                    controller: _rows[i].installments,
                    inputFormatters: [NormalizeNumberFormatter(), FilteringTextInputFormatter.digitsOnly],
                    keyboardType: TextInputType.number,
                    decoration: _field('عدد الدفعات'),
                    onChanged: (_) => _emit(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: Key('payment-plan-rate-$i'),
                    controller: _rows[i].rate,
                    inputFormatters: digits,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: _field('النسبة', suffix: '%'),
                    onChanged: (_) => _emit(),
                  ),
                ),
                IconButton(
                  tooltip: 'حذف الخطة',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() {
                      final removed = _rows.removeAt(i);
                      removed.installments.dispose();
                      removed.rate.dispose();
                    });
                    _emit();
                  },
                ),
              ],
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('payment-plan-add'),
            onPressed: () => setState(() => _rows.add(_PlanRow(null, null))),
            icon: const Icon(Icons.add),
            label: const Text('إضافة خطة'),
          ),
        ),
        SwitchListTile(
          key: const Key('payment-method-tax-invoices'),
          contentPadding: EdgeInsets.zero,
          title: const Text('تُصدر الشركة فاتورة ضريبية شهرية بعمولاتها'),
          subtitle: const Text('تنتظر ضريبة العمولة فاتورة شهر طلباتها، ولا تدخل الإقرار حتى تُدخل '
              'الفاتورة من «الفواتير الضريبية للعمولات».'),
          value: _taxInvoices,
          onChanged: (v) {
            setState(() => _taxInvoices = v);
            _emit();
          },
        ),
        if (_taxInvoices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextFormField(
              key: const Key('payment-method-tax-invoice-from'),
              controller: _taxFrom,
              inputFormatters: [NormalizeNumberFormatter(), FilteringTextInputFormatter.allow(RegExp(r'^[0-9-]*$'))],
              keyboardType: TextInputType.datetime,
              decoration: _field('من شهر (أول فاتورة تُدخل)', hint: '2026-10'),
              onChanged: (_) => _emit(),
            ),
          ),
      ],
    );
  }
}
