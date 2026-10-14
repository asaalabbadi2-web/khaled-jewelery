import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../api_service.dart';
import '../../models/safe_box_model.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_semantic_colors.dart';

/// The theme's colours (ADR-038): the scheme and the semantic tones.
ColorScheme _cs(BuildContext context) => Theme.of(context).colorScheme;
AppSemanticColors _tn(BuildContext context) => AppSemanticColors.of(context);

class CategoryWeightAuditReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const CategoryWeightAuditReportScreen({
    super.key,
    required this.api,
    required this.isArabic,
  });

  @override
  State<CategoryWeightAuditReportScreen> createState() =>
      _CategoryWeightAuditReportScreenState();
}

class _CategoryWeightAuditReportScreenState
    extends State<CategoryWeightAuditReportScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _balancesSearchController =
      TextEditingController();
  final TextEditingController _invoiceIdController = TextEditingController();

  late final TabController _tabController;

  bool _loadingFilters = true;
  String? _filtersError;

  List<SafeBoxModel> _safeBoxes = const [];
  List<dynamic> _categories = const [];

  int? _selectedSafeBoxId;
  int? _selectedCategoryId;

  bool _loadingBalances = false;
  String? _balancesError;
  List<Map<String, dynamic>> _balances = const [];

  bool _loadingMovements = false;
  String? _movementsError;
  List<Map<String, dynamic>> _movements = const [];

  int _movementsLimit = 200;
  DateTimeRange? _movementsDateRange;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    _balancesSearchController.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    _loadFilters();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _balancesSearchController.dispose();
    _invoiceIdController.dispose();
    super.dispose();
  }

  Future<void> _loadFilters() async {
    setState(() {
      _loadingFilters = true;
      _filtersError = null;
    });

    try {
      final safeBoxesFuture = widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
        includeBalance: false,
        includeAccount: false,
      );
      final categoriesFuture = widget.api.getCategories();

      final safeBoxes = await safeBoxesFuture;
      final categories = await categoriesFuture;

      if (!mounted) return;
      setState(() {
        _safeBoxes = safeBoxes;
        _categories = categories;
        _loadingFilters = false;
      });

      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filtersError = e.toString();
        _loadingFilters = false;
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadBalances(),
      _loadMovements(),
    ]);
  }

  Future<void> _loadBalances() async {
    setState(() {
      _loadingBalances = true;
      _balancesError = null;
    });

    try {
      final rows = await widget.api.getCategoryWeightBalances(
        safeBoxId: _selectedSafeBoxId,
        categoryId: _selectedCategoryId,
      );

      if (!mounted) return;
      setState(() {
        _balances = rows;
        _loadingBalances = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _balancesError = e.toString();
        _loadingBalances = false;
      });
    }
  }

  int? _parsedInvoiceId() {
    final raw = _invoiceIdController.text.trim();
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  Future<void> _loadMovements() async {
    setState(() {
      _loadingMovements = true;
      _movementsError = null;
    });

    try {
      final range = _movementsDateRange;
      final rows = await widget.api.getCategoryWeightMovements(
        safeBoxId: _selectedSafeBoxId,
        categoryId: _selectedCategoryId,
        invoiceId: _parsedInvoiceId(),
        startDate: range?.start,
        endDate: range?.end,
        limit: _movementsLimit,
      );

      if (!mounted) return;
      setState(() {
        _movements = rows;
        _loadingMovements = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _movementsError = e.toString();
        _loadingMovements = false;
      });
    }
  }

  String _t(String ar, String en) => widget.isArabic ? ar : en;

  String _fmtYmd(DateTime dt) => dt.toIso8601String().split('T').first;

  String _fmtNum(dynamic v, {int decimals = 3}) {
    if (v == null) return '0';
    if (v is int) return v.toString();
    if (v is num) return v.toStringAsFixed(decimals);
    final parsed = num.tryParse(v.toString());
    if (parsed == null) return v.toString();
    return parsed.toStringAsFixed(decimals);
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _asString(dynamic v) => (v == null) ? '' : v.toString();

  List<Map<String, dynamic>> _filteredBalances() {
    final q = _balancesSearchController.text.trim().toLowerCase();
    if (q.isEmpty) return _balances;

    return _balances.where((row) {
      final safeName = _asString(row['safe_box_name']).toLowerCase();
      final categoryName = _asString(row['category_name']).toLowerCase();
      return safeName.contains(q) || categoryName.contains(q);
    }).toList(growable: false);
  }

  Widget _buildFiltersCard() {
    final theme = Theme.of(context);

    final safeBoxItems = <DropdownMenuItem<int?>>[
      DropdownMenuItem<int?>(
        value: null,
        child: Text(_t('كل المواقع', 'All locations')),
      ),
      ..._safeBoxes.map(
        (sb) => DropdownMenuItem<int?>(
          value: sb.id,
          child: Text(sb.name),
        ),
      ),
    ];

    final categoryItems = <DropdownMenuItem<int?>>[
      DropdownMenuItem<int?>(
        value: null,
        child: Text(_t('كل التصنيفات', 'All categories')),
      ),
      ..._categories.whereType<Map<String, dynamic>>().map((c) {
        final id = c['id'];
        final name = c['name'];
        final parsedId = (id is int) ? id : int.tryParse(id.toString());
        return DropdownMenuItem<int?>(
          value: parsedId,
          child: Text(name?.toString() ?? ''),
        );
      }),
    ];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment:
              widget.isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: _cs(context).primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _t('عوامل التصفية', 'Filters'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                    textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
                  ),
                ),
                TextButton.icon(
                  onPressed:
                      (_loadingBalances || _loadingMovements) ? null : _refreshAll,
                  icon: const Icon(Icons.refresh),
                  label: Text(_t('تحديث', 'Refresh')),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    value: _selectedSafeBoxId,
                    items: safeBoxItems,
                    decoration: InputDecoration(
                      labelText: _t('الموقع/الخزنة', 'Location / Safe box'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) async {
                      setState(() => _selectedSafeBoxId = v);
                      await _refreshAll();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    value: _selectedCategoryId,
                    items: categoryItems,
                    decoration: InputDecoration(
                      labelText: _t('التصنيف', 'Category'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) async {
                      setState(() => _selectedCategoryId = v);
                      await _refreshAll();
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalancesTab() {
    final filtered = _filteredBalances();

    if (_loadingBalances) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_balancesError != null) {
      return _buildErrorState(_balancesError!, onRetry: _loadBalances);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        TextField(
          controller: _balancesSearchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: _t('بحث (الموقع/التصنيف)...', 'Search (location/category)...'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        _buildDistributionCardIfPossible(filtered),
        const SizedBox(height: 12),
        _buildBalancesTable(filtered),
      ],
    );
  }

  Widget _buildDistributionCardIfPossible(List<Map<String, dynamic>> rows) {
    final safeBoxSelected = _selectedSafeBoxId != null;
    if (!safeBoxSelected) {
      return _buildInfoCard(
        icon: Icons.pie_chart_outline,
        title: _t('توزيع حسب التصنيف', 'Distribution by Category'),
        message: _t(
          'اختر موقع/خزنة لعرض مخطط التوزيع.',
          'Select a location to view the distribution chart.',
        ),
      );
    }

    final grouped = <String, double>{};
    for (final row in rows) {
      final cat = _asString(row['category_name']);
      final value = _asDouble(row['weight_main_karat']);
      if (cat.isEmpty) continue;
      if (value <= 0) continue; // chart focuses on positive balances
      grouped[cat] = (grouped[cat] ?? 0) + value;
    }

    final entries = grouped.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (entries.isEmpty) {
      return _buildInfoCard(
        icon: Icons.pie_chart_outline,
        title: _t('توزيع حسب التصنيف', 'Distribution by Category'),
        message: _t(
          'لا توجد أرصدة موجبة كافية للرسم.',
          'No positive balances to render a chart.',
        ),
      );
    }

    final top = entries.take(6).toList(growable: false);
    final restSum = entries.skip(6).fold<double>(
      0,
      (acc, e) => acc + e.value,
    );

    final pieData = <MapEntry<String, double>>[
      ...top,
      if (restSum > 0) MapEntry(_t('أخرى', 'Others'), restSum),
    ];

    final total = pieData.fold<double>(0, (acc, e) => acc + e.value);

    // The chart's palette: the theme's section tones, readable in both modes (ADR-038).
    final tones = _tn(context);
    final colors = [
      _cs(context).primary,
      tones.warning.fg,
      tones.sectionSlate.fg,
      tones.sectionRed.fg,
      tones.sectionTeal.fg,
      tones.sectionIndigo.fg,
      tones.sectionPurple.fg,
      tones.sectionBlue.fg,
    ];

    final sections = <PieChartSectionData>[];
    for (var i = 0; i < pieData.length; i++) {
      final e = pieData[i];
      final pct = (e.value / total) * 100;
      sections.add(
        PieChartSectionData(
          color: colors[i % colors.length],
          value: e.value,
          title: '${pct.toStringAsFixed(1)}%',
          radius: 60,
          titleStyle: TextStyle(
            color: _cs(context).onPrimary,
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
              widget.isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              _t('توزيع الأوزان حسب التصنيف', 'Weight Distribution by Category'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 240,
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
                  SizedBox(
                    width: 180,
                    child: ListView.builder(
                      itemCount: pieData.length,
                      itemBuilder: (_, index) {
                        final item = pieData[index];
                        final color = colors[index % colors.length];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(width: 12, height: 12, color: color),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${item.key} • ${item.value.toStringAsFixed(3)}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
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

  Widget _buildBalancesTable(List<Map<String, dynamic>> rows) {
    final isArabic = widget.isArabic;

    if (rows.isEmpty) {
      return _buildInfoCard(
        icon: Icons.inventory_2_outlined,
        title: _t('الأرصدة', 'Balances'),
        message: _t('لا توجد بيانات للعرض.', 'No data to display.'),
      );
    }

    DataRow buildRow(Map<String, dynamic> row) {
      final safeName = _asString(row['safe_box_name']);
      final catName = _asString(row['category_name']);
      final main = _asDouble(row['weight_main_karat']);
      final grams = _asDouble(row['weight_grams_signed']);

      final mainColor = main <= 0 ? _cs(context).error : _tn(context).ready.fg;
      final gramsColor =
          grams <= 0 ? _cs(context).error : _tn(context).ready.fg;

      return DataRow(
        cells: [
          DataCell(Text(safeName.isEmpty ? '-' : safeName)),
          DataCell(Text(catName.isEmpty ? '-' : catName)),
          DataCell(
            Text(
              _fmtNum(main, decimals: 3),
              style: TextStyle(fontWeight: FontWeight.w700, color: mainColor),
            ),
          ),
          DataCell(
            Text(
              _fmtNum(grams, decimals: 3),
              style: TextStyle(fontWeight: FontWeight.w700, color: gramsColor),
            ),
          ),
        ],
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment:
              widget.isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              _t('أرصدة التصنيفات حسب الموقع', 'Category Balances by Location'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 44,
                dataRowMinHeight: 44,
                dataRowMaxHeight: 56,
                columns: [
                  DataColumn(label: Text(_t('الموقع', 'Location'))),
                  DataColumn(label: Text(_t('التصنيف', 'Category'))),
                  DataColumn(
                    numeric: true,
                    label: Text(_t('بالعيار الرئيسي', 'Main karat')),
                  ),
                  DataColumn(
                    numeric: true,
                    label: Text(_t('بالجرام (مُوقّع)', 'Grams (signed)')),
                  ),
                ],
                rows: rows.map(buildRow).toList(growable: false),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _t(
                'ملاحظة: القيم باللون الأحمر تعني صفر/سالب.',
                'Note: Red values mean zero/negative.',
              ),
              textAlign: isArabic ? TextAlign.right : TextAlign.left,
              style: TextStyle(color: _cs(context).onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMovementsTab() {
    if (_loadingMovements) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_movementsError != null) {
      return _buildErrorState(_movementsError!, onRetry: _loadMovements);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: widget.isArabic
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  _t('تصفية الحركة', 'Movement Filters'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                _buildMovementsDateRangeRow(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _invoiceIdController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _t('رقم الفاتورة (اختياري)', 'Invoice ID (optional)'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _loadMovements(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 170,
                      child: DropdownButtonFormField<int>(
                        value: _movementsLimit,
                        decoration: InputDecoration(
                          labelText: _t('الحد', 'Limit'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 100, child: Text('100')),
                          DropdownMenuItem(value: 200, child: Text('200')),
                          DropdownMenuItem(value: 500, child: Text('500')),
                          DropdownMenuItem(value: 1000, child: Text('1000')),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _movementsLimit = v);
                          await _loadMovements();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _invoiceIdController.clear();
                          _movementsDateRange = null;
                          _movementsLimit = 200;
                        });
                        _loadMovements();
                      },
                      icon: const Icon(Icons.clear),
                      label: Text(_t('مسح', 'Clear')),
                    ),
                    ElevatedButton.icon(
                      onPressed: _loadMovements,
                      icon: const Icon(Icons.search),
                      label: Text(_t('تطبيق', 'Apply')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_movements.isEmpty)
          _buildInfoCard(
            icon: Icons.history,
            title: _t('الحركات', 'Movements'),
            message: _t('لا توجد حركات للعرض.', 'No movements to display.'),
          )
        else
          ..._movements.map(_buildMovementCard),
      ],
    );
  }

  Widget _buildMovementsDateRangeRow() {
    final range = _movementsDateRange;

    String label;
    if (range == null) {
      label = _t('بدون فلتر تاريخ', 'No date filter');
    } else {
      label = widget.isArabic
          ? 'من ${_fmtYmd(range.start)} إلى ${_fmtYmd(range.end)}'
          : '${_fmtYmd(range.start)} → ${_fmtYmd(range.end)}';
    }

    return Column(
      crossAxisAlignment:
          widget.isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickMovementsDateRange,
                icon: const Icon(Icons.date_range),
                label: Text(label, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _quickRangeChip(
              label: _t('اليوم', 'Today'),
              onTap: () => _setMovementsRange(_todayRange()),
            ),
            _quickRangeChip(
              label: _t('أمس', 'Yesterday'),
              onTap: () => _setMovementsRange(_yesterdayRange()),
            ),
            _quickRangeChip(
              label: _t('هذا الأسبوع', 'This week'),
              onTap: () => _setMovementsRange(_thisWeekRange()),
            ),
            _quickRangeChip(
              label: _t('آخر 7 أيام', 'Last 7 days'),
              onTap: () => _setMovementsRange(_lastDaysRange(7)),
            ),
            _quickRangeChip(
              label: _t('آخر 30 يوم', 'Last 30 days'),
              onTap: () => _setMovementsRange(_lastDaysRange(30)),
            ),
            _quickRangeChip(
              label: _t('هذا الشهر', 'This month'),
              onTap: () => _setMovementsRange(_thisMonthRange()),
            ),
            _quickRangeChip(
              label: _t('بدون', 'None'),
              onTap: () => _setMovementsRange(null),
            ),
          ],
        ),
      ],
    );
  }

  Widget _quickRangeChip({required String label, required VoidCallback onTap}) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      backgroundColor: _cs(context).surfaceContainerHigh,
      side: BorderSide(color: _cs(context).outlineVariant),
    );
  }

  DateTimeRange _yesterdayRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 1));
    final end = today.subtract(const Duration(days: 1));
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange _todayRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTimeRange(start: today, end: today);
  }

  DateTimeRange _thisWeekRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Week starts on Monday (ISO-8601 style): weekday 1..7 (Mon..Sun)
    final start = today.subtract(Duration(days: today.weekday - 1));
    return DateTimeRange(start: start, end: today);
  }

  DateTimeRange _lastDaysRange(int days) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final start = end.subtract(Duration(days: days - 1));
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange _thisMonthRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(now.year, now.month, now.day);
    return DateTimeRange(start: start, end: end);
  }

  Future<void> _pickMovementsDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      locale: widget.isArabic ? const Locale('ar') : const Locale('en'),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _movementsDateRange,
    );

    if (picked != null) {
      setState(() => _movementsDateRange = picked);
      _loadMovements();
    }
  }

  void _setMovementsRange(DateTimeRange? range) {
    setState(() => _movementsDateRange = range);
    _loadMovements();
  }

  Widget _buildMovementCard(Map<String, dynamic> row) {
    final safeName = _asString(row['safe_box_name']);
    final catName = _asString(row['category_name']);
    final invoiceId = row['invoice_id'];
    final invoiceType = _asString(row['invoice_type']);
    final karat = row['karat'];

    final deltaMain = _asDouble(row['weight_delta_main_karat']);
    final deltaGrams = _asDouble(row['weight_delta_grams']);

    final createdAt = _asString(row['created_at']);
    final label = _asString(row['line_label']);

    final deltaColor =
        deltaMain == 0 ? _cs(context).onSurfaceVariant : (deltaMain > 0 ? _tn(context).ready.fg : _cs(context).error);

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        title: Text(
          '${catName.isEmpty ? '-' : catName} • ${safeName.isEmpty ? '-' : safeName}',
          textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: widget.isArabic
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                _t(
                  'فاتورة: ${invoiceId ?? '-'} • النوع: ${invoiceType.isEmpty ? '-' : invoiceType} • عيار: ${karat ?? '-'}',
                  'Invoice: ${invoiceId ?? '-'} • Type: ${invoiceType.isEmpty ? '-' : invoiceType} • Karat: ${karat ?? '-'}',
                ),
                textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
              ),
              if (label.isNotEmpty)
                Text(
                  _t('وصف: $label', 'Label: $label'),
                  textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
                ),
              if (createdAt.isNotEmpty)
                Text(
                  _t('التاريخ: $createdAt', 'Date: $createdAt'),
                  textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
                ),
            ],
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _fmtNum(deltaMain, decimals: 3),
              style: TextStyle(fontWeight: FontWeight.w800, color: deltaColor),
            ),
            Text(
              '${_fmtNum(deltaGrams, decimals: 3)} g',
              style: TextStyle(color: _cs(context).onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 34, color: _cs(context).primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: widget.isArabic
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    textAlign: widget.isArabic ? TextAlign.right : TextAlign.left,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(String error, {required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: _cs(context).error, size: 42),
            const SizedBox(height: 10),
            Text(
              _t('حدث خطأ أثناء التحميل', 'Failed to load'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: _cs(context).onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: onRetry,
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
    final title = _t('جرد الأوزان حسب التصنيف', 'Category Weight Audit');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: TabBar(
          controller: _tabController,
          labelColor: Theme.of(context).appBarTheme.foregroundColor,
          unselectedLabelColor:
              Theme.of(context).appBarTheme.foregroundColor?.withValues(alpha: 0.7),
          indicatorColor: Theme.of(context).appBarTheme.foregroundColor,
          tabs: [
            Tab(text: _t('الأرصدة', 'Balances')),
            Tab(text: _t('الحركة', 'Movements')),
          ],
        ),
      ),
      body: _loadingFilters
          ? const Center(child: CircularProgressIndicator())
          : (_filtersError != null)
              ? _buildErrorState(_filtersError!, onRetry: _loadFilters)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _buildFiltersCard(),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildBalancesTab(),
                          _buildMovementsTab(),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
