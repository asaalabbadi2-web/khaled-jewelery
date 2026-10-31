import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils.dart' show normalizeNumber;
import '../utils/arabic_number_formatter.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// The payroll's policy, the owner's figures (PAYROLL-2..5): every ratio and
/// count the runs read, none written in the code. A field left empty is not
/// set -- its part of the run is not reckoned and says so (the end of
/// service's figures are seeded none: «ابنِ هيكله ولا تضع أي أرقام»).
enum _Kind { percent, count, months, flag, choice }

class _Field {
  const _Field(this.key, this.kind, this.ar, this.en, {this.hintAr = ''});
  final String key;
  final _Kind kind;
  final String ar;
  final String en;
  final String hintAr;
}

const _sections = <(String, String, List<_Field>)>[
  (
    'هيكل الراتب',
    'Salary structure',
    [
      _Field(
        'housing_ratio',
        _Kind.percent,
        'بدل السكن من الأساسي',
        'Housing of basic',
      ),
      _Field(
        'transport_ratio',
        _Kind.percent,
        'بدل النقل من الأساسي',
        'Transport of basic',
      ),
    ],
  ),
  (
    'السلف',
    'Advances',
    [
      _Field(
        'advance_cap_ratio',
        _Kind.percent,
        'حدّ قسط السلفة من الأجر',
        'Installment cap of wage',
        hintAr: 'المادة 92',
      ),
      _Field(
        'advance_installments',
        _Kind.count,
        'عدد الأقساط إن لم يُذكر القسط',
        'Default installments',
      ),
    ],
  ),
  (
    'الحضور',
    'Attendance',
    [
      _Field(
        'attendance_enabled',
        _Kind.flag,
        'تفعيل الحضور',
        'Attendance enabled',
      ),
      _Field(
        'day_divisor',
        _Kind.count,
        'قاسم أجر اليوم',
        'Day divisor',
        hintAr: 'أجر اليوم = الأجر الشهري ÷ القاسم',
      ),
      _Field(
        'overtime_premium_ratio',
        _Kind.percent,
        'علاوة الساعة الإضافية',
        'Overtime premium',
      ),
    ],
  ),
  (
    'مكافأة نهاية الخدمة',
    'End of service',
    [
      _Field(
        'eos_wage_base',
        _Kind.choice,
        'وعاء الأجر',
        'Wage base',
        hintAr: 'المادة 84: الأجر الفعلي',
      ),
      _Field('eos_first_years', _Kind.count, 'السنوات الأولى', 'First years'),
      _Field(
        'eos_first_years_months',
        _Kind.months,
        'أشهر الأجر عن كل سنة من السنوات الأولى',
        'Months of wage per first year',
      ),
      _Field(
        'eos_after_years_months',
        _Kind.months,
        'أشهر الأجر عن كل سنة بعدها',
        'Months of wage per later year',
      ),
    ],
  ),
];

const _wageBases = {
  'gross': ('الإجمالي', 'Gross'),
  'basic_housing': ('الأساسي والسكن', 'Basic + housing'),
  'basic': ('الأساسي', 'Basic'),
};

class PayrollPolicyScreen extends StatefulWidget {
  const PayrollPolicyScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.service,
  });
  final ApiService api;
  final bool isArabic;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<PayrollPolicyScreen> createState() => _PayrollPolicyScreenState();
}

class _PayrollPolicyScreenState extends State<PayrollPolicyScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  final Map<String, TextEditingController> _text = {};
  final Map<String, Object?> _picked = {};

  /// The figures the owner unset -- sent null, the server forgets them (not 0).
  final Set<String> _cleared = {};
  Map<String, dynamic>? _policy;
  Object? _error;
  bool _busy = false;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _plain(num v) => formatAmount(
    v,
    decimals: v == v.roundToDouble() ? 0 : 2,
  ).replaceAll(',', '');

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final policy = await _service.policy();
      if (!mounted) return;
      setState(() {
        _policy = policy;
        for (final (_, _, fields) in _sections) {
          for (final f in fields) {
            final value = policy[f.key];
            switch (f.kind) {
              case _Kind.flag || _Kind.choice:
                _picked[f.key] = value;
              case _Kind.percent:
                _text[f.key] = TextEditingController(
                  text: value == null ? '' : _plain((value as num) * 100),
                );
              case _Kind.count || _Kind.months:
                _text[f.key] = TextEditingController(
                  text: value == null ? '' : _plain(value as num),
                );
            }
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// The fields filled in -- an empty one is not sent, unless it was unset
  /// here: then it is sent null and the server forgets it.
  Map<String, dynamic> get _changes {
    final changes = <String, dynamic>{};
    for (final (_, _, fields) in _sections) {
      for (final f in fields) {
        switch (f.kind) {
          case _Kind.flag || _Kind.choice:
            if (_picked[f.key] != null) {
              changes[f.key] = _picked[f.key];
            } else if (_cleared.contains(f.key)) {
              changes[f.key] = null;
            }
          case _Kind.percent || _Kind.count || _Kind.months:
            final raw = normalizeNumber(_text[f.key]!.text).trim();
            if (raw.isEmpty) {
              if (_cleared.contains(f.key)) changes[f.key] = null;
              continue;
            }
            final number = double.tryParse(raw);
            changes[f.key] = f.kind == _Kind.percent && number != null
                ? number / 100
                : (number ?? raw);
        }
      }
    }
    return changes;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final saved = await _service.savePolicy(_changes);
      if (!mounted) return;
      setState(() {
        _policy = saved;
        _cleared.clear();
      });
      AppFeedback.success(
        context,
        _isAr ? 'حُفظت سياسة الرواتب' : 'Policy saved',
      );
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _unset(_Field f) => setState(() {
    _cleared.add(f.key);
    _picked[f.key] = null;
    _text[f.key]?.clear();
  });

  /// The field, and its «إلغاء الضبط» while it holds a figure.
  Widget _withUnset(_Field f) {
    final holds = switch (f.kind) {
      _Kind.flag || _Kind.choice => _picked[f.key] != null,
      _ => _text[f.key]!.text.isNotEmpty,
    };
    return Row(
      children: [
        Expanded(child: _field(f)),
        if (holds)
          IconButton(
            key: ValueKey('policy-unset-${f.key}'),
            tooltip: _isAr ? 'إلغاء الضبط' : 'Unset',
            icon: const Icon(Icons.backspace_outlined),
            onPressed: () => _unset(f),
          ),
      ],
    );
  }

  Widget _field(_Field f) {
    final isAr = _isAr;
    final theme = Theme.of(context);
    final unset = _policy?[f.key] == null;
    final label = isAr ? f.ar : f.en;
    final helper = [
      if (isAr && f.hintAr.isNotEmpty) f.hintAr,
      if (unset) isAr ? 'غير مضبوط' : 'Not set',
    ].join(' · ');
    switch (f.kind) {
      case _Kind.flag:
        return SwitchListTile(
          key: ValueKey('policy-${f.key}'),
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: helper.isEmpty ? null : Text(helper),
          value: _picked[f.key] == true,
          onChanged: (v) => setState(() => _picked[f.key] = v),
        );
      case _Kind.choice:
        return DropdownButtonFormField<String>(
          // keyed by its value: unset, it is drawn again empty
          key: ValueKey('policy-${f.key}-${_picked[f.key]}'),
          initialValue: _picked[f.key] as String?,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper.isEmpty ? null : helper,
          ),
          items: [
            for (final e in _wageBases.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(isAr ? e.value.$1 : e.value.$2),
              ),
          ],
          onChanged: (v) => setState(() => _picked[f.key] = v),
        );
      case _Kind.percent || _Kind.count || _Kind.months:
        return TextField(
          key: ValueKey('policy-${f.key}'),
          controller: _text[f.key],
          onChanged: (_) => setState(() {}),
          textDirection: TextDirection.ltr,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            ArabicNumberTextInputFormatter(),
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: label,
            helperText: helper.isEmpty ? null : helper,
            helperStyle: unset
                ? theme.textTheme.bodySmall?.copyWith(
                    color: AppSemanticColors.of(context).warning.fg,
                  )
                : null,
            suffixText: switch (f.kind) {
              _Kind.percent => '%',
              _Kind.months => isAr ? 'شهر' : 'months',
              _ => null,
            },
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final theme = Theme.of(context);
    Widget body;
    if (_error != null && _policy == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل سياسة الرواتب' : 'Could not load the policy',
        error: _error!,
        onRetry: _load,
      );
    } else if (_policy == null) {
      body = const AppLoadingView(summaryBlocks: 0, rows: 8);
    } else {
      body = ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          for (final (ar, en, fields) in _sections)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(isAr ? ar : en, style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpace.sm),
                    for (final f in fields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: _withUnset(f),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'سياسة الرواتب' : 'Payroll policy')),
      body: body,
      bottomNavigationBar: _policy == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: FilledButton.icon(
                  key: const ValueKey('policy-save'),
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(isAr ? 'حفظ' : 'Save'),
                ),
              ),
            ),
    );
  }
}
