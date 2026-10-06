import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';
import '../models/account_node.dart';
import '../providers/accounts_tree_provider.dart';
import '../utils.dart';
import '../web_file_io.dart' as web_io;
import '../widgets/account_toolbar.dart';
import '../widgets/account_tree_node.dart';
import '../widgets/breadcrumb_bar.dart';
import 'account_statement_screen.dart';

class ChartOfAccountsScreen extends StatelessWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AccountsTreeProvider()..load(),
      child: const _ChartOfAccountsView(),
    );
  }
}

// ─── Main view ────────────────────────────────────────────────────────────────

class _ChartOfAccountsView extends StatefulWidget {
  const _ChartOfAccountsView();

  @override
  State<_ChartOfAccountsView> createState() => _ChartOfAccountsViewState();
}

class _ChartOfAccountsViewState extends State<_ChartOfAccountsView> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _openStatement(Map<String, dynamic> account) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AccountStatementScreen(
          accountId: account['id'] as int,
          accountName: account['name']?.toString() ?? 'N/A',
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AccountsTreeProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F4EE),
      appBar: _buildAppBar(context, provider),
      body: provider.loading
          ? const Center(child: CircularProgressIndicator())
          : provider.error != null
              ? _buildError(provider)
              : _buildBody(context, provider),
      floatingActionButton: _buildFAB(provider),
    );
  }

  // ─── AppBar ───────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(
      BuildContext context, AccountsTreeProvider provider) {
    return AppBar(
      backgroundColor: AppColors.goldTone,
      foregroundColor: Colors.white,
      elevation: 1,
      titleSpacing: 12,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'دليل الحسابات',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFamily: 'Cairo',
            ),
          ),
          if (!provider.loading)
            Text(
              '${provider.totalCount} حساب',
              style: const TextStyle(fontSize: 11, fontFamily: 'Cairo'),
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'تصدير',
          icon: const Icon(Icons.download_outlined, size: 20),
          onPressed: () => _onExportAccounts(context),
        ),
        IconButton(
          tooltip: 'استيراد',
          icon: const Icon(Icons.upload_file, size: 20),
          onPressed: () => _onImportAccounts(context, provider),
        ),
        IconButton(
          tooltip: 'تحديث',
          icon: const Icon(Icons.refresh, size: 20),
          onPressed: provider.load,
        ),
      ],
    );
  }

  // ─── Body ─────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, AccountsTreeProvider provider) {
    final cashRoots = provider.filteredCashRoots;
    final goldRoots = provider.filteredGoldRoots;
    final hasResults = cashRoots.isNotEmpty || goldRoots.isNotEmpty;

    return Column(
      children: [
        // Toolbar (search + controls)
        Material(
          elevation: 1,
          color: Colors.white,
          child: AccountToolbar(
            provider: provider,
            searchController: _searchController,
            onExpandAll: provider.expandAll,
            onCollapseAll: provider.collapseAll,
          ),
        ),
        // Breadcrumb
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: BreadcrumbBar(
            selectedNode: provider.selectedNode,
            allRoots: provider.filteredRoots,
            onTap: (node) {
              provider.select(node);
              if (node.isParent) {
                provider.expandTo(node);
              }
            },
          ),
        ),
        // Tree
        Expanded(
          child: RefreshIndicator(
            onRefresh: provider.load,
            child: hasResults
                ? ListView(
                    padding: const EdgeInsets.only(bottom: 80),
                    children: [
                      if (cashRoots.isNotEmpty) ...[
                        _SectionHeader(
                          label: 'الحسابات النقدية (بالريال السعودي)',
                          icon: Icons.account_balance_wallet_outlined,
                          collapsed: provider.cashSectionCollapsed,
                          onToggle: provider.toggleCashSection,
                        ),
                        if (!provider.cashSectionCollapsed)
                          ...cashRoots.asMap().entries.map((e) =>
                              _buildRootNode(
                                  context, provider, e.value, e.key,
                                  e.key == cashRoots.length - 1)),
                      ],
                      if (goldRoots.isNotEmpty) ...[
                        _SectionHeader(
                          label: 'الحسابات الوزنية (بالجرام)',
                          icon: Icons.scale_outlined,
                          collapsed: provider.goldSectionCollapsed,
                          onToggle: provider.toggleGoldSection,
                          gold: true,
                        ),
                        if (!provider.goldSectionCollapsed)
                          ...goldRoots.asMap().entries.map((e) =>
                              _buildRootNode(
                                  context, provider, e.value, e.key,
                                  e.key == goldRoots.length - 1)),
                      ],
                    ],
                  )
                : _buildEmpty(provider),
          ),
        ),
      ],
    );
  }

  Widget _buildRootNode(BuildContext context, AccountsTreeProvider provider,
      AccountNode node, int index, bool isLast) {
    return AccountTreeNodeWidget(
      key: ValueKey(node.id),
      node: node,
      depth: 0,
      parentHasMore: const [],
      isLast: isLast,
      provider: provider,
      onEdit: _showEditAccountDialog,
      onDelete: _deleteAccount,
      onAddChild: (acc) => _showAddAccountDialog(parentAccount: acc),
      onStatement: _openStatement,
      searchQuery: provider.search,
    );
  }

  Widget _buildEmpty(AccountsTreeProvider provider) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(
            provider.search.isNotEmpty
                ? 'لا توجد حسابات مطابقة لـ «${provider.search}»'
                : 'لا توجد حسابات',
            style: const TextStyle(
                color: AppColors.muted, fontFamily: 'Cairo', fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildError(AccountsTreeProvider provider) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.credit),
          const SizedBox(height: 12),
          Text(
            provider.error ?? 'خطأ غير معروف',
            textAlign: TextAlign.center,
            style:
                const TextStyle(color: AppColors.muted, fontFamily: 'Cairo'),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: provider.load,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
          ),
        ],
      ),
    );
  }

  Widget _buildFAB(AccountsTreeProvider provider) {
    return FloatingActionButton(
      onPressed: () => _showAddAccountDialog(),
      tooltip: 'إضافة حساب رئيسي',
      backgroundColor: AppColors.goldTone,
      foregroundColor: Colors.white,
      child: const Icon(Icons.add),
    );
  }

  // ─── Dialog helpers ───────────────────────────────────────────────────────

  void _showAddAccountDialog({Map<String, dynamic>? parentAccount}) {
    _showAccountDialog(parentAccount: parentAccount);
  }

  void _showEditAccountDialog(Map<String, dynamic> account) {
    _showAccountDialog(editingAccount: account);
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  void _deleteAccount(int accountId) {
    final provider = context.read<AccountsTreeProvider>();
    final node = provider.findById(accountId);
    final hasChildren = node != null && node.children.isNotEmpty;

    if (hasChildren) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يمكن حذف حساب لديه حسابات فرعية.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text(
            'هل أنت متأكد من رغبتك في حذف هذا الحساب؟ لا يمكن التراجع عن هذا الإجراء.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.of(context).pop();
              _doDeleteAccount(accountId);
            },
            child: const Text('حذف'),
          ),
        ],
      ),
    );
  }

  Future<void> _doDeleteAccount(int accountId,
      {bool? deleteParallel}) async {
    final provider = context.read<AccountsTreeProvider>();
    try {
      final result = await ApiService()
          .deleteAccount(accountId, deleteParallel: deleteParallel);

      if (result['result'] == 'confirm_required') {
        final parallel = result['parallel_account'] as Map<String, dynamic>;
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('حذف الحساب الموازي'),
            content: Text(
              'الحساب مرتبط بحساب موازي:\n'
              '${parallel['account_number']} — ${parallel['name']}\n\n'
              'هل تريد حذف الاثنين معاً؟',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('إلغاء')),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _doDeleteAccount(accountId, deleteParallel: false);
                },
                child: const Text('حذف هذا فقط'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Navigator.of(context).pop();
                  _doDeleteAccount(accountId, deleteParallel: true);
                },
                child: const Text('حذف الاثنين'),
              ),
            ],
          ),
        );
        return;
      }

      if (!mounted) return;
      provider.load();
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      final msg = raw.startsWith('Exception: ')
          ? raw.substring('Exception: '.length)
          : raw;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red.shade700));
    }
  }

  // ─── Account dialog ───────────────────────────────────────────────────────

  void _showAccountDialog({
    Map<String, dynamic>? editingAccount,
    Map<String, dynamic>? parentAccount,
  }) {
    final provider = context.read<AccountsTreeProvider>();
    // Flatten accounts list from provider's accountsById for dropdowns
    final accounts = provider.accountsById.values.toList()
      ..sort((a, b) {
        final na = (a['account_number'] ?? '').toString();
        final nb = (b['account_number'] ?? '').toString();
        final ia = int.tryParse(na.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final ib = int.tryParse(nb.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return ia.compareTo(ib);
      });

    final formKey = GlobalKey<FormState>();
    final bool isEditing = editingAccount != null;

    String name = isEditing ? editingAccount['name'] : '';
    String type = isEditing
        ? editingAccount['type']
        : (parentAccount != null ? parentAccount['type'] : 'Asset');
    int? parentId =
        isEditing ? editingAccount['parent_id'] : parentAccount?['id'];

    bool createParallel = !isEditing &&
        parentAccount != null &&
        parentAccount['memo_account_id'] != null;
    String? suggestedParallelNumber;
    bool includeInGramProfit =
        isEditing ? (editingAccount['include_in_gram_profit'] == true) : false;

    final accountNumberController = TextEditingController();
    bool isSuggestingNumber = false;

    const accountTypeTranslations = {
      'Asset': 'أصل',
      'Liability': 'التزام',
      'Equity': 'حقوق ملكية',
      'Revenue': 'إيراد',
      'Expense': 'مصروف',
    };

    Future<void> updateAccountFields(int? pId, StateSetter setState) async {
      parentId = pId;
      if (pId != null) {
        final parentAcc = accounts.firstWhere((a) => a['id'] == pId);
        final parentNumber = normalizeNumber(parentAcc['account_number']);
        type = parentAcc['type'];
        setState(() {
          isSuggestingNumber = true;
          accountNumberController.text = '';
        });
        try {
          final suggestion =
              await ApiService().getNextAccountNumber(parentNumber);
          final suggestedNumber = normalizeNumber(
              suggestion['suggested_number']?.toString() ?? '');
          if (!mounted) return;
          setState(() {
            accountNumberController.text = suggestedNumber;
            createParallel = suggestion['parent_has_parallel'] == true;
            suggestedParallelNumber =
                suggestion['suggested_parallel_number']?.toString();
          });
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('تعذر اقتراح رقم الحساب: $e')));
        } finally {
          if (!mounted) return;
          setState(() => isSuggestingNumber = false);
        }
      } else {
        final roots = accounts.where((a) => a['parent_id'] == null).toList();
        int maxRoot = 0;
        for (final r in roots) {
          final n =
              int.tryParse(normalizeNumber(r['account_number'])) ?? 0;
          if (n > maxRoot) maxRoot = n;
        }
        setState(() => accountNumberController.text = (maxRoot + 1).toString());
      }
    }

    if (isEditing) {
      accountNumberController.text =
          normalizeNumber(editingAccount['account_number']);
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isEditing
            ? 'تعديل الحساب'
            : (parentAccount != null
                ? 'إضافة حساب فرعي'
                : 'إضافة حساب رئيسي')),
        content: StatefulBuilder(
          builder: (ctx, setState) {
            if (!isEditing &&
                accountNumberController.text.isEmpty &&
                !isSuggestingNumber) {
              // ignore: discarded_futures
              updateAccountFields(parentId, setState);
            }
            return Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<int?>(
                      initialValue: parentId,
                      decoration:
                          const InputDecoration(labelText: 'الحساب الأصلي (اختياري)'),
                      items: [
                        const DropdownMenuItem<int?>(
                            value: null, child: Text('لا يوجد (حساب رئيسي)')),
                        ...accounts
                            .where((a) =>
                                !isEditing ||
                                a['id'] != editingAccount['id'])
                            .map<DropdownMenuItem<int?>>((a) =>
                                DropdownMenuItem<int?>(
                                  value: a['id'] as int,
                                  child: Text(
                                      '${a['account_number']} - ${a['name']}'),
                                )),
                      ],
                      onChanged: (v) =>
                          // ignore: discarded_futures
                          updateAccountFields(v, setState),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: accountNumberController,
                      decoration: InputDecoration(
                        labelText: 'رقم الحساب',
                        suffixIcon: isSuggestingNumber
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                              )
                            : null,
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        NormalizeNumberFormatter(),
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onChanged: (_) => setState(() {}),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'الرجاء إدخال رقم' : null,
                    ),
                    TextFormField(
                      initialValue: name,
                      decoration:
                          const InputDecoration(labelText: 'اسم الحساب'),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'الرجاء إدخال اسم' : null,
                      onSaved: (v) => name = v!,
                    ),
                    const SizedBox(height: 8),
                    if (parentId == null)
                      DropdownButtonFormField<String>(
                        initialValue: type,
                        decoration:
                            const InputDecoration(labelText: 'نوع الحساب'),
                        items: accountTypeTranslations.keys
                            .map((k) => DropdownMenuItem(
                                value: k,
                                child: Text(accountTypeTranslations[k]!)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => type = v);
                        },
                      ),
                    const SizedBox(height: 4),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: includeInGramProfit,
                      title: const Text('يدخل في تقرير ربح الجرام'),
                      subtitle: const Text(
                          'تفعيل = يُحسب ضمن الربح الوزني (إيراد أو مصروف)'),
                      onChanged: (v) =>
                          setState(() => includeInGramProfit = v),
                    ),
                    if (!isEditing)
                      Builder(builder: (ctx2) {
                        final isMemo =
                            accountNumberController.text.startsWith('7');
                        if (isMemo) return const SizedBox.shrink();
                        return Column(children: [
                          const Divider(height: 24),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            value: createParallel,
                            title: const Text('إنشاء حساب موازي وزني'),
                            subtitle: Text(suggestedParallelNumber != null
                                ? 'الحساب الموازي المقترح: $suggestedParallelNumber'
                                : 'يُنشئ حساباً بالرقم نفسه مسبوقاً بـ 7'),
                            onChanged: (v) =>
                                setState(() => createParallel = v),
                          ),
                        ]);
                      }),
                  ],
                ),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              formKey.currentState!.save();
              try {
                final finalNumber =
                    normalizeNumber(accountNumberController.text);

                if (parentId != null) {
                  final parentAcc =
                      accounts.firstWhere((a) => a['id'] == parentId);
                  final parentNumber =
                      normalizeNumber(parentAcc['account_number']);
                  final validation = await ApiService().validateAccountNumber(
                    accountNumber: finalNumber,
                    parentAccountNumber: parentNumber,
                    excludeAccountId:
                        isEditing ? (editingAccount['id'] as int) : null,
                  );
                  if (validation['is_valid'] != true) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(validation['message']?.toString() ??
                            'رقم الحساب غير صالح')));
                    return;
                  }
                }

                final data = {
                  'name': name,
                  'account_number': finalNumber,
                  'type': type,
                  'parent_id': parentId,
                  'include_in_gram_profit': includeInGramProfit,
                };
                if (!isEditing) data['create_parallel'] = createParallel;

                if (isEditing) {
                  await ApiService()
                      .updateAccount(editingAccount['id'] as int, data);
                } else {
                  await ApiService().addAccount(data);
                }

                if (!mounted) return;
                Navigator.of(context).pop();
                context.read<AccountsTreeProvider>().load();
              } catch (e) {
                if (!mounted) return;
                final raw = e.toString();
                final msg = raw.startsWith('Exception: ')
                    ? raw.substring('Exception: '.length)
                    : raw;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(msg),
                    backgroundColor: Colors.red.shade700));
              }
            },
            child: Text(isEditing ? 'حفظ' : 'إضافة'),
          ),
        ],
      ),
    ).whenComplete(() => accountNumberController.dispose());
  }

  // ─── Export / Import ──────────────────────────────────────────────────────

  Future<void> _onExportAccounts(BuildContext context) async {
    try {
      final jsonStr = await ApiService().exportAccounts();
      final controller = TextEditingController(text: jsonStr);
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('تصدير شجرة الحسابات'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('يمكنك نسخ محتوى JSON أدناه وحفظه كملف'),
                const SizedBox(height: 8),
                Expanded(
                    child: SingleChildScrollView(
                        child: SelectableText(controller.text))),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: controller.text));
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('تم نسخ JSON إلى الحافظة')));
              },
              child: const Text('نسخ'),
            ),
            if (kIsWeb)
              TextButton(
                onPressed: () {
                  try {
                    web_io.downloadString('accounts.json', controller.text);
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('فشل التنزيل: $e')));
                  }
                },
                child: const Text('تحميل'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
      controller.dispose();
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر التصدير: $e')));
    }
  }

  Future<void> _onImportAccounts(
      BuildContext context, AccountsTreeProvider provider) async {
    final importController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('استيراد شجرة الحسابات'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('الصق هنا محتوى JSON المصدّر ثم اضغط استيراد'),
              const SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: importController,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: const InputDecoration(
                    hintText: '{"accounts": [...] }',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (kIsWeb)
            TextButton(
              onPressed: () async {
                try {
                  final content = await web_io.pickJsonFile();
                  if (content != null) {
                    importController.text = content;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'تم تحميل الملف. يمكنك الآن الضغط على استيراد')));
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('فشل تحميل الملف: $e')));
                }
              },
              child: const Text('اختر ملف'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final payload = importController.text.trim();
              if (payload.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('الرجاء لصق محتوى JSON أولاً')));
                return;
              }
              try {
                final res =
                    await ApiService().importAccountsFromJsonString(payload);
                Navigator.of(context).pop(true);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        'تم الاستيراد: ${res['created'] ?? 0} إنشاء, ${res['updated'] ?? 0} تحديث')));
                provider.load();
              } catch (e) {
                Navigator.of(context).pop(false);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('فشل الاستيراد: $e')));
              }
            },
            child: const Text('استيراد'),
          ),
        ],
      ),
    );
    importController.dispose();
    if (result == true) {
      // already refreshed inside
    }
  }
}

// ─── Section header widget ────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool collapsed;
  final VoidCallback onToggle;
  final bool gold;

  const _SectionHeader({
    required this.label,
    required this.icon,
    required this.collapsed,
    required this.onToggle,
    this.gold = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = gold ? AppColors.goldTone : AppColors.debit;
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          border: Border(
            bottom: BorderSide(color: color.withValues(alpha: 0.25)),
            top: BorderSide(color: color.withValues(alpha: 0.10)),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Cairo',
                  color: color,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(Icons.expand_more, size: 16, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
