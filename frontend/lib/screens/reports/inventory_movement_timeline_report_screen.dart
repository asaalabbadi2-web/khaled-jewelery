import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

class InventoryMovementTimelineReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const InventoryMovementTimelineReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<InventoryMovementTimelineReportScreen> createState() =>
      _InventoryMovementTimelineReportScreenState();
}

class _InventoryMovementTimelineReportScreenState
    extends State<InventoryMovementTimelineReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  DateTimeRange _selectedRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 29)),
    end: DateTime.now(),
  );

  final Set<num> _selectedKarats = <num>{};
  final Set<int> _selectedOffices = <int>{};
  final List<num> _karatOptions = [18, 21, 22, 24];
  final List<int> _movementLimitOptions = [50, 100, 200, 300, 400, 500];
  final List<String> _intervalOptions = ['day', 'week', 'month'];

  String _groupInterval = 'day';
  bool _includeUnposted = false;
  bool _includeReturns = true;
  int _movementsLimit = 200;

  List<Map<String, dynamic>> _availableOffices = [];
  bool _isLoadingOffices = false;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;
  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;

  @override
  void initState() {
    super.initState();
    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );
    _weightFormat = NumberFormat('#,##0.000');
    _loadReport();
    _loadOffices();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    if (settings.currencySymbol != _currencySymbol ||
        settings.decimalPlaces != _currencyDecimals ||
        settings.mainKarat != _mainKarat) {
      setState(() {
        _currencySymbol = settings.currencySymbol;
        _currencyDecimals = settings.decimalPlaces;
        _mainKarat = settings.mainKarat;
        _currencyFormat = NumberFormat.currency(
          locale: widget.isArabic ? 'ar' : 'en',
          symbol: _currencySymbol,
          decimalDigits: _currencyDecimals,
        );
      });
    }
  }

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await widget.api.getInventoryMovementReport(
        startDate: _selectedRange.start,
        endDate: _selectedRange.end,
        groupInterval: _groupInterval,
        includeUnposted: _includeUnposted,
        includeReturns: _includeReturns,
        karats: _selectedKarats.isEmpty ? null : _selectedKarats.toList(),
        officeIds: _selectedOffices.isEmpty ? null : _selectedOffices.toList(),
        movementsLimit: _movementsLimit,
      );

      if (!mounted) return;
      setState(() => _report = response);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loadOffices() async {
    setState(() => _isLoadingOffices = true);
    try {
      final data = await widget.api.getOffices(activeOnly: true);
      if (!mounted) return;
      setState(() {
        _availableOffices = data
            .whereType<Map<String, dynamic>>()
            .map(
              (office) => {
                'id': office['id'] is int
                    ? office['id'] as int
                    : int.tryParse('${office['id']}') ?? 0,
                'name': office['name'] ?? office['office_code'] ?? 'Office',
              },
            )
            .where((office) => (office['id'] as int) != 0)
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _availableOffices = const []);
    } finally {
      if (mounted) {
        setState(() => _isLoadingOffices = false);
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final result = await showDateRangePicker(
      context: context,
      locale: widget.isArabic ? const Locale('ar') : const Locale('en'),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _selectedRange,
    );

    if (result != null) {
      setState(() => _selectedRange = result);
      _loadReport();
    }
  }

  void _clearFilters() {
    setState(() {
      _selectedRange = DateTimeRange(
        start: DateTime.now().subtract(const Duration(days: 29)),
        end: DateTime.now(),
      );
      _groupInterval = 'day';
      _includeUnposted = false;
      _includeReturns = true;
      _movementsLimit = 200;
      _selectedKarats.clear();
      _selectedOffices.clear();
    });
    _loadReport();
  }

  List<Map<String, dynamic>> get _timelineEntries {
    final raw = _report?['timeline'];
    if (raw is List) {
      return raw.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  List<Map<String, dynamic>> get _movementEntries {
    final raw = _report?['movements'];
    if (raw is List) {
      return raw.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  Map<String, dynamic> get _summary {
    final raw = _report?['summary'];
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return const {};
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  String _formatCurrency(num value) => _currencyFormat.format(value);

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isArabic ? 'حركة المخزون الزمنية' : 'Inventory Movement Timeline',
          ),
          actions: [
            IconButton(
              tooltip: isArabic ? 'تحديث' : 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _isLoading ? null : _loadReport,
            ),
          ],
        ),
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _buildErrorState(isArabic)
              : _buildContent(isArabic),
        ),
      ),
    );
  }

  Widget _buildErrorState(bool isArabic) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 12),
          Text(
            isArabic ? 'تعذّر تحميل التقرير' : 'Failed to load report',
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
            onPressed: _loadReport,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isArabic) {
    return RefreshIndicator(
      onRefresh: _loadReport,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildFiltersCard(isArabic),
          const SizedBox(height: 16),
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildTimelineChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTimelineTableCard(isArabic),
          const SizedBox(height: 16),
          _buildMovementsCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText =
        '${DateFormat('yyyy-MM-dd').format(_selectedRange.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange.end)}';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: isArabic
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                Text(
                  isArabic ? 'خيارات التقرير' : 'Report Filters',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.refresh),
                  label: Text(isArabic ? 'إعادة الضبط' : 'Reset'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.date_range),
                  label: Text(rangeText),
                ),
                Wrap(
                  spacing: 8,
                  children: _intervalOptions.map((interval) {
                    final selected = _groupInterval == interval;
                    return ChoiceChip(
                      label: Text(_localizedInterval(interval, isArabic)),
                      selected: selected,
                      onSelected: (value) {
                        if (!value || selected) return;
                        setState(() => _groupInterval = interval);
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                FilterChip(
                  label: Text(
                    isArabic ? 'تضمين غير المرحلة' : 'Include unposted',
                  ),
                  selected: _includeUnposted,
                  onSelected: (value) {
                    setState(() => _includeUnposted = value);
                    _loadReport();
                  },
                ),
                FilterChip(
                  label: Text(isArabic ? 'تضمين المرتجعات' : 'Include returns'),
                  selected: _includeReturns,
                  onSelected: (value) {
                    setState(() => _includeReturns = value);
                    _loadReport();
                  },
                ),
                DropdownButton<int>(
                  value: _movementsLimit,
                  items: _movementLimitOptions
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(
                            isArabic ? 'آخر $value حركة' : 'Last $value moves',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _movementsLimit = value);
                    _loadReport();
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: _karatOptions.map((karat) {
                    final selected = _selectedKarats.contains(karat);
                    return FilterChip(
                      label: Text(isArabic ? 'عيار $karat' : '${karat}K'),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedKarats.add(karat);
                          } else {
                            _selectedKarats.remove(karat);
                          }
                        });
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                if (_isLoadingOffices)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_availableOffices.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: _availableOffices.map((office) {
                      final officeId = office['id'] as int;
                      final officeName =
                          office['name']?.toString() ??
                          (isArabic ? 'مكتب' : 'Office');
                      final selected = _selectedOffices.contains(officeId);
                      return FilterChip(
                        label: Text(officeName),
                        selected: selected,
                        avatar: selected
                            ? const Icon(Icons.check, size: 16)
                            : const Icon(Icons.store, size: 16),
                        onSelected: (value) {
                          setState(() {
                            if (value) {
                              _selectedOffices.add(officeId);
                            } else {
                              _selectedOffices.remove(officeId);
                            }
                          });
                          _loadReport();
                        },
                      );
                    }).toList(),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final summary = _summary;
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.timeline,
        message: isArabic ? 'لا توجد بيانات للحركة.' : 'No movement data.',
      );
    }

    final metrics = [
      _SummaryMetric(
        icon: Icons.call_made,
        color: Colors.green,
        title: isArabic ? 'الوزن الوارد' : 'Inbound Weight',
        value: _formatWeight(
          _asDouble(summary['total_inbound_weight_main_karat']),
        ),
      ),
      _SummaryMetric(
        icon: Icons.call_received,
        color: Colors.deepOrange,
        title: isArabic ? 'الوزن الصادر' : 'Outbound Weight',
        value: _formatWeight(
          _asDouble(summary['total_outbound_weight_main_karat']),
        ),
      ),
      _SummaryMetric(
        icon: Icons.balance,
        color: Colors.blueGrey,
        title: isArabic ? 'صافي الوزن' : 'Net Weight',
        value: _formatWeight(_asDouble(summary['net_weight_main_karat'])),
      ),
      _SummaryMetric(
        icon: Icons.attach_money,
        color: Colors.blue,
        title: isArabic ? 'القيمة الواردة' : 'Inbound Value',
        value: _formatCurrency(_asDouble(summary['total_inbound_value'])),
      ),
      _SummaryMetric(
        icon: Icons.money_off,
        color: Colors.purple,
        title: isArabic ? 'القيمة الصادرة' : 'Outbound Value',
        value: _formatCurrency(_asDouble(summary['total_outbound_value'])),
      ),
      _SummaryMetric(
        icon: Icons.trending_up,
        color: Colors.teal,
        title: isArabic ? 'صافي القيمة' : 'Net Value',
        value: _formatCurrency(_asDouble(summary['net_value'])),
      ),
    ];

    final docStats = [
      _SummaryMetric(
        icon: Icons.receipt_long,
        color: Colors.indigo,
        title: isArabic ? 'مستندات الوارد' : 'Inbound Docs',
        value: '${summary['inbound_documents'] ?? 0}',
      ),
      _SummaryMetric(
        icon: Icons.local_shipping,
        color: Colors.brown,
        title: isArabic ? 'مستندات الصادر' : 'Outbound Docs',
        value: '${summary['outbound_documents'] ?? 0}',
      ),
      _SummaryMetric(
        icon: Icons.calendar_month,
        color: Colors.cyan,
        title: isArabic ? 'أيام الفترة' : 'Period days',
        value: '${summary['period_days'] ?? 0}',
      ),
    ];

    final direction = (summary['net_direction'] ?? 'balanced').toString();
    final directionLabel = _localizedDirection(direction, isArabic);

    return Card(
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
                Icon(Icons.summarize, color: Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(
                  isArabic ? 'ملخص الحركة' : 'Movement Summary',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                Chip(
                  avatar: const Icon(Icons.compare_arrows, size: 18),
                  label: Text(directionLabel),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: metrics
                  .map(
                    (metric) =>
                        _SummaryTile(metric: metric, isArabic: isArabic),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: docStats
                  .map(
                    (metric) =>
                        _SummaryTile(metric: metric, isArabic: isArabic),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineChartCard(bool isArabic) {
    final timeline = _timelineEntries;
    if (timeline.isEmpty) {
      return _buildEmptyState(
        icon: Icons.area_chart,
        message: isArabic ? 'لا توجد نقاط للرسم.' : 'No timeline data.',
      );
    }

    final inboundSpots = <FlSpot>[];
    final outboundSpots = <FlSpot>[];
    double maxY = 0;

    for (var i = 0; i < timeline.length; i++) {
      final inboundWeight = _asDouble(timeline[i]['inbound_weight_main_karat']);
      final outboundWeight = _asDouble(
        timeline[i]['outbound_weight_main_karat'],
      );
      inboundSpots.add(FlSpot(i.toDouble(), inboundWeight));
      outboundSpots.add(FlSpot(i.toDouble(), outboundWeight));
      maxY = math.max(maxY, math.max(inboundWeight, outboundWeight));
    }

    if (maxY <= 0) maxY = 1;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'المخطط الزمني للحركة' : 'Timeline chart',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 280,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(0, timeline.length - 1).toDouble(),
                  minY: 0,
                  maxY: maxY * 1.2,
                  gridData: FlGridData(
                    show: true,
                    horizontalInterval: maxY / 4,
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: const Border(
                      bottom: BorderSide(color: Colors.grey),
                      left: BorderSide(color: Colors.grey),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 42,
                        getTitlesWidget: (value, meta) => Text(
                          _weightFormat.format(value),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 48,
                        getTitlesWidget: (value, meta) {
                          final index = value.round();
                          if (index < 0 || index >= timeline.length) {
                            return const SizedBox();
                          }
                          final label =
                              timeline[index]['label']?.toString() ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: RotatedBox(
                              quarterTurns: 1,
                              child: Text(
                                label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  lineBarsData: [
                    _buildLineData(
                      color: Colors.green,
                      spots: inboundSpots,
                      label: isArabic ? 'وارد' : 'Inbound',
                    ),
                    _buildLineData(
                      color: Colors.orange,
                      spots: outboundSpots,
                      label: isArabic ? 'صادر' : 'Outbound',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  LineChartBarData _buildLineData({
    required Color color,
    required List<FlSpot> spots,
    required String label,
  }) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: 3,
      dotData: FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        color: color.withValues(alpha: 0.15),
      ),
    );
  }

  Widget _buildTimelineTableCard(bool isArabic) {
    final timeline = _timelineEntries;
    if (timeline.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'دفتر زمني' : 'Timeline ledger',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الفترة' : 'Period')),
                  DataColumn(
                    label: Text(isArabic ? 'وارد (جم)' : 'Inbound (g)'),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'صادر (جم)' : 'Outbound (g)'),
                  ),
                  DataColumn(label: Text(isArabic ? 'صافي (جم)' : 'Net (g)')),
                  DataColumn(label: Text(isArabic ? 'المستندات' : 'Documents')),
                ],
                rows: timeline.map((entry) {
                  final inbound = _formatWeight(
                    _asDouble(entry['inbound_weight_main_karat']),
                  );
                  final outbound = _formatWeight(
                    _asDouble(entry['outbound_weight_main_karat']),
                  );
                  final net = _formatWeight(
                    _asDouble(entry['net_weight_main_karat']),
                  );
                  final docs =
                      '${entry['inbound_documents'] ?? 0}/${entry['outbound_documents'] ?? 0}';
                  return DataRow(
                    cells: [
                      DataCell(Text(entry['label']?.toString() ?? '-')),
                      DataCell(Text(inbound)),
                      DataCell(Text(outbound)),
                      DataCell(Text(net)),
                      DataCell(Text(docs)),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMovementsCard(bool isArabic) {
    final movements = _movementEntries;
    if (movements.isEmpty) {
      return _buildEmptyState(
        icon: Icons.list_alt,
        message: isArabic
            ? 'لا توجد حركات لعرضها ضمن الحد الحالي.'
            : 'No ledger items within the current limit.',
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'دفتر الحركة' : 'Movement ledger',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: movements.length,
              separatorBuilder: (context, index) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final entry = movements[index];
                final direction = (entry['direction'] ?? 'inbound').toString();
                final isInbound = direction == 'inbound';
                final icon = isInbound
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded;
                final color = isInbound ? Colors.green : Colors.orange;
                final party =
                    entry['party_name']?.toString() ??
                    (isArabic ? 'غير معروف' : 'Unknown');

                DateTime? parsedDate;
                final rawDate = entry['date']?.toString();
                if (rawDate != null) {
                  try {
                    parsedDate = DateTime.parse(rawDate);
                  } catch (_) {
                    parsedDate = null;
                  }
                }

                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(icon, color: color),
                  ),
                  title: Text(
                    '${entry['invoice_type'] ?? ''} • ${entry['office_name'] ?? (isArabic ? 'المكتب الرئيسي' : 'Main Office')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: isArabic
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic ? 'العميل/المورد: $party' : 'Party: $party',
                      ),
                      Text(
                        '${_formatWeight(_asDouble(entry['weight_main_karat']))} · ${_formatCurrency(_asDouble(entry['value']))}',
                      ),
                      Text(
                        '${isArabic ? 'العناصر' : 'Items'}: ${(entry['sample_items'] as List?)?.join(', ') ?? '-'}',
                      ),
                    ],
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        parsedDate != null
                            ? DateFormat('yyyy-MM-dd HH:mm').format(parsedDate)
                            : '-',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Chip(
                        label: Text(
                          '${isArabic ? 'خطوط' : 'Lines'} ${entry['line_count']}',
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _localizedInterval(String interval, bool isArabic) {
    switch (interval) {
      case 'week':
        return isArabic ? 'أسبوعي' : 'Weekly';
      case 'month':
        return isArabic ? 'شهري' : 'Monthly';
      default:
        return isArabic ? 'يومي' : 'Daily';
    }
  }

  String _localizedDirection(String direction, bool isArabic) {
    switch (direction) {
      case 'inbound':
        return isArabic ? 'وارد أعلى' : 'Net inbound';
      case 'outbound':
        return isArabic ? 'صادر أعلى' : 'Net outbound';
      default:
        return isArabic ? 'متوازن' : 'Balanced';
    }
  }
}

class _SummaryMetric {
  final IconData icon;
  final Color color;
  final String title;
  final String value;

  _SummaryMetric({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
  });
}

class _SummaryTile extends StatelessWidget {
  final _SummaryMetric metric;
  final bool isArabic;

  const _SummaryTile({required this.metric, required this.isArabic});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            backgroundColor: metric.color.withValues(alpha: 0.15),
            child: Icon(metric.icon, color: metric.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: isArabic
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  metric.title,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  metric.value,
                  style: const TextStyle(
                    fontSize: 16,
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
}
