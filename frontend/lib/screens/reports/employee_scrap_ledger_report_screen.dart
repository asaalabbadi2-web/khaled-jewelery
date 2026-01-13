import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../api_service.dart';

class EmployeeScrapLedgerReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const EmployeeScrapLedgerReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<EmployeeScrapLedgerReportScreen> createState() =>
      _EmployeeScrapLedgerReportScreenState();
}

class _EmployeeScrapLedgerReportScreenState
    extends State<EmployeeScrapLedgerReportScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _data;

  DateTimeRange? _selectedRange;
  bool _includeUnposted = true;
  bool _includeUnassigned = true;
  int? _selectedBranchId;

  List<Map<String, dynamic>> _branches = const [];
  bool _branchesLoading = false;

  late final NumberFormat _weightFormat;
  late final NumberFormat _currencyFormat;

  @override
  void initState() {
    super.initState();
    _weightFormat = NumberFormat('#,##0.###');
    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: 'ر.س',
      decimalDigits: 2,
    );
    _loadBranches();
    _loadReport();
  }

  Map<String, dynamic> get _totals =>
      (_data?['totals'] as Map<String, dynamic>?) ?? const {};

  List<Map<String, dynamic>> get _rows {
    final raw = _data?['rows'];
    if (raw is List) {
      return raw.map((e) => Map<String, dynamic>.from(e ?? {})).toList();
    }
    return const [];
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  String _fmtWeight(dynamic value) => _weightFormat.format(_asDouble(value));

  String _fmtMoney(dynamic value) => _currencyFormat.format(_asDouble(value));

  Future<void> _loadBranches() async {
    setState(() => _branchesLoading = true);
    try {
      final branches = await widget.api.getBranches(activeOnly: true);
      if (!mounted) return;
      setState(() {
        _branches = branches;
      });
    } catch (_) {
      // Branch filter is optional; keep silent on failure.
    } finally {
      if (mounted) {
        setState(() => _branchesLoading = false);
      }
    }
  }

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getEmployeeScrapLedgerReport(
        startDate: _selectedRange?.start,
        endDate: _selectedRange?.end,
        branchId: _selectedBranchId,
        includeUnposted: _includeUnposted,
        includeUnassigned: _includeUnassigned,
      );

      if (!mounted) return;
      setState(() => _data = result);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initial =
        _selectedRange ??
        DateTimeRange(
          start: DateTime(now.year, now.month, now.day),
          end: DateTime(now.year, now.month, now.day),
        );

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initial,
      helpText: widget.isArabic ? 'اختر الفترة' : 'Select date range',
      cancelText: widget.isArabic ? 'إلغاء' : 'Cancel',
      confirmText: widget.isArabic ? 'تطبيق' : 'Apply',
    );

    if (picked == null) return;

    setState(() => _selectedRange = picked);
  }

  String _dateLabel(DateTime? value) {
    if (value == null) return '—';
    return DateFormat('yyyy-MM-dd').format(value);
  }

  int? _tryParseKarat(dynamic key) {
    final s = key?.toString() ?? '';
    final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return int.tryParse(digits);
  }

  double _karatT(int karat) {
    // Normalize to [0..1] for the range 18k..24k
    final clamped = karat.clamp(18, 24);
    return (clamped - 18) / 6.0;
  }

  Widget _buildKaratWeightChip({
    required ThemeData theme,
    required String karatKey,
    required dynamic weightValue,
  }) {
    final karat = _tryParseKarat(karatKey);
    if (karat == null) {
      return Chip(label: Text('$karatKey: ${_fmtWeight(weightValue)}'));
    }

    final t = _karatT(karat);
    final bgAlpha = theme.brightness == Brightness.dark
        ? (0.18 + (0.24 * t))
        : (0.10 + (0.20 * t));
    final borderAlpha = theme.brightness == Brightness.dark
        ? (0.28 + (0.30 * t))
        : (0.18 + (0.24 * t));

    final bgColor = theme.colorScheme.primary.withValues(alpha: bgAlpha);
    final borderColor = theme.colorScheme.primary.withValues(
      alpha: borderAlpha,
    );

    return Chip(
      backgroundColor: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(color: borderColor),
      ),
      label: Text(
        '$karatKey: ${_fmtWeight(weightValue)}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _copySummary() async {
    final totals = _totals;
    final rows = _rows;

    final start = _selectedRange?.start;
    final end = _selectedRange?.end;

    final header = widget.isArabic
        ? 'تقرير ذهب الكسر (عهدة الموظفين)'
        : 'Employee Scrap Ledger';
    final period = widget.isArabic
        ? 'الفترة: ${_dateLabel(start)} → ${_dateLabel(end)}'
        : 'Period: ${_dateLabel(start)} → ${_dateLabel(end)}';

    final totalWeightMain = _fmtWeight(totals['total_weight_main_karat']);
    final invoiceCount = _asInt(totals['invoice_count']);
    final totalValue = _fmtMoney(totals['total_value']);

    final topLines = rows
        .take(10)
        .map((row) {
          final name = (row['scrap_holder_employee_name'] as String?)?.trim();
          final id = row['scrap_holder_employee_id'];
          final display = (name != null && name.isNotEmpty)
              ? name
              : (id == null
                    ? (widget.isArabic ? 'غير مُسند' : 'Unassigned')
                    : 'ID: $id');
          final w = _fmtWeight(row['total_weight_main_karat']);
          return '- $display: $w جم';
        })
        .join('\n');

    final text = [
      header,
      period,
      widget.isArabic
          ? 'عدد الفواتير: $invoiceCount'
          : 'Invoices: $invoiceCount',
      widget.isArabic
          ? 'الإجمالي (عيار رئيسي): $totalWeightMain جم'
          : 'Total (main karat): $totalWeightMain g',
      widget.isArabic
          ? 'إجمالي القيمة: $totalValue'
          : 'Total value: $totalValue',
      if (topLines.isNotEmpty)
        widget.isArabic ? 'تفصيل (أعلى 10):\n$topLines' : 'Top 10:\n$topLines',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.isArabic ? 'تم نسخ الملخص' : 'Summary copied'),
      ),
    );
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
          title: Text(isArabic ? 'عهدة ذهب الكسر' : 'Scrap Custody'),
          actions: [
            IconButton(
              tooltip: isArabic ? 'نسخ الملخص' : 'Copy summary',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: (_isLoading || _data == null) ? null : _copySummary,
            ),
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
                      _buildTotalsCard(isArabic),
                      const SizedBox(height: 16),
                      _buildRowsList(isArabic),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'الفلاتر' : 'Filters',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.date_range_outlined),
                  label: Text(
                    isArabic
                        ? 'من ${_dateLabel(_selectedRange?.start)} إلى ${_dateLabel(_selectedRange?.end)}'
                        : 'From ${_dateLabel(_selectedRange?.start)} to ${_dateLabel(_selectedRange?.end)}',
                  ),
                ),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey<int?>(_selectedBranchId),
                    initialValue: _selectedBranchId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: isArabic
                          ? 'الفرع (اختياري)'
                          : 'Branch (optional)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: _branchesLoading
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : (_selectedBranchId == null)
                          ? null
                          : IconButton(
                              tooltip: isArabic ? 'مسح' : 'Clear',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() => _selectedBranchId = null);
                              },
                            ),
                    ),
                    items: [
                      DropdownMenuItem<int>(
                        value: null,
                        child: Text(isArabic ? 'كل الفروع' : 'All branches'),
                      ),
                      ..._branches.map((b) {
                        final id = b['id'];
                        final name = b['name'] ?? '';
                        if (id is! int) {
                          return null;
                        }
                        return DropdownMenuItem<int>(
                          value: id,
                          child: Text('$name (ID: $id)'),
                        );
                      }).whereType<DropdownMenuItem<int>>(),
                    ],
                    onChanged: (value) {
                      setState(() => _selectedBranchId = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          isArabic ? 'تضمين غير المُرحّل' : 'Include unposted',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      Switch.adaptive(
                        value: _includeUnposted,
                        onChanged: (value) {
                          setState(() => _includeUnposted = value);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          isArabic ? 'إظهار غير المُسند' : 'Show unassigned',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      Switch.adaptive(
                        value: _includeUnassigned,
                        onChanged: (value) {
                          setState(() => _includeUnassigned = value);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: isArabic
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _loadReport,
                icon: const Icon(Icons.filter_alt_outlined),
                label: Text(isArabic ? 'تطبيق' : 'Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalsCard(bool isArabic) {
    final theme = Theme.of(context);
    final totals = _totals;
    final weightsByKarat = Map<String, dynamic>.from(
      totals['weights_by_karat'] ?? const {},
    );

    final start = _selectedRange?.start;
    final end = _selectedRange?.end;
    final periodLabel = isArabic
        ? 'من ${_dateLabel(start)} إلى ${_dateLabel(end)}'
        : 'From ${_dateLabel(start)} to ${_dateLabel(end)}';

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.35 : 0.6,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.workspace_premium_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: isArabic
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic ? 'إجمالي المحل' : 'Grand totals',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        periodLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.7,
                          ),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: isArabic
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${_fmtWeight(totals['total_weight_main_karat'])} ${isArabic ? 'جم' : 'g'}',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      isArabic ? 'عيار رئيسي' : 'Main karat',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    isArabic
                        ? 'عدد الفواتير: ${_asInt(totals['invoice_count'])}'
                        : 'Invoices: ${_asInt(totals['invoice_count'])}',
                  ),
                ),
                Chip(
                  label: Text(
                    isArabic
                        ? 'إجمالي القيمة: ${_fmtMoney(totals['total_value'])}'
                        : 'Total value: ${_fmtMoney(totals['total_value'])}',
                  ),
                ),
              ],
            ),
            if (weightsByKarat.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                isArabic ? 'حسب العيار' : 'By karat',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: weightsByKarat.entries
                    .map(
                      (e) => _buildKaratWeightChip(
                        theme: theme,
                        karatKey: e.key.toString(),
                        weightValue: e.value,
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRowsList(bool isArabic) {
    final theme = Theme.of(context);
    final rows = _rows;

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            isArabic
                ? 'لا توجد فواتير كسر ضمن الفترة'
                : 'No scrap invoices in this period',
            style: theme.textTheme.bodyLarge,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: isArabic
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          isArabic ? 'ملخص الموظفين' : 'Employees',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: rows.length,
          separatorBuilder: (_, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final row = rows[index];
            final employeeId = row['scrap_holder_employee_id'];
            final name = (row['scrap_holder_employee_name'] as String?)?.trim();
            final title = (name != null && name.isNotEmpty)
                ? name
                : (employeeId == null
                      ? (isArabic ? 'غير مُسند' : 'Unassigned')
                      : 'ID: $employeeId');

            final weightsByKarat = Map<String, dynamic>.from(
              row['weights_by_karat'] ?? const {},
            );
            final weightMain = _asDouble(row['total_weight_main_karat']);
            final isUnassigned = employeeId == null;

            final borderColor = (isUnassigned && weightMain > 0)
                ? theme.colorScheme.error.withValues(alpha: 0.35)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.6);

            final karatEntries = weightsByKarat.entries.toList()
              ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));

            return Card(
              elevation: 0,
              color: theme.colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: borderColor,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: isArabic
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _fmtMoney(row['total_value']),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isUnassigned && weightMain > 0)
                          Chip(
                            avatar: Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            backgroundColor: theme.colorScheme.errorContainer,
                            label: Text(
                              isArabic ? 'غير مُسند' : 'Unassigned',
                            ),
                          ),
                        Chip(
                          label: Text(
                            isArabic
                                ? '${_asInt(row['invoice_count'])} فاتورة'
                                : '${_asInt(row['invoice_count'])} invoices',
                          ),
                        ),
                        Chip(
                          label: Text(
                            isArabic
                                ? '${_fmtWeight(row['total_weight_main_karat'])} جم (رئيسي)'
                                : '${_fmtWeight(row['total_weight_main_karat'])} g (main)',
                          ),
                        ),
                        Chip(
                          label: Text(
                            isArabic
                                ? 'نقد: ${_fmtMoney(row['total_cash_paid'])}'
                                : 'Cash: ${_fmtMoney(row['total_cash_paid'])}',
                          ),
                        ),
                      ],
                    ),
                    if (karatEntries.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: karatEntries
                            .map(
                              (e) => _buildKaratWeightChip(
                                theme: theme,
                                karatKey: e.key.toString(),
                                weightValue: e.value,
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      isArabic
                          ? 'من ${_dateLabel(DateTime.tryParse((row['first_date'] ?? '').toString()))} إلى ${_dateLabel(DateTime.tryParse((row['last_date'] ?? '').toString()))}'
                          : 'From ${_dateLabel(DateTime.tryParse((row['first_date'] ?? '').toString()))} to ${_dateLabel(DateTime.tryParse((row['last_date'] ?? '').toString()))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
