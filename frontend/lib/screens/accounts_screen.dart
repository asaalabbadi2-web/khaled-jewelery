import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
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

enum _AccountsViewMode { cards, compact, tree }

class AccountsScreen extends StatefulWidget {
  final bool initialOnlyDetailAccounts;

  /// The server; tests pass a fake.
  final ApiService? apiService;

  const AccountsScreen({super.key, this.initialOnlyDetailAccounts = false, this.apiService});

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
  final Set<int> _absorbedMemoIds = {};
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
    super.dispose();
  }

  Future<void> _restoreViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_viewModeKey);
      final mode = _AccountsViewMode.values.where((m) => m.name == saved).firstOrNull;
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
      _viewMode ?? (width >= 900 ? _AccountsViewMode.compact : _AccountsViewMode.cards);

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

  /// When a leaf account has a linked memo/weight account
  /// (Account.memo_account_id) that is itself a leaf (category-level nodes
  /// also carry memo_account_id, e.g. root "2 - الخصوم" <-> root "72 -
  /// الخصوم وزني", but those always show a zero balance of their own so
  /// there's nothing useful to merge there), folds the memo account's
  /// weight balance, name/number, and own map into the financial account's
  /// map for the combined summary and the quick-jump ⚖️ shortcut, and
  /// records the memo account's id in [_absorbedMemoIds] so _filterAccounts
  /// can drop its now-redundant standalone card from the list (its balance
  /// is already shown on the financial account's card). The memo account
  /// still surfaces normally when "وزنية فقط" is active, since that filter
  /// is an explicit ask to see weight accounts specifically.
  ///
  /// Note: tapping the ⚖️ shortcut (or "كشف الحساب" on the financial card)
  /// opens AccountStatementScreen, which has its own دمج/ذهبي/نقدي toggle
  /// (_viewMode in account_statement_screen.dart) -- so the single merged
  /// card loses no access to either breakdown. The backend's
  /// get_account_statement may also auto-return a merged cash+gold
  /// statement (is_merged: true) for either id -- see the NOTE in
  /// routes.py's get_account_statement. Intentional, not a bug.
  List<Map<String, dynamic>> _annotateMemoLinks(
    List<Map<String, dynamic>> accounts,
  ) {
    // Rebuilt fresh each call (_fetchAccounts can re-run via pull-to-refresh
    // or the refresh button), so stale ids from a previous load never stick.
    _absorbedMemoIds.clear();
    final byId = <int, Map<String, dynamic>>{};
    for (final acc in accounts) {
      final id = _asInt(acc['id']);
      if (id != null) byId[id] = acc;
    }
    final hasChildren = <int>{};
    for (final acc in accounts) {
      final parentId = _asInt(acc['parent_id']);
      if (parentId != null) hasChildren.add(parentId);
    }

    for (final acc in accounts) {
      final id = _asInt(acc['id']);
      if (id == null || acc['tracks_weight'] == true) continue;
      if (hasChildren.contains(id)) continue;
      final memoId = _asInt(acc['memo_account_id']);
      if (memoId == null) continue;
      final memoAccount = byId[memoId];
      if (memoAccount == null || memoAccount['tracks_weight'] != true) {
        continue;
      }
      if (hasChildren.contains(memoId)) continue;

      acc['_merged_weight_total'] = _goldBalanceOf(memoAccount);
      acc['_merged_memo_name'] = (memoAccount['name'] ?? '').toString();
      acc['_merged_memo_number'] = (memoAccount['account_number'] ?? '')
          .toString();
      acc['_merged_memo_account'] = memoAccount;
      _absorbedMemoIds.add(memoId);
    }

    return accounts;
  }

  bool _effectivelyTracksWeight(Map<String, dynamic> account) {
    return _tracksWeight(account) || account['_merged_weight_total'] != null;
  }

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

  String _goldText(double value) => '${_goldFormat.format(value.abs())} جم${_side(value, epsilon: 0.0005)}';

  /// Gold is shown where it belongs: a weight account, or any with gold on it
  /// -- a cash account's «0 جم» was noise.
  bool _showsGold(Map<String, dynamic> account, double gold) =>
      _effectivelyTracksWeight(account) || gold.abs() >= 0.0005;

  int _childCount(Map<String, dynamic> account) =>
      ((account['sub_accounts'] as List?) ?? const []).length;

  bool _hasChildren(Map<String, dynamic> account) {
    final subAccounts = account['sub_accounts'] as List?;
    return subAccounts != null && subAccounts.isNotEmpty;
  }

  bool _tracksWeight(Map<String, dynamic> account) =>
      account['tracks_weight'] == true;

  double _cashBalanceOf(Map<String, dynamic> account) {
    return _asDouble(_balancesOf(account)?['cash']);
  }

  double _goldBalanceOf(Map<String, dynamic> account) {
    final mergedWeight = account['_merged_weight_total'];
    if (mergedWeight is double) {
      return mergedWeight;
    }
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
    return type.isEmpty ? 'غير مصنف' : type;
  }

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
          final memoName = normalizeForSearch((account['_merged_memo_name'] ?? '').toString());
          final memoNumber = normalizeForSearch((account['_merged_memo_number'] ?? '').toString());

          final matchesQuery =
              query.isEmpty ||
              name.contains(query) ||
              accountNumber.contains(query) ||
              type.contains(query) ||
              parent.contains(query) ||
              memoName.contains(query) ||
              memoNumber.contains(query);

          if (!matchesQuery) {
            return false;
          }
          if (!_onlyWeightAccounts) {
            final id = _asInt(account['id']);
            if (id != null && _absorbedMemoIds.contains(id)) {
              return false;
            }
          }
          if (_onlyDetailAccounts && _hasChildren(account)) {
            return false;
          }
          if (_onlyWithBalance && !_hasAnyBalance(account)) {
            return false;
          }
          if (_onlyWeightAccounts && !_effectivelyTracksWeight(account)) {
            return false;
          }
          return true;
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
    // The order is how they are listed, not which: not a filter.
    return count;
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
    final totalAccounts = _filteredAccounts.length;
    final detailAccounts = _filteredAccounts
        .where((account) => !_hasChildren(account))
        .length;
    final weightAccounts = _filteredAccounts
        .where(_effectivelyTracksWeight)
        .length;
    final withBalance = _filteredAccounts.where(_hasAnyBalance).length;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _buildSummaryCard(
          title: 'الحسابات المطابقة',
          value: '$totalAccounts',
          subtitle: 'بعد الفلاتر الحالية',
          icon: Icons.account_balance_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        _buildSummaryCard(
          title: 'حسابات فرعية',
          value: '$detailAccounts',
          subtitle: 'جاهزة للكشوف والحركة',
          icon: Icons.account_tree_outlined,
          color: Theme.of(context).colorScheme.tertiary,
        ),
        _buildSummaryCard(
          title: 'حسابات برصيد',
          value: '$withBalance',
          subtitle: 'نقدي أو وزني',
          icon: Icons.account_balance_wallet_outlined,
          color: AppSemanticColors.of(context).cash.fg,
        ),
        _buildSummaryCard(
          title: 'حسابات وزنية',
          value: '$weightAccounts',
          subtitle: 'تتعقب الذهب أو الوزن',
          icon: Icons.scale_outlined,
          color: AppSemanticColors.of(context).gold.fg,
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
                  'النتائج: ${_filteredAccounts.length}',
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
    final cashBalance = _cashBalanceOf(account);
    final goldBalance = _goldBalanceOf(account);
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
                      _effectivelyTracksWeight(account)
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
                    onSelected: (value) {
                      if (value == 'statement') {
                        _openStatement(account);
                      } else if (value == 'ledger') {
                        _openLedger(account);
                      } else if (value == 'copy') {
                        _copyAccountNumber(account);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'statement',
                        child: Text('كشف الحساب'),
                      ),
                      PopupMenuItem(
                        value: 'ledger',
                        child: Text('دفتر الأستاذ'),
                      ),
                      PopupMenuItem(
                        value: 'copy',
                        child: Text('نسخ رقم الحساب'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_tracksWeight(account))
                    Chip(
                      avatar: const Icon(Icons.scale_outlined, size: 16),
                      label: const Text('وزني'),
                    ),
                  if (account['_merged_memo_account'] != null)
                    Tooltip(
                      message: 'عرض كشف الحساب الوزني المرتبط',
                      child: ActionChip(
                        avatar: const Icon(Icons.scale_outlined, size: 16),
                        label: Text(
                          'وزني مرتبط: ${account['_merged_memo_number']}',
                        ),
                        onPressed: () => _openStatement(
                          account['_merged_memo_account']
                              as Map<String, dynamic>,
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
                  Expanded(
                    child: _buildBalanceTile(
                      icon: Icons.payments_outlined,
                      label: 'الرصيد النقدي',
                      value: _cashText(cashBalance),
                      color: AppSemanticColors.of(context).cash.fg,
                    ),
                  ),
                  if (_showsGold(account, goldBalance)) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildBalanceTile(
                        icon: Icons.auto_awesome_outlined,
                        label: 'الرصيد الذهبي',
                        value: _goldText(goldBalance),
                        color: AppSemanticColors.of(context).gold.fg,
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

  Widget _buildCompactRow(Map<String, dynamic> account, {AccountTreeRow? tree}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final cashBalance = _cashBalanceOf(account);
    final goldBalance = _goldBalanceOf(account);
    final id = _asInt(account['id']);

    return Material(
      color: colorScheme.surface,
      child: InkWell(
        onTap: () => _openStatement(account),
        child: Container(
          padding: EdgeInsetsDirectional.only(
              start: 14 + (tree?.depth ?? 0) * 20.0, end: 6, top: 10, bottom: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colorScheme.outline.withValues(alpha: 0.1))),
          ),
          child: Row(
            children: [
              if (tree != null)
                SizedBox(
                  width: 32,
                  child: tree.hasChildren
                      ? IconButton(
                          key: Key('account-fold-$id'),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          tooltip: tree.expanded ? 'طيّ' : 'فتح',
                          icon: Icon(tree.expanded ? Icons.expand_more : Icons.chevron_left, size: 20),
                          onPressed: () => setState(() {
                            final collapsed = _collapsed ??= <int>{};
                            if (id == null) return;
                            collapsed.contains(id) ? collapsed.remove(id) : collapsed.add(id);
                          }),
                        )
                      : const SizedBox.shrink(),
                ),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (account['name'] ?? 'N/A').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: tree != null && tree.hasChildren ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_accountNumber(account)} • ${_accountTypeLabel(account)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: cu.SarAwareText(
                  _cashText(cashBalance),
                  isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: tones.cash.fg),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Text(
                  _showsGold(account, goldBalance) ? _goldText(goldBalance) : '',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: tones.gold.fg),
                ),
              ),
              SizedBox(
                width: 40,
                child: account['_merged_memo_account'] != null
                    ? IconButton(
                        tooltip: 'عرض كشف الحساب الوزني المرتبط',
                        icon: Icon(Icons.scale_outlined, size: 18, color: colorScheme.secondary),
                        onPressed: () => _openStatement(account['_merged_memo_account'] as Map<String, dynamic>),
                      )
                    : null,
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'statement') {
                    _openStatement(account);
                  } else if (value == 'ledger') {
                    _openLedger(account);
                  } else if (value == 'copy') {
                    _copyAccountNumber(account);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'statement', child: Text('كشف الحساب')),
                  PopupMenuItem(value: 'ledger', child: Text('دفتر الأستاذ')),
                  PopupMenuItem(value: 'copy', child: Text('نسخ رقم الحساب')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactHeader() {
    final theme = Theme.of(context);
    TextStyle? head() => theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('الحساب', style: head())),
          Expanded(flex: 2, child: Text('نقد', textAlign: TextAlign.end, style: head())),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: Text('ذهب', textAlign: TextAlign.end, style: head())),
          const SizedBox(width: 88),
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

  /// The accounts as the tree shows them: every filter but the search and
  /// «فرعية فقط» (the tree is the parents), a parent kept for a kept child.
  List<AccountTreeRow> _treeRows() => accountTreeRows(
        _allAccounts,
        collapsed: _collapsed ?? const <int>{},
        include: (account) {
          final id = _asInt(account['id']);
          if (!_onlyWeightAccounts && id != null && _absorbedMemoIds.contains(id)) return false;
          if (_onlyWithBalance && !_hasAnyBalance(account)) return false;
          if (_onlyWeightAccounts && !_effectivelyTracksWeight(account)) return false;
          return true;
        },
      );

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
              Text('تعذر تحميل الحسابات', style: Theme.of(context).textTheme.titleMedium),
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
    if (mode == _AccountsViewMode.tree && !searching) {
      final rows = _treeRows();
      if (rows.isEmpty) return _buildEmptyState();
      return _framedList(
        itemCount: rows.length,
        itemBuilder: (i) => _buildCompactRow(rows[i].account, tree: rows[i]),
      );
    }

    if (_filteredAccounts.isEmpty) {
      return _buildEmptyState();
    }

    if (mode == _AccountsViewMode.cards) {
      return RefreshIndicator(
        onRefresh: _fetchAccounts,
        child: ListView.builder(
          primary: true,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          itemCount: _filteredAccounts.length,
          itemBuilder: (context, index) => _buildAccountCard(_filteredAccounts[index]),
        ),
      );
    }

    return _framedList(
      itemCount: _filteredAccounts.length,
      itemBuilder: (i) => _buildCompactRow(_filteredAccounts[i]),
    );
  }

  /// The compact table: a header, then rows built as they scroll into view --
  /// it built all 456 at once.
  Widget _framedList({required int itemCount, required Widget Function(int) itemBuilder}) {
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
                child: ListView.builder(
                  primary: true,
                  itemCount: itemCount,
                  itemBuilder: (context, index) => itemBuilder(index),
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

    return LayoutBuilder(builder: (context, constraints) {
      final mode = _effectiveViewMode(constraints.maxWidth);
      return Scaffold(
        appBar: AppBar(
          title: const Text('كشوفات الحسابات'),
          actions: [
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
                PopupMenuItem(value: _AccountsViewMode.compact, child: Text('عرض مضغوط')),
                PopupMenuItem(value: _AccountsViewMode.tree, child: Text('شجرة الحسابات')),
                PopupMenuItem(value: _AccountsViewMode.cards, child: Text('بطاقات')),
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
    });
  }
}
