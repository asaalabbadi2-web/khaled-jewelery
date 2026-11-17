import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/app_state_views.dart';
import '../widgets/party_table.dart';
import 'account_statement_screen.dart';
import 'add_customer_screen.dart';

/// The customers (the owner, 17 Nov 2026: «طريقة عرض قائمة الموردين والعملاء
/// في الشاشات العريضة تحتاج تطوير»): a table on a wide screen, as the
/// suppliers' (party_table), cards on a narrow one; what stands between us
/// and them summed above, and the same filters as the suppliers'. A balance
/// is said «له» or «عليه», never with a minus sign; the gold at the main
/// karat is the server's (balance_gold_main), not a formula of the screen's.
/// A list that did not load says so -- it said «لا يوجد عملاء».
class CustomersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const CustomersScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  List<Map<String, dynamic>> _all = const [];
  bool _loading = true;
  Object? _error;
  bool _onlyWithBalance = false;
  bool _onlyActive = false;
  PartyTableSort _sort = PartyTableSort.name;
  bool _ascending = true;

  bool get _isAr => widget.isArabic;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.api.getCustomers();
      if (!mounted) return;
      setState(() {
        _all = [for (final r in rows) Map<String, dynamic>.from(r as Map)];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  double _cash(Map c) => (c['balance_cash'] as num?)?.toDouble() ?? 0.0;

  /// The customer's gold at the main karat, as the server converts it;
  /// null while the settings hold no main karat.
  double? _gold(Map c) => (c['balance_gold_main'] as num?)?.toDouble();

  bool _active(Map c) => (c['active'] ?? true) == true;

  bool _hasBalance(Map c) =>
      _cash(c).abs() >= 0.005 || (_gold(c) ?? 0).abs() >= 0.0005;

  /// The customers the search and the filters leave, as the header sorts them.
  List<Map<String, dynamic>> get _visible {
    final query = _searchController.text.trim().toLowerCase();
    bool matches(Map c) =>
        query.isEmpty ||
        [c['name'], c['phone'], c['customer_code']]
            .any((v) => '${v ?? ''}'.toLowerCase().contains(query));
    int by(Map a, Map b) => switch (_sort) {
      PartyTableSort.cash => _cash(a).compareTo(_cash(b)),
      PartyTableSort.gold => (_gold(a) ?? 0).compareTo(_gold(b) ?? 0),
      PartyTableSort.name => '${a['name'] ?? ''}'.compareTo('${b['name'] ?? ''}'),
    };
    return [
      for (final c in _all)
        if (matches(c) &&
            (!_onlyWithBalance || _hasBalance(c)) &&
            (!_onlyActive || _active(c)))
          c,
    ]..sort((a, b) => _ascending ? by(a, b) : by(b, a));
  }

  void _openStatement(Map c) {
    final customerId = c['id'];
    if (customerId == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountStatementScreen(
          accountId: customerId,
          accountName: c['name'],
          entityType: 'customer',
        ),
      ),
    );
  }

  Future<void> _editCustomer([Map? c]) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddCustomerScreen(
          api: widget.api,
          customer: c == null ? null : Map<String, dynamic>.from(c),
          isArabic: _isAr,
        ),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _deleteCustomer(Map c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isAr ? 'تأكيد الحذف' : 'Confirm Deletion'),
        content: Text(
          _isAr
              ? 'هل أنت متأكد من حذف هذا العميل؟'
              : 'Are you sure you want to delete this customer?',
        ),
        actions: [
          TextButton(
            child: Text(_isAr ? 'إلغاء' : 'Cancel'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: Text(_isAr ? 'حذف' : 'Delete'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await widget.api.deleteCustomer(c['id']);
      if (!mounted) return;
      AppFeedback.success(context, _isAr ? 'تم حذف العميل بنجاح' : 'Customer deleted successfully');
      _load();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: _isAr ? 'خطأ في الحذف' : 'Deletion failed');
    }
  }

  /// A customer's other actions: edit, and delete -- kept in the menu, not a
  /// red button beside the others.
  Widget _customerMenu(Map c) => PopupMenuButton<String>(
    key: Key('customer-menu-${c['id']}'),
    tooltip: _isAr ? 'الإجراءات' : 'Actions',
    onSelected: (value) => value == 'edit' ? _editCustomer(c) : _deleteCustomer(c),
    itemBuilder: (context) => [
      PopupMenuItem(value: 'edit', child: Text(_isAr ? 'تعديل' : 'Edit')),
      PopupMenuItem(value: 'delete', child: Text(_isAr ? 'حذف' : 'Delete')),
    ],
  );

  @override
  Widget build(BuildContext context) => AppListShortcuts(
    searchFocus: _searchFocus,
    onRefresh: _load,
    child: _buildScreen(context),
  );

  Widget _buildScreen(BuildContext context) {
    context.watch<SettingsProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAr ? 'قائمة العملاء' : 'Customers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: _isAr ? 'تحديث' : 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_loading && _error == null) _buildSummary(),
          _buildToolbar(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editCustomer(),
        tooltip: _isAr ? 'إضافة عميل' : 'Add Customer',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// What stands between us and the customers shown: how many, how many
  /// active, and what they owe us and we them, in cash and in gold.
  Widget _buildSummary() {
    final visible = _visible;
    final mainKarat = context.read<SettingsProvider>().mainKarat;
    double sum(Iterable<double> values) => values.fold(0.0, (a, b) => a + b);
    final cashOwed = sum(visible.map(_cash).where((v) => v > 0));
    final cashWeOwe = sum(visible.map(_cash).where((v) => v < 0));
    final goldOwed = sum(visible.map((c) => _gold(c) ?? 0).where((v) => v > 0));
    final goldWeOwe = sum(visible.map((c) => _gold(c) ?? 0).where((v) => v < 0));
    final tones = AppSemanticColors.of(context);
    final settings = context.read<SettingsProvider>();
    final cards = [
      _stat(
        title: _isAr ? 'العملاء المطابقون' : 'Customers shown',
        value: '${visible.length}',
        subtitle: _isAr ? 'النشطون: ${visible.where(_active).length}' : 'Active: ${visible.where(_active).length}',
        icon: Icons.people_alt_outlined,
        tone: tones.info,
      ),
      _stat(
        title: _isAr ? 'نقد لنا عندهم' : 'Cash owed to us',
        value: '${ltrIsolate(formatAmount(cashOwed))} ${settings.currencySymbolText}',
        subtitle: _isAr
            ? 'علينا لهم ${ltrIsolate(formatAmount(cashWeOwe.abs()))}'
            : 'We owe ${formatAmount(cashWeOwe.abs())}',
        icon: Icons.payments_outlined,
        tone: tones.debit,
        currency: true,
      ),
      _stat(
        title: _isAr ? 'ذهب لنا عندهم ($mainKarat)' : 'Gold owed to us ($mainKarat)',
        value: '${ltrIsolate(formatGrams(goldOwed))} ${_isAr ? 'جم' : 'g'}',
        subtitle: _isAr
            ? 'علينا لهم ${ltrIsolate(formatGrams(goldWeOwe.abs()))} جم'
            : 'We owe ${formatGrams(goldWeOwe.abs())} g',
        icon: Icons.diamond_outlined,
        tone: tones.gold,
      ),
      _stat(
        title: _isAr ? 'عملاء برصيد' : 'With a balance',
        value: '${visible.where(_hasBalance).length}',
        subtitle: _isAr ? 'نقدي أو ذهبي' : 'Cash or gold',
        icon: Icons.account_balance_wallet_outlined,
        tone: tones.ready,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= cards.length * 230) {
            return Row(
              key: const Key('customers-summary-line'),
              children: [
                for (final (i, card) in cards.indexed) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: card),
                ],
              ],
            );
          }
          // A phone: one row that scrolls sideways, the list still in sight.
          return SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) => SizedBox(width: 230, child: cards[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _stat({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required SemanticTone tone,
    bool currency = false,
  }) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w800,
      color: tone.fg,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tone.container,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Icon(icon, color: tone.onContainer, size: 20),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: currency
                      ? context.read<SettingsProvider>().buildText(value, style: valueStyle)
                      : Text(value, style: valueStyle),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The search, the suppliers' filters, and how many are shown.
  Widget _buildToolbar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: TextField(
              key: const Key('customers-search'),
              controller: _searchController,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: _isAr
                    ? 'بحث بالاسم أو الهاتف أو الكود...'
                    : 'Search by name, phone or code...',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          FilterChip(
            key: const Key('customers-with-balance'),
            label: Text(_isAr ? 'برصيد فقط' : 'With a balance'),
            selected: _onlyWithBalance,
            onSelected: (v) => setState(() => _onlyWithBalance = v),
          ),
          FilterChip(
            key: const Key('customers-only-active'),
            label: Text(_isAr ? 'نشط فقط' : 'Active only'),
            selected: _onlyActive,
            onSelected: (v) => setState(() => _onlyActive = v),
          ),
          if (!_loading && _error == null)
            Text(
              _isAr ? 'النتائج: ${_visible.length}' : 'Results: ${_visible.length}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const AppLoadingView();
    if (_error != null) {
      return AppErrorView(
        title: _isAr ? 'تعذّر تحميل العملاء' : 'Unable to load customers',
        error: _error,
        onRetry: _load,
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      final filtered = _searchController.text.trim().isNotEmpty || _onlyWithBalance || _onlyActive;
      return AppEmptyView(
        icon: Icons.people_outline,
        title: filtered
            ? (_isAr ? 'لا توجد نتائج مطابقة' : 'No matching customers')
            : (_isAr ? 'لا يوجد عملاء بعد' : 'No customers yet'),
        actionLabel: filtered
            ? (_isAr ? 'مسح الفلاتر' : 'Clear filters')
            : (_isAr ? 'إضافة عميل' : 'Add customer'),
        actionIcon: filtered ? Icons.filter_alt_off : Icons.add,
        onAction: filtered
            ? () {
                _searchController.clear();
                setState(() {
                  _onlyWithBalance = false;
                  _onlyActive = false;
                });
              }
            : () => _editCustomer(),
      );
    }
    // A table on a wide screen (party_table), cards on a narrow one.
    if (MediaQuery.sizeOf(context).width >= partyTableMinWidth) {
      return _buildTable(visible);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
        itemCount: visible.length,
        itemBuilder: (context, i) => _buildCard(visible[i]),
      ),
    );
  }

  Widget _buildTable(List<Map<String, dynamic>> rows) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: PartyTable(
      partyLabel: _isAr ? 'العميل' : 'Customer',
      mainKarat: context.read<SettingsProvider>().mainKarat,
      rows: [
        for (final c in rows)
          (
            name: '${c['name'] ?? ''}',
            code: '${c['customer_code'] ?? ''}',
            phone: '${c['phone'] ?? ''}',
            active: _active(c),
            cash: _cash(c),
            gold: _gold(c),
          ),
      ],
      onOpen: (i) => _openStatement(rows[i]),
      actions: (i) => [
        (
          icon: Icons.receipt_long_outlined,
          label: _isAr ? 'كشف الحساب' : 'Statement',
          onPressed: () => _openStatement(rows[i]),
        ),
        (
          icon: Icons.edit_outlined,
          label: _isAr ? 'تعديل' : 'Edit',
          onPressed: () => _editCustomer(rows[i]),
        ),
      ],
      menu: (i) => _customerMenu(rows[i]),
      onRefresh: _load,
      sort: _sort,
      ascending: _ascending,
      onSort: (by) => setState(() {
        _ascending = _sort == by ? !_ascending : true;
        _sort = by;
      }),
    ),
  );

  /// A customer on a phone: its name, its code and phone, its balances said
  /// «له» or «عليه», and each karat held when there are more than one.
  Widget _buildCard(Map<String, dynamic> c) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final code = '${c['customer_code'] ?? ''}';
    final phone = '${c['phone'] ?? ''}';
    final karats = [
      for (final k in const [24, 22, 21, 18])
        if (((c['balance_gold_${k}k'] as num?) ?? 0).abs() >= 0.0005)
          (k, ((c['balance_gold_${k}k'] as num?) ?? 0).toDouble()),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => _openStatement(c),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.person, color: theme.colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c['name'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: _active(c) ? null : muted,
                          ),
                        ),
                        Text(
                          [if (code.isNotEmpty) ltrIsolate(code), if (phone.isNotEmpty) ltrIsolate(phone)].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.receipt_long_outlined),
                    color: theme.colorScheme.primary,
                    tooltip: _isAr ? 'كشف حساب' : 'Account Statement',
                    onPressed: () => _openStatement(c),
                  ),
                  _customerMenu(c),
                ],
              ),
              if (_hasBalance(c)) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.lg,
                  runSpacing: AppSpace.xs,
                  children: [
                    if (_cash(c).abs() >= 0.005) PartyBalance(_cash(c), cash: true, large: false),
                    if ((_gold(c) ?? 0).abs() >= 0.0005) PartyBalance(_gold(c)!, cash: false, large: false),
                  ],
                ),
              ],
              if (karats.length >= 2) ...[
                const SizedBox(height: AppSpace.xs),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final (k, grams) in karats)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: tones.karat(k).container,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          '$k: ${ltrIsolate(formatGrams(grams.abs()))} ${_isAr ? 'جم' : 'g'}',
                          style: theme.textTheme.labelSmall?.copyWith(color: tones.karat(k).onContainer),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
