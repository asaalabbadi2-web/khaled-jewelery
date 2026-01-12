import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';

class SafeBoxesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  SafeBoxesScreen({super.key, ApiService? api, this.isArabic = true})
    : api = api ?? ApiService();

  @override
  State<SafeBoxesScreen> createState() => _SafeBoxesScreenState();
}

class _SafeBoxesScreenState extends State<SafeBoxesScreen> {
  List<SafeBoxModel> _safeBoxes = [];
  String _filterType = 'all'; // all, cash, bank, gold, check
  String _searchQuery = '';
  bool _activeOnly = false;
  bool _defaultOnly = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSafeBoxes();
  }

  Future<void> _loadSafeBoxes() async {
    setState(() => _isLoading = true);
    try {
      final boxes = await widget.api.getSafeBoxes(
        safeType: _filterType == 'all' ? null : _filterType,
        includeAccount: true,
        includeBalance: true,
      );
      setState(() {
        _safeBoxes = boxes;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack(e.toString(), isError: true);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _showAddEditDialog({SafeBoxModel? safeBox}) async {
    final isEdit = safeBox != null;
    final isAr = widget.isArabic;

    // الحقول
    final nameController = TextEditingController(text: safeBox?.name ?? '');
    final nameEnController = TextEditingController(text: safeBox?.nameEn ?? '');
    String selectedType = safeBox?.safeType ?? 'cash';
    int? selectedAccountId = safeBox?.accountId;
    int? selectedKarat = safeBox?.karat;
    final bankNameController = TextEditingController(
      text: safeBox?.bankName ?? '',
    );
    final ibanController = TextEditingController(text: safeBox?.iban ?? '');
    final swiftController = TextEditingController(
      text: safeBox?.swiftCode ?? '',
    );
    final branchController = TextEditingController(text: safeBox?.branch ?? '');
    final notesController = TextEditingController(text: safeBox?.notes ?? '');
    bool isActive = safeBox?.isActive ?? true;
    bool isDefault = safeBox?.isDefault ?? false;

    // جلب الحسابات
    List<Map<String, dynamic>> accounts = [];
    try {
      final accountsResponse = await widget.api.getAccounts();
      accounts = accountsResponse.cast<Map<String, dynamic>>();
    } catch (e) {
      _showSnack('فشل تحميل الحسابات', isError: true);
      return;
    }

    String accountLabelFor(Map<String, dynamic> acc) {
      final name = (acc['name'] ?? '').toString();
      final number = (acc['account_number'] ?? '').toString();
      return '$name ($number)';
    }

    String initialAccountLabel = '';
    if (selectedAccountId != null) {
      final match = accounts
          .where((a) => a['id'] == selectedAccountId)
          .cast<Map<String, dynamic>>()
          .toList();
      if (match.isNotEmpty) {
        initialAccountLabel = accountLabelFor(match.first);
      }
    }
    final linkedAccountController = TextEditingController(
      text: initialAccountLabel,
    );

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            isEdit
                ? (isAr ? 'تعديل خزينة' : 'Edit Safe Box')
                : (isAr ? 'إضافة خزينة جديدة' : 'Add New Safe Box'),
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // الاسم
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(
                      labelText: isAr ? 'الاسم *' : 'Name *',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // الاسم بالإنجليزية
                  TextField(
                    controller: nameEnController,
                    decoration: const InputDecoration(
                      labelText: 'Name (English)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // نوع الخزينة
                  DropdownButtonFormField<String>(
                    initialValue: selectedType,
                    decoration: InputDecoration(
                      labelText: isAr ? 'نوع الخزينة *' : 'Safe Type *',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'cash',
                        child: Text(isAr ? 'نقدي' : 'Cash'),
                      ),
                      DropdownMenuItem(
                        value: 'bank',
                        child: Text(isAr ? 'بنكي' : 'Bank'),
                      ),
                      DropdownMenuItem(
                        value: 'gold',
                        child: Text(isAr ? 'ذهبي' : 'Gold'),
                      ),
                      DropdownMenuItem(
                        value: 'check',
                        child: Text(isAr ? 'شيكات' : 'Check'),
                      ),
                    ],
                    onChanged: (value) {
                      setDialogState(() {
                        selectedType = value!;
                      });
                    },
                  ),
                  const SizedBox(height: 12),

                  // الحساب المرتبط
                  Autocomplete<Map<String, dynamic>>(
                    initialValue: TextEditingValue(text: initialAccountLabel),
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final query = textEditingValue.text.trim().toLowerCase();
                      if (query.isEmpty) {
                        return const Iterable<Map<String, dynamic>>.empty();
                      }
                      return accounts.where((acc) {
                        final label = accountLabelFor(acc).toLowerCase();
                        return label.contains(query);
                      });
                    },
                    displayStringForOption: (opt) => accountLabelFor(opt),
                    fieldViewBuilder:
                        (
                          context,
                          textEditingController,
                          focusNode,
                          onFieldSubmitted,
                        ) {
                          // Keep controller in sync for edit mode display.
                          if (linkedAccountController.text.isNotEmpty &&
                              textEditingController.text.isEmpty) {
                            textEditingController.text =
                                linkedAccountController.text;
                          }
                          return TextField(
                            controller: textEditingController,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: isAr
                                  ? 'الحساب المرتبط * (ابحث بالاسم/الرقم)'
                                  : 'Linked Account * (search by name/number)',
                              border: const OutlineInputBorder(),
                            ),
                          );
                        },
                    onSelected: (selection) {
                      setDialogState(() {
                        selectedAccountId = selection['id'] as int?;
                      });
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 320),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final opt = options.elementAt(index);
                                return ListTile(
                                  dense: true,
                                  title: Text(accountLabelFor(opt)),
                                  onTap: () => onSelected(opt),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),

                  // العيار (للذهب فقط)
                  if (selectedType == 'gold')
                    DropdownButtonFormField<int>(
                      initialValue: selectedKarat,
                      decoration: InputDecoration(
                        labelText: isAr ? 'العيار *' : 'Karat *',
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 18, child: Text('18')),
                        DropdownMenuItem(value: 21, child: Text('21')),
                        DropdownMenuItem(value: 22, child: Text('22')),
                        DropdownMenuItem(value: 24, child: Text('24')),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedKarat = value;
                        });
                      },
                    ),
                  if (selectedType == 'gold') const SizedBox(height: 12),

                  // معلومات البنك (للبنوك فقط)
                  if (selectedType == 'bank') ...[
                    TextField(
                      controller: bankNameController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'اسم البنك' : 'Bank Name',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ibanController,
                      decoration: const InputDecoration(
                        labelText: 'IBAN',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: swiftController,
                      decoration: const InputDecoration(
                        labelText: 'SWIFT Code',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: branchController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'فرع البنك' : 'Bank Branch',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ملاحظات
                  TextField(
                    controller: notesController,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: isAr ? 'ملاحظات' : 'Notes',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // نشط
                  SwitchListTile(
                    title: Text(isAr ? 'نشط' : 'Active'),
                    value: isActive,
                    onChanged: (value) {
                      setDialogState(() {
                        isActive = value;
                      });
                    },
                  ),

                  // افتراضي
                  SwitchListTile(
                    title: Text(isAr ? 'افتراضي' : 'Default'),
                    subtitle: Text(
                      isAr
                          ? 'الخزينة الافتراضية للنوع المحدد'
                          : 'Default safe box for this type',
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: isDefault,
                    onChanged: (value) {
                      setDialogState(() {
                        isDefault = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                // التحقق من الحقول
                if (nameController.text.isEmpty) {
                  _showSnack(
                    isAr ? 'الاسم مطلوب' : 'Name is required',
                    isError: true,
                  );
                  return;
                }
                if (selectedAccountId == null) {
                  _showSnack(
                    isAr
                        ? 'الحساب المرتبط مطلوب'
                        : 'Linked account is required',
                    isError: true,
                  );
                  return;
                }
                if (selectedType == 'gold' && selectedKarat == null) {
                  _showSnack(
                    isAr
                        ? 'العيار مطلوب للخزائن الذهبية'
                        : 'Karat is required for gold',
                    isError: true,
                  );
                  return;
                }

                final newSafeBox = SafeBoxModel(
                  id: safeBox?.id,
                  name: nameController.text,
                  nameEn: nameEnController.text.isNotEmpty
                      ? nameEnController.text
                      : null,
                  safeType: selectedType,
                  accountId: selectedAccountId!,
                  karat: selectedKarat,
                  bankName: bankNameController.text.isNotEmpty
                      ? bankNameController.text
                      : null,
                  iban: ibanController.text.isNotEmpty
                      ? ibanController.text
                      : null,
                  swiftCode: swiftController.text.isNotEmpty
                      ? swiftController.text
                      : null,
                  branch: branchController.text.isNotEmpty
                      ? branchController.text
                      : null,
                  isActive: isActive,
                  isDefault: isDefault,
                  notes: notesController.text.isNotEmpty
                      ? notesController.text
                      : null,
                  createdBy: 'admin',
                );

                try {
                  if (isEdit) {
                    await widget.api.updateSafeBox(safeBox.id!, newSafeBox);
                    _showSnack(
                      isAr ? 'تم التحديث بنجاح' : 'Updated successfully',
                    );
                  } else {
                    await widget.api.createSafeBox(newSafeBox);
                    _showSnack(
                      isAr ? 'تم الإنشاء بنجاح' : 'Created successfully',
                    );
                  }
                  Navigator.pop(ctx);
                  _loadSafeBoxes();
                } catch (e) {
                  _showSnack(e.toString(), isError: true);
                }
              },
              child: Text(
                isEdit ? (isAr ? 'تحديث' : 'Update') : (isAr ? 'إضافة' : 'Add'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSafeBox(SafeBoxModel safeBox) async {
    final isAr = widget.isArabic;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'تأكيد الحذف' : 'Confirm Delete'),
        content: Text(
          isAr ? 'هل تريد حذف "${safeBox.name}"؟' : 'Delete "${safeBox.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isAr ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.api.deleteSafeBox(safeBox.id!);
        _showSnack(isAr ? 'تم الحذف بنجاح' : 'Deleted successfully');
        _loadSafeBoxes();
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    final filteredSafeBoxes = _safeBoxes.where((sb) {
      if (_activeOnly && !sb.isActive) return false;
      if (_defaultOnly && !sb.isDefault) return false;

      final q = _searchQuery.trim().toLowerCase();
      if (q.isEmpty) return true;

      final name = (sb.name).toLowerCase();
      final nameEn = (sb.nameEn ?? '').toLowerCase();
      final bankName = (sb.bankName ?? '').toLowerCase();
      final accountName = (sb.account?.name ?? '').toLowerCase();
      final accountNo = (sb.account?.accountNumber ?? '').toLowerCase();

      return name.contains(q) ||
          nameEn.contains(q) ||
          bankName.contains(q) ||
          accountName.contains(q) ||
          accountNo.contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'إدارة الخزائن' : 'Safe Boxes Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSafeBoxes,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddEditDialog(),
          ),
        ],
      ),
      body: Column(
        children: [
          // البحث
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: isAr
                    ? 'بحث بالاسم / الحساب / البنك...'
                    : 'Search by name / account / bank...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
              textAlign: isAr ? TextAlign.right : TextAlign.left,
            ),
          ),

          // الفلترة
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  label: Text(isAr ? 'نشط فقط' : 'Active only'),
                  selected: _activeOnly,
                  onSelected: (selected) {
                    setState(() {
                      _activeOnly = selected;
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'افتراضي فقط' : 'Default only'),
                  selected: _defaultOnly,
                  onSelected: (selected) {
                    setState(() {
                      _defaultOnly = selected;
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'الكل' : 'All'),
                  selected: _filterType == 'all',
                  onSelected: (selected) {
                    setState(() {
                      _filterType = 'all';
                      _loadSafeBoxes();
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'نقدي' : 'Cash'),
                  selected: _filterType == 'cash',
                  avatar: const Icon(Icons.money, size: 18),
                  onSelected: (selected) {
                    setState(() {
                      _filterType = 'cash';
                      _loadSafeBoxes();
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'بنكي' : 'Bank'),
                  selected: _filterType == 'bank',
                  avatar: const Icon(Icons.account_balance, size: 18),
                  onSelected: (selected) {
                    setState(() {
                      _filterType = 'bank';
                      _loadSafeBoxes();
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'ذهبي' : 'Gold'),
                  selected: _filterType == 'gold',
                  avatar: const Icon(Icons.diamond, size: 18),
                  onSelected: (selected) {
                    setState(() {
                      _filterType = 'gold';
                      _loadSafeBoxes();
                    });
                  },
                ),
                FilterChip(
                  label: Text(isAr ? 'شيكات' : 'Checks'),
                  selected: _filterType == 'check',
                  avatar: const Icon(Icons.receipt_long, size: 18),
                  onSelected: (selected) {
                    setState(() {
                      _filterType = 'check';
                      _loadSafeBoxes();
                    });
                  },
                ),
              ],
            ),
          ),

          // القائمة
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredSafeBoxes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.account_balance_wallet,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isAr ? 'لا توجد خزائن مطابقة' : 'No safe boxes match',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.add),
                          label: Text(isAr ? 'إضافة خزينة' : 'Add Safe Box'),
                          onPressed: () => _showAddEditDialog(),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredSafeBoxes.length,
                    padding: const EdgeInsets.all(8),
                    itemBuilder: (context, index) {
                      final safeBox = filteredSafeBoxes[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: safeBox.typeColor.withValues(
                              alpha: 0.2,
                            ),
                            child: Icon(safeBox.icon, color: safeBox.typeColor),
                          ),
                          title: Row(
                            children: [
                              Expanded(child: Text(safeBox.name)),
                              if (safeBox.isDefault)
                                Chip(
                                  label: Text(
                                    isAr ? 'افتراضي' : 'Default',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  backgroundColor: Colors.amber,
                                  padding: EdgeInsets.zero,
                                ),
                              if (!safeBox.isActive)
                                Chip(
                                  label: Text(
                                    isAr ? 'معطل' : 'Inactive',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  backgroundColor: Colors.grey,
                                  padding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr ? safeBox.typeNameAr : safeBox.typeNameEn,
                                style: TextStyle(color: safeBox.typeColor),
                              ),
                              if (safeBox.balance != null)
                                Text(
                                  '${isAr ? 'الرصيد:' : 'Balance:'} ${safeBox.cashBalance.toStringAsFixed(2)} ${isAr ? 'ر.س' : 'SAR'}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                  ),
                                ),
                              if (safeBox.account != null)
                                Text(
                                  '${safeBox.account!.name} (${safeBox.account!.accountNumber})',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              if (safeBox.bankName != null)
                                Text(
                                  safeBox.bankName!,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              if (safeBox.karat != null)
                                Text(
                                  '${isAr ? 'عيار' : 'Karat'} ${safeBox.karat}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20),
                                onPressed: () =>
                                    _showAddEditDialog(safeBox: safeBox),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  size: 20,
                                  color: Colors.red,
                                ),
                                onPressed: () => _deleteSafeBox(safeBox),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'خزينة جديدة' : 'New Safe Box'),
        onPressed: () => _showAddEditDialog(),
      ),
    );
  }
}
