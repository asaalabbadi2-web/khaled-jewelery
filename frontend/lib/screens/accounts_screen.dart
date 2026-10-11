import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

import '../api_service.dart';
import 'account_ledger_screen.dart';
import 'account_statement_screen.dart';
import '../utils/currency_utils.dart' as cu;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/account_tree.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/arabic_search.dart';
import '../widgets/account_management.dart';

enum _AccountsViewMode { cards, compact, tree }

class AccountsScreen extends StatefulWidget {
  final bool initialOnlyDetailAccounts;

  /// The home's and the settings' «دليل الحسابات» open it on its tree
  /// (CHART-UI-1; the owner's «الاسم الأشهر», 12 Oct 2026).
  final bool openOnTree;

  /// The server; tests pass a fake.
  final ApiService? apiService;

  const AccountsScreen({
    super.key,
    this.initialOnlyDetailAccounts = false,
    this.openOnTree = false,
    this.apiService,
  });

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  final TextEditingController _searchController = TextEditingController();

  /// The view a viewer chose, kept on this device (10 Oct 2026).
  static const _viewModeKey = 'accounts_view_mode';

  /// The tree's folded parents; null until the accounts arrive.
  Set<int>? _collapsed;

  List<Map<String, dynamic>> _allAccounts = const [];
  List<Map<String, dynamic>> _filteredAccounts = const [];
  bool _isLoading = true;
  String? _error;

  late bool _onlyDetailAccounts;
  bool _onlyWithBalance = false;
  bool _onlyWeightAccounts = false;

  /// The accounts under a root that tracks weight (71–75): the weight chart,
  /// shown in its own section (CHART-UI-2).
  final Set<int> _weightChart = {};
  final Map<int, Map<String, dynamic>> _byId = {};

  /// The sections folded by their header.
  final Set<String> _foldedSections = {};

  /// The account chosen in the tree; its path is shown above it.
  int? _selectedId;

  /// The row under the mouse: its actions show (the old tree's, CHART-UI-2).
  final ValueNotifier<int?> _hovered = ValueNotifier(null);

  /// The list's scroll, to bring a located account into view.
  ScrollController? _listController;
  _AccountsViewMode _mode = _AccountsViewMode.compact;

  static const _rowExtent = 64.0;

  /// A level's step in the tree: less on a phone, where the names need it.
  double get _indent => _wide ? 20 : 12;
  String _sortBy = 'number';
  bool _sortAscending = true;

  /// Null until restored or chosen: then compact on a wide screen, cards on a
  /// narrow one -- 456 accounts in cards of three badges each was a long read.
  _AccountsViewMode? _viewMode;

  final NumberFormat _cashFormat = NumberFormat('#,##0.00', 'ar');
  final NumberFormat _goldFormat = NumberFormat('#,##0.###', 'ar');

  @override
  void initState() {
    super.initState();
    _onlyDetailAccounts = widget.initialOnlyDetailAccounts;
    _searchController.addListener(_filterAccounts);
    _restoreViewMode();
    _fetchAccounts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _hovered.dispose();
    super.dispose();
  }

  Future<void> _restoreViewMode() async {
    if (widget.openOnTree) {
      setState(() => _viewMode = _AccountsViewMode.tree);
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_viewModeKey);
      final mode = _AccountsViewMode.values
          .where((m) => m.name == saved)
          .firstOrNull;
      if (mode != null && mounted) setState(() => _viewMode = mode);
    } catch (_) {
      // The default for the screen's width stands.
    }
  }

  Future<void> _setViewMode(_AccountsViewMode mode) async {
    setState(() => _viewMode = mode);
    _filterAccounts();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_viewModeKey, mode.name);
    } catch (_) {
      // Not remembered on this device.
    }
  }

  _AccountsViewMode _effectiveViewMode(double width) =>
      _viewMode ??
      (width >= 900 ? _AccountsViewMode.compact : _AccountsViewMode.cards);

  Future<void> _fetchAccounts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final allAccounts = await _api.getAccounts();
      if (!mounted) {
        return;
      }
      final normalized = allAccounts
          .whereType<Map>()
          .map(
            (entry) =>
                entry.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(growable: false);
      _allAccounts = _annotateMemoLinks(normalized);
      _collapsed ??= accountTreeDefaultCollapsed(_allAccounts);
      _filterAccounts();
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      // Said once, in the page's error state, in words -- not the exception's
      // raw text in a snackbar besides.
      setState(() {
        _isLoading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Each account's section and a financial leaf's weight twin (CHART-UI-2).
  ///
  /// The section is the root's: under a root that tracks weight (71–75) is
  /// the weight chart. A financial leaf whose memo account (memo_account_id)
  /// tracks weight keeps it as `_weight_twin` for the ⚖ shortcut to its
  /// statement. The twin is no longer folded into the financial row and hidden
  /// (10 Oct 2026): the weight chart is shown whole, in grams, in its section
  /// -- the merge left «الموردون وزني» with no children and 293 of 463 shown.
  List<Map<String, dynamic>> _annotateMemoLinks(
    List<Map<String, dynamic>> accounts,
  ) {
    // Rebuilt fresh each call (_fetchAccounts can re-run).
    _byId.clear();
    _weightChart.clear();
    for (final acc in accounts) {
      final id = _asInt(acc['id']);
      if (id != null) _byId[id] = acc;
    }
    final hasChildren = <int>{};
    for (final acc in accounts) {
      final parentId = _asInt(acc['parent_id']);
      if (parentId != null) hasChildren.add(parentId);
    }

    for (final acc in accounts) {
      final id = _asInt(acc['id']);
      if (id == null) continue;
      if (_tracksWeight(_rootOf(acc))) _weightChart.add(id);
    }

    for (final acc in accounts) {
      final id = _asInt(acc['id']);
      if (id == null || _weightChart.contains(id) || hasChildren.contains(id)) {
        continue;
      }
      final twin = _byId[_asInt(acc['memo_account_id'])];
      if (twin != null && _tracksWeight(twin) && twin['id'] != acc['id']) {
        acc['_weight_twin'] = twin;
      }
    }

    return accounts;
  }

  Map<String, dynamic> _rootOf(Map<String, dynamic> account) {
    var a = account;
    final seen = <int>{};
    while (true) {
      final parent = _byId[_asInt(a['parent_id'])];
      if (parent == null || !seen.add(_asInt(parent['id']) ?? -1)) return a;
      a = parent;
    }
  }

  /// The account and the parents above it, the root first.
  List<Map<String, dynamic>> _pathOf(Map<String, dynamic> account) {
    final path = <Map<String, dynamic>>[account];
    final seen = <int>{_asInt(account['id']) ?? -1};
    var parent = _byId[_asInt(account['parent_id'])];
    while (parent != null && seen.add(_asInt(parent['id']) ?? -1)) {
      path.insert(0, parent);
      parent = _byId[_asInt(parent['parent_id'])];
    }
    return path;
  }

  bool _inWeightChart(Map<String, dynamic> account) =>
      _weightChart.contains(_asInt(account['id']));

  static const _sections = ['financial', 'weight'];

  String _sectionOf(Map<String, dynamic> account) =>
      _inWeightChart(account) ? 'weight' : 'financial';

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('${value ?? ''}');
  }

  double _asDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse('${value ?? ''}') ?? 0.0;
  }

  Map<String, dynamic>? _balancesOf(Map<String, dynamic> account) {
    final balances = account['balances'];
    if (balances is Map) {
      return balances.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  /// «مدين / دائن» after a balance, as an accountant reads it -- not a sign.
  String _side(double value, {double epsilon = 0.005}) =>
      value.abs() < epsilon ? '' : (value > 0 ? ' مدين' : ' دائن');

  String _cashText(double value) =>
      '${_cashFormat.format(value.abs())} ${context.read<SettingsProvider>().currencySymbolText}${_side(value)}';

  String _goldText(double value) =>
      '${_goldFormat.format(value.abs())} جم${_side(value, epsilon: 0.0005)}';

  /// Gold is shown where it belongs: a weight account, or any with gold on it
  /// -- a cash account's «0 جم» was noise.
  bool _showsGold(Map<String, dynamic> account, double gold) =>
      _tracksWeight(account) || gold.abs() >= 0.0005;

  int _childCount(Map<String, dynamic> account) =>
      ((account['sub_accounts'] as List?) ?? const []).length;

  bool _hasChildren(Map<String, dynamic> account) {
    final subAccounts = account['sub_accounts'] as List?;
    return subAccounts != null && subAccounts.isNotEmpty;
  }

  bool _tracksWeight(Map<String, dynamic> account) =>
      account['tracks_weight'] == true;

  /// A parent's balance is the server's, its own entries and all under it
  /// (CHART-UI-1): the screen sums nothing.
  Map<String, dynamic>? _subtreeOf(Map<String, dynamic> account) {
    final subtree = account['subtree_balances'];
    return subtree is Map
        ? subtree.map((k, v) => MapEntry(k.toString(), v))
        : null;
  }

  double _cashBalanceOf(Map<String, dynamic> account) {
    return _asDouble((_subtreeOf(account) ?? _balancesOf(account))?['cash']);
  }

  double _goldBalanceOf(Map<String, dynamic> account) {
    final subtree = _subtreeOf(account);
    if (subtree != null) return _asDouble(subtree['weight_total']);
    final weight = _balancesOf(account)?['weight'];
    if (weight is Map) {
      return _asDouble(weight['total']);
    }
    return 0.0;
  }

  bool _hasAnyBalance(Map<String, dynamic> account) {
    return _cashBalanceOf(account).abs() > 0.01 ||
        _goldBalanceOf(account).abs() > 0.001;
  }

  String _accountTypeLabel(Map<String, dynamic> account) {
    final type = (account['type'] ?? '').toString().trim();
    return type.isEmpty ? 'غير مصنف' : accountTypeLabel(type);
  }

  /// One of the five, or null for all (CHART-UI-1).
  String? _typeFilter;

  bool _ofType(Map<String, dynamic> account) =>
      _typeFilter == null ||
      (account['type'] ?? '').toString().toLowerCase() ==
          _typeFilter!.toLowerCase();

  String _parentLabel(Map<String, dynamic> account) {
    final parent = account['parent_account'];
    if (parent is! Map) {
      return 'بدون حساب رئيسي';
    }
    final name = (parent['name'] ?? '').toString().trim();
    final number = (parent['account_number'] ?? '').toString().trim();
    if (name.isNotEmpty && number.isNotEmpty) {
      return '$name • $number';
    }
    if (name.isNotEmpty) {
      return name;
    }
    return number.isEmpty ? 'بدون حساب رئيسي' : number;
  }

  String _accountNumber(Map<String, dynamic> account) {
    return (account['account_number'] ?? '').toString().trim();
  }

  void _filterAccounts() {
    final query = normalizeForSearch(_searchController.text);
    final filtered = _allAccounts
        .where((account) {
          final name = normalizeForSearch((account['name'] ?? '').toString());
          final accountNumber = normalizeForSearch(_accountNumber(account));
          final type = normalizeForSearch(_accountTypeLabel(account));
          final parent = normalizeForSearch(_parentLabel(account));

          final matchesQuery =
              query.isEmpty ||
              name.contains(query) ||
              accountNumber.contains(query) ||
              type.contains(query) ||
              parent.contains(query);

          if (!matchesQuery) {
            return false;
          }
          if (_onlyDetailAccounts && _hasChildren(account)) {
            return false;
          }
          if (_onlyWithBalance && !_hasAnyBalance(account)) {
            return false;
          }
          if (_onlyWeightAccounts && !_tracksWeight(account)) {
            return false;
          }
          return _ofType(account);
        })
        .toList(growable: false);

    filtered.sort((a, b) {
      int comparison;
      switch (_sortBy) {
        case 'name':
          comparison = (a['name'] ?? '').toString().compareTo(
            (b['name'] ?? '').toString(),
          );
          break;
        case 'cash':
          comparison = _cashBalanceOf(a).compareTo(_cashBalanceOf(b));
          break;
        case 'gold':
          comparison = _goldBalanceOf(a).compareTo(_goldBalanceOf(b));
          break;
        case 'type':
          comparison = _accountTypeLabel(a).compareTo(_accountTypeLabel(b));
          break;
        case 'children':
          // By how many, not by whether any (it sorted by has-children).
          comparison = _childCount(a).compareTo(_childCount(b));
          break;
        default:
          comparison = _accountNumber(a).compareTo(_accountNumber(b));
          break;
      }

      if (comparison == 0) {
        comparison = (a['name'] ?? '').toString().compareTo(
          (b['name'] ?? '').toString(),
        );
      }
      return _sortAscending ? comparison : -comparison;
    });

    setState(() {
      _filteredAccounts = filtered;
    });
  }

  int get _activeFiltersCount {
    int count = 0;
    if (_searchController.text.trim().isNotEmpty) count++;
    if (_onlyDetailAccounts) count++;
    if (_onlyWithBalance) count++;
    if (_onlyWeightAccounts) count++;
    if (_typeFilter != null) count++;
    // The order is how they are listed, not which: not a filter.
    return count;
  }

  /// A deactivated account keeps its entries and takes no new one (ADR-043).
  bool _isInactive(Map<String, dynamic> account) =>
      account['is_active'] == false;

  List<PopupMenuEntry<String>> _accountMenuItems(
    Map<String, dynamic> account,
  ) => [
    const PopupMenuItem(value: 'statement', child: Text('كشف الحساب')),
    const PopupMenuItem(value: 'ledger', child: Text('دفتر الأستاذ')),
    const PopupMenuItem(value: 'copy', child: Text('نسخ رقم الحساب')),
    if (_mode != _AccountsViewMode.tree ||
        _searchController.text.trim().isNotEmpty)
      const PopupMenuItem(value: 'locate', child: Text('إظهار في الشجرة')),
    const PopupMenuDivider(),
    const PopupMenuItem(value: 'add_child', child: Text('إضافة حساب فرعي')),
    const PopupMenuItem(value: 'edit', child: Text('تعديل')),
    const PopupMenuItem(value: 'delete', child: Text('حذف')),
    PopupMenuItem(
      key: Key('account-active-${account['id']}'),
      value: 'active',
      child: Text(_isInactive(account) ? 'تفعيل الحساب' : 'إيقاف الحساب'),
    ),
  ];

  void _onAccountMenu(String value, Map<String, dynamic> account) {
    if (value == 'statement') {
      _openStatement(account);
    } else if (value == 'ledger') {
      _openLedger(account);
    } else if (value == 'copy') {
      _copyAccountNumber(account);
    } else if (value == 'locate') {
      _locate(account);
    } else if (value == 'active') {
      _toggleActive(account);
    } else if (value == 'add_child') {
      _manage(
        showAccountForm(
          context,
          api: _api,
          accounts: _allAccounts,
          parent: account,
        ),
      );
    } else if (value == 'edit') {
      _manage(
        showAccountForm(
          context,
          api: _api,
          accounts: _allAccounts,
          editing: account,
        ),
      );
    } else if (value == 'delete') {
      _manage(deleteAccountFlow(context, api: _api, account: account));
    }
  }

  /// A change the server took: the chart is read again.
  Future<void> _manage(Future<bool> change) async {
    if (await change && mounted) await _fetchAccounts();
  }

  Future<void> _toggleActive(Map<String, dynamic> account) async {
    final id = _asInt(account['id']);
    if (id == null) return;
    final activate = _isInactive(account);
    final label = '${_accountNumber(account)} «${account['name'] ?? ''}»';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(activate ? 'تفعيل الحساب' : 'إيقاف الحساب'),
        content: Text(
          activate
              ? 'يعود $label يقبل القيود.'
              : 'يبقى $label بحركاته في الكشوف والتقارير، ولا يقبل أي قيد جديد. '
                    'لا يُوقف حساب له رصيد أو قيد غير مرحّل أو ربط محاسبي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            key: const Key('account-active-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(activate ? 'تفعيل' : 'إيقاف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _api.setAccountActive(id, activate);
      messenger.showSnackBar(
        SnackBar(content: Text(activate ? 'فُعّل $label' : 'أُوقف $label')),
      );
      await _fetchAccounts();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _copyAccountNumber(Map<String, dynamic> account) async {
    final accountNumber = _accountNumber(account);
    if (accountNumber.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: accountNumber));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('تم نسخ رقم الحساب $accountNumber')));
  }

  void _openStatement(Map<String, dynamic> account) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountStatementScreen(
          accountId: _asInt(account['id']) ?? 0,
          accountName: (account['name'] ?? 'N/A').toString(),
        ),
      ),
    );
  }

  void _openLedger(Map<String, dynamic> account) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountLedgerScreen(
          accountId: _asInt(account['id']) ?? 0,
          accountName: (account['name'] ?? 'N/A').toString(),
        ),
      ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 250),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withValues(alpha: 0.16)),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.62,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatisticsSection() {
    final financial = _filteredAccounts.where((a) => !_inWeightChart(a)).length;
    final weight = _filteredAccounts.where(_inWeightChart).length;
    final detailAccounts = _filteredAccounts
        .where((account) => !_hasChildren(account))
        .length;
    final withBalance = _filteredAccounts.where(_hasAnyBalance).length;
    final tones = AppSemanticColors.of(context);

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _buildSummaryCard(
          title: 'الحسابات المالية',
          value: '$financial',
          subtitle: 'بالريال',
          icon: Icons.account_balance_wallet_outlined,
          color: tones.cash.fg,
        ),
        _buildSummaryCard(
          title: 'الحسابات الوزنية',
          value: '$weight',
          subtitle: 'بالجرام',
          icon: Icons.scale_outlined,
          color: tones.gold.fg,
        ),
        _buildSummaryCard(
          title: 'حسابات فرعية',
          value: '$detailAccounts',
          subtitle: 'تقبل القيود',
          icon: Icons.account_tree_outlined,
          color: Theme.of(context).colorScheme.tertiary,
        ),
        _buildSummaryCard(
          title: 'حسابات برصيد',
          value: '$withBalance',
          subtitle: 'نقدي أو وزني',
          icon: Icons.account_balance_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }

  Widget _buildManagementToolbar(_AccountsViewMode mode) {
    final inTree = mode == _AccountsViewMode.tree;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!inTree)
                      FilterChip(
                        label: const Text('فرعية فقط'),
                        selected: _onlyDetailAccounts,
                        onSelected: (value) {
                          setState(() {
                            _onlyDetailAccounts = value;
                          });
                          _filterAccounts();
                        },
                      ),
                    FilterChip(
                      label: const Text('برصيد فقط'),
                      selected: _onlyWithBalance,
                      onSelected: (value) {
                        setState(() {
                          _onlyWithBalance = value;
                        });
                        _filterAccounts();
                      },
                    ),
                    FilterChip(
                      label: const Text('وزنية فقط'),
                      selected: _onlyWeightAccounts,
                      onSelected: (value) {
                        setState(() {
                          _onlyWeightAccounts = value;
                        });
                        _filterAccounts();
                      },
                    ),
                    PopupMenuButton<String?>(
                      key: const Key('accounts-type-filter'),
                      tooltip: 'نوع الحساب',
                      onSelected: (value) {
                        setState(() => _typeFilter = value);
                        _filterAccounts();
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: null,
                          child: Text('كل الأنواع'),
                        ),
                        for (final e in accountTypeLabels.entries)
                          PopupMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      child: Chip(
                        avatar: const Icon(Icons.category_outlined, size: 16),
                        label: Text(
                          _typeFilter == null
                              ? 'كل الأنواع'
                              : accountTypeLabel(_typeFilter),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_activeFiltersCount > 0)
                TextButton.icon(
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _onlyDetailAccounts = false;
                      _onlyWithBalance = false;
                      _onlyWeightAccounts = false;
                      _typeFilter = null;
                    });
                    _filterAccounts();
                  },
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('مسح الفلاتر'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 420,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText:
                        'ابحث بالاسم أو رقم الحساب أو النوع أو الحساب الرئيسي',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchController.text.trim().isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _filterAccounts();
                            },
                          ),
                  ),
                ),
              ),
              if (!inTree)
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    value: _sortBy,
                    decoration: const InputDecoration(
                      labelText: 'الترتيب',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'number',
                        child: Text('رقم الحساب'),
                      ),
                      DropdownMenuItem(value: 'name', child: Text('الاسم')),
                      DropdownMenuItem(value: 'type', child: Text('التصنيف')),
                      DropdownMenuItem(
                        value: 'cash',
                        child: Text('الرصيد النقدي'),
                      ),
                      DropdownMenuItem(
                        value: 'gold',
                        child: Text('الرصيد الذهبي'),
                      ),
                      DropdownMenuItem(
                        value: 'children',
                        child: Text('عدد الأبناء'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _sortBy = value;
                      });
                      _filterAccounts();
                    },
                  ),
                ),
              if (inTree) ...[
                OutlinedButton.icon(
                  key: const Key('accounts-expand-all'),
                  onPressed: () => setState(() => _collapsed = <int>{}),
                  icon: const Icon(Icons.unfold_more, size: 18),
                  label: const Text('توسيع الكل'),
                ),
                OutlinedButton.icon(
                  key: const Key('accounts-collapse-all'),
                  onPressed: () => setState(
                    () => _collapsed = {
                      for (final a in _allAccounts)
                        if (_hasChildren(a)) ?_asInt(a['id']),
                    },
                  ),
                  icon: const Icon(Icons.unfold_less, size: 18),
                  label: const Text('طي الكل'),
                ),
              ],
              if (!inTree)
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _sortAscending = !_sortAscending;
                    });
                    _filterAccounts();
                  },
                  icon: Icon(
                    _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(_sortAscending ? 'تصاعدي' : 'تنازلي'),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.55,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'المعروض: ${_filteredAccounts.length} من ${_allAccounts.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(Map<String, dynamic> account) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasChildren = _hasChildren(account);
    final accountNumber = _accountNumber(account);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openStatement(account),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _tracksWeight(account)
                          ? Icons.scale_outlined
                          : Icons.account_balance_wallet_outlined,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (account['name'] ?? 'N/A').toString(),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          accountNumber.isEmpty
                              ? _accountTypeLabel(account)
                              : '$accountNumber • ${_accountTypeLabel(account)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.65,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'الإجراءات',
                    onSelected: (value) => _onAccountMenu(value, account),
                    itemBuilder: (context) => _accountMenuItems(account),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_isInactive(account))
                    Chip(
                      avatar: const Icon(Icons.block, size: 16),
                      label: const Text('موقوف'),
                    ),
                  if (_tracksWeight(account))
                    Chip(
                      avatar: const Icon(Icons.scale_outlined, size: 16),
                      label: const Text('وزني'),
                    ),
                  if (account['_weight_twin'] is Map)
                    Tooltip(
                      message: 'كشف الحساب الوزني المرتبط',
                      child: ActionChip(
                        avatar: const Icon(Icons.scale_outlined, size: 16),
                        label: Text(
                          'وزني مرتبط: ${(account['_weight_twin'] as Map)['account_number']}',
                        ),
                        onPressed: () => _openStatement(
                          account['_weight_twin'] as Map<String, dynamic>,
                        ),
                      ),
                    ),
                  Chip(
                    avatar: Icon(
                      hasChildren
                          ? Icons.account_tree_outlined
                          : Icons.subdirectory_arrow_left_outlined,
                      size: 16,
                    ),
                    label: Text(hasChildren ? 'رئيسي' : 'فرعي'),
                  ),
                  if (hasChildren)
                    Chip(
                      avatar: const Icon(Icons.layers_outlined, size: 16),
                      label: Text(
                        'أبناء: ${((account['sub_accounts'] as List?) ?? const []).length}',
                      ),
                    ),
                  Chip(
                    avatar: const Icon(Icons.link_outlined, size: 16),
                    label: Text(_parentLabel(account)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final (k, b) in _balancesShown(account).indexed) ...[
                    if (k > 0) const SizedBox(width: 8),
                    Expanded(
                      child: _buildBalanceTile(
                        icon: b.gold
                            ? Icons.auto_awesome_outlined
                            : Icons.payments_outlined,
                        label: b.gold ? 'الرصيد الوزني' : 'الرصيد النقدي',
                        value: b.text,
                        color: b.odd
                            ? AppSemanticColors.of(context).warning.fg
                            : (b.gold
                                  ? AppSemanticColors.of(context).gold.fg
                                  : AppSemanticColors.of(context).cash.fg),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _openStatement(account),
                      icon: const Icon(Icons.assessment_outlined, size: 18),
                      label: const Text('كشف الحساب'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openLedger(account),
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      label: const Text('دفتر الأستاذ'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The balances an account shows: its chart's unit first -- a financial
  /// account in riyals, a weight account in grams (CHART-UI-2). The other unit
  /// shows only when it is there: gold on a financial account that tracks
  /// weight; cash on a weight account -- which should not be, so it is marked.
  List<({String text, bool gold, bool odd})> _balancesShown(
    Map<String, dynamic> account,
  ) {
    final cash = _cashBalanceOf(account);
    final gold = _goldBalanceOf(account);
    if (_inWeightChart(account)) {
      return [
        (text: _goldText(gold), gold: true, odd: false),
        if (cash.abs() >= 0.005)
          (text: _cashText(cash), gold: false, odd: true),
      ];
    }
    return [
      (text: _cashText(cash), gold: false, odd: false),
      if (_showsGold(account, gold))
        (text: _goldText(gold), gold: true, odd: false),
    ];
  }

  /// The name, what the search found in it marked (the old tree's, CHART-UI-2)
  /// -- found as the search finds it: «النقديه» marks «النقدية».
  Widget _highlightedName(String name, TextStyle? style) {
    final query = normalizeForSearch(_searchController.text);
    if (query.isEmpty) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final normalized = StringBuffer();
    final origin = <int>[];
    for (var i = 0; i < name.length; i++) {
      final ch = name[i];
      final n = ch.trim().isEmpty ? ch : normalizeForSearch(ch);
      normalized.write(n);
      for (var k = 0; k < n.length; k++) {
        origin.add(i);
      }
    }
    final at = normalized.toString().indexOf(query);
    if (at < 0) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final from = origin[at];
    final to = origin[at + query.length - 1] + 1;
    final tone = AppSemanticColors.of(context).warning;
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: name.substring(0, from)),
          TextSpan(
            text: name.substring(from, to),
            style: TextStyle(
              backgroundColor: tone.container,
              color: tone.onContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: name.substring(to)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// A row's actions under the mouse, beside its menu -- which stays where it
  /// is and works (the old tree hid and disabled it under the pointer).
  Widget _hoverActions(Map<String, dynamic> account) {
    final id = _asInt(account['id']);
    return ValueListenableBuilder<int?>(
      valueListenable: _hovered,
      builder: (context, hovered, _) => Visibility(
        visible: hovered == id,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'كشف الحساب',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.receipt_long_outlined, size: 18),
              onPressed: () => _openStatement(account),
            ),
            IconButton(
              tooltip: 'إضافة حساب فرعي',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_circle_outline, size: 18),
              onPressed: () => _onAccountMenu('add_child', account),
            ),
            IconButton(
              tooltip: 'تعديل',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () => _onAccountMenu('edit', account),
            ),
          ],
        ),
      ),
    );
  }

  /// Hover actions where there is room for them (a wide screen).
  bool get _wide => MediaQuery.sizeOf(context).width >= 900;

  /// In the tree a parent opens and closes where it is tapped and is chosen
  /// (its path shows); a leaf is chosen and opens its statement.
  void _onRowTap(Map<String, dynamic> account, AccountTreeRow? tree) {
    if (tree == null) {
      _openStatement(account);
      return;
    }
    final id = _asInt(account['id']);
    setState(() {
      _selectedId = id;
      if (tree.hasChildren && id != null) {
        final collapsed = _collapsed ??= <int>{};
        collapsed.contains(id) ? collapsed.remove(id) : collapsed.add(id);
      }
    });
    if (!tree.hasChildren) _openStatement(account);
  }

  Widget _buildCompactRow(
    Map<String, dynamic> account, {
    AccountTreeRow? tree,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final id = _asInt(account['id']);
    final parent = tree?.hasChildren ?? _hasChildren(account);
    final selected = tree != null && _selectedId != null && _selectedId == id;
    final depth = tree?.depth ?? 0;
    final balances = _balancesShown(account);
    final twin = account['_weight_twin'];

    return MouseRegion(
      onEnter: (_) => _hovered.value = id,
      onExit: (_) {
        if (_hovered.value == id) _hovered.value = null;
      },
      child: Material(
        key: Key('account-row-$id'),
        // A parent on its own shade, the chosen row on the theme's (CHART-UI-2).
        color: selected
            ? colorScheme.secondaryContainer
            : (tree != null && parent
                  ? colorScheme.surfaceContainerLow
                  : colorScheme.surface),
        child: InkWell(
          onTap: () => _onRowTap(account, tree),
          child: CustomPaint(
            painter: tree == null || depth == 0
                ? null
                : _TreeLines(
                    depth: depth,
                    indent: _indent,
                    color: colorScheme.outlineVariant,
                    rtl: Directionality.of(context) == TextDirection.rtl,
                  ),
            child: Container(
              padding: EdgeInsetsDirectional.only(
                start: 14 + depth * _indent,
                end: 6,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outline.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                children: [
                  if (tree != null) ...[
                    SizedBox(
                      width: 32,
                      child: tree.hasChildren
                          ? IconButton(
                              key: Key('account-fold-$id'),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              tooltip: tree.expanded ? 'طيّ' : 'فتح',
                              icon: Icon(
                                tree.expanded
                                    ? Icons.expand_more
                                    : Icons.chevron_left,
                                size: 20,
                              ),
                              onPressed: () => setState(() {
                                final collapsed = _collapsed ??= <int>{};
                                if (id == null) return;
                                collapsed.contains(id)
                                    ? collapsed.remove(id)
                                    : collapsed.add(id);
                              }),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Icon(
                      tree.hasChildren
                          ? (tree.expanded
                                ? Icons.folder_open_outlined
                                : Icons.folder_outlined)
                          : Icons.description_outlined,
                      size: 18,
                      color: tree.hasChildren
                          ? tones.gold.fg
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    flex: _wide ? 4 : 5,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _highlightedName(
                          (account['name'] ?? 'N/A').toString(),
                          theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: parent
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_accountNumber(account)} • ${_accountTypeLabel(account)}'
                          '${_isInactive(account) ? ' • موقوف' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final (k, b) in balances.indexed)
                          // One line each, shrunk to fit -- on a phone a balance
                          // wrapped and overflowed its row.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerEnd,
                            child: b.gold
                                ? Text(
                                    b.text,
                                    textAlign: TextAlign.end,
                                    style:
                                        (k == 0
                                                ? theme.textTheme.bodyMedium
                                                : theme.textTheme.bodySmall)
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: b.odd
                                                  ? tones.warning.fg
                                                  : tones.gold.fg,
                                            ),
                                  )
                                : cu.SarAwareText(
                                    b.text,
                                    isNewSar: context
                                        .read<SettingsProvider>()
                                        .currencyIsNewSar,
                                    textAlign: TextAlign.end,
                                    style:
                                        (k == 0
                                                ? theme.textTheme.bodyMedium
                                                : theme.textTheme.bodySmall)
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: b.odd
                                                  ? tones.warning.fg
                                                  : tones.cash.fg,
                                            ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    // On a phone the name takes the room of a missing ⚖.
                    width: twin is Map<String, dynamic> || _wide ? 40 : 0,
                    child: twin is Map<String, dynamic>
                        ? IconButton(
                            tooltip: 'كشف الحساب الوزني المرتبط',
                            icon: Icon(
                              Icons.scale_outlined,
                              size: 18,
                              color: tones.gold.fg,
                            ),
                            onPressed: () => _openStatement(twin),
                          )
                        : null,
                  ),
                  if (_wide) _hoverActions(account),
                  PopupMenuButton<String>(
                    key: Key('account-menu-${account['id']}'),
                    onSelected: (value) => _onAccountMenu(value, account),
                    itemBuilder: (context) => _accountMenuItems(account),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A section's head: its name and unit, how many accounts are in it, and
  /// a tap folds it (the old tree's two sections, CHART-UI-2).
  Widget _sectionHeader(String section) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final weight = section == 'weight';
    final tone = weight ? tones.gold : tones.cash;
    final folded = _foldedSections.contains(section);
    final count = _filteredAccounts
        .where((a) => _sectionOf(a) == section)
        .length;
    return Material(
      key: Key('accounts-section-$section'),
      color: tone.container,
      child: InkWell(
        onTap: () => setState(
          () => folded
              ? _foldedSections.remove(section)
              : _foldedSections.add(section),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                weight
                    ? Icons.scale_outlined
                    : Icons.account_balance_wallet_outlined,
                size: 20,
                color: tone.fg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  weight
                      ? 'الحسابات الوزنية (بالجرام)'
                      : 'الحسابات المالية (بالريال)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: tone.onContainer,
                  ),
                ),
              ),
              Text(
                '$count حساب',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tone.onContainer,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                folded ? Icons.chevron_left : Icons.expand_more,
                color: tone.onContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Where the chosen account sits: its parents, each a step back to it.
  Widget _pathBar() {
    final chosen = _byId[_selectedId];
    if (chosen == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final path = _pathOf(chosen);
    return Container(
      key: const Key('accounts-path'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (k, a) in path.indexed) ...[
                    if (k > 0)
                      Icon(
                        Icons.chevron_left,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    TextButton(
                      onPressed: () => _locate(a),
                      child: Text(
                        (a['name'] ?? '').toString(),
                        style: k == path.length - 1
                            ? const TextStyle(fontWeight: FontWeight.w800)
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'إلغاء الاختيار',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _selectedId = null),
          ),
        ],
      ),
    );
  }

  /// The account in the tree: the search cleared, its parents and section
  /// opened, chosen, and scrolled to (CHART-UI-2).
  void _locate(Map<String, dynamic> account) {
    final collapsed = _collapsed ??= <int>{};
    for (final a in _pathOf(account)) {
      if (a != account) collapsed.remove(_asInt(a['id']));
    }
    _foldedSections.remove(_sectionOf(account));
    setState(() => _selectedId = _asInt(account['id']));
    if (_searchController.text.isNotEmpty) _searchController.clear();
    if (_mode != _AccountsViewMode.tree) _setViewMode(_AccountsViewMode.tree);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _listController;
      if (!mounted || controller == null || !controller.hasClients) return;
      final at = _entries(asTree: true).indexWhere(
        (e) => e.account != null && _asInt(e.account!['id']) == _selectedId,
      );
      if (at < 0) return;
      final position = controller.position;
      controller.jumpTo(
        (at * _rowExtent - 2 * _rowExtent).clamp(0.0, position.maxScrollExtent),
      );
    });
  }

  Widget _compactHeader() {
    final theme = Theme.of(context);
    TextStyle? head() =>
        theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('الحساب', style: head())),
          Expanded(
            flex: 3,
            child: Text('الرصيد', textAlign: TextAlign.end, style: head()),
          ),
          SizedBox(width: 88 + (_wide ? 120 : 0)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            _activeFiltersCount > 0
                ? 'لا توجد حسابات مطابقة'
                : 'لا توجد حسابات للعرض',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'جرّب تعديل البحث أو إزالة بعض الفلاتر الحالية',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  /// The accounts of a section as the tree shows them: every filter but the
  /// search and «فرعية فقط» (the tree is the parents), a parent kept for a
  /// kept child.
  List<AccountTreeRow> _treeRows(String section) => accountTreeRows(
    _allAccounts,
    collapsed: _collapsed ?? const <int>{},
    include: (account) {
      if (_sectionOf(account) != section) return false;
      if (_onlyWithBalance && !_hasAnyBalance(account)) return false;
      if (_onlyWeightAccounts && !_tracksWeight(account)) return false;
      return _ofType(account);
    },
  );

  /// What the list shows: each section's head, then its accounts -- the
  /// financial chart, then the weight chart (CHART-UI-2).
  List<_Entry> _entries({required bool asTree}) {
    final out = <_Entry>[];
    for (final section in _sections) {
      final rows = asTree
          ? [for (final r in _treeRows(section)) _Entry(section, r.account, r)]
          : [
              for (final a in _filteredAccounts)
                if (_sectionOf(a) == section) _Entry(section, a),
            ];
      if (rows.isEmpty) continue;
      out.add(_Entry(section));
      if (!_foldedSections.contains(section)) out.addAll(rows);
    }
    return out;
  }

  Widget _buildBody(_AccountsViewMode mode) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _allAccounts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            key: const Key('accounts-load-error'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'تعذر تحميل الحسابات',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _fetchAccounts,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    // A search lists its matches flat, each with its parent named: a tree of
    // matches would bury them under their ancestors.
    final searching = _searchController.text.trim().isNotEmpty;
    final asTree = mode == _AccountsViewMode.tree && !searching;
    final entries = _entries(asTree: asTree);
    if (entries.isEmpty) return _buildEmptyState();

    if (mode == _AccountsViewMode.cards) {
      return RefreshIndicator(
        onRefresh: _fetchAccounts,
        child: ListView.builder(
          primary: true,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final e = entries[index];
            if (e.account == null) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(height: 52, child: _sectionHeader(e.section)),
                ),
              );
            }
            return KeyedSubtree(
              key: Key('account-row-${e.account!['id']}'),
              child: _buildAccountCard(e.account!),
            );
          },
        ),
      );
    }

    return Column(
      children: [
        if (asTree) _pathBar(),
        Expanded(
          child: _framedList(
            itemCount: entries.length,
            itemBuilder: (i) {
              final e = entries[i];
              if (e.account == null) return _sectionHeader(e.section);
              return _buildCompactRow(e.account!, tree: e.tree);
            },
          ),
        ),
      ],
    );
  }

  /// The compact table: a header, then rows built as they scroll into view --
  /// it built all 456 at once.
  Widget _framedList({
    required int itemCount,
    required Widget Function(int) itemBuilder,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            _compactHeader(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _fetchAccounts,
                child: Builder(
                  builder: (context) {
                    _listController = PrimaryScrollController.maybeOf(context);
                    return ListView.builder(
                      primary: true,
                      itemExtent: _rowExtent,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => itemBuilder(index),
                    );
                  },
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
    context.watch<SettingsProvider>();

    return LayoutBuilder(
      builder: (context, constraints) {
        final mode = _effectiveViewMode(constraints.maxWidth);
        _mode = mode;
        return Scaffold(
          appBar: AppBar(
            title: const Text('دليل الحسابات'),
            actions: [
              PopupMenuButton<String>(
                key: const Key('accounts-chart-actions'),
                tooltip: 'إدارة الحسابات',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'add_root') {
                    _manage(
                      showAccountForm(
                        context,
                        api: _api,
                        accounts: _allAccounts,
                      ),
                    );
                  } else if (value == 'export') {
                    exportAccountsFlow(context, api: _api);
                  } else if (value == 'import') {
                    _manage(importAccountsFlow(context, api: _api));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'add_root',
                    child: Text('إضافة حساب رئيسي'),
                  ),
                  PopupMenuItem(value: 'export', child: Text('تصدير الشجرة')),
                  PopupMenuItem(value: 'import', child: Text('استيراد شجرة')),
                ],
              ),
              PopupMenuButton<_AccountsViewMode>(
                key: const Key('accounts-view-mode'),
                tooltip: 'طريقة العرض',
                icon: Icon(switch (mode) {
                  _AccountsViewMode.cards => Icons.view_agenda_outlined,
                  _AccountsViewMode.compact => Icons.table_rows_outlined,
                  _AccountsViewMode.tree => Icons.account_tree_outlined,
                }),
                initialValue: mode,
                onSelected: _setViewMode,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _AccountsViewMode.compact,
                    child: Text('عرض مضغوط'),
                  ),
                  PopupMenuItem(
                    value: _AccountsViewMode.tree,
                    child: Text('عرض شجري'),
                  ),
                  PopupMenuItem(
                    value: _AccountsViewMode.cards,
                    child: Text('بطاقات'),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'تحديث',
                icon: const Icon(Icons.refresh),
                onPressed: _fetchAccounts,
              ),
            ],
          ),
          // One scroll (10 Oct 2026): the summary is the page's head and scrolls
          // away, the toolbar heads the list -- the screen rebuilt itself on
          // every pixel of scrolling to fold the summary by hand.
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _buildStatisticsSection(),
                ),
              ),
            ],
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _buildManagementToolbar(mode),
                ),
                Expanded(child: _buildBody(mode)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One line of the list: a section's head (no account), or an account.
class _Entry {
  const _Entry(this.section, [this.account, this.tree]);
  final String section;
  final Map<String, dynamic>? account;
  final AccountTreeRow? tree;
}

/// The tree's guide lines: one down each level above a row, and an elbow
/// into the row itself (the old tree's, CHART-UI-2).
class _TreeLines extends CustomPainter {
  _TreeLines({
    required this.depth,
    required this.indent,
    required this.color,
    required this.rtl,
  });
  final int depth;
  final double indent;
  final Color color;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    double x(double fromStart) => rtl ? size.width - fromStart : fromStart;
    for (var i = 0; i < depth; i++) {
      final at = 14 + i * indent + 16;
      final last = i == depth - 1;
      canvas.drawLine(
        Offset(x(at), 0),
        Offset(x(at), last ? size.height / 2 : size.height),
        paint,
      );
      if (last) {
        canvas.drawLine(
          Offset(x(at), size.height / 2),
          Offset(x(at + 14), size.height / 2),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TreeLines old) =>
      old.indent != indent ||
      old.depth != depth ||
      old.color != color ||
      old.rtl != rtl;
}
