import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../api_service.dart';
import '../models/account_statement_model.dart';

class AccountStatementScreen extends StatefulWidget {
  final int accountId;
  final String accountName;

  const AccountStatementScreen({super.key, required this.accountId, required this.accountName});

  @override
  State<AccountStatementScreen> createState() => _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  bool _isLoading = true;
  AccountStatement? _statement;
  List<StatementLine> _filteredLines = [];
  DateTimeRange? _dateRange;
  final TextEditingController _searchController = TextEditingController();
  String _filterType = 'all'; // 'all', 'credit', 'debit'
  // int? _expandedTransactionId; // Removed: unused

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  int _viewMode = 0; // 0: dual, 1: gold, 2: cash
  bool _showOnlyMovement = false;
  bool _includeBreakdown = true;
  bool _isExporting = false;


  @override
  void initState() {
    super.initState();
    // _fetchAccountStatement(); // We will call this from didChangeDependencies
    _searchController.addListener(_filterLines);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fetchAccountStatement();
  }

  @override
  void dispose() {
    // Dispose controllers to avoid leaks
    _searchController.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  Future<void> _fetchAccountStatement() async {
    setState(() => _isLoading = true);
    try {
      final data = await ApiService().getAccountStatement(widget.accountId);
      if (!mounted) return;
      setState(() {
        _statement = AccountStatement.fromJson(data);
        _filterLines(); // This will also handle the initial list
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load statement: $e')),
      );
    }
  }

  void _filterLines() {
    if (_statement == null) return;

    setState(() {
      var filtered = _statement!.lines.where((line) {
        final date = line.date;
        final description = line.description.toLowerCase();
        final query = _searchController.text.toLowerCase();

        final isAfterStartDate = _dateRange?.start == null || date.isAfter(_dateRange!.start.subtract(const Duration(days: 1)));
        final isBeforeEndDate = _dateRange?.end == null || date.isBefore(_dateRange!.end.add(const Duration(days: 1)));
        final matchesSearch = description.contains(query);

        bool matchesFilterType = true;
        if (_filterType == 'credit') {
          matchesFilterType = line.goldCredit > 0 || line.cashCredit > 0;
        } else if (_filterType == 'debit') {
          matchesFilterType = line.goldDebit > 0 || line.cashDebit > 0;
        }

        final hasMovement = (line.goldDebit + line.goldCredit + line.cashDebit + line.cashCredit).abs() > 0.0001;
        final matchesMovement = !_showOnlyMovement || hasMovement;

        return isAfterStartDate && isBeforeEndDate && matchesSearch && matchesFilterType && matchesMovement;
      }).toList();

      // Recalculate running balances for the filtered list
      double runningGold = _statement!.openingBalanceGold;
      double runningCash = _statement!.openingBalanceCash;
      _filteredLines = [];
      for (var line in filtered) {
        runningGold += line.goldDebit - line.goldCredit;
        runningCash += line.cashDebit - line.cashCredit;
        _filteredLines.add(line.copyWith(
          runningGoldBalance: runningGold,
          runningCashBalance: runningCash,
        ));
      }
    });
  }

  Future<void> _pickDateRange() async {
    final initialDateRange = _dateRange ?? DateTimeRange(
      start: DateTime.now().subtract(const Duration(days: 30)),
      end: DateTime.now(),
    );

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: initialDateRange,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      saveText: 'تطبيق',
      builder: (context, child) {
        return Directionality(textDirection: ui.TextDirection.rtl, child: child!);
      },
    );

    if (picked != null) {
      setState(() {
        _dateRange = picked;
      });
      _filterLines();
    }
  }

  void _showExportSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf),
                  title: const Text('تصدير إلى PDF'),
                  subtitle: const Text('تنسيق احترافي للطباعة والمشاركة'),
                  onTap: () => _handleExport(_exportToPdf),
                ),
                ListTile(
                  leading: const Icon(Icons.table_view),
                  title: const Text('تصدير إلى CSV/Excel'),
                  subtitle: const Text('للمحاسبين والتحليل في Excel'),
                  onTap: () => _handleExport(_exportToCsv),
                ),
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('نسخ ملخص الحساب'),
                  subtitle: const Text('يتم النسخ إلى الحافظة'),
                  onTap: () => _handleExport(() async {
                    await _copySummaryToClipboard();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الملخص')));
                    }
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleExport(Future<void> Function() action) async {
    Navigator.of(context).pop();
    setState(() => _isExporting = true);
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل التصدير: $e')));
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _exportToCsv() async {
    if (_statement == null) return;

    final headers = <String>['التاريخ', 'الوصف'];
    if (_viewMode != 2) {
      headers.addAll(['ذهب مدين', 'ذهب دائن', 'رصيد الذهب']);
    }
    if (_viewMode != 1) {
      headers.addAll(['نقد مدين', 'نقد دائن', 'رصيد النقد']);
    }

    final rows = <List<String>>[headers];
    for (final line in _filteredLines) {
      final row = <String>[
        DateFormat('yyyy-MM-dd').format(line.date),
        line.description,
      ];

      if (_viewMode != 2) {
        final mainKarat = (_statement?.mainKarat ?? 21).toDouble();
        final debitMain = _convertToMainKarat(line.debit18k + line.debit21k + line.debit22k + line.debit24k, 21, mainKarat);
        final creditMain = _convertToMainKarat(line.credit18k + line.credit21k + line.credit22k + line.credit24k, 21, mainKarat);
        row
          ..add(debitMain.toStringAsFixed(3))
          ..add(creditMain.toStringAsFixed(3))
          ..add((line.runningGoldBalance ?? 0).toStringAsFixed(3));
      }

      if (_viewMode != 1) {
        row
          ..add(line.cashDebit.toStringAsFixed(2))
          ..add(line.cashCredit.toStringAsFixed(2))
          ..add((line.runningCashBalance ?? 0).toStringAsFixed(2));
      }

      rows.add(row);
    }

    final csvData = const ListToCsvConverter().convert(rows);
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv');
    await file.writeAsString(csvData, encoding: utf8);
    await OpenFile.open(file.path);
  }

  Future<void> _exportToPdf() async {
    if (_statement == null) return;

  final doc = pw.Document();
    final headers = <String>['التاريخ', 'الوصف'];
    if (_viewMode != 2) {
      headers.addAll(['ذهب مدين', 'ذهب دائن', 'رصيد الذهب']);
    }
    if (_viewMode != 1) {
      headers.addAll(['نقد مدين', 'نقد دائن', 'رصيد النقد']);
    }

    final tableData = _filteredLines.map((line) {
      final row = <String>[
        DateFormat('yyyy-MM-dd').format(line.date),
        line.description,
      ];

      if (_viewMode != 2) {
        final mainKarat = (_statement?.mainKarat ?? 21).toDouble();
        final debitMain = _convertToMainKarat(line.debit18k + line.debit21k + line.debit22k + line.debit24k, 21, mainKarat);
        final creditMain = _convertToMainKarat(line.credit18k + line.credit21k + line.credit22k + line.credit24k, 21, mainKarat);
        row
          ..add(debitMain.toStringAsFixed(3))
          ..add(creditMain.toStringAsFixed(3))
          ..add((line.runningGoldBalance ?? 0).toStringAsFixed(3));
      }

      if (_viewMode != 1) {
        row
          ..add(line.cashDebit.toStringAsFixed(2))
          ..add(line.cashCredit.toStringAsFixed(2))
          ..add((line.runningCashBalance ?? 0).toStringAsFixed(2));
      }

      return row;
    }).toList();

  doc.addPage(
      pw.MultiPage(
  pageFormat: pdf.PdfPageFormat.a4,
        build: (context) => [
          pw.Header(level: 0, text: 'كشف حساب ${widget.accountName}'),
          pw.Text('تاريخ التوليد: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}'),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: tableData,
            cellAlignment: pw.Alignment.centerRight,
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 10),
            columnWidths: {
              0: const pw.FixedColumnWidth(70),
              1: const pw.FlexColumnWidth(2),
            },
          ),
        ],
      ),
    );

  final bytes = await doc.save();
  await Printing.sharePdf(
      bytes: bytes,
      filename: 'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
    );
  }

  Future<void> _copySummaryToClipboard() async {
    if (_statement == null) return;

    final statement = _statement!;
    final summary = StringBuffer()
      ..writeln('كشف حساب: ${widget.accountName}')
      ..writeln('عيار أساسي: ${statement.mainKarat}')
      ..writeln('رصيد افتتاحي ذهب: ${statement.openingBalanceGold.toStringAsFixed(3)}')
      ..writeln('رصيد افتتاحي نقد: ${statement.openingBalanceCash.toStringAsFixed(2)}')
      ..writeln('إجمالي ذهب مدين: ${statement.totalDebitGold.toStringAsFixed(3)}')
      ..writeln('إجمالي ذهب دائن: ${statement.totalCreditGold.toStringAsFixed(3)}')
      ..writeln('إجمالي نقد مدين: ${statement.totalDebitCash.toStringAsFixed(2)}')
      ..writeln('إجمالي نقد دائن: ${statement.totalCreditCash.toStringAsFixed(2)}')
      ..writeln('رصيد ختامي ذهب: ${statement.closingBalanceGoldNormalized.toStringAsFixed(3)}')
      ..writeln('رصيد ختامي نقد: ${statement.closingBalanceCash.toStringAsFixed(2)}');

    await Clipboard.setData(ClipboardData(text: summary.toString()));
  }

  // Removed unused _exportToCsv

  // Removed unused _exportToPdf

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('كشف حساب ${widget.accountName}'),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _statement == null
                ? _buildEmptyState()
                : _buildStatementContent(),
      ),
    );
  }

  Widget _buildStatementContent() {
    return RefreshIndicator(
      onRefresh: _fetchAccountStatement,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _buildSummaryOverview(constraints.maxWidth),
              const SizedBox(height: 16),
              _buildToolbar(constraints.maxWidth),
              const SizedBox(height: 16),
              _buildStatementTable(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          const Text('لا توجد سجلات لهذا الحساب'),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _fetchAccountStatement,
            icon: const Icon(Icons.refresh),
            label: const Text('تحديث'),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryOverview(double maxWidth) {
    final theme = Theme.of(context);
    final statement = _statement!;

    final cards = <Widget>[
      _SummaryCard(
        title: 'رصيد افتتاحي (عيار ${statement.mainKarat})',
        goldValue: statement.openingBalanceGold,
        cashValue: statement.openingBalanceCash,
        color: theme.colorScheme.primary,
        icon: Icons.lock_clock,
      ),
      _SummaryCard(
        title: 'إجمالي الحركة',
        goldValue: statement.totalDebitGold - statement.totalCreditGold,
        cashValue: statement.totalDebitCash - statement.totalCreditCash,
        color: theme.colorScheme.secondary,
        icon: Icons.sync_alt,
      ),
      _SummaryCard(
        title: 'رصيد ختامي (موزون)',
        goldValue: statement.closingBalanceGoldNormalized,
        cashValue: statement.closingBalanceCash,
        color: theme.colorScheme.tertiary,
        icon: Icons.summarize,
      ),
    ];

    final isCompact = maxWidth < 720;
    final cardWidth = isCompact ? maxWidth : (maxWidth - 24) / 3;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cards
      .map((card) => SizedBox(
        width: cardWidth.clamp(260, 420).toDouble(),
                child: card,
              ))
          .toList(),
    );
  }

  Widget _buildToolbar(double maxWidth) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: _pickDateRange,
              icon: const Icon(Icons.date_range),
              label: Text(_dateRange == null
                  ? 'نطاق التاريخ'
                  : '${DateFormat('dd/MM/yyyy').format(_dateRange!.start)} - ${DateFormat('dd/MM/yyyy').format(_dateRange!.end)}'),
            ),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('مزدوج')),
                ButtonSegment(value: 1, label: Text('ذهب فقط')),
                ButtonSegment(value: 2, label: Text('نقدي فقط')),
              ],
              selected: {_viewMode},
              onSelectionChanged: (value) {
                setState(() => _viewMode = value.first);
              },
            ),
            FilterChip(
              label: const Text('حركات فقط'),
              selected: _showOnlyMovement,
              onSelected: (value) {
                setState(() {
                  _showOnlyMovement = value;
                  _filterLines();
                });
              },
            ),
            FilterChip(
              label: const Text('تفصيل العيارات'),
              selected: _includeBreakdown,
              onSelected: (value) {
                setState(() => _includeBreakdown = value);
              },
            ),
            _buildExportMenu(),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _filterLines();
                          },
                        ),
                  hintText: 'ابحث في الوصف أو المرجع',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _filterType,
              items: const [
                DropdownMenuItem(value: 'all', child: Text('الكل')),
                DropdownMenuItem(value: 'debit', child: Text('مدين')),
                DropdownMenuItem(value: 'credit', child: Text('دائن')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _filterType = value;
                  _filterLines();
                });
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExportMenu() {
    return ElevatedButton.icon(
      onPressed: _isExporting ? null : _showExportSheet,
      icon: _isExporting
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_download),
      label: const Text('تصدير'),
    );
  }

  Widget _buildStatementTable() {
    final mainKarat = (_statement?.mainKarat ?? 21).toDouble();

    final List<DataColumn> columns = [
      const DataColumn(label: Text('التاريخ', style: TextStyle(fontWeight: FontWeight.bold))),
      const DataColumn(label: Text('البيان', style: TextStyle(fontWeight: FontWeight.bold))),
    ];

    if (_viewMode != 2) {
      columns.addAll(const [
        DataColumn(label: Text('ذهب مدين', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('ذهب دائن', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('رصيد الذهب', style: TextStyle(fontWeight: FontWeight.bold))),
      ]);
    }

    if (_viewMode != 1) {
      columns.addAll(const [
        DataColumn(label: Text('نقد مدين', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('نقد دائن', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('رصيد النقد', style: TextStyle(fontWeight: FontWeight.bold))),
      ]);
    }

    if (_includeBreakdown && _viewMode != 2) {
      columns.add(const DataColumn(label: Text('العيارات', style: TextStyle(fontWeight: FontWeight.bold))));
    }

    final rows = _filteredLines.map((line) {
      final debitMain = _convertToMainKarat(line.debit18k, 18, mainKarat) +
          _convertToMainKarat(line.debit21k, 21, mainKarat) +
          _convertToMainKarat(line.debit22k, 22, mainKarat) +
          _convertToMainKarat(line.debit24k, 24, mainKarat);
      final creditMain = _convertToMainKarat(line.credit18k, 18, mainKarat) +
          _convertToMainKarat(line.credit21k, 21, mainKarat) +
          _convertToMainKarat(line.credit22k, 22, mainKarat) +
          _convertToMainKarat(line.credit24k, 24, mainKarat);

      final cells = <DataCell>[
        DataCell(Text(DateFormat('yyyy-MM-dd').format(line.date))),
        DataCell(_buildDescriptionCell(line)),
      ];

      if (_viewMode != 2) {
        cells.addAll([
          DataCell(_numCell(debitMain, color: Colors.green.shade600)),
          DataCell(_numCell(creditMain, color: Colors.red.shade600)),
          DataCell(_numCell(line.runningGoldBalance, color: Colors.blueGrey.shade700)),
        ]);
      }

      if (_viewMode != 1) {
        cells.addAll([
          DataCell(_numCell(line.cashDebit, color: Colors.green.shade600)),
          DataCell(_numCell(line.cashCredit, color: Colors.red.shade600)),
          DataCell(_numCell(line.runningCashBalance, color: Colors.blueGrey.shade700)),
        ]);
      }

      if (_includeBreakdown && _viewMode != 2) {
        cells.add(DataCell(
          Tooltip(
            message: 'تفاصيل العيارات',
            child: IconButton(
              icon: const Icon(Icons.tune, size: 20),
              onPressed: () => _showLineDetails(line, mainKarat),
            ),
          ),
        ));
      }

      return DataRow(
        cells: cells,
        onSelectChanged: (_) => _showLineDetails(line, mainKarat),
      );
    }).toList();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Scrollbar(
            controller: _horizontalController,
            thumbVisibility: true,
            notificationPredicate: (notification) => notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _horizontalController,
              scrollDirection: Axis.horizontal,
              child: Scrollbar(
                controller: _verticalController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _verticalController,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                      Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    ),
                    columnSpacing: 24,
                    dataRowMinHeight: 48,
                    dataRowMaxHeight: 68,
                    columns: columns,
                    rows: rows,
                  ),
                ),
              ),
            ),
          ),
          if (_statement != null) _buildClosingBreakdown(mainKarat),
        ],
      ),
    );
  }

  Widget _buildClosingBreakdown(double mainKarat) {
    final closingDetails = _statement!.closingBalanceGoldDetails;
    if (closingDetails.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('تفصيل الرصيد الختامي حسب العيارات', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: closingDetails.entries
                .map((entry) => Chip(
                      avatar: const Icon(Icons.scale, size: 16),
                      label: Text('${entry.key}: ${entry.value.toStringAsFixed(3)} جم ≈ ${_convertToMainKarat(entry.value, int.tryParse(entry.key.replaceAll(RegExp(r'[^0-9]'), '')) ?? 21, mainKarat).toStringAsFixed(3)} (${_statement!.mainKarat}k)'),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  double _convertToMainKarat(double value, int karat, double mainKarat) {
    if (value == 0) return 0;
    return (value * karat) / mainKarat;
  }

  Widget _numCell(double? value, {Color? color}) {
    if (value == null || value.abs() < 0.0001) {
      return const Text('', textAlign: TextAlign.center);
    }

    return Text(
      value.toStringAsFixed(3),
      textAlign: TextAlign.center,
      style: TextStyle(color: color ?? Colors.blueGrey.shade800, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildDescriptionCell(StatementLine line) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(line.description, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.key, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('ID: ${line.id}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ],
    );
  }

  void _showLineDetails(StatementLine line, double mainKarat) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.receipt_long),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تفاصيل الحركة - ${DateFormat('dd/MM/yyyy').format(line.date)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_all),
                    onPressed: () async {
                      final summary = _buildLineSummary(line, mainKarat);
                      await Clipboard.setData(ClipboardData(text: summary));
                      if (mounted) {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ التفاصيل')));
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildDetailsRow('الوصف', line.description),
              _buildDetailsRow('رقم السطر', line.id.toString()),
              const Divider(height: 24),
              if (_viewMode != 2) ...[
                _buildDetailsRow('ذهب مدين (عيار ${_statement!.mainKarat})', _convertToMainKarat(line.debit21k + line.debit22k + line.debit24k + line.debit18k, 21, mainKarat).toStringAsFixed(3)),
                _buildDetailsRow('ذهب دائن (عيار ${_statement!.mainKarat})', _convertToMainKarat(line.credit21k + line.credit22k + line.credit24k + line.credit18k, 21, mainKarat).toStringAsFixed(3)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (line.debit18k != 0 || line.credit18k != 0) _buildKaratChip('18k', line.debit18k, line.credit18k),
                    if (line.debit21k != 0 || line.credit21k != 0) _buildKaratChip('21k', line.debit21k, line.credit21k),
                    if (line.debit22k != 0 || line.credit22k != 0) _buildKaratChip('22k', line.debit22k, line.credit22k),
                    if (line.debit24k != 0 || line.credit24k != 0) _buildKaratChip('24k', line.debit24k, line.credit24k),
                  ],
                ),
              ],
              if (_viewMode != 1) ...[
                const Divider(height: 32),
                _buildDetailsRow('نقد مدين', line.cashDebit.toStringAsFixed(2)),
                _buildDetailsRow('نقد دائن', line.cashCredit.toStringAsFixed(2)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailsRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildKaratChip(String label, double debit, double credit) {
    return Chip(
      backgroundColor: Colors.blueGrey.shade50,
      label: Text('$label • مدين ${debit.toStringAsFixed(3)} / دائن ${credit.toStringAsFixed(3)}'),
    );
  }

  String _buildLineSummary(StatementLine line, double mainKarat) {
    final buffer = StringBuffer()
      ..writeln('التاريخ: ${DateFormat('yyyy-MM-dd').format(line.date)}')
      ..writeln('الوصف: ${line.description}')
      ..writeln('رقم السطر: ${line.id}');

    if (_viewMode != 2) {
      buffer
        ..writeln('ذهب مدين (عيار ${_statement!.mainKarat}): ${_convertToMainKarat(line.debit18k + line.debit21k + line.debit22k + line.debit24k, 21, mainKarat).toStringAsFixed(3)}')
        ..writeln('ذهب دائن (عيار ${_statement!.mainKarat}): ${_convertToMainKarat(line.credit18k + line.credit21k + line.credit22k + line.credit24k, 21, mainKarat).toStringAsFixed(3)}');
    }

    if (_viewMode != 1) {
      buffer
        ..writeln('نقد مدين: ${line.cashDebit.toStringAsFixed(2)}')
        ..writeln('نقد دائن: ${line.cashCredit.toStringAsFixed(2)}');
    }

    return buffer.toString();
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final double goldValue;
  final double cashValue;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.title,
    required this.goldValue,
    required this.cashValue,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryMetric(
                    label: 'ذهب (جم)',
                    value: goldValue.toStringAsFixed(3),
                    color: Colors.amber.shade800,
                    icon: Icons.scale,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryMetric(
                    label: 'نقد (ر.س)',
                    value: cashValue.toStringAsFixed(2),
                    color: Colors.green.shade700,
                    icon: Icons.payments,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.8)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                FittedBox(
                  alignment: AlignmentDirectional.centerStart,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 15),
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