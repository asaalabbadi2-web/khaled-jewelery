import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';

/// Enhanced Trial Balance Screen with dual-entry accounting support
/// Features: Date filtering, karat detail view, balance calculations, professional UI
class TrialBalanceScreenV2 extends StatefulWidget {
  const TrialBalanceScreenV2({super.key});

  @override
  State<TrialBalanceScreenV2> createState() => _TrialBalanceScreenV2State();
}

class _TrialBalanceScreenV2State extends State<TrialBalanceScreenV2> {
  final ApiService _apiService = ApiService();

  // Filter states
  DateTime? _startDate;
  DateTime? _endDate;
  bool _showKaratDetail = false;

  // Data state
  List<Map<String, dynamic>> _entries = [];
  Map<String, dynamic> _totals = {};
  bool _isLoading = false;
  String? _errorMessage;

  // Settings
  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;
  int _mainKarat = 21;

  @override
  void initState() {
    super.initState();
    _loadTrialBalance();
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

  double _toDouble(dynamic value, {double fallback = 0.0}) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      return parsed ?? fallback;
    }
    return fallback;
  }

  double _getTotal(String key, {double fallback = 0.0}) {
    return _toDouble(_totals[key], fallback: fallback);
  }

  double _entryDouble(
    Map<String, dynamic> entry,
    String key, {
    double fallback = 0.0,
  }) {
    return _toDouble(entry[key], fallback: fallback);
  }

  Future<void> _loadTrialBalance() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _apiService.getTrialBalance(
        startDate: _startDate != null
            ? DateFormat('yyyy-MM-dd').format(_startDate!)
            : null,
        endDate: _endDate != null
            ? DateFormat('yyyy-MM-dd').format(_endDate!)
            : null,
        karatDetail: _showKaratDetail,
      );

      setState(() {
        _entries = List<Map<String, dynamic>>.from(
          response['trial_balance'] ?? [],
        );
        _totals = response['totals'] ?? {};
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'خطأ في تحميل البيانات: $e';
        _isLoading = false;
      });
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _showKaratDetail = false;
    });
    _loadTrialBalance();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'ميزان المراجعة',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.filter_alt),
            onPressed: _showFilterDialog,
            tooltip: 'الفلاتر',
          ),
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadTrialBalance,
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterSummary(),
          _buildSummaryCards(),
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator())
                : _errorMessage != null
                ? _buildErrorWidget()
                : _entries.isEmpty
                ? Center(
                    child: Text(
                      'لا توجد بيانات',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                  )
                : _buildTrialBalanceTable(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSummary() {
    if (_startDate == null && _endDate == null && !_showKaratDetail) {
      return SizedBox.shrink();
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.shade700,
        boxShadow: [
          BoxShadow(color: Colors.black12, offset: Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (_startDate != null)
                  Chip(
                    label: Text(
                      'من: ${DateFormat('yyyy-MM-dd').format(_startDate!)}',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    backgroundColor: Colors.blue.shade800,
                    deleteIcon: Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                    onDeleted: () {
                      setState(() => _startDate = null);
                      _loadTrialBalance();
                    },
                  ),
                if (_endDate != null)
                  Chip(
                    label: Text(
                      'إلى: ${DateFormat('yyyy-MM-dd').format(_endDate!)}',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    backgroundColor: Colors.blue.shade800,
                    deleteIcon: Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                    onDeleted: () {
                      setState(() => _endDate = null);
                      _loadTrialBalance();
                    },
                  ),
                if (_showKaratDetail)
                  Chip(
                    label: Text(
                      'تفصيل العيارات',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                    backgroundColor: Colors.amber.shade700,
                    deleteIcon: Icon(
                      Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                    onDeleted: () {
                      setState(() => _showKaratDetail = false);
                      _loadTrialBalance();
                    },
                  ),
              ],
            ),
          ),
          TextButton.icon(
            icon: Icon(Icons.clear_all, size: 18, color: Colors.white),
            label: Text('مسح الكل', style: TextStyle(color: Colors.white)),
            onPressed: _clearFilters,
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    if (_totals.isEmpty) return SizedBox.shrink();

    return Container(
      padding: EdgeInsets.all(16),
      child: _showKaratDetail
          ? _buildKaratDetailSummary()
          : _buildNormalSummary(),
    );
  }

  Widget _buildNormalSummary() {
    final goldDebit = _getTotal('gold_debit');
    final goldCredit = _getTotal('gold_credit');
    final goldBalance = _getTotal('gold_balance');
    final cashDebit = _getTotal('cash_debit');
    final cashCredit = _getTotal('cash_credit');
    final cashBalance = _getTotal('cash_balance');

    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            'الذهب (عيار $_mainKarat)',
            'المدين: ${_formatWeight(goldDebit)}',
            'الدائن: ${_formatWeight(goldCredit)}',
            'الرصيد: ${_formatWeight(goldBalance)}',
            goldBalance >= 0 ? Colors.green.shade700 : Colors.red.shade700,
            Icons.savings,
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: _buildSummaryCard(
            'النقد',
            'المدين: ${_formatCash(cashDebit)}',
            'الدائن: ${_formatCash(cashCredit)}',
            'الرصيد: ${_formatCash(cashBalance)}',
            cashBalance >= 0 ? Colors.green.shade700 : Colors.red.shade700,
            Icons.account_balance_wallet,
          ),
        ),
      ],
    );
  }

  Widget _buildKaratDetailSummary() {
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.blue.shade700,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.analytics, color: Colors.white, size: 22),
              SizedBox(width: 8),
              Text(
                'ملخص العيارات',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildKaratSummaryChip(
              '18K',
              _getTotal('debit_18k'),
              _getTotal('credit_18k'),
            ),
            _buildKaratSummaryChip(
              '21K',
              _getTotal('debit_21k'),
              _getTotal('credit_21k'),
            ),
            _buildKaratSummaryChip(
              '22K',
              _getTotal('debit_22k'),
              _getTotal('credit_22k'),
            ),
            _buildKaratSummaryChip(
              '24K',
              _getTotal('debit_24k'),
              _getTotal('credit_24k'),
            ),
          ],
        ),
        SizedBox(height: 12),
        _buildSummaryCard(
          'النقد',
          'المدين: ${_formatCash(_getTotal('cash_debit'))}',
          'الدائن: ${_formatCash(_getTotal('cash_credit'))}',
          'الرصيد: ${_formatCash(_getTotal('cash_balance'))}',
          _getTotal('cash_balance') >= 0
              ? Colors.green.shade700
              : Colors.red.shade700,
          Icons.account_balance_wallet,
        ),
      ],
    );
  }

  Widget _buildKaratSummaryChip(String karat, double debit, double credit) {
    final balance = debit - credit;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.amber.shade700, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black12, offset: Offset(0, 2), blurRadius: 4),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            karat,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: Colors.brown.shade900, // لون داكن جداً
            ),
          ),
          SizedBox(height: 4),
          Text(
            _formatWeight(balance),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: balance >= 0
                  ? Colors.green.shade800
                  : Colors.red.shade800, // أغمق
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(
    String title,
    String line1,
    String line2,
    String line3,
    Color color,
    IconData icon,
  ) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.1), Colors.white],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
            SizedBox(height: 12),
            Text(
              line1,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
            ),
            SizedBox(height: 4),
            Text(
              line2,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
            ),
            SizedBox(height: 8),
            Text(
              line3,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
          SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: TextStyle(fontSize: 16, color: Colors.red),
          ),
          SizedBox(height: 16),
          ElevatedButton.icon(
            icon: Icon(Icons.refresh),
            label: Text('إعادة المحاولة'),
            onPressed: _loadTrialBalance,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrialBalanceTable() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: _showKaratDetail
            ? _buildKaratDetailTable()
            : _buildNormalTable(),
      ),
    );
  }

  Widget _buildNormalTable() {
    return DataTable(
      headingRowColor: WidgetStateProperty.all(Colors.grey.shade200),
      headingTextStyle: TextStyle(
        fontWeight: FontWeight.bold,
        color: Color(0xFF1976D2),
        fontSize: 14,
      ),
      dataRowMinHeight: 56,
      dataRowMaxHeight: 56,
      columns: const [
        DataColumn(label: Text('رقم الحساب')),
        DataColumn(label: Text('اسم الحساب')),
        DataColumn(label: Text('مدين ذهب'), numeric: true),
        DataColumn(label: Text('دائن ذهب'), numeric: true),
        DataColumn(label: Text('رصيد ذهب'), numeric: true),
        DataColumn(label: Text('مدين نقد'), numeric: true),
        DataColumn(label: Text('دائن نقد'), numeric: true),
        DataColumn(label: Text('رصيد نقد'), numeric: true),
      ],
      rows: [
        ..._entries.map((entry) {
          final goldBalance = _entryDouble(entry, 'gold_balance');
          final cashBalance = _entryDouble(entry, 'cash_balance');

          return DataRow(
            cells: [
              DataCell(
                Text(
                  entry['account_number'] ?? 'N/A',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.blue.shade400, // لون فاتح
                  ),
                ),
              ),
              DataCell(
                Text(
                  entry['account_name'] ?? '',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ), // لون فاتح
              DataCell(
                Text(
                  _formatWeight(
                    _entryDouble(entry, 'gold_debit'),
                    includeUnit: false,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _formatWeight(
                    _entryDouble(entry, 'gold_credit'),
                    includeUnit: false,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _formatWeight(goldBalance, includeUnit: false),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: goldBalance >= 0
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _formatCash(
                    _entryDouble(entry, 'cash_debit'),
                    includeSymbol: false,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _formatCash(
                    _entryDouble(entry, 'cash_credit'),
                    includeSymbol: false,
                  ),
                ),
              ),
              DataCell(
                Text(
                  _formatCash(cashBalance, includeSymbol: false),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: cashBalance >= 0
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                  ),
                ),
              ),
            ],
          );
        }),
        // Totals row
        DataRow(
          color: WidgetStateProperty.all(Colors.blue.shade50),
          cells: [
            DataCell(Text('', style: TextStyle(fontWeight: FontWeight.bold))),
            DataCell(
              Text(
                'الإجمالي',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.blue.shade900, // لون داكن جداً
                ),
              ),
            ),
            DataCell(
              Text(
                _formatWeight(_getTotal('gold_debit'), includeUnit: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900, // داكن جداً
                ),
              ),
            ),
            DataCell(
              Text(
                _formatWeight(_getTotal('gold_credit'), includeUnit: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900, // داكن جداً
                ),
              ),
            ),
            DataCell(
              Text(
                _formatWeight(_getTotal('gold_balance'), includeUnit: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: _getTotal('gold_balance') >= 0
                      ? Colors.green.shade900
                      : Colors.red.shade900, // أغمق
                ),
              ),
            ),
            DataCell(
              Text(
                _formatCash(_getTotal('cash_debit'), includeSymbol: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900, // داكن جداً
                ),
              ),
            ),
            DataCell(
              Text(
                _formatCash(_getTotal('cash_credit'), includeSymbol: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900, // داكن جداً
                ),
              ),
            ),
            DataCell(
              Text(
                _formatCash(_getTotal('cash_balance'), includeSymbol: false),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: _getTotal('cash_balance') >= 0
                      ? Colors.green.shade900
                      : Colors.red.shade900, // أغمق
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildKaratDetailTable() {
    return DataTable(
      headingRowColor: WidgetStateProperty.all(Colors.grey.shade200),
      headingTextStyle: TextStyle(
        fontWeight: FontWeight.bold,
        color: Color(0xFF1976D2),
        fontSize: 13,
      ),
      dataRowMinHeight: 56,
      dataRowMaxHeight: 56,
      columnSpacing: 12,
      columns: const [
        DataColumn(label: Text('رقم الحساب')),
        DataColumn(label: Text('اسم الحساب')),
        DataColumn(label: Text('18K مدين'), numeric: true),
        DataColumn(label: Text('18K دائن'), numeric: true),
        DataColumn(label: Text('18K رصيد'), numeric: true),
        DataColumn(label: Text('21K مدين'), numeric: true),
        DataColumn(label: Text('21K دائن'), numeric: true),
        DataColumn(label: Text('21K رصيد'), numeric: true),
        DataColumn(label: Text('22K مدين'), numeric: true),
        DataColumn(label: Text('22K دائن'), numeric: true),
        DataColumn(label: Text('22K رصيد'), numeric: true),
        DataColumn(label: Text('24K مدين'), numeric: true),
        DataColumn(label: Text('24K دائن'), numeric: true),
        DataColumn(label: Text('24K رصيد'), numeric: true),
        DataColumn(label: Text('نقد مدين'), numeric: true),
        DataColumn(label: Text('نقد دائن'), numeric: true),
        DataColumn(label: Text('نقد رصيد'), numeric: true),
      ],
      rows: [
        ..._entries.map((entry) {
          return DataRow(
            cells: [
              DataCell(
                Text(
                  entry['account_number'] ?? 'N/A',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.blue.shade400, // لون فاتح
                  ),
                ),
              ),
              DataCell(
                Text(
                  entry['account_name'] ?? '',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ), // لون فاتح
              // 18K
              DataCell(
                Text(_entryDouble(entry, 'debit_18k').toStringAsFixed(3)),
              ),
              DataCell(
                Text(_entryDouble(entry, 'credit_18k').toStringAsFixed(3)),
              ),
              DataCell(
                _buildBalanceCell(_entryDouble(entry, 'balance_18k'), true),
              ),
              // 21K
              DataCell(
                Text(_entryDouble(entry, 'debit_21k').toStringAsFixed(3)),
              ),
              DataCell(
                Text(_entryDouble(entry, 'credit_21k').toStringAsFixed(3)),
              ),
              DataCell(
                _buildBalanceCell(_entryDouble(entry, 'balance_21k'), true),
              ),
              // 22K
              DataCell(
                Text(_entryDouble(entry, 'debit_22k').toStringAsFixed(3)),
              ),
              DataCell(
                Text(_entryDouble(entry, 'credit_22k').toStringAsFixed(3)),
              ),
              DataCell(
                _buildBalanceCell(_entryDouble(entry, 'balance_22k'), true),
              ),
              // 24K
              DataCell(
                Text(_entryDouble(entry, 'debit_24k').toStringAsFixed(3)),
              ),
              DataCell(
                Text(_entryDouble(entry, 'credit_24k').toStringAsFixed(3)),
              ),
              DataCell(
                _buildBalanceCell(_entryDouble(entry, 'balance_24k'), true),
              ),
              // Cash
              DataCell(
                Text(_entryDouble(entry, 'cash_debit').toStringAsFixed(2)),
              ),
              DataCell(
                Text(_entryDouble(entry, 'cash_credit').toStringAsFixed(2)),
              ),
              DataCell(
                _buildBalanceCell(_entryDouble(entry, 'cash_balance'), false),
              ),
            ],
          );
        }),
        // Totals row
        DataRow(
          color: WidgetStateProperty.all(Colors.blue.shade50),
          cells: [
            DataCell(Text('')),
            DataCell(
              Text(
                'الإجمالي',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.blue.shade900, // داكن جداً
                ),
              ),
            ),
            // 18K
            DataCell(
              Text(
                _getTotal('debit_18k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              Text(
                _getTotal('credit_18k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              _buildBalanceCell(_getTotal('balance_18k'), true, bold: true),
            ),
            // 21K
            DataCell(
              Text(
                _getTotal('debit_21k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              Text(
                _getTotal('credit_21k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              _buildBalanceCell(_getTotal('balance_21k'), true, bold: true),
            ),
            // 22K
            DataCell(
              Text(
                _getTotal('debit_22k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              Text(
                _getTotal('credit_22k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              _buildBalanceCell(_getTotal('balance_22k'), true, bold: true),
            ),
            // 24K
            DataCell(
              Text(
                _getTotal('debit_24k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              Text(
                _getTotal('credit_24k').toStringAsFixed(3),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              _buildBalanceCell(_getTotal('balance_24k'), true, bold: true),
            ),
            // Cash
            DataCell(
              Text(
                _getTotal('cash_debit').toStringAsFixed(2),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              Text(
                _getTotal('cash_credit').toStringAsFixed(2),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade900,
                ),
              ),
            ),
            DataCell(
              _buildBalanceCell(_getTotal('cash_balance'), false, bold: true),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBalanceCell(double balance, bool isGold, {bool bold = false}) {
    final decimals = isGold ? 3 : 2;
    return Text(
      balance.toStringAsFixed(decimals),
      style: TextStyle(
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontSize: bold ? 15 : 14,
        color: balance >= 0
            ? (bold ? Colors.green.shade900 : Colors.green.shade700)
            : (bold ? Colors.red.shade900 : Colors.red.shade700),
      ),
    );
  }

  void _showFilterDialog() {
    DateTime? tempStartDate = _startDate;
    DateTime? tempEndDate = _endDate;
    bool tempKaratDetail = _showKaratDetail;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.filter_alt, color: Colors.blue.shade700),
              SizedBox(width: 8),
              Text(
                'خيارات الفلترة',
                style: TextStyle(color: Colors.blue.shade700),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade700,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'الفترة الزمنية',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(height: 12),

                // Start Date
                ListTile(
                  leading: Icon(
                    Icons.calendar_today,
                    color: Colors.blue.shade700,
                  ),
                  title: Text(
                    'من تاريخ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  subtitle: Text(
                    tempStartDate != null
                        ? DateFormat('yyyy-MM-dd').format(tempStartDate!)
                        : 'غير محدد',
                    style: TextStyle(
                      color: tempStartDate != null
                          ? Colors.blue.shade900
                          : Colors.grey.shade600,
                      fontWeight: tempStartDate != null
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: tempStartDate != null
                      ? IconButton(
                          icon: Icon(Icons.clear, size: 20),
                          onPressed: () {
                            setDialogState(() => tempStartDate = null);
                          },
                        )
                      : null,
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: tempStartDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      locale: const Locale('ar'),
                    );
                    if (picked != null) {
                      setDialogState(() => tempStartDate = picked);
                    }
                  },
                ),

                // End Date
                ListTile(
                  leading: Icon(
                    Icons.calendar_today,
                    color: Colors.blue.shade700,
                  ),
                  title: Text(
                    'إلى تاريخ',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  subtitle: Text(
                    tempEndDate != null
                        ? DateFormat('yyyy-MM-dd').format(tempEndDate!)
                        : 'غير محدد',
                    style: TextStyle(
                      color: tempEndDate != null
                          ? Colors.blue.shade900
                          : Colors.grey.shade600,
                      fontWeight: tempEndDate != null
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: tempEndDate != null
                      ? IconButton(
                          icon: Icon(Icons.clear, size: 20),
                          onPressed: () {
                            setDialogState(() => tempEndDate = null);
                          },
                        )
                      : null,
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: tempEndDate ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                      locale: const Locale('ar'),
                    );
                    if (picked != null) {
                      setDialogState(() => tempEndDate = picked);
                    }
                  },
                ),

                Divider(height: 32, thickness: 2, color: Colors.grey.shade300),

                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade700,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'خيارات العرض',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(height: 8),

                SwitchListTile(
                  secondary: Icon(Icons.details, color: Colors.amber.shade800),
                  title: Text(
                    'إظهار تفاصيل العيارات',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  subtitle: Text(
                    'عرض 18K, 21K, 22K, 24K بشكل منفصل',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  value: tempKaratDetail,
                  activeThumbColor: Colors.amber.shade800,
                  onChanged: (value) {
                    setDialogState(() => tempKaratDetail = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('إلغاء', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              icon: Icon(Icons.check),
              label: Text('تطبيق'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                setState(() {
                  _startDate = tempStartDate;
                  _endDate = tempEndDate;
                  _showKaratDetail = tempKaratDetail;
                });
                Navigator.pop(context);
                _loadTrialBalance();
              },
            ),
          ],
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
    final effectiveDecimals = decimals ?? 3;
    final formatted = amount.toStringAsFixed(effectiveDecimals);
    return includeUnit ? '$formatted جم' : formatted;
  }
}
