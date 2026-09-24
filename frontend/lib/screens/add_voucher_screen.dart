import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../models/employee_model.dart';
import '../models/safe_box_model.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'voucher_preview_screen.dart';
import '../utils.dart';
import '../widgets/account_picker_sheet.dart';
import '../widgets/party_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';

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
          color: selected ? effectiveColor.withOpacity(0.15) : Colors.transparent,
          border: Border.all(
            color: selected ? effectiveColor : theme.colorScheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? effectiveColor : theme.colorScheme.onSurfaceVariant,
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

  const AddVoucherScreen({
    super.key,
    required this.voucherType,
    this.existingVoucher,
    this.initialSupplierId,
    this.initialPartyType,
    this.initialOtherAccountId,
    this.initialDescription,
  });

  @override
  State<AddVoucherScreen> createState() => _AddVoucherScreenState();
}

class _AddVoucherScreenState extends State<AddVoucherScreen> {
  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();
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
  List<SafeBoxModel> _safeBoxes = [];

  int? _customersAggregateAccountId;
  String? _customersAggregateAccountNumber;
  int? _suppliersAggregateAccountId;
  String? _suppliersAggregateAccountNumber;

  final Map<int, double> _safeLedgerCashBalance = {};
  final Set<int> _safeLedgerCashBalanceLoading = {};
  final Map<int, int> _safeUsageCounts = {};
  static const String _safeUsagePrefsKey = 'yasargold_safe_usage_counts_v1';
  List<EmployeeModel> _employees = [];

  int? _selectedCustomerId;
  int? _selectedSupplierId;

  /// What a gold payment to a supplier is FOR. Recorded at payment time
  /// because it cannot be recovered later: of 113 historical gold vouchers not
  /// one named an invoice, and at payment time 61% of them had two or more
  /// plausible candidates. 'supplier' (a general settlement on account) is a
  /// legitimate answer and stays the default — the employee is never pushed
  /// into inventing a link to an invoice.
  String _goldPaymentPurpose = 'supplier'; // 'invoice' | 'advance' | 'supplier'
  int? _goldPurposeInvoiceId;
  List<Map<String, dynamic>> _goldPurposeCandidates = const [];
  bool _loadingGoldPurposeCandidates = false;
  int? _selectedEmployeeId;
  int? _selectedOtherAccountId;

  bool _isLoading = false;
  bool _isSaving = false;

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

    // Quick-create: preselect supplier when opening a payment voucher
    // from the suppliers list.
    if (widget.existingVoucher == null &&
        widget.voucherType == 'payment' &&
        widget.initialSupplierId != null) {
      _partyType = 'supplier';
      _selectedSupplierId = widget.initialSupplierId;
      _selectedCustomerId = null;
      _selectedEmployeeId = null;
      _selectedOtherAccountId = null;
    }

    if (widget.existingVoucher == null) {
      final initialPartyType = (widget.initialPartyType ?? '').trim();
      if (initialPartyType.isNotEmpty) {
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ السند لإكماله لاحقاً')),
      );
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
      _notesController.text = (v['notes'] ?? '') as String;
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

      int? partyAccountId;
      if (_partyType == 'customer' && _selectedCustomerId != null) {
        final customer = _findById(_customers, _selectedCustomerId);
        partyAccountId = _coerceAccountId(
          customer?['account_id'] ?? customer?['account_category_id'],
        );
        partyAccountId ??= _customersAggregateAccountId;
        if (partyAccountId == null &&
            _customersAggregateAccountNumber != null) {
          partyAccountId = _findAccountIdByNumber(
            _customersAggregateAccountNumber!,
          );
        }
      } else if (_partyType == 'supplier' && _selectedSupplierId != null) {
        final supplier = _findById(_suppliers, _selectedSupplierId);
        partyAccountId = _coerceAccountId(
          supplier?['account_id'] ?? supplier?['account_category_id'],
        );
        partyAccountId ??= _suppliersAggregateAccountId;
        if (partyAccountId == null &&
            _suppliersAggregateAccountNumber != null) {
          partyAccountId = _findAccountIdByNumber(
            _suppliersAggregateAccountNumber!,
          );
        }
      } else if (_partyType == 'employee' && _selectedEmployeeId != null) {
        final emp = _findEmployeeById(_selectedEmployeeId);
        partyAccountId = emp?.accountId;
      } else if (_partyType == 'other' && _selectedOtherAccountId != null) {
        partyAccountId = _selectedOtherAccountId;
      }

      if (_partyType == 'other' && partyAccountId == null) {
        final String partyLineType = widget.voucherType == 'receipt'
            ? 'credit'
            : 'debit';
        final Map<String, dynamic> partyLine = _incomingAccountLinesRaw!
            .firstWhere(
              (line) => line['line_type'] == partyLineType,
              orElse: () => <String, dynamic>{},
            );
        final candidateId = _coerceAccountId(partyLine['account_id']);
        if (candidateId != null) {
          partyAccountId = candidateId;
          _selectedOtherAccountId = candidateId;
        }
      }

      final List<AccountLineModel> applied = [];
      for (final map in _incomingAccountLinesRaw!) {
        final mapAccountId = map['account_id'] is num
            ? (map['account_id'] as num).toInt()
            : null;

        if (partyAccountId != null &&
            mapAccountId != null &&
            mapAccountId == partyAccountId) {
          continue;
        }

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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ميزة إرفاق الملفات غير متاحة حالياً.')),
    );
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
      ),
    );
    if (selected == null) return;
    final id = _toInt(selected['id']);
    if (id == null) return;
    setState(() {
      _selectedSupplierId = id;
      _smartFillDescriptionAndReceiver();
    });
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
        _safeBoxes = safeBoxes;

        _customersAggregateAccountId = customersAggId;
        _customersAggregateAccountNumber = customersAggNumber;
        _suppliersAggregateAccountId = suppliersAggId;
        _suppliersAggregateAccountNumber = suppliersAggNumber;

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في تحميل البيانات: $e')));
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
      // the employee's personal account under 1700 (170xxxx) to reduce the advance
      // balance as part of the same voucher.
      final bool allowEmployeeAdvanceOffset =
          widget.voucherType != 'receipt' &&
          (lineType ?? '') == 'credit' &&
          (amountType ?? '') == 'cash' &&
          _selectedTemplateId == 'payment_salary';

      if (!allowEmployeeAdvanceOffset) {
        return safeOptions;
      }

      final employeeAccounts = _accounts.where((acc) {
        final accNum = (acc['account_number'] ?? '').toString();
        return (accNum.startsWith('170') || accNum.startsWith('171')) &&
            accNum.length >= 5;
      }).toList();

      // Combine: safes first (common UX), then employee accounts.
      return [...safeOptions, ...employeeAccounts];
    }

    // للحالات الأخرى: نعرض الحسابات العادية
    final commonAccounts = [
      '1000',
      '1010',
      '1020',
      '1030',
      '1200',
      '1210',
      '1220',
      '1230',
      '1240',
      '1250',
      '1260',
    ];

    // فلترة الحسابات: إظهار الحسابات التفصيلية فقط (4 خانات أو أكثر)،
    // وتطابق نوع المبلغ (نقدي/ذهب) لهذا السطر تلقائياً -- بنفس حقل
    // transaction_type المستخدَم في فلتر "نقدي/ذهبي/كلاهما" بديلوج
    // "الطرف: آخر"، فيتغيّر محتوى القائمة فوراً عند تبديل نوع السطر بدل
    // اختلاط حسابات نقدية ووزنية معاً بلا علاقة بما هو محدَّد.
    final detailedAccounts = _accounts.where((acc) {
      final accountNumber = acc['account_number'].toString();
      if (accountNumber.length < 4) return false; // حسابات تفصيلية فقط

      final t = (acc['transaction_type'] ?? 'both').toString().toLowerCase();
      if (amountType == 'gold') return t == 'gold' || t == 'both';
      return t == 'cash' || t == 'both';
    }).toList();

    // ترتيب: الحسابات الأكثر استخداماً في المقدمة
    detailedAccounts.sort((a, b) {
      final aNumber = a['account_number'].toString();
      final bNumber = b['account_number'].toString();

      final aIndex = commonAccounts.indexOf(aNumber);
      final bIndex = commonAccounts.indexOf(bNumber);

      // الحسابات الشائعة في المقدمة
      if (aIndex != -1 && bIndex != -1) {
        return aIndex.compareTo(bIndex);
      } else if (aIndex != -1) {
        return -1; // a قبل b
      } else if (bIndex != -1) {
        return 1; // b قبل a
      } else {
        // ترتيب باقي الحسابات حسب الرقم
        return aNumber.compareTo(bNumber);
      }
    });

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
        line.accountId = def?.accountId;
      }
    }
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

  String _normalizeSearchText(String value) {
    // Best-effort normalization for matching Arabic names in account labels.
    return (value).toString().trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
  }

  int? _findEmployeeSalaryPayableAccountId(EmployeeModel employee) {
    // Expected: per-employee salary payable account under 2400xxxx
    // Account name pattern (from backend helpers): "ح/ذمم الموظف <name> - رواتب"
    final empKey = _normalizeSearchText(employee.name);

    final candidates = _accounts.where((acc) {
      final numStr = (acc['account_number'] ?? '').toString().trim();
      if (!numStr.startsWith('2400') || numStr.length < 5) return false;

      final nameStr = (acc['name'] ?? '').toString();
      final key = _normalizeSearchText(nameStr);
      return key.contains(empKey) &&
          key.contains(_normalizeSearchText('رواتب'));
    }).toList();

    if (candidates.isEmpty) {
      // Fallback: match employee name under 2400 even if "رواتب" missing.
      final fallback = _accounts.where((acc) {
        final numStr = (acc['account_number'] ?? '').toString().trim();
        if (!numStr.startsWith('2400') || numStr.length < 5) return false;
        final nameStr = (acc['name'] ?? '').toString();
        return _normalizeSearchText(nameStr).contains(empKey);
      }).toList();
      if (fallback.isEmpty) return null;
      // Prefer the most specific/longest account number.
      fallback.sort((a, b) {
        final an = (a['account_number'] ?? '').toString().length;
        final bn = (b['account_number'] ?? '').toString().length;
        return bn.compareTo(an);
      });
      return _coerceAccountId(fallback.first['id']);
    }

    // Prefer the most specific/longest account number.
    candidates.sort((a, b) {
      final an = (a['account_number'] ?? '').toString().length;
      final bn = (b['account_number'] ?? '').toString().length;
      return bn.compareTo(an);
    });
    return _coerceAccountId(candidates.first['id']);
  }

  int? _findEmployeeBonusPayableAccountId(EmployeeModel employee) {
    // Expected: per-employee bonus payable account under 2310xxxx
    // Account name pattern: "ح/مكافآت مستحقة <name>" or similar
    final empKey = _normalizeSearchText(employee.name);

    final candidates = _accounts.where((acc) {
      final numStr = (acc['account_number'] ?? '').toString().trim();
      if (!numStr.startsWith('2310') || numStr.length < 5) return false;
      final nameStr = (acc['name'] ?? '').toString();
      return _normalizeSearchText(nameStr).contains(empKey);
    }).toList();

    if (candidates.isNotEmpty) {
      candidates.sort((a, b) {
        final an = (a['account_number'] ?? '').toString().length;
        final bn = (b['account_number'] ?? '').toString().length;
        return bn.compareTo(an);
      });
      return _coerceAccountId(candidates.first['id']);
    }

    // Fallback: only the exact parent 2310 account — never a sibling employee's sub-account
    final fallback = _accounts.where((acc) {
      final numStr = (acc['account_number'] ?? '').toString().trim();
      return numStr == '2310';
    }).toList();
    if (fallback.isEmpty) return null;
    return _coerceAccountId(fallback.first['id']);
  }

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
          firstLine.accountId = def!.accountId;
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
              ? 'حدد حساب السلفة (140xxx) المرتبط بالموظف.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'استرداد سلفة',
          );
          // البحث عن حساب السلف التجميعي
          final advanceAccount = _accounts.firstWhere(
            (acc) => acc['account_number']?.toString() == '1400',
            orElse: () => <String, dynamic>{},
          );
          if (advanceAccount.isNotEmpty) {
            _selectedOtherAccountId = advanceAccount['id'] as int?;
          }
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
              ? 'اختر الموظف وسيتم الربط تلقائياً بحساب ذمم الرواتب (2400xxxx).'
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
              ? 'اختر الموظف وسيتم الربط تلقائياً بحسابه ضمن الأصول (170xxxx).'
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
              ? 'اختر الموظف وسيتم الربط تلقائياً بحساب المكافآت المستحقة (2310xxxx).'
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
          final expenseAccount = _accounts.firstWhere(
            (acc) => acc['account_number']?.toString().startsWith('5') ?? false,
            orElse: () => <String, dynamic>{},
          );
          if (expenseAccount.isNotEmpty) {
            _selectedOtherAccountId = expenseAccount['id'] as int?;
          }
          break;
      }
    });

    if (!mounted) return;

    // بعد تطبيق النموذج نُطلق التوليد الذكي ليُضمّن اسم الطرف إن كان محدداً
    _smartFillDescriptionAndReceiver(force: true);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('تم تطبيق القالب بنجاح'),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.primaryGold,
      ),
    );
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

    // ── تطبيق البيان ─────────────────────────────────────────────────────────
    if (newDesc != null) {
      final current = _descriptionController.text.trim();
      final canWrite = force ||
          current.isEmpty ||
          current == _lastAutoDesc;
      if (canWrite) {
        _descriptionController.text = newDesc;
        _lastAutoDesc = newDesc;
      }
    }

    // ── تطبيق المستلم ────────────────────────────────────────────────────────
    {
      final current = _receiverNameController.text.trim();
      final canWrite = force ||
          current.isEmpty ||
          current == _lastAutoReceiver;
      if (canWrite) {
        final val = newReceiver ?? '';
        _receiverNameController.text = val;
        _lastAutoReceiver = val;
      }
    }
  }

  Widget _buildStatusChip({
    required IconData icon,
    required Color color,
    required String label,
    String? subtitle,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: color.withValues(alpha: 0.85),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Reusable cluster of status chips to keep the indicators consistent
  /// wherever they are rendered (hero header, status board, etc.).
  Widget _buildStatusChips({
    required bool partyReady,
    required bool accountsReady,
    required bool hasAmounts,
    required bool hasSafeOverdraft,
    required String totalGoldText,
  }) {
    final theme = Theme.of(context);
    final Color successColor = AppColors.success;
    final Color warningColor = AppColors.warning;
    final Color infoColor = AppColors.info;
    final Color neutralColor = theme.colorScheme.outlineVariant;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildStatusChip(
          icon: partyReady ? Icons.verified_user : Icons.person_search,
          color: partyReady ? successColor : warningColor,
          label: partyReady ? 'الطرف جاهز' : 'الطرف غير محدد',
          subtitle: partyReady
              ? 'يمكنك متابعة تعبئة السند.'
              : 'حدد الطرف المناسب قبل المتابعة.',
        ),
        _buildStatusChip(
          icon: accountsReady ? Icons.check_circle : Icons.list_alt,
          color: accountsReady ? infoColor : warningColor,
          label: accountsReady ? 'سطور الحسابات مكتملة' : 'أكمل بيانات السطور',
          subtitle: accountsReady
              ? 'كل السطور تحتوي على حساب ومبلغ.'
              : 'تأكد من اختيار الحساب وإدخال المبلغ لكل سطر.',
        ),
        _buildStatusChip(
          icon: Icons.account_balance_wallet,
          color: hasAmounts ? infoColor : neutralColor,
          label: hasAmounts
              ? 'إجمالي النقد: ${_formatCash(_totalCash)}'
              : 'لا يوجد مبلغ مُدخل',
          subtitle: totalGoldText.isNotEmpty ? 'الذهب: $totalGoldText' : null,
        ),
        if (hasSafeOverdraft)
          _buildStatusChip(
            icon: Icons.warning_amber_rounded,
            color: AppColors.error,
            label: 'تحذير أرصدة الخزائن',
            subtitle: 'يوجد سطر يتجاوز الرصيد المتاح للخزينة المختارة.',
          )
        else
          _buildStatusChip(
            icon: Icons.shield_outlined,
            color: successColor,
            label: 'الخزائن ضمن الحدود',
            subtitle: 'لا توجد تجاوزات في أرصدة الخزائن الحالية.',
          ),
      ],
    );
  }

  Widget _buildStatusBoard() {
    final bool partyReady =
        (_partyType == 'customer' && _selectedCustomerId != null) ||
        (_partyType == 'supplier' && _selectedSupplierId != null) ||
        (_partyType == 'employee' && _selectedEmployeeId != null) ||
        (_partyType == 'other' && _selectedOtherAccountId != null);

    final bool accountsReady =
        _accountLines.isNotEmpty &&
        _accountLines.every(
          (line) => line.accountId != null && line.amount > 0,
        );

    final bool hasAmounts =
        _totalCash > 0 || _totalGoldByKarat.values.any((value) => value > 0);

    final Map<int, double> outflowBySafeId = {};
    for (final line in _accountLines) {
      if (!_isCashOutflowFromSafe(line)) continue;
      final safe = _findSafeByAccountId(line.accountId);
      final safeId = safe?.id;
      if (safe == null || safeId == null) continue;
      outflowBySafeId[safeId] = (outflowBySafeId[safeId] ?? 0.0) + line.amount;
    }

    final bool hasSafeOverdraft = outflowBySafeId.entries.any((entry) {
      final safeId = entry.key;
      final totalOutflow = entry.value;
      SafeBoxModel? safe;
      try {
        safe = _safeBoxes.firstWhere((s) => s.id == safeId);
      } catch (_) {
        safe = null;
      }
      if (safe == null) return false;
      final available = _getAvailableSafeCash(safe);
      if (available == null) {
        // Best-effort: if we don't know the available balance, don't block/flag.
        return false;
      }
      return totalOutflow > available + 0.01;
    });

    final totalGoldText = _totalGoldByKarat.entries
        .map(
          (entry) =>
              '${_formatWeight(entry.value, includeUnit: false)} جم ع ${entry.key.toInt()}',
        )
        .join(' • ');

    String statusSummary;
    if (!partyReady) {
      statusSummary = 'حدد الطرف لإكمال بيانات السند';
    } else if (!accountsReady) {
      statusSummary = 'أكمل تفاصيل السطور المتبقية';
    } else if (!hasAmounts) {
      statusSummary = 'أدخل المبالغ النقدية أو الذهبية';
    } else if (hasSafeOverdraft) {
      statusSummary = 'تحقق من أرصدة الخزائن قبل الحفظ';
    } else {
      statusSummary = 'السند مكتمل وجاهز للحفظ أو الترحيل';
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: AppColors.lightGold.withValues(alpha: 0.6),
          width: 1.2,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          maintainState: true,
          leading: Icon(
            Icons.dashboard_customize_outlined,
            color: AppColors.primaryGold,
          ),
          title: Text(
            'مؤشرات السند',
            style: TextStyle(
              color: AppColors.deepGold,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              statusSummary,
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            const SizedBox(height: 8),
            _buildStatusChips(
              partyReady: partyReady,
              accountsReady: accountsReady,
              hasAmounts: hasAmounts,
              hasSafeOverdraft: hasSafeOverdraft,
              totalGoldText: totalGoldText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader(
    BuildContext context,
    bool isReceipt,
    Color accentColor,
    IconData icon,
    String title,
  ) {
    final theme = Theme.of(context);
    final dateText = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final totalGoldText = _totalGoldByKarat.entries
        .map(
          (entry) =>
              '${_formatWeight(entry.value, includeUnit: false)} جم ع ${entry.key.toInt()}',
        )
        .join(' • ');
    final bool isBalanced = _balanceDiff <= 0.01;

    Widget buildChip(
      IconData chipIcon,
      String label,
      Color foreground, {
      Color? background,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: background ?? foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: foreground.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chipIcon, color: foreground, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      shadowColor: accentColor.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: accentColor, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isReceipt
                            ? 'سجّل عمليات التحصيل النقدي أو الذهب بسهولة مع تتبع الخزائن والعيارات.'
                            : 'إدارة عمليات الصرف للطرف المستفيد مع مراقبة أرصدة الخزائن والعيارات.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          buildChip(
                            Icons.account_balance_wallet,
                            'نقد: ${_formatCash(_totalCash)}',
                            accentColor,
                          ),
                          if (totalGoldText.isNotEmpty)
                            buildChip(
                              Icons.diamond_outlined,
                              'ذهب: $totalGoldText',
                              AppColors.darkGold,
                              background: AppColors.lightGold.withValues(
                                alpha: 0.25,
                              ),
                            ),
                          buildChip(
                            isBalanced
                                ? Icons.verified_outlined
                                : Icons.warning_amber_rounded,
                            isBalanced
                                ? 'السند متوازن'
                                : 'فرق: ${_formatWeight(_balanceDiff)}',
                            isBalanced ? AppColors.success : AppColors.warning,
                          ),
                          buildChip(
                            Icons.list_alt_outlined,
                            '${_accountLines.length} سطور',
                            AppColors.mediumGold,
                            background: AppColors.lightGold.withValues(
                              alpha: 0.25,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _selectVoucherDate(context),
                      icon: const Icon(Icons.event),
                      label: Text(dateText),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: accentColor,
                        side: BorderSide(
                          color: accentColor.withValues(alpha: 0.6),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        textStyle: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isReceipt ? 'نوع السند: تحصيل' : 'نوع السند: صرف',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.mediumGold,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectVoucherDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryGold,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
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
          color: AppColors.lightGold.withValues(alpha: 0.5),
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
                Icon(Icons.group_outlined, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'الطرف',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                helperText: _customersAggregateAccountNumber != null
                    ? 'سيتم القيد على الحساب التجميعي للعملاء ($_customersAggregateAccountNumber)'
                    : 'سيتم القيد على الحساب التجميعي للعملاء',
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
                helperText: _suppliersAggregateAccountNumber != null
                    ? 'سيتم القيد على الحساب التجميعي للموردين ($_suppliersAggregateAccountNumber)'
                    : 'سيتم القيد على الحساب التجميعي للموردين',
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
                hintText: _selectedTemplateId == 'payment_salary'
                    ? 'اختر حساب ذمم الموظفين - رواتب (2400xxxx)'
                    : _selectedTemplateId == 'payment_advance'
                    ? 'اختر حساب الموظف (170xxxx)'
                    : 'اختر الحساب المناسب (مصروف، سلفة، إلخ)',
                title: 'اختيار حساب',
                isArabic: true,
                helperText: _selectedTemplateId == 'payment_salary'
                    ? 'سيتم تسجيل الراتب على ذمم الموظفين (رواتب)'
                    : _selectedTemplateId == 'payment_advance'
                    ? 'سيتم تسجيل السلفة على حساب الموظف ضمن الأصول'
                    : _selectedTemplateId == 'receipt_safe_transfer'
                    ? 'اختر الحساب الداخلي المصدر للتحويل إلى الخزينة.'
                    : 'اختر الحساب المناسب (مصروف، سلفة، إلخ)',
                predicate: (a) {
                  final accNum = accountNumberOf(a);
                  final safeType = (a['safe_box_type'] ?? '')
                      .toString()
                      .trim()
                      .toLowerCase();

                  // Template-driven filters:
                  // - Salary: employee salary payables accounts under 2400xxxx
                  // - Advances: employee personal/receivable accounts under 170xxxx
                  if (_selectedTemplateId == 'payment_salary') {
                    return accNum.startsWith('2400') && accNum.length >= 5;
                  }
                  if (_selectedTemplateId == 'payment_advance') {
                    return (accNum.startsWith('170') ||
                            accNum.startsWith('171')) &&
                        accNum.length >= 5;
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
                  return accNum.length >= 4;
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
          ],
        ),
      ),
    );
  }

  /// Only asked when the question is real: a gold payment to a supplier.
  /// A cash-only voucher, or one with no supplier, has nothing to attribute.
  bool get _showGoldPurposeSelector =>
      _partyType == 'supplier' &&
      _selectedSupplierId != null &&
      _accountLines.any((l) => l.amountType == 'gold');

  Future<void> _loadGoldPurposeCandidates() async {
    final supplierId = _selectedSupplierId;
    if (supplierId == null) return;
    setState(() => _loadingGoldPurposeCandidates = true);
    try {
      final rows = await _apiService.getSupplierOpenGoldObligations(supplierId);
      if (!mounted) return;
      setState(() {
        _goldPurposeCandidates = rows;
        _loadingGoldPurposeCandidates = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A failed lookup must not block recording the payment: the employee can
      // still declare it a general supplier settlement, which is the truthful
      // answer in most cases anyway.
      setState(() {
        _goldPurposeCandidates = const [];
        _loadingGoldPurposeCandidates = false;
      });
    }
  }

  Widget _buildGoldPurposeCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.call_split, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'هذه الدفعة الذهبية تخص',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'يُسجَّل الاختيار الآن لأنه لا يمكن استرجاعه لاحقًا',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            RadioListTile<String>(
              value: 'invoice',
              groupValue: _goldPaymentPurpose,
              dense: true,
              title: const Text('فاتورة محددة'),
              onChanged: (v) {
                setState(() => _goldPaymentPurpose = v ?? 'supplier');
                if (_goldPurposeCandidates.isEmpty) {
                  _loadGoldPurposeCandidates();
                }
              },
            ),
            if (_goldPaymentPurpose == 'invoice')
              Padding(
                padding: const EdgeInsets.only(right: 32, bottom: 8),
                child: _loadingGoldPurposeCandidates
                    ? const LinearProgressIndicator()
                    : (_goldPurposeCandidates.isEmpty
                        ? const Text(
                            'لا توجد فواتير لهذا المورد عليها التزام ذهب مفتوح',
                            style: TextStyle(fontSize: 12, color: Colors.redAccent),
                          )
                        : DropdownButtonFormField<int>(
                            initialValue: _goldPurposeInvoiceId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'الفاتورة',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: _goldPurposeCandidates.map((row) {
                              final id = (row['invoice_id'] as num).toInt();
                              final open = (row['open_main_karat'] as num?)?.toDouble() ?? 0.0;
                              final date = (row['date'] ?? '').toString();
                              final shortDate =
                                  date.length >= 10 ? date.substring(0, 10) : date;
                              return DropdownMenuItem<int>(
                                value: id,
                                child: Text(
                                  'فاتورة #$id  ·  $shortDate  ·  متبقٍ ${open.toStringAsFixed(2)} جم',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
                            onChanged: (v) =>
                                setState(() => _goldPurposeInvoiceId = v),
                          )),
              ),
            RadioListTile<String>(
              value: 'advance',
              groupValue: _goldPaymentPurpose,
              dense: true,
              title: const Text('سلفة ذهب'),
              subtitle: const Text(
                'تُسجَّل كسلفة، ولا تُنسب لأي فاتورة تلقائيًا',
                style: TextStyle(fontSize: 11),
              ),
              onChanged: (v) => setState(() {
                _goldPaymentPurpose = v ?? 'supplier';
                _goldPurposeInvoiceId = null;
              }),
            ),
            RadioListTile<String>(
              value: 'supplier',
              groupValue: _goldPaymentPurpose,
              dense: true,
              title: const Text('تسوية مورد عامة'),
              subtitle: const Text(
                'على حساب المورد، بلا نسب لفاتورة — وهي حالة صحيحة',
                style: TextStyle(fontSize: 11),
              ),
              onChanged: (v) => setState(() {
                _goldPaymentPurpose = v ?? 'supplier';
                _goldPurposeInvoiceId = null;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.description_outlined, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'البيان',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                hintText: 'أدخل وصف السند أو سبب التحصيل/الصرف',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.mediumGold.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.primaryGold,
                    width: 2,
                  ),
                ),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiverCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_outline, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'اسم المستلم',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _receiverNameController,
              decoration: InputDecoration(
                hintText: 'اسم الشخص المستلم/المسلم للسند',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.mediumGold.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.primaryGold,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentsCard() {
    final hasAttachments = _attachedFileNames.isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.3)),
      ),
      color: AppColors.lightGold.withValues(alpha: 0.12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          maintainState: true,
          initiallyExpanded: hasAttachments,
          leading: Icon(Icons.attach_file, color: AppColors.primaryGold),
          title: Text(
            'المرفقات (اختياري)',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasAttachments
                  ? 'تم إرفاق ${_attachedFileNames.length} ملف/ملفات'
                  : 'أضف صور الفواتير، إيصالات البنك أو أي مستندات داعمة عند الحاجة',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('إرفاق مستند'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGold,
                  foregroundColor: Colors.white,
                ),
                onPressed: _pickFiles,
              ),
            ),
            if (hasAttachments)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _attachedFileNames
                      .map(
                        (f) => Chip(
                          label: Text(f),
                          backgroundColor: Theme.of(context).cardTheme.color,
                          deleteIcon: const Icon(Icons.close, size: 18),
                          onDeleted: () {
                            setState(() {
                              _attachedFileNames.remove(f);
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
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
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'ر.س/جم',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixText: 'ر.س',
                  labelStyle: TextStyle(
                    fontSize: 11,
                    color: isEarn
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.error,
                  ),
                ),
                onChanged: (v) => setState(
                    () => entry.commissionPerGram = double.tryParse(v) ?? 0),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '= ${total.toStringAsFixed(2)} ر.س',
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
    return Row(
      children: [
        Text(
          'سطور الحسابات',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepGold,
          ),
        ),
      ],
    );
  }

  Widget _buildTotalsCard() {
    return Card(
      color: AppColors.lightGold.withValues(alpha: 0.3),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.primaryGold.withValues(alpha: 0.3),
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
                Icon(Icons.attach_money, color: AppColors.darkGold),
                const SizedBox(width: 8),
                Text(
                  'مجموع النقد: ',
                  style: TextStyle(
                    color: AppColors.darkGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatCash(_totalCash),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(Icons.circle, color: AppColors.primaryGold, size: 14),
                const SizedBox(width: 4),
                Text(
                  'مجموع الذهب:',
                  style: TextStyle(
                    color: AppColors.darkGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_totalGoldByKarat.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '0 جم',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                    ),
                  )
                else
                  ..._totalGoldByKarat.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '${_formatWeight(e.value)} ع ${e.key.toInt()}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '✅ سيتم إضافة سطر الطرف تلقائياً لتوازن القيد',
                    style: TextStyle(
                      color: AppColors.success,
                      fontWeight: FontWeight.bold,
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

  Widget _buildNotesCard() {
    final hasNotes = _notesController.text.isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          maintainState: true,
          initiallyExpanded: hasNotes,
          leading: Icon(Icons.note_alt_outlined, color: AppColors.primaryGold),
          title: Text(
            'ملاحظات (اختياري)',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasNotes
                  ? 'تمت إضافة ملاحظات للسند'
                  : 'احفظ تفاصيل داخلية بدون إظهارها في الطباعة',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                hintText: 'أضف تفاصيل إضافية أو ملاحظات داخلية',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveSection(Color accentColor) {
    if (_balanceDiff > 0.01) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey),
              child: const Text('حفظ السند', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'لا يمكن الحفظ: السطور غير متوازنة (الفرق: ${_formatWeight(_balanceDiff)})',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_balanceDiff <= 0.1)
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_accountLines.isNotEmpty) {
                        _accountLines.last.amount += _balanceDiff;
                      }
                    });
                  },
                  child: Text(
                    'تصحيح تلقائي',
                    style: TextStyle(
                      color: AppColors.primaryGold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _saveVoucher,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        icon: _isSaving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.save_outlined, size: 24),
        label: Text(
          _isSaving ? 'جاري الحفظ...' : 'حفظ السند',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildTemplateSelector() {
    final templates = _getTemplates();
    if (templates.isEmpty) {
      return const SizedBox.shrink();
    }

    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = isReceipt ? AppColors.success : AppColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.lightGold.withValues(alpha: 0.2),
            AppColors.lightGold.withValues(alpha: 0.05),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.lightGold.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.flash_on, color: AppColors.primaryGold, size: 20),
          const SizedBox(width: 8),
          Text(
            'سريع:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.darkGold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: templates.map((template) {
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
                            color: isSelected ? accentColor : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? accentColor
                                  : AppColors.lightGold.withValues(alpha: 0.5),
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                template['icon'] as IconData,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.primaryGold,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                template['title'] as String,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : AppColors.darkGold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartyInfoCard() {
    String title;
    String name = '---';
    String? phone;
    String? idNumber;

    Map<String, dynamic>? selected;

    switch (_partyType) {
      case 'customer':
        selected = _findById(_customers, _selectedCustomerId);
        title = 'العميل المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone =
              selected['mobile']?.toString() ?? selected['phone']?.toString();
          idNumber = selected['id_number']?.toString();
        }
        break;
      case 'supplier':
        selected = _findById(_suppliers, _selectedSupplierId);
        title = 'المورد المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone = selected['phone']?.toString();
          idNumber =
              selected['tax_number']?.toString() ??
              selected['id_number']?.toString();
        }
        break;
      case 'employee':
        final employee = _findEmployeeById(_selectedEmployeeId);
        if (employee == null) {
          return const SizedBox.shrink();
        }
        title = 'الموظف المختار';
        name = employee.name;
        phone = employee.phone;
        idNumber = employee.nationalId;
        break;
      case 'other':
        selected = _findById(_accounts, _selectedOtherAccountId);
        title = 'الحساب المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone =
              selected['mobile']?.toString() ?? selected['phone']?.toString();
          idNumber = selected['id_number']?.toString();
        }
        break;
      default:
        return const SizedBox.shrink();
    }

    if (_partyType != 'employee' && selected == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepGold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (phone != null && phone.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text(phone, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
            if (idNumber != null && idNumber.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.credit_card_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text(idNumber, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ],
        ),
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
      bgColor = exceedsBalance ? Colors.red.shade50 : Colors.green.shade50;
      borderColor = exceedsBalance
          ? Colors.red.shade200
          : Colors.green.shade200;
      textColor = exceedsBalance ? Colors.red.shade700 : Colors.green.shade700;

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
      bgColor = exceedsBalance ? Colors.red.shade50 : Colors.green.shade50;
      borderColor = exceedsBalance
          ? Colors.red.shade200
          : Colors.green.shade200;
      textColor = exceedsBalance ? Colors.red.shade700 : Colors.green.shade700;

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
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w600,
                fontSize: 13,
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
        AccountLineModel(
          accountId: defaultSafe?.accountId,
          lineType: lineType,
          amountType: 'cash',
        ),
      );
    });
  }

  void _removeLine(int index) {
    if (_accountLines.length > 1) {
      setState(() {
        _accountLines.removeAt(index);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يجب أن يحتوي السند على سطر واحد على الأقل'),
        ),
      );
    }
  }

  Future<void> _saveVoucher() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate party - مطلوب دائماً لأن سطر الطرف يتم إضافته تلقائياً
    if (_partyType == 'customer' && _selectedCustomerId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار عميل')));
      return;
    }
    if (_partyType == 'supplier' && _selectedSupplierId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار مورد')));
      return;
    }
    if (_partyType == 'employee' && _selectedEmployeeId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار موظف')));
      return;
    }
    if (_partyType == 'other' && _selectedOtherAccountId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار حساب')));
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
        // Final fallback for older servers/configs.
        partyAccountId ??= _findAccountIdByNumber('1100');

        if (partyAccountId == null) {
          final expected = _customersAggregateAccountNumber ?? '1100';
          throw Exception(
            'العميل المختار لا يملك حساباً مرتبطاً، ولا يوجد حساب تجميعي للعملاء ($expected) في شجرة الحسابات',
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
        // Final fallback for older servers/configs: prefer 220 then 211.
        partyAccountId ??= _findAccountIdByNumber('220');
        partyAccountId ??= _findAccountIdByNumber('211');

        if (partyAccountId == null) {
          final expected = _suppliersAggregateAccountNumber ?? '220/211';
          throw Exception(
            'المورد المختار لا يملك حساباً مرتبطاً، ولا يوجد حساب تجميعي للموردين ($expected) في شجرة الحسابات',
          );
        }
      } else if (_partyType == 'employee') {
        // اختيار الموظف بالاسم، ثم الربط بالخلفية حسب القالب:
        // - راتب: ذمم الموظفين-رواتب (2400xxxx)
        // - سلفة: حساب الموظف ضمن الأصول (170xxxx)
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
              'لا يوجد حساب ذمم رواتب (2400xxxx) مرتبط بهذا الموظف.\n'
              'يرجى إنشاء/تأكيد حسابات الذمم للموظف من شاشة الموظفين (Ensure setup).',
            );
          }
        } else if (_selectedTemplateId == 'payment_bonus') {
          partyAccountId = _findEmployeeBonusPayableAccountId(selectedEmployee);
          if (partyAccountId == null) {
            throw Exception(
              'لا يوجد حساب مكافآت مستحقة (2310xxxx) في شجرة الحسابات.\n'
              'يرجى إنشاء حساب المكافآت المستحقة أولاً.',
            );
          }
        } else {
          // Default: employee personal account (170xxxx)
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يجب اختيار حساب لجميع السطور')),
          );
          setState(() => _isSaving = false);
          return;
        }

        if (line.amountType == 'cash') {
          if (line.amount <= 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('يجب إدخال مبلغ أكبر من صفر لجميع السطور'),
              ),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('يجب إدخال وزن أكبر من صفر في سطور الذهب'),
            ),
          );
          setState(() => _isSaving = false);
          return;
        }

        final hasMissingKarat = entries.any((entry) => entry.karat == null);
        if (hasMissingKarat) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يجب اختيار العيار لكل حقل ذهب')),
          );
          setState(() => _isSaving = false);
          return;
        }

        for (final entry in entries) {
          final netWeight = entry.netWeight ?? entry.amount;
          final stonesWeight = entry.stonesWeight ?? 0.0;
          final grossWeight = entry.grossWeight ?? (netWeight + stonesWeight);

          if (netWeight <= 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('الوزن الصافي يجب أن يكون أكبر من صفر'),
              ),
            );
            setState(() => _isSaving = false);
            return;
          }

          if (entry.netWeight != null &&
              (netWeight - entry.amount).abs() > 0.001) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('وزن السطر المحاسبي يجب أن يساوي الوزن الصافي'),
              ),
            );
            setState(() => _isSaving = false);
            return;
          }

          if (stonesWeight < 0 || grossWeight + 0.001 < netWeight) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'الوزن القائم يجب أن يكون أكبر من أو يساوي الصافي، ووزن الأحجار غير سالب',
                ),
              ),
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

      final auth = context.read<AuthProvider>();
      final createdBy = (auth.fullName.isNotEmpty
              ? auth.fullName
              : auth.username)
          .trim();

      // Prepare voucher data
      final Map<String, dynamic> voucherData = {
        'voucher_type': widget.voucherType,
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'party_type': _partyType,
        if (createdBy.isNotEmpty) 'created_by': createdBy,
        'description': _descriptionController.text,
        'notes': _notesController.text.isNotEmpty
            ? _notesController.text
            : null,
        'receiver_name': _receiverNameController.text.isNotEmpty
            ? _receiverNameController.text
            : null,
        'account_lines': allAccountLines,
        // The employee's declared purpose. 'invoice' keeps the existing
        // discriminator, which the cash side relies on in seven places; the
        // backend records the gold attribution at approval from it.
        if (_showGoldPurposeSelector) ...{
          'reference_type': _goldPaymentPurpose == 'invoice'
              ? 'invoice'
              : (_goldPaymentPurpose == 'advance' ? 'gold_advance' : 'gold_supplier'),
          if (_goldPaymentPurpose == 'invoice') 'reference_id': _goldPurposeInvoiceId,
        },
      };

      // عمولة / رسوم فرق العيار — احتساب per-line
      {
        double earnTotal = 0.0;
        double payTotal = 0.0;
        for (final line in _accountLines) {
          if (line.amountType != 'gold') continue;
          for (final entry in line.goldEntries) {
            if (entry.commissionDirection.isEmpty || entry.amount <= 0) continue;
            final amt = double.parse((entry.amount * entry.commissionPerGram).toStringAsFixed(2));
            if (entry.commissionDirection == 'earn') earnTotal += amt;
            if (entry.commissionDirection == 'pay') payTotal += amt;
          }
        }
        if (earnTotal > 0) voucherData['karat_diff_earn_total'] = double.parse(earnTotal.toStringAsFixed(2));
        if (payTotal > 0) voucherData['karat_diff_pay_total'] = double.parse(payTotal.toStringAsFixed(2));
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

      if (mounted) {
        // add id for preview
        voucherData['id'] = response['id'];
        voucherData['account_lines'] = (voucherData['account_lines'] as List)
            .map((line) {
              final account = _accounts.firstWhere(
                (acc) => acc['id'] == line['account_id'],
                orElse: () => <String, dynamic>{},
              );

              String? accountName = account['name'] as String?;
              if (accountName == null || accountName.isEmpty) {
                if (line['account_id'] == partyAccountId) {
                  if (selectedCustomer != null) {
                    accountName =
                        (selectedCustomer['account_name'] ??
                                selectedCustomer['account_category_name'])
                            as String?;
                  } else if (selectedSupplier != null) {
                    accountName =
                        (selectedSupplier['account_name'] ??
                                selectedSupplier['account_category_name'])
                            as String?;
                  } else if (selectedEmployee != null) {
                    accountName = selectedEmployee.name;
                  }
                }
              }

              accountName ??= account['name'] as String? ?? '---';

              return {...line, 'account_name': accountName};
            })
            .toList();

        // show success message and return to list
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.existingVoucher != null
                  ? 'تم تعديل السند بنجاح'
                  : 'تم إنشاء السند بنجاح',
            ),
            action: SnackBarAction(
              label: 'معاينة',
              textColor: AppColors.primaryGold,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => VoucherPreviewScreen(
                      voucherData: voucherData,
                      voucherType: widget.voucherType,
                    ),
                  ),
                );
              },
            ),
          ),
        );

        // العودة إلى شاشة السندات بعد الحفظ
        Navigator.of(context).pop(true); // إرسال true للإشارة إلى أنه تم الحفظ

        // إعادة تعيين النموذج للبقاء في نفس الشاشة
        setState(() {
          _isSaving = false;
          _descriptionController.clear();
          _notesController.clear();
          _accountLines.clear();
          _addNewLine(); // إضافة سطر جديد
          _selectedDate = DateTime.now();
        });
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
      }
    }
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
          color: AppColors.lightGold.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with line number and delete button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.lightGold.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'السطر ${index + 1}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepGold,
                    ),
                  ),
                ),
                if (_accountLines.length > 1)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: AppColors.error),
                    onPressed: () => _removeLine(index),
                  ),
              ],
            ),
            const Divider(height: 24),
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
              helperText: _shouldShowSafeBoxesForLineType(line.lineType)
                  ? 'تم تعبئة الخزنة الأكثر استخداماً تلقائياً. اضغط لعرض كل الخزنات.'
                  : 'اضغط داخل الحقل لعرض كل الحسابات ثم ابحث بالاسم أو الرقم.',
              showTransactionTypeFilter: false,
              showTracksWeightFilter: false,
              validator: (value) {
                if (value == null) {
                  return 'يجب اختيار حساب';
                }
                return null;
              },
              onChanged: (value) {
                setState(() {
                  line.accountId = value;
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

                final safeId = safe.id!;
                final isLoadingFallback = _safeLedgerCashBalanceLoading
                    .contains(safeId);
                final bal = _getAvailableSafeCash(safe);
                final amount = _parseLineAmount(line.amount);

                final isOutflowFromSafe =
                    widget.voucherType == 'payment' &&
                    line.lineType == 'credit' &&
                    line.amountType == 'cash';
                final insufficient =
                    isOutflowFromSafe && bal != null && amount > bal + 0.01;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      context.read<SettingsProvider>().buildText(
                        bal != null
                            ? 'الرصيد الفعلي الحالي: ${bal.toStringAsFixed(2)} $_currencySymbol'
                            : (isLoadingFallback
                                  ? 'جاري تحميل الرصيد الاحتياطي للخزنة...'
                                  : 'الرصيد الفعلي غير متاح'),
                        style: TextStyle(
                          color: insufficient
                              ? AppColors.error
                              : Colors.grey.shade700,
                          fontWeight: insufficient
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (insufficient)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'تنبيه: الرصيد لا يغطي مبلغ الصرف',
                            style: TextStyle(
                              color: AppColors.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),

            // Amount type (Cash/Gold)
            RadioGroup<String>(
              groupValue: line.amountType,
              onChanged: (value) {
                if (value == null) {
                  return;
                }
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
                      line.accountId = def?.accountId;
                    }
                  } else if (oldAmountType != value &&
                      _shouldShowSafeBoxesForLineType(line.lineType)) {
                    // If this line is expected to point to a safe account,
                    // auto-select a default when switching types.
                    final def = _defaultSafeForAmountType(
                      lineType: line.lineType,
                      amountType: value,
                    );
                    if (def != null) {
                      line.accountId = def.accountId;
                    }
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
              },
              child: Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('نقد'),
                      value: 'cash',
                      enabled: _lockedAmountTypeForCurrentParty != 'gold',
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('ذهب'),
                      value: 'gold',
                      enabled: _lockedAmountTypeForCurrentParty != 'cash',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            if (line.amountType == 'cash')
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
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
                            color: AppColors.mediumGold.withValues(alpha: 0.3),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: AppColors.primaryGold,
                            width: 2,
                          ),
                        ),
                        prefixIcon: Icon(
                          Icons.attach_money,
                          color: AppColors.primaryGold,
                        ),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                      onChanged: (value) {
                        setState(() {
                          line.amount = double.tryParse(value) ?? 0;
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
                              color: AppColors.lightGold.withValues(
                                alpha: 0.14,
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppColors.mediumGold.withValues(
                                  alpha: 0.28,
                                ),
                              ),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.diamond_outlined,
                                      size: 16,
                                      color: AppColors.darkGold,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'حقل ذهب ${entryIndex + 1} - عيار $karatLabel',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.deepGold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
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
                                              color: AppColors.mediumGold
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: AppColors.primaryGold,
                                              width: 2,
                                            ),
                                          ),
                                          prefixIcon: Icon(
                                            Icons.scale,
                                            color: AppColors.primaryGold,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          NormalizeNumberFormatter(),
                                        ],
                                        onChanged: (value) {
                                          setState(() {
                                            entry.amount =
                                                double.tryParse(value) ?? 0;
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
                                              color: AppColors.mediumGold
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            borderSide: BorderSide(
                                              color: AppColors.primaryGold,
                                              width: 2,
                                            ),
                                          ),
                                          prefixIcon: Icon(
                                            Icons.diamond,
                                            color: AppColors.primaryGold,
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
                                        color: Colors.red.shade400,
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
            const SizedBox(height: 12),

            // Description (optional)
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
    final isWideLayout = size.width >= 1100;
    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = isReceipt ? AppColors.success : AppColors.error;
    final String title = isReceipt ? 'سند قبض' : 'سند صرف';
    final IconData icon = isReceipt ? Icons.south : Icons.north;

    final List<Widget> leftColumn = [
      // المساعد السريع في أعلى العمود الأيسر
      _buildTemplateSelector(),
      const SizedBox(height: 12),
      _buildStatusBoard(),
      const SizedBox(height: 12),
      _buildPartySelectorCard(),
    ];

    final partyInfo = _buildPartyInfoCard();
    if (partyInfo is! SizedBox) {
      leftColumn
        ..add(const SizedBox(height: 10))
        ..add(partyInfo);
    }

    if (_showGoldPurposeSelector) {
      leftColumn
        ..add(const SizedBox(height: 12))
        ..add(_buildGoldPurposeCard());
    }

    leftColumn.addAll([
      const SizedBox(height: 12),
      _buildDescriptionCard(),
      const SizedBox(height: 12),
      _buildReceiverCard(),
      const SizedBox(height: 12),
      _buildAttachmentsCard(),
    ]);

    // تم نقل المساعد السريع إلى أعلى الشاشة

    final accountLineCards = _accountLines
        .asMap()
        .entries
        .map((entry) => _buildAccountLineCard(entry.key))
        .toList();

    final List<Widget> rightColumn = [
      _buildAccountLinesHeader(),
      const SizedBox(height: 12),
      ...accountLineCards,
      if (accountLineCards.isNotEmpty) const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('إضافة سطر'),
          onPressed: _addNewLine,
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: Colors.white,
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _buildTotalsCard(),
      const SizedBox(height: 16),
      _buildNotesCard(),
      const SizedBox(height: 20),
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

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: AppColors.deepGold,
        foregroundColor: Colors.white,
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
              icon: const Icon(Icons.schedule, color: Colors.white70),
              label: const Text(
                'إكمال لاحقاً',
                style: TextStyle(color: Colors.white70),
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
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeroHeader(
                        context,
                        isReceipt,
                        accentColor,
                        icon,
                        title,
                      ),
                      const SizedBox(height: 24),
                      layoutContent,
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  String _formatCash(double amount, {bool includeSymbol = true}) {
    final formatter = NumberFormat.currency(
      symbol: includeSymbol ? _currencySymbol : '',
      decimalDigits: _currencyDecimalPlaces,
    );
    final formatted = formatter.format(amount).replaceAll('\u00A0', ' ');
    return includeSymbol ? formatted : formatted.trim();
  }

  String _formatWeight(
    double amount, {
    int? decimals,
    bool includeUnit = true,
  }) {
    final effectiveDecimals = decimals ?? (amount.abs() < 1 ? 3 : 2);
    final formatted = amount.toStringAsFixed(effectiveDecimals);
    return includeUnit ? '$formatted جم' : formatted;
  }
}
