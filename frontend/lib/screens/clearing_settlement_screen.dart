import 'dart:convert';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart' as theme;
import '../utils.dart';
import '../widgets/account_picker_sheet.dart';
import '../widgets/safe_box_picker_dialog.dart';

class ClearingSettlementScreen extends StatefulWidget {
  final int? initialClearingSafeBoxId;
  final int? initialBankSafeBoxId;

  /// Maximum settleable amount (due amount) from the monitor screen.
  final double? initialDueAmount;

  /// IDs of the selected invoice payments from the monitor screen.
  final List<int>? initialInvoicePaymentIds;

  /// Number of selected transactions — pre-fills the tx-count field.
  final int? initialTxCount;

  /// The server; tests pass a fake. Defaults to the app's [ApiService].
  final ApiService? apiService;

  const ClearingSettlementScreen({
    super.key,
    this.initialClearingSafeBoxId,
    this.initialBankSafeBoxId,
    this.initialDueAmount,
    this.initialInvoicePaymentIds,
    this.initialTxCount,
    this.apiService,
  });

  @override
  State<ClearingSettlementScreen> createState() =>
      _ClearingSettlementScreenState();
}

class _ClearingSettlementScreenState extends State<ClearingSettlementScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();

  final TextEditingController _grossController = TextEditingController();
  final TextEditingController _feeController = TextEditingController(text: '0');
  final TextEditingController _rateController = TextEditingController(
    text: '0',
  );
  final TextEditingController _fixedFeeController = TextEditingController(
    text: '0',
  );
  final TextEditingController _txCountController = TextEditingController(
    text: '1',
  );
  final TextEditingController _referenceController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  String? _error;

  bool _autoCalcFee = true;
  bool _updatingFee = false;
  bool _feeAlreadyAppliedInInvoice = false;

  // VAT settings (used for journal preview; backend is source of truth)
  bool _taxEnabled = true;
  double _taxRate = 0.15;
  bool _settingsLoaded = false;

  List<SafeBoxModel> _safeBoxes = <SafeBoxModel>[];
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _paymentMethods = <Map<String, dynamic>>[];

  SafeBoxModel? _clearingSafe;
  SafeBoxModel? _bankSafe;
  Map<String, dynamic>? _feeAccount;

  // Matched payment method from clearing safe selection
  Map<String, dynamic>? _matchedPaymentMethod;
  bool _autoSettlementEnabled = false;
  String? _settlementScheduleInfo;

  List<Map<String, dynamic>> _pendingTransactions = [];
  bool _loadingPendingTxs = false;

  /// المبلغ المستحق الفعلي من API (المستحقات - ما تمت تسويته)
  double? _dueAmount;

  // Settlement history — loaded for admin/manager reversal
  List<Map<String, dynamic>> _settlementHistory = [];
  bool _loadingHistory = false;

  DateTime _settlementDate = DateTime.now();

  /// The payments this settlement settles, as chosen in the clearing monitor;
  /// null when the screen was opened without a choice (then the server takes
  /// the box's pending payments oldest-first). CLEARING-SEL-1: the screen once
  /// sent every pending payment even when some were chosen, and the server
  /// settled the oldest -- AV-2026-00472/00473 landed on the wrong invoice.
  List<int>? get _chosenPaymentIds {
    final ids = widget.initialInvoicePaymentIds;
    return (ids == null || ids.isEmpty) ? null : ids;
  }

  /// The pending rows this settlement covers: the chosen ones, or all.
  List<Map<String, dynamic>> get _coveredTransactions {
    final chosen = _chosenPaymentIds;
    if (chosen == null) return _pendingTransactions;
    return _pendingTransactions
        .where((tx) => chosen.contains(tx['invoice_payment_id']))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _dueAmount = widget.initialDueAmount;
    // Pre-fill gross from initialDueAmount if available
    if (widget.initialDueAmount != null && widget.initialDueAmount! > 0) {
      final prefill = widget.initialDueAmount!.toStringAsFixed(2);
      _grossController.text = prefill;
    }
    // Pre-fill tx count from monitor selection
    if (widget.initialTxCount != null && widget.initialTxCount! > 1) {
      _txCountController.text = widget.initialTxCount!.toString();
    }
    // Track last text values to avoid unnecessary setState on cursor-only changes
    _lastGrossText = _grossController.text;
    _lastRateText = _rateController.text;
    _lastFixedFeeText = _fixedFeeController.text;
    _lastTxCountText = _txCountController.text;
    _lastFeeText = _feeController.text;
    _grossController.addListener(_onGrossChanged);
    _rateController.addListener(_onRateChanged);
    _fixedFeeController.addListener(_onFixedFeeChanged);
    _txCountController.addListener(_onTxCountChanged);
    _feeController.addListener(_onFeeFieldChanged);
    _load();
  }

  // Last-known text values to detect real text changes vs cursor moves
  String _lastGrossText = '';
  String _lastRateText = '';
  String _lastFixedFeeText = '';
  String _lastTxCountText = '';
  String _lastFeeText = '';
  bool _summaryRefreshScheduled = false;

  /// Schedule a single post-frame setState to refresh the summary card.
  /// Coalesces multiple rapid changes into one rebuild.
  void _scheduleRefresh() {
    if (_summaryRefreshScheduled) return;
    _summaryRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _summaryRefreshScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _onGrossChanged() {
    if (_grossController.text == _lastGrossText) return;
    _lastGrossText = _grossController.text;
    _recomputeFeeIfNeeded();
    _scheduleRefresh();
  }

  void _onRateChanged() {
    if (_rateController.text == _lastRateText) return;
    _lastRateText = _rateController.text;
    _recomputeFeeIfNeeded();
    _scheduleRefresh();
  }

  void _onFixedFeeChanged() {
    if (_fixedFeeController.text == _lastFixedFeeText) return;
    _lastFixedFeeText = _fixedFeeController.text;
    _recomputeFeeIfNeeded();
    _scheduleRefresh();
  }

  void _onTxCountChanged() {
    if (_txCountController.text == _lastTxCountText) return;
    _lastTxCountText = _txCountController.text;
    _recomputeFeeIfNeeded();
    _scheduleRefresh();
  }

  void _onFeeFieldChanged() {
    if (_updatingFee) return;
    if (_feeController.text == _lastFeeText) return;
    _lastFeeText = _feeController.text;
    _scheduleRefresh();
  }

  @override
  void dispose() {
    _grossController.removeListener(_onGrossChanged);
    _rateController.removeListener(_onRateChanged);
    _fixedFeeController.removeListener(_onFixedFeeChanged);
    _txCountController.removeListener(_onTxCountChanged);
    _feeController.removeListener(_onFeeFieldChanged);
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
      List<Map<String, dynamic>> paymentMethods = <Map<String, dynamic>>[];
      try {
        final pmsRaw = await _api.getActivePaymentMethods();
        paymentMethods = pmsRaw
            .whereType<Map<String, dynamic>>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      } catch (_) {
        paymentMethods = <Map<String, dynamic>>[];
      }
      final accountsRaw = await _api.getAccounts();
      final accounts = accountsRaw
          .whereType<Map<String, dynamic>>()
          .map((m) => m)
          .toList();

      // Load settings for VAT rate (best-effort)
      bool taxEnabled = true;
      double taxRate = 0.15;
      bool settingsLoaded = false;
      try {
        final settings = await _api.getSettings();
        final rawEnabled = settings['tax_enabled'];
        final rawRate = settings['tax_rate'];
        taxEnabled = (rawEnabled is bool)
            ? rawEnabled
            : (rawEnabled?.toString().toLowerCase() == 'true');
        double parsedRate = 0.15;
        if (rawRate is num) {
          parsedRate = rawRate.toDouble();
        } else {
          parsedRate = double.tryParse(rawRate?.toString() ?? '') ?? 0.15;
        }
        if (parsedRate > 1.0) parsedRate = parsedRate / 100.0;
        if (parsedRate < 0) parsedRate = parsedRate.abs();
        taxRate = parsedRate;
        settingsLoaded = true;
      } catch (_) {
        // ignore, keep defaults
        settingsLoaded = false;
      }

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
        _paymentMethods = paymentMethods;
        _accounts = accounts;
        _clearingSafe = defaultClearing;
        _bankSafe = defaultBank;
        _taxEnabled = taxEnabled;
        _taxRate = taxRate;
        _settingsLoaded = settingsLoaded;
        _loading = false;
      });

      // Apply default fee policy based on the selected clearing safe (if it maps to a payment method).
      _applyFeePolicyFromClearingSafe();

      // Load settlement history for admin/manager reversal.
      _loadHistory();

      // If policy indicates fee was already applied at invoice time, disable fee inputs to avoid double-deduction.
      if (_feeAlreadyAppliedInInvoice) {
        setState(() {
          _autoCalcFee = false;
          _rateController.text = '0';
          _fixedFeeController.text = '0';
          _txCountController.text = '1';
          _feeController.text = '0';
          _feeAccount = null;
        });
      }

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
    if (_feeAlreadyAppliedInInvoice) return;
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
    final newFeeText = rounded.toStringAsFixed(2);
    _feeController.text = newFeeText;
    _lastFeeText = newFeeText;
    _updatingFee = false;
  }

  String _formatMoney(double v) {
    return v.toStringAsFixed(2);
  }

  double _round2(double v) => double.tryParse(v.toStringAsFixed(2)) ?? v;

  String _accountNameById(int accountId) {
    for (final a in _accounts) {
      final rawId = a['id'];
      final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
      if (id != null && id == accountId) {
        final name = (a['name'] ?? '').toString();
        final number = (a['account_number'] ?? a['accountNumber'] ?? '')
            .toString();
        if (number.isNotEmpty) return '$number - $name';
        return name;
      }
    }
    return 'حساب #$accountId';
  }

  double _computeFeeVat(double fee) {
    if (_feeAlreadyAppliedInInvoice) return 0.0;
    if (!_taxEnabled) return 0.0;
    if (fee <= 0) return 0.0;
    return _round2(fee * _taxRate);
  }

  List<Map<String, dynamic>> _buildJournalPreviewLines({
    required double gross,
    required double fee,
    required double feeVat,
    required double net,
  }) {
    final lines = <Map<String, dynamic>>[];

    final bank = _bankSafe;
    final clearing = _clearingSafe;

    if (bank != null && net > 0) {
      lines.add({
        'side': 'debit',
        'label': 'مدين',
        'account': '${bank.name} — ${_accountNameById(bank.accountId)}',
        'amount': _round2(net),
      });
    }

    if (fee > 0) {
      final feeAccName = (_feeAccount?['name'] ?? '').toString();
      lines.add({
        'side': 'debit',
        'label': 'مدين',
        'account': feeAccName.isNotEmpty
            ? feeAccName
            : 'مصروف العمولة (غير محدد)',
        'amount': _round2(fee),
      });
    }

    if (feeVat > 0) {
      lines.add({
        'side': 'debit',
        'label': 'مدين',
        'account': 'ضريبة عمولة التحصيل (commission_vat / vat_receivable)',
        'amount': _round2(feeVat),
      });
    }

    if (clearing != null) {
      lines.add({
        'side': 'credit',
        'label': 'دائن',
        'account': '${clearing.name} — ${_accountNameById(clearing.accountId)}',
        'amount': _round2(gross),
      });
    }

    return lines;
  }

  Future<bool> _confirmJournalPreview({
    required double gross,
    required double fee,
    required double feeVat,
    required double net,
  }) async {
    final lines = _buildJournalPreviewLines(
      gross: gross,
      fee: fee,
      feeVat: feeVat,
      net: net,
    );

    final debitTotal = _round2(
      lines
          .where((l) => l['side'] == 'debit')
          .fold<double>(0.0, (sum, l) => sum + (l['amount'] as double? ?? 0.0)),
    );
    final creditTotal = _round2(
      lines
          .where((l) => l['side'] == 'credit')
          .fold<double>(0.0, (sum, l) => sum + (l['amount'] as double? ?? 0.0)),
    );

    final isBalanced = (debitTotal - creditTotal).abs() <= 0.02;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ملخص القيد قبل الحفظ'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.AppColors.primaryGold.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.black.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('الإجمالي: ${_formatMoney(gross)}'),
                      Text('العمولة: ${_formatMoney(fee)}'),
                      if (feeVat > 0)
                        Text(
                          'ضريبة العمولة: ${_formatMoney(feeVat)}'
                          '${_settingsLoaded ? '' : ' (تقديري)'}',
                        ),
                      Text('الصافي إلى البنك: ${_formatMoney(net)}'),
                      const SizedBox(height: 6),
                      Text(
                        _feeAlreadyAppliedInInvoice
                            ? 'ملاحظة: العمولة محسوبة في الفاتورة (لن تُخصم هنا).'
                            : 'ملاحظة: سيتم تسجيل العمولة أثناء التسوية.',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'سطور القيد:',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                ...lines.map((l) {
                  final side = (l['label'] ?? '').toString();
                  final account = (l['account'] ?? '').toString();
                  final amount = (l['amount'] as double? ?? 0.0);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color:
                                (side == 'مدين'
                                        ? theme.AppColors.success
                                        : theme.AppColors.error)
                                    .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            side,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: side == 'مدين'
                                  ? theme.AppColors.success
                                  : theme.AppColors.error,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            account,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _formatMoney(amount),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'إجمالي المدين: ${_formatMoney(debitTotal)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'إجمالي الدائن: ${_formatMoney(creditTotal)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  isBalanced ? 'القيد متوازن ✅' : 'تنبيه: القيد غير متوازن ⚠️',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: isBalanced
                        ? theme.AppColors.success
                        : theme.AppColors.error,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.AppColors.primaryGold,
              foregroundColor: Colors.black,
            ),
            child: const Text('تأكيد الحفظ'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
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
        selectedSafeBoxId: (type == 'clearing')
            ? _clearingSafe?.id
            : _bankSafe?.id,
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

    if (type == 'clearing') {
      _applyFeePolicyFromClearingSafe();
    }

    // Nudge fee recalculation when changing context.
    _recomputeFeeIfNeeded();
  }

  void _applyFeePolicyFromClearingSafe() {
    final clearingId = _clearingSafe?.id;
    if (clearingId == null) return;

    Map<String, dynamic>? matched;
    for (final pm in _paymentMethods) {
      final rawSbId = pm['default_safe_box_id'];
      final sbId = rawSbId is int
          ? rawSbId
          : int.tryParse(rawSbId?.toString() ?? '');
      if (sbId != null && sbId == clearingId) {
        matched = pm;
        break;
      }
    }

    // Build schedule info and auto-settlement flag
    String? scheduleInfo;
    bool autoSettlement = false;
    if (matched != null) {
      autoSettlement = matched['auto_settlement_enabled'] == true;
      // The schedule as the server reads it (ADR-037) -- not recomputed here.
      final summary = matched['schedule_summary']?.toString() ?? '';
      scheduleInfo = summary.isEmpty ? null : summary;
    }

    final timing = matched == null
        ? 'invoice'
        : (matched['commission_timing']?.toString().trim().toLowerCase() ??
              'invoice');
    final shouldTreatAsAlreadyApplied = timing != 'settlement';

    // Auto-select bank safe from settlement_bank_safe_box_id
    SafeBoxModel? autoBank;
    if (matched != null) {
      final rawBankId = matched['settlement_bank_safe_box_id'];
      final bankId = rawBankId is int
          ? rawBankId
          : int.tryParse(rawBankId?.toString() ?? '');
      if (bankId != null && _bankSafe?.id != bankId) {
        try {
          autoBank = _safeBoxes.firstWhere((s) => s.id == bankId);
        } catch (_) {}
      }
    }

    setState(() {
      _matchedPaymentMethod = matched;
      _autoSettlementEnabled = autoSettlement;
      _settlementScheduleInfo = scheduleInfo;

      _feeAlreadyAppliedInInvoice = shouldTreatAsAlreadyApplied;

      if (!shouldTreatAsAlreadyApplied && matched != null) {
        // timing == 'settlement': auto-populate commission fields
        final rate = (matched['commission_rate'] as num?)?.toDouble() ?? 0.0;
        final fixed =
            (matched['commission_fixed_amount'] as num?)?.toDouble() ?? 0.0;
        _rateController.text = _formatDecimalCompact(rate);
        _fixedFeeController.text = _formatDecimalCompact(fixed);
        _autoCalcFee = true;

        // Auto-select fee expense account from PM configuration
        final feeAccId = matched['fee_expense_account_id'];
        if (feeAccId != null) {
          final id = feeAccId is int
              ? feeAccId
              : int.tryParse(feeAccId.toString());
          if (id != null) {
            final found = _accounts.where((a) => a['id'] == id).firstOrNull;
            if (found != null) _feeAccount = found;
          }
        }
      } else {
        // timing == 'invoice': fee already in invoice, disable fee fields
        _autoCalcFee = false;
        _rateController.text = '0';
        _fixedFeeController.text = '0';
        _txCountController.text = '1';
        _feeController.text = '0';
        _feeAccount = null;
      }

      // Auto-select bank safe when PM specifies one
      if (autoBank != null) {
        _bankSafe = autoBank;
      }
    });

    _recomputeFeeIfNeeded();

    // Always load due_amount and pending transactions
    _loadPendingTransactions();
  }

  /// Loads unsettled transactions and due_amount for the selected clearing safe box.
  Future<void> _loadPendingTransactions() async {
    final clearingId = _clearingSafe?.id;
    if (clearingId == null) return;

    setState(() => _loadingPendingTxs = true);

    try {
      final res = await _api.getPendingSettlementTransactions(
        clearingSafeBoxId: clearingId,
      );
      final txList =
          (res['transactions'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      final chosen = _chosenPaymentIds;
      // With a choice, what may be settled is what was chosen -- not the box.
      final dueAmt = chosen == null
          ? (res['due_amount'] as num?)?.toDouble()
          : txList
                .where((tx) => chosen.contains(tx['invoice_payment_id']))
                .fold<double>(
                  0.0,
                  (sum, tx) => sum + ((tx['amount'] as num?)?.toDouble() ?? 0),
                );
      final txCountForFee = chosen == null
          ? (res['tx_count_for_fee'] as num?)?.toInt()
          : chosen.length;
      if (mounted) {
        setState(() {
          _pendingTransactions = txList;
          if (dueAmt != null) _dueAmount = dueAmt;
          _loadingPendingTxs = false;
        });
        // Auto-fill gross if still empty and due amount is known
        if (dueAmt != null && dueAmt > 0) {
          final currentGross = _parseAmount(_grossController.text);
          if (currentGross <= 0) {
            final prefill = dueAmt.toStringAsFixed(2);
            _grossController.text = prefill;
            _lastGrossText = prefill;
            _recomputeFeeIfNeeded();
          }
        }
        // Auto-fill tx count for per-transaction commission (bulk mode only)
        if (txCountForFee != null &&
            txCountForFee > 0 &&
            !_feeAlreadyAppliedInInvoice) {
          final currentTxCount = int.tryParse(_txCountController.text) ?? 0;
          if (currentTxCount <= 1) {
            _txCountController.text = txCountForFee.toString();
            _lastTxCountText = txCountForFee.toString();
            _recomputeFeeIfNeeded();
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pendingTransactions = [];
          _loadingPendingTxs = false;
        });
      }
    }
  }

  /// Formats a double compactly: no trailing zeros after decimal.
  String _formatDecimalCompact(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toString().replaceAll(RegExp(r'0+$'), '');
  }

  Future<void> _pickFeeAccount() async {
    final selected = await showAccountPickerBottomSheet(
      context: context,
      accounts: _accounts,
      title: 'اختيار حساب مصروف العمولة',
      isArabic: true,
      selectedId: _feeAccount?['id'] as int?,
      showTransactionTypeFilter: true,
      showTracksWeightFilter: false,
    );

    if (!mounted || selected == null) return;
    setState(() => _feeAccount = selected);
  }

  void _showSnack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error
            ? theme.AppColors.error
            : theme.AppColors.success,
      ),
    );
  }

  /// Load recent clearing settlement vouchers (for admin/manager reversal).
  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() => _loadingHistory = true);
    try {
      final res = await _api.getVouchers(
        referenceType: 'clearing_settlement',
        perPage: 15,
        sortBy: 'date',
        sortOrder: 'desc',
      );
      final raw = res['vouchers'];
      if (!mounted) return;
      setState(() {
        _settlementHistory = (raw is List)
            ? raw.whereType<Map<String, dynamic>>().toList()
            : [];
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _settlementHistory = []);
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  /// Reverse a clearing settlement voucher after admin confirmation.
  Future<void> _reverseSettlement(
    int voucherId,
    String voucherNumber,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('عكس التسوية'),
        content: Text(
          'هل تريد عكس سند التسوية رقم $voucherNumber؟\n'
          'سيتم إنشاء قيد محاسبي عكسي وإلغاء السند.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text(
              'عكس',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await _api.cancelVoucher(voucherId, 'عكس تسوية مقاصة');
      if (!mounted) return;
      _showSnack('تم عكس التسوية بنجاح');
      _loadHistory();
    } catch (e) {
      if (!mounted) return;
      _showSnack(e.toString(), error: true);
    }
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
    final fee = _feeAlreadyAppliedInInvoice
        ? 0.0
        : _parseAmount(_feeController.text);
    final feeVat = _computeFeeVat(fee);
    final net = gross - fee - feeVat;

    final availableClearing = _clearingSafe?.cashBalance ?? 0.0;

    if (gross <= 0) {
      _showSnack('أدخل مبلغ إجمالي صحيح', error: true);
      return;
    }

    if (_chosenPaymentIds != null && _coveredTransactions.isEmpty) {
      _showSnack(
        'الدفعات المحددة لم تعد معلّقة — عُد إلى شاشة المراقبة وحدّث القائمة',
        error: true,
      );
      return;
    }

    // Check against due_amount (if known) or clearing balance
    final cap = (_dueAmount != null && _dueAmount! > 0)
        ? _dueAmount!
        : availableClearing;
    if (cap > 0 && gross > (cap + 0.01)) {
      final label = _dueAmount != null
          ? 'المبلغ المستحق'
          : 'الرصيد المتاح في خزينة المستحقات';
      _showSnack(
        '$label ${_formatMoney(cap)} ولا يمكن تسوية مبلغ إجمالي ${_formatMoney(gross)}',
        error: true,
      );
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

    // Journal preview confirmation before saving
    final ok = await _confirmJournalPreview(
      gross: gross,
      fee: fee,
      feeVat: feeVat,
      net: net,
    );
    if (!ok) return;

    setState(() => _submitting = true);

    try {
      // The chosen payments, exactly; only without a choice, the box's
      // pending payments (the server settles those oldest-first).
      final ipIds =
          _chosenPaymentIds ??
          _pendingTransactions
              .map((tx) => tx['invoice_payment_id'] as int?)
              .whereType<int>()
              .toList();

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
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        invoicePaymentIds: ipIds.isNotEmpty ? ipIds : null,
      );

      final voucher = res['voucher'];
      String voucherNumber = '';
      if (voucher is Map<String, dynamic>) {
        voucherNumber =
            (voucher['voucher_number'] ?? voucher['voucherNumber'] ?? '')
                .toString();
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
              if (feeVat > 0) Text('ضريبة العمولة: ${_formatMoney(feeVat)}'),
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
        if (msg.startsWith('Exception:')) {
          msg = msg.substring('Exception:'.length).trim();
        }
        final decoded = json.decode(msg);
        if (decoded is Map<String, dynamic>) {
          final err = (decoded['error'] ?? decoded['message'] ?? '').toString();
          if (err == 'Clearing balance is insufficient for settlement') {
            final cb = (decoded['clearing_balance'] as num?)?.toDouble();
            final ga = (decoded['gross_amount'] as num?)?.toDouble();
            if (cb != null && ga != null) {
              msg =
                  'الرصيد المتاح في خزينة المستحقات ${_formatMoney(cb)} ولا يمكن تسوية مبلغ إجمالي ${_formatMoney(ga)}';
            } else {
              msg = 'الرصيد المتاح في خزينة المستحقات غير كافٍ لتنفيذ التسوية';
            }
          } else if (err == 'no_due_amount') {
            msg =
                decoded['message']?.toString() ?? 'لا يوجد مبلغ مستحق للتسوية';
          } else if (err == 'exceeds_due_amount') {
            msg =
                decoded['message']?.toString() ??
                'المبلغ المطلوب يتجاوز المبلغ المستحق للتسوية';
          } else {
            msg = (decoded['message'] ?? decoded['error'] ?? msg).toString();
          }
        }
      } catch (_) {}

      _showSnack(msg, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Which payments this settlement settles, shown before it is saved.
  Widget _buildCoveredPaymentsCard() {
    final chosen = _chosenPaymentIds != null;
    final rows = _coveredTransactions;
    final muted = TextStyle(fontSize: 12, color: Colors.grey.shade700);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chosen
                  ? 'الدفعات المحددة للتسوية'
                  : 'الدفعات المعلّقة في الخزينة',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              chosen
                  ? 'تُسوّى هذه الدفعات وحدها.'
                  : 'لم تُحدَّد دفعات: سيُوزَّع المبلغ على أقدم الدفعات المعلّقة أولاً. '
                        'لتسوية دفعة بعينها حدّدها من شاشة مراقبة المقاصة.',
              style: muted,
            ),
            const Divider(),
            if (rows.isEmpty)
              Text('الدفعات المحددة لم تعد معلّقة.', style: muted)
            else
              for (final tx in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          (tx['invoice_number'] ?? '').toString().isNotEmpty
                              ? 'فاتورة: ${tx['invoice_number']}'
                              : (tx['note'] ?? 'تحويل').toString(),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        _formatMoney((tx['amount'] as num?)?.toDouble() ?? 0),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
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

    final themeData = Theme.of(context);
    final isLight = themeData.brightness == Brightness.light;

    final gross = _parseAmount(_grossController.text);
    final fee = _feeAlreadyAppliedInInvoice
        ? 0.0
        : _parseAmount(_feeController.text);
    final feeVat = _computeFeeVat(fee);
    final net = gross - fee - feeVat;

    final availableClearing = _clearingSafe?.cashBalance ?? 0.0;
    // Use due_amount as the primary cap; fall back to clearing balance
    final effectiveCap = (_dueAmount != null && _dueAmount! > 0)
        ? _dueAmount!
        : availableClearing;
    final exceedsAvailable = effectiveCap > 0 && gross > (effectiveCap + 0.01);

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
                _SummaryCard(gross: gross, fee: fee, feeVat: feeVat, net: net),
                // Keep a stable ListView child to avoid index shifts that can
                // make TextFields lose focus while typing.
                Builder(
                  key: const ValueKey('clearing.vat_note'),
                  builder: (_) {
                    if (feeVat <= 0) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'ملاحظة: الصافي محسوب بعد خصم ضريبة العمولة (${(_taxRate * 100).toStringAsFixed(0)}%)'
                        '${_settingsLoaded ? '' : ' (قد تختلف حسب الإعدادات)'}',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
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
                          trailing: (_clearingSafe == null)
                              ? null
                              : Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.AppColors.primaryGold
                                        .withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    _formatMoney(availableClearing),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
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
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 380),
                  transitionBuilder: (child, animation) {
                    final slide =
                        Tween<Offset>(
                          begin: const Offset(0, 0.12),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOut,
                          ),
                        );
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: _matchedPaymentMethod != null
                      ? Padding(
                          key: ValueKey(_matchedPaymentMethod!['id']),
                          padding: const EdgeInsets.only(top: 12),
                          child: _PaymentMethodInfoCard(
                            paymentMethod: _matchedPaymentMethod!,
                            autoSettlementEnabled: _autoSettlementEnabled,
                            scheduleInfo: _settlementScheduleInfo,
                            feeAccountName: _feeAccount == null
                                ? null
                                : (_feeAccount?['name'] as String? ?? '')
                                      .trim()
                                      .isNotEmpty
                                ? _feeAccount!['name'] as String
                                : '${_feeAccount?['account_number'] ?? ''} - ${_feeAccount?['name'] ?? ''}',
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey(0)),
                ),

                if (!_loadingPendingTxs &&
                    _pendingTransactions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildCoveredPaymentsCard(),
                ],

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
                          key: const ValueKey('clearing.gross'),
                          controller: _grossController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [NormalizeNumberFormatter()],
                          decoration: InputDecoration(
                            labelText: 'الإجمالي (Gross)',
                            prefixIcon: const Icon(Icons.payments_outlined),
                            border: const OutlineInputBorder(),
                            helperText: (_clearingSafe == null)
                                ? null
                                : _dueAmount != null
                                ? 'المستحق: ${_formatMoney(_dueAmount!)} ${context.read<SettingsProvider>().currencySymbolText}  |  رصيد الخزينة: ${_formatMoney(availableClearing)}'
                                : 'الحد الأقصى المتاح: ${_formatMoney(availableClearing)}',
                            helperMaxLines: 2,
                            errorText: exceedsAvailable
                                ? (_dueAmount != null
                                      ? 'الإجمالي يتجاوز المبلغ المستحق (${_formatMoney(_dueAmount!)})'
                                      : 'الإجمالي يتجاوز الرصيد المتاح')
                                : null,
                          ),
                        ),
                        const SizedBox(height: 10),

                        SwitchListTile.adaptive(
                          value: _feeAlreadyAppliedInInvoice,
                          onChanged: (v) {
                            setState(() {
                              _feeAlreadyAppliedInInvoice = v;
                              if (v) {
                                _autoCalcFee = false;
                                _rateController.text = '0';
                                _fixedFeeController.text = '0';
                                _txCountController.text = '1';
                                _feeController.text = '0';
                                _feeAccount = null;
                              } else {
                                _autoCalcFee = true;
                              }
                            });
                            _recomputeFeeIfNeeded();
                          },
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'العمولة محسوبة في الفاتورة (لا تخصم مرة أخرى)',
                          ),
                          subtitle: Text(
                            _feeAlreadyAppliedInInvoice
                                ? 'سيتم تحويل كامل المبلغ من خزينة المستحقات إلى خزينة البنك بدون خصم عمولة هنا.'
                                : 'سيتم احتساب/تسجيل العمولة أثناء التسوية (قد يخصمها البنك عند الإيداع).',
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ),
                        const SizedBox(height: 10),

                        SwitchListTile.adaptive(
                          value: _autoCalcFee,
                          onChanged: _feeAlreadyAppliedInInvoice
                              ? null
                              : (v) {
                                  setState(() => _autoCalcFee = v);
                                  _recomputeFeeIfNeeded();
                                },
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'احتساب العمولة تلقائياً (نسبة + مبلغ ثابت)',
                          ),
                          subtitle: Text(
                            _autoCalcFee
                                ? 'سيتم احتساب العمولة تلقائياً وإرسالها كـ fee_amount'
                                : 'يمكنك إدخال العمولة يدوياً',
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ),
                        if (_autoCalcFee && !_feeAlreadyAppliedInInvoice)
                          Column(
                            children: [
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      key: const ValueKey('clearing.fee_rate'),
                                      controller: _rateController,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      inputFormatters: [
                                        NormalizeNumberFormatter(),
                                      ],
                                      enabled: !_feeAlreadyAppliedInInvoice,
                                      decoration: const InputDecoration(
                                        labelText: 'نسبة العمولة %',
                                        prefixIcon: Icon(Icons.percent),
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextField(
                                      key: const ValueKey(
                                        'clearing.fee_fixed_per_tx',
                                      ),
                                      controller: _fixedFeeController,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      inputFormatters: [
                                        NormalizeNumberFormatter(),
                                      ],
                                      enabled: !_feeAlreadyAppliedInInvoice,
                                      decoration: const InputDecoration(
                                        labelText: 'مبلغ ثابت/عملية',
                                        prefixIcon: Icon(Icons.attach_money),
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                key: const ValueKey('clearing.tx_count'),
                                controller: _txCountController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [NormalizeNumberFormatter()],
                                enabled: !_feeAlreadyAppliedInInvoice,
                                decoration: const InputDecoration(
                                  labelText: 'عدد العمليات',
                                  prefixIcon: Icon(
                                    Icons.confirmation_number_outlined,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ],
                          )
                        else
                          TextField(
                            key: const ValueKey('clearing.fee_manual'),
                            controller: _feeController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            inputFormatters: [NormalizeNumberFormatter()],
                            enabled: !_feeAlreadyAppliedInInvoice,
                            decoration: const InputDecoration(
                              labelText: 'العمولة (Fee)',
                              prefixIcon: Icon(Icons.percent),
                              border: OutlineInputBorder(),
                            ),
                          ),

                        if (_autoCalcFee && !_feeAlreadyAppliedInInvoice)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: TextField(
                              key: const ValueKey(
                                'clearing.fee_computed_readonly',
                              ),
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
                          onTap: () {
                            if (_feeAlreadyAppliedInInvoice) return;
                            _pickFeeAccount();
                          },
                          trailing: _feeAccount == null
                              ? null
                              : IconButton(
                                  tooltip: 'مسح',
                                  onPressed: _feeAlreadyAppliedInInvoice
                                      ? null
                                      : () =>
                                            setState(() => _feeAccount = null),
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
                        // The voucher's date is the bank statement's line
                        // (ADR-037): the day the money reached the bank.
                        _PickerTile(
                          title: 'تاريخ الإيداع في البنك',
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
                  label: Text(
                    _submitting ? 'جارٍ الحفظ...' : 'تنفيذ التسوية',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.AppColors.primaryGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                // ── Settlement history (admin/manager only) ──
                if (context.read<AuthProvider>().isManager) ...[
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'سجل التسويات السابقة',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              InkWell(
                                onTap: _loadHistory,
                                borderRadius: BorderRadius.circular(20),
                                child: const Padding(
                                  padding: EdgeInsets.all(4),
                                  child: Icon(Icons.refresh, size: 18),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_loadingHistory)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          else if (_settlementHistory.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'لا توجد تسويات سابقة',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            )
                          else
                            ..._settlementHistory.map((v) {
                              final voucherId =
                                  (v['id'] as num?)?.toInt() ?? 0;
                              final voucherNumber =
                                  v['voucher_number']?.toString() ??
                                  '#$voucherId';
                              final dateStr =
                                  (v['date'] ?? v['created_at'] ?? '')
                                      .toString();
                              final displayDate = dateStr.length >= 10
                                  ? dateStr.substring(0, 10)
                                  : dateStr;
                              final status =
                                  (v['status'] ?? '').toString();
                              final totalCash =
                                  (v['amount_cash'] as num?)?.toDouble() ??
                                  (v['total_cash'] as num?)?.toDouble() ??
                                  0.0;
                              final isActive = status == 'active' || status == 'approved';
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 5),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'سند: $voucherNumber',
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          if (displayDate.isNotEmpty)
                                            Text(
                                              displayDate,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Text(
                                      _formatMoney(totalCash),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (isActive)
                                      OutlinedButton(
                                        onPressed: () => _reverseSettlement(
                                          voucherId,
                                          voucherNumber,
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.red,
                                          side: const BorderSide(
                                            color: Colors.red,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 2,
                                          ),
                                          minimumSize: const Size(56, 30),
                                          tapTargetSize: MaterialTapTargetSize
                                              .shrinkWrap,
                                        ),
                                        child: const Text(
                                          'عكس',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      )
                                    else
                                      Chip(
                                        label: const Text(
                                          'ملغي',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        backgroundColor: Colors.grey.shade200,
                                        padding: EdgeInsets.zero,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _PaymentMethodInfoCard extends StatelessWidget {
  final Map<String, dynamic> paymentMethod;
  final bool autoSettlementEnabled;
  final String? scheduleInfo;
  final String? feeAccountName;

  const _PaymentMethodInfoCard({
    required this.paymentMethod,
    required this.autoSettlementEnabled,
    this.scheduleInfo,
    this.feeAccountName,
  });

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    final name = paymentMethod['name']?.toString() ?? '';
    final timing =
        (paymentMethod['commission_timing']?.toString().toLowerCase() ?? '')
            .trim();
    final rate = (paymentMethod['commission_rate'] as num?)?.toDouble() ?? 0.0;
    final fixed =
        (paymentMethod['commission_fixed_amount'] as num?)?.toDouble() ?? 0.0;

    String timingLabel;
    Color timingColor;
    if (timing == 'settlement') {
      timingLabel = 'عمولة عند التسوية';
      timingColor = Colors.orange.shade700;
    } else {
      timingLabel = 'عمولة محسوبة في الفاتورة';
      timingColor = Colors.green.shade700;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.AppColors.primaryGold.withValues(alpha: 0.10),
        border: Border.all(
          color: theme.AppColors.primaryGold.withValues(alpha: 0.40),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.credit_card_outlined,
                size: 18,
                color: theme.AppColors.darkGold,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'وسيلة الدفع: $name',
                  style: themeData.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (autoSettlementEnabled)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: Colors.green.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.autorenew,
                        size: 13,
                        color: Colors.green.shade700,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'تسوية تلقائية',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoChip(
                label: timingLabel,
                color: timingColor,
                icon: Icons.schedule,
              ),
              if (rate > 0)
                _InfoChip(
                  label:
                      'نسبة ${rate.toStringAsFixed(rate == rate.truncateToDouble() ? 0 : 2)}%',
                  color: Colors.blue.shade700,
                  icon: Icons.percent,
                ),
              if (fixed > 0)
                _InfoChip(
                  label:
                      'ثابت ${fixed.toStringAsFixed(fixed == fixed.truncateToDouble() ? 0 : 2)} ${context.read<SettingsProvider>().currencySymbolText}/عملية',
                  color: Colors.purple.shade700,
                  icon: Icons.attach_money,
                ),
              if (scheduleInfo != null)
                _InfoChip(
                  label: scheduleInfo!,
                  color: Colors.teal.shade700,
                  icon: Icons.event_repeat,
                ),
              if (feeAccountName != null)
                _InfoChip(
                  label: 'مصروف العمولة: $feeAccountName',
                  color: Colors.indigo.shade700,
                  icon: Icons.account_tree_outlined,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _InfoChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
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
  final double feeVat;
  final double net;

  const _SummaryCard({
    required this.gross,
    required this.fee,
    required this.feeVat,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: chipColor(value).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: context.read<SettingsProvider>().buildText(
                      context.read<SettingsProvider>().currencySymbolText,
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
            if (feeVat > 0) ...[
              const SizedBox(height: 10),
              context.read<SettingsProvider>().buildText(
                'ضريبة العمولة: ${feeVat.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}',
                style: themeData.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
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
                    (value == null || value!.trim().isEmpty)
                        ? 'اضغط للاختيار'
                        : value!,
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
            if (trailing != null)
              trailing!
            else
              const Icon(Icons.chevron_right),
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
            const Icon(
              Icons.error_outline,
              size: 48,
              color: theme.AppColors.error,
            ),
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
