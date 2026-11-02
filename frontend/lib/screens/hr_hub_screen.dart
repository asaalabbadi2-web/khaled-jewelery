import 'package:flutter/material.dart';

import '../api_service.dart';
import 'prepare_run_screen.dart';
import '../utils/month_names.dart';
import '../models/payroll_run_models.dart';
import '../services/payroll_service.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_tokens.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_state_views.dart';
import '../widgets/employee_overview.dart';
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
            onChanged: _load,
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
    // HR-UX ط6 (the owner, 2 Nov 2026: the approved board 1): the page's own
    // head -- its mark, its name and what it holds, «موظف جديد» -- and its
    // four tabs as one bar of pills above them, the chosen one gold.
    final tabs = [
      (HrTab.employees, isAr ? 'الموظفون' : 'Employees', 'hr-tab-employees'),
      (HrTab.payroll, isAr ? 'الرواتب' : 'Payroll', 'hr-tab-payroll'),
      (HrTab.followup, isAr ? 'المتابعة' : 'Follow-up', 'hr-tab-followup'),
      (HrTab.settings, isAr ? 'الإعدادات' : 'Settings', 'hr-tab-settings'),
    ];
    return Scaffold(
      // the screen's whole width (the owner, 2 Nov 2026: a cap left it small on
      // a wide screen)
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.lg,
            AppSpace.lg,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HubHead(
                isAr: isAr,
                onRefresh: _load,
                onNewEmployee: _newEmployee,
              ),
              const SizedBox(height: AppSpace.lg),
              _TabPills(
                controller: _tabs,
                tabs: tabs,
                followupCount: _followupCount,
              ),
              const SizedBox(height: AppSpace.sm),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

/// The page's head (board 1): its mark, its name, what it holds; refresh and
/// «موظف جديد»; the way back when it was opened over another screen.
class _HubHead extends StatelessWidget {
  const _HubHead({
    required this.isAr,
    required this.onRefresh,
    required this.onNewEmployee,
  });
  final bool isAr;
  final VoidCallback onRefresh;
  final VoidCallback onNewEmployee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final canPop = Navigator.of(context).canPop();
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.lg,
      runSpacing: AppSpace.md,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canPop)
              IconButton(
                key: const ValueKey('hr-back'),
                tooltip: isAr ? 'رجوع' : 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const BackButtonIcon(),
              ),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tones.gold.fg,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Icon(
                Icons.groups_2_outlined,
                color: theme.colorScheme.onPrimary,
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isAr ? 'الموارد البشرية' : 'Human resources',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    isAr
                        ? 'الموظفون، والرواتب، وما يحتاج إجراءً، والإعدادات — في مكان واحد'
                        : 'Employees, payroll, what needs doing, settings -- in one place',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: isAr ? 'تحديث' : 'Refresh',
            ),
            const SizedBox(width: AppSpace.xs),
            FilledButton.icon(
              key: const ValueKey('hr-new-employee'),
              onPressed: onNewEmployee,
              icon: const Icon(Icons.add),
              label: Text(isAr ? 'موظف جديد' : 'New employee'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The four tabs as one bar of pills (board 1), the chosen one gold; scrolls
/// on a narrow screen. «المتابعة» carries what needs doing, counted.
class _TabPills extends StatelessWidget {
  const _TabPills({
    required this.controller,
    required this.tabs,
    required this.followupCount,
  });
  final TabController controller;
  final List<(HrTab, String, String)> tabs;
  final int followupCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpace.xs),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (tab, label, key) in tabs)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpace.xs),
                  child: Semantics(
                    selected: controller.index == tab.index,
                    button: true,
                    child: InkWell(
                      key: ValueKey(key),
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      onTap: () => controller.animateTo(tab.index),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.xl,
                          vertical: AppSpace.sm,
                        ),
                        decoration: BoxDecoration(
                          color: controller.index == tab.index
                              ? tones.gold.container
                              : null,
                          borderRadius: BorderRadius.circular(
                            AppRadius.control,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: controller.index == tab.index
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                color: controller.index == tab.index
                                    ? tones.gold.onContainer
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (tab == HrTab.followup && followupCount > 0) ...[
                              const SizedBox(width: AppSpace.sm),
                              _Count(followupCount),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
                  // the number plain: an isolate after «و» set it before it
                  isAr
                      ? '${kpis['stopped'] ?? 0} موقوفون'
                      : '${kpis['stopped'] ?? 0} stopped',
                ),
                kpi(
                  isAr ? 'تكلفة رواتب الشهر' : 'Month payroll',
                  cost == null ? '—' : _money(cost['net']),
                  cost == null
                      ? (isAr ? 'لا مسير بعد' : 'No run yet')
                      : '${isAr ? 'مسير ${monthName(cost['month'] as int)}' : monthName(cost['month'] as int, isAr: false)} · ${cost['paid'] == true ? (isAr ? 'مصروف' : 'paid') : (isAr ? 'معتمد' : 'approved')}',
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
          // board 1: one card -- its search and its filter atop, the
          // employees under them: a table on a wide screen, cards on a phone
          Container(
            key: const ValueKey('hr-employees-list'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
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
                      Wrap(
                        key: const ValueKey('hr-active-filter'),
                        spacing: AppSpace.xs,
                        children: [
                          for (final (value, label) in [
                            (true, isAr ? 'النشطون' : 'Active'),
                            (false, isAr ? 'الموقوفون' : 'Stopped'),
                            (null, isAr ? 'الكل' : 'All'),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: _active == value,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _active = value),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: AppEmptyView(
                      title: isAr
                          ? 'لا موظفين بهذا البحث'
                          : 'No employees match',
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, box) => box.maxWidth >= 900
                        ? _EmployeesTable(
                            rows: rows,
                            isAr: isAr,
                            onOpen: (r) =>
                                widget.onOpen(r['id'] as int, '${r['name']}'),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(AppSpace.sm),
                            child: Column(
                              children: [
                                for (final r in rows)
                                  _EmployeeRow(
                                    row: r,
                                    isAr: isAr,
                                    onTap: () => widget.onOpen(
                                      r['id'] as int,
                                      '${r['name']}',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What a row of the employees says beyond its figures: stopped, missing,
/// salary owed, bonuses owed -- one place, the table's and the card's.
List<Widget> _needs(BuildContext context, Map<String, dynamic> row, bool isAr) {
  final theme = Theme.of(context);
  final tones = AppSemanticColors.of(context);
  final missing = (row['missing'] as List? ?? const []).length;
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
  return [
    if (row['is_active'] != true)
      chip(isAr ? 'موقوف' : 'stopped', tones.blocked),
    if (missing > 0)
      chip(
        isAr ? '${ltrIsolate('$missing')} بيانات ناقصة' : '$missing missing',
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
  ];
}

String _custody(Map<String, dynamic> row, bool isAr) {
  final custody = row['custody'] as Map<String, dynamic>? ?? const {};
  return goldCustodyText(
    (custody['gold'] as Map<String, dynamic>?)?['balances']
            as Map<String, dynamic>? ??
        const {},
    isAr: isAr,
  );
}

/// The employees on a wide screen (board 1): one row each, six columns, the
/// figures under their titles; a row opens his page.
class _EmployeesTable extends StatelessWidget {
  const _EmployeesTable({
    required this.rows,
    required this.isAr,
    required this.onOpen,
  });
  final List<Map<String, dynamic>> rows;
  final bool isAr;
  final void Function(Map<String, dynamic> row) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final head = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );
    final tabular = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.md,
      ),
      child: child,
    );
    return Table(
      columnWidths: const {0: FlexColumnWidth(2.4), 5: FlexColumnWidth(2)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            for (final h in [
              isAr ? 'الموظف' : 'Employee',
              isAr ? 'الراتب الإجمالي' : 'Gross',
              isAr ? 'آخر راتب' : 'Last payroll',
              isAr ? 'السلف' : 'Advances',
              isAr ? 'العهدة' : 'Custody',
              isAr ? 'يحتاج' : 'Needs',
            ])
              cell(Text(h, style: head)),
          ],
        ),
        for (final r in rows)
          TableRow(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            children: [
              for (final child in <Widget>[
                Row(
                  key: ValueKey('hr-employee-${r['id']}'),
                  children: [
                    CircleAvatar(
                      backgroundColor: tones.gold.container,
                      foregroundColor: tones.gold.onContainer,
                      child: Text(
                        '${r['name']}'.isEmpty ? '?' : '${r['name']}'[0],
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r['name']}',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            [
                              if ((r['job_title'] ?? '').toString().isNotEmpty)
                                '${r['job_title']}',
                              ltrIsolate('${r['employee_code']}'),
                            ].join(' · '),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Text(
                  r['gross'] == null
                      ? (isAr ? 'لا هيكل' : 'no structure')
                      : _money(r['gross']),
                  style: tabular,
                ),
                switch (r['last_payroll']) {
                  final Map<String, dynamic> last => Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: ltrIsolate('${last['month']}/${last['year']}'),
                        ),
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: switch (last['status']) {
                            'paid' => isAr ? 'مصروف' : 'paid',
                            'approved' => isAr ? 'معتمد' : 'approved',
                            _ => isAr ? 'مسودة' : 'draft',
                          },
                          style: TextStyle(
                            color: last['status'] == 'paid'
                                ? tones.ready.fg
                                : tones.warning.fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    style: tabular,
                  ),
                  _ => const Text('—'),
                },
                Text(_money(r['advance']), style: tabular),
                Text(_custody(r, isAr), style: tabular),
                Wrap(
                  spacing: AppSpace.xs,
                  runSpacing: AppSpace.xs,
                  children: _needs(context, r, isAr),
                ),
              ])
                TableRowInkWell(onTap: () => onOpen(r), child: cell(child)),
            ],
          ),
      ],
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
    Widget figure(String label, String value) => SizedBox(
      width: 136,
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
          // two figures a line at a phone's width
          child: Wrap(
            spacing: AppSpace.md,
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
              figure(isAr ? 'العهدة' : 'Custody', _custody(row, isAr)),
              Wrap(
                spacing: AppSpace.xs,
                runSpacing: AppSpace.xs,
                children: _needs(context, row, isAr),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── الرواتب ─────────────────────────────────────────────────────────────────

/// «الرواتب» (board 3): the month's run itself -- the one open, else the
/// latest --, its head, stages, totals and lines; above it what needs doing
/// about the next, and the way to the runs before and the monthly report.
class _PayrollTab extends StatefulWidget {
  const _PayrollTab({
    required this.api,
    required this.service,
    required this.overview,
    required this.isAr,
    required this.onLegacy,
    required this.onChanged,
  });
  final ApiService api;
  final PayrollService service;
  final Map<String, dynamic> overview;
  final bool isAr;
  final VoidCallback onLegacy;
  final VoidCallback onChanged;

  @override
  State<_PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<_PayrollTab> {
  List<PayrollRunSummary>? _runs;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final runs = await widget.service.listRuns();
      if (mounted) {
        setState(() {
          _error = null;
          _runs = runs;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _load();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final followup = ((widget.overview['followup'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final missing = followup
        .where((i) => i['kind'] == 'run_missing')
        .firstOrNull;
    final runs = _runs;
    final live =
        runs?.where((r) => r.status != 'cancelled').toList() ?? const [];
    final current =
        live
            .where((r) => r.status == 'draft' || r.status == 'approved')
            .firstOrNull ??
        live.firstOrNull;
    Widget newRun() => FilledButton.icon(
      key: const ValueKey('hr-payroll-new-run'),
      onPressed: () => _push(
        PrepareRunScreen(
          api: widget.api,
          isArabic: isAr,
          service: widget.service,
        ),
      ),
      icon: const Icon(Icons.add),
      label: Text(isAr ? 'مسير جديد' : 'New run'),
    );
    final links = Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // the owner, 2 Nov 2026: a new run from here, not through the runs before
        if (missing == null) newRun(),
        TextButton.icon(
          key: const ValueKey('hr-payroll-runs'),
          onPressed: () => _push(
            PayrollRunsScreen(
              api: widget.api,
              isArabic: isAr,
              service: widget.service,
            ),
          ),
          icon: const Icon(Icons.list_alt),
          label: Text(isAr ? 'المسيرات السابقة' : 'Earlier runs'),
        ),
        // HR-UX ط5: the months before the runs, read by month
        TextButton.icon(
          key: const ValueKey('hr-payroll-legacy'),
          onPressed: widget.onLegacy,
          icon: const Icon(Icons.history),
          label: Text(isAr ? 'تقرير الرواتب الشهري' : 'Monthly payroll report'),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md,
            AppSpace.lg,
            0,
          ),
          child: missing == null
              ? Align(alignment: AlignmentDirectional.centerEnd, child: links)
              : Card(
                  key: const ValueKey('hr-payroll-month'),
                  color: tones.warning.container,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Wrap(
                      spacing: AppSpace.lg,
                      runSpacing: AppSpace.sm,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          isAr
                              ? 'مسير ${monthName(missing['month'] as int)} ${ltrIsolate('${missing['year']}')} لم يُنشأ'
                              : 'Run ${missing['month']}/${missing['year']} not drafted',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: tones.warning.onContainer,
                          ),
                        ),
                        Wrap(
                          spacing: AppSpace.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [newRun(), links],
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        Expanded(
          child: _error != null && runs == null
              ? AppErrorView(
                  title: isAr
                      ? 'تعذّر تحميل المسيرات'
                      : 'Could not load the runs',
                  error: _error!,
                  onRetry: _load,
                )
              : runs == null
              ? const AppLoadingView(summaryBlocks: 4, rows: 5)
              : current == null
              ? PayrollRunsScreen(
                  api: widget.api,
                  isArabic: isAr,
                  embedded: true,
                  service: widget.service,
                )
              : PayrollRunScreen(
                  key: ValueKey('hr-payroll-run-${current.id}'),
                  api: widget.api,
                  runId: current.id,
                  isArabic: isAr,
                  service: widget.service,
                  embedded: true,
                  onChanged: () {
                    _load();
                    widget.onChanged();
                  },
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
    // board 4: each a card, its urgency a strip on its side, its words, its
    // way to it; the most urgent first (the server's order)
    Widget item(
      Map<String, dynamic> i,
      String title,
      String body, {
      Widget? action,
      List<Widget> more = const [],
    }) {
      final tone = toneOf(i);
      return Card(
        key: ValueKey('hr-followup-${i['kind']}'),
        margin: const EdgeInsets.only(bottom: AppSpace.sm),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 6, color: tone.fg),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.sm,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: AppSpace.xs),
                            Text(body, style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                      if (more.isNotEmpty)
                        Wrap(
                          spacing: AppSpace.xs,
                          runSpacing: AppSpace.xs,
                          children: more,
                        ),
                      ?action,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget go(String label, VoidCallback onTap, {bool strong = false}) => strong
        ? FilledButton(onPressed: onTap, child: Text(label))
        : OutlinedButton(onPressed: onTap, child: Text(label));

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
              action: go(
                isAr ? 'إلى الرواتب' : 'Payroll',
                () => onTab(HrTab.payroll),
                strong: true,
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
              action: go(
                isAr ? 'إلى الرواتب' : 'Payroll',
                () => onTab(HrTab.payroll),
                strong: true,
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
              more: [
                for (final e in employees)
                  Tooltip(
                    message: (e['missing'] as List).join('، '),
                    child: ActionChip(
                      key: ValueKey('hr-followup-missing-${e['id']}'),
                      label: Text('${e['name']}'),
                      onPressed: () =>
                          onOpenEmployee(e['id'] as int, '${e['name']}'),
                    ),
                  ),
              ],
            ),
          );
        case 'policy_unset':
          cards.add(
            item(
              i,
              isAr ? 'أرقام لم تُضبط بعد' : 'Figures not set',
              isAr
                  ? 'أرقام نهاية الخدمة ونسب الاستقالة وأيام تنبيه العقود. لا يُحسب جزؤها دونها'
                  : 'End of service, resignation shares, contract alert days',
              action: go(
                isAr ? 'إلى الإعدادات' : 'Settings',
                () => onTab(HrTab.settings),
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
              action: go(
                isAr ? 'ملفه' : 'File',
                () =>
                    onOpenEmployee(i['employee_id'] as int, '${i['employee']}'),
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
              action: go(
                isAr ? 'ملفه' : 'File',
                () =>
                    onOpenEmployee(i['employee_id'] as int, '${i['employee']}'),
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
    // board 4: the kinds with nothing now said so, in small boxes under the rest
    final kinds = {for (final i in items) '${i['kind']}'};
    final quiet = [
      if (!kinds.contains('expiring'))
        isAr ? 'وثائق وعقود تنتهي' : 'Documents and contracts ending',
      if (!kinds.contains('leave'))
        isAr
            ? 'طلبات إجازة · في إجازة اليوم'
            : 'Leave requests · on leave today',
      if (!kinds.contains('termination_unpaid'))
        isAr
            ? 'تسويات نهاية خدمة لم تُصرف'
            : 'End-of-service settlements unpaid',
    ];
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            isAr ? 'ما يحتاج إجراءً' : 'What needs doing',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            isAr
                ? 'الأعجل أولًا. يختفي البند حين يُنجز'
                : 'The most urgent first; an item goes once done',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (cards.isEmpty)
            AppEmptyView(
              title: isAr ? 'لا شيء يحتاج إجراءً' : 'Nothing needs doing',
            ),
          ...cards,
          if (quiet.isNotEmpty)
            LayoutBuilder(
              builder: (context, box) {
                final columns = box.maxWidth >= 720 ? quiet.length : 1;
                final width =
                    (box.maxWidth - AppSpace.sm * (columns - 1)) / columns;
                return Wrap(
                  key: const ValueKey('hr-followup-quiet'),
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final label in quiet)
                      Container(
                        width: width,
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: theme.textTheme.titleSmall),
                            Text(
                              isAr ? 'لا شيء الآن' : 'Nothing now',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
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
