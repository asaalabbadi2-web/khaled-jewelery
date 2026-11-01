import 'package:flutter/material.dart';

import '../api_service.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_bar_tab_bar.dart';
import '../widgets/app_state_views.dart';
import 'attendance_screen.dart';
import 'contribution_schemes_screen.dart';
import 'employee_file_view.dart';
import 'employee_page.dart';
import 'new_employee_screen.dart';
import 'payroll_policy_screen.dart';
import 'payroll_runs_screen.dart';
import 'payroll_report_screen.dart';

/// «الموارد البشرية», one screen with four tabs (HR-UX ر1; the owner, 1 Nov
/// 2026: «اعتمد»): الموظفون، الرواتب، المتابعة، الإعدادات. Each figure is the
/// server's (`/hr/overview`), nothing reckoned here. The screens it replaces
/// stay reachable from it until their parts move in (the inventory:
/// docs/plans/hr-ux-redesign-2026-11.md).
enum HrTab { employees, payroll, followup, settings }

class HrHubScreen extends StatefulWidget {
  const HrHubScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.initialTab = HrTab.employees,
    this.service,
  });
  final ApiService api;
  final bool isArabic;
  final HrTab initialTab;

  /// For tests: a service that answers without a server.
  final PayrollService? service;

  @override
  State<HrHubScreen> createState() => _HrHubScreenState();
}

class _HrHubScreenState extends State<HrHubScreen>
    with SingleTickerProviderStateMixin {
  late final PayrollService _service =
      widget.service ?? PayrollService(widget.api);
  late final TabController _tabs = TabController(
    length: HrTab.values.length,
    vsync: this,
    initialIndex: widget.initialTab.index,
  );
  Map<String, dynamic>? _overview;
  Object? _error;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final overview = await _service.hrOverview();
      if (mounted) setState(() => _overview = overview);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  /// HR-UX ر2: his page, the whole screen.
  Future<void> _openEmployee(int id, String name) => _push(
    EmployeePage(
      api: widget.api,
      employeeId: id,
      isArabic: _isAr,
      service: _service,
    ),
  );

  /// HR-UX ط3: three steps -- his data, his salary, his payment -- then his
  /// page.
  Future<void> _newEmployee() => _push(
    NewEmployeeScreen(api: widget.api, isArabic: _isAr, service: _service),
  );

  int get _followupCount => ((_overview?['followup'] as List?) ?? const [])
      .where((i) => (i as Map)['tone'] != 'info')
      .length;

  @override
  Widget build(BuildContext context) {
    final isAr = _isAr;
    final overview = _overview;
    Widget body;
    if (_error != null && overview == null) {
      body = AppErrorView(
        title: isAr ? 'تعذّر تحميل الموارد البشرية' : 'Could not load HR',
        error: _error!,
        onRetry: _load,
      );
    } else if (overview == null) {
      body = const AppLoadingView(summaryBlocks: 4, rows: 6);
    } else {
      body = TabBarView(
        controller: _tabs,
        children: [
          _EmployeesTab(
            overview: overview,
            isAr: isAr,
            onOpen: _openEmployee,
            onRefresh: _load,
          ),
          _PayrollTab(
            api: widget.api,
            service: _service,
            overview: overview,
            isAr: isAr,
            onLegacy: () =>
                _push(PayrollReportScreen(api: widget.api, isArabic: isAr)),
          ),
          _FollowupTab(
            overview: overview,
            isAr: isAr,
            onRefresh: _load,
            onOpenEmployee: _openEmployee,
            onTab: (tab) => _tabs.animateTo(tab.index),
          ),
          _SettingsTab(
            isAr: isAr,
            service: _service,
            onOpen: _push,
            api: widget.api,
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'الموارد البشرية' : 'Human resources'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: isAr ? 'تحديث' : 'Refresh',
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpace.sm),
            child: FilledButton.icon(
              key: const ValueKey('hr-new-employee'),
              onPressed: _newEmployee,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(isAr ? 'موظف جديد' : 'New employee'),
            ),
          ),
        ],
        // the bar's own tabs: its text colour, not the scheme's gold on gold
        bottom: AppBarTabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            Tab(
              key: const ValueKey('hr-tab-employees'),
              text: isAr ? 'الموظفون' : 'Employees',
            ),
            Tab(
              key: const ValueKey('hr-tab-payroll'),
              text: isAr ? 'الرواتب' : 'Payroll',
            ),
            Tab(
              key: const ValueKey('hr-tab-followup'),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(isAr ? 'المتابعة' : 'Follow-up'),
                  if (_followupCount > 0) ...[
                    const SizedBox(width: AppSpace.xs),
                    _Count(_followupCount),
                  ],
                ],
              ),
            ),
            Tab(
              key: const ValueKey('hr-tab-settings'),
              text: isAr ? 'الإعدادات' : 'Settings',
            ),
          ],
        ),
      ),
      body: body,
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    final tone = AppSemanticColors.of(context).warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 1),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        ltrIsolate('$count'),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: tone.onContainer),
      ),
    );
  }
}

String _money(Object? v) => ltrIsolate(formatAmount((v as num?) ?? 0));

// ── الموظفون ────────────────────────────────────────────────────────────────

class _EmployeesTab extends StatefulWidget {
  const _EmployeesTab({
    required this.overview,
    required this.isAr,
    required this.onOpen,
    required this.onRefresh,
  });
  final Map<String, dynamic> overview;
  final bool isAr;
  final Future<void> Function(int id, String name) onOpen;
  final Future<void> Function() onRefresh;

  @override
  State<_EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends State<_EmployeesTab> {
  String _query = '';
  bool? _active = true;

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final kpis = widget.overview['kpis'] as Map<String, dynamic>? ?? const {};
    final cost = kpis['month_cost'] as Map<String, dynamic>?;
    final rows = ((widget.overview['employees'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((r) => _active == null || r['is_active'] == _active)
        .where(
          (r) =>
              _query.isEmpty ||
              '${r['name']} ${r['employee_code']}'.contains(_query),
        )
        .toList();
    Widget kpi(String label, String value, String sub, {SemanticTone? tone}) =>
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: tone?.container ?? theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tone?.onContainer,
                ),
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: tone?.onContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                sub,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tone?.onContainer,
                ),
              ),
            ],
          ),
        );
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 900 ? 4 : 2;
              final cards = [
                kpi(
                  isAr ? 'الموظفون النشطون' : 'Active',
                  ltrIsolate('${kpis['active'] ?? 0}'),
                  isAr
                      ? 'و${ltrIsolate('${kpis['stopped'] ?? 0}')} موقوفون'
                      : '${kpis['stopped'] ?? 0} stopped',
                ),
                kpi(
                  isAr ? 'تكلفة رواتب الشهر' : 'Month payroll',
                  cost == null ? '—' : _money(cost['net']),
                  cost == null
                      ? (isAr ? 'لا مسير بعد' : 'No run yet')
                      : '${ltrIsolate('${cost['month']}/${cost['year']}')} · ${cost['paid'] == true ? (isAr ? 'مصروف' : 'paid') : (isAr ? 'معتمد' : 'approved')}',
                ),
                kpi(
                  isAr ? 'وثائق تنتهي قريبًا' : 'Documents ending',
                  ltrIsolate('${kpis['expiring'] ?? 0}'),
                  isAr ? 'بأيام التنبيه المضبوطة' : 'by the alert days set',
                ),
                kpi(
                  isAr ? 'بياناتهم ناقصة' : 'Incomplete',
                  ltrIsolate('${kpis['incomplete'] ?? 0}'),
                  isAr ? 'من النشطين' : 'of the active',
                  tone: ((kpis['incomplete'] as num?) ?? 0) > 0
                      ? tones.warning
                      : null,
                ),
              ];
              final width =
                  (box.maxWidth - AppSpace.md * (columns - 1)) / columns;
              // by its width alone: its height its content's (a grid's
              // fixed ratio overflowed at a phone's width)
              return Wrap(
                spacing: AppSpace.md,
                runSpacing: AppSpace.md,
                children: [
                  for (final card in cards) SizedBox(width: width, child: card),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpace.lg),
          Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 360,
                child: TextField(
                  key: const ValueKey('hr-search'),
                  onChanged: (v) => setState(() => _query = v.trim()),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: isAr
                        ? 'ابحث باسم الموظف أو رقمه'
                        : 'Search by name or number',
                  ),
                ),
              ),
              SegmentedButton<bool?>(
                key: const ValueKey('hr-active-filter'),
                segments: [
                  ButtonSegment(
                    value: true,
                    label: Text(isAr ? 'النشطون' : 'Active'),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(isAr ? 'الموقوفون' : 'Stopped'),
                  ),
                  ButtonSegment(
                    value: null,
                    label: Text(isAr ? 'الكل' : 'All'),
                  ),
                ],
                selected: {_active},
                onSelectionChanged: (s) => setState(() => _active = s.first),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (rows.isEmpty)
            AppEmptyView(
              title: isAr ? 'لا موظفين بهذا البحث' : 'No employees match',
            )
          else
            for (final r in rows)
              _EmployeeRow(
                row: r,
                isAr: isAr,
                onTap: () => widget.onOpen(r['id'] as int, '${r['name']}'),
              ),
        ],
      ),
    );
  }
}

class _EmployeeRow extends StatelessWidget {
  const _EmployeeRow({
    required this.row,
    required this.isAr,
    required this.onTap,
  });
  final Map<String, dynamic> row;
  final bool isAr;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final last = row['last_payroll'] as Map<String, dynamic>?;
    final missing = (row['missing'] as List? ?? const []).length;
    final custody = row['custody'] as Map<String, dynamic>? ?? const {};
    final gold =
        (custody['gold'] as Map<String, dynamic>?)?['balances']
            as Map<String, dynamic>? ??
        const {};
    Widget chip(String text, SemanticTone tone) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: tone.onContainer),
      ),
    );
    Widget figure(String label, String value) => SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    final initial = '${row['name']}'.isEmpty ? '?' : '${row['name']}'[0];
    return Card(
      key: ValueKey('hr-employee-${row['id']}'),
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: tones.gold.container,
                      foregroundColor: tones.gold.onContainer,
                      child: Text(initial),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${row['name']}',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            [
                              if ((row['job_title'] ?? '')
                                  .toString()
                                  .isNotEmpty)
                                '${row['job_title']}',
                              ltrIsolate('${row['employee_code']}'),
                            ].join(' · '),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              figure(
                isAr ? 'الراتب الإجمالي' : 'Gross',
                row['gross'] == null
                    ? (isAr ? 'لا هيكل' : 'no structure')
                    : _money(row['gross']),
              ),
              figure(
                isAr ? 'آخر راتب' : 'Last payroll',
                last == null
                    ? '—'
                    : '${ltrIsolate('${last['month']}/${last['year']}')} · ${_money(last['net_salary'])}',
              ),
              figure(isAr ? 'السلف' : 'Advances', _money(row['advance'])),
              figure(
                isAr ? 'العهدة' : 'Custody',
                gold.isEmpty
                    ? '—'
                    : gold.entries
                          .map(
                            (e) =>
                                '${ltrIsolate(formatGrams(e.value as num))} ${e.key}',
                          )
                          .join(' · '),
              ),
              Wrap(
                spacing: AppSpace.xs,
                runSpacing: AppSpace.xs,
                children: [
                  if (row['is_active'] != true)
                    chip(isAr ? 'موقوف' : 'stopped', tones.blocked),
                  if (missing > 0)
                    chip(
                      isAr
                          ? '${ltrIsolate('$missing')} بيانات ناقصة'
                          : '$missing missing',
                      tones.warning,
                    ),
                  if (((row['salary_owed'] as num?) ?? 0) > 0)
                    chip(
                      '${isAr ? 'راتب مستحق' : 'salary owed'} ${_money(row['salary_owed'])}',
                      tones.info,
                    ),
                  if (((row['bonuses_owed'] as num?) ?? 0) > 0)
                    chip(
                      '${isAr ? 'مكافآت' : 'bonuses'} ${_money(row['bonuses_owed'])}',
                      tones.ready,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── الرواتب ─────────────────────────────────────────────────────────────────

class _PayrollTab extends StatelessWidget {
  const _PayrollTab({
    required this.api,
    required this.service,
    required this.overview,
    required this.isAr,
    required this.onLegacy,
  });
  final ApiService api;
  final PayrollService service;
  final Map<String, dynamic> overview;
  final bool isAr;
  final VoidCallback onLegacy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final followup = ((overview['followup'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final runItem = followup
        .where((i) => i['kind'] == 'run_missing' || i['kind'] == 'run_open')
        .firstOrNull;
    final cost =
        (overview['kpis'] as Map<String, dynamic>?)?['month_cost']
            as Map<String, dynamic>?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.lg,
            0,
          ),
          child: Card(
            key: const ValueKey('hr-payroll-month'),
            color: runItem == null ? null : tones.warning.container,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Wrap(
                spacing: AppSpace.lg,
                runSpacing: AppSpace.sm,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        runItem == null
                            ? (isAr ? 'لا مسير ينتظر' : 'No run waiting')
                            : runItem['kind'] == 'run_missing'
                            ? (isAr
                                  ? 'مسير ${ltrIsolate('${runItem['month']}/${runItem['year']}')} لم يُنشأ'
                                  : 'Run ${runItem['month']}/${runItem['year']} not drafted')
                            : (isAr
                                  ? 'مسير ${ltrIsolate('${runItem['month']}/${runItem['year']}')} لم يُصرف بعد'
                                  : 'Run ${runItem['month']}/${runItem['year']} not paid'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: runItem == null
                              ? null
                              : tones.warning.onContainer,
                        ),
                      ),
                      if (cost != null)
                        Text(
                          isAr
                              ? 'آخر شهر: ${ltrIsolate('${cost['month']}/${cost['year']}')} · ${_money(cost['net'])}'
                              : 'Last month ${cost['month']}/${cost['year']}: ${_money(cost['net'])}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: runItem == null
                                ? null
                                : tones.warning.onContainer,
                          ),
                        ),
                    ],
                  ),
                  // HR-UX ط5: the months before the runs, read by month --
                  // their screen of entries keyed one by one is gone
                  TextButton.icon(
                    key: const ValueKey('hr-payroll-legacy'),
                    onPressed: onLegacy,
                    icon: const Icon(Icons.history),
                    label: Text(
                      isAr ? 'تقرير الرواتب الشهري' : 'Monthly payroll report',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: PayrollRunsScreen(
            api: api,
            isArabic: isAr,
            embedded: true,
            service: service,
          ),
        ),
      ],
    );
  }
}

// ── المتابعة ────────────────────────────────────────────────────────────────

class _FollowupTab extends StatelessWidget {
  const _FollowupTab({
    required this.overview,
    required this.isAr,
    required this.onRefresh,
    required this.onOpenEmployee,
    required this.onTab,
  });
  final Map<String, dynamic> overview;
  final bool isAr;
  final Future<void> Function() onRefresh;
  final Future<void> Function(int id, String name) onOpenEmployee;
  final void Function(HrTab tab) onTab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final items = ((overview['followup'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    SemanticTone toneOf(Map<String, dynamic> i) => switch (i['tone']) {
      'blocked' => tones.blocked,
      'warning' => tones.warning,
      _ => tones.info,
    };
    Widget item(
      Map<String, dynamic> i,
      String title,
      String body, {
      Widget? action,
    }) {
      final tone = toneOf(i);
      return Card(
        key: ValueKey('hr-followup-${i['kind']}'),
        margin: const EdgeInsets.only(bottom: AppSpace.sm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.circle, size: 12, color: tone.fg),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: AppSpace.xs),
                    Text(body, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
              ?action,
            ],
          ),
        ),
      );
    }

    final cards = <Widget>[];
    for (final i in items) {
      switch (i['kind']) {
        case 'run_missing':
          cards.add(
            item(
              i,
              isAr
                  ? 'مسير ${ltrIsolate('${i['month']}/${i['year']}')} لم يُنشأ'
                  : 'Run ${i['month']}/${i['year']} not drafted',
              isAr
                  ? 'يُنشأ من هياكل الرواتب في تبويب الرواتب'
                  : 'Draft it from the structures in Payroll',
              action: TextButton(
                onPressed: () => onTab(HrTab.payroll),
                child: Text(isAr ? 'إلى الرواتب' : 'Payroll'),
              ),
            ),
          );
        case 'run_open':
          cards.add(
            item(
              i,
              isAr
                  ? 'مسير ${ltrIsolate('${i['month']}/${i['year']}')} لم يُصرف'
                  : 'Run ${i['month']}/${i['year']} not paid',
              isAr ? 'حالته: ${i['status']}' : 'Status: ${i['status']}',
              action: TextButton(
                onPressed: () => onTab(HrTab.payroll),
                child: Text(isAr ? 'إلى الرواتب' : 'Payroll'),
              ),
            ),
          );
        case 'missing_data':
          final employees = (i['employees'] as List)
              .cast<Map<String, dynamic>>();
          cards.add(
            item(
              i,
              isAr
                  ? 'بيانات ناقصة لـ ${ltrIsolate('${employees.length}')} موظفين'
                  : 'Incomplete data: ${employees.length}',
              isAr
                  ? 'بدونها لا رصيد إجازة ولا مخصص نهاية خدمة'
                  : 'Without it no leave balance nor end-of-service provision',
            ),
          );
          for (final e in employees) {
            cards.add(
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: AppSpace.xl,
                  bottom: AppSpace.xs,
                ),
                child: ActionChip(
                  label: Text(
                    '${e['name']}: ${(e['missing'] as List).join('، ')}',
                  ),
                  onPressed: () =>
                      onOpenEmployee(e['id'] as int, '${e['name']}'),
                ),
              ),
            );
          }
        case 'policy_unset':
          cards.add(
            item(
              i,
              isAr ? 'أرقام لم تُضبط بعد' : 'Figures not set',
              isAr
                  ? 'أرقام نهاية الخدمة ونسب الاستقالة وأيام تنبيه العقود. لا يُحسب جزؤها دونها'
                  : 'End of service, resignation shares, contract alert days',
              action: TextButton(
                onPressed: () => onTab(HrTab.settings),
                child: Text(isAr ? 'إلى الإعدادات' : 'Settings'),
              ),
            ),
          );
        case 'expiring':
          cards.add(
            item(
              i,
              '${i['label']} — ${i['employee']}',
              ((i['days_left'] as num?) ?? 0) < 0
                  ? (isAr
                        ? 'انتهت في ${ltrIsolate('${i['ends_on']}')}'
                        : 'Ended ${i['ends_on']}')
                  : (isAr
                        ? 'تنتهي في ${ltrIsolate('${i['ends_on']}')} — بعد ${ltrIsolate('${i['days_left']}')} يومًا'
                        : 'Ends ${i['ends_on']}'),
              action: TextButton(
                onPressed: () =>
                    onOpenEmployee(i['employee_id'] as int, '${i['employee']}'),
                child: Text(isAr ? 'ملفه' : 'File'),
              ),
            ),
          );
        case 'leave':
          cards.add(
            item(
              i,
              isAr ? 'الإجازات' : 'Leave',
              isAr
                  ? 'طلبات قائمة: ${ltrIsolate('${i['requests']}')} · في إجازة اليوم: ${ltrIsolate('${i['on_leave']}')}'
                  : 'Requests ${i['requests']} · on leave ${i['on_leave']}',
            ),
          );
        case 'termination_unpaid':
          cards.add(
            item(
              i,
              isAr
                  ? 'تسوية نهاية خدمة لم تُصرف — ${i['employee']}'
                  : 'Settlement unpaid — ${i['employee']}',
              isAr
                  ? 'آخر يوم ${ltrIsolate('${i['last_day']}')}'
                  : 'Last day ${i['last_day']}',
              action: TextButton(
                onPressed: () =>
                    onOpenEmployee(i['employee_id'] as int, '${i['employee']}'),
                child: Text(isAr ? 'ملفه' : 'File'),
              ),
            ),
          );
        case 'custody':
          final employees = (i['employees'] as List)
              .cast<Map<String, dynamic>>();
          cards.add(
            item(
              i,
              isAr
                  ? 'عهدة قائمة لدى ${ltrIsolate('${employees.length}')}'
                  : 'Custody open: ${employees.length}',
              employees.map((e) => '${e['name']}').join(' · '),
            ),
          );
      }
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: cards.isEmpty
            ? [
                AppEmptyView(
                  title: isAr ? 'لا شيء يحتاج إجراءً' : 'Nothing needs doing',
                ),
              ]
            : cards,
      ),
    );
  }
}

// ── الإعدادات ───────────────────────────────────────────────────────────────

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({
    required this.isAr,
    required this.service,
    required this.onOpen,
    required this.api,
  });
  final bool isAr;
  final PayrollService service;
  final Future<void> Function(Widget screen) onOpen;
  final ApiService api;

  @override
  Widget build(BuildContext context) {
    Widget tile(
      IconData icon,
      String title,
      String sub,
      VoidCallback onTap,
      String key,
    ) => Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: ListTile(
        key: ValueKey(key),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_left),
        onTap: onTap,
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        tile(
          Icons.tune,
          isAr ? 'سياسة الرواتب' : 'Payroll policy',
          isAr
              ? 'نسب الهيكل، والسلف، والحضور، ونهاية الخدمة، والاستقالة، والعقود'
              : 'Every payroll figure',
          () => onOpen(PayrollPolicyScreen(api: api, isArabic: isAr)),
          'hr-settings-policy',
        ),
        tile(
          Icons.health_and_safety_outlined,
          isAr ? 'خطط الاشتراك (التأمينات)' : 'Contribution schemes',
          isAr ? 'النسب المؤرّخة على أوعيتها' : 'Dated rates',
          () => onOpen(ContributionSchemesScreen(api: api, isArabic: isAr)),
          'hr-settings-schemes',
        ),
        tile(
          Icons.beach_access_outlined,
          isAr ? 'أنواع الإجازات وأيامها' : 'Leave kinds',
          isAr ? 'الفارغ لا يُفحص رصيده' : 'Empty: no balance held',
          () => showDialog<void>(
            context: context,
            builder: (_) => LeaveTypesDialog(service: service, isAr: isAr),
          ),
          'hr-settings-leave',
        ),
        tile(
          Icons.badge_outlined,
          isAr ? 'أنواع الوثائق وأيام التنبيه' : 'Document kinds',
          isAr ? 'الفارغ لا تنبيه له' : 'Empty: no alert',
          () => showDialog<void>(
            context: context,
            builder: (_) => DocumentTypesDialog(service: service, isAr: isAr),
          ),
          'hr-settings-documents',
        ),
        tile(
          Icons.event_available,
          isAr ? 'الحضور والانصراف' : 'Attendance',
          isAr ? 'سجلات الحضور' : 'Attendance records',
          () => onOpen(AttendanceScreen(api: api, isArabic: isAr)),
          'hr-settings-attendance',
        ),
      ],
    );
  }
}
