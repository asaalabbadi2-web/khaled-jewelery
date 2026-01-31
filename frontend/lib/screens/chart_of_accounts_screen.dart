import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../web_file_io.dart' as web_io;
import '../utils.dart';
import '../widgets/account_tree_view.dart';
import 'account_statement_screen.dart';

class ChartOfAccountsScreen extends StatefulWidget {
  const ChartOfAccountsScreen({super.key});

  @override
  State<ChartOfAccountsScreen> createState() => _ChartOfAccountsScreenState();
}

enum _TransactionFilterType { all, cash, gold, both }

enum _WeightFilterType { all, weightOnly, nonWeightOnly }

class _ChartOfAccountsScreenState extends State<ChartOfAccountsScreen> {
  List<dynamic> _accounts = [];
  List<AccountNode> _accountTree = [];
  bool _isLoading = true;
  
  // Search and filter state
  late TextEditingController _searchController;
  _TransactionFilterType _txFilter = _TransactionFilterType.all;
  _WeightFilterType _weightFilter = _WeightFilterType.all;
  bool _showFilters = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _fetchAccounts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAccounts() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final accounts = await ApiService().getAccounts();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _accountTree = buildAccountTree(accounts);
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

  void _showAddAccountDialog({Map<String, dynamic>? parentAccount}) {
    _showAccountDialog(parentAccount: parentAccount);
  }

  /// Flatten account tree into a list for filtering/search
  List<Map<String, dynamic>> _flattenAccountTree() {
    final result = <Map<String, dynamic>>[];
    
    void addAccountAndChildren(Map<String, dynamic> account) {
      result.add(account);
      final children = _accounts.where((acc) => acc['parent_id'] == account['id']).toList();
      children.sort((a, b) => (a['account_number'] as String).compareTo(b['account_number'] as String));
      for (final child in children) {
        addAccountAndChildren(child);
      }
    }
    
    // Get all root accounts
    final roots = _accounts.where((acc) => acc['parent_id'] == null).toList();
    roots.sort((a, b) => (a['account_number'] as String).compareTo(b['account_number'] as String));
    
    for (final root in roots) {
      addAccountAndChildren(root);
    }
    
    return result;
  }

  /// Apply search and filter to accounts
  List<Map<String, dynamic>> _applyFilters(String query) {
    final q = query.trim().toLowerCase();
    final flat = _flattenAccountTree();
    final result = <Map<String, dynamic>>[];
    
    for (final acc in flat) {
      // Search filter
      if (q.isNotEmpty) {
        final number = (acc['account_number'] ?? '').toString().toLowerCase();
        final name = (acc['name'] ?? '').toString().toLowerCase();
        final matches = number.contains(q) || name.contains(q);
        if (!matches) continue;
      }
      
      // Transaction type filter
      final txType = (acc['transaction_type'] ?? 'both').toString().toLowerCase();
      switch (_txFilter) {
        case _TransactionFilterType.all:
          break;
        case _TransactionFilterType.cash:
          if (txType != 'cash') continue;
        case _TransactionFilterType.gold:
          if (txType != 'gold') continue;
        case _TransactionFilterType.both:
          if (txType != 'both') continue;
      }
      
      // Weight tracking filter
      final tracksWeight = acc['tracks_weight'] == true;
      switch (_weightFilter) {
        case _WeightFilterType.all:
          break;
        case _WeightFilterType.weightOnly:
          if (!tracksWeight) continue;
        case _WeightFilterType.nonWeightOnly:
          if (tracksWeight) continue;
      }
      
      result.add(acc);
    }
    
    return result;
  }

  bool _isFilterActive() {
    return _searchController.text.trim().isNotEmpty ||
        _txFilter != _TransactionFilterType.all ||
        _weightFilter != _WeightFilterType.all;
  }

  void _clearFilters() {
    if (!mounted) return;
    setState(() {
      _searchController.clear();
      _txFilter = _TransactionFilterType.all;
      _weightFilter = _WeightFilterType.all;
      _showFilters = false;
    });
  }

  void _showEditAccountDialog(Map<String, dynamic> account) {
    _showAccountDialog(editingAccount: account);
  }

  void _deleteAccount(int accountId) {
    // Prevent deletion if account has children
    bool hasChildren = _accounts.any((acc) => acc['parent_id'] == accountId);
    if (hasChildren) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لا يمكن حذف حساب لديه حسابات فرعية.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('تأكيد الحذف'),
        content: Text(
          'هل أنت متأكد من رغبتك في حذف هذا الحساب؟ لا يمكن التراجع عن هذا الإجراء.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await ApiService().deleteAccount(accountId);
                if (!mounted) return;
                Navigator.of(context).pop();
                _fetchAccounts(); // Refresh the tree
              } catch (e) {
                if (!mounted) return;
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to delete account: $e')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text('حذف'),
          ),
        ],
      ),
    );
  }

  void _showAccountDialog({
    Map<String, dynamic>? editingAccount,
    Map<String, dynamic>? parentAccount,
  }) {
    final formKey = GlobalKey<FormState>();
    final bool isEditing = editingAccount != null;

    String name = isEditing ? editingAccount['name'] : '';
    // Inherit type from parent when adding a child, otherwise default
    String type = isEditing
        ? editingAccount['type']
        : (parentAccount != null ? parentAccount['type'] : 'Asset');
    int? parentId = isEditing
        ? editingAccount['parent_id']
        : parentAccount?['id'];

    bool tracksWeight = isEditing
      ? (editingAccount['tracks_weight'] == true)
      : (parentAccount != null ? parentAccount['tracks_weight'] == true : false);

    final accountNumberController = TextEditingController();
    bool isSuggestingNumber = false;

    final Map<String, String> accountTypeTranslations = {
      'Asset': 'أصل',
      'Liability': 'التزام',
      'Equity': 'حقوق ملكية',
      'Revenue': 'إيراد',
      'Expense': 'مصروف',
    };

    Future<void> updateAccountFields(int? pId, StateSetter setState) async {
      parentId = pId;

      if (pId != null) {
        final parentAcc = _accounts.firstWhere((acc) => acc['id'] == pId);
        final parentNumber = normalizeNumber(parentAcc['account_number']);

        // When adding a child, inherit the parent's type
        type = parentAcc['type'];
        // Child accounts always inherit tracks_weight from parent
        tracksWeight = parentAcc['tracks_weight'] == true;

        setState(() {
          isSuggestingNumber = true;
          accountNumberController.text = '';
        });

        try {
          final suggestion = await ApiService().getNextAccountNumber(
            parentNumber,
          );
          final suggestedNumber = normalizeNumber(
            suggestion['suggested_number']?.toString() ?? '',
          );
          if (!mounted) return;
          setState(() {
            accountNumberController.text = suggestedNumber;
          });
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('تعذر اقتراح رقم الحساب: $e')));
        } finally {
          if (!mounted) return;
          setState(() {
            isSuggestingNumber = false;
          });
        }
      } else {
        // Suggest a new top-level account number locally (no parent constraints)
        final rootAccounts = _accounts
            .where((acc) => acc['parent_id'] == null)
            .toList();
        int maxRootNumber = 0;
        for (var root in rootAccounts) {
          final rootNumber =
              int.tryParse(normalizeNumber(root['account_number'])) ?? 0;
          if (rootNumber > maxRootNumber) {
            maxRootNumber = rootNumber;
          }
        }
        setState(() {
          accountNumberController.text = (maxRootNumber + 1).toString();
        });
      }
    }

    if (isEditing) {
      final fullNumber = normalizeNumber(editingAccount['account_number']);
      accountNumberController.text = fullNumber;
    } else {
      // Initial suggestion
      // ignore: discarded_futures
      // (executed inside StatefulBuilder after it mounts)
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            isEditing
                ? 'تعديل الحساب'
                : (parentAccount != null
                      ? 'إضافة حساب فرعي'
                      : 'إضافة حساب رئيسي'),
          ),
          content: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
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
                        decoration: InputDecoration(
                          labelText: 'الحساب الأصلي (اختياري)',
                        ),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text('لا يوجد (حساب رئيسي)'),
                          ),
                          ..._accounts
                              .where(
                                (acc) =>
                                    !isEditing ||
                                    acc['id'] != editingAccount['id'],
                              )
                              .map<DropdownMenuItem<int?>>((account) {
                                return DropdownMenuItem<int?>(
                                  value: account['id'],
                                  child: Text(
                                    '${account['account_number']} - ${account['name']}',
                                  ),
                                );
                              }),
                        ],
                        onChanged: (value) {
                          // ignore: discarded_futures
                          updateAccountFields(value, setState);
                        },
                      ),
                      SizedBox(height: 16),
                      TextFormField(
                        controller: accountNumberController,
                        decoration: InputDecoration(
                          labelText: 'رقم الحساب',
                          suffixIcon: isSuggestingNumber
                              ? Padding(
                                  padding: const EdgeInsets.all(12.0),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          NormalizeNumberFormatter(),
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: (value) => value == null || value.isEmpty
                            ? 'الرجاء إدخال رقم'
                            : null,
                      ),
                      TextFormField(
                        initialValue: name,
                        decoration: InputDecoration(labelText: 'اسم الحساب'),
                        validator: (value) => value == null || value.isEmpty
                            ? 'الرجاء إدخال اسم الحساب'
                            : null,
                        onSaved: (value) => name = value!,
                      ),
                      SizedBox(height: 8),
                      if (parentId == null)
                        DropdownButtonFormField<String>(
                          initialValue: type,
                          decoration: InputDecoration(labelText: 'نوع الحساب'),
                          items: accountTypeTranslations.keys.map((String key) {
                            return DropdownMenuItem<String>(
                              value: key,
                              child: Text(accountTypeTranslations[key]!),
                            );
                          }).toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => type = value);
                            }
                          },
                        ),
                      const SizedBox(height: 8),
                      if (parentId == null)
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          value: tracksWeight,
                          title: const Text('يتتبع الوزن (حساب وزني)'),
                          subtitle: const Text(
                            'يمكن تعديلها يدويًا للحسابات الرئيسية فقط',
                          ),
                          onChanged: (v) => setState(() => tracksWeight = v),
                        )
                      else
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('تتبع الوزن'),
                          subtitle: Text(
                            tracksWeight
                                ? 'يتبع الأب: يتتبع الوزن'
                                : 'يتبع الأب: لا يتتبع الوزن',
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  formKey.currentState!.save();
                  try {
                    final finalAccountNumber = normalizeNumber(
                      accountNumberController.text,
                    );

                    if (parentId != null) {
                      final parentAcc = _accounts.firstWhere(
                        (acc) => acc['id'] == parentId,
                      );
                      final parentNumber = normalizeNumber(
                        parentAcc['account_number'],
                      );
                      final validation = await ApiService()
                          .validateAccountNumber(
                            accountNumber: finalAccountNumber,
                            parentAccountNumber: parentNumber,
                            excludeAccountId: isEditing
                                ? (editingAccount['id'] as int)
                                : null,
                          );
                      if (validation['is_valid'] != true) {
                        final message =
                            validation['message']?.toString() ??
                            'رقم الحساب غير صالح';
                        if (!mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(message)));
                        return;
                      }
                    }
                    final data = {
                      'name': name,
                      'account_number': finalAccountNumber,
                      'type': type,
                      'parent_id': parentId,
                    };

                    if (parentId != null) {
                      final parentAcc = _accounts.firstWhere(
                        (acc) => acc['id'] == parentId,
                      );
                      data['tracks_weight'] = parentAcc['tracks_weight'] == true;
                    } else {
                      data['tracks_weight'] = tracksWeight;
                    }

                    if (isEditing) {
                      await ApiService().updateAccount(
                        editingAccount['id'],
                        data,
                      );
                    } else {
                      await ApiService().addAccount(data);
                    }

                    if (!mounted) return;
                    Navigator.of(context).pop();
                    _fetchAccounts();
                  } catch (e) {
                    if (!mounted) return;
                    Navigator.of(context).pop(); // Close dialog on error
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to save account: $e')),
                    );
                  }
                }
              },
              child: Text(isEditing ? 'حفظ' : 'إضافة'),
            ),
          ],
        );
      },
    ).whenComplete(() {
      accountNumberController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isFilterActive = _isFilterActive();
    final filteredAccounts = isFilterActive ? _applyFilters(_searchController.text) : <Map<String, dynamic>>[];

    return Scaffold(
      appBar: AppBar(
        title: Text('شجرة الحسابات'),
        actions: [
          IconButton(
            tooltip: 'تصدير شجرة الحسابات',
            icon: Icon(Icons.download_outlined),
            onPressed: _onExportAccounts,
          ),
          IconButton(
            tooltip: 'استيراد شجرة الحسابات',
            icon: Icon(Icons.upload_file),
            onPressed: _onImportAccounts,
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchAccounts,
              child: Column(
                children: [
                  // Search field
                  Padding(
                    padding: EdgeInsets.all(12.0),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) {
                        if (!mounted) return;
                        setState(() {});
                      },
                      decoration: InputDecoration(
                        hintText: 'بحث عن حساب (الرقم أو الاسم)',
                        prefixIcon: Icon(Icons.search),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: Icon(Icons.clear),
                                onPressed: () {
                                  if (!mounted) return;
                                  setState(() => _searchController.clear());
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  // Filter toggles and chips
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                    child: Column(
                      children: [
                        // Show/hide filters button
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () {
                              if (!mounted) return;
                              setState(() => _showFilters = !_showFilters);
                            },
                            icon: Icon(Icons.filter_list),
                            label: Text(_showFilters ? 'إخفاء الفلاتر' : 'عرض الفلاتر'),
                          ),
                        ),
                        // Filter chips (shown when _showFilters is true or when a filter is active)
                        if (_showFilters || isFilterActive)
                          Wrap(
                            spacing: 8,
                            children: [
                              // Transaction type chips
                              FilterChip(
                                selected: _txFilter == _TransactionFilterType.cash,
                                label: Text('نقدي'),
                                onSelected: (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    _txFilter = _txFilter == _TransactionFilterType.cash
                                        ? _TransactionFilterType.all
                                        : _TransactionFilterType.cash;
                                  });
                                },
                              ),
                              FilterChip(
                                selected: _txFilter == _TransactionFilterType.gold,
                                label: Text('ذهبي'),
                                onSelected: (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    _txFilter = _txFilter == _TransactionFilterType.gold
                                        ? _TransactionFilterType.all
                                        : _TransactionFilterType.gold;
                                  });
                                },
                              ),
                              FilterChip(
                                selected: _txFilter == _TransactionFilterType.both,
                                label: Text('كلاهما'),
                                onSelected: (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    _txFilter = _txFilter == _TransactionFilterType.both
                                        ? _TransactionFilterType.all
                                        : _TransactionFilterType.both;
                                  });
                                },
                              ),
                              SizedBox(width: double.infinity),
                              // Weight tracking chips
                              FilterChip(
                                selected: _weightFilter == _WeightFilterType.weightOnly,
                                label: Text('يتتبع الوزن فقط'),
                                onSelected: (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    _weightFilter = _weightFilter == _WeightFilterType.weightOnly
                                        ? _WeightFilterType.all
                                        : _WeightFilterType.weightOnly;
                                  });
                                },
                              ),
                              FilterChip(
                                selected: _weightFilter == _WeightFilterType.nonWeightOnly,
                                label: Text('لا يتتبع الوزن فقط'),
                                onSelected: (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    _weightFilter = _weightFilter == _WeightFilterType.nonWeightOnly
                                        ? _WeightFilterType.all
                                        : _WeightFilterType.nonWeightOnly;
                                  });
                                },
                              ),
                              // Clear button
                              if (isFilterActive)
                                FilterChip(
                                  avatar: Icon(Icons.close, size: 18),
                                  label: Text('مسح الفلاتر'),
                                  onSelected: (_) => _clearFilters(),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  // Content: tree view or filtered list
                  Expanded(
                    child: isFilterActive
                        ? _buildFilteredList(filteredAccounts)
                        : AccountTreeView(
                            roots: _accountTree,
                            onEdit: _showEditAccountDialog,
                            onDelete: _deleteAccount,
                            onAddChild: (parentAccount) =>
                                _showAddAccountDialog(parentAccount: parentAccount),
                            onAccountTap: (account) {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => AccountStatementScreen(
                                    accountId: account['id'],
                                    accountName: account['name'] ?? 'N/A',
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddAccountDialog(),
        tooltip: 'إضافة حساب رئيسي',
        child: Icon(Icons.add),
      ),
    );
  }

  /// Build a flat list view of filtered accounts with hover-based context menu
  Widget _buildFilteredList(List<Map<String, dynamic>> accounts) {
    if (accounts.isEmpty) {
      return Center(
        child: Text('لم يتم العثور على حسابات مطابقة'),
      );
    }

    return ListView.builder(
      itemCount: accounts.length,
      itemBuilder: (context, index) {
        final account = accounts[index];
        final txType = (account['transaction_type'] ?? 'both').toString();
        final tracksWeight = account['tracks_weight'] == true;
        
        return ListTile(
          title: Text('${account['account_number']} - ${account['name']}'),
          subtitle: Text(
            '$txType | ${tracksWeight ? 'يتتبع الوزن' : 'لا يتتبع الوزن'}',
          ),
          trailing: PopupMenuButton(
            itemBuilder: (context) => [
              PopupMenuItem(
                child: Text('عرض الحساب'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => AccountStatementScreen(
                        accountId: account['id'],
                        accountName: account['name'] ?? 'N/A',
                      ),
                    ),
                  );
                },
              ),
              PopupMenuItem(
                child: Text('تعديل'),
                onTap: () {
                  _showEditAccountDialog(account);
                },
              ),
              PopupMenuItem(
                child: Text('إضافة حساب فرعي'),
                onTap: () {
                  _showAddAccountDialog(parentAccount: account);
                },
              ),
              PopupMenuItem(
                child: Text('حذف'),
                onTap: () {
                  _deleteAccount(account['id']);
                },
              ),
            ],
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AccountStatementScreen(
                  accountId: account['id'],
                  accountName: account['name'] ?? 'N/A',
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _onExportAccounts() async {
    try {
      final jsonStr = await ApiService().exportAccounts();
      final controller = TextEditingController(text: jsonStr);

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('تصدير شجرة الحسابات'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('يمكنك نسخ محتوى JSON أدناه وحفظه كملف accounts.json'),
                SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(controller.text),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: controller.text));
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('تم نسخ JSON إلى الحافظة')),
                );
              },
              child: Text('نسخ'),
            ),
            if (kIsWeb)
              TextButton(
                onPressed: () {
                  try {
                    web_io.downloadString('accounts.json', controller.text);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('تم تنزيل الملف')));
                  } catch (e) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('فشل التنزيل: $e')));
                  }
                },
                child: Text('تحميل'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر التصدير: $e')));
    }
  }

  Future<void> _onImportAccounts() async {
    final TextEditingController importController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('استيراد شجرة الحسابات'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('الصق هنا محتوى JSON المصدّر ثم اضغط استيراد'),
              SizedBox(height: 8),
              Expanded(
                child: TextField(
                  controller: importController,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: '{"accounts": [...] }',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Web-only: open file picker and fill the text field
              if (kIsWeb) {
                try {
                  final content = await web_io.pickJsonFile();
                  if (content != null) {
                    importController.text = content;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'تم تحميل الملف. يمكنك الآن الضغط على استيراد',
                        ),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('لم يتم اختيار ملف')),
                    );
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('فشل تحميل الملف: $e')),
                  );
                }
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('اختر ملف مدعوم فقط على الويب')),
                );
              }
            },
            child: Text('اختر ملف'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final payload = importController.text.trim();
              if (payload.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('الرجاء لصق محتوى JSON أولاً')),
                );
                return;
              }

              try {
                final res = await ApiService().importAccountsFromJsonString(
                  payload,
                );
                Navigator.of(context).pop(true);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'تم الاستيراد: ${res['created'] ?? 0} إنشاء, ${res['updated'] ?? 0} تحديث',
                    ),
                  ),
                );
                _fetchAccounts();
              } catch (e) {
                Navigator.of(context).pop(false);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('فشل الاستيراد: $e')));
              }
            },
            child: Text('استيراد'),
          ),
        ],
      ),
    );

    if (result == true) {
      // already refreshed inside
    }
  }
}
