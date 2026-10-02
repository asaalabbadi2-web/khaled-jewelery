import 'dart:convert';

import 'package:flutter/material.dart';
import '../api_service.dart';
import '../app_events.dart';
import '../models/safe_box_model.dart';
import 'account_statement_screen.dart';
import 'add_voucher_screen.dart';
import 'clearing_settlement_screen.dart';
import 'safe_transfer_screen.dart';

enum _SafeCardMenuAction { statement, edit, settlement, delete }

class SafeBoxesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  // Optional: show ledger-based balances and lock to a specific safe type.
  final bool balancesView;
  final String? initialFilterType;
  final bool lockFilterType;
  final String? titleOverride;

  SafeBoxesScreen({
    super.key,
    ApiService? api,
    this.isArabic = true,
    this.balancesView = true,
    this.initialFilterType,
    this.lockFilterType = false,
    this.titleOverride,
  }) : api = api ?? ApiService();

  @override
  State<SafeBoxesScreen> createState() => _SafeBoxesScreenState();
}

class _SafeBoxesScreenState extends State<SafeBoxesScreen> {
  static const Color _primaryColor = Color(0xFFC69214);
  static const Color _successColor = Color(0xFF2E7D32);
  static const Color _dangerColor = Color(0xFFD32F2F);
  static const Color _backgroundColor = Color(0xFFF8F9FB);
  static const Color _textColor = Color(0xFF1C1C1C);

  List<SafeBoxModel> _safeBoxes = [];
  String _filterType = 'all'; // all, cash, bank, clearing, gold, check
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _activeOnly = false;
  bool _defaultOnly = false;
  bool _isLoading = false;
  final Set<int> _expandedCardKeys = <int>{};
  int? _pressedCardId;
  Map<int, Map<String, double>> _stonesMap = {};

  String _effectiveFilterType() {
    if (widget.lockFilterType) {
      final locked = (widget.initialFilterType ?? '').trim();
      if (locked.isNotEmpty) return locked;
    }
    return _filterType;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialFilterType != null &&
        widget.initialFilterType!.isNotEmpty) {
      _filterType = widget.initialFilterType!;
    }
    _loadSafeBoxes();
    AppEvents.vaultRefreshSignal.addListener(_onVaultRefresh);
  }

  void _onVaultRefresh() {
    if (mounted) _loadSafeBoxes();
  }

  @override
  void dispose() {
    AppEvents.vaultRefreshSignal.removeListener(_onVaultRefresh);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSafeBoxes() async {
    setState(() => _isLoading = true);
    try {
      final effectiveType = widget.lockFilterType
          ? (widget.initialFilterType ?? _filterType)
          : _filterType;

      final boxesFuture = widget.balancesView
          ? widget.api.getSafeBoxBalances(
              type: effectiveType == 'all' ? null : effectiveType,
              isActive: null,
            )
          : widget.api.getSafeBoxes(
              safeType: effectiveType == 'all' ? null : effectiveType,
              includeAccount: true,
              includeBalance: true,
            );

      final stonesFuture = widget.api.getStonesBalance();
      final results = await Future.wait([boxesFuture, stonesFuture]);
      final boxes = results[0] as List<SafeBoxModel>;
      final stones = results[1] as Map<int, Map<String, double>>;

      setState(() {
        _safeBoxes = boxes;
        _stonesMap = stones;
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

    final effectiveType = _effectiveFilterType();
    final lockTypeForAdd = !isEdit && effectiveType != 'all';

    // الحقول
    final nameController = TextEditingController(text: safeBox?.name ?? '');
    final nameEnController = TextEditingController(text: safeBox?.nameEn ?? '');
    String selectedType =
        safeBox?.safeType ?? (lockTypeForAdd ? effectiveType : 'cash');
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

    int accountNumberAsInt(Map<String, dynamic> acc) {
      final raw = (acc['account_number'] ?? '').toString().trim();
      return int.tryParse(raw) ?? 0;
    }

    // Keep a stable ordering for browsing/suggestions.
    final accountsSorted = List<Map<String, dynamic>>.from(accounts)
      ..sort((a, b) => accountNumberAsInt(a).compareTo(accountNumberAsInt(b)));

    bool tracksWeight(Map<String, dynamic> acc) => acc['tracks_weight'] == true;

    // Keep tracksWeight helper for validation and picker.

    String accountLabelFor(Map<String, dynamic> acc) {
      final name = (acc['name'] ?? '').toString();
      final number = (acc['account_number'] ?? '').toString();
      return '$name ($number)';
    }

    String initialAccountLabel = '';
    if (selectedAccountId != null) {
      final match = accountsSorted
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

    Future<void> openAccountPicker() async {
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _AccountPickerDialog(
          isArabic: isAr,
          accounts: accountsSorted,
          initialAccountId: selectedAccountId,
          requireTracksWeight: selectedType == 'gold',
          allowShowAllWhenTracksRequired: true,
          initialQuery: linkedAccountController.text,
        ),
      );

      if (picked != null) {
        setState(() {
          selectedAccountId = picked['id'] as int?;
          linkedAccountController.text = accountLabelFor(picked);
        });
      }
    }

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
                    decoration: InputDecoration(
                      labelText: isAr ? 'الاسم بالإنجليزية' : 'Name (English)',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // النوع
                  DropdownButtonFormField<String>(
                    value: selectedType,
                    decoration: InputDecoration(
                      labelText: isAr ? 'النوع *' : 'Type *',
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
                        value: 'clearing',
                        child: Text(isAr ? 'مستحقات تحصيل' : 'Clearing'),
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
                    onChanged: lockTypeForAdd
                        ? null
                        : (value) {
                            if (value == null) return;
                            setDialogState(() {
                              selectedType = value;
                              // If not gold, clear karat selection.
                              if (selectedType != 'gold') {
                                selectedKarat = null;
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 12),

                  // الحساب المرتبط
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: linkedAccountController,
                          readOnly: true,
                          onTap: openAccountPicker,
                          decoration: InputDecoration(
                            labelText: isAr
                                ? 'الحساب المرتبط *'
                                : 'Linked Account *',
                            hintText: isAr
                                ? 'اضغط للاختيار (بحث/فلترة)'
                                : 'Tap to select (search/filter)',
                            helperText: selectedType == 'gold'
                                ? (isAr
                                      ? 'يجب اختيار حساب يتتبع الوزن (tracks_weight=true)'
                                      : 'Must choose tracks_weight=true')
                                : null,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: openAccountPicker,
                        icon: const Icon(Icons.search),
                        tooltip: isAr ? 'اختيار حساب' : 'Pick account',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // العيار (للذهب فقط)
                  if (selectedType == 'gold')
                    DropdownButtonFormField<int?>(
                      value: selectedKarat,
                      decoration: InputDecoration(
                        labelText: isAr
                            ? 'العيار (اختياري)'
                            : 'Karat (optional)',
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem<int?>(
                          value: null,
                          child: Text('— خزينة متعددة العيارات —'),
                        ),
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
                  if (selectedType == 'gold')
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.blue.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        isAr
                            ? '💡 نوعان:\n'
                                  '• مع عيار: خزينة لعيار محدد فقط\n'
                                  '• بدون عيار: تقبل جميع العيارات (أفضل للموظفين)'
                            : '💡 Two types:\n'
                                  '• With karat: specific karat only\n'
                                  '• Without karat: accepts all karats (better for employees)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue.shade800,
                          height: 1.4,
                        ),
                      ),
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

                if (selectedType == 'gold') {
                  final selectedAcc = accountsSorted
                      .where((a) => a['id'] == selectedAccountId)
                      .cast<Map<String, dynamic>>()
                      .toList();
                  final tracks =
                      selectedAcc.isNotEmpty && tracksWeight(selectedAcc.first);
                  if (!tracks) {
                    _showSnack(
                      isAr
                          ? 'لخزنة الذهب يجب اختيار حساب يتتبع الوزن (tracks_weight=true)'
                          : 'Gold safe boxes require a weight-tracking account (tracks_weight=true)',
                      isError: true,
                    );
                    return;
                  }
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
        final raw = e.toString();

        Map<String, dynamic>? payload;
        try {
          final start = raw.indexOf('{');
          final end = raw.lastIndexOf('}');
          if (start != -1 && end != -1 && end > start) {
            final jsonStr = raw.substring(start, end + 1);
            final decoded = json.decode(jsonStr);
            if (decoded is Map<String, dynamic>) {
              payload = decoded;
            }
          }
        } catch (_) {
          payload = null;
        }

        final errCode = (payload?['error'] as String?) ?? '';
        if (errCode == 'cannot_delete_safe_box_in_use') {
          final details = payload?['details'] as Map<String, dynamic>?;
          final employees = details?['employees_linked'] ?? 0;
          final transactions = details?['transactions_linked'] ?? 0;
          final invoices = details?['invoices_linked'] ?? 0;
          final paymentMethods = details?['payment_methods_linked'] ?? 0;

          _showSnack(
            isAr
                ? 'لا يمكن حذف الخزنة لأنها مستخدمة (موظفين: $employees، عمليات: $transactions، فواتير: $invoices، وسائل دفع: $paymentMethods)'
                : 'Cannot delete safe box because it is in use (employees: $employees, transactions: $transactions, invoices: $invoices, payment methods: $paymentMethods).',
            isError: true,
          );
          return;
        }

        final serverMsg = payload?['message'] as String?;
        _showSnack(
          serverMsg?.trim().isNotEmpty == true ? serverMsg! : raw,
          isError: true,
        );
      }
    }
  }

  bool _isGoldSafe(SafeBoxModel safeBox) {
    return safeBox.safeType.trim().toLowerCase() == 'gold';
  }

  int _safeCardKey(SafeBoxModel safeBox) {
    return safeBox.id ?? -safeBox.accountId;
  }

  bool _isCardExpanded(SafeBoxModel safeBox) {
    return _expandedCardKeys.contains(_safeCardKey(safeBox));
  }

  void _toggleCardExpanded(SafeBoxModel safeBox) {
    final key = _safeCardKey(safeBox);
    setState(() {
      if (_expandedCardKeys.contains(key)) {
        _expandedCardKeys.remove(key);
      } else {
        _expandedCardKeys.add(key);
      }
    });
  }

  // كانت هذه الدالة تُفضِّل totalWeightMainKarat الخام (محسوب من
  // SafeBoxTransaction في الباكند) كل مرة كان غير صفر، متجاوزةً تماماً
  // goldBalance*k (التي تُفضِّل القيد المحاسبي أصلاً بعد إصلاح الموديل) --
  // وهذا بالضبط ما جعل كل الانحرافات التي تتبَّعناها اليوم تظهر هنا. الآن
  // مصدر واحد فقط دائماً: goldBalance*k، بلا أي تفرّع بين "وضع كشوفات" أو
  // "حمولة ledger".
  double _effectiveGoldMainKaratBalance(SafeBoxModel safeBox) {
    return safeBox.goldBalance18k * 18 / 21 +
        safeBox.goldBalance21k +
        safeBox.goldBalance22k * 22 / 21 +
        safeBox.goldBalance24k * 24 / 21;
  }

  List<MapEntry<String, double>> _goldBreakdown(SafeBoxModel safeBox) {
    return [
      MapEntry('24k', safeBox.goldBalance24k),
      MapEntry('22k', safeBox.goldBalance22k),
      MapEntry('21k', safeBox.goldBalance21k),
      MapEntry('18k', safeBox.goldBalance18k),
    ];
  }

  String _formatCurrency(double value) {
    final unit = widget.isArabic ? 'ر.س' : 'SAR';
    return '${value.toStringAsFixed(2)} $unit';
  }

  String _formatWeight(double value) {
    final unit = widget.isArabic ? 'جم' : 'g';
    return '${value.toStringAsFixed(3)} $unit';
  }

  String _pendingText(SafeBoxModel safeBox, bool isGold, double primaryBalance) {
    final ar = widget.isArabic;
    final docs = safeBox.pendingDocuments;
    if (isGold && safeBox.pendingWeight.isNotEmpty) {
      // Per karat: what waits, and posted + pending = what should be in hand.
      final posted = {for (final e in _goldBreakdown(safeBox)) e.key: e.value};
      final parts = safeBox.pendingWeight.entries.map((e) {
        final inHand = (posted[e.key] ?? 0.0) + e.value;
        final sign = e.value >= 0 ? '+' : '';
        return ar
            ? '${e.key}: $sign${e.value.toStringAsFixed(3)} ← في اليد ${inHand.toStringAsFixed(3)}'
            : '${e.key}: $sign${e.value.toStringAsFixed(3)} → in hand ${inHand.toStringAsFixed(3)}';
      }).join(' • ');
      return ar ? 'معلّق بانتظار الاعتماد ($docs): $parts' : 'Pending approval ($docs): $parts';
    }
    final pending = safeBox.pendingCash;
    final sign = pending >= 0 ? '+' : '';
    final inHand = _formatCurrency(primaryBalance + pending);
    return ar
        ? 'معلّق بانتظار الاعتماد ($docs): $sign${_formatCurrency(pending)} • المتوقع في اليد: $inHand'
        : 'Pending approval ($docs): $sign${_formatCurrency(pending)} • Expected in hand: $inHand';
  }

  Color _balanceColor(double value) {
    if (value < 0) return _dangerColor;
    if (value > 0) return _successColor;
    return Colors.blueGrey.shade700;
  }

  String _safeTypeLabel(SafeBoxModel safeBox) {
    switch (safeBox.safeType.trim().toLowerCase()) {
      case 'cash':
        return widget.isArabic ? 'نقدي' : 'Cash';
      case 'bank':
        return widget.isArabic ? 'بنكي' : 'Bank';
      case 'gold':
        return widget.isArabic ? 'ذهب' : 'Gold';
      case 'check':
        return widget.isArabic ? 'شبكات' : 'Networks';
      case 'clearing':
        return widget.isArabic ? 'تحصيل' : 'Clearing';
      default:
        return widget.isArabic ? safeBox.typeNameAr : safeBox.typeNameEn;
    }
  }

  Color _safeTypeBadgeBackground(SafeBoxModel safeBox) {
    switch (safeBox.safeType.trim().toLowerCase()) {
      case 'cash':
        return const Color(0xFFE8F5E9);
      case 'bank':
        return const Color(0xFFEAF2FF);
      case 'gold':
        return const Color(0xFFFFF3D8);
      case 'check':
        return const Color(0xFFF3E8FF);
      case 'clearing':
        return const Color(0xFFE7F6F4);
      default:
        return const Color(0xFFF1F3F5);
    }
  }

  Color _safeTypeBadgeForeground(SafeBoxModel safeBox) {
    switch (safeBox.safeType.trim().toLowerCase()) {
      case 'cash':
        return _successColor;
      case 'bank':
        return const Color(0xFF1565C0);
      case 'gold':
        return _primaryColor;
      case 'check':
        return const Color(0xFF7B1FA2);
      case 'clearing':
        return const Color(0xFF0F766E);
      default:
        return const Color(0xFF616161);
    }
  }

  IconData _safeTypeIcon(SafeBoxModel safeBox) {
    switch (safeBox.safeType.trim().toLowerCase()) {
      case 'cash':
        return Icons.payments_outlined;
      case 'bank':
        return Icons.account_balance_outlined;
      case 'gold':
        return Icons.diamond_outlined;
      case 'check':
        return Icons.receipt_long_outlined;
      case 'clearing':
        return Icons.sync_alt_rounded;
      default:
        return Icons.account_balance_wallet_outlined;
    }
  }

  double _cashSummary(List<SafeBoxModel> safeBoxes) {
    return safeBoxes
        .where((safeBox) => !_isGoldSafe(safeBox))
        .fold<double>(0.0, (sum, safeBox) => sum + safeBox.cashBalance);
  }

  double _goldSummary(List<SafeBoxModel> safeBoxes) {
    return safeBoxes
        .where(_isGoldSafe)
        .fold<double>(
          0.0,
          (sum, safeBox) => sum + _effectiveGoldMainKaratBalance(safeBox),
        );
  }

  Future<void> _openStatement(SafeBoxModel safeBox) async {
    final account = safeBox.account;
    if (account == null) {
      _showSnack(
        widget.isArabic
            ? 'لا يوجد حساب مرتبط لعرض كشف الحساب'
            : 'No linked account for statement',
        isError: true,
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountStatementScreen(
          accountId: account.id,
          accountName: safeBox.name,
          entityType: 'account',
        ),
      ),
    );
  }

  Future<void> _openVoucherQuickAction(
    SafeBoxModel safeBox, {
    required String voucherType,
  }) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddVoucherScreen(
          voucherType: voucherType,
          initialPartyType: 'other',
          initialOtherAccountId: safeBox.accountId,
          initialDescription: voucherType == 'receipt'
              ? (widget.isArabic
                    ? 'إضافة رصيد إلى ${safeBox.name}'
                    : 'Top up ${safeBox.name}')
              : (widget.isArabic
                    ? 'سحب من ${safeBox.name}'
                    : 'Withdraw from ${safeBox.name}'),
        ),
      ),
    );

    if (changed == true && mounted) {
      _loadSafeBoxes();
    }
  }

  Future<void> _openTransferQuickAction(
    SafeBoxModel safeBox, {
    int? initialFromSafeId,
    int? initialToSafeId,
    String? note,
  }) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SafeTransferScreen(
          api: widget.api,
          isArabic: widget.isArabic,
          initialMode: _isGoldSafe(safeBox) ? 'gold' : 'cash',
          initialFromSafeId: initialFromSafeId,
          initialToSafeId: initialToSafeId,
          initialNotes: note,
          popOnSuccess: true,
        ),
      ),
    );

    if (changed == true && mounted) {
      _loadSafeBoxes();
    }
  }

  Future<void> _handleMenuAction(
    _SafeCardMenuAction action,
    SafeBoxModel safeBox,
  ) async {
    switch (action) {
      case _SafeCardMenuAction.statement:
        await _openStatement(safeBox);
        break;
      case _SafeCardMenuAction.edit:
        await _showAddEditDialog(safeBox: safeBox);
        break;
      case _SafeCardMenuAction.settlement:
        if (safeBox.id == null) return;
        final changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                ClearingSettlementScreen(initialClearingSafeBoxId: safeBox.id),
          ),
        );
        if (changed == true && mounted) {
          _loadSafeBoxes();
        }
        break;
      case _SafeCardMenuAction.delete:
        await _deleteSafeBox(safeBox);
        break;
    }
  }

  Future<void> _showCardActionsSheet(SafeBoxModel safeBox) async {
    final action = await showModalBottomSheet<_SafeCardMenuAction>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(widget.isArabic ? 'كشف حساب' : 'Statement'),
                onTap: () =>
                    Navigator.of(context).pop(_SafeCardMenuAction.statement),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(widget.isArabic ? 'تعديل' : 'Edit'),
                onTap: () =>
                    Navigator.of(context).pop(_SafeCardMenuAction.edit),
              ),
              if (safeBox.safeType.toLowerCase() == 'clearing')
                ListTile(
                  leading: const Icon(Icons.sync_alt_rounded),
                  title: Text(widget.isArabic ? 'تسوية التحصيل' : 'Settlement'),
                  onTap: () =>
                      Navigator.of(context).pop(_SafeCardMenuAction.settlement),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text(widget.isArabic ? 'حذف' : 'Delete'),
                onTap: () =>
                    Navigator.of(context).pop(_SafeCardMenuAction.delete),
              ),
            ],
          ),
        );
      },
    );

    if (action != null && mounted) {
      await _handleMenuAction(action, safeBox);
    }
  }

  Widget _buildSummaryCard({
    required IconData icon,
    required String title,
    required String value,
    required Color accentColor,
  }) {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accentColor, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      color: _textColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTab({
    required String value,
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final color = selected ? const Color(0xFFC69214) : Colors.grey.shade700;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFC69214) : const Color(0xFFF1F1F1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? const Color(0xFFC69214)
                : Colors.grey.withValues(alpha: 0.25),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFFC69214).withValues(alpha: 0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? Colors.white : color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? Colors.white : color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlagChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      selectedColor: const Color(0xFFC69214).withValues(alpha: 0.16),
      side: BorderSide(
        color: selected
            ? const Color(0xFFC69214)
            : Colors.grey.withValues(alpha: 0.25),
      ),
      labelStyle: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: selected ? const Color(0xFFC69214) : Colors.grey.shade800,
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildGoldDetails(SafeBoxModel safeBox) {
    final breakdown = _goldBreakdown(safeBox);
    final nonZero = breakdown
        .where((entry) => entry.value.abs() > 0.0005)
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isArabic ? 'تفاصيل الذهب' : 'Gold details',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 6),
          if (nonZero.isEmpty)
            Text(
              widget.isArabic ? 'لا توجد أوزان حالياً' : 'No weight balance',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w500,
              ),
            ),
          ...nonZero.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${entry.key}: ${entry.value.toStringAsFixed(3)} ${widget.isArabic ? 'جم' : 'g'}',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMetaPill({
    required String label,
    required Color color,
    Color? textColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: textColor ?? color,
        ),
      ),
    );
  }

  Widget _buildCompactIconAction({
    required IconData icon,
    required VoidCallback onPressed,
    required Color color,
    Color? backgroundColor,
    bool outlined = false,
  }) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        tooltip: null,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        style: IconButton.styleFrom(
          backgroundColor: outlined ? Colors.white : (backgroundColor ?? color),
          side: outlined
              ? BorderSide(color: color.withValues(alpha: 0.55))
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: outlined ? color : Colors.white),
      ),
    );
  }

  Widget _buildSafeCard(SafeBoxModel safeBox) {
    final isGold = _isGoldSafe(safeBox);
    final isExpanded = _isCardExpanded(safeBox);
    final primaryBalance = isGold
        ? _effectiveGoldMainKaratBalance(safeBox)
        : safeBox.cashBalance;
    final primaryBalanceText = isGold
        ? _formatWeight(primaryBalance)
        : _formatCurrency(primaryBalance);
    final accountLine = safeBox.account == null
        ? null
        : '${safeBox.account!.accountNumber} • ${safeBox.account!.name}';
    final secondaryLine = safeBox.bankName?.trim().isNotEmpty == true
        ? safeBox.bankName!
        : (safeBox.notes?.trim().isNotEmpty == true
              ? safeBox.notes!.trim()
              : null);
    final badgeBackground = _safeTypeBadgeBackground(safeBox);
    final badgeForeground = _safeTypeBadgeForeground(safeBox);

    final isPressed = _pressedCardId == safeBox.id;

    return Listener(
      onPointerDown: (_) => setState(() => _pressedCardId = safeBox.id),
      onPointerUp: (_) => setState(() => _pressedCardId = null),
      onPointerCancel: (_) => setState(() => _pressedCardId = null),
      child: AnimatedScale(
        scale: isPressed ? 0.98 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // -- Color strip --
              Container(
                height: 4,
                decoration: BoxDecoration(color: badgeForeground),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // -- Row 1: Icon + Name + Badge + ⋮ --
                    Row(
                      children: [
                        Icon(
                          _safeTypeIcon(safeBox),
                          size: 20,
                          color: badgeForeground,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            safeBox.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: _textColor,
                              height: 1.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: badgeBackground,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _safeTypeLabel(safeBox),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: badgeForeground,
                            ),
                          ),
                        ),
                        if (safeBox.isDefault) ...[
                          const SizedBox(width: 6),
                          _buildCompactMetaPill(
                            label: widget.isArabic ? 'افتراضي' : 'Default',
                            color: Colors.amber,
                            textColor: Colors.amber.shade900,
                          ),
                        ],
                        const Spacer(),
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            splashRadius: 18,
                            onPressed: () => _showCardActionsSheet(safeBox),
                            icon: Icon(
                              Icons.more_vert,
                              size: 20,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // -- Row 2: Balance --
                    Text(
                      primaryBalanceText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: _balanceColor(primaryBalance),
                        height: 1.1,
                      ),
                    ),
                    // What waits for approval -- read only; posted + pending = in hand.
                    if (safeBox.pendingDocuments > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        _pendingText(safeBox, isGold, primaryBalance),
                        maxLines: 4,
                        style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                      ),
                    ],
                    const SizedBox(height: 8),
                    // -- Karat chips (gold only) --
                    if (isGold) ...[
                      Builder(
                        builder: (_) {
                          final chips = _goldBreakdown(
                            safeBox,
                          ).where((e) => e.value.abs() > 0.0001).toList();
                          if (chips.isEmpty) return const SizedBox.shrink();
                          return Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: chips.map((e) {
                              final isNeg = e.value < 0;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isNeg
                                      ? _dangerColor.withValues(alpha: 0.08)
                                      : _primaryColor.withValues(alpha: 0.13),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isNeg
                                        ? _dangerColor.withValues(alpha: 0.35)
                                        : _primaryColor.withValues(alpha: 0.40),
                                    width: 1.2,
                                  ),
                                ),
                                child: Text(
                                  '${e.key}: ${e.value.toStringAsFixed(3)} جم',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: isNeg ? _dangerColor : _primaryColor,
                                  ),
                                ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                    // -- Stones display (gold only) --
                    if (isGold) ...[
                      Builder(
                        builder: (_) {
                          final info = _stonesMap[safeBox.id];
                          final total = info?['total'] ?? 0.0;
                          if (total <= 0.0001) return const SizedBox.shrink();
                          final karatEntries = ['18','21','22','24']
                              .where((k) => (info?[k] ?? 0.0) > 0.0001)
                              .toList();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // الإجمالي
                              Row(children: [
                                const Icon(Icons.diamond_outlined,
                                    size: 12, color: Color(0xFFB56A2F)),
                                const SizedBox(width: 4),
                                Text(
                                  '${total.toStringAsFixed(3)} جم',
                                  style: const TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w700,
                                    color: Color(0xFFB56A2F),
                                  ),
                                ),
                              ]),
                              // تفصيل العيارات (صغير ومدمج)
                              if (karatEntries.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Wrap(
                                  spacing: 4, runSpacing: 3,
                                  children: karatEntries.map((k) {
                                    final v = info![k]!;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFB56A2F)
                                            .withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(0xFFB56A2F)
                                              .withValues(alpha: 0.25),
                                        ),
                                      ),
                                      child: Text(
                                        '$k: ${v.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          fontSize: 10, fontWeight: FontWeight.w600,
                                          color: Color(0xFFB56A2F),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 6),
                    ],
                    // -- Row 3: Action buttons --
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCompactIconAction(
                          icon: Icons.add,
                          color: _successColor,
                          backgroundColor: _successColor,
                          onPressed: () {
                            if (isGold) {
                              _openTransferQuickAction(
                                safeBox,
                                initialToSafeId: safeBox.id,
                                note: widget.isArabic
                                    ? 'إضافة رصيد إلى ${safeBox.name}'
                                    : 'Top up ${safeBox.name}',
                              );
                              return;
                            }
                            _openVoucherQuickAction(
                              safeBox,
                              voucherType: 'receipt',
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        _buildCompactIconAction(
                          icon: Icons.remove,
                          color: _dangerColor,
                          outlined: true,
                          onPressed: () {
                            if (isGold) {
                              _openTransferQuickAction(
                                safeBox,
                                initialFromSafeId: safeBox.id,
                                note: widget.isArabic
                                    ? 'سحب من ${safeBox.name}'
                                    : 'Withdraw from ${safeBox.name}',
                              );
                              return;
                            }
                            _openVoucherQuickAction(
                              safeBox,
                              voucherType: 'payment',
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        _buildCompactIconAction(
                          icon: Icons.swap_horiz,
                          color: _primaryColor,
                          outlined: true,
                          onPressed: () {
                            _openTransferQuickAction(
                              safeBox,
                              initialFromSafeId: safeBox.id,
                              note: widget.isArabic
                                  ? 'تحويل من ${safeBox.name}'
                                  : 'Transfer from ${safeBox.name}',
                            );
                          },
                        ),
                      ],
                    ),
                    // -- Expand tap area --
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggleCardExpanded(safeBox),
                      child: AnimatedCrossFade(
                        duration: const Duration(milliseconds: 200),
                        crossFadeState: isExpanded
                            ? CrossFadeState.showSecond
                            : CrossFadeState.showFirst,
                        firstChild: const SizedBox(height: 4),
                        secondChild: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Divider(
                                height: 1,
                                color: Colors.black.withValues(alpha: 0.08),
                              ),
                              const SizedBox(height: 8),
                              if (accountLine != null) ...[
                                Text(
                                  accountLine,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                              ],
                              if (secondaryLine != null) ...[
                                Text(
                                  secondaryLine,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                              ],
                              if (isGold) _buildGoldDetails(safeBox),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final useWideSummaryLayout = screenWidth >= 900;

    final filteredSafeBoxes =
        _safeBoxes.where((sb) {
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
        }).toList()..sort((a, b) {
          // Defaults first, then by name
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return a.name.compareTo(b.name);
        });

    final visibleCashTotal = _cashSummary(filteredSafeBoxes);
    final visibleGoldTotal = _goldSummary(filteredSafeBoxes);
    final activeCount = filteredSafeBoxes
        .where((safeBox) => safeBox.isActive)
        .length;
    final typeTabs = <Map<String, dynamic>>[
      {
        'value': 'all',
        'label': isAr ? 'الكل' : 'All',
        'icon': Icons.apps_rounded,
      },
      {
        'value': 'cash',
        'label': isAr ? 'نقدي' : 'Cash',
        'icon': Icons.payments_outlined,
      },
      {
        'value': 'bank',
        'label': isAr ? 'بنكي' : 'Bank',
        'icon': Icons.account_balance_outlined,
      },
      {
        'value': 'clearing',
        'label': isAr ? 'مستحقات تحصيل' : 'Clearing',
        'icon': Icons.sync_alt_rounded,
      },
      {
        'value': 'gold',
        'label': isAr ? 'ذهبي' : 'Gold',
        'icon': Icons.diamond_outlined,
      },
      {
        'value': 'check',
        'label': isAr ? 'شبكات' : 'Networks',
        'icon': Icons.receipt_long_outlined,
      },
    ];

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        toolbarHeight: 64,
        backgroundColor: _primaryColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 24,
        title: Text(
          widget.titleOverride ??
              (isAr ? 'إدارة الخزائن' : 'Safe Boxes Management'),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () => _showAddEditDialog(),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: _loadSafeBoxes,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: useWideSummaryLayout
                ? Row(
                    children: [
                      Expanded(
                        child: _buildSummaryCard(
                          icon: Icons.payments_outlined,
                          title: isAr ? 'إجمالي النقد' : 'Total cash',
                          value: _formatCurrency(visibleCashTotal),
                          accentColor: _successColor,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildSummaryCard(
                          icon: Icons.diamond_outlined,
                          title: isAr ? 'إجمالي الذهب' : 'Total gold',
                          value: _formatWeight(visibleGoldTotal),
                          accentColor: _primaryColor,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildSummaryCard(
                          icon: Icons.account_balance_wallet_outlined,
                          title: isAr ? 'عدد الخزائن' : 'Vault count',
                          value: filteredSafeBoxes.length.toString(),
                          accentColor: const Color(0xFF1565C0),
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      _buildSummaryCard(
                        icon: Icons.payments_outlined,
                        title: isAr ? 'إجمالي النقد' : 'Total cash',
                        value: _formatCurrency(visibleCashTotal),
                        accentColor: _successColor,
                      ),
                      const SizedBox(height: 16),
                      _buildSummaryCard(
                        icon: Icons.diamond_outlined,
                        title: isAr ? 'إجمالي الذهب' : 'Total gold',
                        value: _formatWeight(visibleGoldTotal),
                        accentColor: _primaryColor,
                      ),
                      const SizedBox(height: 16),
                      _buildSummaryCard(
                        icon: Icons.account_balance_wallet_outlined,
                        title: isAr ? 'عدد الخزائن' : 'Vault count',
                        value: filteredSafeBoxes.length.toString(),
                        accentColor: const Color(0xFF1565C0),
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 44,
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _searchQuery = value),
                      textAlign: isAr ? TextAlign.right : TextAlign.left,
                      decoration: InputDecoration(
                        hintText: isAr
                            ? 'ابحث باسم الخزنة أو الحساب...'
                            : 'Search by safe name or account...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _searchQuery.trim().isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                                icon: const Icon(Icons.close_rounded, size: 18),
                                tooltip: isAr ? 'مسح' : 'Clear',
                              ),
                        filled: true,
                        fillColor: const Color(0xFFF5F5F5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!widget.lockFilterType)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: typeTabs.map((tab) {
                          final selected = _filterType == tab['value'];
                          return _buildTypeTab(
                            value: tab['value'] as String,
                            label: tab['label'] as String,
                            icon: tab['icon'] as IconData,
                            selected: selected,
                            onTap: () {
                              if (_filterType == tab['value']) return;
                              setState(() {
                                _filterType = tab['value'] as String;
                              });
                              _loadSafeBoxes();
                            },
                          );
                        }).toList(),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildFlagChip(
                          label: isAr ? 'نشط فقط' : 'Active only',
                          selected: _activeOnly,
                          onSelected: (selected) {
                            setState(() => _activeOnly = selected);
                          },
                        ),
                        _buildFlagChip(
                          label: isAr ? 'افتراضي فقط' : 'Default only',
                          selected: _defaultOnly,
                          onSelected: (selected) {
                            setState(() => _defaultOnly = selected);
                          },
                        ),
                        _buildFlagChip(
                          label: isAr
                              ? 'نشط: $activeCount'
                              : 'Active: $activeCount',
                          selected: false,
                          onSelected: (_) {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = constraints.maxWidth >= 900
                          ? 3
                          : constraints.maxWidth >= 600
                          ? 2
                          : 1;
                      final totalSpacing = 12.0 * (crossAxisCount - 1) + 32;
                      final cardWidth =
                          (constraints.maxWidth - totalSpacing) /
                          crossAxisCount;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: filteredSafeBoxes.map((safeBox) {
                            return SizedBox(
                              width: cardWidth,
                              child: _buildSafeCard(safeBox),
                            );
                          }).toList(),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: FloatingActionButton(
        heroTag: 'add_safe',
        backgroundColor: _primaryColor,
        tooltip: isAr ? 'خزينة جديدة' : 'New Safe Box',
        onPressed: () => _showAddEditDialog(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

class _AccountPickerDialog extends StatefulWidget {
  final bool isArabic;
  final List<Map<String, dynamic>> accounts;
  final int? initialAccountId;
  final bool requireTracksWeight;
  final bool allowShowAllWhenTracksRequired;
  final String? initialQuery;

  const _AccountPickerDialog({
    required this.isArabic,
    required this.accounts,
    required this.initialAccountId,
    required this.requireTracksWeight,
    required this.allowShowAllWhenTracksRequired,
    this.initialQuery,
  });

  @override
  State<_AccountPickerDialog> createState() => _AccountPickerDialogState();
}

class _AccountPickerDialogState extends State<_AccountPickerDialog> {
  late final TextEditingController _searchController;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery ?? '');
    _showAll = !widget.requireTracksWeight;
    _searchController.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _tracksWeight(Map<String, dynamic> acc) => acc['tracks_weight'] == true;

  String _labelFor(Map<String, dynamic> acc) {
    final name = (acc['name'] ?? '').toString();
    final number = (acc['account_number'] ?? '').toString();
    return '$name ($number)';
  }

  bool _matchesQuery(Map<String, dynamic> acc, String q) {
    final label = _labelFor(acc).toLowerCase();
    if (label.contains(q)) return true;

    // If user types digits, prioritize account number matching.
    final digitsOnly = q.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isNotEmpty) {
      final number = (acc['account_number'] ?? '').toString();
      return number.contains(digitsOnly) || number.startsWith(digitsOnly);
    }

    return false;
  }

  List<Map<String, dynamic>> _filtered() {
    final q = _searchController.text.trim().toLowerCase();

    final base = (widget.requireTracksWeight && !_showAll)
        ? widget.accounts.where(_tracksWeight)
        : widget.accounts;

    if (q.isEmpty) {
      // Initial browsing list.
      return base.take(200).toList(growable: false);
    }

    final matches = base.where((a) => _matchesQuery(a, q)).toList();
    // Keep list bounded for performance on web.
    if (matches.length > 500) {
      return matches.take(500).toList(growable: false);
    }
    return matches;
  }

  String _t(String ar, String en) => widget.isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _filtered();

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: widget.isArabic
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _t('اختيار الحساب المرتبط', 'Select Linked Account'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: widget.isArabic
                          ? TextAlign.right
                          : TextAlign.left,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    tooltip: _t('إغلاق', 'Close'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: _t(
                    'ابحث بالاسم أو رقم الحساب...',
                    'Search by name or account number...',
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              if (widget.requireTracksWeight)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _t(
                          'ملاحظة: خزنة الذهب يجب ربطها بحساب tracks_weight=true',
                          'Note: Gold safe boxes must link to tracks_weight=true',
                        ),
                        style: TextStyle(color: Colors.grey.shade700),
                        textAlign: widget.isArabic
                            ? TextAlign.right
                            : TextAlign.left,
                      ),
                    ),
                    if (widget.allowShowAllWhenTracksRequired)
                      Switch.adaptive(
                        value: _showAll,
                        onChanged: (v) => setState(() => _showAll = v),
                      ),
                    if (widget.allowShowAllWhenTracksRequired)
                      Text(
                        _t('عرض الكل', 'Show all'),
                        style: TextStyle(color: Colors.grey.shade800),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _t('النتائج: ${rows.length}', 'Results: ${rows.length}'),
                      style: TextStyle(color: Colors.grey.shade700),
                      textAlign: widget.isArabic
                          ? TextAlign.right
                          : TextAlign.left,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _searchController.clear(),
                    icon: const Icon(Icons.clear),
                    label: Text(_t('مسح', 'Clear')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: rows.isEmpty
                    ? Center(
                        child: Text(
                          _t('لا توجد نتائج', 'No results'),
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final acc = rows[index];
                          final id = acc['id'] is int
                              ? acc['id'] as int
                              : int.tryParse('${acc['id']}');
                          final isSelected =
                              widget.initialAccountId != null &&
                              id == widget.initialAccountId;
                          final subtitle = widget.requireTracksWeight
                              ? (_tracksWeight(acc)
                                    ? _t('يتتبع الوزن', 'Tracks weight')
                                    : _t(
                                        'لا يتتبع الوزن',
                                        'Does not track weight',
                                      ))
                              : null;

                          return ListTile(
                            dense: true,
                            selected: isSelected,
                            title: Text(
                              _labelFor(acc),
                              textAlign: widget.isArabic
                                  ? TextAlign.right
                                  : TextAlign.left,
                            ),
                            subtitle: subtitle == null
                                ? null
                                : Text(
                                    subtitle,
                                    textAlign: widget.isArabic
                                        ? TextAlign.right
                                        : TextAlign.left,
                                    style: TextStyle(
                                      color: _tracksWeight(acc)
                                          ? Colors.green.shade700
                                          : Colors.red.shade700,
                                    ),
                                  ),
                            trailing:
                                widget.requireTracksWeight &&
                                    !_tracksWeight(acc)
                                ? Icon(
                                    Icons.warning_amber,
                                    color: Colors.red.shade600,
                                  )
                                : null,
                            onTap: () {
                              // When gold safe box requires tracks_weight, allow browsing all
                              // but prevent selecting an invalid account.
                              if (widget.requireTracksWeight &&
                                  !_tracksWeight(acc)) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      _t(
                                        'لا يمكن اختيار هذا الحساب لخزنة الذهب لأنه لا يتتبع الوزن.',
                                        'Cannot select for gold safe box (tracks_weight=false).',
                                      ),
                                    ),
                                    backgroundColor: Colors.red.shade700,
                                  ),
                                );
                                return;
                              }
                              Navigator.pop<Map<String, dynamic>>(context, acc);
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_t('إلغاء', 'Cancel')),
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
}
