import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';

class SupplierLedgerScreen extends StatefulWidget {
  final ApiService api;
  final int supplierId;
  final String supplierName;
  final bool isArabic;

  const SupplierLedgerScreen({
    super.key,
    required this.api,
    required this.supplierId,
    required this.supplierName,
    this.isArabic = true,
  });

  @override
  State<SupplierLedgerScreen> createState() => _SupplierLedgerScreenState();
}

class _SupplierLedgerScreenState extends State<SupplierLedgerScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  Map<String, dynamic>? _ledgerData;

  DateTime? _startDate;
  DateTime? _endDate;
  int _page = 1;
  int _totalPages = 1;
  final int _perPage = 50;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;
  late NumberFormat _cashFormatter;
  late NumberFormat _goldFormatter;

  @override
  void initState() {
    super.initState();
    _updateFormatters();
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
        newDecimals != _currencyDecimals ||
        newMainKarat != _mainKarat) {
      setState(() {
        _currencySymbol = newSymbol;
        _currencyDecimals = newDecimals;
        _mainKarat = newMainKarat;
        _updateFormatters();
      });
    }
  }

  Future<void> _loadLedger() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final data = await widget.api.getSupplierLedger(
        widget.supplierId,
        page: _page,
        perPage: _perPage,
        dateFrom: _startDate,
        dateTo: _endDate,
      );

      if (!mounted) return;
      final pagination = _mapFrom(data['pagination']);
      setState(() {
        _ledgerData = Map<String, dynamic>.from(data);
        _totalPages = _parseInt(pagination?['total_pages']) ?? 1;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _page = 1;
    });
    await _loadLedger();
  }

  Future<void> _pickDateRange() async {
    final initialRange = DateTimeRange(
      start: _startDate ?? DateTime.now().subtract(const Duration(days: 30)),
      end: _endDate ?? DateTime.now(),
    );

    final range = await showDateRangePicker(
      context: context,
      initialDateRange: initialRange,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 5),
      builder: (context, child) {
        final direction = widget.isArabic
            ? ui.TextDirection.rtl
            : ui.TextDirection.ltr;
        return Directionality(
          textDirection: direction,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (range != null) {
      setState(() {
        _startDate = range.start;
        _endDate = range.end;
        _page = 1;
      });
      await _loadLedger();
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _page = 1;
    });
    _loadLedger();
  }

  void _changePage(int delta) {
    final newPage = (_page + delta).clamp(1, _totalPages);
    if (newPage == _page) return;
    setState(() {
      _page = newPage;
    });
    _loadLedger();
  }

  void _updateFormatters() {
    final localeCode = widget.isArabic ? 'ar' : 'en';
    _cashFormatter = NumberFormat.currency(
      locale: localeCode,
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );
    _goldFormatter = NumberFormat('#,##0.###', localeCode);
  }

  Map<String, dynamic>? _mapFrom(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      value.forEach((key, val) {
        result[key.toString()] = val;
      });
      return result;
    }
    return null;
  }

  List<Map<String, dynamic>> _listOfMaps(dynamic value) {
    if (value is List) {
      return value.map(_mapFrom).whereType<Map<String, dynamic>>().toList();
    }
    return const [];
  }

  int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    if (value is double) return value.round();
    return null;
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  // Converts raw gold values to the configured main karat equivalent.
  double _goldToMain(Map<String, dynamic>? values) {
    if (values == null || _mainKarat == 0) {
      return 0;
    }

    final gold18 = _toDouble(values['gold_18k']);
    final gold21 = _toDouble(values['gold_21k']);
    final gold22 = _toDouble(values['gold_22k']);
    final gold24 = _toDouble(values['gold_24k']);

    return gold18 * (18 / _mainKarat) +
        gold21 +
        gold22 * (22 / _mainKarat) +
        gold24 * (24 / _mainKarat);
  }

  bool _hasGoldBalances(Map<String, dynamic>? values) {
    if (values == null) return false;
    return _toDouble(values['gold_18k']).abs() > 0.0001 ||
        _toDouble(values['gold_21k']).abs() > 0.0001 ||
        _toDouble(values['gold_22k']).abs() > 0.0001 ||
        _toDouble(values['gold_24k']).abs() > 0.0001;
  }

  String _formatCash(double value) => _cashFormatter.format(value);

  String _formatGold(double value) => _goldFormatter.format(value);

  String _formatDate(String? raw) {
    if (raw == null) return '';
    try {
      final date = DateTime.parse(raw);
      final format = DateFormat(
        'yyyy-MM-dd HH:mm',
        widget.isArabic ? 'ar' : 'en',
      );
      return format.format(date);
    } catch (_) {
      return raw;
    }
  }

  String _formatShortDate(String? raw) {
    if (raw == null || raw.isEmpty) return _t('غير محدد', 'N/A');
    try {
      final date = DateTime.parse(raw);
      final format = DateFormat('yyyy-MM-dd', widget.isArabic ? 'ar' : 'en');
      return format.format(date);
    } catch (_) {
      return raw;
    }
  }

  String _t(String ar, String en) => widget.isArabic ? ar : en;

  Widget _buildInfoPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.withValues(alpha: 0.9),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildMetricTile(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: color.withValues(alpha: 0.06),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryHeader(Map<String, dynamic>? summary) {
    if (summary == null) return const SizedBox.shrink();

    final supplierInfo = _mapFrom(summary['supplier']);
    final supplierCode = supplierInfo?['code']?.toString();
    final totalEntries = _parseInt(summary['total_entries']) ?? 0;
    final lastDate = summary['last_transaction_date']?.toString();
    final filters = _mapFrom(summary['filters']);
    final dateFrom = _formatShortDate(filters?['date_from']?.toString());
    final dateTo = _formatShortDate(filters?['date_to']?.toString());

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        supplierInfo?['name']?.toString() ??
                            widget.supplierName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (supplierCode != null && supplierCode.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${_t('كود المورد', 'Supplier Code')}: $supplierCode',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
                _buildInfoPill(
                  '${_t('إجمالي القيود', 'Journal lines')}: $totalEntries',
                  Colors.indigo,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildMetricTile(
                  _t('آخر حركة', 'Last transaction'),
                  lastDate != null && lastDate.isNotEmpty
                      ? _formatDate(lastDate)
                      : _t('لا توجد حركات', 'No transactions'),
                  Icons.schedule,
                  Colors.teal,
                ),
                const SizedBox(width: 12),
                _buildMetricTile(
                  _t('الفترة الحالية', 'Current range'),
                  '$dateFrom → $dateTo',
                  Icons.calendar_today,
                  Colors.deepPurple,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClosingCard(Map<String, dynamic>? net) {
    if (net == null) return const SizedBox.shrink();

    final cash = _toDouble(net['cash']);
    final goldMain = _goldToMain(net);

    Color valueColor(double value) => value >= 0 ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('صافي المركز', 'Net Position'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildMetricTile(
                  _t('رصيد نقدي', 'Cash balance'),
                  _formatCash(cash),
                  Icons.payments,
                  valueColor(cash),
                ),
                const SizedBox(width: 12),
                _buildMetricTile(
                  _t('ذهب مكافئ $_mainKarat', 'Gold (${_mainKarat}k eq.)'),
                  '${_formatGold(goldMain)} ${_t('جم', 'g')}',
                  Icons.workspace_premium,
                  valueColor(goldMain),
                ),
              ],
            ),
            if (_hasGoldBalances(net)) ...[
              const SizedBox(height: 16),
              Text(
                _t('تفاصيل صافى الأعيرة', 'Net by karat'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_toDouble(net['gold_18k']).abs() > 0.0001)
                    _buildInfoPill(
                      '${_t('ذهب 18', 'Gold 18k')}: ${_formatGold(_toDouble(net['gold_18k']))} ${_t('جم', 'g')}',
                      Colors.orange,
                    ),
                  if (_toDouble(net['gold_21k']).abs() > 0.0001)
                    _buildInfoPill(
                      '${_t('ذهب 21', 'Gold 21k')}: ${_formatGold(_toDouble(net['gold_21k']))} ${_t('جم', 'g')}',
                      Colors.amber.shade800,
                    ),
                  if (_toDouble(net['gold_22k']).abs() > 0.0001)
                    _buildInfoPill(
                      '${_t('ذهب 22', 'Gold 22k')}: ${_formatGold(_toDouble(net['gold_22k']))} ${_t('جم', 'g')}',
                      Colors.deepOrange,
                    ),
                  if (_toDouble(net['gold_24k']).abs() > 0.0001)
                    _buildInfoPill(
                      '${_t('ذهب 24', 'Gold 24k')}: ${_formatGold(_toDouble(net['gold_24k']))} ${_t('جم', 'g')}',
                      Colors.brown,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTotalsCard(Map<String, dynamic>? summary) {
    if (summary == null) return const SizedBox.shrink();

    final debits = _mapFrom(summary['total_debits']);
    final credits = _mapFrom(summary['total_credits']);

    if (debits == null || credits == null) {
      return const SizedBox.shrink();
    }

    final debitCash = _formatCash(_toDouble(debits['cash']));
    final creditCash = _formatCash(_toDouble(credits['cash']));
    final debitGold = _formatGold(_goldToMain(debits));
    final creditGold = _formatGold(_goldToMain(credits));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('ملخص الحركات', 'Movements Summary'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _t('إجمالي مدين', 'Total Debits'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildInfoPill(
                        '${_t('نقد', 'Cash')}: $debitCash',
                        Colors.green,
                      ),
                      const SizedBox(height: 6),
                      _buildInfoPill(
                        '${_t('ذهب مكافئ $_mainKarat', 'Gold ${_mainKarat}k eq.')}: $debitGold ${_t('جم', 'g')}',
                        Colors.orange,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _t('إجمالي دائن', 'Total Credits'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildInfoPill(
                        '${_t('نقد', 'Cash')}: $creditCash',
                        Colors.red,
                      ),
                      const SizedBox(height: 6),
                      _buildInfoPill(
                        '${_t('ذهب مكافئ $_mainKarat', 'Gold ${_mainKarat}k eq.')}: $creditGold ${_t('جم', 'g')}',
                        Colors.brown,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCashPills(Map<String, dynamic> movement) {
    final pills = <Widget>[];
    final cashDebit = _toDouble(movement['cash_debit']);
    final cashCredit = _toDouble(movement['cash_credit']);

    if (cashDebit.abs() > 0.0001) {
      pills.add(
        _buildInfoPill(
          '${_t('نقد مدين', 'Cash Debit')}: ${_formatCash(cashDebit)}',
          Colors.green,
        ),
      );
    }
    if (cashCredit.abs() > 0.0001) {
      pills.add(
        _buildInfoPill(
          '${_t('نقد دائن', 'Cash Credit')}: ${_formatCash(cashCredit)}',
          Colors.red,
        ),
      );
    }
    return pills;
  }

  List<Widget> _buildGoldPills(Map<String, dynamic> movement) {
    final pills = <Widget>[];
    const karats = [
      {'label': '18', 'debit': 'gold_18k_debit', 'credit': 'gold_18k_credit'},
      {'label': '21', 'debit': 'gold_21k_debit', 'credit': 'gold_21k_credit'},
      {'label': '22', 'debit': 'gold_22k_debit', 'credit': 'gold_22k_credit'},
      {'label': '24', 'debit': 'gold_24k_debit', 'credit': 'gold_24k_credit'},
    ];

    for (final entry in karats) {
      final label = entry['label'] as String;
      final debitAmount = _toDouble(movement[entry['debit']]);
      final creditAmount = _toDouble(movement[entry['credit']]);

      if (debitAmount.abs() > 0.0001) {
        pills.add(
          _buildInfoPill(
            '${_t('ذهب', 'Gold')} $label${_t(' مدين', ' Debit')}: ${_formatGold(debitAmount)} ${_t('جم', 'g')}',
            Colors.orange,
          ),
        );
      }
      if (creditAmount.abs() > 0.0001) {
        pills.add(
          _buildInfoPill(
            '${_t('ذهب', 'Gold')} $label${_t(' دائن', ' Credit')}: ${_formatGold(creditAmount)} ${_t('جم', 'g')}',
            Colors.brown,
          ),
        );
      }
    }

    return pills;
  }

  Widget _buildMovementCard(Map<String, dynamic> movement) {
    final date = _formatDate(movement['date']?.toString());
    final entryNumber = movement['entry_number']?.toString() ?? '';
    final description = movement['description']?.toString() ?? '';
    final account =
        movement['account_name']?.toString() ?? _t('غير محدد', 'N/A');
    final referenceType = movement['reference_type']?.toString();
    final referenceId = movement['reference_id']?.toString();

    final cashPills = _buildCashPills(movement);
    final goldPills = _buildGoldPills(movement);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    date,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entryNumber.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      entryNumber,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${_t('الحساب', 'Account')}: $account',
              style: const TextStyle(fontSize: 13),
            ),
            if (referenceType != null && referenceId != null) ...[
              const SizedBox(height: 6),
              Text(
                '${_t('مرجع', 'Reference')}: $referenceType #$referenceId',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
            if (cashPills.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: cashPills),
            ],
            if (goldPills.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: goldPills),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPagination(Map<String, dynamic>? pagination) {
    if (_totalPages <= 1) {
      return const SizedBox.shrink();
    }

    final totalItems = _parseInt(pagination?['total_items']);
    final totalLabel = totalItems != null
        ? ' ${_t('• إجمالي', '• Total')} $totalItems'
        : '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${_t('صفحة', 'Page')} $_page / $_totalPages$totalLabel',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          Row(
            children: [
              IconButton(
                onPressed: _page > 1 ? () => _changePage(-1) : null,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                onPressed: _page < _totalPages ? () => _changePage(1) : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBanner() {
    if (_startDate == null && _endDate == null) {
      return const SizedBox.shrink();
    }

    final start = _startDate != null
        ? DateFormat('yyyy-MM-dd').format(_startDate!)
        : _t('البداية', 'Start');
    final end = _endDate != null
        ? DateFormat('yyyy-MM-dd').format(_endDate!)
        : _t('النهاية', 'End');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.indigo.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.indigo.shade100),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_t('الفترة المختارة', 'Selected period')}: $start → $end',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.indigo.shade700,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _clearFilters,
            icon: const Icon(Icons.filter_alt_off),
            label: Text(_t('مسح', 'Clear')),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final summary = _mapFrom(_ledgerData?['summary']);
    final net = _mapFrom(summary?['net']);
    final pagination = _mapFrom(_ledgerData?['pagination']);
    final movements = _listOfMaps(_ledgerData?['movements']);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildSummaryHeader(summary),
          _buildFilterBanner(),
          _buildClosingCard(net),
          _buildTotalsCard(summary),
          const SizedBox(height: 8),
          Text(
            _t('الحركات', 'Movements'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (movements.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inbox, size: 48, color: Colors.grey.shade500),
                  const SizedBox(height: 12),
                  Text(
                    _t(
                      'لا توجد حركات في هذه الفترة',
                      'No movements for this period',
                    ),
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                ],
              ),
            )
          else
            ...movements.map(_buildMovementCard),
          _buildPagination(pagination),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? _t('حدث خطأ غير متوقع', 'Unexpected error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadLedger,
              icon: const Icon(Icons.refresh),
              label: Text(_t('إعادة المحاولة', 'Retry')),
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
            Text(
              _t('كشف المورد', 'Supplier Ledger'),
              style: const TextStyle(fontSize: 16),
            ),
            Text(
              widget.supplierName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: _t('تحديد الفترة', 'Select period'),
            onPressed: _pickDateRange,
          ),
          if (_startDate != null || _endDate != null)
            IconButton(
              icon: const Icon(Icons.filter_alt_off),
              tooltip: _t('مسح الفلاتر', 'Clear filters'),
              onPressed: _clearFilters,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: _t('تحديث', 'Refresh'),
            onPressed: _loadLedger,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : (_errorMessage != null ? _buildErrorView() : _buildContent()),
    );
  }
}
