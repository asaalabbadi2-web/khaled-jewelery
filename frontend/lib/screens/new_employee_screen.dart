import 'package:flutter/material.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_leave_guard.dart';
import '../widgets/date_field.dart';
import '../widgets/employee_salary_panel.dart';
import 'employee_page.dart';

/// A new employee in three steps (HR-UX ط3; the owner, 2 Nov 2026, «اعتمد»):
/// his data -- he is saved there --, his salary, how he is paid; then his
/// page. Each step is saved as it is left, so leaving loses nothing saved.
/// Beside the steps, what he still lacks for the month's run -- as his file
/// says it, once he is saved.
///
/// The salary and payment steps are the salary panel's own cards: one
/// implementation, not a second form.
class NewEmployeeScreen extends StatefulWidget {
  const NewEmployeeScreen({
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
  State<NewEmployeeScreen> createState() => _NewEmployeeScreenState();
}

class _NewEmployeeScreenState extends State<NewEmployeeScreen> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _jobTitle = TextEditingController();
  final _department = TextEditingController();
  final _hireDate = TextEditingController();
  final _nationalId = TextEditingController();
  final _phone = TextEditingController();
  bool _ownCashSafe = false;
  bool _ownGoldSafe = false;
  final _salaryUnsaved = ValueNotifier<List<String>>(const []);

  int _step = 0;
  int? _employeeId;
  String _savedName = '';
  Map<String, dynamic>? _file;
  bool _busy = false;

  bool get _isAr => widget.isArabic;

  @override
  void dispose() {
    for (final c in [
      _name,
      _jobTitle,
      _department,
      _hireDate,
      _nationalId,
      _phone,
    ]) {
      c.dispose();
    }
    _salaryUnsaved.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _employeeId;
    if (id == null) return;
    try {
      final file = await _service.employeeFile(id);
      if (mounted) setState(() => _file = file);
    } catch (_) {
      // the checklist waits for the next step; the steps stand
    }
  }

  Future<void> _create() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    String? typed(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    setState(() => _busy = true);
    try {
      final created = await widget.api.createEmployee(
        {
          'name': _name.text.trim(),
          'job_title': typed(_jobTitle),
          'department': typed(_department),
          'hire_date': typed(_hireDate),
          'national_id': typed(_nationalId),
          'phone': typed(_phone),
          'auto_create_cash_safe_box': _ownCashSafe,
          'auto_create_gold_safe_box': _ownGoldSafe,
        }..removeWhere((_, v) => v == null),
      );
      if (!mounted) return;
      setState(() {
        _employeeId = created.id;
        _savedName = created.name;
        _step = 1;
      });
      AppFeedback.success(context, _isAr ? 'حُفظ الموظف' : 'Saved');
      await _refresh();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    if (_salaryUnsaved.value.isNotEmpty &&
        !await AppLeaveGuard.confirmLeave(context)) {
      return;
    }
    _salaryUnsaved.value = const [];
    if (_step < 2) {
      setState(() => _step++);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EmployeePage(
          api: widget.api,
          employeeId: _employeeId!,
          isArabic: _isAr,
          service: widget.service,
        ),
      ),
    );
  }

  Widget _steps() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    final steps = [
      (isAr ? 'البيانات' : 'His data', isAr ? 'يُحفظ الموظف' : 'He is saved'),
      (
        isAr ? 'الراتب' : 'His salary',
        isAr ? 'الإجمالي وتقسيمه' : 'Gross and split',
      ),
      (isAr ? 'الصرف' : 'His payment', isAr ? 'تحويل أو نقد' : 'Bank or cash'),
    ];
    return Row(
      children: [
        for (final (i, (title, hint)) in steps.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Container(
              key: ValueKey('new-employee-step-$i'),
              padding: const EdgeInsets.all(AppSpace.sm),
              decoration: BoxDecoration(
                color: i < _step
                    ? tones.ready.container
                    : i == _step
                    ? tones.gold.container
                    : theme.colorScheme.surfaceContainerLow,
                border: i == _step
                    ? Border.all(color: tones.gold.fg, width: 2)
                    : null,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: i < _step
                        ? tones.ready.fg
                        : i == _step
                        ? tones.gold.fg
                        : theme.colorScheme.outlineVariant,
                    foregroundColor: theme.colorScheme.surface,
                    child: i < _step
                        ? const Icon(Icons.check, size: 16)
                        : Text('${i + 1}'),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          hint,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _dataStep() {
    final isAr = _isAr;
    Widget field(
      TextEditingController c,
      String label,
      String key, {
      bool required = false,
      bool ltr = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: TextFormField(
        key: ValueKey(key),
        controller: c,
        textDirection: ltr ? TextDirection.ltr : null,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (v) => (v ?? '').trim().isEmpty
                  ? (isAr ? 'الاسم مطلوب' : 'The name is required')
                  : null
            : null,
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field(
                _name,
                isAr ? 'الاسم الكامل' : 'Full name',
                'new-employee-name',
                required: true,
              ),
              field(
                _jobTitle,
                isAr ? 'المسمى الوظيفي' : 'Job title',
                'new-employee-job',
              ),
              field(
                _department,
                isAr ? 'القسم' : 'Department',
                'new-employee-department',
              ),
              DateField(
                key: const ValueKey('new-employee-hire-date'),
                controller: _hireDate,
                label: isAr ? 'تاريخ التعيين' : 'Hire date',
              ),
              const SizedBox(height: AppSpace.sm),
              field(
                _nationalId,
                isAr ? 'الهوية / الإقامة (اختياري)' : 'National ID (optional)',
                'new-employee-national-id',
                ltr: true,
              ),
              field(
                _phone,
                isAr ? 'الجوال (اختياري)' : 'Mobile (optional)',
                'new-employee-phone',
                ltr: true,
              ),
              SwitchListTile(
                key: const ValueKey('new-employee-own-cash-safe'),
                contentPadding: EdgeInsets.zero,
                value: _ownCashSafe,
                onChanged: (v) => setState(() => _ownCashSafe = v),
                title: Text(
                  isAr ? 'خزنة نقد خاصة به' : 'A cash safe of his own',
                ),
              ),
              SwitchListTile(
                key: const ValueKey('new-employee-own-gold-safe'),
                contentPadding: EdgeInsets.zero,
                value: _ownGoldSafe,
                onChanged: (v) => setState(() => _ownGoldSafe = v),
                title: Text(
                  isAr ? 'خزنة ذهب خاصة به' : 'A gold safe of his own',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  key: const ValueKey('new-employee-create'),
                  onPressed: _busy ? null : _create,
                  child: Text(
                    isAr ? 'احفظ، التالي: الراتب' : 'Save, next: his salary',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panelStep(List<SalaryPanelPart> parts) {
    final isAr = _isAr;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EmployeeSalaryPanel(
          key: ValueKey('new-employee-panel-$_step'),
          service: _service,
          employeeId: _employeeId!,
          isAr: isAr,
          parts: parts,
          startChanging: _step == 1,
          unsaved: _salaryUnsaved,
          onSaved: () async {
            await _refresh();
            if (mounted && _step == 1) setState(() => _step = 2);
          },
        ),
        const SizedBox(height: AppSpace.md),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AppSpace.sm,
          children: [
            TextButton(
              key: const ValueKey('new-employee-later'),
              onPressed: () {
                _step = 2;
                _next();
              },
              child: Text(isAr ? 'لاحقًا، افتح صفحته' : 'Later: open his page'),
            ),
            FilledButton(
              key: const ValueKey('new-employee-next'),
              onPressed: _next,
              child: Text(
                _step == 1
                    ? (isAr ? 'التالي: الصرف' : 'Next: his payment')
                    : (isAr ? 'تم: افتح صفحته' : 'Done: open his page'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// What his file says he still lacks for the run (services/employee_file).
  Widget _ready() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    final file = _file;
    final employee = file?['employee'] as Map<String, dynamic>? ?? const {};
    final salary = file?['salary'] as Map<String, dynamic>? ?? const {};
    final items = [
      (isAr ? 'الاسم' : 'His name', file != null),
      (isAr ? 'تاريخ التعيين' : 'His hire date', employee['hire_date'] != null),
      (isAr ? 'الراتب' : 'His salary', salary['structure'] != null),
      (
        isAr ? 'طريقة الصرف' : 'How he is paid',
        salary['payment_method'] != null,
      ),
    ];
    return Card(
      key: const ValueKey('new-employee-ready'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAr ? 'ليدخل مسير الشهر' : 'For the month\'s run',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              isAr
                  ? 'يُحفظ ما تُدخله عند كل خطوة'
                  : 'Each step is saved as it is left',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpace.sm),
            for (final (label, done) in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 20,
                      color: done
                          ? tones.ready.fg
                          : theme.colorScheme.outlineVariant,
                      semanticLabel: done ? (isAr ? 'تم' : 'done') : null,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Text(label),
                  ],
                ),
              ),
            const Divider(),
            Text(
              isAr
                  ? 'الهوية والعقد والوثائق تُكمَل من صفحته'
                  : 'His ID, contract and documents: from his page',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final step = switch (_step) {
      0 => _dataStep(),
      1 => _panelStep(const [SalaryPanelPart.salary]),
      _ => _panelStep(const [SalaryPanelPart.payment]),
    };
    return AppLeaveGuard(
      // before he is saved, his typed data; after, the step's unsaved
      controllers: const [],
      isDirty: () => _employeeId == null
          ? [
              _name,
              _jobTitle,
              _department,
              _hireDate,
              _nationalId,
              _phone,
            ].any((c) => c.text.trim().isNotEmpty)
          : _salaryUnsaved.value.isNotEmpty,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _savedName.isEmpty
                ? (isAr ? 'موظف جديد' : 'New employee')
                : '${isAr ? 'موظف جديد' : 'New employee'}: $_savedName',
          ),
        ),
        body: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 900;
            final main = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _steps(),
                const SizedBox(height: AppSpace.md),
                step,
              ],
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: main),
                            const SizedBox(width: AppSpace.lg),
                            SizedBox(width: 300, child: _ready()),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            main,
                            const SizedBox(height: AppSpace.md),
                            _ready(),
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
