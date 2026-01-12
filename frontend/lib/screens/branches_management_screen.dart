import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';

class BranchesManagementScreen extends StatefulWidget {
  final bool isArabic;

  const BranchesManagementScreen({super.key, required this.isArabic});

  @override
  State<BranchesManagementScreen> createState() =>
      _BranchesManagementScreenState();
}

class _BranchesManagementScreenState extends State<BranchesManagementScreen> {
  final _api = ApiService();

  bool _isLoading = false;
  String? _error;
  List<Map<String, dynamic>> _branches = [];

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final branches = await _api.getBranches(activeOnly: false);
      if (!mounted) return;
      setState(() {
        _branches = branches;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  bool _asBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    final s = value.toString().trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes' || s == 'active';
  }

  String _asString(dynamic value) => (value ?? '').toString();

  Future<void> _openBranchForm({Map<String, dynamic>? branch}) async {
    final isEdit = branch != null;
    final nameController = TextEditingController(
      text: isEdit ? _asString(branch['name']) : '',
    );
    final codeController = TextEditingController(
      text: isEdit ? _asString(branch['branch_code']) : '',
    );

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            widget.isArabic
                ? (isEdit ? 'تعديل الفرع' : 'إضافة فرع')
                : (isEdit ? 'Edit Branch' : 'Add Branch'),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'اسم الفرع' : 'Branch name',
                    prefixIcon: const Icon(Icons.storefront),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: InputDecoration(
                    labelText: widget.isArabic
                        ? 'رمز الفرع (Code)'
                        : 'Branch code',
                    prefixIcon: const Icon(Icons.confirmation_number_outlined),
                    helperText: widget.isArabic
                        ? 'اتركه فارغاً لتوليده تلقائياً'
                        : 'Leave empty to auto-generate',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(widget.isArabic ? 'حفظ' : 'Save'),
            ),
          ],
        );
      },
    );

    if (result != true) return;

    final name = nameController.text.trim();
    final code = codeController.text.trim();

    if (name.isEmpty) {
      _showSnack(
        widget.isArabic ? 'اسم الفرع مطلوب' : 'Branch name is required',
        isError: true,
      );
      return;
    }

    try {
      if (isEdit) {
        final id = _asInt(branch['id']);
        if (id == null) throw Exception('Invalid branch id');
        await _api.updateBranch(
          id,
          name: name,
          branchCode: code.isEmpty ? null : code,
        );
      } else {
        await _api.createBranch(
          name: name,
          branchCode: code.isEmpty ? null : code,
          active: true,
        );
      }
      await _loadBranches();
      _showSnack(widget.isArabic ? 'تم الحفظ' : 'Saved');
    } catch (e) {
      _showSnack(
        (widget.isArabic ? 'فشل الحفظ: ' : 'Save failed: ') + e.toString(),
        isError: true,
      );
    }
  }

  Future<void> _toggleActive(
    Map<String, dynamic> branch,
    bool nextValue,
  ) async {
    final id = _asInt(branch['id']);
    if (id == null) {
      _showSnack(
        widget.isArabic ? 'معرّف الفرع غير صالح' : 'Invalid branch id',
        isError: true,
      );
      return;
    }

    try {
      if (nextValue) {
        await _api.activateBranch(id);
      } else {
        await _api.deactivateBranch(id);
      }
      await _loadBranches();
    } catch (e) {
      _showSnack(
        (widget.isArabic ? 'فشل تحديث الحالة: ' : 'Failed to update status: ') +
            e.toString(),
        isError: true,
      );
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.warning : AppColors.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAr = widget.isArabic;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'إدارة الفروع' : 'Branches'),
          actions: [
            IconButton(
              tooltip: isAr ? 'تحديث' : 'Refresh',
              onPressed: _loadBranches,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openBranchForm(),
          icon: const Icon(Icons.add),
          label: Text(isAr ? 'إضافة فرع' : 'Add'),
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isAr ? 'فشل تحميل الفروع' : 'Failed to load branches',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _loadBranches,
                          icon: const Icon(Icons.refresh),
                          label: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _branches.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final b = _branches[index];
                    final name = _asString(b['name']);
                    final code = _asString(b['branch_code']);
                    final active = _asBool(b['active']);

                    return Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.account_tree,
                          color: active
                              ? theme.colorScheme.primary
                              : theme.disabledColor,
                        ),
                        title: Text(
                          name.isEmpty ? (isAr ? 'فرع' : 'Branch') : name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          code.isEmpty
                              ? (isAr ? 'بدون رمز' : 'No code')
                              : (isAr ? 'الرمز: $code' : 'Code: $code'),
                        ),
                        trailing: Switch(
                          value: active,
                          onChanged: (v) => _toggleActive(b, v),
                        ),
                        onTap: () => _openBranchForm(branch: b),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
