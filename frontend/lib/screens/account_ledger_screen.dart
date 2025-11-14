import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';

/// شاشة دفتر أستاذ لحساب محدد
/// تعرض: رصيد افتتاحي، حركات، رصيد ختامي، تفاصيل أعيرة
class AccountLedgerScreen extends StatefulWidget {
  final int accountId;
  final String accountName;

  const AccountLedgerScreen({
    Key? key,
    required this.accountId,
    required this.accountName,
  }) : super(key: key);

  @override
  State<AccountLedgerScreen> createState() => _AccountLedgerScreenState();
}

class _AccountLedgerScreenState extends State<AccountLedgerScreen> {
  final ApiService _apiService = ApiService();

  DateTime? _startDate;
  DateTime? _endDate;
  bool _karatDetail = true;

  Map<String, dynamic>? _ledgerData;
  bool _isLoading = false;
  String? _errorMessage;
  String currencySymbol = 'ر.س';
  int currencyDecimalPlaces = 2;

  @override
  void initState() {
    super.initState();
    _loadLedger();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
    final newDecimals = settings.decimalPlaces;

    if (newSymbol != currencySymbol || newDecimals != currencyDecimalPlaces) {
      setState(() {
        currencySymbol = newSymbol;
        currencyDecimalPlaces = newDecimals;
      });
    }
  }

  Future<void> _loadLedger() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await _apiService.getAccountLedger(
        widget.accountId,
        startDate: _startDate?.toIso8601String().split('T')[0],
        endDate: _endDate?.toIso8601String().split('T')[0],
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

  void _showDatePicker() async {
    DateTime? tempStartDate = _startDate;
    DateTime? tempEndDate = _endDate;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('اختر الفترة الزمنية'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today),
                label: Text(
                  tempStartDate != null
                      ? 'من: ${DateFormat('yyyy-MM-dd').format(tempStartDate!)}'
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
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today),
                label: Text(
                  tempEndDate != null
                      ? 'إلى: ${DateFormat('yyyy-MM-dd').format(tempEndDate!)}'
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
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _startDate = tempStartDate;
                  _endDate = tempEndDate;
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('دفتر الأستاذ', style: TextStyle(fontSize: 16)),
            Text(
              widget.accountName,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_karatDetail ? Icons.view_list : Icons.view_module),
            onPressed: () {
              setState(() {
                _karatDetail = !_karatDetail;
              });
              _loadLedger();
            },
            tooltip: _karatDetail
                ? 'إخفاء تفاصيل الأعيرة'
                : 'عرض تفاصيل الأعيرة',
          ),
          IconButton(
            icon: const Icon(Icons.date_range),
            onPressed: _showDatePicker,
            tooltip: 'تحديد الفترة',
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

    if (_ledgerData == null) {
      return const Center(child: Text('لا توجد بيانات'));
    }

    final openingBalance = _ledgerData!['opening_balance'];
    final closingBalance = _ledgerData!['closing_balance'];
    final entries = List<Map<String, dynamic>>.from(
      _ledgerData!['entries'] ?? [],
    );
    final totalEntries = _ledgerData!['total_entries'] ?? 0;

    return Column(
      children: [
        // Date Range Indicator
        if (_startDate != null || _endDate != null)
          Container(
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'الفترة: ${_startDate != null ? DateFormat('yyyy-MM-dd').format(_startDate!) : "البداية"} إلى ${_endDate != null ? DateFormat('yyyy-MM-dd').format(_endDate!) : "النهاية"}',
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
                      _startDate = null;
                      _endDate = null;
                    });
                    _loadLedger();
                  },
                ),
              ],
            ),
          ),

        // Opening Balance
        _buildBalanceCard('الرصيد الافتتاحي', openingBalance, Colors.blue),

        // Entries Count
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            'عدد الحركات: $totalEntries',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        // Entries List
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('لا توجد حركات في هذه الفترة'),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    return _buildEntryCard(entries[index]);
                  },
                ),
        ),

        // Closing Balance
        _buildBalanceCard('الرصيد الختامي', closingBalance, Colors.green),
      ],
    );
  }

  Widget _buildBalanceCard(
    String title,
    Map<String, dynamic>? balance,
    Color color,
  ) {
    if (balance == null) return const SizedBox.shrink();

    final cashBalance = (balance['cash'] ?? 0).toDouble();
    final goldBalance = (balance['gold_normalized'] ?? 0).toDouble();
    final byKarat = balance['by_karat'];

    return Card(
      margin: const EdgeInsets.all(8),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, color.withValues(alpha: 0.05)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const Divider(height: 20, thickness: 1.5),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildBalanceItem('نقد', cashBalance, currencySymbol, color),
                  Container(width: 2, height: 50, color: Colors.grey.shade300),
                  _buildBalanceItem(
                    'ذهب (21k)',
                    goldBalance,
                    'جم',
                    Colors.amber.shade700,
                  ),
                ],
              ),
              if (_karatDetail && byKarat != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(8),
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
                          fontSize: 14,
                          color: Color(0xFF424242),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Table(
                        border: TableBorder.all(
                          color: Colors.grey.shade400,
                          width: 1.5,
                        ),
                        children: [
                          TableRow(
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                            ),
                            children: const [
                              Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Text(
                                  'العيار',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1976D2),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Text(
                                  'الوزن (جم)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1976D2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ...['18k', '21k', '22k', '24k'].map((karat) {
                            final weight = (byKarat[karat] ?? 0).toDouble();
                            return TableRow(
                              decoration: BoxDecoration(
                                color: weight != 0
                                    ? Colors.amber.shade50
                                    : Colors.white,
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Text(
                                    karat,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF424242),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Text(
                                    weight.toStringAsFixed(3),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: weight < 0
                                          ? Colors.red.shade700
                                          : Colors.green.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
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
    double value,
    String unit,
    Color color,
  ) {
    final isCurrency = unit == currencySymbol;
    final decimals = isCurrency
        ? currencyDecimalPlaces
        : (value.abs() < 1 ? 3 : 2);
    final formattedValue = '${value.toStringAsFixed(decimals)} $unit';
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
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: value < 0 ? Colors.red : color,
          ),
        ),
      ],
    );
  }

  Widget _buildEntryCard(Map<String, dynamic> entry) {
    final date = DateTime.parse(entry['date']);
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(date);

    final cashDebit = (entry['cash_debit'] ?? 0).toDouble();
    final cashCredit = (entry['cash_credit'] ?? 0).toDouble();
    final goldDebit = (entry['gold_debit'] ?? 0).toDouble();
    final goldCredit = (entry['gold_credit'] ?? 0).toDouble();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(entry['description'] ?? 'بدون وصف'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dateStr),
            const SizedBox(height: 4),
            Row(
              children: [
                if (cashDebit > 0)
                  Chip(
                    label: Text('نقد مدين: ${_formatCash(cashDebit)}'),
                    backgroundColor: Colors.blue.shade100,
                    labelStyle: const TextStyle(fontSize: 11),
                  ),
                if (cashCredit > 0)
                  Chip(
                    label: Text('نقد دائن: ${_formatCash(cashCredit)}'),
                    backgroundColor: Colors.red.shade100,
                    labelStyle: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
            Row(
              children: [
                if (goldDebit > 0)
                  Chip(
                    label: Text('ذهب مدين: ${goldDebit.toStringAsFixed(3)} جم'),
                    backgroundColor: Colors.amber.shade100,
                    labelStyle: const TextStyle(fontSize: 11),
                  ),
                if (goldCredit > 0)
                  Chip(
                    label: Text(
                      'ذهب دائن: ${goldCredit.toStringAsFixed(3)} جم',
                    ),
                    backgroundColor: Colors.orange.shade100,
                    labelStyle: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ],
        ),
        trailing: entry['running_balance'] != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('رصيد', style: TextStyle(fontSize: 10)),
                  Text(
                    _formatCash(
                      (entry['running_balance']['cash'] ?? 0).toDouble(),
                    ),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${(entry['running_balance']['gold_normalized'] ?? 0).toStringAsFixed(3)} جم',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              )
            : null,
        onTap: _karatDetail && entry['karat_details'] != null
            ? () => _showKaratDetails(entry)
            : null,
      ),
    );
  }

  void _showKaratDetails(Map<String, dynamic> entry) {
    final karatDetails = entry['karat_details'];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تفاصيل الأعيرة'),
        content: Table(
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
              final debit = (karatDetails[karat]?['debit'] ?? 0).toDouble();
              final credit = (karatDetails[karat]?['credit'] ?? 0).toDouble();

              return TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(karat),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      debit.toStringAsFixed(3),
                      style: TextStyle(
                        color: debit > 0 ? Colors.blue : Colors.grey,
                        fontWeight: debit > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      credit.toStringAsFixed(3),
                      style: TextStyle(
                        color: credit > 0 ? Colors.red : Colors.grey,
                        fontWeight: credit > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  String _formatCash(double value, {int? decimals}) {
    final effectiveDecimals = decimals ?? currencyDecimalPlaces;
    return '${value.toStringAsFixed(effectiveDecimals)} $currencySymbol';
  }
}
