import 'dart:convert';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart' as theme;
import '../utils.dart';
import '../widgets/safe_box_picker_dialog.dart';

class ClearingSettlementScreen extends StatefulWidget {
  final int? initialClearingSafeBoxId;
  final int? initialBankSafeBoxId;

  const ClearingSettlementScreen({
    super.key,
    this.initialClearingSafeBoxId,
    this.initialBankSafeBoxId,
  });

  @override
  State<ClearingSettlementScreen> createState() => _ClearingSettlementScreenState();
}

class _ClearingSettlementScreenState extends State<ClearingSettlementScreen> {
  final ApiService _api = ApiService();

  final TextEditingController _grossController = TextEditingController();
  final TextEditingController _feeController = TextEditingController(text: '0');
  final TextEditingController _rateController = TextEditingController(text: '0');
  final TextEditingController _fixedFeeController = TextEditingController(text: '0');
  final TextEditingController _txCountController = TextEditingController(text: '1');
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  String? _error;

  bool _autoCalcFee = true;
  bool _updatingFee = false;

  List<SafeBoxModel> _safeBoxes = <SafeBoxModel>[];
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];

  SafeBoxModel? _clearingSafe;
  SafeBoxModel? _bankSafe;
  Map<String, dynamic>? _feeAccount;

  DateTime _settlementDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _grossController.dispose();
    _feeController.dispose();
    _rateController.dispose();
    _fixedFeeController.dispose();
    _txCountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final safeBoxes = await _api.getPaymentSafeBoxes();
      final accountsRaw = await _api.getAccounts();
      final accounts = accountsRaw
          .whereType<Map<String, dynamic>>()
          .map((m) => m)
          .toList();

      SafeBoxModel? defaultClearing;
      SafeBoxModel? defaultBank;

      try {
        defaultClearing = safeBoxes.firstWhere(
          (sb) => (sb.safeType).toLowerCase() == 'clearing' && sb.isDefault,
          orElse: () => safeBoxes.firstWhere(
            (sb) => (sb.safeType).toLowerCase() == 'clearing',
            orElse: () => SafeBoxModel(
              id: null,
              name: '',
              safeType: 'clearing',
              accountId: 0,
            ),
          ),
        );
        if (defaultClearing.id == null) defaultClearing = null;
      } catch (_) {
        defaultClearing = null;
      }

      // Override with explicit initial selection if provided.
      final initialClearingId = widget.initialClearingSafeBoxId;
      if (initialClearingId != null) {
        try {
          final picked = safeBoxes.firstWhere(
            (sb) => (sb.id ?? -1) == initialClearingId,
          );
          if ((picked.safeType).toLowerCase() == 'clearing') {
            defaultClearing = picked;
          }
        } catch (_) {
          // ignore if not found
        }
      }

      try {
        defaultBank = safeBoxes.firstWhere(
          (sb) => (sb.safeType).toLowerCase() == 'bank' && sb.isDefault,
          orElse: () => safeBoxes.firstWhere(
            (sb) => (sb.safeType).toLowerCase() == 'bank',
            orElse: () => SafeBoxModel(
              id: null,
              name: '',
              safeType: 'bank',
              accountId: 0,
            ),
          ),
        );
        if (defaultBank.id == null) defaultBank = null;
      } catch (_) {
        defaultBank = null;
      }

      final initialBankId = widget.initialBankSafeBoxId;
      if (initialBankId != null) {
        try {
          final picked = safeBoxes.firstWhere(
            (sb) => (sb.id ?? -1) == initialBankId,
          );
          if ((picked.safeType).toLowerCase() == 'bank') {
            defaultBank = picked;
          }
        } catch (_) {
          // ignore if not found
        }
      }

      setState(() {
        _safeBoxes = safeBoxes;
        _accounts = accounts;
        _clearingSafe = defaultClearing;
        _bankSafe = defaultBank;
        _loading = false;
      });

      // If enabled, compute fee based on current inputs.
      _recomputeFeeIfNeeded();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  double _parseAmount(String raw) {
    final normalized = normalizeNumber(raw).trim().replaceAll(',', '');
    return double.tryParse(normalized) ?? 0.0;
  }

  int _parseInt(String raw, {int fallback = 0}) {
    final normalized = normalizeNumber(raw).trim().replaceAll(',', '');
    return int.tryParse(normalized) ?? fallback;
  }

  void _recomputeFeeIfNeeded() {
    if (!_autoCalcFee || _updatingFee) return;

    final gross = _parseAmount(_grossController.text);
    final rate = _parseAmount(_rateController.text);
    final fixedFee = _parseAmount(_fixedFeeController.text);
    final txCount = _parseInt(_txCountController.text, fallback: 1);

    final safeTxCount = txCount <= 0 ? 1 : txCount;
    final percentFee = gross > 0 ? (gross * (rate / 100.0)) : 0.0;
    final totalFee = (percentFee + (fixedFee * safeTxCount));
    final rounded = totalFee.isFinite ? totalFee : 0.0;

    _updatingFee = true;
    _feeController.text = rounded.toStringAsFixed(2);
    _updatingFee = false;
  }

  String _formatMoney(double v) {
    return v.toStringAsFixed(2);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _settlementDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    setState(() => _settlementDate = picked);
  }

  Future<void> _pickSafeBox({required String type}) async {
    final selected = await showDialog<SafeBoxModel>(
      context: context,
      builder: (_) => SafeBoxPickerDialog(
        safeBoxes: _safeBoxes,
        selectedSafeBoxId: (type == 'clearing') ? _clearingSafe?.id : _bankSafe?.id,
        filterSafeType: type,
        excludeGold: true,
      ),
    );

    if (!mounted || selected == null) return;

    setState(() {
      if (type == 'clearing') {
        _clearingSafe = selected;
      } else {
        _bankSafe = selected;
      }
    });
  }

  Future<void> _pickFeeAccount() async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AccountPickerDialog(accounts: _accounts, selectedId: _feeAccount?['id'] as int?),
    );

    if (!mounted || selected == null) return;
    setState(() => _feeAccount = selected);
  }

  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? theme.AppColors.error : theme.AppColors.success,
      ),
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final clearingId = _clearingSafe?.id;
    final bankId = _bankSafe?.id;

    if (clearingId == null) {
      _showSnack('اختر خزينة المستحقات أولاً', error: true);
      return;
    }

    if (bankId == null) {
      _showSnack('اختر خزينة البنك أولاً', error: true);
      return;
    }

    final gross = _parseAmount(_grossController.text);
    final fee = _parseAmount(_feeController.text);
    final net = gross - fee;

    if (gross <= 0) {
      _showSnack('أدخل مبلغ إجمالي صحيح', error: true);
      return;
    }

    if (fee < 0) {
      _showSnack('العمولة لا يمكن أن تكون سالبة', error: true);
      return;
    }

    if (net < 0) {
      _showSnack('العمولة لا يمكن أن تتجاوز الإجمالي', error: true);
      return;
    }

    if (fee > 0 && (_feeAccount == null || _feeAccount?['id'] == null)) {
      _showSnack('اختر حساب مصروف العمولة', error: true);
      return;
    }

    setState(() => _submitting = true);

    try {
      final res = await _api.createClearingSettlement(
        clearingSafeBoxId: clearingId,
        bankSafeBoxId: bankId,
        grossAmount: gross,
        feeAmount: fee,
        feeAccountId: fee > 0 ? (_feeAccount?['id'] as int?) : null,
        settlementDate: _settlementDate,
        referenceNumber: _referenceController.text.trim().isEmpty
            ? null
            : _referenceController.text.trim(),
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
      );

      final voucher = res['voucher'];
      String voucherNumber = '';
      if (voucher is Map<String, dynamic>) {
        voucherNumber = (voucher['voucher_number'] ?? voucher['voucherNumber'] ?? '').toString();
      }

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('تمت التسوية بنجاح'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (voucherNumber.isNotEmpty) Text('رقم السند: $voucherNumber'),
              const SizedBox(height: 8),
              Text('الإجمالي: ${_formatMoney(gross)}'),
              Text('العمولة: ${_formatMoney(fee)}'),
              Text('الصافي: ${_formatMoney(net)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('حسناً'),
            ),
          ],
        ),
      );

      _showSnack('تم إنشاء سند التسوية');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      String msg = e.toString();
      // Backend sometimes returns JSON as string.
      try {
        final decoded = json.decode(msg);
        if (decoded is Map<String, dynamic>) {
          msg = (decoded['message'] ?? decoded['error'] ?? msg).toString();
        }
      } catch (_) {}

      _showSnack(msg, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    final isLight = themeData.brightness == Brightness.light;

    final gross = _parseAmount(_grossController.text);
    final fee = _parseAmount(_feeController.text);
    final net = gross - fee;

    return Scaffold(
      appBar: AppBar(
        title: const Text('تسوية مستحقات تحصيل'),
        backgroundColor: theme.AppColors.primaryGold,
        foregroundColor: isLight ? Colors.black : Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null)
              ? _ErrorState(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _SummaryCard(
                      gross: gross,
                      fee: fee,
                      net: net,
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'الخزائن',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 10),
                            _PickerTile(
                              title: 'خزينة المستحقات (Clearing)',
                              value: _clearingSafe?.name,
                              icon: Icons.swap_horiz,
                              onTap: () => _pickSafeBox(type: 'clearing'),
                            ),
                            const SizedBox(height: 8),
                            _PickerTile(
                              title: 'خزينة البنك',
                              value: _bankSafe?.name,
                              icon: Icons.account_balance,
                              onTap: () => _pickSafeBox(type: 'bank'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'المبالغ',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _grossController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [NormalizeNumberFormatter()],
                              decoration: const InputDecoration(
                                labelText: 'الإجمالي (Gross)',
                                prefixIcon: Icon(Icons.payments_outlined),
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) {
                                setState(() {});
                                _recomputeFeeIfNeeded();
                              },
                            ),
                            const SizedBox(height: 10),
                            SwitchListTile.adaptive(
                              value: _autoCalcFee,
                              onChanged: (v) {
                                setState(() => _autoCalcFee = v);
                                _recomputeFeeIfNeeded();
                              },
                              contentPadding: EdgeInsets.zero,
                              title: const Text('احتساب العمولة تلقائياً (نسبة + مبلغ ثابت)'),
                              subtitle: Text(
                                _autoCalcFee
                                    ? 'سيتم احتساب العمولة تلقائياً وإرسالها كـ fee_amount'
                                    : 'يمكنك إدخال العمولة يدوياً',
                                style: TextStyle(color: Colors.grey.shade700),
                              ),
                            ),
                            if (_autoCalcFee)
                              Column(
                                children: [
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _rateController,
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          inputFormatters: [NormalizeNumberFormatter()],
                                          decoration: const InputDecoration(
                                            labelText: 'نسبة العمولة %',
                                            prefixIcon: Icon(Icons.percent),
                                            border: OutlineInputBorder(),
                                          ),
                                          onChanged: (_) {
                                            setState(() {});
                                            _recomputeFeeIfNeeded();
                                          },
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: TextField(
                                          controller: _fixedFeeController,
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          inputFormatters: [NormalizeNumberFormatter()],
                                          decoration: const InputDecoration(
                                            labelText: 'مبلغ ثابت/عملية',
                                            prefixIcon: Icon(Icons.attach_money),
                                            border: OutlineInputBorder(),
                                          ),
                                          onChanged: (_) {
                                            setState(() {});
                                            _recomputeFeeIfNeeded();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  TextField(
                                    controller: _txCountController,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [NormalizeNumberFormatter()],
                                    decoration: const InputDecoration(
                                      labelText: 'عدد العمليات',
                                      prefixIcon: Icon(Icons.confirmation_number_outlined),
                                      border: OutlineInputBorder(),
                                    ),
                                    onChanged: (_) {
                                      setState(() {});
                                      _recomputeFeeIfNeeded();
                                    },
                                  ),
                                ],
                              )
                            else
                              TextField(
                                controller: _feeController,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                inputFormatters: [NormalizeNumberFormatter()],
                                decoration: const InputDecoration(
                                  labelText: 'العمولة (Fee)',
                                  prefixIcon: Icon(Icons.percent),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),

                            if (_autoCalcFee)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: TextField(
                                  controller: _feeController,
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    labelText: 'العمولة المحتسبة (Fee)',
                                    prefixIcon: Icon(Icons.calculate_outlined),
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            _PickerTile(
                              title: 'حساب مصروف العمولة',
                              value: _feeAccount == null
                                  ? null
                                  : '${_feeAccount?['account_number'] ?? ''} - ${_feeAccount?['name'] ?? ''}',
                              icon: Icons.receipt_long,
                              onTap: _pickFeeAccount,
                              trailing: _feeAccount == null
                                  ? null
                                  : IconButton(
                                      tooltip: 'مسح',
                                      onPressed: () => setState(() => _feeAccount = null),
                                      icon: const Icon(Icons.close),
                                    ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'ملاحظة: يلزم تحديد حساب مصروف العمولة فقط إذا كانت العمولة > 0',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'بيانات إضافية',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 10),
                            _PickerTile(
                              title: 'تاريخ التسوية',
                              value:
                                  '${_settlementDate.year}-${_settlementDate.month.toString().padLeft(2, '0')}-${_settlementDate.day.toString().padLeft(2, '0')}',
                              icon: Icons.event,
                              onTap: _pickDate,
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _referenceController,
                              decoration: const InputDecoration(
                                labelText: 'رقم مرجعي (اختياري)',
                                prefixIcon: Icon(Icons.tag),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _descriptionController,
                              decoration: const InputDecoration(
                                labelText: 'وصف (اختياري)',
                                prefixIcon: Icon(Icons.notes),
                                border: OutlineInputBorder(),
                              ),
                              maxLines: 2,
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _notesController,
                              decoration: const InputDecoration(
                                labelText: 'ملاحظات (اختياري)',
                                prefixIcon: Icon(Icons.sticky_note_2_outlined),
                                border: OutlineInputBorder(),
                              ),
                              maxLines: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _submit,
                      icon: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(_submitting ? 'جارٍ الحفظ...' : 'تنفيذ التسوية'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.AppColors.primaryGold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final double gross;
  final double fee;
  final double net;

  const _SummaryCard({
    required this.gross,
    required this.fee,
    required this.net,
  });

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    final bool isLight = themeData.brightness == Brightness.light;

    Color chipColor(double value) {
      if (value < 0) return theme.AppColors.error;
      if (value == 0) return Colors.grey;
      return theme.AppColors.success;
    }

    Widget metric(String label, double value) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isLight ? Colors.white : themeData.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: themeData.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    value.toStringAsFixed(2),
                    style: themeData.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: chipColor(value).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      'SAR',
                      style: TextStyle(
                        color: chipColor(value),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.AppColors.lightGold.withValues(alpha: 0.35),
            theme.AppColors.primaryGold.withValues(alpha: 0.18),
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ملخص التسوية',
              style: themeData.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                metric('الإجمالي', gross),
                const SizedBox(width: 10),
                metric('العمولة', fee),
                const SizedBox(width: 10),
                metric('الصافي', net),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  final String title;
  final String? value;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailing;

  const _PickerTile({
    required this.title,
    required this.value,
    required this.icon,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        ),
        child: Row(
          children: [
            Icon(icon, color: theme.AppColors.darkGold),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: themeData.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (value == null || value!.trim().isEmpty) ? 'اضغط للاختيار' : value!,
                    style: themeData.textTheme.bodyMedium?.copyWith(
                      color: (value == null || value!.trim().isEmpty)
                          ? Colors.grey.shade700
                          : themeData.colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing! else const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: theme.AppColors.error),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> accounts;
  final int? selectedId;

  const _AccountPickerDialog({required this.accounts, this.selectedId});

  @override
  State<_AccountPickerDialog> createState() => _AccountPickerDialogState();
}

class _AccountPickerDialogState extends State<_AccountPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _filtered() {
    final q = _q.trim().toLowerCase();
    final items = widget.accounts.where((a) {
      final numStr = (a['account_number'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final nameEn = (a['name_en'] ?? '').toString().toLowerCase();
      if (q.isEmpty) return true;
      return numStr.contains(q) || name.contains(q) || nameEn.contains(q);
    }).toList();

    items.sort((a, b) {
      final an = (a['account_number'] ?? '').toString();
      final bn = (b['account_number'] ?? '').toString();
      return an.compareTo(bn);
    });

    return items;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();

    return AlertDialog(
      title: const Text('اختيار حساب'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'ابحث برقم الحساب/الاسم',
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () => setState(() {
                          _q = '';
                          _search.clear();
                        }),
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 10),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'لا توجد نتائج',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final a = filtered[index];
                    final id = a['id'] as int?;
                    final selected = (id != null && id == widget.selectedId);
                    final number = (a['account_number'] ?? '').toString();
                    final name = (a['name'] ?? '').toString();

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: selected
                            ? theme.AppColors.primaryGold.withValues(alpha: 0.18)
                            : Colors.grey.shade200,
                        child: Icon(
                          Icons.account_tree_outlined,
                          color: selected ? theme.AppColors.darkGold : Colors.grey.shade700,
                        ),
                      ),
                      title: Text('$number - $name'),
                      trailing: selected
                          ? Icon(Icons.check_circle, color: theme.AppColors.darkGold)
                          : null,
                      onTap: () => Navigator.pop(context, a),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}
