import 'dart:convert';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_semantic_colors.dart';
import 'app_feedback.dart';
import 'payment_plans_editor.dart';
import 'safe_box_picker_dialog.dart';
import 'settlement_schedule_editor.dart';

/// A payment method added or edited (the owner, 24 Nov 2026: «شاشة وسائل
/// الدفع وديالوجاتها تحتاج تطوير من حيث الشكل، الألوان والتباين ودعم الشاشات
/// الصغيرة والكبيرة»). Its sections said apart -- the method, its commission
/// and plans, its settlement, its safe and accounts, its invoices -- on a wide
/// screen beside an index, on a phone a whole page. Every color the theme's.
/// True when saved.
Future<bool?> showPaymentMethodForm(
  BuildContext context, {
  required ApiService api,
  Map<String, dynamic>? editingMethod,
  required List<Map<String, dynamic>> paymentTypes,
  required List<Map<String, dynamic>> invoiceTypeOptions,
  required List<String> invoiceTypeDefaultSelection,
  required List<SafeBoxModel> safeBoxes,
  required List<Map<String, dynamic>> accounts,
}) {
  final compact = MediaQuery.sizeOf(context).width < PaymentMethodForm.compactBelow;
  final form = PaymentMethodForm(
    api: api,
    editingMethod: editingMethod,
    paymentTypes: paymentTypes,
    invoiceTypeOptions: invoiceTypeOptions,
    invoiceTypeDefaultSelection: invoiceTypeDefaultSelection,
    safeBoxes: safeBoxes,
    accounts: accounts,
    compact: compact,
  );
  return showDialog<bool>(
    context: context,
    builder: (_) => compact
        ? Dialog.fullscreen(child: form)
        : Dialog(
            insetPadding: const EdgeInsets.all(24),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 1040,
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: form,
            ),
          ),
  );
}

/// The icon of a payment method by its type.
IconData paymentTypeIcon(String? type) => switch ((type ?? '').toLowerCase()) {
  'cash' => Icons.payments_outlined,
  'bank_transfer' => Icons.account_balance_outlined,
  'check' => Icons.receipt_long_outlined,
  'stc_pay' || 'apple_pay' || 'online' => Icons.smartphone_outlined,
  'receivable' => Icons.request_quote_outlined,
  'tabby' || 'tamara' => Icons.shopping_bag_outlined,
  _ => Icons.credit_card,
};

/// The tone a payment method wears by its type -- the theme's, in both modes.
SemanticTone paymentTypeTone(BuildContext context, String? type) {
  final tones = AppSemanticColors.of(context);
  return switch ((type ?? '').toLowerCase()) {
    'cash' => tones.cash,
    'bank_transfer' => tones.sectionIndigo,
    'check' => tones.sectionAmber,
    'stc_pay' || 'apple_pay' || 'online' => tones.sectionTeal,
    'tabby' => tones.sectionPurple,
    'tamara' => tones.sectionRed,
    'receivable' => tones.sectionSlate,
    _ => tones.sectionBlue,
  };
}

class PaymentMethodForm extends StatefulWidget {
  const PaymentMethodForm({
    super.key,
    required this.api,
    required this.editingMethod,
    required this.paymentTypes,
    required this.invoiceTypeOptions,
    required this.invoiceTypeDefaultSelection,
    required this.safeBoxes,
    required this.accounts,
    required this.compact,
  });

  /// Below this width the form is a whole page.
  static const double compactBelow = 720;

  final ApiService api;
  final Map<String, dynamic>? editingMethod;
  final List<Map<String, dynamic>> paymentTypes;
  final List<Map<String, dynamic>> invoiceTypeOptions;
  final List<String> invoiceTypeDefaultSelection;
  final List<SafeBoxModel> safeBoxes;
  final List<Map<String, dynamic>> accounts;
  final bool compact;

  @override
  State<PaymentMethodForm> createState() => _PaymentMethodFormState();
}

enum _Section { basic, fees, settlement, accounts, invoices }

class _PaymentMethodFormState extends State<PaymentMethodForm> {
  final _formKey = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final Map<_Section, GlobalKey> _sectionKeys = {for (final s in _Section.values) s: GlobalKey()};

  late final TextEditingController _name;
  late final TextEditingController _rate;
  late final TextEditingController _fixed;
  late PaymentFeeTerms _feeTerms;
  late SettlementScheduleValue _schedule;
  late bool _auto;
  late bool _active;
  String? _type;
  String? _typeWarning;
  int? _bankBoxId;
  int? _defaultBoxId;
  int? _feeAccountId;
  late final Set<String> _invoiceTypes;
  String? _invoiceTypesError;
  bool _saving = false;

  Map<String, dynamic>? get _m => widget.editingMethod;
  bool get _editing => _m != null;

  static int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

  List<String> get _allInvoiceTypes => [
    for (final o in widget.invoiceTypeOptions)
      if ('${o['value'] ?? ''}'.isNotEmpty) '${o['value']}',
  ];

  @override
  void initState() {
    super.initState();
    final m = _m;
    _name = TextEditingController(text: '${m?['name'] ?? ''}');
    _rate = TextEditingController(text: '${(m?['commission_rate'] as num?)?.toDouble() ?? 0.0}');
    _fixed = TextEditingController(text: '${(m?['commission_fixed_amount'] as num?)?.toDouble() ?? 0.0}');
    _feeTerms = PaymentFeeTerms.fromMethod(m);
    _schedule = SettlementScheduleValue.fromMethod(m);
    _auto = m?['auto_settlement_enabled'] == true || '${m?['auto_settlement_enabled']}'.toLowerCase() == 'true';
    _active = m?['is_active'] ?? true;
    _bankBoxId = _int(m?['settlement_bank_safe_box_id']);
    _defaultBoxId = _int(m?['default_safe_box_id']);
    _feeAccountId = _int(m?['fee_expense_account_id']);
    _type = m?['payment_type'] as String?;
    final codes = {for (final t in widget.paymentTypes) '${t['code'] ?? ''}'};
    if (_type != null && !codes.contains(_type)) {
      _typeWarning = 'نوع هذه الوسيلة غير موجود في القائمة: اختر نوعًا صحيحًا.';
      _type = null;
    }
    final own = m == null
        ? (widget.invoiceTypeDefaultSelection.isNotEmpty ? widget.invoiceTypeDefaultSelection : _allInvoiceTypes)
        : [
            if (m['applicable_invoice_types'] is List)
              for (final v in m['applicable_invoice_types'] as List)
                if ('${v ?? ''}'.isNotEmpty) '$v',
          ];
    _invoiceTypes = (own.isNotEmpty
            ? own
            : (widget.invoiceTypeDefaultSelection.isNotEmpty ? widget.invoiceTypeDefaultSelection : _allInvoiceTypes))
        .toSet();
  }

  @override
  void dispose() {
    _name.dispose();
    _rate.dispose();
    _fixed.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── what a type takes ─────────────────────────────────────────────────

  static String _suggestedSafeType(String? type) {
    final t = (type ?? '').trim().toLowerCase();
    if (t == 'cash') return 'cash';
    if (t == 'check') return 'check';
    if (t == 'bank_transfer' || t.contains('transfer') || t.contains('bank')) return 'bank';
    return 'clearing'; // card networks, installment companies, wallets settle later
  }

  static String _safeTypeLabel(String safeType) => switch (safeType.trim().toLowerCase()) {
    'cash' => 'نقدي',
    'bank' => 'بنكي',
    'clearing' => 'مستحقات تحصيل',
    'check' => 'شيكات',
    'gold' => 'ذهبي',
    _ => safeType,
  };

  static bool _safeFits(String? type, String safeType) {
    final t = (type ?? '').trim().toLowerCase();
    final s = safeType.trim().toLowerCase();
    if (s == 'gold') return false;
    if (t == 'cash') return s == 'cash';
    if (t == 'check') return s == 'check' || s == 'bank';
    if (t == 'bank_transfer' || t.contains('transfer') || t.contains('bank')) return s == 'bank';
    return s == 'clearing' || s == 'bank';
  }

  SafeBoxModel? _box(int? id) {
    if (id == null) return null;
    for (final b in widget.safeBoxes) {
      if (b.id == id) return b;
    }
    return null;
  }

  Map<String, dynamic>? _account(int? id) {
    if (id == null) return null;
    for (final a in widget.accounts) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  static String _backendError(Object error) {
    final message = error.toString();
    final start = message.indexOf('{');
    final end = message.lastIndexOf('}');
    if (start != -1 && end > start) {
      try {
        final parsed = json.decode(message.substring(start, end + 1));
        if (parsed is Map && parsed['error'] is String) return parsed['error'] as String;
      } catch (_) {}
    }
    return message;
  }

  // ── saving ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      _goTo(_Section.basic);
      return;
    }
    if (_feeTerms.error != null) {
      _goTo(_Section.fees);
      AppFeedback.warning(context, _feeTerms.error!);
      return;
    }
    if (_auto && _bankBoxId == null) {
      _goTo(_Section.settlement);
      AppFeedback.warning(context, 'اختر الخزينة البنكية التي تُودَع فيها التسوية');
      return;
    }
    if (_invoiceTypes.isEmpty) {
      _goTo(_Section.invoices);
      setState(() => _invoiceTypesError = 'اختر نوع فاتورة واحدًا على الأقل');
      return;
    }
    setState(() => _saving = true);
    final s = _schedule;
    final t = _feeTerms;
    try {
      if (!_editing) {
        await widget.api.createPaymentMethod(
          paymentType: _type!,
          name: _name.text.trim(),
          defaultSafeBoxId: _defaultBoxId,
          commissionRate: _hasPlans ? 0.0 : double.tryParse(_rate.text) ?? 0.0,
          commissionFixedAmount: double.tryParse(_fixed.text) ?? 0.0,
          autoSettlementEnabled: _auto,
          settlementScheduleType: s.batchPeriod,
          settlementWeekday: s.batchPeriod == 'weekday' ? s.closeWeekday : null,
          settlementBankSafeBoxId: _bankBoxId,
          feeExpenseAccountId: _feeAccountId,
          minSettlementAmount: s.minSettlementAmount,
          depositDelayDays: s.depositRule == 'days' ? s.depositDays : 0,
          depositScheduleType: s.depositRule,
          depositWeekday: s.depositRule == 'weekday' ? s.depositWeekday : null,
          bankWeekendDays: s.bankWeekend.toList()..sort(),
          skipPublicHolidays: s.skipPublicHolidays,
          isActive: _active,
          applicableInvoiceTypes: _invoiceTypes.toList(),
          depositFixedFee: t.depositFixedFee,
          commissionPerOrder: t.perOrder,
          plans: t.plansJson,
          depositConfirmationRequired: t.confirmDeposits,
          depositDifferenceAllowed: t.differenceAllowed,
          commissionRounding: t.rounding,
          commissionRefundableRate: t.refundableRate,
          taxInvoiceFrom: t.taxInvoiceFromJson,
        );
      } else {
        await widget.api.updatePaymentMethod(
          _m!['id'] as int,
          paymentType: _type!,
          name: _name.text.trim(),
          commissionRate: _hasPlans ? 0.0 : double.tryParse(_rate.text) ?? 0.0,
          commissionFixedAmount: double.tryParse(_fixed.text) ?? 0.0,
          settlementDays: _int(_m!['settlement_days']) ?? 0,
          autoSettlementEnabled: _auto,
          settlementScheduleType: s.batchPeriod,
          settlementWeekday: s.batchPeriod == 'weekday' ? s.closeWeekday : null,
          settlementBankSafeBoxId: _bankBoxId,
          feeExpenseAccountId: _feeAccountId,
          minSettlementAmount: s.minSettlementAmount,
          depositDelayDays: s.depositRule == 'days' ? s.depositDays : 0,
          depositScheduleType: s.depositRule,
          depositWeekday: s.depositRule == 'weekday' ? s.depositWeekday : null,
          bankWeekendDays: s.bankWeekend.toList()..sort(),
          skipPublicHolidays: s.skipPublicHolidays,
          isActive: _active,
          defaultSafeBoxId: _defaultBoxId,
          applicableInvoiceTypes: _invoiceTypes.toList(),
          depositFixedFee: t.depositFixedFee,
          commissionPerOrder: t.perOrder,
          plans: t.plansJson,
          depositConfirmationRequired: t.confirmDeposits,
          depositDifferenceAllowed: t.differenceAllowed,
          commissionRounding: t.rounding,
          commissionRefundableRate: t.refundableRate,
          taxInvoiceFrom: t.taxInvoiceFromJson,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      final said = _backendError(error);
      setState(() {
        _saving = false;
        if (said.contains('نوع فاتورة')) _invoiceTypesError = said;
      });
      AppFeedback.error(context, said, title: 'لم تُحفظ وسيلة الدفع');
    }
  }

  void _goTo(_Section s) {
    final c = _sectionKeys[s]!.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250), alignment: 0.02);
    }
  }

  // ── the look ──────────────────────────────────────────────────────────

  static const _titles = {
    _Section.basic: ('الوسيلة', Icons.badge_outlined),
    _Section.fees: ('العمولة والخطط', Icons.percent),
    _Section.settlement: ('التسوية والإيداع', Icons.event_repeat_outlined),
    _Section.accounts: ('الخزينة والحساب', Icons.account_balance_wallet_outlined),
    _Section.invoices: ('الفواتير', Icons.receipt_long_outlined),
  };

  Color get _fill => Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55);

  InputDecoration _field(String label, {IconData? icon, String? hint, String? suffix, Widget? suffixIcon}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
        prefixIcon: icon == null ? null : Icon(icon),
        suffixIcon: suffixIcon,
        isDense: true,
        filled: true,
        fillColor: _fill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  /// Two fields side by side on a wide screen, one above the other on a phone.
  Widget _pair(Widget a, Widget b) => widget.compact
      ? Column(children: [a, const SizedBox(height: 12), b])
      : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)],
        );

  Widget _section(_Section s, List<Widget> children, {String? hint}) {
    final theme = Theme.of(context);
    final (title, icon) = _titles[s]!;
    return Container(
      key: _sectionKeys[s],
      margin: const EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(widget.compact ? 14 : 18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  /// A field whose value is picked from a list (a safe, an account).
  Widget _picker({
    required Key key,
    required String label,
    required IconData icon,
    required String? value,
    required String placeholder,
    required VoidCallback? onTap,
    required VoidCallback? onClear,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: _field(
          label,
          icon: icon,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value != null && onClear != null)
                IconButton(tooltip: 'مسح الربط', onPressed: onClear, icon: const Icon(Icons.close)),
              Icon(Icons.arrow_drop_down, color: onTap == null ? cs.outline : cs.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
          ),
        ),
        child: Text(
          value ?? placeholder,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: value == null ? cs.onSurfaceVariant : cs.onSurface),
        ),
      ),
    );
  }

  List<Widget> _basic() => [
    _pair(
      DropdownButtonFormField<String>(
        key: const Key('pm-form-type'),
        initialValue: _type,
        isExpanded: true,
        decoration: _field('نوع وسيلة الدفع *', icon: Icons.category_outlined),
        items: [
          for (final t in widget.paymentTypes)
            DropdownMenuItem(
              value: '${t['code']}',
              child: Row(
                children: [
                  Icon(paymentTypeIcon('${t['code']}'), size: 20, color: paymentTypeTone(context, '${t['code']}').fg),
                  const SizedBox(width: 8),
                  Flexible(child: Text('${t['name_ar'] ?? t['code']}', overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
        onChanged: (v) => setState(() {
          _type = v;
          _typeWarning = null;
          final b = _box(_defaultBoxId);
          if (b != null && !_safeFits(_type, b.safeType)) _defaultBoxId = null;
        }),
        validator: (v) => v == null ? 'مطلوب' : null,
      ),
      TextFormField(
        key: const Key('pm-form-name'),
        controller: _name,
        decoration: _field('اسم وسيلة الدفع *', icon: Icons.text_fields, hint: 'مثال: مدى - بنك الراجحي'),
        validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null,
      ),
    ),
    if (_typeWarning != null) _note(_typeWarning!),
    const SizedBox(height: 4),
    SwitchListTile(
      key: const Key('pm-form-active'),
      contentPadding: EdgeInsets.zero,
      title: Text(_active ? 'نشطة' : 'معطّلة'),
      subtitle: Text(_active ? 'تظهر في الفواتير وتُقبل بها الدفعات' : 'لا تظهر في الفواتير'),
      value: _active,
      onChanged: (v) => setState(() => _active = v),
    ),
  ];

  /// With plans every sale takes its plan's rate: the single rate is no
  /// payment's, so it is not shown, and is saved as nothing (the owner, 25
  /// Nov 2026: «يُخفى ويُحفظ صفرًا»; the server refuses it beside plans).
  bool get _hasPlans => _feeTerms.plans.isNotEmpty;

  List<Widget> _fees() {
    final fixed = TextFormField(
      key: const Key('pm-form-fixed'),
      controller: _fixed,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _field(_hasPlans ? 'عمولة ثابتة لكل طلب' : 'عمولة ثابتة لكل عملية',
          icon: Icons.payments_outlined, hint: '0', suffix: 'ريال'),
    );
    return [
      if (_hasPlans) ...[
        fixed,
        const SizedBox(height: 6),
        Text(
          'لهذه الوسيلة خطط: كل بيع بنسبة خطته، ويُضاف المبلغ الثابت لكل طلب. لا نسبة ثابتة معها.',
          key: const Key('pm-form-rate-by-plans'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ] else
        _pair(
          TextFormField(
            key: const Key('pm-form-rate'),
            controller: _rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _field('نسبة العمولة', icon: Icons.percent, hint: '2.5', suffix: '%'),
          ),
          fixed,
        ),
      const SizedBox(height: 14),
      PaymentPlansEditor(
        initial: _feeTerms,
        fieldFill: _fill,
        onChanged: (t) {
          final had = _hasPlans;
          _feeTerms = t;
          if (had != _hasPlans) setState(() {});
        },
      ),
    ];
  }

  List<Widget> _settlement() {
    final bankBoxes = [for (final b in widget.safeBoxes) if (b.safeType.trim().toLowerCase() == 'bank') b];
    final bank = _box(_bankBoxId);
    return [
      SwitchListTile(
        key: const Key('pm-form-auto'),
        contentPadding: EdgeInsets.zero,
        title: const Text('تسوية تلقائية: من المستحقات إلى البنك'),
        subtitle: const Text('يُنشئ النظام سند التسوية بنفسه في يوم الإيداع حسب الجدول.'),
        value: _auto,
        onChanged: (v) => setState(() => _auto = v),
      ),
      if (_auto) ...[
        const SizedBox(height: 8),
        SettlementScheduleEditor(
          initial: _schedule,
          api: widget.api,
          fieldFill: _fill,
          onChanged: (v) => _schedule = v,
        ),
        const SizedBox(height: 14),
        _picker(
          key: const Key('pm-form-bank'),
          label: 'الخزينة البنكية التي تُودَع فيها *',
          icon: Icons.account_balance_outlined,
          value: bank == null ? null : '${bank.name} (${bank.typeNameAr})',
          placeholder: bankBoxes.isEmpty ? 'لا توجد خزائن بنكية' : 'اختر خزينة بنكية',
          onTap: bankBoxes.isEmpty
              ? null
              : () async {
                  final picked = await showDialog<SafeBoxModel>(
                    context: context,
                    builder: (_) => SafeBoxPickerDialog(
                      safeBoxes: bankBoxes,
                      selectedSafeBoxId: _bankBoxId,
                      filterSafeType: 'bank',
                      excludeGold: true,
                    ),
                  );
                  if (picked != null) setState(() => _bankBoxId = picked.id);
                },
          onClear: () => setState(() => _bankBoxId = null),
        ),
      ],
    ];
  }

  List<Widget> _accounts() {
    final suggested = _suggestedSafeType(_type);
    final box = _box(_defaultBoxId);
    final account = _account(_feeAccountId);
    return [
      _pair(
        _picker(
          key: const Key('pm-form-safe'),
          label: 'الخزينة التي تستلم الدفعة',
          icon: Icons.account_balance_wallet_outlined,
          value: box == null ? null : '${box.name} (${box.typeNameAr})',
          placeholder: widget.safeBoxes.isEmpty
              ? 'لا توجد خزائن'
              : 'اختر خزينة (المقترح: ${_safeTypeLabel(suggested)})',
          onTap: widget.safeBoxes.isEmpty
              ? null
              : () async {
                  final picked = await showDialog<SafeBoxModel>(
                    context: context,
                    builder: (_) => SafeBoxPickerDialog(
                      safeBoxes: widget.safeBoxes,
                      selectedSafeBoxId: _defaultBoxId,
                      filterSafeType: suggested,
                      excludeGold: true,
                    ),
                  );
                  if (picked == null || !mounted) return;
                  if (!_safeFits(_type, picked.safeType)) {
                    AppFeedback.warning(context, 'نوع هذه الخزينة لا يناسب نوع وسيلة الدفع');
                    return;
                  }
                  setState(() => _defaultBoxId = picked.id);
                },
          onClear: () => setState(() => _defaultBoxId = null),
        ),
        _picker(
          key: const Key('pm-form-fee-account'),
          label: 'حساب مصروف العمولة',
          icon: Icons.account_tree_outlined,
          value: account == null ? null : '${account['name']} (${account['account_number'] ?? ''})',
          placeholder: widget.accounts.isEmpty ? 'لا توجد حسابات' : 'اختر حسابًا (اختياري)',
          onTap: widget.accounts.isEmpty
              ? null
              : () async {
                  final picked = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => _AccountPickerDialog(accounts: widget.accounts, selectedId: _feeAccountId),
                  );
                  if (picked != null) setState(() => _feeAccountId = picked['id'] as int?);
                },
          onClear: () => setState(() => _feeAccountId = null),
        ),
      ),
      _note('بلا خزينة يختار النظام الخزينة عند تسجيل الدفعة حسب الفاتورة والإعدادات. '
          'وحساب المصروف تُقيَّد عليه عمولة التسوية.'),
    ];
  }

  List<Widget> _invoices() {
    final all = _allInvoiceTypes;
    final everything = all.isNotEmpty && _invoiceTypes.length == all.length;
    final cs = Theme.of(context).colorScheme;
    if (widget.invoiceTypeOptions.isEmpty) {
      return [_note('لم تُحمَّل أنواع الفواتير؛ تُقبل الوسيلة في كل الأنواع.')];
    }
    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const Key('pm-form-all-invoices'),
          onPressed: () => setState(() {
            everything ? _invoiceTypes.clear() : (_invoiceTypes..clear()..addAll(all));
            _invoiceTypesError = _invoiceTypes.isEmpty ? 'اختر نوع فاتورة واحدًا على الأقل' : null;
          }),
          icon: Icon(everything ? Icons.remove_done : Icons.done_all),
          label: Text(everything ? 'إلغاء تحديد الكل' : 'تحديد كل الأنواع'),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final o in widget.invoiceTypeOptions)
            if ('${o['value'] ?? ''}'.isNotEmpty)
              FilterChip(
                key: Key('pm-form-invoice-${o['value']}'),
                selected: _invoiceTypes.contains('${o['value']}'),
                label: Text('${o['name_ar'] ?? o['label'] ?? o['value']}'),
                avatar: Icon(o['category'] == 'accounting' ? Icons.account_balance_outlined : Icons.storefront_outlined,
                    size: 18),
                onSelected: (on) => setState(() {
                  on ? _invoiceTypes.add('${o['value']}') : _invoiceTypes.remove('${o['value']}');
                  _invoiceTypesError = _invoiceTypes.isEmpty ? 'اختر نوع فاتورة واحدًا على الأقل' : null;
                }),
              ),
        ],
      ),
      if (_invoiceTypesError != null) ...[
        const SizedBox(height: 8),
        Text(_invoiceTypesError!, style: TextStyle(color: cs.error)),
      ],
    ];
  }

  Widget _content() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(_Section.basic, _basic()),
        _section(_Section.fees, _fees(),
            hint: 'ما تخصمه الشركة: نسبتها، والثابت لكل عملية، وخططها، ورسم الإيداع، وكيف تقرّب.'),
        _section(_Section.settlement, _settlement(), hint: 'متى يصل مال هذه الوسيلة إلى البنك.'),
        _section(_Section.accounts, _accounts()),
        _section(_Section.invoices, _invoices(), hint: 'الفواتير التي تُقبل بها هذه الوسيلة.'),
      ],
    ),
  );

  Widget _saveButton() => FilledButton.icon(
    key: const Key('pm-form-save'),
    onPressed: _saving ? null : _save,
    icon: _saving
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(_editing ? Icons.save_outlined : Icons.add),
    label: Text(_editing ? 'حفظ' : 'إضافة'),
  );

  String get _title => _editing ? 'تعديل «${_m!['name'] ?? ''}»' : 'إضافة وسيلة دفع';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.compact) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'إغلاق',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          title: Text(_title, overflow: TextOverflow.ellipsis),
          actions: [Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: _saveButton())],
        ),
        body: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          child: _content(),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 12, 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: paymentTypeTone(context, _type).container,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(paymentTypeIcon(_type), color: paymentTypeTone(context, _type).onContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(_title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'إغلاق',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 210,
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final s in _Section.values)
                      ListTile(
                        key: Key('pm-form-go-${s.name}'),
                        dense: true,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        leading: Icon(_titles[s]!.$2, size: 20),
                        title: Text(_titles[s]!.$1),
                        onTap: () => _goTo(s),
                      ),
                  ],
                ),
              ),
              VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: _content(),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('pm-form-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('إلغاء'),
              ),
              const SizedBox(width: 8),
              _saveButton(),
            ],
          ),
        ),
      ],
    );
  }
}

/// An account picked from a list, searched by name or number.
class _AccountPickerDialog extends StatefulWidget {
  const _AccountPickerDialog({required this.accounts, this.selectedId});

  final List<Map<String, dynamic>> accounts;
  final int? selectedId;

  @override
  State<_AccountPickerDialog> createState() => _AccountPickerDialogState();
}

class _AccountPickerDialogState extends State<_AccountPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final a in widget.accounts)
        if (q.isEmpty ||
            '${a['name'] ?? ''}'.toLowerCase().contains(q) ||
            '${a['account_number'] ?? ''}'.contains(q))
          a,
    ];
    return AlertDialog(
      title: const Text('اختر حساب المصروف'),
      content: SizedBox(
        width: 380,
        height: 440,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'بحث باسم الحساب أو رقمه',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final a = shown[i];
                  final selected = a['id'] == widget.selectedId;
                  return ListTile(
                    selected: selected,
                    selectedTileColor: cs.primaryContainer,
                    selectedColor: cs.onPrimaryContainer,
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text('${a['name'] ?? ''}'),
                    subtitle: Text('${a['account_number'] ?? ''}'),
                    onTap: () => Navigator.pop(context, a),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء'))],
    );
  }
}
