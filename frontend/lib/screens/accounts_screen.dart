import 'package:flutter/material.dart';
import '../api_service.dart';
import 'account_statement_screen.dart';
import 'account_ledger_screen.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<dynamic> _allAccounts = [];
  List<dynamic> _filteredAccounts = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  bool _onlyDetailAccounts = false;
  bool _onlyWithBalance = false;

  @override
  void initState() {
    super.initState();
    _fetchAccounts();
    _searchController.addListener(_filterAccounts);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAccounts() async {
    setState(() => _isLoading = true);
    try {
      final allAccounts = await ApiService().getAccounts();
      setState(() {
        _allAccounts = allAccounts;
        _filterAccounts();
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load accounts: $e')));
    }
  }

  void _filterAccounts() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredAccounts = _allAccounts
          .where((account) {
            final name = account['name']?.toLowerCase() ?? '';
            final accountNumber =
                account['account_number']?.toLowerCase() ?? '';
            return name.contains(query) || accountNumber.contains(query);
          })
          .where((account) {
            final subAccounts = account['sub_accounts'] as List?;
            final hasChildren = subAccounts != null && subAccounts.isNotEmpty;

            if (_onlyDetailAccounts && hasChildren) {
              return false;
            }

            if (_onlyWithBalance) {
              final balances = account['balances'] as Map<String, dynamic>?;
              final cashBalance = balances?['cash'];
              final weight = balances?['weight'] as Map<String, dynamic>?;
              final weightTotal = weight?['total'];
              final hasCash = cashBalance is num && cashBalance.abs() > 0.01;
              final hasGold = weightTotal is num && weightTotal.abs() > 0.001;
              if (!hasCash && !hasGold) {
                return false;
              }
            }

            return true;
          })
          .toList();

      // Keep accounts with children grouped directly under the parent first to reduce duplicates in the list view.
      _filteredAccounts.sort((a, b) {
        final aHasChildren = (a['sub_accounts'] as List?)?.isNotEmpty ?? false;
        final bHasChildren = (b['sub_accounts'] as List?)?.isNotEmpty ?? false;
        if (aHasChildren == bHasChildren) {
          return (a['name'] ?? '').toString().compareTo(
            (b['name'] ?? '').toString(),
          );
        }
        return aHasChildren ? -1 : 1;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('حسابات العملاء'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'تصفية النتائج',
            onPressed: _showFilterSheet,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56.0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'بحث بالاسم أو رقم الحساب...',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: theme.scaffoldBackgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: theme.dividerColor),
                ),
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchAccounts,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_onlyDetailAccounts || _onlyWithBalance)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_onlyDetailAccounts)
                            InputChip(
                              avatar: const Icon(Icons.account_tree, size: 18),
                              label: const Text('حسابات فرعية فقط'),
                              onDeleted: () {
                                setState(() {
                                  _onlyDetailAccounts = false;
                                  _filterAccounts();
                                });
                              },
                            ),
                          if (_onlyWithBalance)
                            InputChip(
                              avatar: const Icon(
                                Icons.account_balance_wallet,
                                size: 18,
                              ),
                              label: const Text('الحسابات ذات الرصيد'),
                              onDeleted: () {
                                setState(() {
                                  _onlyWithBalance = false;
                                  _filterAccounts();
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                  if (_filteredAccounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 120),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.search_off,
                            size: 64,
                            color: Colors.grey.shade500,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'لا توجد حسابات مطابقة',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ..._filteredAccounts.map(
                      (account) => _buildAccountTile(
                        account as Map<String, dynamic>,
                        theme,
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
    );
  }

  Widget _buildAccountTile(Map<String, dynamic> account, ThemeData theme) {
    final parent = account['parent_account'] as Map<String, dynamic>?;
    final balances = account['balances'] as Map<String, dynamic>?;
    final tracksWeight = account['tracks_weight'] == true;

    String subtitle = 'رقم الحساب: ${account['account_number'] ?? ''}';
    if (parent != null) {
      subtitle +=
          '\nحساب رئيسي: ${parent['name'] ?? parent['account_number'] ?? ''}';
    }
    if ((account['type'] ?? '').toString().isNotEmpty) {
      subtitle += '\nالتصنيف: ${account['type']}';
    }

    String trailingText = '';
    if (balances != null) {
      final cashBalance = balances['cash'];
      if (cashBalance is num && cashBalance.abs() > 0.01) {
        trailingText += 'نقد: ${cashBalance.toStringAsFixed(2)}';
      }

      final weight = balances['weight'] as Map<String, dynamic>?;
      if (weight != null) {
        final weightTotal = weight['total'];
        if (weightTotal is num && weightTotal.abs() > 0.001) {
          if (trailingText.isNotEmpty) {
            trailingText += '\n';
          }
          trailingText += 'ذهب: ${weightTotal.toStringAsFixed(3)} جم';
        }
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
          child: Icon(
            tracksWeight ? Icons.scale : Icons.account_balance_wallet,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          account['name'] ?? 'N/A',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(subtitle),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (trailingText.isNotEmpty)
              Text(
                trailingText,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.book, size: 18),
                  tooltip: 'دفتر الأستاذ',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AccountLedgerScreen(
                          accountId: account['id'] as int,
                          accountName: account['name'] ?? 'N/A',
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_ios, size: 14),
              ],
            ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AccountStatementScreen(
                accountId: account['id'] as int,
                accountName: account['name'] ?? 'N/A',
              ),
            ),
          );
        },
      ),
    );
  }

  void _showFilterSheet() {
    bool tempOnlyDetail = _onlyDetailAccounts;
    bool tempOnlyWithBalance = _onlyWithBalance;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.filter_alt, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'خيارات التصفية',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            setModalState(() {
                              tempOnlyDetail = false;
                              tempOnlyWithBalance = false;
                            });
                          },
                          child: const Text('إعادة تعيين'),
                        ),
                      ],
                    ),
                    const Divider(),
                    SwitchListTile.adaptive(
                      value: tempOnlyDetail,
                      title: const Text('عرض الحسابات الفرعية فقط'),
                      subtitle: const Text(
                        'إخفاء الحسابات الرئيسية التي تحتوي على حسابات فرعية',
                      ),
                      onChanged: (value) {
                        setModalState(() => tempOnlyDetail = value);
                      },
                    ),
                    SwitchListTile.adaptive(
                      value: tempOnlyWithBalance,
                      title: const Text('عرض الحسابات ذات الرصيد فقط'),
                      subtitle: const Text(
                        'إخفاء الحسابات التي أرصدتها صفرية نقداً وذهباً',
                      ),
                      onChanged: (value) {
                        setModalState(() => tempOnlyWithBalance = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          setState(() {
                            _onlyDetailAccounts = tempOnlyDetail;
                            _onlyWithBalance = tempOnlyWithBalance;
                            _filterAccounts();
                          });
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('تطبيق التصفية'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
