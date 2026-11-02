import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/employee_model.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_leave_guard.dart';
import '../widgets/app_state_views.dart';
import '../widgets/employee_advances_panel.dart';
import '../widgets/employee_data_panel.dart';
import '../widgets/employee_overview.dart';
import '../widgets/employee_salary_panel.dart';
import '../widgets/user_avatar_widget.dart';
import 'employee_file_view.dart';
import 'users_screen.dart';
import '../widgets/goal_settings_tile.dart';

/// An employee's page, the whole screen (HR-UX ر2; the owner, 1 Nov 2026:
/// «اعتمد»): its head -- his photo, name, state, user, how complete his file
/// is, his actions -- and his file's parts, one at a time (the file's own
/// sections, services/employee_file; nothing reckoned here).
class _Part {
  const _Part(this.id, this.ar, this.en, this.sections, this.icon);
  final String id;
  final String ar;
  final String en;
  final Set<String> sections;
  final IconData icon;
}

const _parts = [
  _Part('overview', 'نظرة عامة', 'Overview', {
    'missing',
    'salary',
    'payroll',
    'advances',
    'bonuses',
    'custody',
  }, Icons.dashboard_outlined),
  _Part('data', 'البيانات', 'His data', <String>{}, Icons.badge_outlined),
  _Part('salary', 'الراتب', 'Salary', {'payroll'}, Icons.payments_outlined),
  _Part('leave', 'الإجازات', 'Leave', {'leave'}, Icons.beach_access_outlined),
  _Part('contract', 'العقد والوثائق', 'Contract & documents', {
    'contract',
    'documents',
  }, Icons.description_outlined),
  _Part(
    'money',
    'العهدة والحسابات',
    'Custody & accounts',
    {'bonuses', 'custody', 'accounts'},
    Icons.account_balance_wallet_outlined,
  ),
  _Part(
    'performance',
    'الأداء',
    'Performance',
    <String>{},
    Icons.emoji_events_outlined,
  ),
  _Part('access', 'السجل والدخول', 'Sign-in', {'access'}, Icons.key_outlined),
  _Part('end', 'إنهاء الخدمة', 'End of service', {'end'}, Icons.logout),
];

class EmployeePage extends StatefulWidget {
  const EmployeePage({
    super.key,
    required this.api,
    required this.employeeId,
    this.isArabic = true,
    this.service,
  });
  final ApiService api;
  final int employeeId;
  final bool isArabic;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<EmployeePage> createState() => _EmployeePageState();
}

class _EmployeePageState extends State<EmployeePage> {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  Map<String, dynamic>? _file;
  Object? _error;
  String _part = 'overview';
  int _version = 0;

  /// What a part's panel holds typed and not saved (HR-UX ط2): asked before
  /// the page or the part is left.
  final _salaryUnsaved = ValueNotifier<List<String>>(const []);
  final _advancesUnsaved = ValueNotifier<List<String>>(const []);
  final _dataUnsaved = ValueNotifier<List<String>>(const []);

  bool get _dirty =>
      _salaryUnsaved.value.isNotEmpty ||
      _advancesUnsaved.value.isNotEmpty ||
      _dataUnsaved.value.isNotEmpty;

  Future<void> _pick(String id) async {
    if (id == _part) return;
    if (_dirty && !await AppLeaveGuard.confirmLeave(context)) return;
    _salaryUnsaved.value = const [];
    _advancesUnsaved.value = const [];
    _dataUnsaved.value = const [];
    if (mounted) setState(() => _part = id);
  }

  @override
  void dispose() {
    _salaryUnsaved.dispose();
    _advancesUnsaved.dispose();
    _dataUnsaved.dispose();
    super.dispose();
  }

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final file = await _service.employeeFile(widget.employeeId);
      if (mounted) {
        setState(() {
          _file = file;
          _version++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic> get _employee =>
      _file?['employee'] as Map<String, dynamic>? ?? const {};

  Future<void> _toggle() async {
    try {
      final result = await widget.api.toggleEmployeeActive(widget.employeeId);
      await _load();
      if (!mounted) return;
      final closed = (result['users_closed'] as List? ?? const [])
          .cast<String>();
      if (closed.isNotEmpty) {
        AppFeedback.info(
          context,
          _isAr
              ? 'أُوقف دخول: ${closed.join('، ')}'
              : 'Sign-in stopped: ${closed.join(', ')}',
        );
      }
      if (result['warning'] case final String warning) {
        AppFeedback.warning(context, warning);
      }
    } catch (e) {
      if (mounted) AppFeedback.error(context, e.toString());
    }
  }

  Future<void> _users() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UsersScreen(api: widget.api, isArabic: _isAr),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final file = _file;
    Widget body;
    if (_error != null && file == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل الموظف' : 'Could not load',
        error: _error!,
        onRetry: _load,
      );
    } else if (file == null) {
      body = const AppLoadingView(summaryBlocks: 2, rows: 6);
    } else {
      final part = _parts.firstWhere((p) => p.id == _part);
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // the users' screen holds his sign-in: made, its password reset
          if (_part == 'access')
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: OutlinedButton.icon(
                  key: const ValueKey('employee-page-users'),
                  onPressed: _users,
                  icon: const Icon(Icons.manage_accounts_outlined),
                  label: Text(
                    isAr
                        ? 'حساب الدخول وكلمة المرور في «المستخدمون»'
                        : 'Sign-in and password in Users',
                  ),
                ),
              ),
            ),
          Expanded(
            child: _part == 'overview'
                ? EmployeeOverview(
                    key: ValueKey('overview-$_version'),
                    file: file,
                    isAr: isAr,
                    onGo: _pick,
                  )
                : _part == 'data'
                ? SingleChildScrollView(
                    child: EmployeeDataPanel(
                      key: ValueKey('data-$_version'),
                      api: widget.api,
                      employee: _employee,
                      isAr: isAr,
                      unsaved: _dataUnsaved,
                      onSaved: _load,
                      onGo: _pick,
                    ),
                  )
                : _part == 'performance'
                ? SingleChildScrollView(
                    child: GoalSettingsTile(
                      key: ValueKey('goal-$_version'),
                      employee: EmployeeModel.fromJson(_employee),
                      isArabic: isAr,
                      api: widget.api,
                      onSaved: (_) => _load(),
                    ),
                  )
                : EmployeeFileView(
                    key: ValueKey('file-$_part-$_version'),
                    api: widget.api,
                    employeeId: widget.employeeId,
                    isArabic: isAr,
                    service: _service,
                    only: part.sections,
                    leading: [
                      if (_part == 'salary')
                        EmployeeSalaryPanel(
                          service: _service,
                          employeeId: widget.employeeId,
                          isAr: isAr,
                          unsaved: _salaryUnsaved,
                          onSaved: _load,
                        ),
                      if (_part == 'money')
                        EmployeeAdvancesPanel(
                          service: _service,
                          employeeId: widget.employeeId,
                          isAr: isAr,
                          unsaved: _advancesUnsaved,
                          onSaved: _load,
                        ),
                    ],
                  ),
          ),
        ],
      );
      body = LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final nav = _Nav(
            parts: _parts,
            current: _part,
            isAr: isAr,
            vertical: wide,
            onPick: _pick,
          );
          return Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Head(
                  file: file,
                  isAr: isAr,
                  api: widget.api,
                  employeeId: widget.employeeId,
                  onEdit: () => _pick('data'),
                  onToggle: _toggle,
                  onPhoto: _load,
                ),
                const SizedBox(height: AppSpace.md),
                if (!wide) ...[nav, const SizedBox(height: AppSpace.sm)],
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 230, child: nav),
                            const SizedBox(width: AppSpace.lg),
                            Expanded(child: content),
                          ],
                        )
                      : content,
                ),
              ],
            ),
          );
        },
      );
    }
    return AppLeaveGuard(
      controllers: const [],
      isDirty: () => _dirty,
      // board 2: no bar of its own -- the way back above his head
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // board 2: the way back above his head, whatever his file's state
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpace.sm,
                  top: AppSpace.sm,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('employee-page-back'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const BackButtonIcon(),
                    label: Text(
                      _isAr ? 'الموارد البشرية · الموظفون' : 'HR · Employees',
                    ),
                  ),
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head({
    required this.file,
    required this.isAr,
    required this.api,
    required this.employeeId,
    required this.onEdit,
    required this.onToggle,
    required this.onPhoto,
  });
  final Map<String, dynamic> file;
  final bool isAr;
  final ApiService api;
  final int employeeId;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onPhoto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final employee = file['employee'] as Map<String, dynamic>? ?? const {};
    final active = employee['is_active'] == true;
    final complete = file['completeness'] as Map<String, dynamic>? ?? const {};
    final done = (complete['done'] as num?) ?? 0;
    final of = (complete['of'] as num?) ?? 1;
    final missing = (file['missing'] as List? ?? const []).cast<String>();
    final users = (file['users'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final state = active ? tones.ready : tones.blocked;
    return Card(
      key: const ValueKey('employee-page-head'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Wrap(
          spacing: AppSpace.xl,
          runSpacing: AppSpace.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            UserAvatarWidget(
              displayName: '${employee['name'] ?? ''}',
              photoBase64: employee['photo'] as String?,
              radius: 36,
              editable: true,
              onUpload: (base64) async {
                await api.updateEmployeePhoto(employeeId, base64);
                onPhoto();
              },
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpace.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${employee['name'] ?? ''}',
                        style: theme.textTheme.headlineSmall,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: state.container,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          active
                              ? (isAr ? 'نشط' : 'Active')
                              : (isAr ? 'موقوف' : 'Stopped'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: state.onContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    [
                      if ((employee['job_title'] ?? '').toString().isNotEmpty)
                        '${employee['job_title']}',
                      ltrIsolate('${employee['employee_code'] ?? ''}'),
                      for (final u in users)
                        '${isAr ? 'الدخول' : 'sign-in'} ${ltrIsolate('${u['username']}')}${u['is_active'] == true ? '' : (isAr ? ' (موقوف)' : ' (stopped)')}',
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          key: const ValueKey('employee-page-completeness'),
                          value: of == 0 ? 1 : done / of,
                          strokeWidth: 6,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          color: tones.gold.fg,
                        ),
                      ),
                      Text(
                        ltrIsolate('$done/$of'),
                        style: theme.textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    missing.isEmpty
                        ? (isAr ? 'ملفه مكتمل' : 'His file is complete')
                        : '${isAr ? 'ناقص' : 'Missing'}: ${missing.join('، ')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: missing.isEmpty ? null : tones.warning.fg,
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: AppSpace.sm,
              children: [
                FilledButton.icon(
                  key: const ValueKey('employee-page-edit'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(isAr ? 'تعديل البيانات' : 'Edit'),
                ),
                OutlinedButton(
                  key: const ValueKey('employee-page-toggle'),
                  onPressed: onToggle,
                  child: Text(
                    active
                        ? (isAr ? 'إيقاف' : 'Stop')
                        : (isAr ? 'تفعيل' : 'Start'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.parts,
    required this.current,
    required this.isAr,
    required this.vertical,
    required this.onPick,
  });
  final List<_Part> parts;
  final String current;
  final bool isAr;
  final bool vertical;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    if (!vertical) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in parts)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: AppSpace.xs),
                child: ChoiceChip(
                  key: ValueKey('employee-part-${p.id}'),
                  label: Text(isAr ? p.ar : p.en),
                  selected: p.id == current,
                  onSelected: (_) => onPick(p.id),
                ),
              ),
          ],
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in parts)
              ListTile(
                key: ValueKey('employee-part-${p.id}'),
                dense: true,
                selected: p.id == current,
                selectedTileColor: tones.gold.container,
                selectedColor: tones.gold.onContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                leading: Icon(p.icon),
                title: Text(
                  isAr ? p.ar : p.en,
                  style: p.id == 'end'
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: tones.blocked.fg,
                        )
                      : null,
                ),
                onTap: () => onPick(p.id),
              ),
          ],
        ),
      ),
    );
  }
}
