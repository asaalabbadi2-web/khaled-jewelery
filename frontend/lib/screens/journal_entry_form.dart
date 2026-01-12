import 'package:flutter/material.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../utils/arabic_number_formatter.dart';

// --- Data Models ---
class JournalLine {
  int? accountId;
  String? accountTransactionType; // 'cash', 'gold', or 'both'
  final TextEditingController cashDebitController;
  final TextEditingController cashCreditController;
  final Map<int, TextEditingController> goldDebitControllers = {};
  final Map<int, TextEditingController> goldCreditControllers = {};
  final Map<int, bool> goldKaratEnabled = {};

  JournalLine({
    this.accountId,
    this.accountTransactionType,
    String cashDebit = '0.0',
    String cashCredit = '0.0',
    Map<int, String>? goldDebits,
    Map<int, String>? goldCredits,
    Set<int>? defaultGoldKarats,
    required List<int> karats,
  }) : cashDebitController = TextEditingController(text: cashDebit),
       cashCreditController = TextEditingController(text: cashCredit) {
    for (var karat in karats) {
      final debitText = goldDebits?[karat] ?? '0.0';
      final creditText = goldCredits?[karat] ?? '0.0';

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

  factory JournalLine.fromMap(Map<String, dynamic> map, List<int> karats) {
    Map<int, String> goldDebits = {};
    Map<int, String> goldCredits = {};
    for (var karat in karats) {
      goldDebits[karat] = (map['debit_${karat}k'] ?? 0.0).toString();
      goldCredits[karat] = (map['credit_${karat}k'] ?? 0.0).toString();
    }

    return JournalLine(
      accountId: map['account_id'],
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
    cashDebitController.text = '0.0';
    cashCreditController.text = '0.0';
  }

  void clearGoldFields({bool disable = false}) {
    for (var c in goldDebitControllers.values) {
      c.text = '0.0';
    }
    for (var c in goldCreditControllers.values) {
      c.text = '0.0';
    }

    if (disable) {
      goldKaratEnabled.updateAll((key, value) => false);
    }
  }

  void setGoldKaratEnabled(int karat, bool enabled) {
    goldKaratEnabled[karat] = enabled;
    if (!enabled) {
      goldDebitControllers[karat]?.text = '0.0';
      goldCreditControllers[karat]?.text = '0.0';
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

  const AddEditJournalEntryScreen({
    super.key,
    this.entry,
    this.isEditMode = false,
  });

  @override
  State<AddEditJournalEntryScreen> createState() =>
      _AddEditJournalEntryScreenState();
}

class _AddEditJournalEntryScreenState extends State<AddEditJournalEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();
  late TextEditingController _descriptionController;
  late TextEditingController _dateController;
  late TextEditingController _referenceNumberController;
  late ScrollController _linesScrollController;

  List<JournalLine> _lines = [];
  List<dynamic> _accounts = [];
  final List<int> _supportedKarats = [18, 21, 22, 24];
  int _mainKarat = 21;
  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;
  bool _settingsSynced = false;
  String _selectedEntryType = 'عادي'; // نوع القيد
  String? _referenceType; // نوع المرجع

  double _totalCashDebit = 0.0;
  double _totalCashCredit = 0.0;
  double _totalGoldDebit = 0.0;
  double _totalGoldCredit = 0.0;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
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
        _currencySymbol = newSymbol;
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
  }

  Future<void> _fetchAccounts() async {
    try {
      final accounts = await _apiService.getAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          // After fetching accounts, update transaction types for existing lines
          for (var line in _lines) {
            if (line.accountId != null) {
              try {
                final account = _accounts.firstWhere(
                  (acc) => acc['id'] == line.accountId,
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

    setState(() {
      _totalCashDebit = cashDebit;
      _totalCashCredit = cashCredit;
      _totalGoldDebit = goldDebit;
      _totalGoldCredit = goldCredit;
    });
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
    setState(() {
      _lines[index].dispose();
      _lines.removeAt(index);
      _calculateTotals();
    });
  }

  void _onAccountChanged(JournalLine line, int? accountId) {
    setState(() {
      line.accountId = accountId;
      if (accountId == null) {
        line.accountTransactionType = null;
        line.clearGoldFields(disable: true);
      } else {
        final account = _accounts.firstWhere((acc) => acc['id'] == accountId);
        line.accountTransactionType = account['transaction_type'];

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
      _calculateTotals();
    });
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

    setState(() {
      targetController.text = finalWeight.toStringAsFixed(4);
      _calculateTotals();
    });
  }

  // --- Save Logic ---
  Future<void> _saveJournalEntry() async {
    // First, validate the form fields themselves
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Then, perform custom validation on the lines
    if (!_validateLines()) return;

    // Finally, check for balance and ask for confirmation if needed
    if (!await _checkBalances()) return;

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
        Navigator.of(context).pop(true); // Return true to indicate success
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل حفظ القيد: ${e.toString()}')),
        );
      }
    }
  }

  bool _validateLines() {
    // Identify all parent accounts
    final parentIds = _accounts.map((acc) => acc['parent_id']).toSet();

    for (var line in _lines) {
      // Skip empty lines
      if (!line.hasValues) continue;

      // Check if an account is selected
      if (line.accountId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('يجب تحديد حساب لجميع الأسطر التي تحتوي على قيم.'),
          ),
        );
        return false;
      }

      // Check if the selected account is a parent account
      if (parentIds.contains(line.accountId)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'لا يمكن إجراء معاملة على حساب رئيسي. الرجاء اختيار حساب فرعي.',
            ),
          ),
        );
        return false;
      }
    }
    return true;
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

    if ((_totalGoldDebit - _totalGoldCredit).abs() > tolerance) {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('قيد الذهب غير متوازن'),
          content: Text(
            'الفرق هو ${(_totalGoldDebit - _totalGoldCredit).toStringAsFixed(4)} غرام. هل تود المتابعة والسماح للخادم بموازنة الفرق تلقائياً؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('العودة والمراجعة'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('نعم، متابعة'),
            ),
          ],
        ),
      );
      return proceed ?? false;
    }
    return true;
  }

  // --- Build Method ---
  @override
  Widget build(BuildContext context) {
    final parentIds = _accounts.map((acc) => acc['parent_id']).toSet();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry == null ? 'إضافة قيد يومية' : 'تعديل قيد يومية',
        ),
        actions: [
          IconButton(icon: Icon(Icons.save), onPressed: _saveJournalEntry),
        ],
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _buildHeaderFields(),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'الأسطر',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _buildLinesList(parentIds), // This is Expanded
            _buildProfessionalSummary(),
          ],
        ),
      ),
    );
  }

  // --- UI Helper Widgets ---
  Widget _buildHeaderFields() {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: 'الوصف',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'الرجاء إدخال الوصف';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _dateController,
                decoration: InputDecoration(
                  labelText: 'التاريخ',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                readOnly: true,
                onTap: () async {
                  DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate:
                        DateTime.tryParse(_dateController.text) ??
                        DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2101),
                  );
                  if (picked != null) {
                    _dateController.text = picked
                        .toIso8601String()
                        .split('T')
                        .first;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                initialValue: _selectedEntryType,
                decoration: InputDecoration(
                  labelText: 'نوع القيد',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 'عادي', child: Text('عادي')),
                  DropdownMenuItem(value: 'افتتاحي', child: Text('افتتاحي')),
                  DropdownMenuItem(value: 'دوري', child: Text('دوري')),
                  DropdownMenuItem(value: 'إقفال', child: Text('إقفال')),
                  DropdownMenuItem(value: 'تسوية', child: Text('تسوية')),
                  DropdownMenuItem(value: 'تعديل', child: Text('تعديل')),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedEntryType = value!;
                  });
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String?>(
                initialValue: _referenceType,
                decoration: InputDecoration(
                  labelText: 'نوع المرجع',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('بدون مرجع'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'فاتورة',
                    child: Text('فاتورة'),
                  ),
                  DropdownMenuItem<String?>(value: 'سند', child: Text('سند')),
                  DropdownMenuItem<String?>(value: 'شيك', child: Text('شيك')),
                  DropdownMenuItem<String?>(
                    value: 'أمر دفع',
                    child: Text('أمر دفع'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'recurring_template',
                    child: Text('قيد دوري'),
                  ),
                  DropdownMenuItem<String?>(value: 'أخرى', child: Text('أخرى')),
                ],
                onChanged: (value) {
                  setState(() {
                    _referenceType = value;
                  });
                },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _referenceNumberController,
                decoration: InputDecoration(
                  labelText: 'رقم المرجع',
                  hintText: 'اختياري',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLinesList(Set<dynamic> parentIds) {
    final selectableAccounts = _accounts
        .where((acc) => !parentIds.contains(acc['id']))
        .toList();

    final sortedAccounts = List<dynamic>.from(selectableAccounts)
      ..sort((a, b) {
        final aNum = int.tryParse(a['account_number']?.toString() ?? '0') ?? 0;
        final bNum = int.tryParse(b['account_number']?.toString() ?? '0') ?? 0;
        return aNum.compareTo(bNum);
      });

    return Expanded(
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _linesScrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              itemCount: _lines.length + 1,
              itemBuilder: (context, index) {
                // If this is the last item, render the Add Line button as part of the list
                if (index == _lines.length) {
                  // Render the Add Line button as the final list item.
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ElevatedButton.icon(
                          onPressed: _addLine,
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة سطر'),
                        ),
                      ),
                    ),
                  );
                }

                final line = _lines[index];
                final isSelectedAccountValid = sortedAccounts.any(
                  (acc) => acc['id'] == line.accountId,
                );

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: isSelectedAccountValid
                                    ? line.accountId
                                    : null,
                                isExpanded: true,
                                hint: const Text('اختر حساب فرعي'),
                                items: sortedAccounts
                                    .map<DropdownMenuItem<int>>((account) {
                                      final accountNumber =
                                          account['account_number']
                                              ?.toString() ??
                                          '';
                                      final accountName =
                                          account['name']?.toString() ?? '';
                                      return DropdownMenuItem<int>(
                                        value: account['id'],
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '$accountNumber - $accountName',
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              _transactionTypeLabel(
                                                account['transaction_type'],
                                              ),
                                              style: TextStyle(
                                                color: Colors.grey.shade600,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    })
                                    .toList(),
                                onChanged: (value) =>
                                    _onAccountChanged(line, value),
                                decoration: InputDecoration(
                                  labelText: 'الحساب',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                    horizontal: 12,
                                  ),
                                  helperText: sortedAccounts.isEmpty
                                      ? null
                                      : 'يمكنك كتابة رقم الحساب أو استخدام زر البحث المتقدم',
                                  helperStyle: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                                validator: (value) {
                                  if (line.hasValues && value == null) {
                                    return 'حساب غير صالح أو رئيسي';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(
                                Icons.manage_search,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              tooltip: 'بحث متقدم عن الحساب',
                              onPressed: sortedAccounts.isEmpty
                                  ? null
                                  : () => _showAccountSelectionDialog(
                                      sortedAccounts,
                                      line,
                                    ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.delete,
                                color: Colors.red.shade400,
                              ),
                              onPressed: () => _removeLine(index),
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildCashInputFields(line),
                        _buildGoldInputFields(line),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCashInputFields(JournalLine line) {
    // ✅ تم إلغاء منطق الإخفاء بناءً على نوع الحساب
    // جميع الحسابات (نقدية وذهبية) يمكنها استخدام حقول النقد

    // في وضع التعديل، اعرض جميع الصفوف دائماً
    if (!widget.isEditMode) {
      // أخفِ الحقول قبل اختيار الحساب للمحافظة على بساطة الواجهة
      final debitValue = double.tryParse(line.cashDebitController.text) ?? 0.0;
      final creditValue =
          double.tryParse(line.cashCreditController.text) ?? 0.0;

      if (line.accountId == null && debitValue == 0.0 && creditValue == 0.0) {
        return const SizedBox.shrink();
      }
    }

    final debitValue = double.tryParse(line.cashDebitController.text) ?? 0.0;
    final creditValue = double.tryParse(line.cashCreditController.text) ?? 0.0;

    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: line.cashDebitController,
            style: debitValue > 0.0
                ? const TextStyle(
                    color: Colors.blue,
                    fontWeight: FontWeight.bold,
                  )
                : null,
            decoration: InputDecoration(
              labelText: 'مدين (مبلغ)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: 12,
              ),
              suffixText: _currencySymbol,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [ArabicNumberTextInputFormatter()],
            onChanged: (_) => _calculateTotals(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextFormField(
            controller: line.cashCreditController,
            style: creditValue > 0.0
                ? const TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  )
                : null,
            decoration: InputDecoration(
              labelText: 'دائن (مبلغ)',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                vertical: 10,
                horizontal: 12,
              ),
              suffixText: _currencySymbol,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [ArabicNumberTextInputFormatter()],
            onChanged: (_) => _calculateTotals(),
          ),
        ),
      ],
    );
  }

  Widget _buildGoldInputFields(JournalLine line) {
    // ✅ تم إلغاء منطق الإخفاء بناءً على نوع الحساب
    // جميع الحسابات (نقدية وذهبية) يمكنها استخدام حقول الذهب
    final hasAnyGoldValue = line.hasGoldValues;

    final shouldDelayDisplay =
        !widget.isEditMode && line.accountId == null && !hasAnyGoldValue;
    if (shouldDelayDisplay) {
      return const SizedBox.shrink();
    }

    final karatRows = <Widget>[];

    // Render a row per karat. Toggles are shown horizontally at the top-left
    // of the gold section; each enabled karat renders a full debit+credit row.
    for (final karat in _supportedKarats) {
      if (!line.isGoldKaratEnabled(karat)) continue;

      final debitValue =
          double.tryParse(line.goldDebitControllers[karat]!.text) ?? 0.0;
      final creditValue =
          double.tryParse(line.goldCreditControllers[karat]!.text) ?? 0.0;

      karatRows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Row(
            children: [
              Expanded(
                child: _buildGoldAmountField(
                  controller: line.goldDebitControllers[karat]!,
                  karat: karat,
                  isDebit: true,
                  highlight: debitValue > 0.0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildGoldAmountField(
                  controller: line.goldCreditControllers[karat]!,
                  karat: karat,
                  isDebit: false,
                  highlight: creditValue > 0.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: Text(
            'تفاصيل الذهب:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: _buildGoldToggleRow(line),
        ),
        if (karatRows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'قم بتفعيل العيارات المطلوبة لإدخال الأوزان.',
              style: hintStyle,
            ),
          )
        else
          ...karatRows,
      ],
    );
  }

  Widget _buildGoldToggleRow(JournalLine line) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: _supportedKarats.map((karat) {
          final isSelected = line.isGoldKaratEnabled(karat);
          return GestureDetector(
            onTap: () {
              setState(() {
                line.setGoldKaratEnabled(karat, !isSelected);
              });
              _calculateTotals();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  width: 1,
                ),
              ),
              child: Text(
                '${karat}k',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGoldAmountField({
    required TextEditingController controller,
    required int karat,
    required bool isDebit,
    required bool highlight,
  }) {
    final label = isDebit ? 'مدين ($karat"k)' : 'دائن ($karat"k)';
    final highlightColor = isDebit ? Colors.blue : Colors.orange;

    return TextFormField(
      controller: controller,
      style: highlight
          ? TextStyle(color: highlightColor, fontWeight: FontWeight.bold)
          : null,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 10,
          horizontal: 12,
        ),
        suffixIcon: IconButton(
          icon: const Icon(Icons.calculate_outlined, size: 20),
          tooltip: 'حساب الوزن لموازنة القيد',
          onPressed: () => _balanceGold(controller, karat, isDebit),
        ),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [ArabicNumberTextInputFormatter()],
      onChanged: (_) => _calculateTotals(),
    );
  }

  Widget _buildProfessionalSummary() {
    if (_totalCashDebit == 0 &&
        _totalCashCredit == 0 &&
        _totalGoldDebit == 0 &&
        _totalGoldCredit == 0) {
      return SizedBox.shrink();
    }

    const tolerance = 0.001;
    bool isCashBalanced =
        (_totalCashDebit - _totalCashCredit).abs() < tolerance;
    bool isGoldBalanced =
        (_totalGoldDebit - _totalGoldCredit).abs() < tolerance;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 16.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFFFFAF0), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1),
      ),
      child: Column(
        children: [
          // Header compact
          Row(
            children: [
              Icon(Icons.assessment, color: Color(0xFFFFD700), size: 18),
              SizedBox(width: 8),
              Text(
                'ملخص القيد',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
              ),
              Spacer(),
              if (isCashBalanced && isGoldBalanced)
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 12),
                      SizedBox(width: 3),
                      Text(
                        'متوازن',
                        style: TextStyle(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning, color: Colors.red, size: 12),
                      SizedBox(width: 3),
                      Text(
                        'غير متوازن',
                        style: TextStyle(
                          color: Colors.red.shade800,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          SizedBox(height: 10),
          // النقد
          _buildCompactSummaryRow(
            icon: Icons.account_balance_wallet,
            iconColor: Colors.blue.shade600,
            label: 'نقد',
            debit: _formatCashValue(_totalCashDebit, includeSymbol: false),
            credit: _formatCashValue(_totalCashCredit, includeSymbol: false),
            suffix: _currencySymbol,
            isBalanced: isCashBalanced,
          ),
          if (_totalGoldDebit > 0 || _totalGoldCredit > 0) ...[
            SizedBox(height: 6),
            _buildCompactSummaryRow(
              icon: Icons.workspace_premium,
              iconColor: Color(0xFFFFD700),
              label: 'ذهب $_mainKarat',
              debit: _totalGoldDebit.toStringAsFixed(3),
              credit: _totalGoldCredit.toStringAsFixed(3),
              suffix: 'غ',
              isBalanced: isGoldBalanced,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactSummaryRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String debit,
    required String credit,
    required String suffix,
    required bool isBalanced,
  }) {
    final difference =
        (double.tryParse(debit) ?? 0) - (double.tryParse(credit) ?? 0);
    final diffText = difference.abs().toStringAsFixed(suffix == 'غ' ? 3 : 2);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 16),
          SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCompactValue('مدين', debit, suffix, Colors.blue.shade700),
                Container(width: 1, height: 20, color: Colors.grey.shade300),
                _buildCompactValue(
                  'دائن',
                  credit,
                  suffix,
                  Colors.orange.shade700,
                ),
                Container(width: 1, height: 20, color: Colors.grey.shade300),
                _buildCompactValue(
                  'فرق',
                  diffText,
                  suffix,
                  isBalanced ? Colors.green.shade700 : Colors.red.shade700,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactValue(
    String label,
    String value,
    String suffix,
    Color color,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
        SizedBox(height: 2),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            children: [
              TextSpan(text: value),
              TextSpan(text: ' $suffix', style: TextStyle(fontSize: 9)),
            ],
          ),
        ),
      ],
    );
  }

  String _transactionTypeLabel(dynamic transactionType) {
    switch (transactionType) {
      case 'cash':
        return 'نقدي';
      case 'gold':
        return 'ذهبي';
      case 'both':
      default:
        return 'مختلط';
    }
  }

  void _showAccountSelectionDialog(List<dynamic> accounts, JournalLine line) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final mediaQuery = MediaQuery.of(dialogContext);
        List<dynamic> filtered = List<dynamic>.from(accounts);

        return StatefulBuilder(
          builder: (context, setState) {
            void filterAccounts(String query) {
              final normalized = query.trim().toLowerCase();
              if (normalized.isEmpty) {
                setState(() => filtered = List<dynamic>.from(accounts));
              } else {
                setState(() {
                  filtered = accounts.where((account) {
                    final accountNumber =
                        account['account_number']?.toString().toLowerCase() ??
                        '';
                    final accountName =
                        account['name']?.toString().toLowerCase() ?? '';
                    return accountNumber.contains(normalized) ||
                        accountName.contains(normalized);
                  }).toList();
                });
              }
            }

            return AlertDialog(
              title: const Text('البحث عن حساب'),
              content: SizedBox(
                width: mediaQuery.size.width * 0.85,
                height: mediaQuery.size.height * 0.6,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'ادخل رقم الحساب أو اسمه',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: filterAccounts,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text(
                                'لا توجد حسابات مطابقة للبحث',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final account = filtered[index];
                                final accountNumber =
                                    account['account_number']?.toString() ?? '';
                                final accountName =
                                    account['name']?.toString() ?? '';
                                final badgeColor = Theme.of(
                                  dialogContext,
                                ).colorScheme.secondary.withValues(alpha: 0.15);
                                final badgeText = accountNumber.length > 2
                                    ? accountNumber.substring(
                                        accountNumber.length - 2,
                                      )
                                    : accountNumber;

                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: badgeColor,
                                    child: Text(
                                      badgeText,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  title: Text('$accountNumber - $accountName'),
                                  subtitle: Text(
                                    _transactionTypeLabel(
                                      account['transaction_type'],
                                    ),
                                  ),
                                  onTap: () {
                                    _onAccountChanged(line, account['id']);
                                    Navigator.of(dialogContext).pop();
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('إغلاق'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
