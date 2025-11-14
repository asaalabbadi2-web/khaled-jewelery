import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';

/// شاشة دفتر الأستاذ المطورة - النسخة 2
/// تدعم: التصفية، الأرصدة التراكمية، تفاصيل الأعيرة
class GeneralLedgerScreenV2 extends StatefulWidget {
  const GeneralLedgerScreenV2({Key? key}) : super(key: key);

  @override
  State<GeneralLedgerScreenV2> createState() => _GeneralLedgerScreenV2State();
}

class _GeneralLedgerScreenV2State extends State<GeneralLedgerScreenV2> {
  final ApiService _apiService = ApiService();

  // Filters
  int? _selectedAccountId;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _showBalances = true;
  bool _karatDetail = false;

  // Data
  Map<String, dynamic>? _ledgerData;
  List<Map<String, dynamic>> _accounts = [];
  bool _isLoading = false;
  String? _errorMessage;
  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;
  int _mainKarat = 21;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _loadLedger();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
    final newDecimals = settings.decimalPlaces;
    final newMainKarat = settings.mainKarat;

    if (newSymbol != _currencySymbol ||
        newDecimals != _currencyDecimalPlaces ||
        newMainKarat != _mainKarat) {
      setState(() {
        _currencySymbol = newSymbol;
        _currencyDecimalPlaces = newDecimals;
        _mainKarat = newMainKarat;
      });
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await _apiService.getAccounts();
      setState(() {
        _accounts = List<Map<String, dynamic>>.from(accounts);
      });
    } catch (e) {
      debugPrint('خطأ في تحميل الحسابات: $e');
    }
  }

  Future<void> _loadLedger() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _apiService.getGeneralLedgerAll(
        accountId: _selectedAccountId,
        startDate: _startDate?.toIso8601String().split('T')[0],
        endDate: _endDate?.toIso8601String().split('T')[0],
        showBalances: _showBalances,
        karatDetail: _karatDetail,
      );

      setState(() {
        _ledgerData = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'فشل تحميل دفتر الأستاذ: $e';
        _isLoading = false;
      });
    }
  }

  void _showFilterDialog() {
    // متغيرات مؤقتة لحفظ التغييرات
    int? tempAccountId = _selectedAccountId;
    DateTime? tempStartDate = _startDate;
    DateTime? tempEndDate = _endDate;
    bool tempShowBalances = _showBalances;
    bool tempKaratDetail = _karatDetail;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تصفية دفتر الأستاذ'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Account Filter
                const Text(
                  'الحساب:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                DropdownButton<int?>(
                  isExpanded: true,
                  value: tempAccountId,
                  hint: const Text('جميع الحسابات'),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('جميع الحسابات'),
                    ),
                    ..._accounts.map(
                      (acc) => DropdownMenuItem<int?>(
                        value: acc['id'],
                        child: Text(
                          '${acc['account_number']} - ${acc['name']}',
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setDialogState(() {
                      tempAccountId = value;
                    });
                  },
                ),
                const SizedBox(height: 16),

                // Date Range
                const Text(
                  'الفترة الزمنية:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          tempStartDate != null
                              ? DateFormat('yyyy-MM-dd').format(tempStartDate!)
                              : 'من تاريخ',
                        ),
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: tempStartDate ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (date != null) {
                            setDialogState(() {
                              tempStartDate = date;
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          tempEndDate != null
                              ? DateFormat('yyyy-MM-dd').format(tempEndDate!)
                              : 'إلى تاريخ',
                        ),
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: tempEndDate ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (date != null) {
                            setDialogState(() {
                              tempEndDate = date;
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (tempStartDate != null || tempEndDate != null)
                  TextButton(
                    onPressed: () {
                      setDialogState(() {
                        tempStartDate = null;
                        tempEndDate = null;
                      });
                    },
                    child: const Text('مسح التواريخ'),
                  ),
                const SizedBox(height: 16),

                // Options
                SwitchListTile(
                  title: const Text('عرض الأرصدة التراكمية'),
                  value: tempShowBalances,
                  onChanged: (value) {
                    setDialogState(() {
                      tempShowBalances = value;
                    });
                  },
                ),
                SwitchListTile(
                  title: const Text('عرض تفاصيل الأعيرة'),
                  subtitle: const Text('18k, 21k, 22k, 24k'),
                  value: tempKaratDetail,
                  onChanged: (value) {
                    setDialogState(() {
                      tempKaratDetail = value;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _selectedAccountId = tempAccountId;
                  _startDate = tempStartDate;
                  _endDate = tempEndDate;
                  _showBalances = tempShowBalances;
                  _karatDetail = tempKaratDetail;
                });
                Navigator.pop(context);
                _loadLedger();
              },
              child: const Text('تطبيق'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('دفتر الأستاذ العام'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
            tooltip: 'تصفية',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLedger,
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadLedger,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    if (_ledgerData == null || _ledgerData!['entries'] == null) {
      return const Center(child: Text('لا توجد بيانات'));
    }

    final entries = List<Map<String, dynamic>>.from(_ledgerData!['entries']);
    final summary = _ledgerData!['summary'];
    final filters = _ledgerData!['filters'];

    return Column(
      children: [
        // Filter Summary
        if (filters != null) _buildFilterSummary(filters),

        // Summary Card
        if (summary != null) _buildSummaryCard(summary),

        // Entries List
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('لا توجد حركات'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    return _buildEntryCard(entries[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterSummary(Map<String, dynamic> filters) {
    final parts = <String>[];

    if (filters['account_id'] != null) {
      final account = _accounts.firstWhere(
        (a) => a['id'] == filters['account_id'],
        orElse: () => {'name': 'حساب #${filters["account_id"]}'},
      );
      parts.add('الحساب: ${account['name']}');
    }

    if (filters['start_date'] != null) {
      parts.add('من: ${filters['start_date']}');
    }

    if (filters['end_date'] != null) {
      parts.add('إلى: ${filters['end_date']}');
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade700,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.filter_list, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parts.join(' | '),
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Colors.white),
            onPressed: () {
              setState(() {
                _selectedAccountId = null;
                _startDate = null;
                _endDate = null;
              });
              _loadLedger();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(Map<String, dynamic> summary) {
    final finalBalance = summary['final_balance'];

    return Card(
      margin: const EdgeInsets.all(8),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.green.shade700, width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Colors.green.shade50],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.shade700,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'الملخص',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey.shade400),
                    ),
                    child: Text(
                      'عدد الحركات: ${summary['total_entries']}',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 20, thickness: 1.5),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildBalanceItem(
                    'الرصيد النقدي',
                    finalBalance['cash']?.toDouble() ?? 0,
                    isCash: true,
                    color: Colors.green.shade700,
                  ),
                  Container(width: 2, height: 50, color: Colors.grey.shade300),
                  _buildBalanceItem(
                    'رصيد الذهب',
                    finalBalance['gold_normalized']?.toDouble() ?? 0,
                    isCash: false,
                    color: Colors.amber.shade700,
                  ),
                ],
              ),
              if (_karatDetail && finalBalance['by_karat'] != null) ...[
                const Divider(height: 20, thickness: 1.5),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'تفاصيل الأعيرة:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF424242),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          _buildKaratChip(
                            '18k',
                            finalBalance['by_karat']['18k'],
                          ),
                          _buildKaratChip(
                            '21k',
                            finalBalance['by_karat']['21k'],
                          ),
                          _buildKaratChip(
                            '22k',
                            finalBalance['by_karat']['22k'],
                          ),
                          _buildKaratChip(
                            '24k',
                            finalBalance['by_karat']['24k'],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBalanceItem(
    String label,
    double value, {
    required bool isCash,
    required Color color,
  }) {
    final formattedValue = isCash ? _formatCash(value) : _formatWeight(value);
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 4),
        Text(
          formattedValue,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: value < 0 ? Colors.red : color,
          ),
        ),
      ],
    );
  }

  Widget _buildKaratChip(String karat, dynamic value) {
    final val = (value ?? 0).toDouble();
    if (val == 0) return const SizedBox.shrink();
    final formatted = _formatWeight(val, decimals: 3, includeUnit: false);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade700, width: 1.5),
      ),
      child: Text(
        '$karat: $formatted جم',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.amber.shade900,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildEntryCard(Map<String, dynamic> entry) {
    final date = DateTime.parse(entry['date']);
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(date);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        title: Text(entry['description'] ?? 'بدون وصف'),
        subtitle: Text('$dateStr | ${entry['account_name']}'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildEntryRow(
                  'الحساب',
                  entry['account_name'],
                  '${entry['account_number']}',
                ),
                const Divider(),

                // Cash
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildAmountChip(
                      'نقد مدين',
                      entry['cash_debit'],
                      Colors.blue,
                      isCash: true,
                    ),
                    _buildAmountChip(
                      'نقد دائن',
                      entry['cash_credit'],
                      Colors.red,
                      isCash: true,
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Gold
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildAmountChip(
                      'ذهب مدين',
                      entry['gold_debit'],
                      Colors.amber.shade700,
                      isCash: false,
                    ),
                    _buildAmountChip(
                      'ذهب دائن',
                      entry['gold_credit'],
                      Colors.orange.shade700,
                      isCash: false,
                    ),
                  ],
                ),

                // Running Balance
                if (_showBalances && entry['running_balance'] != null) ...[
                  const Divider(),
                  const Text(
                    'الرصيد التراكمي:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildBalanceChip(
                        'نقد',
                        entry['running_balance']['cash'],
                        isCash: true,
                      ),
                      _buildBalanceChip(
                        'ذهب',
                        entry['running_balance']['gold_normalized'],
                        isCash: false,
                      ),
                    ],
                  ),
                ],

                // Karat Details
                if (_karatDetail && entry['karat_details'] != null) ...[
                  const Divider(),
                  const Text(
                    'تفاصيل الأعيرة:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _buildKaratDetailsTable(entry['karat_details']),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryRow(String label, String value, String? subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAmountChip(
    String label,
    dynamic value,
    Color color, {
    required bool isCash,
  }) {
    final amount = (value ?? 0).toDouble();
    if (amount == 0) return const SizedBox.shrink();
    final formattedAmount = isCash
        ? _formatCash(amount)
        : _formatWeight(amount);

    return Chip(
      label: Text('$label: ${formattedAmount.replaceAll('\u00A0', ' ')}'),
      backgroundColor: color.withValues(alpha: 0.1),
      labelStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildBalanceChip(
    String label,
    dynamic value, {
    required bool isCash,
  }) {
    final amount = (value ?? 0).toDouble();
    final formatted = isCash ? _formatCash(amount) : _formatWeight(amount);
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: amount < 0 ? Colors.red.shade50 : Colors.green.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            formatted.replaceAll('\u00A0', ' '),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: amount < 0 ? Colors.red : Colors.green.shade700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKaratDetailsTable(Map<String, dynamic> details) {
    return Table(
      border: TableBorder.all(color: Colors.grey.shade300),
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade100),
          children: const [
            Padding(
              padding: EdgeInsets.all(8.0),
              child: Text(
                'العيار',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8.0),
              child: Text(
                'مدين',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(8.0),
              child: Text(
                'دائن',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        ...['18k', '21k', '22k', '24k'].map((karat) {
          final debit = (details[karat]?['debit'] ?? 0).toDouble();
          final credit = (details[karat]?['credit'] ?? 0).toDouble();
          final debitFormatted = _formatWeight(
            debit,
            decimals: 3,
            includeUnit: false,
          );
          final creditFormatted = _formatWeight(
            credit,
            decimals: 3,
            includeUnit: false,
          );

          return TableRow(
            children: [
              Padding(padding: const EdgeInsets.all(8.0), child: Text(karat)),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  debitFormatted,
                  style: TextStyle(
                    color: debit > 0 ? Colors.blue : Colors.grey,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  creditFormatted,
                  style: TextStyle(
                    color: credit > 0 ? Colors.red : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ],
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
