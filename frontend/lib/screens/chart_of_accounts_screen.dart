import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../utils.dart';
import '../widgets/account_tree_view.dart';
import 'account_statement_screen.dart';

class ChartOfAccountsScreen extends StatefulWidget {
  const ChartOfAccountsScreen({Key? key}) : super(key: key);

  @override
  _ChartOfAccountsScreenState createState() => _ChartOfAccountsScreenState();
}

class _ChartOfAccountsScreenState extends State<ChartOfAccountsScreen> {
  List<dynamic> _accounts = [];
  List<AccountNode> _accountTree = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAccounts();
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
            child: Text('حذف'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          ),
        ],
      ),
    );
  }

  void _showAccountDialog({
    Map<String, dynamic>? editingAccount,
    Map<String, dynamic>? parentAccount,
  }) {
    final _formKey = GlobalKey<FormState>();
    final bool isEditing = editingAccount != null;

    String name = isEditing ? editingAccount['name'] : '';
    // Inherit type from parent when adding a child, otherwise default
    String type = isEditing
        ? editingAccount['type']
        : (parentAccount != null ? parentAccount['type'] : 'Asset');
    int? parentId = isEditing
        ? editingAccount['parent_id']
        : parentAccount?['id'];

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
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<int?>(
                        value: parentId,
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
                              })
                              .toList(),
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
                          value: type,
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
                if (_formKey.currentState!.validate()) {
                  _formKey.currentState!.save();
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
              child: AccountTreeView(
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
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            _showAddAccountDialog(), // No parent, adds a root account
        child: Icon(Icons.add),
        tooltip: 'إضافة حساب رئيسي',
      ),
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
                    SnackBar(content: Text('تم نسخ JSON إلى الحافظة')));
              },
              child: Text('نسخ'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر التصدير: $e')));
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
                    hintText: '{\"accounts\": [...] }',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () async {
              final payload = importController.text.trim();
              if (payload.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('الرجاء لصق محتوى JSON أولاً')));
                return;
              }

              try {
                final res = await ApiService()
                    .importAccountsFromJsonString(payload);
                Navigator.of(context).pop(true);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('تم الاستيراد: ${res['created'] ?? 0} إنشاء, ${res['updated'] ?? 0} تحديث')));
                _fetchAccounts();
              } catch (e) {
                Navigator.of(context).pop(false);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('فشل الاستيراد: $e')));
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
