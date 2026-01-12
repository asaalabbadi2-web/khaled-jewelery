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
  final String entityType; // 'customer', 'supplier', 'account'

  const AccountStatementScreen({
    super.key,
    required this.accountId,
    required this.accountName,
    this.entityType =
        'account', // default to account for backward compatibility
  });

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

  void _clearFilters() {
    setState(() {
      _dateRange = null;
      _filterType = 'all';
      _showOnlyMovement = false;
    });
    _searchController.clear();
    _filterLines();
  }

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
      Map<String, dynamic> data;

      // Call appropriate API based on entity type
      if (widget.entityType == 'customer') {
        data = await ApiService().getCustomerStatement(widget.accountId);
      } else if (widget.entityType == 'supplier') {
        data = await ApiService().getSupplierStatement(widget.accountId);
      } else {
        data = await ApiService().getAccountStatement(widget.accountId);
      }

      if (!mounted) return;
      setState(() {
        _statement = AccountStatement.fromJson(data);
        _filterLines(); // This will also handle the initial list
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load statement: $e')));
    }
  }

  void _filterLines() {
    if (_statement == null) return;

    setState(() {
      final mainKarat = (_statement?.mainKarat ?? 21).toDouble();
      final query = _searchController.text.trim().toLowerCase();

      var filtered = _statement!.lines.where((line) {
        final date = line.date;
        final description = line.description.toLowerCase();

        final isAfterStartDate =
            _dateRange?.start == null ||
            date.isAfter(_dateRange!.start.subtract(const Duration(days: 1)));
        final isBeforeEndDate =
            _dateRange?.end == null ||
            date.isBefore(_dateRange!.end.add(const Duration(days: 1)));
        final matchesSearch = query.isEmpty
          ? true
          : description.contains(query) ||
              _matchesSearch(line: line, query: query, mainKarat: mainKarat);

        bool matchesFilterType = true;
        if (_filterType == 'credit') {
          matchesFilterType = line.goldCredit > 0 || line.cashCredit > 0;
        } else if (_filterType == 'debit') {
          matchesFilterType = line.goldDebit > 0 || line.cashDebit > 0;
        }

        final hasMovement =
            (line.goldDebit +
                    line.goldCredit +
                    line.cashDebit +
                    line.cashCredit)
                .abs() >
            0.0001;
        final matchesMovement = !_showOnlyMovement || hasMovement;

        return isAfterStartDate &&
            isBeforeEndDate &&
            matchesSearch &&
            matchesFilterType &&
            matchesMovement;
      }).toList();

      // Recalculate running balances for the filtered list
      double runningGold = _statement!.openingBalanceGold;
      double runningCash = _statement!.openingBalanceCash;
      _filteredLines = [];
      for (var line in filtered) {
        runningGold += line.goldDebit - line.goldCredit;
        runningCash += line.cashDebit - line.cashCredit;
        _filteredLines.add(
          line.copyWith(
            runningGoldBalance: runningGold,
            runningCashBalance: runningCash,
          ),
        );
      }
    });
  }

  bool _matchesSearch({
    required StatementLine line,
    required String query,
    required double mainKarat,
  }) {
    final normalizedQuery = query.replaceAll(',', '.');

    final ref = (line.referenceNumber ?? '').toLowerCase();
    if (ref.isNotEmpty && ref.contains(query)) return true;

    final entryNum = (line.entryNumber ?? '').toLowerCase();
    if (entryNum.isNotEmpty && entryNum.contains(query)) return true;

    if (line.id.toString().contains(normalizedQuery)) return true;

    final invoiceId = _tryExtractInvoiceId(line);
    if (invoiceId != null && invoiceId.toString().contains(normalizedQuery)) {
      return true;
    }

    final debitMain =
        _convertToMainKarat(line.debit18k, 18, mainKarat) +
        _convertToMainKarat(line.debit21k, 21, mainKarat) +
        _convertToMainKarat(line.debit22k, 22, mainKarat) +
        _convertToMainKarat(line.debit24k, 24, mainKarat);
    final creditMain =
        _convertToMainKarat(line.credit18k, 18, mainKarat) +
        _convertToMainKarat(line.credit21k, 21, mainKarat) +
        _convertToMainKarat(line.credit22k, 22, mainKarat) +
        _convertToMainKarat(line.credit24k, 24, mainKarat);

    final netGold = debitMain - creditMain;
    final netCash = line.cashDebit - line.cashCredit;

    final candidates = <String>{
      debitMain.toStringAsFixed(3),
      creditMain.toStringAsFixed(3),
      netGold.toStringAsFixed(3),
      (line.runningGoldBalance ?? 0).toStringAsFixed(3),
      line.cashDebit.toStringAsFixed(2),
      line.cashCredit.toStringAsFixed(2),
      netCash.toStringAsFixed(2),
      (line.runningCashBalance ?? 0).toStringAsFixed(2),
      DateFormat('yyyy-MM-dd').format(line.date).toLowerCase(),
    };

    for (final c in candidates) {
      if (c.toLowerCase().contains(normalizedQuery)) return true;
    }

    return false;
  }

  Future<void> _pickDateRange() async {
    final initialDateRange =
        _dateRange ??
        DateTimeRange(
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
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: child!,
        );
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
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 12.0,
            ),
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
                  leading: const Icon(Icons.print),
                  title: const Text('طباعة'),
                  subtitle: const Text('فتح نافذة الطباعة مباشرة'),
                  onTap: () => _handleExport(_printPdf),
                ),
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم نسخ الملخص')),
                      );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('فشل التصدير: $e')));
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
        final debitMain = _convertToMainKarat(
          line.debit18k + line.debit21k + line.debit22k + line.debit24k,
          21,
          mainKarat,
        );
        final creditMain = _convertToMainKarat(
          line.credit18k + line.credit21k + line.credit22k + line.credit24k,
          21,
          mainKarat,
        );
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
    final file = File(
      '${directory.path}/account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv',
    );
    await file.writeAsString(csvData, encoding: utf8);
    await OpenFile.open(file.path);
  }

  Future<void> _exportToPdf() async {
    if (_statement == null) return;

    final bytes = await _buildStatementPdfBytes(pdf.PdfPageFormat.a4);
    await Printing.sharePdf(
      bytes: bytes,
      filename:
          'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
    );
  }

  Future<void> _printPdf() async {
    if (_statement == null) return;
    final filename =
        'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf';
    await Printing.layoutPdf(
      name: filename,
      onLayout: (format) async => _buildStatementPdfBytes(format),
    );
  }

  Future<Uint8List> _buildStatementPdfBytes(
    pdf.PdfPageFormat pageFormat,
  ) async {
    if (_statement == null) return Uint8List(0);

    // Ensure Arabic renders correctly and RTL layout is respected.
    final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final boldFontData = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    final baseFont = pw.Font.ttf(fontData);
    final boldFont = pw.Font.ttf(boldFontData);
    final theme = pw.ThemeData.withFont(base: baseFont, bold: boldFont);

    // We want the printed table to read naturally in Arabic:
    // rightmost: التاريخ, then البيان, then القيم to the left.
    // Some table layouts still behave as LTR, so we build a physical
    // column order that guarantees the desired visual ordering.
    const dateKey = 'date';
    const descKey = 'desc';
    const goldDebitKey = 'gold_debit';
    const goldCreditKey = 'gold_credit';
    const goldBalKey = 'gold_balance';
    const cashDebitKey = 'cash_debit';
    const cashCreditKey = 'cash_credit';
    const cashBalKey = 'cash_balance';

    final valueColumns = <({String key, String header})>[];
    if (_viewMode != 2) {
      valueColumns.addAll([
        (key: goldDebitKey, header: 'ذهب مدين'),
        (key: goldCreditKey, header: 'ذهب دائن'),
        (key: goldBalKey, header: 'رصيد الذهب'),
      ]);
    }
    if (_viewMode != 1) {
      valueColumns.addAll([
        (key: cashDebitKey, header: 'نقد مدين'),
        (key: cashCreditKey, header: 'نقد دائن'),
        (key: cashBalKey, header: 'رصيد النقد'),
      ]);
    }

    // Physical order (left -> right) to achieve (right -> left): date, desc, values.
    final columns = <({String key, String header})>[
      ...valueColumns,
      (key: descKey, header: 'البيان'),
      (key: dateKey, header: 'التاريخ'),
    ];

    pw.Widget dataCellFor({
      required String key,
      required String text,
      pw.Font? font,
      double fontSize = 9,
      pw.Alignment alignment = pw.Alignment.center,
    }) {
      final isRtlText = key == descKey;
      return pw.Align(
        alignment: alignment,
        child: pw.Text(
          text,
          textDirection: isRtlText
              ? pw.TextDirection.rtl
              : pw.TextDirection.ltr,
          style: pw.TextStyle(font: font ?? baseFont, fontSize: fontSize),
        ),
      );
    }

    pw.Widget headerCellFor({
      required String text,
      required pw.Alignment alignment,
    }) {
      return pw.Align(
        alignment: alignment,
        child: pw.Text(
          text,
          textDirection: pw.TextDirection.rtl,
          style: pw.TextStyle(font: boldFont, fontSize: 10),
        ),
      );
    }

    final headerWidgets = columns
        .map(
          (c) => headerCellFor(
            text: c.header,
            alignment: c.key == descKey
                ? pw.Alignment.centerRight
                : pw.Alignment.center,
          ),
        )
        .toList();

    final rowWidgets = _filteredLines.map((line) {
      final mainKarat = (_statement?.mainKarat ?? 21).toDouble();

      final goldDebitMain = _convertToMainKarat(
        line.debit18k + line.debit21k + line.debit22k + line.debit24k,
        21,
        mainKarat,
      );
      final goldCreditMain = _convertToMainKarat(
        line.credit18k + line.credit21k + line.credit22k + line.credit24k,
        21,
        mainKarat,
      );

      final values = <String, String>{
        dateKey: DateFormat('yyyy-MM-dd').format(line.date),
        descKey: line.description,
        goldDebitKey: goldDebitMain.toStringAsFixed(3),
        goldCreditKey: goldCreditMain.toStringAsFixed(3),
        goldBalKey: (line.runningGoldBalance ?? 0).toStringAsFixed(3),
        cashDebitKey: line.cashDebit.toStringAsFixed(2),
        cashCreditKey: line.cashCredit.toStringAsFixed(2),
        cashBalKey: (line.runningCashBalance ?? 0).toStringAsFixed(2),
      };

      return columns.map((c) {
        final alignment = c.key == descKey
            ? pw.Alignment.centerRight
            : pw.Alignment.center;
        return dataCellFor(
          key: c.key,
          text: values[c.key] ?? '',
          alignment: alignment,
        );
      }).toList();
    }).toList();

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        theme: theme,
        build: (context) {
          return [
            pw.Directionality(
              textDirection: pw.TextDirection.rtl,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'كشف حساب ${widget.accountName}',
                    style: pw.TextStyle(font: boldFont, fontSize: 18),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    'تاريخ التوليد: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.SizedBox(height: 12),
                  pw.TableHelper.fromTextArray(
                    headers: headerWidgets,
                    data: rowWidgets,
                    border: pw.TableBorder.all(color: pdf.PdfColors.grey300),
                    headerDecoration: pw.BoxDecoration(
                      color: pdf.PdfColors.grey200,
                    ),
                    cellPadding: const pw.EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 3,
                    ),
                    cellAlignment: pw.Alignment.center,
                    cellAlignments: {
                      for (var i = 0; i < columns.length; i++)
                        i: columns[i].key == descKey
                            ? pw.Alignment.centerRight
                            : pw.Alignment.center,
                    },
                    columnWidths: {
                      for (var i = 0; i < columns.length; i++)
                        i: columns[i].key == descKey
                            ? const pw.FlexColumnWidth(3.2)
                            : (columns[i].key == dateKey
                                  ? const pw.FixedColumnWidth(72)
                                  : const pw.FixedColumnWidth(56)),
                    },
                  ),
                ],
              ),
            ),
          ];
        },
      ),
    );

    return doc.save();
  }

  Future<void> _copySummaryToClipboard() async {
    if (_statement == null) return;

    final statement = _statement!;
    final summary = StringBuffer()
      ..writeln('كشف حساب: ${widget.accountName}')
      ..writeln('عيار أساسي: ${statement.mainKarat}')
      ..writeln(
        'رصيد افتتاحي ذهب: ${statement.openingBalanceGold.toStringAsFixed(3)}',
      )
      ..writeln(
        'رصيد افتتاحي نقد: ${statement.openingBalanceCash.toStringAsFixed(2)}',
      )
      ..writeln(
        'إجمالي ذهب مدين: ${statement.totalDebitGold.toStringAsFixed(3)}',
      )
      ..writeln(
        'إجمالي ذهب دائن: ${statement.totalCreditGold.toStringAsFixed(3)}',
      )
      ..writeln(
        'إجمالي نقد مدين: ${statement.totalDebitCash.toStringAsFixed(2)}',
      )
      ..writeln(
        'إجمالي نقد دائن: ${statement.totalCreditCash.toStringAsFixed(2)}',
      )
      ..writeln(
        'رصيد ختامي ذهب (حسب الكشف): ${statement.closingBalanceGoldNormalized.toStringAsFixed(3)}',
      )
      ..writeln(
        'رصيد ختامي نقد (حسب الكشف): ${statement.closingBalanceCash.toStringAsFixed(2)}',
      );

    if (statement.hasEntityBalances) {
      summary
        ..writeln(
          'الرصيد الحالي ذهب (من الملف): ${statement.effectiveClosingGold.toStringAsFixed(3)}',
        )
        ..writeln(
          'الرصيد الحالي نقد (من الملف): ${statement.effectiveClosingCash.toStringAsFixed(2)}',
        );
    }

    await Clipboard.setData(ClipboardData(text: summary.toString()));
  }

  // Removed unused _exportToCsv

  // Removed unused _exportToPdf

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('كشف حساب ${widget.accountName}')),
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
              const SizedBox(height: 12),
              _buildFilteredTotalsBar(),
              const SizedBox(height: 16),
              _buildStatementTable(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilteredTotalsBar() {
    if (_statement == null) return const SizedBox.shrink();

    final mainKarat = (_statement?.mainKarat ?? 21).toDouble();

    double goldDebit = 0;
    double goldCredit = 0;
    double cashDebit = 0;
    double cashCredit = 0;

    for (final line in _filteredLines) {
      final debitMain =
          _convertToMainKarat(line.debit18k, 18, mainKarat) +
          _convertToMainKarat(line.debit21k, 21, mainKarat) +
          _convertToMainKarat(line.debit22k, 22, mainKarat) +
          _convertToMainKarat(line.debit24k, 24, mainKarat);
      final creditMain =
          _convertToMainKarat(line.credit18k, 18, mainKarat) +
          _convertToMainKarat(line.credit21k, 21, mainKarat) +
          _convertToMainKarat(line.credit22k, 22, mainKarat) +
          _convertToMainKarat(line.credit24k, 24, mainKarat);

      goldDebit += debitMain;
      goldCredit += creditMain;
      cashDebit += line.cashDebit;
      cashCredit += line.cashCredit;
    }

    final theme = Theme.of(context);
    final chips = <Widget>[
      Chip(
        label: Text('النتائج: ${_filteredLines.length}'),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
    ];

    if (_viewMode != 2) {
      chips.addAll([
        Chip(
          label: Text('ذهب مدين: ${goldDebit.toStringAsFixed(3)}'),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        Chip(
          label: Text('ذهب دائن: ${goldCredit.toStringAsFixed(3)}'),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        Chip(
          label: Text(
            'صافي ذهب: ${(goldDebit - goldCredit).toStringAsFixed(3)}',
          ),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ]);
    }

    if (_viewMode != 1) {
      chips.addAll([
        Chip(
          label: Text('نقد مدين: ${cashDebit.toStringAsFixed(2)}'),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        Chip(
          label: Text('نقد دائن: ${cashCredit.toStringAsFixed(2)}'),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        Chip(
          label: Text(
            'صافي نقد: ${(cashDebit - cashCredit).toStringAsFixed(2)}',
          ),
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ]);
    }

    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: chips,
        ),
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

    final closingTitle = statement.hasEntityBalances
        ? 'الرصيد الحالي (من الملف)'
        : 'رصيد ختامي (موزون)';

    final cards = <Widget>[
      _SummaryCard(
        title: 'رصيد افتتاحي (عيار ${statement.mainKarat})',
        goldValue: statement.openingBalanceGold,
        cashValue: statement.openingBalanceCash,
        color: theme.colorScheme.primary,
        icon: Icons.lock_clock,
        mainKarat: statement.mainKarat,
      ),
      _SummaryCard(
        title: 'إجمالي الحركة',
        goldValue: statement.totalDebitGold - statement.totalCreditGold,
        cashValue: statement.totalDebitCash - statement.totalCreditCash,
        color: theme.colorScheme.secondary,
        icon: Icons.sync_alt,
        mainKarat: statement.mainKarat,
      ),
      _SummaryCard(
        title: closingTitle,
        goldValue: statement.effectiveClosingGold,
        cashValue: statement.effectiveClosingCash,
        color: theme.colorScheme.tertiary,
        icon: Icons.summarize,
        mainKarat: statement.mainKarat,
      ),
    ];

    final isCompact = maxWidth < 720;
    final cardWidth = isCompact ? maxWidth : (maxWidth - 24) / 3;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: cards
          .map(
            (card) => SizedBox(
              width: cardWidth.clamp(260, 420).toDouble(),
              child: card,
            ),
          )
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
              label: Text(
                _dateRange == null
                    ? 'نطاق التاريخ'
                    : '${DateFormat('dd/MM/yyyy').format(_dateRange!.start)} - ${DateFormat('dd/MM/yyyy').format(_dateRange!.end)}',
              ),
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
            OutlinedButton.icon(
              onPressed:
                  (_dateRange != null ||
                      _searchController.text.isNotEmpty ||
                      _filterType != 'all' ||
                      _showOnlyMovement)
                  ? _clearFilters
                  : null,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('مسح الفلاتر'),
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
                  hintText: 'ابحث بالبيان / رقم المرجع / المبلغ',
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
    final theme = Theme.of(context);
    final mainKarat = (_statement?.mainKarat ?? 21).toDouble();

    final positiveColor = theme.colorScheme.primary;
    final negativeColor = theme.colorScheme.error;
    final balanceColor = theme.colorScheme.onSurfaceVariant;

    Text heading(String text) {
      return Text(text, style: const TextStyle(fontWeight: FontWeight.bold));
    }

    final List<DataColumn> columns = [
      DataColumn(label: heading('التاريخ')),
      DataColumn(label: heading('البيان')),
    ];

    if (_viewMode != 2) {
      columns.addAll([
        DataColumn(label: heading('حركة الذهب (+/-)')),
        DataColumn(label: heading('رصيد الذهب')),
      ]);
    }

    if (_viewMode != 1) {
      columns.addAll([
        DataColumn(label: heading('حركة النقد (+/-)')),
        DataColumn(label: heading('رصيد النقد')),
      ]);
    }

    if (_includeBreakdown && _viewMode != 2) {
      columns.add(
        const DataColumn(
          label: Text(
            'العيارات',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    final rows = List<DataRow>.generate(_filteredLines.length, (index) {
      final line = _filteredLines[index];
      final debitMain =
          _convertToMainKarat(line.debit18k, 18, mainKarat) +
          _convertToMainKarat(line.debit21k, 21, mainKarat) +
          _convertToMainKarat(line.debit22k, 22, mainKarat) +
          _convertToMainKarat(line.debit24k, 24, mainKarat);
      final creditMain =
          _convertToMainKarat(line.credit18k, 18, mainKarat) +
          _convertToMainKarat(line.credit21k, 21, mainKarat) +
          _convertToMainKarat(line.credit22k, 22, mainKarat) +
          _convertToMainKarat(line.credit24k, 24, mainKarat);

        final goldMovement = debitMain - creditMain;
        final cashMovement = line.cashDebit - line.cashCredit;

      final cells = <DataCell>[
        DataCell(Text(DateFormat('yyyy-MM-dd').format(line.date))),
        DataCell(_buildDescriptionCell(line)),
      ];

      if (_viewMode != 2) {
        cells.addAll([
          DataCell(
            _signedNumCell(
              goldMovement,
              positiveColor: positiveColor,
              negativeColor: negativeColor,
              fractionDigits: 3,
            ),
          ),
          DataCell(
            _numCell(
              line.runningGoldBalance,
              color: balanceColor,
              fractionDigits: 3,
            ),
          ),
        ]);
      }

      if (_viewMode != 1) {
        cells.addAll([
          DataCell(
            _signedNumCell(
              cashMovement,
              positiveColor: positiveColor,
              negativeColor: negativeColor,
              fractionDigits: 2,
            ),
          ),
          DataCell(
            _numCell(
              line.runningCashBalance,
              color: balanceColor,
              fractionDigits: 2,
            ),
          ),
        ]);
      }

      if (_includeBreakdown && _viewMode != 2) {
        cells.add(
          DataCell(
            Tooltip(
              message: 'تفاصيل العيارات',
              child: IconButton(
                icon: const Icon(Icons.tune, size: 20),
                onPressed: () => _showLineDetails(line, mainKarat),
              ),
            ),
          ),
        );
      }

      return DataRow(
        color: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Theme.of(context).colorScheme.primaryContainer;
          }
          return index.isEven
              ? Theme.of(context).colorScheme.surface
              : Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
        }),
        cells: cells,
        onSelectChanged: (_) => _handleRowTap(line, mainKarat),
      );
    });

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Scrollbar(
            controller: _horizontalController,
            thumbVisibility: true,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
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
                      Theme.of(context).colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                    ),
                    headingRowHeight: 48,
                    columnSpacing: 18,
                    dataRowMinHeight: 56,
                    dataRowMaxHeight: 84,
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
    final closingDetails = _statement!.effectiveClosingGoldDetails;
    if (closingDetails.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'تفصيل الرصيد الختامي حسب العيارات',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: closingDetails.entries
                .map(
                  (entry) => Chip(
                    avatar: const Icon(Icons.scale, size: 16),
                    label: Text(
                      '${entry.key}: ${entry.value.toStringAsFixed(3)} جم ≈ ${_convertToMainKarat(entry.value, int.tryParse(entry.key.replaceAll(RegExp(r'[^0-9]'), '')) ?? 21, mainKarat).toStringAsFixed(3)} (${_statement!.mainKarat}k)',
                    ),
                  ),
                )
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

  Widget _numCell(double? value, {Color? color, int fractionDigits = 3}) {
    if (value == null || value.abs() < 0.0001) {
      return const Text('', textAlign: TextAlign.end);
    }

    return Text(
      value.toStringAsFixed(fractionDigits),
      textAlign: TextAlign.end,
      style: TextStyle(
        color: color ?? Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w500,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _signedNumCell(
    double value, {
    required Color positiveColor,
    required Color negativeColor,
    int fractionDigits = 3,
  }) {
    if (value.abs() < 0.0001) {
      return const Text('', textAlign: TextAlign.end);
    }
    final isPositive = value > 0;
    final sign = isPositive ? '+' : '-';
    final absText = value.abs().toStringAsFixed(fractionDigits);
    return Text(
      '$sign$absText',
      textAlign: TextAlign.end,
      style: TextStyle(
        color: isPositive ? positiveColor : negativeColor,
        fontWeight: FontWeight.w500,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }

  Widget _buildDescriptionCell(StatementLine line) {
    final theme = Theme.of(context);
    final icon = _iconForLine(line);
    final subtitle = _subtitleForLine(line);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                line.description,
                style: const TextStyle(fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.tag, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  IconData _iconForLine(StatementLine line) {
    final refType = (line.referenceType ?? '').toLowerCase().trim();
    if (refType == 'invoice') return Icons.receipt_long;
    if (refType == 'voucher') return Icons.payments;
    if (refType == 'journal_entry') return Icons.library_books;
    if (refType == 'manual') return Icons.edit_note;

    final desc = line.description.toLowerCase();
    if (desc.contains('مقايضة')) return Icons.compare_arrows;
    if (desc.contains('سداد') || desc.contains('قبض') || desc.contains('صرف')) {
      return Icons.payments;
    }
    if (desc.contains('فاتورة') || desc.contains('invoice')) {
      return Icons.receipt_long;
    }
    return Icons.notes;
  }

  String _subtitleForLine(StatementLine line) {
    final parts = <String>[];
    if ((line.referenceNumber ?? '').trim().isNotEmpty) {
      parts.add('مرجع: ${line.referenceNumber}');
    } else if ((line.entryNumber ?? '').trim().isNotEmpty) {
      parts.add('قيد: ${line.entryNumber}');
    }
    parts.add('ID: ${line.id}');
    return parts.join(' • ');
  }

  int? _tryExtractInvoiceId(StatementLine line) {
    if ((line.referenceType ?? '').toLowerCase().trim() == 'invoice') {
      return line.referenceId;
    }

    final match = RegExp(
      r'(?:فاتورة|invoice)\s*#?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(line.description);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  Future<void> _handleRowTap(StatementLine line, double mainKarat) async {
    final invoiceId = _tryExtractInvoiceId(line);
    if (invoiceId != null) {
      await _showInvoiceQuickView(invoiceId);
      return;
    }
    _showLineDetails(line, mainKarat);
  }

  Future<void> _showInvoiceQuickView(int invoiceId) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: FutureBuilder<Map<String, dynamic>>(
              future: ApiService().getInvoiceById(invoiceId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 240,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return SizedBox(
                    height: 240,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.error_outline),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'تعذر تحميل تفاصيل الفاتورة (#$invoiceId)',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(snapshot.error.toString()),
                      ],
                    ),
                  );
                }

                final invoice = snapshot.data!;
                final items = (invoice['items'] as List?) ?? const [];
                final invoiceType = (invoice['invoice_type'] ?? '').toString();
                final customerName = (invoice['customer_name'] ?? '').toString();
                final supplierName = (invoice['supplier_name'] ?? '').toString();

                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
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
                              'عرض سريع للفاتورة #$invoiceId',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (invoiceType.isNotEmpty)
                            Chip(label: Text('النوع: $invoiceType')),
                          if (customerName.isNotEmpty && customerName != 'N/A')
                            Chip(label: Text('العميل: $customerName')),
                          if (supplierName.isNotEmpty && supplierName != 'N/A')
                            Chip(label: Text('المورد: $supplierName')),
                          Chip(label: Text('الأصناف: ${items.length}')),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      Expanded(
                        child: items.isEmpty
                            ? const Center(child: Text('لا توجد أصناف'))
                            : ListView.separated(
                                itemCount: items.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  if (item is! Map) {
                                    return ListTile(
                                      title: Text(item.toString()),
                                    );
                                  }

                                  final description =
                                      (item['description'] ?? item['item_name'] ?? '')
                                          .toString();
                                  final karat = (item['karat'] ?? '').toString();
                                  final weight = item['weight_grams'];
                                  final weightText = (weight is num)
                                      ? weight.toDouble().toStringAsFixed(3)
                                      : (weight?.toString() ?? '');

                                  return ListTile(
                                    dense: true,
                                    title: Text(
                                      description.isEmpty
                                          ? 'صنف #${index + 1}'
                                          : description,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: karat.isEmpty
                                        ? null
                                        : Text('عيار: $karat'),
                                    trailing: weightText.isEmpty
                                        ? null
                                        : Text('$weightText جم'),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
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
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_all),
                    onPressed: () async {
                      final summary = _buildLineSummary(line, mainKarat);
                      await Clipboard.setData(ClipboardData(text: summary));
                      if (mounted) {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تم نسخ التفاصيل')),
                        );
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
                _buildDetailsRow(
                  'ذهب مدين (عيار ${_statement!.mainKarat})',
                  _convertToMainKarat(
                    line.debit21k +
                        line.debit22k +
                        line.debit24k +
                        line.debit18k,
                    21,
                    mainKarat,
                  ).toStringAsFixed(3),
                ),
                _buildDetailsRow(
                  'ذهب دائن (عيار ${_statement!.mainKarat})',
                  _convertToMainKarat(
                    line.credit21k +
                        line.credit22k +
                        line.credit24k +
                        line.credit18k,
                    21,
                    mainKarat,
                  ).toStringAsFixed(3),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (line.debit18k != 0 || line.credit18k != 0)
                      _buildKaratChip('18k', line.debit18k, line.credit18k),
                    if (line.debit21k != 0 || line.credit21k != 0)
                      _buildKaratChip('21k', line.debit21k, line.credit21k),
                    if (line.debit22k != 0 || line.credit22k != 0)
                      _buildKaratChip('22k', line.debit22k, line.credit22k),
                    if (line.debit24k != 0 || line.credit24k != 0)
                      _buildKaratChip('24k', line.debit24k, line.credit24k),
                  ],
                ),
              ],
              if (_viewMode != 1) ...[
                const Divider(height: 32),
                _buildDetailsRow('نقد مدين', line.cashDebit.toStringAsFixed(2)),
                _buildDetailsRow(
                  'نقد دائن',
                  line.cashCredit.toStringAsFixed(2),
                ),
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
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildKaratChip(String label, double debit, double credit) {
    return Chip(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      label: Text(
        '$label • مدين ${debit.toStringAsFixed(3)} / دائن ${credit.toStringAsFixed(3)}',
      ),
    );
  }

  String _buildLineSummary(StatementLine line, double mainKarat) {
    final buffer = StringBuffer()
      ..writeln('التاريخ: ${DateFormat('yyyy-MM-dd').format(line.date)}')
      ..writeln('الوصف: ${line.description}')
      ..writeln('رقم السطر: ${line.id}');

    if (_viewMode != 2) {
      buffer
        ..writeln(
          'ذهب مدين (عيار ${_statement!.mainKarat}): ${_convertToMainKarat(line.debit18k + line.debit21k + line.debit22k + line.debit24k, 21, mainKarat).toStringAsFixed(3)}',
        )
        ..writeln(
          'ذهب دائن (عيار ${_statement!.mainKarat}): ${_convertToMainKarat(line.credit18k + line.credit21k + line.credit22k + line.credit24k, 21, mainKarat).toStringAsFixed(3)}',
        );
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
  final int mainKarat;

  const _SummaryCard({
    required this.title,
    required this.goldValue,
    required this.cashValue,
    required this.color,
    required this.icon,
    required this.mainKarat,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final borderColor = theme.colorScheme.outlineVariant;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderColor),
      ),
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
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
                    subtitle: 'مكافئ عيار $mainKarat',
                    color: theme.colorScheme.primary,
                    icon: Icons.scale,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryMetric(
                    label: 'نقد (ر.س)',
                    value: cashValue.toStringAsFixed(2),
                    color: theme.colorScheme.tertiary,
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
  final String? subtitle;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  style: TextStyle(
                    fontSize: 12,
                    color: color.withValues(alpha: 0.8),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                FittedBox(
                  alignment: AlignmentDirectional.centerStart,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: 15,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
