import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../api_service.dart';

class GoldPositionReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const GoldPositionReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<GoldPositionReportScreen> createState() => _GoldPositionReportScreenState();
}

class _GoldPositionReportScreenState extends State<GoldPositionReportScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _data;

  bool _includeZero = false;
  double _minVariance = 0.1;
  final Set<String> _selectedSafeTypes = <String>{};
  final Set<num> _selectedKarats = <num>{};
  final Set<int> _selectedOfficeIds = <int>{};

  final TextEditingController _varianceController = TextEditingController();
  final TextEditingController _officeController = TextEditingController();

  late final NumberFormat _weightFormat;
  late final NumberFormat _currencyFormat;

  final List<_SafeTypeOption> _safeTypeOptions = const [
    _SafeTypeOption('cash', Icons.savings_outlined),
    _SafeTypeOption('bank', Icons.account_balance_outlined),
    _SafeTypeOption('gold', Icons.scale_outlined),
    _SafeTypeOption('check', Icons.receipt_long),
  ];

  final List<num> _karatOptions = const [18, 21, 22, 24];

  @override
  void initState() {
    super.initState();
    _varianceController.text = _minVariance.toStringAsFixed(2);
    _weightFormat = NumberFormat('#,##0.000');
    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: 'ر.س',
      decimalDigits: 2,
    );
    _loadReport();
  }

  @override
  void dispose() {
    _varianceController.dispose();
    _officeController.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _summary =>
      (_data?['summary'] as Map<String, dynamic>?) ?? const {};

  List<Map<String, dynamic>> _asList(String key) {
    final raw = _data?[key];
    if (raw is List) {
      return raw.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getGoldPositionReport(
        includeZero: _includeZero,
        minVariance: _minVariance,
        karats: _selectedKarats.isEmpty ? null : _selectedKarats.toList(),
        safeTypes: _selectedSafeTypes.isEmpty ? null : _selectedSafeTypes.toList(),
        officeIds: _selectedOfficeIds.isEmpty ? null : _selectedOfficeIds.toList(),
      );
      if (!mounted) return;
      setState(() => _data = result);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err.toString());
    } finally {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  double _weightValue(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  String _weightLabel(dynamic value) => _weightFormat.format(_weightValue(value));

  String _asString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  String _currencyLabel(dynamic value) {
    final double parsed = _weightValue(value);
    return _currencyFormat.format(parsed);
  }

  void _applyVariance() {
    final parsed = double.tryParse(_varianceController.text.replaceAll(',', '.'));
    if (parsed == null) return;
    setState(() => _minVariance = parsed.clamp(0.0, 1000.0));
    _loadReport();
  }

  void _applyOfficeFilter() {
    final trimmed = _officeController.text.trim();
    final ids = <int>{};
    if (trimmed.isNotEmpty) {
      for (final token in trimmed.split(',')) {
        final cleaned = token.trim();
        if (cleaned.isEmpty) continue;
        final parsed = int.tryParse(cleaned);
        if (parsed != null) ids.add(parsed);
      }
    }
    setState(() => _selectedOfficeIds
      ..clear()
      ..addAll(ids));
    _loadReport();
  }

  Widget _buildError(bool isArabic) {
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
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
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

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'مركز الذهب' : 'Gold Position'),
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
                  ? _buildError(isArabic)
                  : RefreshIndicator(
                      onRefresh: _loadReport,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          _buildFiltersCard(isArabic),
                          const SizedBox(height: 16),
                          _buildSummaryCard(isArabic),
                          const SizedBox(height: 16),
                          _buildDistributionCard(isArabic),
                          const SizedBox(height: 16),
                          _buildTopPositionsCard(isArabic),
                          const SizedBox(height: 16),
                          _buildAccountsTable(isArabic),
                          const SizedBox(height: 16),
                          _buildSafeBoxesTable(isArabic),
                          const SizedBox(height: 16),
                          _buildOfficesTable(isArabic),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'خيارات التقرير' : 'Report filters',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: Text(isArabic ? 'إظهار الأرصدة الصفرية' : 'Show zero balances'),
                  selected: _includeZero,
                  onSelected: (value) {
                    setState(() => _includeZero = value);
                    _loadReport();
                  },
                ),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _varianceController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: isArabic ? 'حد التباين (جم)' : 'Variance (g)',
                    ),
                    onSubmitted: (_) => _applyVariance(),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _officeController,
                    keyboardType: TextInputType.text,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: isArabic ? 'مكاتب (IDs)' : 'Office IDs',
                      helperText: isArabic ? 'مفصولة بفواصل' : 'Comma separated',
                    ),
                    onSubmitted: (_) => _applyOfficeFilter(),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: _safeTypeOptions.map((option) {
                    final selected = _selectedSafeTypes.contains(option.code);
                    return FilterChip(
                      avatar: Icon(option.icon, size: 18),
                      label: Text(_localizedSafeType(option.code, isArabic)),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedSafeTypes.add(option.code);
                          } else {
                            _selectedSafeTypes.remove(option.code);
                          }
                        });
                        _loadReport();
                      },
                    );
                  }).toList(),
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
                if (_selectedOfficeIds.isNotEmpty)
                  InputChip(
                    label: Text(
                      isArabic
                          ? 'مكاتب محددة (${_selectedOfficeIds.join(', ')})'
                          : 'Offices (${_selectedOfficeIds.join(', ')})',
                    ),
                    onDeleted: () {
                      setState(() => _selectedOfficeIds.clear());
                      _officeController.clear();
                      _loadReport();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _localizedSafeType(String code, bool isArabic) {
    switch (code) {
      case 'cash':
        return isArabic ? 'صندوق نقدي' : 'Cash Safe';
      case 'bank':
        return isArabic ? 'خزينة بنكية' : 'Bank Safe';
      case 'gold':
        return isArabic ? 'خزينة ذهب' : 'Gold Safe';
      case 'check':
        return isArabic ? 'شيكات' : 'Checks';
      default:
        return code;
    }
  }

  Widget _buildSummaryCard(bool isArabic) {
    if (_summary.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.analytics_outlined,
        message: isArabic ? 'لا بيانات حتى الآن' : 'No data available yet',
      );
    }

    final tiles = [
      _SummaryTileData(
        title: isArabic ? 'إجمالي الذهب (عيار رئيسي)' : 'Total Gold (Main Karat)',
        value: _weightLabel(_summary['total_main_karat']),
        icon: Icons.balance,
        color: Colors.amber.shade700,
      ),
      _SummaryTileData(
        title: isArabic ? 'مراكز دائنة' : 'Long Positions',
        value: _weightLabel(_summary['long_position_main']),
        icon: Icons.trending_up,
        color: Colors.green.shade600,
      ),
      _SummaryTileData(
        title: isArabic ? 'مراكز مدينة' : 'Short Positions',
        value: _weightLabel(_summary['short_position_main']),
        icon: Icons.trending_down,
        color: Colors.red.shade600,
      ),
      _SummaryTileData(
        title: isArabic ? 'صافي المركز' : 'Net Position',
        value: _weightLabel(_summary['net_position_main']),
        icon: Icons.compare_arrows,
        color: Colors.blue.shade600,
      ),
      if (_summary['estimated_value_sar'] != null)
        _SummaryTileData(
          title: isArabic ? 'القيمة التقديرية' : 'Estimated Value',
          value: _currencyLabel(_summary['estimated_value_sar']),
          icon: Icons.attach_money,
          color: Colors.teal.shade600,
        ),
    ];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: tiles
              .map((tile) => SizedBox(
                    width: 210,
                    child: _SummaryTile(data: tile, isArabic: isArabic),
                  ))
              .toList(),
        ),
      ),
    );
  }

  Widget _buildDistributionCard(bool isArabic) {
    final distribution = _summary['distribution'];
    if (distribution is! List || distribution.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.pie_chart_outline,
        message: isArabic ? 'لا يمكن رسم التوزيع حالياً' : 'No distribution data yet',
      );
    }

    final total = distribution.fold<double>(
      0,
      (prev, item) => prev + _weightValue(item['normalized_main_karat']),
    );

    if (total == 0) {
      return _buildEmptyStateCard(
        icon: Icons.pie_chart_outline,
        message: isArabic ? 'لا يمكن رسم التوزيع حالياً' : 'No distribution data yet',
      );
    }

    final sections = <PieChartSectionData>[];
    final colors = [
      Colors.amber.shade600,
      Colors.orange.shade700,
      Colors.blueGrey.shade400,
      Colors.deepOrange.shade400,
    ];

    for (var i = 0; i < distribution.length; i++) {
      final item = distribution[i];
      final value = _weightValue(item['normalized_main_karat']);
      if (value <= 0) continue;
      sections.add(
        PieChartSectionData(
          color: colors[i % colors.length],
          value: value,
          title: '${((value / total) * 100).toStringAsFixed(1)}%',
          radius: 60,
          titleStyle: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'توزيع الذهب حسب العيار' : 'Distribution by Karat',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 220,
              child: Row(
                children: [
                  Expanded(
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 4,
                        centerSpaceRadius: 48,
                        sections: sections,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment:
                        isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: distribution.map<Widget>((item) {
                      final color = colors[distribution.indexOf(item) % colors.length];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(width: 12, height: 12, color: color),
                            const SizedBox(width: 8),
                            Text(
                              '${item['karat']} • ${_weightLabel(item['raw_weight'])} جم',
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPositionsCard(bool isArabic) {
    final long = _asList('top_long_accounts');
    final short = _asList('top_short_accounts');

    if (long.isEmpty && short.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.swap_vert,
        message: isArabic ? 'لا توجد مراكز مميزة بعد' : 'No highlighted positions yet',
      );
    }

    Widget buildList(String title, List<Map<String, dynamic>> data, Color color) {
      return Expanded(
        child: Column(
          crossAxisAlignment:
              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            ...data.map((item) => ListTile(
                  dense: true,
                  leading: Icon(Icons.account_balance, color: color),
                  title: Text(item['name'] ?? ''),
                  subtitle: Text(item['account_number'] ?? ''),
                  trailing: Text(_weightLabel(item['total_main_karat'])),
                )),
          ],
        ),
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (long.isNotEmpty)
              buildList(
                isArabic ? 'أكبر مراكز دائنة' : 'Top Long Positions',
                long,
                Colors.green.shade600,
              ),
            if (short.isNotEmpty)
              buildList(
                isArabic ? 'أكبر مراكز مدينة' : 'Top Short Positions',
                short,
                Colors.red.shade600,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountsTable(bool isArabic) {
    final accounts = _asList('accounts');
    if (accounts.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.account_balance,
        message: isArabic ? 'لا توجد حسابات مطابقة' : 'No accounts match filters',
      );
    }

    return _buildDataTableCard(
      title: isArabic ? 'حسابات الميزانية الذهبية' : 'Gold Accounts',
      isArabic: isArabic,
      headers: [
        isArabic ? 'الحساب' : 'Account',
        isArabic ? 'الإجمالي (عيار رئيسي)' : 'Total (Main Karat)',
        '18K',
        '21K',
        '22K',
        '24K',
      ],
      rows: accounts.map((account) {
        final weights = account['weights'] as Map<String, dynamic>? ?? const {};
        final accountNumber = _asString(account['account_number']);
        final accountName = _asString(account['name']);
        return <String>[
          '$accountNumber — $accountName',
          _weightLabel(account['total_main_karat']),
          _weightLabel(weights['18k']),
          _weightLabel(weights['21k']),
          _weightLabel(weights['22k']),
          _weightLabel(weights['24k']),
        ];
      }).toList(),
    );
  }

  Widget _buildSafeBoxesTable(bool isArabic) {
    final safeBoxes = _asList('safe_boxes');
    if (safeBoxes.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.safety_check,
        message: isArabic ? 'لا توجد خزائن مطابقة' : 'No safe boxes match filters',
      );
    }

    return _buildDataTableCard(
      title: isArabic ? 'الخزائن الرئيسية' : 'Safe Boxes',
      isArabic: isArabic,
      headers: [
        isArabic ? 'الخزينة' : 'Safe Box',
        isArabic ? 'النوع' : 'Type',
        isArabic ? 'الإجمالي (عيار رئيسي)' : 'Total (Main Karat)',
        '18K',
        '21K',
        '22K',
        '24K',
      ],
      rows: safeBoxes.map((entry) {
        final weights = entry['weights'] as Map<String, dynamic>? ?? const {};
        final safeType = _localizedSafeType(entry['safe_type'] ?? '', isArabic);
        final safeName = _asString(entry['name']);
        return <String>[
          safeName,
          safeType,
          _weightLabel(entry['total_main_karat']),
          _weightLabel(weights['18k']),
          _weightLabel(weights['21k']),
          _weightLabel(weights['22k']),
          _weightLabel(weights['24k']),
        ];
      }).toList(),
    );
  }

  Widget _buildOfficesTable(bool isArabic) {
    final offices = _asList('offices');
    if (offices.isEmpty) {
      return _buildEmptyStateCard(
        icon: Icons.storefront,
        message: isArabic ? 'لا توجد مكاتب مطابقة' : 'No offices match filters',
      );
    }

    return _buildDataTableCard(
      title: isArabic ? 'أرصدة المكاتب' : 'Office Balances',
      isArabic: isArabic,
      headers: [
        isArabic ? 'المكتب' : 'Office',
        isArabic ? 'الإجمالي (عيار رئيسي)' : 'Total (Main Karat)',
        '18K',
        '21K',
        '22K',
        '24K',
      ],
      rows: offices.map((office) {
        final weights = office['weights'] as Map<String, dynamic>? ?? const {};
        final name = _asString(office['name'] ?? office['office_code'] ?? '');
        return <String>[
          name,
          _weightLabel(office['total_main_karat']),
          _weightLabel(weights['18k']),
          _weightLabel(weights['21k']),
          _weightLabel(weights['22k']),
          _weightLabel(weights['24k']),
        ];
      }).toList(),
    );
  }

  Widget _buildDataTableCard({
    required String title,
    required bool isArabic,
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: headers
                    .map((header) => DataColumn(label: Text(header)))
                    .toList(),
                rows: rows
                    .map(
                      (row) => DataRow(
                        cells: row.map((cell) => DataCell(Text(cell))).toList(),
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

  Widget _buildEmptyStateCard({
    required IconData icon,
    required String message,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade500),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryTileData {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryTileData({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });
}

class _SummaryTile extends StatelessWidget {
  final _SummaryTileData data;
  final bool isArabic;

  const _SummaryTile({
    required this.data,
    required this.isArabic,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: data.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment:
            isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(data.icon, color: data.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  data.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: isArabic ? TextAlign.right : TextAlign.left,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            data.value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: data.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _SafeTypeOption {
  final String code;
  final IconData icon;

  const _SafeTypeOption(this.code, this.icon);
}
