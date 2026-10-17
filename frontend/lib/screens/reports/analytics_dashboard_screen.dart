import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';
import '../../utils/currency_utils.dart' as cu;
import '../../utils/invoice_type_label.dart';

class AnalyticsDashboardScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const AnalyticsDashboardScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<AnalyticsDashboardScreen> createState() =>
      _AnalyticsDashboardScreenState();
}

class _AnalyticsDashboardScreenState extends State<AnalyticsDashboardScreen> {
  Map<String, dynamic>? _response;
  Map<String, dynamic>? _transactionTypeResponse;
  bool _isLoading = false;
  String? _error;

  DateTimeRange? _selectedRange;
  String _groupBy =
      'branch'; // branch | gold_office | transaction_type | employee
  bool _postedOnly = true;

  String _currencySymbol = '';
  int _currencyDecimals = 2;

  // weight_main | amount_cash | weight_out_main | weight_in_main | cash_in | cash_out
  String _chartMetric = 'weight_main';

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    _selectedRange = DateTimeRange(
      start: todayDate.subtract(const Duration(days: 29)),
      end: todayDate,
    );

    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );
    _weightFormat = NumberFormat('#,##0.000');

    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final symbol = settings.currencySymbolText;
    final decimals = settings.decimalPlaces;

    if (symbol != _currencySymbol || decimals != _currencyDecimals) {
      setState(() {
        _currencySymbol = symbol;
        _currencyDecimals = decimals;
        _currencyFormat = NumberFormat.currency(
          locale: widget.isArabic ? 'ar' : 'en',
          symbol: _currencySymbol,
          decimalDigits: _currencyDecimals,
        );
      });
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final futures = <Future<Map<String, dynamic>>>[];
      futures.add(
        widget.api.getAnalyticsSummary(
          groupBy: _groupBy,
          startDate: _selectedRange?.start,
          endDate: _selectedRange?.end,
          postedOnly: _postedOnly,
        ),
      );

      // نستخدم تجميع نوع العملية دائماً لاستخراج KPIs سلوكية (بيع/شراء من عميل)
      // حتى لو كان المستخدم يعرض التجميع حسب الفرع/الموظف.
      if (_groupBy == 'transaction_type') {
        futures.add(Future.value(<String, dynamic>{}));
      } else {
        futures.add(
          widget.api.getAnalyticsSummary(
            groupBy: 'transaction_type',
            startDate: _selectedRange?.start,
            endDate: _selectedRange?.end,
            postedOnly: _postedOnly,
          ),
        );
      }

      final results = await Future.wait(futures);
      final result = results[0];
      final transactionResult = _groupBy == 'transaction_type'
          ? result
          : results[1];

      if (!mounted) return;
      setState(() {
        _response = result;
        _transactionTypeResponse = transactionResult;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return 0.0;
  }

  String _formatCurrency(num value) => _currencyFormat.format(value);

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialRange =
        _selectedRange ??
        DateTimeRange(start: now.subtract(const Duration(days: 29)), end: now);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initialRange,
      locale: widget.isArabic ? const Locale('ar') : const Locale('en'),
    );

    if (picked != null) {
      setState(() {
        _selectedRange = picked;
      });
      await _loadData();
    }
  }

  void _clearDateRange() {
    setState(() {
      _selectedRange = null;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isArabic ? 'لوحة التحليل الوزني' : 'Weighted Analytics Dashboard',
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: isArabic ? 'تحديث' : 'Refresh',
              onPressed: _isLoading ? null : _loadData,
            ),
          ],
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _buildErrorState()
              : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final isArabic = widget.isArabic;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 12),
          Text(
            isArabic ? 'تعذّر تحميل البيانات' : 'Failed to load data',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final isArabic = widget.isArabic;
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildFiltersCard(isArabic),
          const SizedBox(height: 16),
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildBarChartCard(isArabic),
          const SizedBox(height: 16),
          _buildSalesVsScrapChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTableCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText = _selectedRange == null
        ? (isArabic ? 'كل الفترات' : 'All time')
        : '${DateFormat('yyyy-MM-dd').format(_selectedRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange!.end)}';

    final groupLabels = <String, String>{
      'branch': isArabic ? 'الفروع' : 'Branches',
      'gold_office': isArabic ? 'مكاتب التسكير' : 'Gold Offices',
      'transaction_type': isArabic ? 'نوع العملية' : 'Transaction Type',
      'employee': isArabic ? 'الموظفون' : 'Employees',
    };

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'خيارات التحليل' : 'Analytics Options',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: isArabic
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic ? 'الفترة الزمنية' : 'Date range',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        rangeText,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.date_range),
                  tooltip: isArabic ? 'تغيير الفترة' : 'Change range',
                ),
                IconButton(
                  onPressed: _selectedRange == null ? null : _clearDateRange,
                  icon: const Icon(Icons.clear),
                  tooltip: isArabic ? 'كل الفترات' : 'All time',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: groupLabels.entries.map((entry) {
                final selected = _groupBy == entry.key;
                return ChoiceChip(
                  label: Text(entry.value),
                  selected: selected,
                  onSelected: (_) {
                    setState(() {
                      _groupBy = entry.key;
                    });
                    _loadData();
                  },
                  selectedColor: Theme.of(context).colorScheme.primary,
                  labelStyle: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimary
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Switch(
                  value: _postedOnly,
                  onChanged: (value) {
                    setState(() {
                      _postedOnly = value;
                    });
                    _loadData();
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  isArabic
                      ? 'عرض القيود المرحّلة فقط'
                      : 'Show posted entries only',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final items = (_response?['items'] as List?) ?? const [];
    final txItems = (_transactionTypeResponse?['items'] as List?) ?? const [];

    num totalCash = 0;
    num totalCashIn = 0;
    num totalCashOut = 0;
    num totalWeight24 = 0;
    num totalWeightMain = 0;
    num totalWeightOutMain = 0;
    num totalWeightInMain = 0;

    // 🆕 مؤشرات سلوكية: مبيعات ذهب + شراء من عميل (كسر)
    // تعتمد على تجميع transaction_type حتى لا تتأثر بنقص أبعاد الفرع/الموظف.
    num totalGoldSalesMain = 0;
    num totalGoldBoughtFromCustomersMain = 0;

    for (final raw in items) {
      if (raw is Map<String, dynamic>) {
        totalCash += _asDouble(raw['amount_cash']);
        totalCashIn += _asDouble(raw['cash_in']);
        totalCashOut += _asDouble(raw['cash_out']);
        totalWeight24 += _asDouble(raw['weight_24k']);
        totalWeightMain += _asDouble(raw['weight_main']);
        totalWeightOutMain += _asDouble(raw['weight_out_main']);
        totalWeightInMain += _asDouble(raw['weight_in_main']);
      }
    }

    for (final raw in txItems) {
      if (raw is Map<String, dynamic>) {
        final category = (raw['transaction_category'] ?? raw['group'] ?? '')
            .toString();
        if (category == 'بيع') {
          // مبيعات الذهب = وزن خارج من المخزون لمعاملات البيع
          totalGoldSalesMain += _asDouble(raw['weight_out_main']);
        } else if (category == 'شراء من عميل') {
          // شراء كسر من العملاء = وزن داخل للمخزون
          totalGoldBoughtFromCustomersMain += _asDouble(raw['weight_in_main']);
        }
      }
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'ملخص الفترة' : 'Period Summary',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي الوزن بالعيار الرئيسي'
                        : 'Total Main-Karat Weight',
                    value: _formatWeight(totalWeightMain),
                    icon: Icons.balance,
                    color: Colors.blue.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic ? 'إجمالي الوزن 24k' : 'Total 24k Weight',
                    value: _formatWeight(totalWeight24),
                    icon: Icons.scale,
                    color: Colors.amber.shade700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي التدفق النقدي'
                        : 'Total Cash Flow',
                    value: _formatCurrency(totalCash),
                    icon: Icons.payments,
                    color: Colors.green.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'الوزن الخارج (العيار الرئيسي)'
                        : 'Outbound Weight (Main)',
                    value: _formatWeight(totalWeightOutMain),
                    icon: Icons.north_east,
                    color: Colors.red.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'الوزن الداخل (العيار الرئيسي)'
                        : 'Inbound Weight (Main)',
                    value: _formatWeight(totalWeightInMain),
                    icon: Icons.south_west,
                    color: Colors.green.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي المقبوضات النقدية'
                        : 'Total Cash Inflows',
                    value: _formatCurrency(totalCashIn),
                    icon: Icons.arrow_downward,
                    color: Colors.blue.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي المدفوعات النقدية'
                        : 'Total Cash Outflows',
                    value: _formatCurrency(totalCashOut),
                    icon: Icons.arrow_upward,
                    color: Colors.red.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي مبيعات الذهب (وزن خارج)'
                        : 'Total Gold Sales (Outbound)',
                    value: _formatWeight(totalGoldSalesMain),
                    icon: Icons.shopping_cart_checkout,
                    color: Colors.deepOrange.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildSummaryTile(
                    title: isArabic
                        ? 'إجمالي الذهب المشتَرى من العملاء'
                        : 'Total Gold Bought from Customers',
                    value: _formatWeight(totalGoldBoughtFromCustomersMain),
                    icon: Icons.shopping_cart,
                    color: Colors.purple.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryTile({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                cu.SarAwareText(
                  value,
                  isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
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
    );
  }

  Widget _buildBarChartCard(bool isArabic) {
    final items = (_response?['items'] as List?) ?? const [];

    if (items.isEmpty) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              isArabic
                  ? 'لا توجد بيانات كافية لعرض الرسم البياني'
                  : 'Not enough data to display chart',
            ),
          ),
        ),
      );
    }

    final barSpots = <BarChartGroupData>[];
    final labels = <int, String>{};

    double maxAbsValue = 0;

    for (var i = 0; i < items.length; i++) {
      final raw = items[i];
      if (raw is! Map<String, dynamic>) continue;
      // A transaction type's group reads by its name (شراء كسر …); other groups as given.
      final label = invoiceTypeLabelOf(raw['group']);

      double value;
      if (_chartMetric == 'amount_cash') {
        value = _asDouble(raw['amount_cash']).abs();
      } else if (_chartMetric == 'cash_in') {
        value = _asDouble(raw['cash_in']);
      } else if (_chartMetric == 'cash_out') {
        value = _asDouble(raw['cash_out']);
      } else if (_chartMetric == 'weight_out_main') {
        value = _asDouble(raw['weight_out_main']);
      } else if (_chartMetric == 'weight_in_main') {
        value = _asDouble(raw['weight_in_main']);
      } else {
        value = _asDouble(raw['weight_main']);
      }

      final absValue = value.abs();
      maxAbsValue = absValue > maxAbsValue ? absValue : maxAbsValue;

      barSpots.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: value,
              color: _chartMetric == 'amount_cash'
                  ? Colors.teal.shade600
                  : _chartMetric == 'cash_in'
                  ? Colors.green.shade600
                  : _chartMetric == 'cash_out'
                  ? Colors.red.shade600
                  : _chartMetric == 'weight_out_main'
                  ? Colors.red.shade600
                  : _chartMetric == 'weight_in_main'
                  ? Colors.green.shade700
                  : Colors.amber.shade700,
              width: 14,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ),
      );
      labels[i] = label;
    }

    if (maxAbsValue == 0) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              isArabic
                  ? 'لا توجد قيم كافية لعرض الرسم البياني'
                  : 'No meaningful values to display chart',
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isArabic ? 'الرسم التحليلي' : 'Analytical Chart',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ToggleButtons(
                  isSelected: [
                    _chartMetric == 'weight_main',
                    _chartMetric == 'weight_out_main',
                    _chartMetric == 'weight_in_main',
                    _chartMetric == 'cash_in',
                    _chartMetric == 'cash_out',
                    _chartMetric == 'amount_cash',
                  ],
                  onPressed: (index) {
                    setState(() {
                      if (index == 0) {
                        _chartMetric = 'weight_main';
                      } else if (index == 1) {
                        _chartMetric = 'weight_out_main';
                      } else if (index == 2) {
                        _chartMetric = 'weight_in_main';
                      } else if (index == 3) {
                        _chartMetric = 'cash_in';
                      } else if (index == 4) {
                        _chartMetric = 'cash_out';
                      } else {
                        _chartMetric = 'amount_cash';
                      }
                    });
                    _loadData();
                  },
                  borderRadius: BorderRadius.circular(20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        isArabic
                            ? 'الوزن الصافي (العيار الرئيسي)'
                            : 'Net Weight (Main)',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        isArabic
                            ? 'الوزن الخارج (عيار رئيسي)'
                            : 'Outbound (Main)',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        isArabic
                            ? 'الوزن الداخل (عيار رئيسي)'
                            : 'Inbound (Main)',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(isArabic ? 'الكاش الداخل' : 'Cash In'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(isArabic ? 'الكاش الخارج' : 'Cash Out'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(isArabic ? 'صافي الكاش' : 'Net Cash'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: BarChart(
                BarChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                      ),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          final label = labels[index] ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: barSpots,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// رسم بياني مقارن بين:
  /// - إجمالي مبيعات الذهب (بيع)
  /// - إجمالي الذهب المشتَرى من العملاء (شراء من عميل)
  Widget _buildSalesVsScrapChartCard(bool isArabic) {
    final items = (_transactionTypeResponse?['items'] as List?) ?? const [];

    if (items.isEmpty) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              isArabic
                  ? 'لا توجد بيانات كافية للمقارنة بين البيع والشراء من العملاء'
                  : 'Not enough data to compare sales vs customer purchases',
            ),
          ),
        ),
      );
    }

    num totalGoldSalesMain = 0;
    num totalGoldBoughtFromCustomersMain = 0;

    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      final category = (raw['transaction_category'] ?? raw['group'] ?? '')
          .toString();
      if (category == 'بيع') {
        totalGoldSalesMain += _asDouble(raw['weight_out_main']);
      } else if (category == 'شراء من عميل') {
        totalGoldBoughtFromCustomersMain += _asDouble(raw['weight_in_main']);
      }
    }

    if (totalGoldSalesMain == 0 && totalGoldBoughtFromCustomersMain == 0) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              isArabic
                  ? 'لا توجد بيانات مبيعات أو مشتريات من العملاء لعرض المقارنة'
                  : 'No sales or customer purchase data available for comparison',
            ),
          ),
        ),
      );
    }

    final barGroups = <BarChartGroupData>[];
    final labels = <int, String>{};

    double maxValue = 0;

    final totalSales = totalGoldSalesMain.toDouble();
    final totalScrap = totalGoldBoughtFromCustomersMain.toDouble();

    maxValue = [totalSales, totalScrap].reduce((a, b) => a > b ? a : b);

    barGroups.add(
      BarChartGroupData(
        x: 0,
        barRods: [
          BarChartRodData(
            toY: totalSales,
            color: Colors.deepOrange.shade600,
            width: 18,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );
    labels[0] = isArabic ? 'ذهب مباع' : 'Gold Sold';

    barGroups.add(
      BarChartGroupData(
        x: 1,
        barRods: [
          BarChartRodData(
            toY: totalScrap,
            color: Colors.purple.shade600,
            width: 18,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );
    labels[1] = isArabic
        ? 'ذهب مشتَرى من العملاء'
        : 'Gold Bought from Customers';

    if (maxValue == 0) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              isArabic
                  ? 'لا توجد قيم كافية لعرض المقارنة'
                  : 'No meaningful values to display comparison',
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic
                  ? 'مقارنة الذهب المشتَرى من العملاء مقابل الذهب المباع'
                  : 'Customer Scrap vs Gold Sales Comparison',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: BarChart(
                BarChartData(
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                      ),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          final label = labels[index] ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: barGroups,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTableCard(bool isArabic) {
    final items = (_response?['items'] as List?) ?? const [];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'التفاصيل التحليلية' : 'Analytical Breakdown',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'المجموعة' : 'Group')),
                  DataColumn(
                    label: Text(isArabic ? 'الوزن 24k' : '24k Weight (grams)'),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'الوزن بالعيار الرئيسي' : 'Main-Karat Weight',
                    ),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'الخارج 24k' : 'Outbound 24k'),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'الخارج (عيار رئيسي)' : 'Outbound (Main)',
                    ),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'الداخل 24k' : 'Inbound 24k'),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'الداخل (عيار رئيسي)' : 'Inbound (Main)',
                    ),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'الكاش الداخل' : 'Cash In'),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'الكاش الخارج' : 'Cash Out'),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'صافي التدفق النقدي' : 'Net Cash Flow',
                    ),
                  ),
                  DataColumn(
                    numeric: true,
                    label: Text(isArabic ? 'عدد السطور' : 'Line Count'),
                  ),
                ],
                rows: [
                  for (final raw in items)
                    if (raw is Map<String, dynamic>)
                      DataRow(
                        cells: [
                          DataCell(Text(invoiceTypeLabelOf(raw['group']))),
                          DataCell(
                            Text(_formatWeight(_asDouble(raw['weight_24k']))),
                          ),
                          DataCell(
                            Text(_formatWeight(_asDouble(raw['weight_main']))),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(_asDouble(raw['weight_out_24k'])),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(_asDouble(raw['weight_out_main'])),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(_asDouble(raw['weight_in_24k'])),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(_asDouble(raw['weight_in_main'])),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatCurrency(_asDouble(raw['cash_in'])),
                              style: TextStyle(color: Colors.green.shade700),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatCurrency(_asDouble(raw['cash_out'])),
                              style: TextStyle(color: Colors.red.shade700),
                            ),
                          ),
                          DataCell(
                            Builder(
                              builder: (_) {
                                var cash = _asDouble(raw['amount_cash']);
                                if (cash.abs() < 0.005) {
                                  cash = 0.0;
                                }
                                Color? color;
                                if (cash > 0) {
                                  color = Colors.green.shade700;
                                } else if (cash < 0) {
                                  color = Colors.red.shade700;
                                } else {
                                  color = Colors.grey.shade700;
                                }
                                return Text(
                                  _formatCurrency(cash),
                                  style: TextStyle(color: color),
                                );
                              },
                            ),
                          ),
                          DataCell(Text((raw['line_count'] ?? 0).toString())),
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
}
