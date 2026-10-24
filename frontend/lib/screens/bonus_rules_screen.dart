import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/bonus_rule_model.dart';
import '../models/employee_model.dart';
import '../models/invoice_type_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/currency_utils.dart' as cu;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../widgets/tiered_rule_editor.dart';

/// Bonus rules (bonus study م3ج): each rule said as the calculator reads it --
/// its measure or payout, its employees by name, its floor and cap, its
/// validity -- and the form offers only what the calculator reads.
class BonusRulesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final bool embedded;

  const BonusRulesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.embedded = false,
  });

  @override
  State<BonusRulesScreen> createState() => _BonusRulesScreenState();
}

class _BonusRulesScreenState extends State<BonusRulesScreen> {
  List<BonusRuleModel> _rules = [];
  bool _loading = false;
  Object? _error;
  bool? _activeFilter;

  static final _day = DateFormat('yyyy-MM-dd');

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getBonusRules(isActive: _activeFilter);
      if (!mounted) return;
      setState(() => _rules = [
            for (final json in data)
              BonusRuleModel.fromJson(json as Map<String, dynamic>),
          ]);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showRuleDialog({BonusRuleModel? rule}) {
    showDialog(
      context: context,
      builder: (ctx) => _BonusRuleDialog(
        api: widget.api,
        isArabic: widget.isArabic,
        rule: rule,
        onSaved: () {
          Navigator.of(ctx).pop();
          AppFeedback.success(context, rule == null ? 'أُضيفت القاعدة' : 'حُفظت القاعدة');
          _loadRules();
        },
      ),
    );
  }

  /// Stopping a rule keeps it and its bonuses; it computes nothing more.
  Future<void> _toggle(BonusRuleModel rule) async {
    if (rule.id == null) return;
    try {
      await widget.api.updateBonusRule(rule.id!, {'is_active': !rule.isActive});
      if (!mounted) return;
      AppFeedback.success(context,
          rule.isActive ? 'أُوقفت «${rule.name}»: لا تُحسب بها مكافأة بعد اليوم' : 'فُعّلت «${rule.name}»');
      _loadRules();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم يتغيّر');
    }
  }

  Future<void> _deleteRule(BonusRuleModel rule) async {
    if (rule.id == null) return;
    final go = await confirmFinancialAction(
      context,
      title: 'حذف «${rule.name}»',
      effect: 'تُحذف القاعدة نهائيًّا. وما كانت له مكافآت أو كان هدف موظف لا يُحذف: '
          'يُوقَف بدلًا من ذلك، فتبقى مكافآته وتاريخه.',
      confirmLabel: 'حذف',
    );
    if (go == null || !mounted) return;
    try {
      await widget.api.deleteBonusRule(rule.id!);
      if (!mounted) return;
      AppFeedback.success(context, 'حُذفت «${rule.name}»');
      _loadRules();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'rule_in_use') {
        AppFeedback.warning(context, e.message,
            action: rule.isActive ? (label: 'أوقفها', onPressed: () => _toggle(rule)) : null);
      } else {
        AppFeedback.error(context, e, title: 'لم تُحذف');
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُحذف');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final Widget content;
    if (_loading) {
      content = const AppLoadingView(summaryBlocks: 0, rows: 4);
    } else if (_error != null) {
      content = AppErrorView(title: 'تعذّر تحميل القواعد', error: _error!, onRetry: _loadRules);
    } else if (_rules.isEmpty) {
      content = AppEmptyView(
        title: _activeFilter == null ? 'لا قواعد مكافآت' : 'لا قواعد بهذا الفلتر',
        hint: 'القاعدة تقول ما يُقاس، وفترته، وما يُصرف عليه.',
        icon: Icons.rule_rounded,
        actionLabel: 'إضافة قاعدة',
        actionIcon: Icons.add,
        onAction: () => _showRuleDialog(),
      );
    } else {
      content = ListView.builder(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 96),
        itemCount: _rules.length,
        itemBuilder: (ctx, i) => _buildRuleCard(_rules[i]),
      );
    }

    final body = widget.embedded
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildEmbeddedHeader(isAr),
              Expanded(child: content),
            ],
          )
        : content;

    return Scaffold(
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(isAr ? 'قواعد المكافآت' : 'Bonus Rules'),
              centerTitle: true,
              actions: _buildAppBarActions(isAr),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showRuleDialog(),
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'إضافة قاعدة' : 'Add Rule'),
      ),
      body: SafeArea(top: widget.embedded, bottom: false, child: body),
    );
  }

  List<Widget> _buildAppBarActions(bool isAr) {
    return [
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'تحديث',
        onPressed: _loading ? null : _loadRules,
      ),
      PopupMenuButton<bool?>(
        icon: const Icon(Icons.filter_list),
        tooltip: 'الحالة',
        onSelected: (value) {
          setState(() => _activeFilter = value);
          _loadRules();
        },
        itemBuilder: (ctx) => [
          PopupMenuItem(value: null, child: Text(isAr ? 'الكل' : 'All')),
          PopupMenuItem(value: true, child: Text(isAr ? 'نشطة فقط' : 'Active Only')),
          PopupMenuItem(value: false, child: Text(isAr ? 'موقوفة فقط' : 'Stopped Only')),
        ],
      ),
    ];
  }

  Widget _buildEmbeddedHeader(bool isAr) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            isAr ? 'قواعد المكافآت' : 'Bonus Rules',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          ..._buildAppBarActions(isAr),
        ],
      ),
    );
  }

  String _money(num v) => '${cu.formatAmount(v)} ${context.read<SettingsProvider>().currencySymbolText}';

  static String _n(Object? v) =>
      v is num ? cu.formatAmount(v, decimals: v == v.truncate() ? 0 : 2) : '${v ?? '—'}';

  /// What the rule is said by, line by line, as the calculator reads it.
  List<(String, String)> _factsOf(BonusRuleModel rule) {
    final c = rule.conditions ?? const <String, dynamic>{};
    final valid = [
      if (rule.validFrom != null) 'من ${_day.format(rule.validFrom!)}',
      if (rule.validTo != null) 'إلى ${_day.format(rule.validTo!)}',
    ];
    return [
      if (rule.description != null && rule.description!.isNotEmpty) ('الوصف', rule.description!),
      (
        'يُصرف لـ',
        rule.targetEmployeeNames.isNotEmpty
            ? rule.targetEmployeeNames.join('، ')
            : (rule.targetEmployeeIds?.isNotEmpty ?? false)
                ? '${rule.targetEmployeeIds!.length} موظف'
                : 'كل الموظفين',
      ),
      if (rule.ruleType != 'tiered')
        ('المكافأة', '${BonusRuleModel.getBonusTypeNameAr(rule.bonusType)}: ${_n(rule.bonusValue)}'),
      if (rule.ruleType == 'sales_target') ('هدف المبيعات', _money((c['sales_target'] as num?) ?? 0)),
      if (rule.ruleType == 'profit_based') ...[
        ('أقل ربح', _n(c['min_profit'] ?? 0)),
        ('الربح', c['profit_type'] == 'gold' ? 'بالذهب' : 'بالنقد'),
        (
          'الفواتير',
          (rule.applicableInvoiceTypes?.isNotEmpty ?? false)
              ? rule.applicableInvoiceTypes!.join('، ')
              : 'البيع وشراء الكسر',
        ),
      ],
      if (rule.isPointsBased) ...[
        (
          'فترة النقاط',
          BonusRuleModel.getPointsPeriodNameAr((c['points_period'] as String?) ?? 'month'),
        ),
        if (c['min_points'] != null) ('أقل نقاط', _n(c['min_points'])),
      ],
      if (rule.minBonus > 0) ('أقل مبلغ يُصرف', _money(rule.minBonus)),
      if (rule.maxBonus != null) ('سقف المكافأة', _money(rule.maxBonus!)),
      if (valid.isNotEmpty) ('الصلاحية', valid.join(' ')),
      if (rule.targetDepartments?.isNotEmpty ?? false) ('الأقسام', rule.targetDepartments!.join('، ')),
      if (rule.targetPositions?.isNotEmpty ?? false) ('الوظائف', rule.targetPositions!.join('، ')),
    ];
  }

  Widget _buildRuleCard(BonusRuleModel rule) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final tone = rule.isActive ? tones.ready : tones.sectionSlate;

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      child: ExpansionTile(
        shape: const Border(),
        leading: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
          decoration: BoxDecoration(
            color: tone.container,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
          child: Text(
            rule.isActive ? 'نشطة' : 'موقوفة',
            style: theme.textTheme.labelSmall?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w600),
          ),
        ),
        title: Text(rule.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(rule.summaryAr, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
        children: [
          for (final (label, value) in _factsOf(rule))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(label,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                  Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpace.sm,
            children: [
              TextButton.icon(
                onPressed: () => _showRuleDialog(rule: rule),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('تعديل'),
              ),
              TextButton.icon(
                key: Key('rule-toggle-${rule.id}'),
                onPressed: () => _toggle(rule),
                icon: Icon(rule.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 18),
                label: Text(rule.isActive ? 'إيقاف' : 'تفعيل'),
              ),
              TextButton.icon(
                key: Key('rule-delete-${rule.id}'),
                onPressed: () => _deleteRule(rule),
                style: TextButton.styleFrom(foregroundColor: cs.error),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('حذف'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A rule's form. It offers what the calculator reads, and nothing else
/// (bonus study م3ج): per type its payouts and its own condition -- a sales
/// target, a least profit, a points period -- and invoice types where they
/// are read (a profit rule). The fields nobody read («حد أدنى للمبيعات»,
/// «ربح % من الفاتورة», «نسبة حضور») are gone; a sales rule's target, which
/// no field set, is offered.
class _BonusRuleDialog extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final BonusRuleModel? rule;
  final VoidCallback onSaved;

  const _BonusRuleDialog({
    required this.api,
    required this.isArabic,
    this.rule,
    required this.onSaved,
  });

  @override
  State<_BonusRuleDialog> createState() => _BonusRuleDialogState();
}

class _BonusRuleDialogState extends State<_BonusRuleDialog> {
  /// The condition keys the form owns; the rest of a rule's conditions are
  /// kept as they are. The last three were read by no calculator.
  static const _ownedConditions = {
    'sales_target', 'min_profit', 'profit_type', 'min_points', 'points_period',
    'min_sales', 'min_profit_percent_of_invoice', 'min_attendance_rate',
  };

  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(text: widget.rule?.name ?? '');
  late final _descController = TextEditingController(text: widget.rule?.description ?? '');
  late final _valueController = TextEditingController(text: _typed(widget.rule?.bonusValue ?? 0));
  late final _minController = TextEditingController(text: _typed(widget.rule?.minBonus ?? 0));
  late final _maxController =
      TextEditingController(text: widget.rule?.maxBonus == null ? '' : _typed(widget.rule!.maxBonus!));
  late final _salesTargetController = TextEditingController(text: _condition('sales_target'));
  late final _minProfitController = TextEditingController(text: _condition('min_profit'));
  late final _minPointsController = TextEditingController(text: _condition('min_points'));

  late String _ruleType = widget.rule?.ruleType ?? 'tiered';

  /// A tiered rule's measure, period and tiers (bonus study م2).
  late TieredTerms _tiered =
      widget.rule?.ruleType == 'tiered' ? TieredTerms.of(widget.rule!) : TieredTerms.blank();
  late String _bonusType = _payoutFor(_ruleType, widget.rule?.bonusType);
  late String _pointsPeriod = (widget.rule?.conditions?['points_period'] as String?) ?? 'month';
  late String _profitType = (widget.rule?.conditions?['profit_type'] as String?) ?? 'cash';
  late bool _isActive = widget.rule?.isActive ?? true;
  late DateTime? _validFrom = widget.rule?.validFrom;
  late DateTime? _validTo = widget.rule?.validTo;
  bool _saving = false;

  List<EmployeeModel> _allEmployees = [];
  late final List<int> _selectedEmployeeIds = [...?widget.rule?.targetEmployeeIds];
  List<InvoiceTypeModel> _availableInvoiceTypes = [];
  late final List<String> _selectedInvoiceTypes = [...?widget.rule?.applicableInvoiceTypes];
  bool _loadingData = false;
  Object? _dataError;

  static final _day = DateFormat('yyyy-MM-dd');

  static String _typed(double v) => v == v.truncateToDouble() ? '${v.toInt()}' : '$v';

  String _condition(String key) {
    final v = widget.rule?.conditions?[key];
    return v is num ? _typed(v.toDouble()) : '';
  }

  /// [current] when its type computes it, else the type's first payout.
  static String _payoutFor(String ruleType, String? current) {
    final offered = BonusRuleModel.bonusTypesByRule[ruleType];
    if (offered == null) return current ?? 'fixed';
    return offered.contains(current) ? current! : offered.first;
  }

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loadingData = true;
      _dataError = null;
    });
    try {
      final employeesResponse = await widget.api.getEmployees(isActive: true, perPage: 100);
      final employeesData = employeesResponse['employees'];
      final employees = employeesData is List<EmployeeModel>
          ? employeesData
          : [
              for (final json in (employeesData as List? ?? const []))
                EmployeeModel.fromJson(json as Map<String, dynamic>),
            ];
      final invoiceTypesData = await widget.api.getInvoiceTypes();
      final invoiceTypes = [
        for (final t in invoiceTypesData)
          t is Map
              ? InvoiceTypeModel.fromJson(Map<String, dynamic>.from(t))
              : InvoiceTypeModel(value: '$t', label: '$t', description: '$t'),
      ];
      if (!mounted) return;
      setState(() {
        _allEmployees = employees;
        _availableInvoiceTypes = invoiceTypes;
      });
    } catch (e) {
      if (mounted) setState(() => _dataError = e);
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nameController, _descController, _valueController, _minController, _maxController,
      _salesTargetController, _minProfitController, _minPointsController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static double? _number(TextEditingController c) =>
      c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());

  String? _numberOrEmpty(String? v) =>
      v == null || v.trim().isEmpty || double.tryParse(v.trim()) != null ? null : 'رقم';

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final tiered = _ruleType == 'tiered';
    if (tiered && _tiered.error != null) {
      AppFeedback.error(context, _tiered.error!, title: 'الشرائح');
      return;
    }

    final conditions = <String, dynamic>{
      for (final e in (widget.rule?.conditions ?? const <String, dynamic>{}).entries)
        if (!_ownedConditions.contains(e.key)) e.key: e.value,
      if (_ruleType == 'sales_target') 'sales_target': _number(_salesTargetController) ?? 0.0,
      if (_ruleType == 'profit_based') ...{
        'min_profit': _number(_minProfitController) ?? 0.0,
        'profit_type': _profitType,
      },
      if (_ruleType == 'points_based') ...{
        if (_number(_minPointsController) != null) 'min_points': _number(_minPointsController),
        'points_period': _pointsPeriod,
      },
    };

    final payload = <String, dynamic>{
      'name': _nameController.text.trim(),
      'description': _descController.text.trim().isEmpty ? null : _descController.text.trim(),
      'rule_type': _ruleType,
      if (tiered) ..._tiered.toJson(),
      if (!tiered) 'bonus_type': _bonusType,
      if (!tiered) 'bonus_value': _number(_valueController) ?? 0.0,
      'min_bonus': _number(_minController) ?? 0.0,
      'max_bonus': _number(_maxController),
      'conditions': conditions,
      'target_employee_ids': _selectedEmployeeIds.isEmpty ? null : _selectedEmployeeIds,
      // Read by the profit rule alone; the others keep what they hold.
      if (_ruleType == 'profit_based')
        'applicable_invoice_types': _selectedInvoiceTypes.isEmpty ? null : _selectedInvoiceTypes,
      'is_active': _isActive,
      'valid_from': _validFrom == null ? null : _day.format(_validFrom!),
      'valid_to': _validTo == null ? null : _day.format(_validTo!),
    };

    setState(() => _saving = true);
    try {
      if (widget.rule?.id != null) {
        await widget.api.updateBonusRule(widget.rule!.id!, payload);
      } else {
        await widget.api.createBonusRule(payload);
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'لم تُحفظ القاعدة');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(String title, {String? hint}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          if (hint != null)
            Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _numberField(TextEditingController c, String label, {String? helper, Key? key}) => TextFormField(
        key: key,
        controller: c,
        decoration: InputDecoration(labelText: label, helperText: helper),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: _numberOrEmpty,
      );

  Widget _date(String label, DateTime? value, ValueChanged<DateTime?> set) => Expanded(
        child: InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked != null) setState(() => set(picked));
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              suffixIcon: value == null
                  ? null
                  : IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => set(null)),
                    ),
            ),
            child: Text(value != null ? _day.format(value) : 'بلا حد'),
          ),
        ),
      );

  Widget _chips<T>({
    required List<T> all,
    required List<T> selected,
    required String Function(T) label,
    required String empty,
  }) {
    final theme = Theme.of(context);
    if (_loadingData) return const SizedBox(height: 80, child: AppLoadingView(summaryBlocks: 0, rows: 1));
    if (_dataError != null) {
      return Row(children: [
        Expanded(
          child: Text('تعذّر التحميل: ${AppFeedback.messageOf(_dataError!)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ),
        TextButton(onPressed: _loadInitialData, child: const Text('إعادة المحاولة')),
      ]);
    }
    if (all.isEmpty) {
      return Text(empty, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final item in all)
          FilterChip(
            label: Text(label(item)),
            selected: selected.contains(item),
            onSelected: (on) => setState(() => on ? selected.add(item) : selected.remove(item)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final payouts = BonusRuleModel.bonusTypesByRule[_ruleType] ?? const <String>[];
    final employees = _allEmployees.where((e) => e.id != null).toList();

    return AlertDialog(
      title: Text(
        widget.rule == null
            ? (isAr ? 'إضافة قاعدة مكافأة' : 'Add Bonus Rule')
            : (isAr ? 'تعديل قاعدة المكافأة' : 'Edit Bonus Rule'),
      ),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: isAr ? 'الاسم' : 'Name'),
                  validator: (v) => v == null || v.trim().isEmpty ? 'مطلوب' : null,
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _descController,
                  decoration: InputDecoration(labelText: isAr ? 'الوصف' : 'Description'),
                  maxLines: 2,
                ),
                const SizedBox(height: AppSpace.md),
                DropdownButtonFormField<String>(
                  value: _ruleType,
                  decoration: InputDecoration(labelText: isAr ? 'نوع القاعدة' : 'Rule Type'),
                  items: [
                    for (final t in BonusRuleModel.ruleTypesFor(widget.rule?.ruleType))
                      DropdownMenuItem(value: t, child: Text(BonusRuleModel.getRuleTypeNameAr(t))),
                  ],
                  onChanged: (v) => setState(() {
                    _ruleType = v!;
                    _bonusType = _payoutFor(_ruleType, _bonusType);
                  }),
                ),
                const SizedBox(height: AppSpace.md),
                if (_ruleType == 'tiered')
                  TieredRuleEditor(
                    initial: _tiered,
                    api: widget.api,
                    scope: () => {
                      if (_selectedEmployeeIds.isNotEmpty) 'target_employee_ids': _selectedEmployeeIds,
                      'min_bonus': _number(_minController) ?? 0.0,
                      if (_number(_maxController) != null) 'max_bonus': _number(_maxController),
                    },
                    onChanged: (t) => _tiered = t,
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    key: const Key('rule-payout'),
                    value: _bonusType,
                    decoration: InputDecoration(labelText: isAr ? 'نوع المكافأة' : 'Bonus Type'),
                    items: [
                      for (final t in payouts)
                        DropdownMenuItem(value: t, child: Text(BonusRuleModel.getBonusTypeNameAr(t))),
                    ],
                    onChanged: (v) => setState(() => _bonusType = v!),
                  ),
                  const SizedBox(height: AppSpace.md),
                  _numberField(
                    _valueController,
                    switch (_bonusType) {
                      'points_per_unit' => 'المبلغ لكل نقطة',
                      'fixed' => 'المبلغ',
                      _ => 'النسبة %',
                    },
                    helper: _bonusType == 'points_per_unit' ? 'مثال: 0.5 يعني 0.5 $currency لكل نقطة' : null,
                  ),
                  if (_ruleType == 'sales_target') ...[
                    const SizedBox(height: AppSpace.md),
                    _numberField(
                      _salesTargetController,
                      'هدف المبيعات',
                      key: const Key('rule-sales-target'),
                      helper: 'لا تُصرف المكافأة إلا إذا بلغت مبيعات الموظف في الفترة هذا الرقم',
                    ),
                  ],
                  if (_ruleType == 'profit_based') ...[
                    const SizedBox(height: AppSpace.md),
                    Row(children: [
                      Expanded(child: _numberField(_minProfitController, 'أقل ربح')),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _profitType,
                          decoration: const InputDecoration(labelText: 'الربح'),
                          items: const [
                            DropdownMenuItem(value: 'cash', child: Text('بالنقد')),
                            DropdownMenuItem(value: 'gold', child: Text('بالذهب')),
                          ],
                          onChanged: (v) => setState(() => _profitType = v!),
                        ),
                      ),
                    ]),
                  ],
                  if (_ruleType == 'points_based') ...[
                    const SizedBox(height: AppSpace.md),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _pointsPeriod,
                          decoration: const InputDecoration(labelText: 'فترة النقاط'),
                          items: [
                            for (final p in BonusRuleModel.pointsPeriods)
                              DropdownMenuItem(value: p, child: Text(BonusRuleModel.getPointsPeriodNameAr(p))),
                          ],
                          onChanged: (v) => setState(() => _pointsPeriod = v!),
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(child: _numberField(_minPointsController, 'أقل نقاط')),
                    ]),
                  ],
                ],
                const SizedBox(height: AppSpace.md),
                Row(children: [
                  Expanded(child: _numberField(_minController, 'أقل مبلغ يُصرف')),
                  const SizedBox(width: AppSpace.md),
                  Expanded(child: _numberField(_maxController, 'سقف المكافأة', helper: 'فارغ: بلا سقف')),
                ]),
                _section('الصلاحية', hint: 'فارغ: بلا حد.'),
                Row(children: [
                  _date('من تاريخ', _validFrom, (v) => _validFrom = v),
                  const SizedBox(width: AppSpace.md),
                  _date('إلى تاريخ', _validTo, (v) => _validTo = v),
                ]),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isAr ? 'نشطة' : 'Active'),
                  subtitle: const Text('الموقوفة لا تُحسب بها مكافأة، وتبقى مكافآتها'),
                  value: _isActive,
                  onChanged: (v) => setState(() => _isActive = v),
                ),
                _section(
                  'الموظفون${_selectedEmployeeIds.isEmpty ? '' : ' (${_selectedEmployeeIds.length})'}',
                  hint: 'لا أحد محدد: تُطبَّق على الجميع.',
                ),
                _chips<int>(
                  all: [for (final e in employees) e.id!],
                  selected: _selectedEmployeeIds,
                  label: (id) => employees.firstWhere((e) => e.id == id).name,
                  empty: 'لا موظفين نشطين',
                ),
                if (_ruleType == 'profit_based') ...[
                  _section(
                    'أنواع الفواتير${_selectedInvoiceTypes.isEmpty ? '' : ' (${_selectedInvoiceTypes.length})'}',
                    hint: 'لا شيء محدد: البيع وشراء الكسر.',
                  ),
                  _chips<String>(
                    all: [for (final t in _availableInvoiceTypes) t.value],
                    selected: _selectedInvoiceTypes,
                    label: (v) => _availableInvoiceTypes.firstWhere((t) => t.value == v).label,
                    empty: 'لا أنواع فواتير',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('تراجع'),
        ),
        FilledButton(
          key: const Key('rule-save'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'جارٍ الحفظ…' : (isAr ? 'حفظ' : 'Save')),
        ),
      ],
    );
  }
}
