import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/inline_number_cell.dart';
import '../widgets/supplier_invoice_picker.dart';
import '../utils/voucher_readiness.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../models/employee_model.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'voucher_saved_screen.dart';
import '../utils.dart';
import '../widgets/account_picker_sheet.dart';
import '../widgets/party_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';
import '../utils/bidi.dart';
import '../utils/party_balance.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_shortcuts.dart';

class GoldLineEntryModel {
  double amount;
  double? karat;
  double? grossWeight;
  double? netWeight;
  double? stonesWeight;
  // عمولة / رسوم فرق العيار لكل سطر
  double commissionPerGram;
  String commissionDirection; // '' = بدون | 'earn' = عمولة | 'pay' = رسوم

  GoldLineEntryModel({
    this.amount = 0,
    this.karat,
    this.grossWeight,
    this.netWeight,
    this.stonesWeight,
    this.commissionPerGram = 0,
    this.commissionDirection = '',
  });

  double get commissionTotal => amount * commissionPerGram;

  Map<String, dynamic> toJson() => {
    'amount': amount,
    if (karat != null) 'karat': karat,
    if (grossWeight != null) 'gross_weight': grossWeight,
    if (netWeight != null) 'net_weight': netWeight,
    if (stonesWeight != null) 'stones_weight': stonesWeight,
  };

  factory GoldLineEntryModel.fromJson(Map<String, dynamic> map) {
    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return GoldLineEntryModel(
      amount: toDouble(map['amount']) ?? 0,
      karat: toDouble(map['karat']),
      grossWeight: toDouble(map['gross_weight']),
      netWeight: toDouble(map['net_weight']),
      stonesWeight: toDouble(map['stones_weight']),
      commissionPerGram: toDouble(map['commission_per_gram']) ?? 0,
      commissionDirection: (map['commission_direction'] as String?) ?? '',
    );
  }
}

class _CommissionToggleButton extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _CommissionToggleButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? effectiveColor.withOpacity(0.15)
              : Colors.transparent,
          border: Border.all(
            color: selected ? effectiveColor : theme.colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected
                ? effectiveColor
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// نموذج لسطر حساب في السند
class AccountLineModel {
  int? accountId;
  String lineType; // 'debit' or 'credit'
  String amountType; // 'cash' or 'gold'
  double amount;
  double? karat;
  final List<GoldLineEntryModel> goldEntries;
  String? description;

  /// The account was put there by the screen (the safe most used), not
  /// picked: only then is it said to have been filled.
  bool accountAutoFilled = false;

  AccountLineModel({
    this.accountId,
    required this.lineType,
    required this.amountType,
    this.amount = 0,
    this.karat,
    List<GoldLineEntryModel>? goldEntries,
    this.description,
  }) : goldEntries = goldEntries ?? [];

  void ensureGoldEntries(double defaultKarat) {
    if (amountType != 'gold') return;
    if (goldEntries.isEmpty) {
      goldEntries.add(
        GoldLineEntryModel(
          amount: amount > 0 ? amount : 0,
          karat: karat ?? defaultKarat,
        ),
      );
    }
  }

  void syncFromGoldEntries({required double defaultKarat}) {
    if (amountType != 'gold') {
      amount = 0;
      karat = null;
      return;
    }

    if (goldEntries.isEmpty) {
      amount = 0;
      karat = defaultKarat;
      return;
    }

    amount = goldEntries.fold<double>(0, (sum, e) => sum + e.amount);
    if (goldEntries.length == 1) {
      karat = goldEntries.first.karat ?? defaultKarat;
    } else {
      karat = null;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      if (accountId != null) 'account_id': accountId,
      'line_type': lineType,
      'amount_type': amountType,
      'amount': amount,
      if (karat != null) 'karat': karat,
      if (goldEntries.isNotEmpty)
        'gold_entries': goldEntries.map((e) => e.toJson()).toList(),
      if (description != null && description!.isNotEmpty)
        'description': description,
    };
  }
}

class AddVoucherScreen extends StatefulWidget {
  final String voucherType; // 'receipt' or 'payment'
  final Map<String, dynamic>? existingVoucher; // optional: edit mode
  final int? initialSupplierId; // optional: quick-create for a supplier
  final String? initialPartyType;
  final int? initialOtherAccountId;
  final String? initialDescription;

  /// The server; a test hands its own.
  final ApiService? apiService;

  const AddVoucherScreen({
    super.key,
    required this.voucherType,
    this.existingVoucher,
    this.initialSupplierId,
    this.initialPartyType,
    this.initialOtherAccountId,
    this.initialDescription,
    this.apiService,
  });

  @override
  State<AddVoucherScreen> createState() => _AddVoucherScreenState();
}

class _AddVoucherScreenState extends State<AddVoucherScreen> {
  // الألوان من الثيم (ثيم-٠): تتبع الوضعين.
  ColorScheme get _cs => Theme.of(context).colorScheme;
  AppSemanticColors get _tone => AppSemanticColors.of(context);

  /// The voucher's own color: green for a receipt, indigo for a payment --
  /// never the error red (ADR-049).
  SemanticTone get _voucherTone => _tone.voucher(
    widget.voucherType == 'receipt' ? VoucherKind.receipt : VoucherKind.payment,
  );

  final _formKey = GlobalKey<FormState>();

  /// The party card is measured after it is drawn; the invoice card beside it
  /// never grows past its height (the owner, 10 Oct 2026).
  final _partyCardKey = GlobalKey();
  double? _partyCardHeight;
  late final ApiService _apiService = widget.apiService ?? ApiService();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _receiverNameController = TextEditingController();

  final List<AccountLineModel> _accountLines = [];
  final List<String> _attachedFileNames = [];

  // Raw incoming account lines from server when opening in edit mode.
  // We store them until accounts/customers/safes are loaded so we can
  // correctly separate party lines from editable account lines.
  List<Map<String, dynamic>>? _incomingAccountLinesRaw;

  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _accounts = [];
  // The group accounts (some account is under them): not posted to.
  Set<int> _parentAccountIds = {};
  List<SafeBoxModel> _safeBoxes = [];

  int? _customersAggregateAccountId;
  String? _customersAggregateAccountNumber;
  int? _suppliersAggregateAccountId;
  String? _suppliersAggregateAccountNumber;

  // The groups the templates filter by -- mapped roles on the server and the ids
  // under them (/app-config account_groups), never account numbers (CHART-002 5c).
  // A group's own account is left out: a voucher line takes an employee's account.
  Set<int> _employeePersonalIds = const {};
  Set<int> _employeeSalaryPayableIds = const {};
  int? _employeeBonusPayableParentId;
  Set<int> _expenseIds = const {};

  final Map<int, double> _safeLedgerCashBalance = {};
  final Set<int> _safeLedgerCashBalanceLoading = {};
  final Map<int, int> _safeUsageCounts = {};
  static const String _safeUsagePrefsKey = 'yasargold_safe_usage_counts_v1';
  List<EmployeeModel> _employees = [];

  int? _selectedCustomerId;
  int? _selectedSupplierId;

  /// The invoices this supplier payment is for (VOUCHER-ATTR-1, the owner
  /// 9 Oct 2026): ticked by the employee; the server spreads the payment over
  /// them oldest first, and what they do not owe stays on account.
  List<Map<String, dynamic>> _invoiceCandidates = const [];
  bool _loadingInvoiceCandidates = false;
  int? _candidatesSupplierId; // whose open invoices are loaded
  final Set<int> _chosenInvoiceIds = {};
  Map<String, dynamic>? _paymentPlan;
  String? _planKey;

  /// A gold payment for gold not yet bought (an advance), asked only when no
  /// invoice is chosen.
  bool _goldAdvance = false;
  int _amountFillEpoch = 0; // rebuilds the amount field when it is filled

  int? _selectedEmployeeId;
  int? _selectedOtherAccountId;

  bool _isLoading = false;
  bool _isSaving = false;

  /// The review is open: nothing is being sent yet.
  bool _inReview = false;

  String _partyType = 'customer';
  String? _selectedTemplateId;

  // تتبع آخر نص بيان وُلِّد تلقائياً — حتى لا نُلغي تعديلات المستخدم اليدوية
  String? _lastAutoDesc;
  String? _lastAutoReceiver;

  DateTime _selectedDate = DateTime.now();

  bool _checkedLocalDraft = false;

  int _currencyDecimalPlaces = 2;
  int _mainKarat = 21;

  SettingsProvider? _settingsProvider;

  final List<double> _availableKarats = const [24, 22, 21, 18];

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _loadSafeUsageCounts();
    if (widget.voucherType == 'payment') {
      _partyType = 'supplier';
    }
    _accountLines.add(
      AccountLineModel(
        lineType: widget.voucherType == 'receipt' ? 'debit' : 'credit',
        amountType: 'cash',
      ),
    );

    if (widget.existingVoucher != null) {
      _populateFromExisting(widget.existingVoucher!);
    }

    if (widget.existingVoucher == null) {
      // The party it was opened for: a supplier named stays chosen whether
      // or not its kind is named with it (it used to be cleared by it).
      final initialPartyType = (widget.initialPartyType ?? '').trim();
      if (widget.initialSupplierId != null &&
          (initialPartyType.isEmpty || initialPartyType == 'supplier')) {
        _partyType = 'supplier';
        _selectedSupplierId = widget.initialSupplierId;
        _selectedCustomerId = null;
        _selectedEmployeeId = null;
        _selectedOtherAccountId = null;
      } else if (initialPartyType.isNotEmpty) {
        _partyType = initialPartyType;
        _selectedCustomerId = null;
        _selectedSupplierId = null;
        _selectedEmployeeId = null;
        _selectedOtherAccountId = initialPartyType == 'other'
            ? widget.initialOtherAccountId
            : null;
      } else if (widget.initialOtherAccountId != null) {
        _partyType = 'other';
        _selectedCustomerId = null;
        _selectedSupplierId = null;
        _selectedEmployeeId = null;
        _selectedOtherAccountId = widget.initialOtherAccountId;
      }

      final initialDescription = (widget.initialDescription ?? '').trim();
      if (initialDescription.isNotEmpty &&
          _descriptionController.text.trim().isEmpty) {
        _descriptionController.text = initialDescription;
      }
    }

    if (widget.existingVoucher == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybePromptRestoreLocalDraft();
      });
    }

    _loadData();
  }

  String _localDraftKey() {
    return 'yasargold_voucher_draft_${widget.voucherType}';
  }

  Map<String, dynamic> _buildLocalDraftPayload() {
    return {
      'voucher_type': widget.voucherType,
      'date': _selectedDate.toIso8601String(),
      'party_type': _partyType,
      'customer_id': _selectedCustomerId,
      'supplier_id': _selectedSupplierId,
      'employee_id': _selectedEmployeeId,
      'other_account_id': _selectedOtherAccountId,
      'description': _descriptionController.text,
      'notes': _notesController.text,
      'receiver_name': _receiverNameController.text,
      'account_lines': _accountLines.map((l) => l.toJson()).toList(),
    };
  }

  AccountLineModel _accountLineFromJson(Map<String, dynamic> jsonLine) {
    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return int.tryParse('${v ?? ''}');
    }

    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return AccountLineModel(
      accountId: toInt(jsonLine['account_id']),
      lineType: (jsonLine['line_type'] ?? 'debit').toString(),
      amountType: (jsonLine['amount_type'] ?? 'cash').toString(),
      amount: toDouble(jsonLine['amount']) ?? 0,
      karat: toDouble(jsonLine['karat']),
      goldEntries: (jsonLine['gold_entries'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => GoldLineEntryModel.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      description: jsonLine['description']?.toString(),
    );
  }

  void _ensureAtLeastOneLine() {
    if (_accountLines.isNotEmpty) return;
    _accountLines.add(
      AccountLineModel(
        lineType: widget.voucherType == 'receipt' ? 'debit' : 'credit',
        amountType: 'cash',
      ),
    );
  }

  Future<void> _saveLocalDraft({bool showToast = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = _buildLocalDraftPayload();
    await prefs.setString(_localDraftKey(), jsonEncode(payload));

    if (showToast && mounted) {
      AppFeedback.success(context, 'تم حفظ السند لإكماله لاحقاً');
    }
  }

  Future<void> _clearLocalDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localDraftKey());
  }

  Future<void> _maybePromptRestoreLocalDraft() async {
    if (!mounted || _checkedLocalDraft) return;
    _checkedLocalDraft = true;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localDraftKey());
    if (raw == null || raw.trim().isEmpty) return;

    Map<String, dynamic>? decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      // If draft is corrupted, just remove it.
      await _clearLocalDraft();
      return;
    }

    final bool? restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('محفوظ للإكمال لاحقاً'),
        content: const Text('يوجد سند محفوظ لإكماله لاحقاً. هل تريد استعادته؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('تجاهل'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('استعادة'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (restore != true) {
      await _clearLocalDraft();
      return;
    }

    try {
      setState(() {
        int? toInt(dynamic v) {
          if (v is int) return v;
          if (v is num) return v.toInt();
          if (v is String) return int.tryParse(v);
          return int.tryParse('${v ?? ''}');
        }

        final dateRaw = decoded?['date']?.toString();
        if (dateRaw != null && dateRaw.isNotEmpty) {
          _selectedDate = DateTime.tryParse(dateRaw) ?? _selectedDate;
        }

        _partyType = (decoded?['party_type'] ?? _partyType).toString();
        _selectedCustomerId = toInt(decoded?['customer_id']);
        _selectedSupplierId = toInt(decoded?['supplier_id']);
        _selectedEmployeeId = toInt(decoded?['employee_id']);
        _selectedOtherAccountId = toInt(decoded?['other_account_id']);

        _descriptionController.text = (decoded?['description'] ?? '')
            .toString();
        _notesController.text = (decoded?['notes'] ?? '').toString();
        _receiverNameController.text = (decoded?['receiver_name'] ?? '')
            .toString();

        _accountLines.clear();
        final rawLines = (decoded?['account_lines'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        for (final line in rawLines) {
          _accountLines.add(_accountLineFromJson(line));
        }
        _ensureAtLeastOneLine();
      });
    } catch (_) {
      // If something goes wrong during restore, discard the draft.
      await _clearLocalDraft();
    }
  }

  // Move populate/apply helpers to instance methods so they can be reused
  // after metadata loads.
  void _populateFromExisting(Map<String, dynamic> v) {
    try {
      if (v['date'] != null) {
        _selectedDate = DateTime.tryParse(v['date']) ?? _selectedDate;
      }
      _descriptionController.text = (v['description'] ?? '') as String;
      // The note the employee wrote, not the splits riding with it, and the
      // invoices the voucher was written for (VOUCHER-ATTR-1).
      _notesController.text = '${v['note_text'] ?? v['notes'] ?? ''}';
      _chosenInvoiceIds
        ..clear()
        ..addAll([
          for (final id in (v['invoice_ids'] as List? ?? const []))
            if (id is num) id.toInt(),
        ]);
      _receiverNameController.text = (v['receiver_name'] ?? '') as String;

      final partyType = (v['party_type'] ?? '') as String;
      if (partyType.isNotEmpty) {
        _partyType = partyType;
      }
      if (_partyType == 'customer') {
        _selectedCustomerId = v['customer_id'] as int?;
      } else if (_partyType == 'supplier') {
        _selectedSupplierId = v['supplier_id'] as int?;
      } else if (_partyType == 'employee') {
        _selectedEmployeeId = v['employee_id'] as int?;
      }

      final rawLines = (v['account_lines'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _incomingAccountLinesRaw = rawLines;

      if (_partyType == 'other') {
        final String partyLineType = widget.voucherType == 'receipt'
            ? 'credit'
            : 'debit';
        final Map<String, dynamic> partyLine = rawLines.firstWhere(
          (line) => line['line_type'] == partyLineType,
          orElse: () => <String, dynamic>{},
        );
        final candidateId = _coerceAccountId(partyLine['account_id']);
        if (candidateId != null) {
          _selectedOtherAccountId = candidateId;
        }
      }

      _accountLines.clear();
    } catch (_) {
      // ignore and keep defaults if population fails
    }
  }

  /// After account/safe/customer data is loaded, convert incoming raw lines into
  /// editable `_accountLines`, excluding the party-side lines which are stored on the
  /// voucher but are not user-editable (they are auto-generated from the other lines).
  void _applyIncomingAccountLinesIfNeeded() {
    if (_incomingAccountLinesRaw == null) return;

    try {
      double? toDouble(dynamic v) {
        if (v == null) return null;
        if (v is double) return v;
        if (v is int) return v.toDouble();
        if (v is num) return v.toDouble();
        return double.tryParse(v.toString());
      }

      // The party's side -- credit on a receipt, debit on a payment -- is the
      // line the screen writes itself; every line typed is on the other side.
      // Told apart by side, not by account: a gold party line is stored on
      // the party's weight twin, not on the account the screen knows.
      final String partyLineType = widget.voucherType == 'receipt'
          ? 'credit'
          : 'debit';
      if (_partyType == 'other' && _selectedOtherAccountId == null) {
        final Map<String, dynamic> partyLine = _incomingAccountLinesRaw!
            .firstWhere(
              (line) => line['line_type'] == partyLineType,
              orElse: () => <String, dynamic>{},
            );
        final candidateId = _coerceAccountId(partyLine['account_id']);
        if (candidateId != null) _selectedOtherAccountId = candidateId;
      }

      final List<AccountLineModel> applied = [];
      for (final map in _incomingAccountLinesRaw!) {
        final mapAccountId = map['account_id'] is num
            ? (map['account_id'] as num).toInt()
            : null;

        if (map['line_type'] == partyLineType) continue;

        final amountType = (map['amount_type'] ?? 'cash') as String;
        final karat = map['karat'] != null
            ? (map['karat'] as num).toDouble()
            : null;
        final amount = (map['amount'] is num)
            ? (map['amount'] as num).toDouble()
            : double.tryParse('${map['amount']}') ?? 0.0;
        applied.add(
          AccountLineModel(
            accountId: mapAccountId,
            lineType: (map['line_type'] ?? 'debit') as String,
            amountType: amountType,
            amount: amount,
            karat: karat,
            goldEntries: amountType == 'gold'
                ? [
                    GoldLineEntryModel(
                      amount: amount,
                      karat: karat,
                      grossWeight: toDouble(map['gross_weight']),
                      netWeight: toDouble(map['net_weight']),
                      stonesWeight: toDouble(map['stones_weight']),
                    ),
                  ]
                : [],
            description: map['description'] as String?,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        if (applied.isNotEmpty) {
          _accountLines
            ..clear()
            ..addAll(applied);
        } else {
          _accountLines
            ..clear()
            ..add(
              AccountLineModel(
                lineType: widget.voucherType == 'receipt' ? 'debit' : 'credit',
                amountType: 'cash',
              ),
            );
        }
        _incomingAccountLinesRaw = null;
      });
    } catch (_) {
      _incomingAccountLinesRaw = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<SettingsProvider>(context);
    if (_settingsProvider != provider ||
        _currencySymbol != provider.currencySymbol ||
        _currencyDecimalPlaces != provider.decimalPlaces ||
        _mainKarat != provider.mainKarat) {
      setState(() {
        _settingsProvider = provider;
        _currencyDecimalPlaces = provider.decimalPlaces;
        _mainKarat = provider.mainKarat;
      });
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _notesController.dispose();
    _receiverNameController.dispose();
    super.dispose();
  }

  double get _totalCash => _accountLines
      .where((line) => line.amountType == 'cash')
      .fold(0.0, (sum, line) => sum + line.amount);

  Map<double, double> get _totalGoldByKarat {
    final Map<double, double> totals = {};
    for (final line in _accountLines) {
      if (line.amountType != 'gold') continue;
      final entries = _effectiveGoldEntries(line);
      for (final entry in entries) {
        final karat = entry.karat ?? _mainKarat.toDouble();
        totals[karat] = (totals[karat] ?? 0) + entry.amount;
      }
    }
    return totals;
  }

  /// The first thing in the way of saving, or null (VOUCHER-UX-1).
  String? get _blocker {
    final partyChosen = switch (_partyType) {
      'customer' => _selectedCustomerId != null,
      'supplier' => _selectedSupplierId != null,
      'employee' => _selectedEmployeeId != null,
      _ => _selectedOtherAccountId != null,
    };
    return voucherReadiness(
      VoucherFacts(
        partyType: _partyType,
        partyChosen: partyChosen,
        lines: [
          for (final line in _accountLines)
            VoucherLineFacts(
              hasAccount: line.accountId != null,
              isGold: line.amountType == 'gold',
              amount: line.amount,
              gold: [
                if (line.amountType == 'gold')
                  for (final e in _effectiveGoldEntries(line))
                    VoucherGoldFacts(
                      weight: e.amount,
                      hasKarat: e.karat != null,
                      gross: e.grossWeight,
                      stones: e.stonesWeight,
                    ),
              ],
            ),
        ],
        unbalanced: _balanceDiff > 0.01,
      ),
    );
  }

  /// Something typed that leaving would lose.
  bool get _hasEntries => _accountLines.any(
    (l) =>
        l.amount > 0 ||
        (l.amountType == 'gold' &&
            _effectiveGoldEntries(l).any((e) => e.amount > 0)),
  );

  void _saveIfReady() {
    if (_blocker != null || _isSaving || _isLoading) return;
    _saveVoucher();
  }

  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('سند غير محفوظ'),
        content: const Text('ما كُتب في السند لم يُحفظ بعد.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'stay'),
            child: const Text('البقاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'discard'),
            child: const Text('اخرج دون حفظ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'draft'),
            child: const Text('احفظه مسودة واخرج'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'stay') return;
    if (choice == 'draft') await _saveLocalDraft(showToast: false);
    if (mounted) Navigator.of(context).pop(false);
  }

  String get _partyLabel {
    switch (_partyType) {
      case 'customer':
        return '${_findById(_customers, _selectedCustomerId)?['name'] ?? '—'}';
      case 'supplier':
        return '${_findById(_suppliers, _selectedSupplierId)?['name'] ?? '—'}';
      case 'employee':
        return _findEmployeeById(_selectedEmployeeId)?.name ?? '—';
      default:
        return '${_findAccountById(_selectedOtherAccountId)?['name'] ?? '—'}';
    }
  }

  String _lineAccountLabel(AccountLineModel line) =>
      _findSafeByAccountId(line.accountId)?.name ??
      '${_findAccountById(line.accountId)?['name'] ?? '—'}';

  /// Each line as it is said -- where, and how much -- in the review and on
  /// the page that says the voucher was saved.
  List<(String, String)> get _lineSummaries => [
    for (final line in _accountLines) ..._lineSummary(line),
  ];

  List<(String, String)> _lineSummary(AccountLineModel line) =>
      line.amountType == 'gold'
      ? [
          for (final e in _effectiveGoldEntries(line))
            if (e.amount > 0)
              (
                _lineAccountLabel(line),
                '${formatGrams(e.amount)} جم عيار ${formatAmount(e.karat ?? 0, decimals: 0)}',
              ),
        ]
      : [(_lineAccountLabel(line), _formatCash(line.amount))];

  /// The review before saving: the party, the date, each line's account and
  /// amount or weights, what it is for, and the saved vouchers like it.
  Future<bool> _review(Map<String, dynamic> voucherData) async {
    var similar = const <Map<String, dynamic>>[];
    var similarUnknown = false;
    try {
      similar = await _apiService.similarVouchers({
        ...voucherData,
        if (widget.existingVoucher?['id'] != null)
          'exclude_id': widget.existingVoucher!['id'],
      });
    } catch (_) {
      similarUnknown = true;
    }
    if (!mounted) return false;

    final isReceipt = widget.voucherType == 'receipt';
    final tones = AppSemanticColors.of(context);
    final theme = Theme.of(context);
    String day(Object? iso) => '${iso ?? ''}'.length >= 10
        ? '${iso ?? ''}'.substring(0, 10)
        : '${iso ?? ''}';
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    final planLines = _planLines;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isReceipt ? 'مراجعة سند قبض' : 'مراجعة سند صرف'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row(isReceipt ? 'من' : 'إلى', _partyLabel),
                row('التاريخ', day(_selectedDate.toIso8601String())),
                const Divider(),
                for (final (where, what) in _lineSummaries) row(where, what),
                if (planLines.isNotEmpty) ...[
                  const Divider(),
                  for (final line in planLines) Text(line),
                ],
                if (_descriptionController.text.trim().isNotEmpty)
                  row('البيان', _descriptionController.text.trim()),
                if (similar.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: tones.warning.container,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'سند مشابه محفوظ — تأكد أنه ليس تكرارًا:',
                          style: TextStyle(
                            color: tones.warning.onContainer,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        for (final v in similar)
                          Text(
                            '${v['voucher_number'] ?? '#${v['id']}'} — ${day(v['date'])} — '
                            '${((v['amount_cash'] as num?) ?? 0) > 0 ? _formatCash(((v['amount_cash'] as num?) ?? 0).toDouble()) : '${formatGrams(((v['amount_gold'] as num?) ?? 0).toDouble())} جم'}',
                            style: TextStyle(color: tones.warning.onContainer),
                          ),
                      ],
                    ),
                  ),
                ] else if (similarUnknown) ...[
                  const SizedBox(height: 12),
                  Text(
                    'تعذّر التحقق من السندات المشابهة.',
                    style: TextStyle(color: tones.warning.fg),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            key: const Key('voucher-review-save'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(similar.isEmpty ? 'حفظ السند' : 'حفظ رغم التشابه'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  double get _balanceDiff {
    double debitTotal = 0;
    double creditTotal = 0;

    for (final line in _accountLines) {
      final normalized = _normalizeLineAmount(line);
      if (line.lineType == 'debit') {
        debitTotal += normalized;
      } else {
        creditTotal += normalized;
      }
    }

    if (debitTotal == 0 || creditTotal == 0) {
      return 0;
    }

    return (debitTotal - creditTotal).abs();
  }

  double _normalizeLineAmount(AccountLineModel line) {
    if (line.amountType == 'gold') {
      if (_mainKarat <= 0) {
        return line.amount;
      }

      final entries = _effectiveGoldEntries(line);
      double total = 0;
      for (final entry in entries) {
        final karat = entry.karat ?? _mainKarat.toDouble();
        total += entry.amount * (karat / _mainKarat);
      }
      return total;
    }
    return line.amount;
  }

  Future<void> _pickFiles() async {
    if (!mounted) return;
    AppFeedback.info(context, 'ميزة إرفاق الملفات غير متاحة حالياً.');
  }

  Map<String, dynamic>? _findById(List<Map<String, dynamic>> items, int? id) {
    if (id == null) {
      return null;
    }
    try {
      return items.firstWhere((item) => item['id'] == id);
    } catch (_) {
      return null;
    }
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  /// A chosen party with no account of its own, nor a category: its line
  /// goes on the aggregate -- the only case the field says so.
  bool _onAggregate(Map<String, dynamic>? party) =>
      party != null &&
      _coerceAccountId(party['account_id']) == null &&
      _coerceAccountId(party['account_category_id']) == null;

  String? _selectedPartyName(String partyType) {
    if (partyType == 'customer') {
      final selected = _findById(_customers, _selectedCustomerId);
      final name = (selected?['name'] ?? '').toString().trim();
      return name.isEmpty ? null : name;
    }
    if (partyType == 'supplier') {
      final selected = _findById(_suppliers, _selectedSupplierId);
      final name = (selected?['name'] ?? '').toString().trim();
      return name.isEmpty ? null : name;
    }
    return null;
  }

  Future<void> _pickCustomer() async {
    if (_customers.isEmpty) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => PartyPickerDialog(
        title: 'اختيار عميل',
        items: _customers,
        selectedId: _selectedCustomerId,
        emptyText: 'لا يوجد عميل مطابق',
        currencySymbol: _currencySymbol,
      ),
    );
    if (selected == null) return;
    final id = _toInt(selected['id']);
    if (id == null) return;
    setState(() {
      _selectedCustomerId = id;
      _smartFillDescriptionAndReceiver();
    });
  }

  Future<void> _pickSupplier() async {
    if (_suppliers.isEmpty) return;
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => PartyPickerDialog(
        title: 'اختيار مورد',
        items: _suppliers,
        selectedId: _selectedSupplierId,
        emptyText: 'لا يوجد مورد مطابق',
        currencySymbol: _currencySymbol,
      ),
    );
    if (selected == null) return;
    final id = _toInt(selected['id']);
    if (id == null) return;
    setState(() {
      _selectedSupplierId = id;
      // Another supplier's invoices are not this payment's candidates.
      _invoiceCandidates = const [];
      _chosenInvoiceIds.clear();
      _paymentPlan = null;
      _planKey = null;
      _smartFillDescriptionAndReceiver();
    });
    if (_showInvoicePicker) _loadInvoiceCandidates();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final results = await Future.wait([
        _apiService.getCustomers(),
        _apiService.getSuppliers(),
        _apiService.getEmployees(isActive: true, perPage: 200),
        _apiService.getAccounts(skipBalances: true),
        _apiService.getAppConfig(),
      ]);

      final customers = results[0] as List<dynamic>;
      final suppliers = results[1] as List<dynamic>;
      final employeesData = results[2] as Map<String, dynamic>;
      final accounts = results[3] as List<dynamic>;
      final appConfig = results[4] as Map<String, dynamic>;

      // تحميل الخزائن النشطة (نقدية وبنكية فقط)
      final safeBoxes = await _apiService.getSafeBoxes(
        safeType: null, // جميع الأنواع
        isActive: true,
        includeAccount: true,
        includeBalance: true,
      );

      final aggregate = (appConfig['aggregate_accounts'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      final customersAgg = (aggregate?['customers'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      final suppliersAgg = (aggregate?['suppliers'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );

      final groups = (appConfig['account_groups'] as Map?)?.map(
        (k, v) => MapEntry(k.toString(), v),
      );
      Set<int> childrenOf(String name) {
        final g = groups?[name];
        if (g is! Map) return const {};
        final root = _coerceAccountId(g['account_id']);
        return ((g['subtree_ids'] as List?) ?? const [])
            .map(_coerceAccountId)
            .whereType<int>()
            .where((id) => id != root)
            .toSet();
      }

      final employeePersonalIds = childrenOf('employee_personal');
      final employeeSalaryPayableIds = childrenOf('employee_salary_payable');
      final bonusGroup = groups?['employee_bonus_payable'];
      final employeeBonusPayableParentId = bonusGroup is Map
          ? _coerceAccountId(bonusGroup['account_id'])
          : null;
      // The expense template offers operating expenses (the owner, 20 Oct
      // 2026: not purchases or cost of sales); all expenses where that
      // group is not mapped.
      Set<int> idsOf(String name) {
        final g = groups?[name];
        return g is Map
            ? ((g['subtree_ids'] as List?) ?? const [])
                  .map(_coerceAccountId)
                  .whereType<int>()
                  .toSet()
            : <int>{};
      }

      final operatingIds = idsOf('operating_expenses');
      final expenseIds = operatingIds.isNotEmpty
          ? operatingIds
          : idsOf('expenses');

      final customersAggId = _coerceAccountId(customersAgg?['account_id']);
      final customersAggNumber = customersAgg?['account_number']?.toString();
      final suppliersAggId = _coerceAccountId(suppliersAgg?['account_id']);
      final suppliersAggNumber = suppliersAgg?['account_number']?.toString();

      setState(() {
        _customers = customers
            .whereType<Map<String, dynamic>>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList();
        _suppliers = suppliers
            .whereType<Map<String, dynamic>>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
        _employees =
            (employeesData['employees'] as List<EmployeeModel>? ??
            <EmployeeModel>[]);
        _accounts = accounts
            .whereType<Map<String, dynamic>>()
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
        _parentAccountIds = parentAccountIdsOf(_accounts);
        _safeBoxes = safeBoxes;

        _customersAggregateAccountId = customersAggId;
        _customersAggregateAccountNumber = customersAggNumber;
        _suppliersAggregateAccountId = suppliersAggId;
        _suppliersAggregateAccountNumber = suppliersAggNumber;
        _employeePersonalIds = employeePersonalIds;
        _employeeSalaryPayableIds = employeeSalaryPayableIds;
        _employeeBonusPayableParentId = employeeBonusPayableParentId;
        _expenseIds = expenseIds;

        _isLoading = false;
      });

      _applyIncomingAccountLinesIfNeeded();
      // توليد البيان والمستلم تلقائياً بعد اكتمال تحميل البيانات
      // (يُغطي حالة الفتح من مورد/عميل عبر initialSupplierId/initialPartyType)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _smartFillDescriptionAndReceiver(),
      );
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        AppFeedback.error(context, e, title: 'خطأ في تحميل البيانات');
      }
    }
  }

  List<dynamic> _getFilteredAccounts({String? lineType, String? amountType}) {
    // تحديد متى نعرض الخزائن بناءً على نوع السند:
    // - سند القبض: الخزائن مدينة (debit) - نستقبل فيها
    // - سند الصرف: الخزائن دائنة (credit) - نصرف منها
    final bool isReceipt = widget.voucherType == 'receipt';
    final bool shouldShowSafeBoxes =
        (isReceipt && lineType == 'debit') ||
        (!isReceipt && lineType == 'credit');

    if (shouldShowSafeBoxes) {
      // فلترة الخزائن حسب نوع المبلغ
      final filteredSafes = _safeBoxes.where((sb) {
        if (amountType == 'gold') {
          return sb.safeType == 'gold';
        }
        // الوضع الافتراضي (نقد/شيكات/بنك)
        return sb.safeType == 'cash' ||
            sb.safeType == 'bank' ||
            sb.safeType == 'clearing' ||
            sb.safeType == 'check';
      }).toList();

      final safeOptions = filteredSafes
          .map(
            (sb) => {
              'id': sb.accountId,
              'account_number': sb.account?.accountNumber ?? '',
              'name': sb.name, // اسم الخزينة
              'safe_type': sb.safeType, // نوع الخزينة
              'bank_name': sb.bankName, // اسم البنك
              'is_default': sb.isDefault, // افتراضي
              'safe_balance': sb.balance?.cash,
              'safe_weight': sb.balance?.weight,
              'safe_karat': sb.karat,
              'safe_model': sb,
            },
          )
          .toList();

      // Special case: Salary payment with advance deduction.
      // In the salary template, allow adding a second CREDIT cash line that targets
      // the employee's personal account (its group from /app-config) to reduce the advance
      // balance as part of the same voucher.
      final bool allowEmployeeAdvanceOffset =
          widget.voucherType != 'receipt' &&
          (lineType ?? '') == 'credit' &&
          (amountType ?? '') == 'cash' &&
          _selectedTemplateId == 'payment_salary';

      if (!allowEmployeeAdvanceOffset) {
        return safeOptions;
      }

      final employeeAccounts = _accounts
          .where(
            (acc) => _employeePersonalIds.contains(_coerceAccountId(acc['id'])),
          )
          .toList();

      // Combine: safes first (common UX), then employee accounts.
      return [...safeOptions, ...employeeAccounts];
    }

    // للحالات الأخرى: نعرض الحسابات العادية

    // فلترة الحسابات: إظهار الحسابات التفصيلية فقط (ما ليس أبًا لحساب)،
    // وتطابق نوع المبلغ (نقدي/ذهب) لهذا السطر تلقائياً -- بنفس حقل
    // transaction_type المستخدَم في فلتر "نقدي/ذهبي/كلاهما" بديلوج
    // "الطرف: آخر"، فيتغيّر محتوى القائمة فوراً عند تبديل نوع السطر بدل
    // اختلاط حسابات نقدية ووزنية معاً بلا علاقة بما هو محدَّد.
    final detailedAccounts = _accounts.where((acc) {
      if (!isLeafAccount(acc, _parentAccountIds)) {
        return false; // حسابات تفصيلية فقط
      }

      final t = (acc['transaction_type'] ?? 'both').toString().toLowerCase();
      if (amountType == 'gold') return t == 'gold' || t == 'both';
      return t == 'cash' || t == 'both';
    }).toList();

    // ترتيب الحسابات حسب الرقم (كانت قائمة «شائعة» بأرقام مكتوبة، عشرة من
    // أحد عشر منها لا وجود لها على الإنتاج — CHART-002)
    detailedAccounts.sort(
      (a, b) => a['account_number'].toString().compareTo(
        b['account_number'].toString(),
      ),
    );

    return detailedAccounts;
  }

  SafeBoxModel? _findSafeByAccountId(int? accountId) {
    if (accountId == null) {
      return null;
    }
    try {
      return _safeBoxes.firstWhere((sb) => sb.accountId == accountId);
    } catch (_) {
      return null;
    }
  }

  /// Returns 'cash'/'gold' if the given party account only makes sense as
  /// one amount type, or null if it's free (dual account, or no party
  /// selected). A safe box forces its own type; a plain account forces its
  /// type unless it has a linked memo_account_id (dual -- the backend's
  /// _resolve_account_id_for_amount_type already redirects gold lines to
  /// the memo account at approval, so both types are valid and nothing
  /// needs forcing).
  String? _lockedAmountTypeForAccount(int? partyAccountId) {
    final safe = _findSafeByAccountId(partyAccountId);
    if (safe != null) {
      return safe.safeType == 'gold' ? 'gold' : 'cash';
    }
    final account = _findAccountById(partyAccountId);
    if (account == null) return null;
    final tracksWeight = account['tracks_weight'] == true;
    final hasMemo = account['memo_account_id'] != null;
    if (tracksWeight) return 'gold';
    if (!hasMemo) return 'cash';
    return null; // dual account -- leave lines free.
  }

  /// The amount type lines must currently use, given the selected party for
  /// party types where the picked account also implies a financial/weight
  /// nature ("آخر" today). Drives both forcing existing lines (see
  /// _syncLinesAmountTypeToParty) and disabling the non-matching radio
  /// option in the line UI so the user can't switch back manually.
  String? get _lockedAmountTypeForCurrentParty {
    if (_partyType != 'other') return null;
    return _lockedAmountTypeForAccount(_selectedOtherAccountId);
  }

  /// When the party (الطرف) is a safe box, force all lines to match its type:
  /// gold safe → all lines become gold; cash/bank safe → all lines become cash.
  ///
  /// When it's a plain account (not safe-linked), its nature still narrows
  /// what makes sense: a pure weight/memo account (tracks_weight) only
  /// accepts gold lines, and a cash account with no linked memo
  /// (memo_account_id) only accepts cash lines -- same single-type lock as
  /// a safe box, just account-driven instead of safe-driven. A cash account
  /// that DOES have a memo_account_id is dual (e.g. a regular supplier/
  /// customer-style account): both cash and gold are valid, the backend
  /// already redirects gold lines to the memo account at approval (see
  /// _resolve_account_id_for_amount_type in routes.py) -- so leave lines
  /// free to be either type, no forcing needed.
  void _syncLinesAmountTypeToParty(int? partyAccountId) {
    final targetType = _lockedAmountTypeForAccount(partyAccountId);
    if (targetType == null) return;

    for (final line in _accountLines) {
      if (line.amountType == targetType) continue;
      line.amountType = targetType;
      if (targetType == 'gold') {
        line.ensureGoldEntries(_mainKarat.toDouble());
        _syncGoldSummary(line);
      } else {
        line.goldEntries.clear();
        line.karat = null;
      }
      // Switch the line's account to a matching safe
      final existingSafe = _findSafeByAccountId(line.accountId);
      if (existingSafe != null &&
          !_safeMatchesAmountType(existingSafe, targetType)) {
        final def = _defaultSafeForAmountType(
          lineType: line.lineType,
          amountType: targetType,
        );
        _autoFill(line, def?.accountId);
      }
    }
  }

  /// What an account offered for a line holds of the line's kind -- «فيها
  /// 410.600 جم عيار 21» -- from the balances the accounts came with; null
  /// when they did not come with any.
  String? _accountHolds(int? accountId, String kind) {
    if (accountId == null) return null;
    final safe = _findSafeByAccountId(accountId);
    if (kind == 'gold') {
      // The account's live weight where the accounts came with it, else the
      // safe's own -- the banner's sources, in the banner's order.
      final weight = safe?.balance?.weight;
      double? held(int k) =>
          _getLiveAccountWeightBalance(accountId, k) ??
          switch (k) {
            24 => weight?.karat24,
            22 => weight?.karat22,
            21 => weight?.karat21,
            _ => weight?.karat18,
          };
      final known = [for (final k in const [24, 22, 21, 18]) held(k)];
      if (known.every((v) => v == null)) return null;
      final said = [
        for (final (i, k) in const [24, 22, 21, 18].indexed)
          if ((known[i] ?? 0).abs() >= 0.0005)
            '${ltrIsolate(formatGrams(known[i]!))} جم عيار $k',
      ];
      return said.isEmpty ? 'لا ذهب فيها' : 'فيها ${said.join(' • ')}';
    }
    final cash = safe != null
        ? _getAvailableSafeCash(safe)
        : _getLiveAccountCashBalance(accountId);
    return cash == null ? null : 'فيها ${_formatCash(cash)}';
  }


  /// A line's account put there by the screen, said so on the line.
  void _autoFill(AccountLineModel line, int? accountId) {
    line.accountId = accountId;
    line.accountAutoFilled = accountId != null;
  }

  Map<String, dynamic>? _findAccountById(int? accountId) {
    if (accountId == null) {
      return null;
    }
    try {
      return _accounts.firstWhere(
        (account) => _coerceAccountId(account['id']) == accountId,
      );
    } catch (_) {
      return null;
    }
  }

  double? _getLiveAccountCashBalance(int? accountId) {
    final account = _findAccountById(accountId);
    if (account == null) {
      return null;
    }
    final balances = account['balances'];
    if (balances is Map) {
      final cash = balances['cash'];
      if (cash is num) {
        return cash.toDouble();
      }
      if (cash != null) {
        return double.tryParse(cash.toString());
      }
    }
    return null;
  }

  double? _getLiveAccountWeightBalance(int? accountId, int karat) {
    final account = _findAccountById(accountId);
    if (account == null) {
      return null;
    }
    final balances = account['balances'];
    if (balances is! Map) {
      return null;
    }
    final weight = balances['weight'];
    if (weight is! Map) {
      return null;
    }
    final raw = weight['${karat}k'];
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw != null) {
      return double.tryParse(raw.toString());
    }
    return null;
  }

  double _parseLineAmount(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0.0;
    return 0.0;
  }

  Future<void> _ensureSafeLedgerBalanceLoaded(SafeBoxModel safe) async {
    final safeId = safe.id;
    if (safeId == null) {
      return;
    }

    if (_safeLedgerCashBalance.containsKey(safeId)) {
      return;
    }
    if (_safeLedgerCashBalanceLoading.contains(safeId)) {
      return;
    }

    setState(() {
      _safeLedgerCashBalanceLoading.add(safeId);
    });
    try {
      final resp = await _apiService.getSafeBoxLedgerBalance(safeId);
      final bal = (resp['cash_balance'] as num?)?.toDouble() ?? 0.0;
      if (!mounted) return;
      setState(() {
        _safeLedgerCashBalance[safeId] = bal;
      });
    } catch (_) {
      // Best-effort UI hint; ignore failures (permissions/network).
    } finally {
      if (mounted) {
        setState(() {
          _safeLedgerCashBalanceLoading.remove(safeId);
        });
      }
    }
  }

  double? _getAvailableSafeCash(SafeBoxModel safe) {
    final liveCash = _getLiveAccountCashBalance(safe.accountId);
    if (liveCash != null) {
      return liveCash;
    }
    final safeId = safe.id;
    if (safeId != null) {
      final ledger = _safeLedgerCashBalance[safeId];
      if (ledger != null) return ledger;
    }
    final fallback = safe.balance?.cash;
    return fallback?.toDouble();
  }

  bool _isCashOutflowFromSafe(AccountLineModel line) {
    return widget.voucherType == 'payment' &&
        line.amountType == 'cash' &&
        line.lineType == 'credit' &&
        line.amount > 0;
  }

  EmployeeModel? _findEmployeeById(int? employeeId) {
    if (employeeId == null) {
      return null;
    }
    try {
      return _employees.firstWhere((emp) => emp.id == employeeId);
    } catch (_) {
      return null;
    }
  }

  /// The employee's salary payable account: its link on the server
  /// (payable_accounts), never a number prefix and a name (CHART-002 5c).
  int? _findEmployeeSalaryPayableAccountId(EmployeeModel employee) =>
      employee.payableAccounts['salary_payable'];

  /// The employee's bonus payable account by its link -- or, before their first
  /// approved bonus, the bonus payables' parent (a mapped role on the server).
  int? _findEmployeeBonusPayableAccountId(EmployeeModel employee) =>
      employee.payableAccounts['bonus_payable'] ??
      _employeeBonusPayableParentId;

  int? _coerceAccountId(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      return int.tryParse(trimmed);
    }
    return null;
  }

  int? _findAccountIdByNumber(String accountNumber) {
    final target = accountNumber.trim();
    if (target.isEmpty) return null;
    try {
      final acc = _accounts.firstWhere(
        (a) => a['account_number']?.toString().trim() == target,
      );
      return _coerceAccountId(acc['id']);
    } catch (_) {
      return null;
    }
  }

  bool _shouldShowSafeBoxesForLineType(String? lineType) {
    if (lineType == null) return false;
    final bool isReceipt = widget.voucherType == 'receipt';
    return (isReceipt && lineType == 'debit') ||
        (!isReceipt && lineType == 'credit');
  }

  bool _safeMatchesAmountType(SafeBoxModel safe, String amountType) {
    if (amountType == 'gold') return safe.safeType == 'gold';
    return safe.safeType == 'cash' ||
        safe.safeType == 'bank' ||
        safe.safeType == 'clearing' ||
        safe.safeType == 'check';
  }

  List<GoldLineEntryModel> _effectiveGoldEntries(AccountLineModel line) {
    if (line.amountType != 'gold') return const <GoldLineEntryModel>[];
    line.ensureGoldEntries(_mainKarat.toDouble());
    return line.goldEntries;
  }

  void _syncGoldSummary(AccountLineModel line) {
    line.syncFromGoldEntries(defaultKarat: _mainKarat.toDouble());
  }

  void _addGoldEntryField(AccountLineModel line) {
    line.ensureGoldEntries(_mainKarat.toDouble());
    final used = line.goldEntries
        .map((e) => e.karat)
        .whereType<double>()
        .toSet();
    final nextKarat = _availableKarats.firstWhere(
      (k) => !used.contains(k),
      orElse: () => _mainKarat.toDouble(),
    );
    line.goldEntries.add(GoldLineEntryModel(amount: 0, karat: nextKarat));
    _syncGoldSummary(line);
  }

  void _removeGoldEntryField(AccountLineModel line, int entryIndex) {
    if (entryIndex < 0 || entryIndex >= line.goldEntries.length) return;
    line.goldEntries.removeAt(entryIndex);
    if (line.goldEntries.isEmpty) {
      line.goldEntries.add(
        GoldLineEntryModel(amount: 0, karat: _mainKarat.toDouble()),
      );
    }
    _syncGoldSummary(line);
  }

  Future<void> _loadSafeUsageCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_safeUsagePrefsKey);
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final Map<int, int> parsed = {};
      decoded.forEach((k, v) {
        final key = int.tryParse(k.toString());
        if (key == null) return;
        int count;
        if (v is int) {
          count = v;
        } else if (v is num) {
          count = v.toInt();
        } else {
          count = int.tryParse(v.toString()) ?? 0;
        }
        if (count > 0) {
          parsed[key] = count;
        }
      });

      _safeUsageCounts
        ..clear()
        ..addAll(parsed);
    } catch (_) {
      // Ignore malformed local stats.
    }
  }

  Future<void> _recordSafeUsage(int? accountId) async {
    final safe = _findSafeByAccountId(accountId);
    if (safe == null) return;

    final id = safe.accountId;
    _safeUsageCounts[id] = (_safeUsageCounts[id] ?? 0) + 1;

    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = <String, int>{
        for (final e in _safeUsageCounts.entries) e.key.toString(): e.value,
      };
      await prefs.setString(_safeUsagePrefsKey, jsonEncode(encoded));
    } catch (_) {
      // Non-blocking UX enhancement only.
    }
  }

  SafeBoxModel? _defaultSafeForAmountType({
    required String? lineType,
    required String amountType,
  }) {
    if (!_shouldShowSafeBoxesForLineType(lineType)) return null;
    final candidates = _safeBoxes
        .where((sb) => _safeMatchesAmountType(sb, amountType))
        .toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final aUsage = _safeUsageCounts[a.accountId] ?? 0;
      final bUsage = _safeUsageCounts[b.accountId] ?? 0;
      if (aUsage != bUsage) {
        return bUsage.compareTo(aUsage);
      }

      final aDefault = a.isDefault == true ? 1 : 0;
      final bDefault = b.isDefault == true ? 1 : 0;
      if (aDefault != bDefault) {
        return bDefault.compareTo(aDefault);
      }

      final aNum = (a.account?.accountNumber ?? '').toString();
      final bNum = (b.account?.accountNumber ?? '').toString();
      return aNum.compareTo(bNum);
    });

    return candidates.first;
  }

  void _ensureFirstLineConfiguration({
    required String amountType,
    double? karat,
    String? description,
  }) {
    if (_accountLines.isEmpty) {
      _addNewLine();
    }

    final firstLine = _accountLines.first;
    firstLine.amountType = amountType;
    if (amountType == 'gold') {
      firstLine.karat = karat ?? _mainKarat.toDouble();
      firstLine.ensureGoldEntries(_mainKarat.toDouble());
      if (firstLine.goldEntries.length == 1) {
        firstLine.goldEntries.first.karat = firstLine.karat;
      }
      _syncGoldSummary(firstLine);
    } else {
      firstLine.goldEntries.clear();
      firstLine.karat = null;
    }
    if (description != null &&
        (firstLine.description == null || firstLine.description!.isEmpty)) {
      firstLine.description = description;
    }

    if (_shouldShowSafeBoxesForLineType(firstLine.lineType)) {
      final currentSafe = _findSafeByAccountId(firstLine.accountId);
      final needsSafe =
          currentSafe == null ||
          !_safeMatchesAmountType(currentSafe, amountType);
      if (needsSafe) {
        final def = _defaultSafeForAmountType(
          lineType: firstLine.lineType,
          amountType: amountType,
        );
        if (def?.accountId != null) {
          _autoFill(firstLine, def!.accountId);
        }
      }
    }
  }

  List<Map<String, dynamic>> _getTemplates() {
    if (widget.voucherType == 'receipt') {
      return [
        {
          'id': 'receipt_customer',
          'title': 'دفعة عميل',
          'description': 'تهيئة السند لتحصيل دفعة نقدية من عميل.',
          'icon': Icons.person_add_alt,
        },
        {
          'id': 'receipt_gold',
          'title': 'استلام ذهب',
          'description': 'استلام ذهب من عميل وتحويله لخزينة ذهب.',
          'icon': Icons.diamond_outlined,
        },
        {
          'id': 'receipt_advance_return',
          'title': 'استرداد سلفة',
          'description': 'استرداد سلفة موظف إلى الخزينة.',
          'icon': Icons.assignment_return_outlined,
        },
        {
          'id': 'receipt_safe_transfer',
          'title': 'تحويل لخزينة',
          'description': 'تحضير السند لتحويل رصيد إلى خزينة محددة.',
          'icon': Icons.account_balance_wallet_outlined,
        },
      ];
    }

    return [
      {
        'id': 'payment_supplier',
        'title': 'دفعة لمورد',
        'description': 'تهيئة السند لصرف دفعة نقدية إلى مورد.',
        'icon': Icons.local_shipping_outlined,
      },
      {
        'id': 'payment_salary',
        'title': 'راتب موظف',
        'description': 'تجهيز السند لصرف راتب موظف محدد.',
        'icon': Icons.badge_outlined,
      },
      {
        'id': 'payment_advance',
        'title': 'سلفة موظف',
        'description': 'صرف سلفة لموظف من الخزينة.',
        'icon': Icons.money_off_outlined,
      },
      {
        'id': 'payment_bonus',
        'title': 'مكافأة موظف',
        'description': 'صرف مكافأة أو مقدم منها لموظف من الخزينة.',
        'icon': Icons.emoji_events_outlined,
      },
      {
        'id': 'payment_expense',
        'title': 'مصروف تشغيلي',
        'description': 'صرف مصروف تشغيلي من الخزينة.',
        'icon': Icons.receipt_long_outlined,
      },
    ];
  }

  void _applyTemplate(String templateId) {
    setState(() {
      _selectedTemplateId = templateId;

      void clearPartySelections() {
        _selectedCustomerId = null;
        _selectedSupplierId = null;
        _selectedEmployeeId = null;
        _selectedOtherAccountId = null;
      }

      switch (templateId) {
        case 'receipt_customer':
          _partyType = 'customer';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استلام دفعة من العميل'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'تحصيل نقدي',
          );
          break;
        case 'receipt_gold':
          _partyType = 'customer';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استلام ذهب وتسليمه إلى الخزينة'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'gold',
            karat: _mainKarat.toDouble(),
            description: 'ذهب مستلم',
          );
          break;
        case 'receipt_advance_return':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استرداد سلفة من موظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'حدد حساب الموظف الذي تُسترد منه السلفة.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'استرداد سلفة',
          );
          // لا حساب يُختار تلقائيًّا: كان يُختار 1400 «ضريبة المدخلات» (CHART-002)
          break;
        case 'receipt_safe_transfer':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'تحويل رصيد إلى خزينة'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'تحويل داخلي',
          );
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر الحساب الداخلي المناسب للتحويل.'
              : _notesController.text;
          break;
        case 'payment_supplier':
          _partyType = 'supplier';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف دفعة للمورد'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'دفعة للمورد',
          );
          break;
        case 'payment_salary':
          _partyType = 'employee';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف راتب موظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر الموظف وسيتم الربط تلقائياً بحساب ذمم رواتبه.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'راتب',
          );
          break;
        case 'payment_advance':
          _partyType = 'employee';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف سلفة لموظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر الموظف وسيتم الربط تلقائياً بحسابه ضمن الأصول.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'سلفة موظف',
          );
          break;
        case 'payment_bonus':
          _partyType = 'employee';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف مكافأة لموظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر الموظف وسيتم الربط تلقائياً بحساب مكافآته المستحقة.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'مكافأة موظف',
          );
          break;
        case 'payment_expense':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف مصروف تشغيلي'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'مصروف تشغيلي',
          );
          // The expense is the employee's to name: the first in the tree
          // was chosen for them («خسارة الوزن» on production).
          break;
      }
    });

    if (!mounted) return;

    // بعد تطبيق النموذج نُطلق التوليد الذكي ليُضمّن اسم الطرف إن كان محدداً
    _smartFillDescriptionAndReceiver(force: true);

    AppFeedback.success(context, 'تم تطبيق القالب بنجاح');
  }

  // ════════════════════════════════════════════════════════════════════════════
  // توليد ذكي لحقلَي البيان والمستلم
  // ────────────────────────────────────────────────────────────────────────────
  // القاعدة: لا نُلغي تعديلاً يدوياً أجراه المستخدم.
  //   • [force=true]  → يُعيد الكتابة حتى لو عدَّل المستخدم (مثال: تغيير النموذج)
  //   • [force=false] → يكتب فقط إن كان الحقل فارغاً أو يحتوي النص التلقائي السابق
  // ════════════════════════════════════════════════════════════════════════════
  void _smartFillDescriptionAndReceiver({bool force = false}) {
    // ── تحديد اسم الطرف الحالي ──────────────────────────────────────────────
    String? partyName;
    if (_partyType == 'customer' && _selectedCustomerId != null) {
      final c = _findById(_customers, _selectedCustomerId);
      partyName = c?['name']?.toString() ?? c?['customer_name']?.toString();
    } else if (_partyType == 'supplier' && _selectedSupplierId != null) {
      final s = _findById(_suppliers, _selectedSupplierId);
      partyName = s?['name']?.toString() ?? s?['supplier_name']?.toString();
    } else if (_partyType == 'employee' && _selectedEmployeeId != null) {
      final e = _findEmployeeById(_selectedEmployeeId);
      partyName = e?.name;
    }

    // ── بناء نص البيان حسب النموذج والطرف ───────────────────────────────────
    final isReceipt = widget.voucherType == 'receipt';
    String? newDesc;
    String? newReceiver;

    switch (_selectedTemplateId) {
      // ── قبض ──────────────────────────────────────────────────────────────
      case 'receipt_customer':
        newDesc = partyName != null
            ? 'استلام دفعة من العميل $partyName'
            : 'استلام دفعة من العميل';
        newReceiver = null; // المستلم هو الصندوق لا الطرف
        break;
      case 'receipt_gold':
        newDesc = partyName != null
            ? 'استلام ذهب من العميل $partyName'
            : 'استلام ذهب وتسليمه إلى الخزينة';
        newReceiver = null;
        break;
      case 'receipt_advance_return':
        newDesc = partyName != null
            ? 'استرداد سلفة من الموظف $partyName'
            : 'استرداد سلفة من موظف';
        newReceiver = partyName;
        break;
      case 'receipt_safe_transfer':
        newDesc = 'تحويل رصيد إلى الخزينة';
        newReceiver = null;
        break;
      // ── صرف ──────────────────────────────────────────────────────────────
      case 'payment_supplier':
        newDesc = partyName != null
            ? 'سداد دفعة للمورد $partyName'
            : 'سداد دفعة للمورد';
        newReceiver = partyName;
        break;
      case 'payment_salary':
        newDesc = partyName != null
            ? 'صرف راتب الموظف $partyName'
            : 'صرف راتب موظف';
        newReceiver = partyName;
        break;
      case 'payment_advance':
        newDesc = partyName != null
            ? 'صرف سلفة للموظف $partyName'
            : 'صرف سلفة لموظف';
        newReceiver = partyName;
        break;
      case 'payment_bonus':
        newDesc = partyName != null
            ? 'مقدم مكافأة للموظف $partyName'
            : 'صرف مكافأة لموظف';
        newReceiver = partyName;
        break;
      case 'payment_expense':
        newDesc = 'صرف مصروف تشغيلي';
        newReceiver = null;
        break;
      default:
        // لا نموذج محدد — نعتمد على نوع الطرف فقط
        if (partyName != null) {
          if (_partyType == 'customer') {
            newDesc = isReceipt
                ? 'استلام دفعة من العميل $partyName'
                : 'دفعة للعميل $partyName';
          } else if (_partyType == 'supplier') {
            newDesc = isReceipt
                ? 'استلام دفعة من المورد $partyName'
                : 'سداد دفعة للمورد $partyName';
            newReceiver = partyName;
          } else if (_partyType == 'employee') {
            newDesc = isReceipt
                ? 'استلام من الموظف $partyName'
                : 'صرف للموظف $partyName';
            newReceiver = partyName;
          }
        }
    }

    // The chosen invoices name the payment (VOUCHER-ATTR-1).
    if (!isReceipt && _partyType == 'supplier') {
      newDesc = _invoiceDescription ?? newDesc;
    }

    // ── تطبيق البيان ─────────────────────────────────────────────────────────
    if (newDesc != null) {
      final current = _descriptionController.text.trim();
      final canWrite = force || current.isEmpty || current == _lastAutoDesc;
      if (canWrite) {
        _descriptionController.text = newDesc;
        _lastAutoDesc = newDesc;
      }
    }

    // ── تطبيق المستلم ────────────────────────────────────────────────────────
    {
      final current = _receiverNameController.text.trim();
      final canWrite = force || current.isEmpty || current == _lastAutoReceiver;
      if (canWrite) {
        final val = newReceiver ?? '';
        _receiverNameController.text = val;
        _lastAutoReceiver = val;
      }
    }
  }

  Future<void> _selectVoucherDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      // The theme's own scheme: a light one forced here was light in the
      // dark theme too.
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Widget _buildPartySelectorCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _tone.gold.container.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.group_outlined, color: _cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.voucherType == 'receipt' ? 'من' : 'إلى',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('voucher-date'),
                  onPressed: () => _selectVoucherDate(context),
                  icon: const Icon(Icons.event),
                  label: Text(
                    ltrIsolate(DateFormat('yyyy-MM-dd').format(_selectedDate)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _partyType,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'customer', child: Text('عميل')),
                DropdownMenuItem(value: 'supplier', child: Text('مورد')),
                DropdownMenuItem(value: 'employee', child: Text('موظف')),
                DropdownMenuItem(value: 'other', child: Text('آخر')),
              ],
              onChanged: (value) {
                setState(() {
                  _partyType = value!;
                  _selectedCustomerId = null;
                  _selectedSupplierId = null;
                  _selectedEmployeeId = null;
                  _selectedOtherAccountId = null;
                  // إعادة توليد البيان والمستلم عند تغيير نوع الطرف
                  _smartFillDescriptionAndReceiver(force: true);
                });
              },
            ),
            const SizedBox(height: 16),
            if (_partyType == 'customer')
              SearchablePickerField(
                labelText: 'العميل *',
                valueText: _selectedPartyName('customer'),
                hintText: _customers.isEmpty
                    ? 'لا يوجد عملاء'
                    : 'اضغط للبحث والاختيار',
                helperText:
                    _onAggregate(_findById(_customers, _selectedCustomerId))
                    ? 'ليس للعميل حساب خاص — يُقيَّد على الحساب التجميعي للعملاء'
                    : null,
                prefixIcon: Icons.person_outline,
                enabled: _customers.isNotEmpty,
                onTap: _pickCustomer,
              ),
            if (_partyType == 'supplier')
              SearchablePickerField(
                labelText: 'المورد *',
                valueText: _selectedPartyName('supplier'),
                hintText: _suppliers.isEmpty
                    ? 'لا يوجد موردين'
                    : 'اضغط للبحث والاختيار',
                helperText:
                    _onAggregate(_findById(_suppliers, _selectedSupplierId))
                    ? 'ليس للمورد حساب خاص — يُقيَّد على الحساب التجميعي للموردين'
                    : null,
                prefixIcon: Icons.store_mall_directory,
                enabled: _suppliers.isNotEmpty,
                onTap: _pickSupplier,
              ),
            if (_partyType == 'employee')
              DropdownButtonFormField<int?>(
                initialValue: _employees.any((e) => e.id == _selectedEmployeeId)
                    ? _selectedEmployeeId
                    : null,
                decoration: const InputDecoration(
                  labelText: 'الموظف *',
                  border: OutlineInputBorder(),
                  helperText: 'اختر الموظف المرتبط بالسند',
                ),
                items: _employees.map<DropdownMenuItem<int?>>((employee) {
                  return DropdownMenuItem<int?>(
                    value: employee.id,
                    child: Text(
                      employee.name.isNotEmpty
                          ? employee.name
                          : 'موظف ${employee.id ?? ''}',
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedEmployeeId = value;
                    _smartFillDescriptionAndReceiver();
                  });
                },
              ),
            if (_partyType == 'other')
              AccountPickerFormField(
                context: context,
                accounts: _accounts,
                value: _selectedOtherAccountId,
                labelText: 'الحساب *',
                hintText: _selectedTemplateId == 'payment_expense'
                    ? 'اختر حساب المصروف'
                    : _selectedTemplateId == 'payment_salary'
                    ? 'اختر حساب ذمم الموظفين - رواتب'
                    : _selectedTemplateId == 'payment_advance'
                    ? 'اختر حساب الموظف'
                    : 'اختر الحساب المناسب (مصروف، سلفة، إلخ)',
                title: 'اختيار حساب',
                isArabic: true,
                helperText: _selectedTemplateId == 'payment_expense'
                    ? 'تُعرض المصروفات التشغيلية وحدها'
                    : _selectedTemplateId == 'payment_salary'
                    ? 'سيتم تسجيل الراتب على ذمم الموظفين (رواتب)'
                    : _selectedTemplateId == 'payment_advance'
                    ? 'سيتم تسجيل السلفة على حساب الموظف ضمن الأصول'
                    : _selectedTemplateId == 'receipt_safe_transfer'
                    ? 'اختر الحساب الداخلي المصدر للتحويل إلى الخزينة.'
                    : 'اختر الحساب المناسب (مصروف، سلفة، إلخ)',
                predicate: (a) {
                  final safeType = (a['safe_box_type'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();

                  // Template-driven filters -- the groups' ids from /app-config:
                  // - Salary: the employees' salary payables
                  // - Advances: the employees' personal accounts
                  final accId = _coerceAccountId(a['id']);
                  if (_selectedTemplateId == 'payment_salary') {
                    return _employeeSalaryPayableIds.contains(accId);
                  }
                  if (_selectedTemplateId == 'payment_advance') {
                    return _employeePersonalIds.contains(accId);
                  }
                  if (_selectedTemplateId == 'payment_expense' &&
                      _expenseIds.isNotEmpty) {
                    return _expenseIds.contains(accId) &&
                        isLeafAccount(a, _parentAccountIds);
                  }
                  if (_selectedTemplateId == 'receipt_safe_transfer') {
                    return safeType == 'cash' ||
                        safeType == 'bank' ||
                        safeType == 'clearing' ||
                        safeType == 'check' ||
                        safeType == 'gold';
                  }

                  // Default (no template): any postable detail account, not
                  // just expense/revenue/VAT. A سند صرف is not limited to
                  // those accounting-wise -- e.g. paying out a partner's
                  // capital (310/320 تحت حقوق الملكية) or a weight/memo
                  // account (7xxxx) are equally valid, and excluding them
                  // entirely (vs. just not being the common case) made them
                  // unreachable from this picker. Category/parent accounts
                  // are still excluded since you can't post to them directly.
                  return isLeafAccount(a, _parentAccountIds);
                },
                showTransactionTypeFilter: true,
                showTracksWeightFilter: false,
                onChanged: (value) {
                  setState(() {
                    _selectedOtherAccountId = value;
                    // Auto-switch all lines to match the party safe type
                    _syncLinesAmountTypeToParty(value);
                  });
                },
              ),
            _buildPartyBalance(),
          ],
        ),
      ),
    );
  }

  /// Asked for a payment to a supplier: which of its invoices it is for.
  bool get _showInvoicePicker =>
      widget.voucherType == 'payment' &&
      _partyType == 'supplier' &&
      _selectedSupplierId != null;

  bool get _hasGoldLines => _accountLines.any((l) => l.amountType == 'gold');

  /// The payment's gold by its own karats, as the plan takes it.
  List<Map<String, dynamic>> get _goldForPlan {
    final byKarat = <double, double>{};
    for (final line in _accountLines.where((l) => l.amountType == 'gold')) {
      for (final e in _effectiveGoldEntries(line)) {
        if (e.amount <= 0 || e.karat == null) continue;
        byKarat[e.karat!] = (byKarat[e.karat!] ?? 0) + e.amount;
      }
    }
    return [
      for (final e in byKarat.entries) {'karat': e.key, 'weight': e.value},
    ];
  }

  /// The chosen invoices, oldest first: the order the plan fills them in.
  List<Map<String, dynamic>> get _chosenInvoicesInOrder {
    final rows =
        _invoiceCandidates
            .where(
              (r) =>
                  _chosenInvoiceIds.contains((r['invoice_id'] as num).toInt()),
            )
            .toList()
          ..sort(
            (a, b) => '${a['date'] ?? ''}'.compareTo('${b['date'] ?? ''}'),
          );
    return rows;
  }

  /// «سداد دفعة لفاتورة رقم …» -- the chosen invoices by their numbers.
  String? get _invoiceDescription {
    final numbers = [
      for (final r in _chosenInvoicesInOrder)
        '${r['invoice_number'] ?? '#${r['invoice_id']}'}',
    ];
    if (numbers.isEmpty) return null;
    return numbers.length == 1
        ? 'سداد دفعة لفاتورة رقم ${numbers.single}'
        : 'سداد دفعة لفواتير رقم ${numbers.join('، ')}';
  }

  /// The supplier's open invoices: what each owes in cash and in gold, in one
  /// list. A failed lookup does not block the payment -- it stays on account.
  Future<void> _loadInvoiceCandidates() async {
    final supplierId = _selectedSupplierId;
    if (supplierId == null) return;
    setState(() {
      _loadingInvoiceCandidates = true;
      _candidatesSupplierId = supplierId;
    });
    List<Map<String, dynamic>> cash = const [], gold = const [];
    try {
      final r = await Future.wait([
        _apiService.getSupplierOpenCashObligations(supplierId),
        _apiService.getSupplierOpenGoldObligations(supplierId),
      ]);
      cash = r[0];
      gold = r[1];
    } catch (_) {}
    if (!mounted || _selectedSupplierId != supplierId) return;
    final byId = <int, Map<String, dynamic>>{};
    for (final row in [...cash, ...gold]) {
      final id = (row['invoice_id'] as num?)?.toInt();
      if (id == null) continue;
      final merged = byId.putIfAbsent(id, () => {'invoice_id': id});
      for (final key in [
        'invoice_number',
        'date',
        'open_cash',
        'open_main_karat',
      ]) {
        if (row[key] != null) merged[key] = row[key];
      }
    }
    setState(() {
      _invoiceCandidates = byId.values.toList();
      _loadingInvoiceCandidates = false;
    });
  }

  void _toggleInvoice(int id) {
    setState(() {
      if (!_chosenInvoiceIds.remove(id)) _chosenInvoiceIds.add(id);
      if (_chosenInvoiceIds.isNotEmpty) _goldAdvance = false;
      _smartFillDescriptionAndReceiver();
    });
    _refreshPlan();
  }

  /// The server's plan for the payment as it stands; asked again only when
  /// the choice or the amounts change.
  Future<void> _refreshPlan() async {
    final supplierId = _selectedSupplierId;
    if (!_showInvoicePicker ||
        supplierId == null ||
        _chosenInvoiceIds.isEmpty) {
      if (_paymentPlan != null || _planKey != null) {
        setState(() {
          _paymentPlan = null;
          _planKey = null;
        });
      }
      return;
    }
    final ids = _chosenInvoiceIds.toList()..sort();
    final gold = _goldForPlan;
    final key = '$supplierId|$ids|${_totalCash.toStringAsFixed(2)}|$gold';
    if (key == _planKey) return;
    _planKey = key;
    try {
      final plan = await _apiService.getSupplierPaymentPlan(
        supplierId: supplierId,
        invoiceIds: ids,
        cash: _totalCash,
        gold: gold,
      );
      if (mounted && _planKey == key) setState(() => _paymentPlan = plan);
    } catch (_) {
      if (mounted && _planKey == key) setState(() => _paymentPlan = null);
    }
  }

  /// The payment's cash line filled with what the chosen invoices owe in
  /// cash. Offered only to a payment with a cash line: it used to turn a gold
  /// line into cash, its grams lost and its gold safe kept.
  void _fillFromInvoices() {
    final owed = _chosenInvoicesInOrder.fold<double>(
      0.0,
      (s, r) => s + ((r['open_cash'] as num?)?.toDouble() ?? 0.0),
    );
    final line = _accountLines.where((l) => l.amountType == 'cash').firstOrNull;
    if (line == null) return;
    setState(() {
      line.amount = double.parse(owed.toStringAsFixed(2));
      _amountFillEpoch++;
    });
    _refreshPlan();
  }

  Widget _buildInvoicePicker() {
    if (_candidatesSupplierId != _selectedSupplierId &&
        !_loadingInvoiceCandidates) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showInvoicePicker) _loadInvoiceCandidates();
      });
    }
    return SupplierInvoicePicker(
      invoices: _invoiceCandidates,
      chosen: _chosenInvoiceIds,
      plan: _paymentPlan,
      loading: _loadingInvoiceCandidates,
      formatCash: _formatCash,
      onToggle: _toggleInvoice,
      onFill: _accountLines.any((l) => l.amountType == 'cash')
          ? _fillFromInvoices
          : null,
      showAdvance: _hasGoldLines,
      advance: _goldAdvance,
      onAdvance: (v) => setState(() => _goldAdvance = v),
      maxHeight: _partyCardHeight,
    );
  }

  /// The distribution, said in the review: each chosen invoice's share, and
  /// what stays on the supplier's account.
  List<String> get _planLines {
    final plan = _paymentPlan;
    if (_chosenInvoiceIds.isEmpty) {
      return _showInvoicePicker
          ? ['الدفعة على حساب المورد (بلا فاتورة)']
          : const [];
    }
    if (plan == null) return const ['يُحسب توزيعها على الفواتير…'];
    String share(int id) {
      final cash = (plan['cash'] as List? ?? const [])
          .where((s) => ((s as Map)['invoice_id'] as num).toInt() == id)
          .fold<double>(
            0,
            (t, s) => t + ((s as Map)['amount'] as num).toDouble(),
          );
      final gold = (plan['gold'] as List? ?? const [])
          .map((s) => s as Map)
          .where((s) => (s['invoice_id'] as num).toInt() == id);
      return [
        if (cash > 0) _formatCash(cash),
        for (final g in gold)
          '${formatGrams((g['weight'] as num).toDouble())} جم عيار ${formatAmount(g['karat'] as num, decimals: 0)}',
      ].join(' • ');
    }

    final cashLeft = (plan['cash_on_account'] as num?)?.toDouble() ?? 0;
    final goldLeft =
        (plan['gold_on_account_main_karat'] as num?)?.toDouble() ?? 0;
    return [
      for (final r in _chosenInvoicesInOrder)
        '${r['invoice_number'] ?? '#${r['invoice_id']}'}: ${share((r['invoice_id'] as num).toInt()).isEmpty ? 'لا شيء' : share((r['invoice_id'] as num).toInt())}',
      if (cashLeft > 0 || goldLeft > 0)
        'يبقى على حساب المورد: ${[if (cashLeft > 0) _formatCash(cashLeft), if (goldLeft > 0) '${formatGrams(goldLeft)} جم بالعيار الرئيسي'].join(' و')}',
    ];
  }

  Widget _buildGoldEntryCommissionRow(GoldLineEntryModel entry) {
    final theme = Theme.of(context);
    final hasCommission = entry.commissionDirection.isNotEmpty;
    final isEarn = entry.commissionDirection == 'earn';
    final total = entry.commissionTotal;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          _CommissionToggleButton(
            label: 'بدون',
            selected: !hasCommission,
            onTap: () => setState(() {
              entry.commissionDirection = '';
              entry.commissionPerGram = 0;
            }),
          ),
          const SizedBox(width: 4),
          _CommissionToggleButton(
            label: 'عمولة',
            selected: entry.commissionDirection == 'earn',
            color: theme.colorScheme.tertiary,
            onTap: () => setState(() => entry.commissionDirection = 'earn'),
          ),
          const SizedBox(width: 4),
          _CommissionToggleButton(
            label: 'رسوم',
            selected: entry.commissionDirection == 'pay',
            color: theme.colorScheme.error,
            onTap: () => setState(() => entry.commissionDirection = 'pay'),
          ),
          if (hasCommission) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: TextFormField(
                initialValue: entry.commissionPerGram > 0
                    ? entry.commissionPerGram.toStringAsFixed(2)
                    : '',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'ر.س/جم',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixText: 'ر.س',
                  labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: isEarn
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.error,
                  ),
                ),
                onChanged: (v) => setState(
                  () => entry.commissionPerGram = readTypedNumber(v) ?? 0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '= ${formatAmount(total)} ر.س',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isEarn
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAccountLinesHeader() {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.voucherType == 'receipt'
                ? 'ما يُقبض، وأين'
                : 'ما يُصرف، ومن أين',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: _tone.gold.fg,
            ),
          ),
        ),
        Text(
          _linesCount(_accountLines.length),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: _cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// The statement, kept in sight; the receiver, the notes and the files
  /// folded under it -- written for the voucher, not needed to save it.
  Widget _buildDetailsCard() {
    final theme = Theme.of(context);
    final hasAttachments = _attachedFileNames.isNotEmpty;
    final hasNotes = _notesController.text.trim().isNotEmpty;
    final receiver = _receiverNameController.text.trim();
    final folded = [
      if (receiver.isNotEmpty) 'المستلم: $receiver',
      if (hasNotes) 'فيه ملاحظات',
      if (hasAttachments) 'مرفقات: ${_attachedFileNames.length}',
    ];
    return Card(
      key: const Key('voucher-details'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('voucher-description'),
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'البيان',
                hintText: 'سبب القبض أو الصرف',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: AppSpace.sm),
                initiallyExpanded: hasNotes || hasAttachments,
                title: Text(
                  'المستلم والملاحظات والمرفقات',
                  style: theme.textTheme.titleSmall,
                ),
                subtitle: Text(
                  folded.isEmpty ? 'اختياري' : folded.join(' • '),
                  style: theme.textTheme.bodySmall,
                ),
                children: [
                  TextFormField(
                    controller: _receiverNameController,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستلم',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  TextFormField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'ملاحظات داخلية (لا تُطبع)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpace.md),
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.attach_file),
                        label: const Text('إرفاق مستند'),
                        onPressed: _pickFiles,
                      ),
                      for (final f in _attachedFileNames)
                        Chip(
                          label: Text(f),
                          onDeleted: () =>
                              setState(() => _attachedFileNames.remove(f)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What is between us and the chosen customer or supplier, as the ledger
  /// says it: «لنا عنده» or «علينا له», cash and each karat.
  Widget _buildPartyBalance() {
    final party = switch (_partyType) {
      'customer' => _findById(_customers, _selectedCustomerId),
      'supplier' => _findById(_suppliers, _selectedSupplierId),
      _ => null,
    };
    final said = party == null
        ? null
        : partyBalanceSaid(party, currencySymbol: _currencySymbol);
    if (said == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      key: const Key('voucher-party-balance'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: _tone.gold.container.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الرصيد بيننا', style: theme.textTheme.labelMedium),
          const SizedBox(height: AppSpace.xs),
          if (said.isEmpty)
            Text('لا رصيد بيننا', style: theme.textTheme.bodyMedium)
          else
            for (final line in said)
              Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
        ],
      ),
    );
  }

  /// The voucher in one sentence: «تصرف 500.00 ر.س من الصندوق إلى مورد
  /// الذهب». None until something is typed.
  String? get _summarySentence {
    final amounts = [
      if (_totalCash > 0) _formatCash(_totalCash),
      for (final e in _totalGoldByKarat.entries)
        if (e.value > 0)
          '${ltrIsolate(formatGrams(e.value))} جم عيار ${e.key.toInt()}',
    ];
    if (amounts.isEmpty) return null;
    final places = <String>{
      for (final line in _accountLines)
        if (line.accountId != null) _lineAccountLabel(line),
    };
    final partyChosen = switch (_partyType) {
      'customer' => _selectedCustomerId != null,
      'supplier' => _selectedSupplierId != null,
      'employee' => _selectedEmployeeId != null,
      _ => _selectedOtherAccountId != null,
    };
    final isReceipt = widget.voucherType == 'receipt';
    return [
      '${isReceipt ? 'تقبض' : 'تصرف'} ${amounts.join(' و')}',
      if (places.isNotEmpty) '${isReceipt ? 'في' : 'من'} ${places.join('، ')}',
      if (partyChosen) '${isReceipt ? 'من' : 'إلى'} $_partyLabel',
    ].join(' ');
  }

  Widget _buildSaveSection(Color accentColor) {
    // The save button and what stands in its way are in the footer; here only
    // the balance's own correction stays.
    if (_balanceDiff > 0.01 && _balanceDiff <= 0.1) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: () {
            setState(() {
              if (_accountLines.isNotEmpty) {
                _accountLines.last.amount += _balanceDiff;
              }
            });
          },
          child: Text(
            'تصحيح تلقائي للفرق (${_formatWeight(_balanceDiff)})',
            style: TextStyle(color: _cs.primary, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildFooter(Color accentColor) {
    final theme = Theme.of(context);
    final blocker = _blocker;
    final ready = blocker == null;
    final tones = AppSemanticColors.of(context);
    final tone = ready ? tones.ready : tones.blocked;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          // A phone stacks the sentence over a save as wide as the screen:
          // beside it, the sentence was squeezed a word to a line.
          child: LayoutBuilder(
            builder: (context, box) {
              final said = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ready ? Icons.check_circle : Icons.error_outline,
                    color: tone.fg,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_summarySentence case final sentence?)
                          Text(
                            sentence,
                            key: const Key('voucher-summary'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        Text(
                          _inReview
                              ? 'مراجعة السند…'
                              : _isSaving
                              ? 'جارٍ الحفظ…'
                              : ready
                              ? 'جاهز للحفظ'
                              : 'غير جاهز للحفظ — $blocker',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: tone.fg,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              if (box.maxWidth < 600) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    said,
                    const SizedBox(height: AppSpace.sm),
                    _buildSaveButton(accentColor, enabled: ready),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: said),
                  const SizedBox(width: 16),
                  _buildSaveButton(accentColor, enabled: ready),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton(Color accentColor, {required bool enabled}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, minHeight: 56),
      child: FilledButton.icon(
        onPressed: _isSaving || !enabled ? null : _saveIfReady,
        // The one strong action on the screen, flat (ADR-049).
        style: AppButtonStyles.primary(context, _voucherTone).copyWith(
          textStyle: WidgetStatePropertyAll(
            Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        icon: _isSaving && !_inReview
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: _cs.surfaceContainerLowest,
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.save_outlined, size: 24),
        label: Text(_isSaving && !_inReview ? 'جاري الحفظ...' : 'حفظ السند'),
      ),
    );
  }

  Widget _buildTemplateSelector() {
    final templates = _getTemplates();
    if (templates.isEmpty) {
      return const SizedBox.shrink();
    }

    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = _tone
        .voucher(isReceipt ? VoucherKind.receipt : VoucherKind.payment)
        .fg;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _tone.gold.container.withValues(alpha: 0.2),
            _tone.gold.container.withValues(alpha: 0.05),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: _tone.gold.container.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      // One wrap, the label first: every template in sight at any width.
      child: Wrap(
        spacing: 0,
        runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpace.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.flash_on, color: _cs.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'سريع:',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _tone.gold.fg,
                  ),
                ),
              ],
            ),
          ),
          ...templates.map((template) {
            final bool isSelected = template['id'] == _selectedTemplateId;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _applyTemplate(template['id'] as String),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? accentColor
                          : _cs.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? accentColor
                            : _tone.gold.container.withValues(alpha: 0.5),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          template['icon'] as IconData,
                          color: isSelected
                              ? _cs.surfaceContainerLowest
                              : _cs.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          template['title'] as String,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? _cs.surfaceContainerLowest
                                    : _tone.gold.fg,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildSafeBalanceInfo(AccountLineModel line) {
    final safe = _findSafeByAccountId(line.accountId);
    if (safe == null) {
      return const SizedBox.shrink();
    }

    // For cash/bank/clearing safes, use the unified available-balance source
    // (live account balance first, then safe-ledger fallback) to avoid UI mismatch.
    final safeType = safe.safeType;
    final isCashLikeSafe =
        safeType == 'cash' || safeType == 'bank' || safeType == 'clearing';
    if (line.amountType == 'cash' && isCashLikeSafe) {
      final safeId = safe.id;
      if (safeId != null &&
          !_safeLedgerCashBalance.containsKey(safeId) &&
          !_safeLedgerCashBalanceLoading.contains(safeId)) {
        // Lazy-load once; _ensureSafeLedgerBalanceLoaded is guarded.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureSafeLedgerBalanceLoaded(safe);
        });
      }
    } else if (safe.balance == null) {
      // For gold balances we need safe.balance.weight details.
      return const SizedBox.shrink();
    }

    final bool isPayment = widget.voucherType == 'payment';
    String message;
    Color bgColor;
    Color borderColor;
    Color textColor;
    bool exceedsBalance;

    if (line.amountType == 'gold') {
      final weightInfo = safe.balance?.weight;
      if (weightInfo == null) {
        final hasAnyLiveWeight = _availableKarats.any(
          (karat) =>
              (_getLiveAccountWeightBalance(line.accountId, karat.toInt()) ??
                  0.0) >
              0.0001,
        );
        if (!hasAnyLiveWeight) {
          return const SizedBox.shrink();
        }
      }

      final requestedByKarat = <int, double>{};
      for (final entry in _effectiveGoldEntries(line)) {
        final karat = (entry.karat ?? _mainKarat.toDouble()).toInt();
        requestedByKarat[karat] = (requestedByKarat[karat] ?? 0) + entry.amount;
      }

      double availableForKarat(int karat) {
        final liveWeight = _getLiveAccountWeightBalance(line.accountId, karat);
        if (liveWeight != null) {
          return liveWeight;
        }
        if (weightInfo == null) {
          return 0.0;
        }
        switch (karat) {
          case 24:
            return weightInfo.karat24;
          case 22:
            return weightInfo.karat22;
          case 21:
            return weightInfo.karat21;
          case 18:
            return weightInfo.karat18;
          default:
            return weightInfo.total;
        }
      }

      final exceededEntry = requestedByKarat.entries.where((e) {
        final available = availableForKarat(e.key);
        return isPayment && e.value > available + 0.0001;
      }).toList();

      exceedsBalance = exceededEntry.isNotEmpty;
      bgColor = exceedsBalance
          ? _tone.blocked.container
          : _tone.ready.container;
      borderColor = exceedsBalance
          ? _tone.blocked.fg.withValues(alpha: 0.4)
          : _tone.ready.fg.withValues(alpha: 0.4);
      textColor = exceedsBalance ? _tone.blocked.fg : _tone.ready.fg;

      if (exceedsBalance) {
        final first = exceededEntry.first;
        final available = availableForKarat(first.key);
        message =
            'تحذير: الوزن المدخل (${_formatWeight(first.value, includeUnit: true)}) '
            'يتجاوز المخزون المتاح ${_formatWeight(available, includeUnit: true)} '
            'لعيار ${first.key} في "${safe.name}".';
      } else {
        // Show the actual available balance per karat for this safe box,
        // similar to how cash safes show their available balance.
        final availableDetails = _availableKarats
            .map((k) => k.toInt())
            .where((k) => availableForKarat(k) > 0.0001)
            .map(
              (k) =>
                  '${_formatWeight(availableForKarat(k), includeUnit: true)} عيار $k',
            )
            .join(' • ');
        message = availableDetails.isEmpty
            ? 'لا يوجد مخزون متاح في "${safe.name}".'
            : 'الرصيد الفعلي في "${safe.name}": $availableDetails';
      }
    } else {
      final available = _getAvailableSafeCash(safe);
      final bool isOutflow = _isCashOutflowFromSafe(line);
      exceedsBalance =
          isOutflow && available != null && line.amount > available + 0.01;
      bgColor = exceedsBalance
          ? _tone.blocked.container
          : _tone.ready.container;
      borderColor = exceedsBalance
          ? _tone.blocked.fg.withValues(alpha: 0.4)
          : _tone.ready.fg.withValues(alpha: 0.4);
      textColor = exceedsBalance ? _tone.blocked.fg : _tone.ready.fg;

      if (available == null) {
        message =
            'الرصيد الفعلي غير متاح حالياً للحساب المرتبط بـ "${safe.name}".';
      } else {
        message = exceedsBalance
            ? 'تحذير: المبلغ المدخل (${_formatCash(line.amount)}) يتجاوز الرصيد الفعلي ${_formatCash(available)} في "${safe.name}".'
            : 'الرصيد الفعلي في "${safe.name}": ${_formatCash(available)}';
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            exceedsBalance
                ? Icons.warning_amber_rounded
                : Icons.savings_outlined,
            color: textColor,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: textColor,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addNewLine() {
    // تحديد نوع السطر بناءً على نوع السند:
    // - سند القبض: السطور مدينة (debit) - الخزائن التي نستقبل فيها
    // - سند الصرف: السطور دائنة (credit) - الخزائن التي نصرف منها
    final lineType = widget.voucherType == 'receipt' ? 'debit' : 'credit';
    final defaultSafe = _defaultSafeForAmountType(
      lineType: lineType,
      amountType: 'cash',
    );

    setState(() {
      _accountLines.add(
        AccountLineModel(lineType: lineType, amountType: 'cash'),
      );
      _autoFill(_accountLines.last, defaultSafe?.accountId);
    });
  }

  void _removeLine(int index) {
    if (_accountLines.length > 1) {
      setState(() {
        _accountLines.removeAt(index);
      });
    } else {
      AppFeedback.error(context, 'يجب أن يحتوي السند على سطر واحد على الأقل');
    }
  }

  Future<void> _saveVoucher() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate party - مطلوب دائماً لأن سطر الطرف يتم إضافته تلقائياً
    if (_partyType == 'customer' && _selectedCustomerId == null) {
      AppFeedback.error(context, 'يجب اختيار عميل');
      return;
    }
    if (_partyType == 'supplier' && _selectedSupplierId == null) {
      AppFeedback.error(context, 'يجب اختيار مورد');
      return;
    }
    if (_partyType == 'employee' && _selectedEmployeeId == null) {
      AppFeedback.error(context, 'يجب اختيار موظف');
      return;
    }
    if (_partyType == 'other' && _selectedOtherAccountId == null) {
      AppFeedback.error(context, 'يجب اختيار حساب');
      return;
    }
    setState(() => _isSaving = true);

    try {
      // Get party account ID - مطلوب دائماً لأن سطر الطرف يتم إضافته تلقائياً
      int? partyAccountId;
      Map<String, dynamic>? selectedCustomer;
      Map<String, dynamic>? selectedSupplier;
      EmployeeModel? selectedEmployee;

      if (_partyType == 'customer') {
        selectedCustomer = _findById(_customers, _selectedCustomerId);
        if (selectedCustomer == null) {
          throw Exception('تعذر العثور على بيانات العميل المحدد');
        }

        final primaryAccountId = _coerceAccountId(
          selectedCustomer['account_id'],
        );
        final categoryAccountId = _coerceAccountId(
          selectedCustomer['account_category_id'],
        );
        partyAccountId = primaryAccountId ?? categoryAccountId;

        // Fallback to configured aggregate account (from /app-config).
        partyAccountId ??= _customersAggregateAccountId;
        if (partyAccountId == null &&
            _customersAggregateAccountNumber != null) {
          partyAccountId = _findAccountIdByNumber(
            _customersAggregateAccountNumber!,
          );
        }
        if (partyAccountId == null) {
          throw Exception(
            'العميل المختار لا يملك حساباً مرتبطاً، ولا حساب تجميعي للعملاء مربوط في «الربط المحاسبي» (سندات / customers)',
          );
        }
      } else if (_partyType == 'supplier') {
        selectedSupplier = _findById(_suppliers, _selectedSupplierId);
        if (selectedSupplier == null) {
          throw Exception('تعذر العثور على بيانات المورد المحدد');
        }

        final primaryAccountId = _coerceAccountId(
          selectedSupplier['account_id'],
        );
        final categoryAccountId = _coerceAccountId(
          selectedSupplier['account_category_id'],
        );
        partyAccountId = primaryAccountId ?? categoryAccountId;

        // Fallback to configured aggregate account (from /app-config).
        partyAccountId ??= _suppliersAggregateAccountId;
        if (partyAccountId == null &&
            _suppliersAggregateAccountNumber != null) {
          partyAccountId = _findAccountIdByNumber(
            _suppliersAggregateAccountNumber!,
          );
        }
        if (partyAccountId == null) {
          throw Exception(
            'المورد المختار لا يملك حساباً مرتبطاً، ولا حساب تجميعي للموردين مربوط في «الربط المحاسبي» (سندات / suppliers)',
          );
        }
      } else if (_partyType == 'employee') {
        // اختيار الموظف بالاسم، ثم الربط بالخلفية حسب القالب:
        // - راتب: ذمم رواتب الموظف (رابطه)
        // - سلفة: حساب الموظف ضمن الأصول
        selectedEmployee = _findEmployeeById(_selectedEmployeeId);
        if (selectedEmployee == null) {
          throw Exception('تعذر العثور على بيانات الموظف المحدد');
        }

        if (_selectedTemplateId == 'payment_salary') {
          partyAccountId = _findEmployeeSalaryPayableAccountId(
            selectedEmployee,
          );
          if (partyAccountId == null) {
            throw Exception(
              'لا يوجد حساب ذمم رواتب مرتبط بهذا الموظف.\n'
              'يرجى إنشاء/تأكيد حسابات الذمم للموظف من شاشة الموظفين (Ensure setup).',
            );
          }
        } else if (_selectedTemplateId == 'payment_bonus') {
          partyAccountId = _findEmployeeBonusPayableAccountId(selectedEmployee);
          if (partyAccountId == null) {
            throw Exception(
              'لا يوجد حساب مكافآت مستحقة مربوط (لا للموظف ولا أبٌ في «الربط المحاسبي»).\n'
              'يرجى إنشاء حساب المكافآت المستحقة أولاً.',
            );
          }
        } else {
          // Default: employee personal account
          if (selectedEmployee.accountId != null) {
            partyAccountId = selectedEmployee.accountId;
          } else {
            throw Exception('الموظف المختار ليس لديه حساب مرتبط');
          }
        }
      } else if (_partyType == 'other') {
        // استخدام الحساب المحدد يدوياً
        partyAccountId = _selectedOtherAccountId;
      }

      if (partyAccountId == null) {
        throw Exception('لم يتم تحديد حساب للطرف');
      }

      // Build account lines
      final List<Map<String, dynamic>> allAccountLines = [];
      final bool isReceipt = widget.voucherType == 'receipt';

      // Add user-entered lines (الخزائن)
      // سند قبض: الخزائن مدينة (نستقبل فيها)
      // سند صرف: الخزائن دائنة (نصرف منها)
      for (var line in _accountLines) {
        if (line.accountId == null) {
          AppFeedback.error(context, 'يجب اختيار حساب لجميع السطور');
          setState(() => _isSaving = false);
          return;
        }

        if (line.amountType == 'cash') {
          if (line.amount <= 0) {
            AppFeedback.error(
              context,
              'يجب إدخال مبلغ أكبر من صفر لجميع السطور',
            );
            setState(() => _isSaving = false);
            return;
          }

          allAccountLines.add({
            'account_id': line.accountId,
            'line_type': line.lineType,
            'amount_type': line.amountType,
            'amount': line.amount,
            'description': line.description ?? 'نقد',
          });
          continue;
        }

        final entries = _effectiveGoldEntries(
          line,
        ).where((entry) => entry.amount > 0).toList();

        if (entries.isEmpty) {
          AppFeedback.error(context, 'يجب إدخال وزن أكبر من صفر في سطور الذهب');
          setState(() => _isSaving = false);
          return;
        }

        final hasMissingKarat = entries.any((entry) => entry.karat == null);
        if (hasMissingKarat) {
          AppFeedback.error(context, 'يجب اختيار العيار لكل حقل ذهب');
          setState(() => _isSaving = false);
          return;
        }

        for (final entry in entries) {
          final netWeight = entry.netWeight ?? entry.amount;
          final stonesWeight = entry.stonesWeight ?? 0.0;
          final grossWeight = entry.grossWeight ?? (netWeight + stonesWeight);

          if (netWeight <= 0) {
            AppFeedback.error(context, 'الوزن الصافي يجب أن يكون أكبر من صفر');
            setState(() => _isSaving = false);
            return;
          }

          if (entry.netWeight != null &&
              (netWeight - entry.amount).abs() > 0.001) {
            AppFeedback.error(
              context,
              'وزن السطر المحاسبي يجب أن يساوي الوزن الصافي',
            );
            setState(() => _isSaving = false);
            return;
          }

          if (stonesWeight < 0 || grossWeight + 0.001 < netWeight) {
            AppFeedback.error(
              context,
              'الوزن القائم يجب أن يكون أكبر من أو يساوي الصافي، ووزن الأحجار غير سالب',
            );
            setState(() => _isSaving = false);
            return;
          }

          allAccountLines.add({
            'account_id': line.accountId,
            'line_type': line.lineType,
            'amount_type': 'gold',
            'amount': entry.amount,
            'karat': entry.karat,
            'gross_weight': grossWeight,
            'net_weight': netWeight,
            'stones_weight': stonesWeight,
            'description': line.description ?? 'ذهب',
          });
        }
      }

      // Calculate totals for party account lines
      double totalCash = 0;
      Map<double, double> totalGoldByKarat = {};
      Map<double, double> totalGrossGoldByKarat = {};
      Map<double, double> totalNetGoldByKarat = {};
      Map<double, double> totalStonesGoldByKarat = {};

      for (var line in _accountLines) {
        if (line.amountType == 'cash') {
          totalCash += line.amount;
        } else if (line.amountType == 'gold') {
          for (final entry in _effectiveGoldEntries(line)) {
            if (entry.amount <= 0 || entry.karat == null) continue;
            final netWeight = entry.netWeight ?? entry.amount;
            final stonesWeight = entry.stonesWeight ?? 0.0;
            final grossWeight = entry.grossWeight ?? (netWeight + stonesWeight);
            totalGoldByKarat[entry.karat!] =
                (totalGoldByKarat[entry.karat!] ?? 0) + entry.amount;
            totalGrossGoldByKarat[entry.karat!] =
                (totalGrossGoldByKarat[entry.karat!] ?? 0) + grossWeight;
            totalNetGoldByKarat[entry.karat!] =
                (totalNetGoldByKarat[entry.karat!] ?? 0) + netWeight;
            totalStonesGoldByKarat[entry.karat!] =
                (totalStonesGoldByKarat[entry.karat!] ?? 0) + stonesWeight;
          }
        }
      }

      // Add party account line (الطرف - عميل أو مورد)
      // سند قبض: الطرف دائن (يدفع لنا)
      // سند صرف: الطرف مدين (نصرف له)
      final partyLineType = isReceipt ? 'credit' : 'debit';

      if (totalCash > 0) {
        allAccountLines.add({
          'account_id': partyAccountId,
          'line_type': partyLineType,
          'amount_type': 'cash',
          'amount': totalCash,
          'description': 'نقد',
        });
      }

      for (var entry in totalGoldByKarat.entries) {
        allAccountLines.add({
          'account_id': partyAccountId,
          'line_type': partyLineType,
          'amount_type': 'gold',
          'amount': entry.value,
          'karat': entry.key,
          'gross_weight': totalGrossGoldByKarat[entry.key] ?? entry.value,
          'net_weight': totalNetGoldByKarat[entry.key] ?? entry.value,
          'stones_weight': totalStonesGoldByKarat[entry.key] ?? 0.0,
          'description': 'ذهب عيار ${entry.key.toInt()}',
        });
      }

      // Prepare voucher data
      final Map<String, dynamic> voucherData = {
        'voucher_type': widget.voucherType,
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'party_type': _partyType,
        'description': _descriptionController.text,
        'notes': _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        'receiver_name': _receiverNameController.text.isNotEmpty
            ? _receiverNameController.text
            : null,
        'account_lines': allAccountLines,
        // The invoices chosen (VOUCHER-ATTR-1): the server spreads the payment
        // over them oldest first and records each share at approval; the rest
        // stays on account. None chosen: the payment is on account -- for gold,
        // a general settlement or an advance.
        if (_showInvoicePicker && _chosenInvoiceIds.isNotEmpty)
          'invoice_ids': _chosenInvoiceIds.toList()
        else if (_showInvoicePicker && _hasGoldLines)
          'reference_type': _goldAdvance ? 'gold_advance' : 'gold_supplier',
      };

      // عمولة / رسوم فرق العيار — احتساب per-line
      {
        double earnTotal = 0.0;
        double payTotal = 0.0;
        for (final line in _accountLines) {
          if (line.amountType != 'gold') continue;
          for (final entry in line.goldEntries) {
            if (entry.commissionDirection.isEmpty || entry.amount <= 0) {
              continue;
            }
            final amt = _round2(entry.amount * entry.commissionPerGram);
            if (entry.commissionDirection == 'earn') earnTotal += amt;
            if (entry.commissionDirection == 'pay') payTotal += amt;
          }
        }
        if (earnTotal > 0) {
          voucherData['karat_diff_earn_total'] = _round2(earnTotal);
        }
        if (payTotal > 0) {
          voucherData['karat_diff_pay_total'] = _round2(payTotal);
        }
      }

      // Add party
      if (_partyType == 'customer') {
        voucherData['customer_id'] = _selectedCustomerId;
      } else if (_partyType == 'supplier') {
        voucherData['supplier_id'] = _selectedSupplierId;
      } else if (_partyType == 'employee') {
        voucherData['employee_id'] = _selectedEmployeeId;
      } else if (_partyType == 'other' && _selectedOtherAccountId != null) {
        // Resolve and send the account name as party_name so it appears
        // in the voucher list, detail view, and printed copies.
        final otherAccount = _findAccountById(_selectedOtherAccountId);
        final accountName = (otherAccount?['name'] ?? '').toString().trim();
        if (accountName.isNotEmpty) {
          voucherData['party_name'] = accountName;
        }
      }

      // Reviewed before it is saved (VOUCHER-UX-1): what is about to be
      // saved, and any saved voucher that looks like it.
      setState(() => _inReview = true);
      final confirmed = await _review(voucherData);
      if (!mounted) return;
      setState(() => _inReview = false);
      if (!confirmed) {
        setState(() => _isSaving = false);
        return;
      }

      // Create or update voucher
      Map<String, dynamic> response;
      if (widget.existingVoucher != null &&
          widget.existingVoucher!['id'] != null) {
        // Update existing
        final int vid = widget.existingVoucher!['id'] is int
            ? widget.existingVoucher!['id'] as int
            : int.tryParse('${widget.existingVoucher!['id']}') ?? 0;
        response = await _apiService.updateVoucher(vid, voucherData);
      } else {
        response = await _apiService.createVoucher(voucherData);
      }

      if (widget.existingVoucher == null) {
        await _clearLocalDraft();
      }

      if (!mounted) return;
      // The page that says it was saved takes the screen's place; the screen
      // that opened this one is told it was saved, as before.
      final summaries = _lineSummaries;
      final party = _partyLabel;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VoucherSavedScreen(
            voucherType: widget.voucherType,
            voucherId: _toInt(response['id']),
            voucherNumber: response['voucher_number']?.toString(),
            status: response['status']?.toString(),
            partyName: party,
            lines: summaries,
            edited: widget.existingVoucher != null,
            newVoucher: (_) => AddVoucherScreen(
              voucherType: widget.voucherType,
              apiService: widget.apiService,
            ),
          ),
        ),
        result: true,
      );
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        AppFeedback.error(context, e, title: 'خطأ في الحفظ');
      }
    }
  }

  /// A line made cash or gold: its safe follows when the one it has holds
  /// the other kind.
  void _setLineKind(AccountLineModel line, String value) {
    setState(() {
      final oldAmountType = line.amountType;
      line.amountType = value;

      if (value == 'gold') {
        line.ensureGoldEntries(_mainKarat.toDouble());
        _syncGoldSummary(line);
      } else {
        line.goldEntries.clear();
        line.karat = null;
      }

      // If the selected account is a safe-backed account and it no
      // longer matches the selected amount type, switch to a
      // suitable default safe (or clear).
      final existingSafe = _findSafeByAccountId(line.accountId);
      if (existingSafe != null) {
        final matches = _safeMatchesAmountType(existingSafe, value);
        if (!matches) {
          final def = _defaultSafeForAmountType(
            lineType: line.lineType,
            amountType: value,
          );
          _autoFill(line, def?.accountId);
        }
      } else if (oldAmountType != value &&
          _shouldShowSafeBoxesForLineType(line.lineType)) {
        // If this line is expected to point to a safe account,
        // auto-select a default when switching types.
        final def = _defaultSafeForAmountType(
          lineType: line.lineType,
          amountType: value,
        );
        if (def != null) _autoFill(line, def.accountId);
      }

      // If a gold safe is selected with fixed karat, sync line karat.
      if (value == 'gold') {
        final safe = _findSafeByAccountId(line.accountId);
        final fixed = safe?.karat;
        if (safe != null &&
            safe.safeType == 'gold' &&
            fixed != null &&
            fixed > 0) {
          line.ensureGoldEntries(_mainKarat.toDouble());
          if (line.goldEntries.length == 1) {
            line.goldEntries.first.karat = fixed.toDouble();
          }
          _syncGoldSummary(line);
        }
      }
    });
  }

  Widget _buildAccountLineCard(int index) {
    final line = _accountLines[index];

    final filteredAccounts = _getFilteredAccounts(
      lineType: line.lineType,
      amountType: line.amountType,
    ).whereType<Map>().map((a) => Map<String, dynamic>.from(a)).toList();

    final selectedId = line.accountId;
    if (selectedId != null &&
        !filteredAccounts.any((a) => _coerceAccountId(a['id']) == selectedId)) {
      try {
        final existing = _accounts.firstWhere(
          (a) => _coerceAccountId(a['id']) == selectedId,
        );
        filteredAccounts.add(Map<String, dynamic>.from(existing));
      } catch (_) {
        // Keep current selection even if account is unavailable.
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _tone.gold.container.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The line's number and its removal, when there is more than one.
            if (_accountLines.length > 1) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _tone.gold.container.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'السطر ${index + 1}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: _tone.gold.fg,
                      ),
                    ),
                  ),
                  if (_accountLines.length > 1)
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: _tone.blocked.fg),
                      onPressed: () => _removeLine(index),
                    ),
                ],
              ),
              const Divider(height: 24),
            ],
            // Cash or gold first: it decides which safes are offered.
            SegmentedButton<String>(
              key: Key('voucher-line-kind-$index'),
              segments: [
                ButtonSegment(
                  value: 'cash',
                  label: const Text('نقد'),
                  icon: const Icon(Icons.payments_outlined),
                  enabled: _lockedAmountTypeForCurrentParty != 'gold',
                ),
                ButtonSegment(
                  value: 'gold',
                  label: const Text('ذهب'),
                  icon: const Icon(Icons.diamond_outlined),
                  enabled: _lockedAmountTypeForCurrentParty != 'cash',
                ),
              ],
              selected: {line.amountType},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _setLineKind(line, v.first),
            ),
            const SizedBox(height: 12),
            AccountPickerFormField(
              context: context,
              key: ValueKey(
                'voucher_line_picker_${index}_${line.lineType}_${line.amountType}_${line.accountId ?? 'none'}',
              ),
              accounts: filteredAccounts,
              value: line.accountId,
              labelText: 'الحساب *',
              hintText: filteredAccounts.isEmpty
                  ? 'لا توجد حسابات متاحة'
                  : 'اختر حساب/خزينة',
              title: 'اختيار حساب',
              isArabic: true,
              enabled: filteredAccounts.isNotEmpty,
              helperText: line.accountAutoFilled && line.accountId != null
                  ? 'اختيرت الخزنة الأكثر استخداماً — اضغط لتغييرها.'
                  : null,
              showTransactionTypeFilter: false,
              showTracksWeightFilter: false,
              subtitleOf: (a) =>
                  _accountHolds(_coerceAccountId(a['id']), line.amountType),
              validator: (value) {
                if (value == null) {
                  return 'يجب اختيار حساب';
                }
                return null;
              },
              onChanged: (value) {
                setState(() {
                  line.accountId = value;
                  line.accountAutoFilled = false;
                });
                _recordSafeUsage(value);

                // If selected account is a SafeBox-backed account, load ledger
                // balance as a fallback source when live account balance is unavailable.
                final safe = _findSafeByAccountId(value);
                if (safe != null &&
                    (safe.safeType == 'cash' ||
                        safe.safeType == 'bank' ||
                        safe.safeType == 'clearing')) {
                  _ensureSafeLedgerBalanceLoaded(safe);
                }
              },
            ),
            const SizedBox(height: 12),

            if (line.amountType == 'cash')
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      key: ValueKey('cash-amount-$index-$_amountFillEpoch'),
                      initialValue: line.amount > 0
                          ? line.amount.toString()
                          : '',
                      decoration: InputDecoration(
                        labelText: 'المبلغ (ريال) *',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: _cs.secondary.withValues(alpha: 0.3),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: _cs.primary, width: 2),
                        ),
                        prefixIcon: Icon(
                          Icons.attach_money,
                          color: _cs.primary,
                        ),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                      onChanged: (value) {
                        setState(() {
                          line.amount = readTypedNumber(value) ?? 0;
                        });
                      },
                    ),
                  ),
                ],
              )
            else
              Builder(
                builder: (context) {
                  final entries = _effectiveGoldEntries(line);
                  return Column(
                    children: [
                      ...entries.asMap().entries.map((entryMap) {
                        final entryIndex = entryMap.key;
                        final entry = entryMap.value;
                        final karatLabel =
                            (entry.karat ?? _mainKarat.toDouble()).toInt();
                        return Padding(
                          padding: EdgeInsets.only(
                            bottom: entryIndex == entries.length - 1 ? 0 : 10,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _tone.gold.container.withValues(
                                alpha: 0.14,
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _cs.secondary.withValues(alpha: 0.28),
                              ),
                            ),
                            child: Column(
                              children: [
                                if (entries.length > 1) ...[
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.diamond_outlined,
                                        size: 16,
                                        color: _tone.gold.fg,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'الوزن ${entryIndex + 1} — عيار $karatLabel',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: _tone.gold.fg,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: TextFormField(
                                        key: ValueKey(
                                          'gold_amount_${index}_$entryIndex',
                                        ),
                                        initialValue: entry.amount > 0
                                            ? entry.amount.toString()
                                            : '',
                                        decoration: InputDecoration(
                                          labelText: 'الوزن (جرام) *',
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: _cs.secondary.withValues(
                                                alpha: 0.3,
                                              ),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: _cs.primary,
                                              width: 2,
                                            ),
                                          ),
                                          prefixIcon: Icon(
                                            Icons.scale,
                                            color: _cs.primary,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          NormalizeNumberFormatter(),
                                        ],
                                        onChanged: (value) {
                                          setState(() {
                                            entry.amount =
                                                readTypedNumber(value) ?? 0;
                                            _syncGoldSummary(line);
                                          });
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<double>(
                                        key: ValueKey(
                                          'gold_karat_${index}_$entryIndex',
                                        ),
                                        initialValue: entry.karat,
                                        decoration: InputDecoration(
                                          labelText: 'العيار *',
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: _cs.secondary.withValues(
                                                alpha: 0.3,
                                              ),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: _cs.primary,
                                              width: 2,
                                            ),
                                          ),
                                          prefixIcon: Icon(
                                            Icons.diamond,
                                            color: _cs.primary,
                                          ),
                                        ),
                                        items: _availableKarats
                                            .map<DropdownMenuItem<double>>((
                                              karat,
                                            ) {
                                              return DropdownMenuItem<double>(
                                                value: karat,
                                                child: Text(karat.toString()),
                                              );
                                            })
                                            .toList(),
                                        onChanged: (value) {
                                          setState(() {
                                            entry.karat = value;
                                            _syncGoldSummary(line);
                                          });
                                        },
                                      ),
                                    ),
                                    if (entries.length > 1) ...[
                                      const SizedBox(width: 8),
                                      IconButton(
                                        onPressed: () {
                                          setState(() {
                                            _removeGoldEntryField(
                                              line,
                                              entryIndex,
                                            );
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                        ),
                                        color: _tone.blocked.fg,
                                        tooltip: 'حذف هذا الحقل',
                                      ),
                                    ],
                                  ],
                                ),
                                // صف العمولة / الرسوم لكل سطر ذهب
                                if (widget.voucherType == 'payment' &&
                                    _partyType == 'supplier' &&
                                    entry.amount > 0)
                                  _buildGoldEntryCommissionRow(entry),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _addGoldEntryField(line);
                            });
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة وزن/عيار'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            // What the safe does not cover, under the amount: above the kind
            // its balance pushed the choice down under the hand.
            Builder(
              builder: (context) {
                final safe = _findSafeByAccountId(line.accountId);
                if (safe == null) return const SizedBox.shrink();
                if (safe.id == null) return const SizedBox.shrink();
                if (!(safe.safeType == 'cash' ||
                    safe.safeType == 'bank' ||
                    safe.safeType == 'clearing')) {
                  return const SizedBox.shrink();
                }

                final bal = _getAvailableSafeCash(safe);
                final amount = _parseLineAmount(line.amount);

                final isOutflowFromSafe =
                    widget.voucherType == 'payment' &&
                    line.lineType == 'credit' &&
                    line.amountType == 'cash';
                final insufficient =
                    isOutflowFromSafe && bal != null && amount > bal + 0.01;

                // The balance is said once, in the safe's banner below; here
                // only what it does not cover.
                if (!insufficient) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'الرصيد لا يغطي مبلغ الصرف',
                    style: TextStyle(
                      color: _tone.blocked.fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),

            // A line's own statement, when the voucher has more than one line;
            // one line is said by the voucher's statement.
            if (_accountLines.length > 1)
              TextFormField(
                initialValue: line.description,
                decoration: const InputDecoration(
                  labelText: 'البيان (اختياري)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  setState(() {
                    line.description = value;
                  });
                },
              ),
            _buildSafeBalanceInfo(line),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWideLayout = size.width >= 900;
    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = _tone
        .voucher(isReceipt ? VoucherKind.receipt : VoucherKind.payment)
        .fg;
    final String title = isReceipt ? 'سند قبض' : 'سند صرف';

    // Who, and for which invoices; then what is paid, from where; then what
    // is written about it (the voucher screen review, release 2).
    final List<Widget> leftColumn = [
      _buildTemplateSelector(),
      const SizedBox(height: 12),
      KeyedSubtree(
        key: _partyCardKey,
        child: KeyedSubtree(
          key: const Key('voucher-party-card'),
          child: _buildPartySelectorCard(),
        ),
      ),
      if (_showInvoicePicker) ...[
        const SizedBox(height: 12),
        _buildInvoicePicker(),
      ],
    ];

    final accountLineCards = _accountLines
        .asMap()
        .entries
        .map((entry) => _buildAccountLineCard(entry.key))
        .toList();

    final List<Widget> rightColumn = [
      _buildAccountLinesHeader(),
      const SizedBox(height: 12),
      ...accountLineCards,
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('إضافة سطر'),
          onPressed: _addNewLine,
          style: AppButtonStyles.tonal(_voucherTone),
        ),
      ),
      const SizedBox(height: 12),
      _buildDetailsCard(),
      _buildSaveSection(accentColor),
    ];

    final Widget layoutContent = isWideLayout
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: leftColumn,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rightColumn,
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...leftColumn,
              const SizedBox(height: 24),
              ...rightColumn,
            ],
          );

    if (_showInvoicePicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final h = _partyCardKey.currentContext?.size?.height;
        if (mounted &&
            h != null &&
            (_partyCardHeight == null || (_partyCardHeight! - h).abs() > 1)) {
          setState(() => _partyCardHeight = h);
        }
      });
    }

    // The plan follows the amounts as they are typed; asked only on a change.
    if (_chosenInvoiceIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshPlan();
      });
    }

    // Ctrl+S saves a ready voucher; leaving with something typed asks first
    // (VOUCHER-UX-1).
    return PopScope(
      canPop: !_hasEntries || _isSaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: AppDocumentShortcuts(
        onSave: _saveIfReady,
        onAddLine: _addNewLine,
        child: Builder(
          builder: (context) => Scaffold(
            bottomNavigationBar: _isLoading ? null : _buildFooter(accentColor),
            appBar: AppBar(
              title: Text(title),
              backgroundColor: _cs.primary,
              foregroundColor: _cs.onPrimary,
              elevation: 2,
              actions: [
                if (widget.existingVoucher == null)
                  TextButton.icon(
                    onPressed: _isSaving
                        ? null
                        : () async {
                            await _saveLocalDraft();
                            if (mounted) {
                              Navigator.of(context).pop(false);
                            }
                          },
                    icon: Icon(
                      Icons.schedule,
                      color: _cs.onPrimary.withValues(alpha: 0.8),
                    ),
                    label: Text(
                      'إكمال لاحقاً',
                      style: TextStyle(
                        color: _cs.onPrimary.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
              ],
            ),
            body: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: Form(key: _formKey, child: layoutContent),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// «1,500.00 ر.س»: the number whole, then the currency, a space apart
  /// (it was «1,500.00ر.س»).
  String _formatCash(double amount, {bool includeSymbol = true}) {
    final number = formatAmount(amount, decimals: _currencyDecimalPlaces);
    return includeSymbol ? '${ltrIsolate(number)} $_currencySymbol' : number;
  }

  /// An amount sent rounded to two places, as it always was.
  double _round2(double x) => double.parse(x.toStringAsFixed(2));

  /// A count of lines as Arabic says it: سطر واحد، سطران، ٣ أسطر، ١١ سطرًا.
  String _linesCount(int n) => switch (n) {
    1 => 'سطر واحد',
    2 => 'سطران',
    >= 3 && <= 10 => '$n أسطر',
    _ => '$n سطرًا',
  };

  String _formatWeight(
    double amount, {
    int? decimals,
    bool includeUnit = true,
  }) {
    final effectiveDecimals = decimals ?? (amount.abs() < 1 ? 3 : 2);
    final formatted = formatGrams(amount, decimals: effectiveDecimals);
    return includeUnit ? '$formatted جم' : formatted;
  }
}
