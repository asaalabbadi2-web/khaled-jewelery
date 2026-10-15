import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/account_picker_sheet.dart';

/// «الربط المحاسبي» (MAPPING-UI-1): يرسم ما يقوله الخادم في `/accounting-roles`
/// -- كل دور يطلبه الكود باسمه وغرضه ونوعه، ولكل عملية حسابها، صريحًا أو
/// موروثًا من «افتراضي»، والتوأم الوزني حيث يُقرأ. لا قائمة أدوار هنا: كانت
/// الشاشة تعرف ١٧ دورًا من كودها، ستة منها لم يعد يطلبها أحد، والكود يطلب ٦٩
/// (١٥ أكتوبر ٢٠٢٦). الحفظ والحذف يحكم فيهما الخادم ويُعرض رفضه كما هو.
class AccountingMappingScreenEnhanced extends StatefulWidget {
  const AccountingMappingScreenEnhanced({super.key, this.api});

  final ApiService? api;

  @override
  State<AccountingMappingScreenEnhanced> createState() =>
      _AccountingMappingScreenEnhancedState();
}

enum _Filter { all, unmapped, twinMissing }

const _defaultOperation = 'افتراضي';
const _changePermission = 'accounting.mapping';

class _AccountingMappingScreenEnhancedState
    extends State<AccountingMappingScreenEnhanced> {
  late final ApiService _api = widget.api ?? ApiService();
  final _search = TextEditingController();

  bool _loading = true;
  String? _error;
  List<String> _groups = const [];
  List<Map<String, dynamic>> _roles = const [];
  Map<String, dynamic> _summary = const {};
  List<Map<String, dynamic>> _accounts = const [];
  _Filter _filter = _Filter.all;
  bool _busy = false;

  bool get _canChange =>
      context.read<AuthProvider>().hasPermission(_changePermission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.getAccountingRoles(),
        _api.getAccounts(skipBalances: true),
      ]);
      if (!mounted) return;
      final body = results[0] as Map<String, dynamic>;
      setState(() {
        _groups = (body['groups'] as List).map((g) => '$g').toList();
        _roles = (body['roles'] as List).cast<Map<String, dynamic>>();
        _summary = (body['summary'] as Map).cast<String, dynamic>();
        _accounts = (results[1] as List).whereType<Map<String, dynamic>>().toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ── ما يُعرض ─────────────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _operations(Map<String, dynamic> role) =>
      (role['operations'] as List).cast<Map<String, dynamic>>();

  static Map<String, dynamic>? _account(Map<String, dynamic> op) =>
      (op['account'] as Map?)?.cast<String, dynamic>();

  static Map<String, dynamic>? _defaultAccount(Map<String, dynamic> role) {
    for (final op in _operations(role)) {
      if (op['operation'] == _defaultOperation) return _account(op);
    }
    return null;
  }

  /// The operations that take the default's account: one line under it, not a row each.
  static List<String> _inheriting(Map<String, dynamic> role) => [
        for (final op in _operations(role))
          if (op['source'] == 'default') '${op['operation']}',
      ];

  /// What «حساب خاص لعملية» offers: an operation with no row of its own.
  static List<String> _overrideCandidates(Map<String, dynamic> role) => [
        ..._inheriting(role),
        ...((role['overridable'] as List?) ?? const []).map((o) => '$o'),
      ];

  static bool _unmapped(Map<String, dynamic> role) =>
      _operations(role).any((op) => op['required'] == true && op['account'] == null);

  static bool _twinMissing(Map<String, dynamic> role) =>
      role['needs_twin'] == true &&
      _operations(role).any((op) {
        final account = _account(op);
        return account != null && account['twin'] == null;
      });

  bool _matches(Map<String, dynamic> role) {
    switch (_filter) {
      case _Filter.unmapped:
        if (!_unmapped(role)) return false;
      case _Filter.twinMissing:
        if (!_twinMissing(role)) return false;
      case _Filter.all:
        break;
    }
    final q = _search.text.trim();
    if (q.isEmpty) return true;
    final haystack = [
      role['label'],
      role['purpose'],
      role['key'],
      for (final op in _operations(role)) ...[
        _account(op)?['number'],
        _account(op)?['name'],
      ],
    ].whereType<Object>().join(' ');
    return haystack.contains(q);
  }

  // ── التغيير ──────────────────────────────────────────────────────────────

  Future<void> _change(Map<String, dynamic> role, String operation,
      Map<String, dynamic>? current) async {
    final weight = role['kind'] == 'weight';
    final picked = await showAccountPickerBottomSheet(
      context: context,
      accounts: _accounts,
      title: '«${role['label']}» — $operation',
      selectedId: current?['id'] as int?,
      // الدور يأخذ نوعًا واحدًا من الحسابات، والخادم يرفض غيره.
      predicate: (a) =>
          accountTracksWeight(a) == weight && a['is_active'] != false,
      showTransactionTypeFilter: false,
      showLeafOnlyFilter: true,
    );
    if (!mounted || picked == null) return;
    final id = picked['id'] is int ? picked['id'] as int : int.tryParse('${picked['id']}');
    if (id == null || id == current?['id']) return;
    final ok = await _confirm(
      title: 'تغيير حساب «${role['label']}»',
      lines: [
        'العملية: ${_operationLabel(operation)}',
        'الحالي: ${_currentText(role, operation)}',
        'الجديد: ${accountLabelOf(picked)}',
        if (operation == _defaultOperation)
          'يسري على كل عملية ليس لها ربط خاص بها.',
      ],
      action: 'حفظ',
    );
    if (!ok) return;
    await _run(() => _api.createAccountingMapping(
        operationType: operation, accountType: '${role['key']}', accountId: id));
  }

  Future<void> _remove(Map<String, dynamic> role, Map<String, dynamic> op) async {
    final ok = await _confirm(
      title: 'حذف ربط «${role['label']}»',
      lines: [
        'العملية: ${_operationLabel('${op['operation']}')}',
        'الحساب: ${_accountText(_account(op)!)}',
        if (op['operation'] != _defaultOperation && role['retired'] != true && _defaultAccount(role) != null)
          'تعود العملية إلى حساب «افتراضي»: ${_accountText(_defaultAccount(role)!)}.',
      ],
      action: 'حذف',
    );
    if (!ok) return;
    await _run(() => _api.deleteAccountingMapping(op['mapping_id'] as int));
  }

  Future<void> _override(Map<String, dynamic> role) async {
    final ops = _overrideCandidates(role);
    final operation = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('حساب خاص لعملية — «${role['label']}»'),
              subtitle: const Text('العملية التي لا ربط خاص لها تأخذ حساب «افتراضي».'),
            ),
            for (final op in ops)
              ListTile(
                leading: const Icon(Icons.call_split),
                title: Text(_operationLabel(op)),
                onTap: () => Navigator.pop(ctx, op),
              ),
          ],
        ),
      ),
    );
    if (!mounted || operation == null) return;
    await _change(role, operation, null);
  }

  Future<void> _run(Future<Object?> Function() call) async {
    setState(() => _busy = true);
    try {
      await call();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('حُفظ الربط')));
    } catch (e) {
      if (!mounted) return;
      // رفض الخادم بنصّه: دور مطلوب، حساب من غير نوعه، حساب موقوف...
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('لم يُحفظ'),
          content: Text('$e'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسنًا')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(
      {required String title, required List<String> lines, required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(line)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  /// What the operation posts on now, and from where -- as the server resolved it.
  static String _currentText(Map<String, dynamic> role, String operation) {
    final op = _operations(role).where((o) => o['operation'] == operation).firstOrNull;
    final account = op == null ? _defaultAccount(role) : _account(op);
    if (account == null) return 'غير مربوط';
    final via = (op?['via'] as Map?)?.cast<String, dynamic>();
    if (via != null) return '${_accountText(account)} (من ربط «${via['label']}»)';
    if (op == null || op['source'] == 'default') return '${_accountText(account)} (من «افتراضي»)';
    return _accountText(account);
  }

  static String _operationLabel(String op) =>
      op == _defaultOperation ? 'افتراضي (لكل العمليات)' : op.replaceAll('_', ' ');

  static String _accountText(Map<String, dynamic> account) =>
      '${account['number']} — ${account['name']}';

  // ── الرسم ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الربط المحاسبي'),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
        body: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('تعذّر تحميل الربط المحاسبي', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }
    final canChange = _canChange;
    final visible = _roles.where(_matches).toList();
    return AbsorbPointer(
      absorbing: _busy,
      child: ListView(
        // A row's account stays next to its buttons on a wide screen.
        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width > 1132
              ? (MediaQuery.sizeOf(context).width - 1100) / 2
              : 16,
          vertical: 16,
        ),
        children: [
          _SummaryCard(summary: _summary, canChange: canChange),
          const SizedBox(height: 12),
          _filters(context),
          const SizedBox(height: 8),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('لا دور يطابق البحث')),
            ),
          for (final group in _groups)
            if (visible.any((r) => r['group'] == group)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                child: Text(group, style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final role in visible.where((r) => r['group'] == group))
                _roleCard(context, role, canChange),
            ],
        ],
      ),
    );
  }

  Widget _filters(BuildContext context) {
    final unmapped = _roles.where(_unmapped).length;
    final twinless = _roles.where(_twinMissing).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'بحث باسم الدور أو رقم الحساب أو اسمه',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('الكل'),
              selected: _filter == _Filter.all,
              onSelected: (_) => setState(() => _filter = _Filter.all),
            ),
            ChoiceChip(
              label: Text('غير المربوط ($unmapped)'),
              selected: _filter == _Filter.unmapped,
              onSelected: (_) => setState(() => _filter = _Filter.unmapped),
            ),
            ChoiceChip(
              label: Text('بلا توأم وزني ($twinless)'),
              selected: _filter == _Filter.twinMissing,
              onSelected: (_) => setState(() => _filter = _Filter.twinMissing),
            ),
          ],
        ),
      ],
    );
  }

  Widget _roleCard(BuildContext context, Map<String, dynamic> role, bool canChange) {
    final tones = AppSemanticColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retired = role['retired'] == true;
    final overridable = _overrideCandidates(role);
    final inheriting = _inheriting(role);
    return Card(
      key: ValueKey('role-${role['key']}'),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _unmapped(role) ? tones.blocked.fg : scheme.outlineVariant,
          width: _unmapped(role) ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${role['label']}', style: Theme.of(context).textTheme.titleSmall),
                if (retired)
                  _Badge('لم يعد مستعملًا', tones.warning)
                else if (role['required'] == true)
                  _Badge('مطلوب', tones.info)
                else
                  _Badge('اختياري', SemanticTone(scheme.outline, scheme.surfaceContainerHighest, scheme.onSurface)),
                if (role['kind'] == 'weight') _Badge('حساب وزني', tones.gold),
                if (role['needs_twin'] == true) _Badge('يُقرأ توأمه الوزني', tones.gold),
              ],
            ),
            const SizedBox(height: 4),
            Text('${role['purpose']}', style: Theme.of(context).textTheme.bodySmall),
            const Divider(height: 16),
            for (final op in _operations(role))
              if (op['source'] != 'default') _operationRow(context, role, op, canChange),
            if (inheriting.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text('تأخذ حساب «افتراضي»: ${inheriting.join('، ')}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (canChange && overridable.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => _override(role),
                  icon: const Icon(Icons.call_split, size: 18),
                  label: const Text('حساب خاص لعملية'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _operationRow(BuildContext context, Map<String, dynamic> role,
      Map<String, dynamic> op, bool canChange) {
    final tones = AppSemanticColors.of(context);
    final text = Theme.of(context).textTheme;
    final account = _account(op);
    final operation = '${op['operation']}';
    // Not its own row: answered by another role's (an inherited one is not a row here).
    final via = (op['via'] as Map?)?.cast<String, dynamic>();
    final retired = role['retired'] == true;
    // As the server allows: an operation's own row, or a retired role's. A live
    // role's default is changed, never removed.
    final removable = canChange &&
        op['mapping_id'] != null &&
        (retired || operation != _defaultOperation);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(_operationLabel(operation), style: text.labelMedium),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (account == null && op['required'] == true)
                  Text('غير مربوط',
                      style: text.bodyMedium
                          ?.copyWith(color: tones.blocked.fg, fontWeight: FontWeight.w600))
                else if (account == null)
                  Text('بلا حساب (لا يطلبه النظام هنا)', style: text.bodyMedium)
                else
                  Text(_accountText(account),
                      textDirection: TextDirection.rtl,
                      style: text.bodyMedium?.copyWith(
                          color: account['is_active'] == false ? tones.blocked.fg : null)),
                if (via != null)
                  Text(
                      'من ربط «${via['label']}»'
                      '${via['operation'] == _defaultOperation ? ' (افتراضي)' : ''}',
                      style: text.bodySmall),
                if (account != null && account['is_active'] == false)
                  Text('الحساب موقوف', style: text.bodySmall?.copyWith(color: tones.blocked.fg)),
                if (account != null && role['needs_twin'] == true)
                  account['twin'] == null
                      ? Text('بلا توأم وزني مربوط',
                          style: text.bodySmall?.copyWith(color: tones.warning.fg))
                      : Text('التوأم الوزني: ${_accountText((account['twin'] as Map).cast<String, dynamic>())}',
                          style: text.bodySmall),
              ],
            ),
          ),
          if (canChange && !retired)
            IconButton(
              tooltip: 'تغيير الحساب',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _change(role, operation, op['mapping_id'] == null ? null : account),
            ),
          if (removable)
            IconButton(
              tooltip: 'حذف الربط',
              icon: Icon(Icons.delete_outline, size: 20, color: tones.blocked.fg),
              onPressed: () => _remove(role, op),
            ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.canChange});

  final Map<String, dynamic> summary;
  final bool canChange;

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final required = (summary['required'] as num?)?.toInt() ?? 0;
    final mapped = (summary['required_mapped'] as num?)?.toInt() ?? 0;
    final complete = required > 0 && mapped == required;
    final tone = complete ? tones.ready : tones.blocked;
    return Card(
      color: tone.container,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'الأدوار المطلوبة: $mapped من $required مربوطة',
              key: const ValueKey('mapping-summary'),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: required == 0 ? 0 : mapped / required,
              color: tone.fg,
              backgroundColor: tone.onContainer.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 8),
            Text(
              complete
                  ? 'كل دور يطلبه النظام له حسابه.'
                  : 'دور مطلوب بلا حساب يُرفض به كل قيد يحتاجه.',
              style: TextStyle(color: tone.onContainer),
            ),
            if (!canChange)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'للعرض فقط: تغيير الربط للمالك والمدير.',
                  key: const ValueKey('mapping-read-only'),
                  style: TextStyle(color: tone.onContainer, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.tone);

  final String text;
  final SemanticTone tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.onContainer)),
    );
  }
}
