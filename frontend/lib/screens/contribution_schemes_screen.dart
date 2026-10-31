import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils.dart' show normalizeNumber;
import '../utils/arabic_number_formatter.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// The contribution schemes, the owner's (PAYROLL-2, ADR-068): a scheme an
/// employee is in -- not his nationality -- and its components, each a rate
/// on the employee and on the employer, on its base, up to its cap, from a
/// day on. A new rate is a new row from its day: the past keeps its own.

const _bases = {
  'basic': ('الأساسي', 'Basic'),
  'basic_housing': ('الأساسي والسكن', 'Basic + housing'),
  'gross': ('الإجمالي', 'Gross'),
};

class ContributionSchemesScreen extends StatefulWidget {
  const ContributionSchemesScreen({
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
  State<ContributionSchemesScreen> createState() =>
      _ContributionSchemesScreenState();
}

class _ContributionSchemesScreenState extends State<ContributionSchemesScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  List<Map<String, dynamic>>? _schemes;
  Object? _error;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final schemes = await _service.allSchemes();
      if (mounted) setState(() => _schemes = schemes);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _do(Future<void> Function() action, String done) async {
    try {
      await action();
      await _load();
      if (mounted) AppFeedback.success(context, done);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _newScheme() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(_isAr ? 'خطة اشتراك جديدة' : 'New scheme'),
        content: TextField(
          key: const ValueKey('scheme-name'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: _isAr ? 'الاسم' : 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            key: const ValueKey('scheme-create'),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(_isAr ? 'أنشئ' : 'Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _do(
      () => _service.createScheme(name),
      _isAr ? 'أُنشئت الخطة' : 'Created',
    );
  }

  Future<void> _component(
    Map<String, dynamic> scheme, [
    Map<String, dynamic>? row,
  ]) async {
    final edited = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ComponentDialog(row: row, isAr: _isAr),
    );
    if (edited == null) return;
    await _do(
      () => row == null
          ? _service.addComponent(scheme['id'] as int, edited)
          : _service.updateComponent(row['id'] as int, edited),
      _isAr ? 'حُفظت النسبة' : 'Saved',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final theme = Theme.of(context);
    final schemes = _schemes;
    Widget body;
    if (_error != null && schemes == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل الخطط' : 'Could not load the schemes',
        error: _error!,
        onRetry: _load,
      );
    } else if (schemes == null) {
      body = const AppLoadingView(summaryBlocks: 0, rows: 5);
    } else if (schemes.isEmpty) {
      body = AppEmptyView(
        title: isAr ? 'لا خطط اشتراك' : 'No schemes',
        actionLabel: isAr ? 'خطة جديدة' : 'New scheme',
        actionIcon: Icons.add,
        onAction: _newScheme,
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          for (final scheme in schemes)
            Card(
              key: ValueKey('scheme-${scheme['id']}'),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${scheme['name']}',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        Switch(
                          key: ValueKey('scheme-active-${scheme['id']}'),
                          value: scheme['is_active'] != false,
                          onChanged: (v) => _do(
                            () => _service.setSchemeActive(
                              scheme['id'] as int,
                              v,
                            ),
                            v
                                ? (isAr ? 'فُعّلت' : 'Active')
                                : (isAr ? 'أُوقفت' : 'Stopped'),
                          ),
                        ),
                      ],
                    ),
                    if (scheme['is_active'] == false)
                      Text(
                        isAr
                            ? 'موقوفة: لا تُحسب لمن فيها'
                            : 'Stopped: not reckoned',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppSemanticColors.of(context).warning.fg,
                        ),
                      ),
                    for (final row
                        in (scheme['components'] as List? ?? const [])
                            .cast<Map<String, dynamic>>())
                      ListTile(
                        key: ValueKey('component-${row['id']}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${row['name']} — '
                          '${isAr ? 'الموظف' : 'employee'} ${ltrIsolate('${row['employee_rate']}%')} · '
                          '${isAr ? 'المنشأة' : 'employer'} ${ltrIsolate('${row['employer_rate']}%')}',
                        ),
                        subtitle: Text(
                          '${isAr ? 'على' : 'on'} ${isAr ? _bases[row['base']]?.$1 ?? row['base'] : _bases[row['base']]?.$2 ?? row['base']}'
                          '${row['base_cap'] == null ? '' : ' · ${isAr ? 'سقف' : 'cap'} ${ltrIsolate(formatAmount(row['base_cap'] as num))}'}'
                          ' · ${isAr ? 'من' : 'from'} ${ltrIsolate('${row['effective_from']}')}',
                        ),
                        trailing: IconButton(
                          tooltip: isAr ? 'تصحيح' : 'Correct',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _component(scheme, row),
                        ),
                      ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: ValueKey('scheme-add-rate-${scheme['id']}'),
                        onPressed: () => _component(scheme),
                        icon: const Icon(Icons.add),
                        label: Text(
                          isAr ? 'نسبة من تاريخ' : 'A rate from a day',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'خطط الاشتراك (التأمينات)' : 'Contribution schemes'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('scheme-new'),
        onPressed: _newScheme,
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'خطة جديدة' : 'New scheme'),
      ),
      body: body,
    );
  }
}

class _ComponentDialog extends StatefulWidget {
  const _ComponentDialog({required this.row, required this.isAr});
  final Map<String, dynamic>? row;
  final bool isAr;

  @override
  State<_ComponentDialog> createState() => _ComponentDialogState();
}

class _ComponentDialogState extends State<_ComponentDialog> {
  late final _code = TextEditingController(
    text: '${widget.row?['code'] ?? ''}',
  );
  late final _name = TextEditingController(
    text: '${widget.row?['name'] ?? ''}',
  );
  late final _employee = TextEditingController(
    text: '${widget.row?['employee_rate'] ?? ''}',
  );
  late final _employer = TextEditingController(
    text: '${widget.row?['employer_rate'] ?? ''}',
  );
  late final _cap = TextEditingController(
    text: '${widget.row?['base_cap'] ?? ''}',
  );
  late final _from = TextEditingController(
    text: '${widget.row?['effective_from'] ?? ''}',
  );
  late String? _base = widget.row?['base'] as String?;

  @override
  void dispose() {
    for (final c in [_code, _name, _employee, _employer, _cap, _from]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _number(TextEditingController c, String label, String key) =>
      TextField(
        key: ValueKey(key),
        controller: c,
        textDirection: TextDirection.ltr,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          ArabicNumberTextInputFormatter(),
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(labelText: label),
      );

  /// As typed; the server checks each and says why it refuses.
  Map<String, dynamic> get _row {
    String plain(TextEditingController c) => normalizeNumber(c.text).trim();
    return {
      'code': _code.text.trim(),
      'name': _name.text.trim(),
      'base': _base,
      'employee_rate': plain(_employee).isEmpty ? null : plain(_employee),
      'employer_rate': plain(_employer).isEmpty ? null : plain(_employer),
      'base_cap': plain(_cap).isEmpty ? null : plain(_cap),
      'effective_from': _from.text.trim(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final correcting = widget.row != null;
    return AlertDialog(
      title: Text(
        correcting
            ? (isAr ? 'تصحيح نسبة' : 'Correct a rate')
            : (isAr ? 'نسبة من تاريخ' : 'A rate from a day'),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (correcting)
                Text(
                  isAr
                      ? 'التصحيح لخطأ في الإدخال؛ النسبة الجديدة تُضاف من تاريخها فيبقى الماضي على نسبته.'
                      : 'Correct a typo; a new rate is added from its day.',
                ),
              TextField(
                key: const ValueKey('component-code'),
                controller: _code,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: isAr ? 'الرمز (مثل annuities)' : 'Code',
                ),
              ),
              TextField(
                key: const ValueKey('component-name'),
                controller: _name,
                decoration: InputDecoration(labelText: isAr ? 'الاسم' : 'Name'),
              ),
              DropdownButtonFormField<String>(
                key: const ValueKey('component-base'),
                initialValue: _base,
                decoration: InputDecoration(
                  labelText: isAr ? 'الوعاء' : 'Base',
                ),
                items: [
                  for (final e in _bases.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(isAr ? e.value.$1 : e.value.$2),
                    ),
                ],
                onChanged: (v) => setState(() => _base = v),
              ),
              _number(
                _employee,
                isAr ? 'نسبة الموظف %' : 'Employee %',
                'component-employee',
              ),
              _number(
                _employer,
                isAr ? 'نسبة المنشأة %' : 'Employer %',
                'component-employer',
              ),
              _number(
                _cap,
                isAr ? 'سقف الوعاء (فارغ: بلا سقف)' : 'Cap (empty: none)',
                'component-cap',
              ),
              TextField(
                key: const ValueKey('component-from'),
                controller: _from,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: isAr
                      ? 'من تاريخ (YYYY-MM-DD)'
                      : 'From (YYYY-MM-DD)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(
          key: const ValueKey('component-save'),
          onPressed: () => Navigator.pop(context, _row),
          child: Text(isAr ? 'حفظ' : 'Save'),
        ),
      ],
    );
  }
}
