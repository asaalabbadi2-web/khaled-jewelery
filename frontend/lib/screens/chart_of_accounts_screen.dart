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
    // Add state for the new transaction type field
    String transactionType = isEditing
        ? editingAccount['transaction_type'] ?? 'both'
        : 'both';

    final accNumController = TextEditingController();
    final originalAccNumController = TextEditingController();

    final Map<String, String> accountTypeTranslations = {
      'Asset': 'أصل',
      'Liability': 'التزام',
      'Equity': 'حقوق ملكية',
      'Revenue': 'إيراد',
      'Expense': 'مصروف',
    };

    void updateAccountFields(int? pId) {
      parentId = pId;
      if (pId != null) {
        final parentAcc = _accounts.firstWhere((acc) => acc['id'] == pId);
        final parentNumber = normalizeNumber(parentAcc['account_number']);
        originalAccNumController.text = parentNumber;

        // Suggest new number only when adding a new account or re-parenting an existing one
        final children = _accounts
            .where((acc) => acc['parent_id'] == pId)
            .toList();
        if (children.isEmpty) {
          accNumController.text = '1';
        } else {
          int maxChildSuffix = 0;
          for (var child in children) {
            final childNumber = normalizeNumber(child['account_number']);
            if (childNumber.startsWith(parentNumber)) {
              final suffix = childNumber.substring(parentNumber.length);
              final suffixInt = int.tryParse(suffix) ?? 0;
              if (suffixInt > maxChildSuffix) {
                maxChildSuffix = suffixInt;
              }
            }
          }
          accNumController.text = (maxChildSuffix + 1).toString();
        }
        // When adding a child, inherit the parent's type
        type = parentAcc['type'];
      } else {
        originalAccNumController.text = '';
        // Suggest a new top-level account number
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
        accNumController.text = (maxRootNumber + 1).toString();
      }
    }

    if (isEditing) {
      final fullNumber = normalizeNumber(editingAccount['account_number']);
      if (parentId != null) {
        try {
          final parent = _accounts.firstWhere((acc) => acc['id'] == parentId);
          final parentNumber = normalizeNumber(parent['account_number']);
          originalAccNumController.text = parentNumber;
          if (fullNumber.startsWith(parentNumber)) {
            accNumController.text = fullNumber.substring(parentNumber.length);
          } else {
            accNumController.text =
                fullNumber; // Fallback if numbers are inconsistent
          }
        } catch (e) {
          originalAccNumController.text = '';
          accNumController.text = fullNumber;
        }
      } else {
        accNumController.text = fullNumber;
      }
    } else {
      updateAccountFields(parentId);
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
                          setState(() => updateAccountFields(value));
                        },
                      ),
                      SizedBox(height: 16),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (originalAccNumController.text.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 18.0,
                                  right: 4.0,
                                ),
                                child: Text(
                                  originalAccNumController.text,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                            Expanded(
                              child: TextFormField(
                                controller: accNumController,
                                decoration: InputDecoration(
                                  labelText: 'رقم الحساب',
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  NormalizeNumberFormatter(),
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                validator: (value) =>
                                    value == null || value.isEmpty
                                    ? 'الرجاء إدخال رقم'
                                    : null,
                              ),
                            ),
                          ],
                        ),
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
                      DropdownButtonFormField<String>(
                        value: transactionType,
                        decoration: InputDecoration(labelText: 'نوع المعاملات'),
                        items: [
                          DropdownMenuItem(
                            value: 'both',
                            child: Text('نقدي وذهبي'),
                          ),
                          DropdownMenuItem(
                            value: 'cash',
                            child: Text('نقدي فقط'),
                          ),
                          DropdownMenuItem(
                            value: 'gold',
                            child: Text('ذهب فقط'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => transactionType = value);
                          }
                        },
                      ),
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
                    final finalAccountNumber =
                        originalAccNumController.text + accNumController.text;
                    final data = {
                      'name': name,
                      'account_number': finalAccountNumber,
                      'type': type,
                      'parent_id': parentId,
                      'transaction_type': transactionType,
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
      accNumController.dispose();
      originalAccNumController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('شجرة الحسابات')),
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
}
