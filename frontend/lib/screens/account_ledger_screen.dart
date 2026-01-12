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
    super.key,
    required this.accountId,
    required this.accountName,
  });

  @override
  State<AccountLedgerScreen> createState() => _AccountLedgerScreenState();
}

class _AccountLedgerScreenState extends State<AccountLedgerScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();

  DateTime? _startDate;
  DateTime? _endDate;
  bool _karatDetail = true;
  String _searchQuery = '';

  Map<String, dynamic>? _ledgerData;
  bool _isLoading = false;
  String? _errorMessage;
  String currencySymbol = 'ر.س';
  int currencyDecimalPlaces = 2;
  int mainKarat = 21;

  @override
  void initState() {
    super.initState();
    _loadLedger();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
    final newDecimals = settings.decimalPlaces;
    final newMainKarat = settings.mainKarat;

    if (newSymbol != currencySymbol ||
        newDecimals != currencyDecimalPlaces ||
        newMainKarat != mainKarat) {
      setState(() {
        currencySymbol = newSymbol;
        currencyDecimalPlaces = newDecimals;
        mainKarat = newMainKarat;
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

    final filteredEntries = _filterEntries(entries);

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

        // Search + quick filters
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Column(
            children: [
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'بحث (وصف/رقم القيد/المبلغ)...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'مسح البحث',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (value) => setState(() {
                  _searchQuery = value;
                }),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'المعروض: ${filteredEntries.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: (_startDate != null ||
                            _endDate != null ||
                            _searchQuery.isNotEmpty)
                        ? () {
                            setState(() {
                              _startDate = null;
                              _endDate = null;
                              _searchQuery = '';
                            });
                            _searchController.clear();
                            _loadLedger();
                          }
                        : null,
                    icon: const Icon(Icons.filter_alt_off),
                    label: const Text('مسح الكل'),
                  ),
                ],
              ),
            ],
          ),
        ),

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
          child: filteredEntries.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inbox, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('لا توجد نتائج مطابقة'),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: filteredEntries.length,
                  itemBuilder: (context, index) {
                    return _buildEntryCard(filteredEntries[index]);
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
                    'ذهب (مكافئ $mainKarat)',
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
                          }),
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

    final hasCash = cashDebit > 0 || cashCredit > 0;
    final hasGold = goldDebit > 0 || goldCredit > 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(entry['description'] ?? 'بدون وصف'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dateStr),
            const SizedBox(height: 6),
            if (hasCash)
              _buildEntryAmountsRow(
                icon: Icons.payments,
                label: 'نقد',
                debitText: cashDebit > 0 ? _formatCash(cashDebit) : null,
                creditText: cashCredit > 0 ? _formatCash(cashCredit) : null,
              ),
            if (hasGold)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _buildEntryAmountsRow(
                  icon: Icons.scale,
                  label: 'ذهب (مكافئ $mainKarat)',
                  debitText: goldDebit > 0
                      ? '${goldDebit.toStringAsFixed(3)} جم'
                      : null,
                  creditText: goldCredit > 0
                      ? '${goldCredit.toStringAsFixed(3)} جم'
                      : null,
                ),
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
        onTap: () => _showEntryQuickView(entry),
      ),
    );
  }

  Widget _buildEntryAmountsRow({
    required IconData icon,
    required String label,
    required String? debitText,
    required String? creditText,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey.shade700),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 10),
        if (debitText != null)
          Expanded(
            child: Text(
              'مدين: $debitText',
              style: TextStyle(
                fontSize: 12,
                color: Colors.blue.shade800,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          const Spacer(),
        if (creditText != null)
          Expanded(
            child: Text(
              'دائن: $creditText',
              style: TextStyle(
                fontSize: 12,
                color: Colors.red.shade800,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }

  List<Map<String, dynamic>> _filterEntries(List<Map<String, dynamic>> entries) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return entries;

    bool matchesAmount(Map<String, dynamic> entry) {
      final normalized = q.replaceAll(',', '.');
      final parsed = double.tryParse(normalized);
      if (parsed == null) return false;
      final values = <double>[
        (entry['cash_debit'] ?? 0).toDouble(),
        (entry['cash_credit'] ?? 0).toDouble(),
        (entry['gold_debit'] ?? 0).toDouble(),
        (entry['gold_credit'] ?? 0).toDouble(),
      ];
      return values.any((v) => (v - parsed).abs() < 0.0001);
    }

    return entries.where((entry) {
      final description = (entry['description'] ?? '').toString().toLowerCase();
      final id = (entry['id'] ?? '').toString();
      final journalId = (entry['journal_entry_id'] ?? '').toString();
      final date = (entry['date'] ?? '').toString().toLowerCase();

      return description.contains(q) ||
          id.contains(q) ||
          journalId.contains(q) ||
          date.contains(q) ||
          matchesAmount(entry);
    }).toList();
  }

  void _showEntryQuickView(Map<String, dynamic> entry) {
    final date = DateTime.tryParse(entry['date'] ?? '') ?? DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(date);
    final description = (entry['description'] ?? 'بدون وصف').toString();

    final cashDebit = (entry['cash_debit'] ?? 0).toDouble();
    final cashCredit = (entry['cash_credit'] ?? 0).toDouble();
    final goldDebit = (entry['gold_debit'] ?? 0).toDouble();
    final goldCredit = (entry['gold_credit'] ?? 0).toDouble();
    final running = entry['running_balance'] as Map<String, dynamic>?;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        'تفاصيل الحركة',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'إغلاق',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildKvRow('التاريخ', dateStr),
                  _buildKvRow('الوصف', description),
                  _buildKvRow(
                    'رقم القيد',
                    (entry['journal_entry_id'] ?? '-').toString(),
                  ),
                  const Divider(height: 24),
                  _buildKvRow('نقد مدين', cashDebit > 0 ? _formatCash(cashDebit) : '-'),
                  _buildKvRow(
                    'نقد دائن',
                    cashCredit > 0 ? _formatCash(cashCredit) : '-',
                  ),
                  _buildKvRow(
                    'ذهب مدين (مكافئ $mainKarat)',
                    goldDebit > 0 ? '${goldDebit.toStringAsFixed(3)} جم' : '-',
                  ),
                  _buildKvRow(
                    'ذهب دائن (مكافئ $mainKarat)',
                    goldCredit > 0
                        ? '${goldCredit.toStringAsFixed(3)} جم'
                        : '-',
                  ),
                  if (running != null) ...[
                    const Divider(height: 24),
                    _buildKvRow(
                      'الرصيد (نقد)',
                      _formatCash((running['cash'] ?? 0).toDouble()),
                    ),
                    _buildKvRow(
                      'الرصيد (ذهب مكافئ $mainKarat)',
                      '${(running['gold_normalized'] ?? 0).toStringAsFixed(3)} جم',
                    ),
                  ],
                  if (_karatDetail && entry['karat_details'] != null) ...[
                    const Divider(height: 24),
                    Text(
                      'تفاصيل الأعيرة',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _buildKaratDetailsTable(entry['karat_details']),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildKvRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              k,
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKaratDetailsTable(dynamic karatDetails) {
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
        }),
      ],
    );
  }

  String _formatCash(double value, {int? decimals}) {
    final effectiveDecimals = decimals ?? currencyDecimalPlaces;
    return '${value.toStringAsFixed(effectiveDecimals)} $currencySymbol';
  }
}
