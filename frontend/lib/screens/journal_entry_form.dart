import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:convert';

import '../theme/app_theme.dart';
import '../utils/arabic_number_formatter.dart';
import '../utils/journal_balance.dart';
import '../utils/journal_readiness.dart';
import '../utils/bidi.dart';
import '../widgets/account_picker_sheet.dart';
import '../widgets/journal_balance_row.dart';

// --- Data Models ---
class JournalLine {
  int? accountId;
  String? accountName;
  String? accountNumber;
  String? accountTransactionType; // 'cash', 'gold', or 'both'
  final TextEditingController cashDebitController;
  final TextEditingController cashCreditController;
  final Map<int, TextEditingController> goldDebitControllers = {};
  final Map<int, TextEditingController> goldCreditControllers = {};
  final Map<int, bool> goldKaratEnabled = {};

  /// Finds the line on screen (scroll to a line that blocks saving) and keeps
  /// each row's field state with its line when lines are added or removed.
  final GlobalKey rowKey = GlobalKey();

  /// The karat breakdown under the line is open.
  bool goldDetailOpen = false;

  JournalLine({
    this.accountId,
    this.accountName,
    this.accountNumber,
    this.accountTransactionType,
    String cashDebit = '',
    String cashCredit = '',
    Map<int, String>? goldDebits,
    Map<int, String>? goldCredits,
    Set<int>? defaultGoldKarats,
    required List<int> karats,
  }) : cashDebitController = TextEditingController(text: blankZero(cashDebit)),
       cashCreditController = TextEditingController(
         text: blankZero(cashCredit),
       ) {
    for (var karat in karats) {
      final debitText = blankZero(goldDebits?[karat]);
      final creditText = blankZero(goldCredits?[karat]);

      goldDebitControllers[karat] = TextEditingController(text: debitText);
      goldCreditControllers[karat] = TextEditingController(text: creditText);

      final debitValue = double.tryParse(debitText) ?? 0.0;
      final creditValue = double.tryParse(creditText) ?? 0.0;

      final isDefaultEnabled = defaultGoldKarats?.contains(karat) ?? false;

      final hasValue = debitValue != 0.0 || creditValue != 0.0;
      goldKaratEnabled[karat] = hasValue || isDefaultEnabled;
    }

    // Ensure at least one karat enabled when defaults provided
    if (goldKaratEnabled.values.where((enabled) => enabled).isEmpty &&
        defaultGoldKarats != null &&
        defaultGoldKarats.isNotEmpty) {
      final fallback = defaultGoldKarats.first;
      if (goldKaratEnabled.containsKey(fallback)) {
        goldKaratEnabled[fallback] = true;
      } else if (goldKaratEnabled.isNotEmpty) {
        final firstKey = goldKaratEnabled.keys.first;
        goldKaratEnabled[firstKey] = true;
      }
    }
  }

  /// An amount field starts empty, not «0.0» the accountant must delete first;
  /// an empty field is sent as 0 ([toMap]).
  static String blankZero(Object? value) {
    final text = '${value ?? ''}'.trim();
    return (double.tryParse(text) ?? 0.0) == 0.0 ? '' : text;
  }

  factory JournalLine.fromMap(Map<String, dynamic> map, List<int> karats) {
    Map<int, String> goldDebits = {};
    Map<int, String> goldCredits = {};
    for (var karat in karats) {
      goldDebits[karat] = (map['debit_${karat}k'] ?? 0.0).toString();
      goldCredits[karat] = (map['credit_${karat}k'] ?? 0.0).toString();
    }

    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return int.tryParse('${v ?? ''}');
    }

    return JournalLine(
      accountId: toInt(map['account_id'] ?? map['accountId']),
      accountName: map['account_name']?.toString(),
      accountNumber: map['account_number']?.toString(),
      // transaction type is set later after accounts are fetched
      cashDebit: (map['cash_debit'] ?? 0.0).toString(),
      cashCredit: (map['cash_credit'] ?? 0.0).toString(),
      goldDebits: goldDebits,
      goldCredits: goldCredits,
      karats: karats,
    );
  }

  Map<String, dynamic> toMap() {
    final map = {
      'account_id': accountId,
      'cash_debit': double.tryParse(cashDebitController.text) ?? 0.0,
      'cash_credit': double.tryParse(cashCreditController.text) ?? 0.0,
    };
    for (var karat in goldDebitControllers.keys) {
      map['debit_${karat}k'] =
          double.tryParse(goldDebitControllers[karat]!.text) ?? 0.0;
      map['credit_${karat}k'] =
          double.tryParse(goldCreditControllers[karat]!.text) ?? 0.0;
    }
    return map;
  }

  bool get hasGoldValues {
    for (var controller in goldDebitControllers.values) {
      if ((double.tryParse(controller.text) ?? 0.0) != 0.0) return true;
    }
    for (var controller in goldCreditControllers.values) {
      if ((double.tryParse(controller.text) ?? 0.0) != 0.0) return true;
    }
    return false;
  }

  bool get hasValues {
    if ((double.tryParse(cashDebitController.text) ?? 0.0) != 0.0) return true;
    if ((double.tryParse(cashCreditController.text) ?? 0.0) != 0.0) return true;
    return hasGoldValues;
  }

  void clearCashFields() {
    cashDebitController.text = '';
    cashCreditController.text = '';
  }

  void clearGoldFields({bool disable = false}) {
    for (var c in goldDebitControllers.values) {
      c.text = '';
    }
    for (var c in goldCreditControllers.values) {
      c.text = '';
    }

    if (disable) {
      goldKaratEnabled.updateAll((key, value) => false);
    }
  }

  void setGoldKaratEnabled(int karat, bool enabled) {
    goldKaratEnabled[karat] = enabled;
    if (!enabled) {
      goldDebitControllers[karat]?.text = '';
      goldCreditControllers[karat]?.text = '';
    }
  }

  bool isGoldKaratEnabled(int karat) {
    return goldKaratEnabled[karat] ?? false;
  }

  void dispose() {
    cashDebitController.dispose();
    cashCreditController.dispose();
    for (var c in goldDebitControllers.values) {
      c.dispose();
    }
    for (var c in goldCreditControllers.values) {
      c.dispose();
    }
  }
}

// --- Screen to Add/Edit a Journal Entry ---
class AddEditJournalEntryScreen extends StatefulWidget {
  final dynamic entry;
  final bool isEditMode;

  /// The server; tests pass a fake. Defaults to the app's [ApiService].
  final ApiService? apiService;

  const AddEditJournalEntryScreen({
    super.key,
    this.entry,
    this.isEditMode = false,
    this.apiService,
  });

  @override
  State<AddEditJournalEntryScreen> createState() =>
      _AddEditJournalEntryScreenState();
}

class _AddEditJournalEntryScreenState extends State<AddEditJournalEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  late final ApiService _apiService = widget.apiService ?? ApiService();
  late TextEditingController _descriptionController;
  late TextEditingController _dateController;
  late TextEditingController _referenceNumberController;
  late ScrollController _linesScrollController;

  List<JournalLine> _lines = [];
  List<dynamic> _accounts = [];
  // Account IDs that are directly linked to a SafeBox — selecting one in a manual
  // JE will NOT create a SafeBoxTransaction (server-side guard).  Show a warning.
  final Set<int> _safeBoxAccountIds = {};
  final List<int> _supportedKarats = [18, 21, 22, 24];
  int _mainKarat = 21;
  int _currencyDecimalPlaces = 2;
  bool _settingsSynced = false;
  bool _calculatingTotals = false;
  String _selectedEntryType = 'عادي'; // نوع القيد
  String? _referenceType; // نوع المرجع

  double _totalCashDebit = 0.0;
  double _totalCashCredit = 0.0;
  double _totalGoldDebit = 0.0;
  double _totalGoldCredit = 0.0;

  bool _checkedLocalDraft = false;

  // One save at a time: a second tap while the request is out would post the
  // same entry twice.
  bool _isSaving = false;

  // After a refused save, every line shows its own error until fixed.
  bool _showErrors = false;

  // An entry was saved by «save and new»; leaving tells the list to refresh.
  bool _savedAny = false;

  // Bumped on «save and new» so the header dropdowns start over.
  int _formGeneration = 0;

  _AccountIndex _index = _AccountIndex.of(const []);

  // The form as it stood once loaded; leaving with anything different asks first.
  String _initialSnapshot = '';

  bool get _isDirty =>
      _initialSnapshot.isNotEmpty &&
      jsonEncode(_buildLocalDraftPayload()) != _initialSnapshot;

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(
      text: widget.entry?['description'] ?? '',
    );
    _dateController = TextEditingController(
      text:
          widget.entry?['date'] ??
          DateTime.now().toIso8601String().split('T').first,
    );
    _referenceNumberController = TextEditingController(
      text: widget.entry?['reference_number'] ?? '',
    );

    _selectedEntryType = widget.entry?['entry_type'] ?? 'عادي';
    _referenceType = widget.entry?['reference_type'];

    _linesScrollController = ScrollController();

    if (widget.entry != null) {
      final entryLines = List<Map<String, dynamic>>.from(widget.entry['lines']);
      _lines = entryLines
          .map((lineMap) => JournalLine.fromMap(lineMap, _supportedKarats))
          .toList();
    }

    _fetchInitialData();
  }

  String _localDraftKey() {
    return 'yasargold_journal_entry_complete_later';
  }

  Map<String, dynamic> _buildLocalDraftPayload() {
    final linesPayload = _lines
        // Keep account selections even if amounts are zero.
        .where((line) => line.hasValues || line.accountId != null)
        .map((line) {
          final enabledKarats = <int>[];
          for (final k in _supportedKarats) {
            if (line.isGoldKaratEnabled(k)) enabledKarats.add(k);
          }
          return {
            'account_id': line.accountId,
            'account_name': line.accountName,
            'account_number': line.accountNumber,
            'cash_debit': line.cashDebitController.text,
            'cash_credit': line.cashCreditController.text,
            for (final k in _supportedKarats)
              'debit_${k}k': line.goldDebitControllers[k]?.text ?? '0.0',
            for (final k in _supportedKarats)
              'credit_${k}k': line.goldCreditControllers[k]?.text ?? '0.0',
            'enabled_karats': enabledKarats,
          };
        })
        .toList();

    return {
      'date': _dateController.text,
      'description': _descriptionController.text,
      'reference_number': _referenceNumberController.text,
      'entry_type': _selectedEntryType,
      'reference_type': _referenceType,
      'lines': linesPayload,
    };
  }

  Future<void> _saveLocalDraft({bool showToast = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _localDraftKey(),
      jsonEncode(_buildLocalDraftPayload()),
    );
    if (showToast && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ القيد لإكماله لاحقاً')),
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

    // Do not restore over edit mode.
    if (widget.entry != null) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_localDraftKey());
    if (raw == null || raw.trim().isEmpty) return;

    Map<String, dynamic>? decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      await _clearLocalDraft();
      return;
    }

    final bool? restore = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('محفوظ للإكمال لاحقاً'),
        content: const Text('يوجد قيد محفوظ لإكماله لاحقاً. هل تريد استعادته؟'),
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

    int? toInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return int.tryParse('${v ?? ''}');
    }

    try {
      // Dispose old lines to avoid controller leaks.
      for (final line in _lines) {
        line.dispose();
      }

      final decodedLines =
          (decoded['lines'] as List?)?.whereType<Map>().toList() ?? [];
      final restored = <JournalLine>[];
      for (final rawLine in decodedLines) {
        final map = Map<String, dynamic>.from(rawLine);
        final enabled =
            (map['enabled_karats'] as List?)
                ?.map((e) => toInt(e))
                .whereType<int>()
                .toSet() ??
            <int>{};

        final jl = JournalLine(
          accountId: toInt(map['account_id']),
          accountName: map['account_name']?.toString(),
          accountNumber: map['account_number']?.toString(),
          cashDebit: (map['cash_debit'] ?? '0.0').toString(),
          cashCredit: (map['cash_credit'] ?? '0.0').toString(),
          goldDebits: {
            for (final k in _supportedKarats)
              k: (map['debit_${k}k'] ?? '0.0').toString(),
          },
          goldCredits: {
            for (final k in _supportedKarats)
              k: (map['credit_${k}k'] ?? '0.0').toString(),
          },
          defaultGoldKarats: enabled,
          karats: _supportedKarats,
        );
        restored.add(jl);
      }

      setState(() {
        _dateController.text = (decoded?['date'] ?? _dateController.text)
            .toString();
        _descriptionController.text = (decoded?['description'] ?? '')
            .toString();
        _referenceNumberController.text = (decoded?['reference_number'] ?? '')
            .toString();
        _selectedEntryType = (decoded?['entry_type'] ?? _selectedEntryType)
            .toString();
        _referenceType = decoded?['reference_type']?.toString();
        _lines = restored;
      });

      // Sync line transaction types if accounts already loaded.
      if (_accounts.isNotEmpty) {
        for (final line in _lines) {
          if (line.accountId == null) continue;
          try {
            final account = _accounts.firstWhere(
              (acc) => toInt(acc['id']) == line.accountId,
            );
            line.accountTransactionType = account['transaction_type'];
          } catch (_) {
            // ignore
          }
        }
      }

      _calculateTotals();
    } catch (_) {
      // If restore fails, clear draft to prevent looping.
      await _clearLocalDraft();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbolText;
    final newDecimals = settings.decimalPlaces;
    final newMainKarat = settings.mainKarat;

    final shouldSync =
        !_settingsSynced ||
        newSymbol != _currencySymbol ||
        newDecimals != _currencyDecimalPlaces ||
        newMainKarat != _mainKarat;

    if (shouldSync) {
      _settingsSynced = true;
      setState(() {
        _currencyDecimalPlaces = newDecimals;
        _mainKarat = newMainKarat;
      });
      _calculateTotals();
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _dateController.dispose();
    _referenceNumberController.dispose();
    for (var line in _lines) {
      line.dispose();
    }
    _linesScrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    await _maybePromptRestoreLocalDraft();
    await _fetchAccounts();

    // If no lines were provided (new entry), create two ready lines on open
    if (_lines.isEmpty) {
      setState(() {
        _lines.addAll([
          JournalLine(
            karats: _supportedKarats,
            defaultGoldKarats: {_mainKarat},
          ),
          JournalLine(
            karats: _supportedKarats,
            defaultGoldKarats: {_mainKarat},
          ),
        ]);
      });
    }

    _calculateTotals(); // Calculate totals after all data is fetched/initialized
    _initialSnapshot = jsonEncode(_buildLocalDraftPayload());

    // Load safe box account IDs in the background so we can warn users.
    _apiService
        .getSafeBoxes()
        .then((boxes) {
          if (!mounted) return;
          setState(() {
            _safeBoxAccountIds.addAll(boxes.map((b) => b.accountId));
          });
        })
        .catchError((_) {
          // Non-critical — silently ignore if safe boxes can't be loaded.
        });
  }

  Future<void> _fetchAccounts() async {
    try {
      final accounts = await _apiService.getAccounts();
      if (mounted) {
        setState(() {
          int? toInt(dynamic v) {
            if (v is int) return v;
            if (v is num) return v.toInt();
            if (v is String) return int.tryParse(v);
            return int.tryParse('${v ?? ''}');
          }

          _accounts = accounts;
          final accountIds = _accounts
              .map((acc) => toInt(acc['id']))
              .whereType<int>()
              .toSet();

          // Add placeholder accounts for lines that reference missing accounts.
          for (var line in _lines) {
            final lineId = toInt(line.accountId);
            if (lineId != null && !accountIds.contains(lineId)) {
              final placeholderName =
                  (line.accountName?.trim().isNotEmpty == true)
                  ? line.accountName!.trim()
                  : 'حساب غير متاح (ID: $lineId)';
              final placeholderNumber = line.accountNumber?.trim() ?? '';
              _accounts.add({
                'id': lineId,
                'account_number': placeholderNumber,
                'name': placeholderName,
              });
              accountIds.add(lineId);
            }
          }

          _index = _AccountIndex.of(_accounts);

          // After fetching accounts, update transaction types for existing lines
          for (var line in _lines) {
            if (line.accountId != null) {
              try {
                final lineId = toInt(line.accountId);
                final account = _accounts.firstWhere(
                  (acc) => toInt(acc['id']) == lineId,
                );
                line.accountTransactionType = account['transaction_type'];
                if (line.accountTransactionType == 'gold' ||
                    line.accountTransactionType == 'both') {
                  _ensureDefaultGoldKaratSelections(line);
                }
              } catch (e) {
                // Account not found, might be an old or deleted account
              }
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل تحميل الحسابات: ${e.toString()}')),
        );
      }
    }
  }

  void _calculateTotals() {
    // Guard against recursive/concurrent calls during build.
    if (_calculatingTotals || !mounted) return;
    _calculatingTotals = true;

    try {
      double cashDebit = 0.0;
      double cashCredit = 0.0;
      double goldDebit = 0.0;
      double goldCredit = 0.0;

      for (var line in _lines) {
        cashDebit += double.tryParse(line.cashDebitController.text) ?? 0.0;
        cashCredit += double.tryParse(line.cashCreditController.text) ?? 0.0;

        for (var karat in _supportedKarats) {
          final debitWeight =
              double.tryParse(line.goldDebitControllers[karat]!.text) ?? 0.0;
          final creditWeight =
              double.tryParse(line.goldCreditControllers[karat]!.text) ?? 0.0;
          goldDebit += _convertToMainKarat(debitWeight, karat);
          goldCredit += _convertToMainKarat(creditWeight, karat);
        }
      }

      if (!mounted) return;
      const eps = 1e-9;
      final changed =
          (cashDebit - _totalCashDebit).abs() > eps ||
          (cashCredit - _totalCashCredit).abs() > eps ||
          (goldDebit - _totalGoldDebit).abs() > eps ||
          (goldCredit - _totalGoldCredit).abs() > eps;
      if (!changed) return;

      setState(() {
        _totalCashDebit = cashDebit;
        _totalCashCredit = cashCredit;
        _totalGoldDebit = goldDebit;
        _totalGoldCredit = goldCredit;
      });
    } finally {
      _calculatingTotals = false;
    }
  }

  double _convertToMainKarat(double weight, int fromKarat) {
    if (fromKarat == 0 || _mainKarat == 0) return 0;
    return (weight * fromKarat) / _mainKarat;
  }

  void _ensureDefaultGoldKaratSelections(JournalLine line) {
    if (line.goldKaratEnabled.values.any((enabled) => enabled)) {
      return;
    }

    int? fallback;
    if (line.goldKaratEnabled.containsKey(_mainKarat)) {
      fallback = _mainKarat;
    } else if (line.goldKaratEnabled.isNotEmpty) {
      fallback = line.goldKaratEnabled.keys.first;
    }

    if (fallback != null) {
      line.setGoldKaratEnabled(fallback, true);
    }
  }

  String _formatCashValue(double amount, {bool includeSymbol = true}) {
    final format = NumberFormat.currency(
      symbol: includeSymbol ? _currencySymbol : '',
      decimalDigits: _currencyDecimalPlaces,
    );
    final formatted = format.format(amount);
    return includeSymbol ? formatted : formatted.trim();
  }

  void _addLine() {
    setState(() {
      _lines.add(
        JournalLine(karats: _supportedKarats, defaultGoldKarats: {_mainKarat}),
      );
    });

    // After adding a line, scroll to bottom so the new line and the button
    // (which becomes the last item) are visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_linesScrollController.hasClients) {
        _linesScrollController.animateTo(
          _linesScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _removeLine(int index) {
    final removed = _lines[index];
    setState(() => _lines.removeAt(index));
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
    _calculateTotals();
  }

  void _onAccountChanged(JournalLine line, int? accountId) {
    setState(() {
      line.accountId = accountId;
      if (accountId == null) {
        line.accountTransactionType = null;
        line.clearGoldFields(disable: true);
      } else {
        line.accountTransactionType = _accountById(
          accountId,
        )?['transaction_type'];

        // Clear fields based on new account type
        if (line.accountTransactionType == 'cash') {
          line.clearGoldFields(disable: true);
        } else if (line.accountTransactionType == 'gold') {
          line.clearCashFields();
          _ensureDefaultGoldKaratSelections(line);
        } else {
          _ensureDefaultGoldKaratSelections(line);
        }
      }
    });

    _calculateTotals();
  }

  // --- Balance Logic ---
  void _balanceGold(
    TextEditingController targetController,
    int targetKarat,
    bool isDebitField,
  ) {
    final currentValue = double.tryParse(targetController.text) ?? 0.0;
    final currentValueInMain = _convertToMainKarat(currentValue, targetKarat);

    final totalDebitWithoutTarget = isDebitField
        ? _totalGoldDebit - currentValueInMain
        : _totalGoldDebit;
    final totalCreditWithoutTarget = !isDebitField
        ? _totalGoldCredit - currentValueInMain
        : _totalGoldCredit;

    double neededInMain;
    if (isDebitField) {
      neededInMain = totalCreditWithoutTarget - totalDebitWithoutTarget;
    } else {
      neededInMain = totalDebitWithoutTarget - totalCreditWithoutTarget;
    }

    if (neededInMain < 0) {
      neededInMain = 0;
    }

    final finalWeight = (neededInMain * _mainKarat) / targetKarat;

    targetController.text = finalWeight.toStringAsFixed(4);
    _calculateTotals();
  }

  // --- Save Logic ---
  Future<void> _saveJournalEntry({bool andNew = false}) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _saveJournalEntryOnce(andNew: andNew);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveJournalEntryOnce({required bool andNew}) async {
    // The screen saves only what the server will accept; otherwise it shows
    // why, on the line that blocks it.
    final readiness = _readiness();
    if (!readiness.isReady) {
      _revealProblem(readiness);
      return;
    }
    if (!_formKey.currentState!.validate()) {
      _revealProblem(readiness);
      return;
    }

    // Finally, check for balance and ask for confirmation if needed
    if (!await _checkBalances()) return;

    // Warn (don't silently redirect) when a line posts a gold amount on a
    // cash-only account or a cash amount on a gold-only account -- e.g. the
    // financial side of a customer/supplier pair instead of its linked
    // weight account. Accounts with transaction_type 'both' (safe-box-linked,
    // real physical custody) are exempt, matching the voucher posting logic.
    if (!await _checkAccountTypeMismatches()) return;

    final data = {
      'description': _descriptionController.text,
      'date': _dateController.text,
      'entry_type': _selectedEntryType,
      'reference_type': _referenceType,
      'reference_number': _referenceNumberController.text.isEmpty
          ? null
          : _referenceNumberController.text,
      'lines': _lines
          .where((line) => line.hasValues)
          .map((line) => line.toMap())
          .toList(),
    };

    try {
      if (widget.entry == null) {
        await _apiService.addJournalEntry(data);
      } else {
        await _apiService.updateJournalEntry(widget.entry['id'], data);
      }
      if (mounted) {
        await _clearLocalDraft();
        if (!mounted) return;
        _savedAny = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم حفظ القيد'),
            backgroundColor: AppColors.success,
          ),
        );
        if (andNew) {
          _resetForNew();
        } else {
          Navigator.of(context).pop(true); // Return true to indicate success
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'فشل حفظ القيد: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  Future<bool> _checkBalances() async {
    const tolerance = 0.001;
    if ((_totalCashDebit - _totalCashCredit).abs() > tolerance) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('القيد النقدي غير متوازن. الرجاء مراجعة الإدخالات'),
        ),
      );
      return false;
    }

    final gap = (_totalGoldDebit - _totalGoldCredit).abs().toStringAsFixed(4);
    switch (goldBalanceVerdict(_totalGoldDebit, _totalGoldCredit)) {
      case GoldBalanceVerdict.balanced:
        break;
      case GoldBalanceVerdict.serverWillSettle:
        final bool? proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('فرق ذهب طفيف'),
            content: Text(
              'الفرق $gap غرام، وهو أقل من 0.01 غرام. ستسوّيه المنظومة '
              'تلقائياً بتعديل أحد الأسطر. هل تتابع؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('العودة والمراجعة'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('متابعة'),
              ),
            ],
          ),
        );
        return proceed ?? false;
      case GoldBalanceVerdict.mustFix:
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('قيد الذهب غير متوازن'),
            content: Text(
              'الفرق $gap غرام (بعيار الأساس $_mainKarat). لا تسوّي المنظومة '
              'تلقائياً إلا ما دون 0.01 غرام، لذا لا يمكن حفظ القيد هكذا. '
              'عدّل الأوزان أو استخدم زر الموازنة بجانب خانة الوزن.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('العودة والمراجعة'),
              ),
            ],
          ),
        );
        return false;
    }
    return true;
  }

  Future<bool> _checkAccountTypeMismatches() async {
    final mismatches = <String>[];
    for (var line in _lines) {
      if (!line.hasValues || line.accountId == null) continue;
      final account = _accountById(line.accountId);
      if (account == null) continue;
      final type = (account['transaction_type'] ?? '').toString().toLowerCase();
      if (type == 'both') continue; // safe-box-linked, real custody — exempt
      // Dual-account pair member (cash↔gold): backend auto-routes mismatched
      // values to the correct parallel account — no user action needed.
      if (account['memo_account_id'] != null) continue;

      final hasCash =
          (double.tryParse(line.cashDebitController.text) ?? 0.0) != 0.0 ||
          (double.tryParse(line.cashCreditController.text) ?? 0.0) != 0.0;

      if (type == 'cash' && line.hasGoldValues) {
        mismatches.add(
          '"${account['name']}" حساب نقدي، وله مبلغ ذهب مُدخَل عليه مباشرة.',
        );
      } else if (type == 'gold' && hasCash) {
        mismatches.add(
          '"${account['name']}" حساب وزني، وله مبلغ نقدي مُدخَل عليه مباشرة.',
        );
      }
    }

    if (mismatches.isEmpty) return true;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تنبيه: نوع مبلغ مخالف لنوع الحساب'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in mismatches)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $m'),
              ),
            const SizedBox(height: 6),
            const Text(
              'إن لم يكن هذا مقصوداً، تحقق من اختيار الحساب الصحيح (المالي أو الوزني المرتبط).',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('نعم، متابعة'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('الرجوع والمراجعة'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  // --- Readiness ---
  Map<String, dynamic>? _accountById(int? id) {
    if (id == null) return null;
    for (final a in _index.sorted) {
      if (_asInt(a['id']) == id) return a;
    }
    return null;
  }

  JournalReadiness _readiness() {
    return journalReadiness(
      description: _descriptionController.text,
      lines: [
        for (final l in _lines)
          JournalLineFacts(
            hasValues: l.hasValues,
            hasAccount: l.accountId != null,
            accountIsParent:
                l.accountId != null && _index.parents.contains(l.accountId),
            accountMissing:
                _index.known.isNotEmpty &&
                l.accountId != null &&
                !_index.known.contains(l.accountId),
          ),
      ],
      cashDebit: _totalCashDebit,
      cashCredit: _totalCashCredit,
      goldDebit: _totalGoldDebit,
      goldCredit: _totalGoldCredit,
      formatCash: (v) => _formatCashValue(v, includeSymbol: false),
    );
  }

  /// Shows every line's error and brings the first blocking line into view.
  void _revealProblem(JournalReadiness readiness) {
    setState(() => _showErrors = true);
    final i = readiness.lineIndex;
    if (i == null || i >= _lines.length) return;
    final target = _lines[i].rowKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        alignment: 0.3,
      );
    }
  }

  void _onSavePressed({bool andNew = false}) {
    if (_isSaving) return;
    final readiness = _readiness();
    if (!readiness.isReady) {
      _revealProblem(readiness);
      return;
    }
    _saveJournalEntry(andNew: andNew);
  }

  /// «Save and new»: the next entry keeps the date and type, nothing else.
  void _resetForNew() {
    final old = List<JournalLine>.from(_lines);
    setState(() {
      _lines = [
        JournalLine(karats: _supportedKarats, defaultGoldKarats: {_mainKarat}),
        JournalLine(karats: _supportedKarats, defaultGoldKarats: {_mainKarat}),
      ];
      _descriptionController.clear();
      _referenceNumberController.clear();
      _referenceType = null;
      _showErrors = false;
      _formGeneration++;
      _totalCashDebit = 0;
      _totalCashCredit = 0;
      _totalGoldDebit = 0;
      _totalGoldCredit = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final l in old) {
        l.dispose();
      }
    });
    _initialSnapshot = jsonEncode(_buildLocalDraftPayload());
  }

  // --- Line actions ---
  void _duplicateLine(int index) {
    final src = _lines[index];
    final copy = JournalLine(
      accountId: src.accountId,
      accountName: src.accountName,
      accountNumber: src.accountNumber,
      accountTransactionType: src.accountTransactionType,
      cashDebit: src.cashDebitController.text,
      cashCredit: src.cashCreditController.text,
      goldDebits: {
        for (final k in _supportedKarats) k: src.goldDebitControllers[k]!.text,
      },
      goldCredits: {
        for (final k in _supportedKarats) k: src.goldCreditControllers[k]!.text,
      },
      defaultGoldKarats: {
        for (final k in _supportedKarats)
          if (src.isGoldKaratEnabled(k)) k,
      },
      karats: _supportedKarats,
    )..goldDetailOpen = src.goldDetailOpen;
    setState(() => _lines.insert(index + 1, copy));
    _calculateTotals();
  }

  /// Adds the entry's remaining cash difference to this line, on the short side.
  void _balanceCashOnLine(JournalLine line) {
    final gap = _totalCashDebit - _totalCashCredit;
    if (gap.abs() <= kBalanceTolerance) {
      _say('النقد متوازن');
      return;
    }
    final target = gap > 0
        ? line.cashCreditController
        : line.cashDebitController;
    final current = double.tryParse(target.text) ?? 0.0;
    setState(() {
      target.text = (current + gap.abs()).toStringAsFixed(
        _currencyDecimalPlaces,
      );
    });
    _calculateTotals();
  }

  /// Adds the entry's remaining gold difference to this line, on the short
  /// side, in its first active karat (the base karat when active).
  void _balanceGoldOnLine(JournalLine line) {
    final gap = _totalGoldDebit - _totalGoldCredit;
    if (gap.abs() <= kBalanceTolerance) {
      _say('الذهب متوازن');
      return;
    }
    final karat = line.isGoldKaratEnabled(_mainKarat)
        ? _mainKarat
        : _supportedKarats.firstWhere(
            line.isGoldKaratEnabled,
            orElse: () => _mainKarat,
          );
    setState(() => line.setGoldKaratEnabled(karat, true));
    final isDebit = gap < 0;
    _balanceGold(
      isDebit
          ? line.goldDebitControllers[karat]!
          : line.goldCreditControllers[karat]!,
      karat,
      isDebit,
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  double _lineGoldInMain(JournalLine line, {required bool debit}) {
    var total = 0.0;
    for (final k in _supportedKarats) {
      if (!line.isGoldKaratEnabled(k)) continue;
      final c = debit
          ? line.goldDebitControllers[k]!
          : line.goldCreditControllers[k]!;
      total += _convertToMainKarat(double.tryParse(c.text) ?? 0.0, k);
    }
    return total;
  }

  /// Only the base karat is in use: the gold columns edit it directly.
  bool _goldIsSimple(JournalLine line) => _supportedKarats.every(
    (k) => k == _mainKarat || !line.isGoldKaratEnabled(k),
  );

  bool _lineTakesGold(JournalLine line) =>
      line.accountTransactionType == 'gold' ||
      line.accountTransactionType == 'both';

  bool _showsGoldDetail(JournalLine line, _LinesLayout layout) {
    if (line.goldDetailOpen) return true;
    if (layout == _LinesLayout.wide) return !_goldIsSimple(line);
    return line.hasGoldValues || _lineTakesGold(line);
  }

  // --- Build ---
  @override
  Widget build(BuildContext context) {
    final readiness = _readiness();
    final isNew = widget.entry == null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _onSavePressed,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true):
              _onSavePressed,
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _addLine,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _addLine,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(isNew ? 'إضافة قيد يومية' : 'تعديل قيد يومية'),
              actions: [
                if (isNew)
                  TextButton.icon(
                    onPressed: _saveForLater,
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).appBarTheme.foregroundColor,
                    ),
                    icon: const Icon(Icons.schedule),
                    label: const Text('إكمال لاحقاً'),
                  ),
                const SizedBox(width: 8),
              ],
            ),
            body: Form(
              key: _formKey,
              autovalidateMode: _showErrors
                  ? AutovalidateMode.always
                  : AutovalidateMode.disabled,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: _buildHeaderFields(),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => Align(
                        alignment: Alignment.topCenter,
                        child: _buildLinesTable(
                          _LinesLayout.of(constraints.maxWidth),
                        ),
                      ),
                    ),
                  ),
                  _buildFooter(readiness),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveForLater() async {
    await _saveLocalDraft(showToast: true);
    if (mounted) Navigator.of(context).pop(_savedAny);
  }

  /// Back, the system gesture, the app bar arrow: leave at once when nothing was
  /// changed, otherwise ask -- the entry is lost with the screen.
  Future<void> _confirmLeave() async {
    if (_isSaving) return;
    if (!_isDirty) {
      Navigator.of(context).pop(_savedAny);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('قيد غير محفوظ'),
        content: const Text('في القيد تعديلات لم تُحفظ. ماذا تريد أن تفعل؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('stay'),
            child: const Text('متابعة التحرير'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('تجاهل التعديلات'),
          ),
          if (widget.entry == null)
            FilledButton(
              onPressed: () => Navigator.of(context).pop('later'),
              child: const Text('إكمال لاحقاً'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'later') {
      await _saveForLater();
    } else if (choice == 'discard') {
      Navigator.of(context).pop(_savedAny);
    }
  }

  // --- Header ---
  InputDecoration _dense(String label, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      suffixIcon: suffixIcon,
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_dateController.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      setState(() {
        _dateController.text = picked.toIso8601String().split('T').first;
      });
    }
  }

  static const _entryTypes = [
    'عادي',
    'افتتاحي',
    'دوري',
    'إقفال',
    'تسوية',
    'تعديل',
  ];

  static const _referenceTypes = <String?, String>{
    null: 'بدون مرجع',
    'فاتورة': 'فاتورة',
    'سند': 'سند',
    'شيك': 'شيك',
    'أمر دفع': 'أمر دفع',
    'أخرى': 'أخرى',
  };

  Widget _buildHeaderFields() {
    final description = TextFormField(
      controller: _descriptionController,
      decoration: _dense('البيان'),
      validator: (value) =>
          (value == null || value.trim().isEmpty) ? 'اكتب بيان القيد' : null,
      onChanged: (_) => setState(() {}),
    );
    final date = TextFormField(
      controller: _dateController,
      readOnly: true,
      textDirection: TextDirection.ltr,
      decoration: _dense(
        'التاريخ',
        suffixIcon: const Icon(Icons.calendar_today, size: 18),
      ),
      onTap: _pickDate,
    );
    final entryType = DropdownButtonFormField<String>(
      key: ValueKey('entry-type-$_formGeneration'),
      initialValue: _entryTypes.contains(_selectedEntryType)
          ? _selectedEntryType
          : 'عادي',
      isDense: true,
      isExpanded: true,
      decoration: _dense('نوع القيد'),
      items: [
        for (final t in _entryTypes) DropdownMenuItem(value: t, child: Text(t)),
      ],
      onChanged: (value) => setState(() => _selectedEntryType = value!),
    );
    // A recurring template's reference is set by the system, never chosen;
    // an entry that already carries it keeps showing it.
    final referenceTypes = {
      ..._referenceTypes,
      if (_referenceType == 'recurring_template')
        'recurring_template': 'قيد دوري',
    };
    final reference = Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String?>(
            key: ValueKey('reference-type-$_formGeneration'),
            initialValue: referenceTypes.containsKey(_referenceType)
                ? _referenceType
                : null,
            isDense: true,
            isExpanded: true,
            decoration: _dense('المرجع'),
            items: [
              for (final e in referenceTypes.entries)
                DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
            ],
            onChanged: (value) => setState(() => _referenceType = value),
          ),
        ),
        if (_referenceType != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              controller: _referenceNumberController,
              decoration: _dense('رقم المرجع'),
            ),
          ),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: description),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: date),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: entryType),
              const SizedBox(width: 8),
              Expanded(flex: _referenceType == null ? 2 : 4, child: reference),
            ],
          );
        }
        if (constraints.maxWidth >= 600) {
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: description),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: date),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: entryType),
                  const SizedBox(width: 8),
                  Expanded(flex: 3, child: reference),
                ],
              ),
            ],
          );
        }
        return Column(
          children: [
            description,
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: date),
                const SizedBox(width: 8),
                Expanded(child: entryType),
              ],
            ),
            const SizedBox(height: 8),
            reference,
          ],
        );
      },
    );
  }

  // --- Lines table ---
  Widget _buildLinesHeader(_LinesLayout layout) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );

    Widget group(String title, Color accent) {
      return SizedBox(
        width: _kAmountWidth * 2 + _kGap,
        child: Column(
          children: [
            Text(
              title,
              style: style?.copyWith(color: accent),
              textAlign: TextAlign.center,
            ),
            Divider(height: 10, color: accent.withValues(alpha: 0.4)),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'مدين',
                    style: style,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: _kGap),
                Expanded(
                  child: Text(
                    'دائن',
                    style: style,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.035),
        border: Border(bottom: BorderSide(color: _hairline(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: _kIndexWidth,
            child: Text('#', style: style),
          ),
          Expanded(child: Text('الحساب', style: style)),
          const SizedBox(width: _kGap),
          group('نقد ($_currencySymbol)', AppColors.info),
          if (layout == _LinesLayout.wide) ...[
            const SizedBox(width: _kGap),
            group('ذهب (غ · عيار $_mainKarat)', AppColors.goldText(context)),
          ],
          const SizedBox(width: _kActionsWidth),
        ],
      ),
    );
  }

  Widget _buildLineRow(int index, _LinesLayout layout) {
    final theme = Theme.of(context);
    final line = _lines[index];
    final cashFaded = line.accountTransactionType == 'gold';
    final goldFaded = line.accountTransactionType == 'cash';

    final indexCell = SizedBox(
      width: _kIndexWidth,
      child: Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Text(
          '${index + 1}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    final account = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_buildAccountField(line), _buildLineHint(line)],
      ),
    );
    final actions = SizedBox(
      width: _kActionsWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'حذف السطر',
            icon: const Icon(Icons.delete_outline, color: AppColors.error),
            onPressed: () => _removeLine(index),
          ),
          _buildLineMenu(line, index),
        ],
      ),
    );

    final Widget body;
    if (layout == _LinesLayout.compact) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [indexCell, account, actions],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: _kIndexWidth),
              Expanded(
                child: _amountField(
                  line.cashDebitController,
                  label: 'مدين',
                  suffix: _currencySymbol,
                  faded: cashFaded,
                ),
              ),
              const SizedBox(width: _kGap),
              Expanded(
                child: _amountField(
                  line.cashCreditController,
                  label: 'دائن',
                  suffix: _currencySymbol,
                  faded: cashFaded,
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          indexCell,
          account,
          const SizedBox(width: _kGap),
          SizedBox(
            width: _kAmountWidth,
            child: _amountField(line.cashDebitController, faded: cashFaded),
          ),
          const SizedBox(width: _kGap),
          SizedBox(
            width: _kAmountWidth,
            child: _amountField(line.cashCreditController, faded: cashFaded),
          ),
          if (layout == _LinesLayout.wide) ...[
            const SizedBox(width: _kGap),
            SizedBox(
              width: _kAmountWidth,
              child: _goldCell(line, debit: true, faded: goldFaded),
            ),
            const SizedBox(width: _kGap),
            SizedBox(
              width: _kAmountWidth,
              child: _goldCell(line, debit: false, faded: goldFaded),
            ),
          ],
          actions,
        ],
      );
    }

    // A line with its karats open is washed gold, detail and all, so the
    // breakdown reads as part of the line; the others alternate faintly.
    final showDetail = _showsGoldDetail(line, layout);
    return Container(
      key: line.rowKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: showDetail
            ? _goldWash(context)
            : index.isOdd
            ? theme.colorScheme.onSurface.withValues(alpha: 0.025)
            : null,
        border: index == 0
            ? null
            : Border(top: BorderSide(color: _hairline(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [body, if (showDetail) _buildGoldDetail(line, layout)],
      ),
    );
  }

  Widget _buildAccountField(JournalLine line) {
    return AccountPickerFormField(
      context: context,
      accounts: _index.sorted,
      value: line.accountId,
      labelText: 'الحساب',
      hintText: 'ابحث برقم الحساب أو اسمه',
      title: 'اختيار حساب',
      isArabic: true,
      enabled: _index.sorted.isNotEmpty,
      showTransactionTypeFilter: true,
      showTracksWeightFilter: false,
      predicate: (acc) {
        final id = _asInt(acc['id']);
        return id != null && !_index.parents.contains(id);
      },
      validator: (value) {
        if (!line.hasValues) return null;
        if (value == null) return 'اختر حساباً لهذا السطر';
        if (_index.parents.contains(value)) {
          return 'حساب رئيسي؛ اختر حساباً فرعياً';
        }
        if (_index.known.isNotEmpty && !_index.known.contains(value)) {
          return 'الحساب غير موجود';
        }
        return null;
      },
      onChanged: (value) => _onAccountChanged(line, value),
    );
  }

  /// The account's balance, said as debit or credit (the server reports
  /// debit minus credit, services/live_balances.py), and the safe-box caveat.
  Widget _buildLineHint(JournalLine line) {
    final account = _accountById(line.accountId);
    if (account == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    String side(num v) => v > 0 ? 'مدين' : 'دائن';
    final parts = <String>[];
    final balances = account['balances'];
    if (balances is Map) {
      final cash = (balances['cash'] as num?)?.toDouble() ?? 0.0;
      final weight = balances['weight'];
      final total = weight is Map ? weight['total'] as num? : null;
      final hasWeight = total != null && total.abs() > 0.0005;
      if (cash.abs() >= 0.005 || !hasWeight) {
        parts.add(
          cash.abs() < 0.005
              ? 'الرصيد 0'
              : 'الرصيد ${ltrIsolate(_formatCashValue(cash.abs(), includeSymbol: false))} ${side(cash)}',
        );
      }
      if (hasWeight) {
        parts.add(
          'ذهب ${ltrIsolate(total.abs().toStringAsFixed(3))} غ ${side(total)}',
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 4, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (parts.isNotEmpty) Text(parts.join(' · '), style: muted),
          if (_safeBoxAccountIds.contains(line.accountId))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'مرتبط بخزينة: القيد اليدوي لا يحدّث حركات الخزينة؛ '
                      'للنقد الفعلي استخدم سند صرف أو قبض',
                      style: muted?.copyWith(color: AppColors.warning),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _amountField(
    TextEditingController controller, {
    String? label,
    String? suffix,
    bool faded = false,
    bool dense = false,
    ValueChanged<String>? onChanged,
  }) {
    final field = TextFormField(
      controller: controller,
      textAlign: TextAlign.left,
      textDirection: TextDirection.ltr,
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
          horizontal: 10,
          vertical: dense ? 10 : 18,
        ),
        suffixText: suffix,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [ArabicNumberTextInputFormatter()],
      onChanged: onChanged ?? (_) => _calculateTotals(),
    );
    // A side the account does not carry is dimmed, not locked: the server
    // routes a paired account's other side to its twin.
    return Opacity(
      opacity: faded && controller.text.isEmpty ? 0.45 : 1,
      child: field,
    );
  }

  Widget _goldCell(
    JournalLine line, {
    required bool debit,
    required bool faded,
  }) {
    if (_goldIsSimple(line) && !line.goldDetailOpen) {
      final controller = debit
          ? line.goldDebitControllers[_mainKarat]!
          : line.goldCreditControllers[_mainKarat]!;
      return _amountField(
        controller,
        faded: faded,
        onChanged: (value) {
          if ((double.tryParse(value) ?? 0.0) != 0.0) {
            line.goldKaratEnabled[_mainKarat] = true;
          }
          _calculateTotals();
        },
      );
    }

    final total = _lineGoldInMain(line, debit: debit);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => line.goldDetailOpen = !line.goldDetailOpen),
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 18,
          ),
          suffixIcon: Icon(
            line.goldDetailOpen ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
        ),
        child: Text(
          total == 0 ? '' : total.toStringAsFixed(4),
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }

  Widget _buildLineMenu(JournalLine line, int index) {
    return PopupMenuButton<String>(
      tooltip: 'خيارات السطر',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'duplicate':
            _duplicateLine(index);
          case 'cash':
            _balanceCashOnLine(line);
          case 'gold':
            _balanceGoldOnLine(line);
          case 'detail':
            setState(() => line.goldDetailOpen = !line.goldDetailOpen);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'duplicate', child: Text('تكرار السطر')),
        const PopupMenuItem(value: 'cash', child: Text('وازن النقد بالباقي')),
        const PopupMenuItem(value: 'gold', child: Text('وازن الذهب بالباقي')),
        PopupMenuItem(
          value: 'detail',
          child: Text(
            line.goldDetailOpen ? 'إخفاء تفصيل العيارات' : 'تفصيل العيارات',
          ),
        ),
      ],
    );
  }

  Widget _karatBadge(int karat) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = AppColors.karatColorFor(karat);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$karat',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: isDark ? color : AppColors.karatBadgeTextColorFor(karat),
        ),
      ),
    );
  }

  /// The karats of one line, inside the line. On a wide table each karat's
  /// weights sit under the gold columns they add up to; narrower, they form a
  /// small grid of their own.
  Widget _buildGoldDetail(JournalLine line, _LinesLayout layout) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
    );
    final active = _supportedKarats.where(line.isGoldKaratEnabled).toList();
    final inactive = _supportedKarats
        .where((k) => !active.contains(k))
        .toList();

    String equivalent(int k) {
      final d = double.tryParse(line.goldDebitControllers[k]!.text) ?? 0.0;
      final c = double.tryParse(line.goldCreditControllers[k]!.text) ?? 0.0;
      final v = _convertToMainKarat(d != 0 ? d : c, k);
      return v == 0 ? '' : v.toStringAsFixed(4);
    }

    Widget removeKarat(int k) => IconButton(
      tooltip: 'إزالة العيار',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close),
      onPressed: () {
        setState(() => line.setGoldKaratEnabled(k, false));
        _calculateTotals();
      },
    );

    final tools = Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (inactive.isNotEmpty) Text('إضافة عيار:', style: labelStyle),
        for (final k in inactive)
          ActionChip(
            label: Text('+ $k'),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(
              color: AppColors.primaryGold.withValues(alpha: 0.5),
            ),
            onPressed: () => setState(() => line.setGoldKaratEnabled(k, true)),
          ),
        TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => _balanceGoldOnLine(line),
          icon: const Icon(Icons.balance, size: 18),
          label: const Text('وازن بالباقي'),
        ),
      ],
    );

    if (layout == _LinesLayout.wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final k in active)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const SizedBox(width: _kIndexWidth),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(width: 44, child: _karatBadge(k)),
                        const SizedBox(width: 10),
                        if (equivalent(k).isNotEmpty)
                          Text(
                            '= ${ltrIsolate(equivalent(k))} غ بعيار $_mainKarat',
                            style: muted,
                          ),
                      ],
                    ),
                  ),
                  // under the cash columns
                  const SizedBox(width: _kGap * 2 + _kAmountWidth * 2),
                  const SizedBox(width: _kGap),
                  SizedBox(
                    width: _kAmountWidth,
                    child: _amountField(
                      line.goldDebitControllers[k]!,
                      dense: true,
                    ),
                  ),
                  const SizedBox(width: _kGap),
                  SizedBox(
                    width: _kAmountWidth,
                    child: _amountField(
                      line.goldCreditControllers[k]!,
                      dense: true,
                    ),
                  ),
                  SizedBox(
                    width: _kActionsWidth,
                    child: Center(child: removeKarat(k)),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: _kIndexWidth,
              top: 4,
            ),
            child: tools,
          ),
        ],
      );
    }

    final indent = layout == _LinesLayout.compact ? 0.0 : _kIndexWidth;
    Widget gridRow(List<Widget> cells) => Padding(
      padding: EdgeInsetsDirectional.only(start: indent, top: 6),
      child: Row(children: cells),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (active.isNotEmpty)
          gridRow([
            SizedBox(width: 44, child: Text('العيار', style: labelStyle)),
            const SizedBox(width: _kGap),
            Expanded(
              child: Text(
                'مدين',
                style: labelStyle,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: _kGap),
            Expanded(
              child: Text(
                'دائن',
                style: labelStyle,
                textAlign: TextAlign.center,
              ),
            ),
            SizedBox(
              width: 84,
              child: Text(
                '= عيار $_mainKarat',
                style: labelStyle,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 40),
          ]),
        for (final k in active)
          gridRow([
            SizedBox(width: 44, child: _karatBadge(k)),
            const SizedBox(width: _kGap),
            Expanded(
              child: _amountField(line.goldDebitControllers[k]!, dense: true),
            ),
            const SizedBox(width: _kGap),
            Expanded(
              child: _amountField(line.goldCreditControllers[k]!, dense: true),
            ),
            SizedBox(
              width: 84,
              child: Text(
                equivalent(k),
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                style: muted?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            SizedBox(width: 40, child: removeKarat(k)),
          ]),
        Padding(
          padding: EdgeInsetsDirectional.only(start: indent, top: 4),
          child: tools,
        ),
      ],
    );
  }

  /// The lines as one panel: column titles pinned on top, the lines scrolling
  /// under them, «add line» as the panel's last row. It is as tall as its
  /// lines, up to the room it has.
  Widget _buildLinesTable(_LinesLayout layout) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _hairline(context)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (layout != _LinesLayout.compact) _buildLinesHeader(layout),
          Flexible(
            child: SingleChildScrollView(
              controller: _linesScrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _lines.length; i++)
                    _buildLineRow(i, layout),
                  InkWell(
                    onTap: _addLine,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: _hairline(context)),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add,
                            size: 18,
                            color: AppColors.goldText(context),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'إضافة سطر',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.goldText(context),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The app's divider colour (grey 300 / grey 800, LightTheme/DarkTheme).
  /// Not ThemeData.dividerColor: the app's colour schemes set no
  /// outlineVariant, so that falls back to near-black.
  Color _hairline(BuildContext context) {
    final theme = Theme.of(context);
    return theme.dividerTheme.color ?? theme.colorScheme.outlineVariant;
  }

  Color _goldWash(BuildContext context) => AppColors.primaryGold.withValues(
    alpha: Theme.of(context).brightness == Brightness.dark ? 0.10 : 0.07,
  );

  // --- Footer ---
  Widget _buildFooter(JournalReadiness readiness) {
    final theme = Theme.of(context);
    final showGold =
        _totalGoldDebit > 0 ||
        _totalGoldCredit > 0 ||
        _lines.any(_lineTakesGold);

    final status = _buildStatus(readiness);
    final totals = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        JournalBalanceRow(
          label: 'نقد',
          debit: _totalCashDebit,
          credit: _totalCashCredit,
          format: (v) => _formatCashValue(v, includeSymbol: false),
          suffix: _currencySymbol,
        ),
        if (showGold)
          JournalBalanceRow(
            label: 'ذهب',
            debit: _totalGoldDebit,
            credit: _totalGoldCredit,
            format: (v) => v.toStringAsFixed(4),
            suffix: 'غ',
          ),
      ],
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.entry == null) ...[
          OutlinedButton(
            onPressed: _isSaving ? null : () => _onSavePressed(andNew: true),
            child: const Text('حفظ وجديد'),
          ),
          const SizedBox(width: 8),
        ],
        _buildSaveButton(readiness),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: _hairline(context))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    status,
                    const SizedBox(height: 6),
                    totals,
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: buttons,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [status, const SizedBox(height: 6), totals],
                    ),
                  ),
                  const SizedBox(width: 16),
                  buttons,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The one state the accountant reads: green only when the server would
  /// accept the entry as it stands.
  Widget _buildStatus(JournalReadiness readiness) {
    final theme = Theme.of(context);
    final (IconData icon, Color color, String text) = switch (readiness.kind) {
      JournalReadinessKind.ready => (
        Icons.check_circle,
        AppColors.success,
        readiness.goldWillBeSettled
            ? 'جاهز للحفظ · فرق ذهب طفيف (أقل من 0.01 غ) تسوّيه المنظومة'
            : 'جاهز للحفظ',
      ),
      JournalReadinessKind.notReady => (
        Icons.error_outline,
        AppColors.error,
        'غير جاهز للحفظ — ${readiness.message}',
      ),
      JournalReadinessKind.empty => (
        Icons.edit_note,
        theme.colorScheme.onSurfaceVariant,
        readiness.message,
      ),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(JournalReadiness readiness) {
    if (_isSaving) {
      return const ElevatedButton(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('جارٍ الحفظ…'),
          ],
        ),
      );
    }
    if (readiness.isReady) {
      return ElevatedButton.icon(
        onPressed: _onSavePressed,
        icon: const Icon(Icons.check),
        label: const Text('حفظ القيد'),
      );
    }
    // Grey, not disabled: a press shows the reason on the line that blocks.
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: readiness.message,
      child: ElevatedButton.icon(
        onPressed: _onSavePressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: onSurface.withValues(alpha: 0.10),
          foregroundColor: onSurface.withValues(alpha: 0.60),
          elevation: 0,
        ),
        icon: const Icon(Icons.block, size: 18),
        label: const Text('حفظ القيد'),
      ),
    );
  }
}

/// How the lines table lays itself out for the width it has.
enum _LinesLayout {
  /// Phone: the account on its own row, the cash amounts under it.
  compact,

  /// Tablet portrait: cash columns; gold in the breakdown under the line.
  medium,

  /// Computer and tablet landscape: cash and gold columns side by side.
  wide;

  static _LinesLayout of(double width) {
    if (width >= 980) return wide;
    if (width >= 640) return medium;
    return compact;
  }
}

const double _kIndexWidth = 28;
const double _kAmountWidth = 128;
const double _kActionsWidth = 96;
const double _kGap = 8;

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}');
}

/// The chart of accounts as the lines need it: sorted by number, and which ids
/// exist and which are parents (never posted to).
class _AccountIndex {
  final List<Map<String, dynamic>> sorted;
  final Set<int> parents;
  final Set<int> known;

  const _AccountIndex(this.sorted, this.parents, this.known);

  factory _AccountIndex.of(List<dynamic> accounts) {
    final sorted =
        accounts
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
          ..sort((a, b) {
            final an = int.tryParse('${a['account_number'] ?? 0}') ?? 0;
            final bn = int.tryParse('${b['account_number'] ?? 0}') ?? 0;
            return an.compareTo(bn);
          });
    return _AccountIndex(
      sorted,
      sorted.map((a) => _asInt(a['parent_id'])).whereType<int>().toSet(),
      sorted.map((a) => _asInt(a['id'])).whereType<int>().toSet(),
    );
  }
}
