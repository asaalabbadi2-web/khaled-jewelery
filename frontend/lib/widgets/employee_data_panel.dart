import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import 'app_feedback.dart';
import 'app_leave_guard.dart';
import 'date_field.dart';

/// His file's data edited where it is shown (HR-UX ط3; the owner, 2 Nov 2026,
/// «اعتمد»): three sections -- personal, work, safes --, each read until its
/// pencil opens it, each saved alone. What another document owns is not here
/// and says where it is (ADR-078): his salary, his stop, his leaving.
///
/// A hire date emptied is sent empty, so it is cleared -- the earlier dialog
/// dropped an empty field, and a date once set could not be taken back.
class EmployeeDataPanel extends StatefulWidget {
  const EmployeeDataPanel({
    super.key,
    required this.api,
    required this.employee,
    required this.isAr,
    this.unsaved,
    this.onSaved,
    this.onGo,
  });

  final ApiService api;

  /// His file's `employee`, as the server sent it.
  final Map<String, dynamic> employee;
  final bool isAr;
  final ValueNotifier<List<String>>? unsaved;
  final VoidCallback? onSaved;

  /// Another part of his page: 'salary', 'end'.
  final void Function(String part)? onGo;

  @override
  State<EmployeeDataPanel> createState() => _EmployeeDataPanelState();
}

class _EmployeeDataPanelState extends State<EmployeeDataPanel> {
  static const _sections = {
    'personal': ['name', 'national_id', 'phone', 'email', 'notes'],
    'work': ['job_title', 'department', 'hire_date'],
  };

  late final Map<String, TextEditingController> _fields = {
    for (final keys in _sections.values)
      for (final key in keys)
        key: TextEditingController(text: _held(key))..addListener(_typed),
  };
  int _cashSafe = 0; // 0: the main safe (none of his own)
  int _goldSafe = 0;
  List<SafeBoxModel> _cashSafes = const [];
  List<SafeBoxModel> _goldSafes = const [];
  String? _editing;
  bool _busy = false;
  final _form = GlobalKey<FormState>();

  bool get _isAr => widget.isAr;

  String _held(String key) => '${widget.employee[key] ?? ''}';

  @override
  void initState() {
    super.initState();
    _cashSafe = (widget.employee['cash_safe_box_id'] as int?) ?? 0;
    _goldSafe = (widget.employee['gold_safe_box_id'] as int?) ?? 0;
    _loadSafes();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSafes() async {
    try {
      final cash = await widget.api.getSafeBoxes(
        safeType: 'cash',
        isActive: true,
      );
      final gold = await widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
      );
      if (mounted) {
        setState(() {
          _cashSafes = cash.where((s) => (s.id ?? 0) > 0).toList();
          _goldSafes = gold.where((s) => (s.id ?? 0) > 0).toList();
        });
      }
    } catch (_) {
      // the safes read only by their numbers until they load; the rest stands
    }
  }

  bool get _dirty {
    final open = _editing;
    if (open == null) return false;
    if (open == 'safes') {
      return _cashSafe !=
              ((widget.employee['cash_safe_box_id'] as int?) ?? 0) ||
          _goldSafe != ((widget.employee['gold_safe_box_id'] as int?) ?? 0);
    }
    return _sections[open]!.any(
      (k) => _fields[k]!.text.trim() != _held(k).trim(),
    );
  }

  void _typed() {
    final told = widget.unsaved;
    final unsaved = _dirty
        ? [_isAr ? 'بيانات الموظف' : 'his data']
        : const <String>[];
    if (told != null && told.value.length != unsaved.length) {
      told.value = unsaved;
    }
    if (mounted) setState(() {});
  }

  Future<void> _open(String section) async {
    if (_dirty && !await AppLeaveGuard.confirmLeave(context)) return;
    _reset();
    setState(() => _editing = section);
  }

  void _reset() {
    for (final e in _fields.entries) {
      e.value.text = _held(e.key);
    }
    _cashSafe = (widget.employee['cash_safe_box_id'] as int?) ?? 0;
    _goldSafe = (widget.employee['gold_safe_box_id'] as int?) ?? 0;
  }

  void _cancel() {
    _reset();
    setState(() => _editing = null);
    _typed();
  }

  Future<void> _save() async {
    final section = _editing!;
    if (!(_form.currentState?.validate() ?? true)) return;
    final payload = <String, dynamic>{
      if (section == 'safes') ...{
        'cash_safe_box_id': _cashSafe,
        'gold_safe_box_id': _goldSafe,
      } else
        for (final key in _sections[section]!)
          key: _fields[key]!.text.trim().isEmpty
              ? null
              : _fields[key]!.text.trim(),
    };
    setState(() => _busy = true);
    try {
      await widget.api.updateEmployee(widget.employee['id'] as int, payload);
      if (!mounted) return;
      setState(() => _editing = null);
      widget.unsaved?.value = const [];
      AppFeedback.success(context, _isAr ? 'حُفظ' : 'Saved');
      widget.onSaved?.call();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _label(String key) => switch (key) {
    'name' => _isAr ? 'الاسم الكامل' : 'Full name',
    'national_id' => _isAr ? 'الهوية / الإقامة' : 'National ID / Iqama',
    'phone' => _isAr ? 'الجوال' : 'Mobile',
    'email' => _isAr ? 'البريد' : 'Email',
    'notes' => _isAr ? 'ملاحظات' : 'Notes',
    'job_title' => _isAr ? 'المسمى الوظيفي' : 'Job title',
    'department' => _isAr ? 'القسم' : 'Department',
    'hire_date' => _isAr ? 'تاريخ التعيين' : 'Hire date',
    _ => key,
  };

  String _safeName(int id, List<SafeBoxModel> safes) => id == 0
      ? (_isAr ? 'الخزنة الرئيسية' : 'The main safe')
      : safes.where((s) => s.id == id).map((s) => s.name).firstOrNull ??
            ltrIsolate('#$id');

  Widget _section(
    String id,
    String title,
    List<Widget> read,
    List<Widget> edit,
  ) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final open = _editing == id;
    return Card(
      key: ValueKey('data-$id'),
      shape: open
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: BorderSide(color: tones.gold.fg, width: 2),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                if (!open)
                  IconButton(
                    key: ValueKey('data-edit-$id'),
                    tooltip: _isAr ? 'تعديل $title' : 'Edit $title',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _busy ? null : () => _open(id),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            if (!open)
              ...read
            else
              Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ...edit,
                    const SizedBox(height: AppSpace.md),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: AppSpace.sm,
                      children: [
                        OutlinedButton(
                          key: const ValueKey('data-cancel'),
                          onPressed: _busy ? null : _cancel,
                          child: Text(_isAr ? 'إلغاء' : 'Cancel'),
                        ),
                        FilledButton(
                          key: const ValueKey('data-save'),
                          onPressed: _busy || !_dirty ? null : _save,
                          child: Text(_isAr ? 'حفظ' : 'Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Widget? action}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: action ?? Text(value.isEmpty ? '—' : value)),
        ],
      ),
    );
  }

  Widget _readRows(String section) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final key in _sections[section]!)
        _row(
          _label(key),
          key == 'hire_date' || key == 'phone' || key == 'national_id'
              ? ltrIsolate(_held(key))
              : _held(key),
          action:
              _held(key).isEmpty && (key == 'national_id' || key == 'hire_date')
              ? Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: ValueKey('data-add-$key'),
                    onPressed: () => _open(section),
                    child: Text('+ ${_isAr ? 'أضف' : 'Add'} ${_label(key)}'),
                  ),
                )
              : null,
        ),
    ],
  );

  Widget _text(String key, {bool required = false, int lines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: TextFormField(
      key: ValueKey('data-field-$key'),
      controller: _fields[key],
      maxLines: lines,
      textDirection: key == 'phone' || key == 'email' || key == 'national_id'
          ? TextDirection.ltr
          : null,
      decoration: InputDecoration(labelText: _label(key)),
      validator: required
          ? (v) => (v ?? '').trim().isEmpty
                ? (_isAr ? 'الاسم مطلوب' : 'The name is required')
                : null
          : null,
    ),
  );

  Widget _safe(
    String label,
    String key,
    int value,
    List<SafeBoxModel> safes,
    ValueChanged<int> pick,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: DropdownButtonFormField<int>(
      key: ValueKey(key),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(
          value: 0,
          child: Text(_isAr ? 'الخزنة الرئيسية' : 'The main safe'),
        ),
        for (final s in safes)
          DropdownMenuItem(value: s.id!, child: Text(s.name)),
        if (value != 0 && !safes.any((s) => s.id == value))
          DropdownMenuItem(value: value, child: Text(ltrIsolate('#$value'))),
      ],
      onChanged: (v) {
        pick(v ?? 0);
        _typed();
      },
    ),
  );

  Widget _notHere() {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isAr = _isAr;
    return Card(
      key: const ValueKey('data-not-here'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'ليس هنا' : 'Not here',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            _row(
              isAr ? 'الراتب وتغييره' : 'His salary',
              '',
              action: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('data-go-salary'),
                  onPressed: () => widget.onGo?.call('salary'),
                  child: Text(isAr ? 'قسم الراتب' : 'The salary part'),
                ),
              ),
            ),
            _row(
              isAr ? 'الإيقاف والتفعيل' : 'Stopping him',
              isAr ? 'زر «إيقاف» في رأس الصفحة' : 'The head\'s «Stop»',
            ),
            _row(
              isAr ? 'تاريخ ترك العمل' : 'His leaving date',
              '',
              action: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const ValueKey('data-go-end'),
                  onPressed: () => widget.onGo?.call('end'),
                  style: TextButton.styleFrom(
                    foregroundColor: tones.blocked.fg,
                  ),
                  child: Text(
                    isAr
                        ? 'إنهاء الخدمة، مع تسويته'
                        : 'End of service, settled',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final cards = [
      _section(
        'personal',
        isAr ? 'البيانات الشخصية' : 'Personal',
        [_readRows('personal')],
        [
          _text('name', required: true),
          _text('national_id'),
          _text('phone'),
          _text('email'),
          _text('notes', lines: 3),
        ],
      ),
      _section(
        'work',
        isAr ? 'العمل' : 'Work',
        [_readRows('work')],
        [
          _text('job_title'),
          _text('department'),
          DateField(
            key: const ValueKey('data-field-hire_date'),
            controller: _fields['hire_date']!,
            label: _label('hire_date'),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            isAr
                ? 'منه يُحسب رصيد الإجازة ومخصص نهاية الخدمة. يُفرَّغ إن كُتب خطأً.'
                : 'His leave balance and end-of-service provision run from it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      _section(
        'safes',
        isAr ? 'الخزائن' : 'Safes',
        [
          _row(
            isAr ? 'خزنة النقد' : 'Cash safe',
            _safeName(_cashSafe, _cashSafes),
          ),
          _row(
            isAr ? 'خزنة الذهب' : 'Gold safe',
            _safeName(_goldSafe, _goldSafes),
          ),
        ],
        [
          _safe(
            isAr ? 'خزنة النقد' : 'Cash safe',
            'data-cash-safe',
            _cashSafe,
            _cashSafes,
            (v) => _cashSafe = v,
          ),
          _safe(
            isAr ? 'خزنة الذهب' : 'Gold safe',
            'data-gold-safe',
            _goldSafe,
            _goldSafes,
            (v) => _goldSafe = v,
          ),
        ],
      ),
      _notHere(),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final two = box.maxWidth >= 760;
        if (!two) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cards,
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [cards[0], cards[2]],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [cards[1], cards[3]],
              ),
            ),
          ],
        );
      },
    );
  }
}
