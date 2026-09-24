import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;

import '../api_service.dart';
import '../models/account_statement_model.dart';
import '../pdf/account_statement_pdf_builder.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart' as app_theme;

enum _StatementDisplayMode { table, cards }

enum _StatementSortColumn {
  date,
  description,
  goldMovement,
  goldBalance,
  cashMovement,
  cashBalance,
}

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
  int? _filterKarat; // null=all, 18, 21, 22, 24
  // int? _expandedTransactionId; // Removed: unused


  final ScrollController _contentScrollController = ScrollController();
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();
  final GlobalKey _stickyHeaderKey = GlobalKey();
  double _stickyHeaderMeasuredHeight = 240;

  int _viewMode = 0; // 0: dual, 1: gold, 2: cash
  _StatementDisplayMode _displayMode = _StatementDisplayMode.table;
  bool _showOnlyMovement = false;
  bool _includeBreakdown = true;
  bool _isExporting = false;
  // Default: newest transactions first
  // (field kept for future use)
  bool _resolvedViewModeDefault = false;
  _StatementSortColumn? _sortColumn = _StatementSortColumn.date;
  bool _sortAscending = false; // newest first by default

  bool _pdfIncludeValuation = true;
  int? _pdfViewModeOverride;
  bool _pdfLandscape = false;

  Future<AccountStatementPdfBranding> _resolvePdfBranding({
    required bool fetchIfEmpty,
  }) async {
    SettingsProvider? settingsProvider;
    try {
      settingsProvider = context.read<SettingsProvider>();
    } catch (_) {
      settingsProvider = null;
    }

    if (fetchIfEmpty &&
        settingsProvider != null &&
        settingsProvider.settings.isEmpty) {
      try {
        await settingsProvider.fetchSettings().timeout(
          const Duration(milliseconds: 800),
        );
      } catch (_) {
        // Non-blocking.
      }
    }

    final companyName = (settingsProvider?.companyName ?? '').trim();
    final companyAddress = (settingsProvider?.companyAddress ?? '').trim();
    final companyPhone = (settingsProvider?.companyPhone ?? '').trim();
    final companyVat = (settingsProvider?.companyTaxNumber ?? '').trim();
    final companyCr = (settingsProvider?.companyCrNumber ?? '').trim();
    final showCompanyLogo = settingsProvider?.showCompanyLogo ?? true;
    final companyLogoBase64 =
        (settingsProvider?.settings['company_logo_base64'] ?? '').toString();

    final prefs = await SharedPreferences.getInstance();
    final bw = !(prefs.getBool('print_in_color') ?? true);

    return AccountStatementPdfBranding(
      companyName: companyName,
      companyAddress: companyAddress,
      companyPhone: companyPhone,
      companyVat: companyVat,
      companyCr: companyCr,
      showCompanyLogo: showCompanyLogo,
      companyLogoBase64: companyLogoBase64,
      currencySymbol: settingsProvider?.currencySymbol ?? 'ر.س',
      blackAndWhite: bw,
    );
  }

  static Uint8List _toGrayscaleBytes(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      return Uint8List.fromList(img.encodePng(img.grayscale(decoded)));
    } catch (_) {
      return bytes;
    }
  }

  Future<Uint8List> _resizeImageBytes(Uint8List bytes, int targetSize) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetSize,
        targetHeight: targetSize,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      if (byteData != null) return byteData.buffer.asUint8List();
    } catch (_) {}
    return bytes;
  }

  bool _truthy(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'yes' || s == 'on';
    }
    return false;
  }

  int _defaultViewModeForAccount(Map<String, dynamic> account) {
    // Default cash/bank style accounts to cash-only.
    // Weight/memo accounts keep the dual view by default.
    try {
      final safeType = (account['safe_box_type'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (safeType.isNotEmpty && safeType != 'gold') return 2;
    } catch (_) {}

    try {
      if (_truthy(account['tracks_weight'])) return 0;
    } catch (_) {}

    try {
      final num = (account['account_number'] ?? '').toString().trim();
      if (num.startsWith('7')) return 0;
    } catch (_) {}

    return 2; // cash-only
  }

  ({DateTime startInclusive, DateTime endExclusive}) _rangeBounds(
    DateTimeRange range,
  ) {
    // Normalize to full-day bounds so statements with timestamps behave
    // consistently across summary cards and table filtering.
    final start = DateTime(
      range.start.year,
      range.start.month,
      range.start.day,
    );
    final endExclusive = DateTime(
      range.end.year,
      range.end.month,
      range.end.day,
    ).add(const Duration(days: 1));
    return (startInclusive: start, endExclusive: endExclusive);
  }

  ({double gold, double cash}) _openingBalanceAt(DateTime? start) {
    final statement = _statement;
    if (statement == null || start == null) {
      return (
        gold: statement?.openingBalanceGold ?? 0.0,
        cash: statement?.openingBalanceCash ?? 0.0,
      );
    }

    double gold = statement.openingBalanceGold;
    double cash = statement.openingBalanceCash;

    for (final line in statement.lines) {
      if (line.date.isBefore(start)) {
        gold += line.goldDebit - line.goldCredit;
        cash += line.cashDebit - line.cashCredit;
      }
    }

    return (gold: gold, cash: cash);
  }

  ({
    double openingGold,
    double openingCash,
    double movementGold,
    double movementCash,
    double closingGold,
    double closingCash,
  })
  _periodSummary() {
    final statement = _statement;
    if (statement == null || _dateRange == null) {
      final movementGold = statement == null
          ? 0.0
          : (statement.totalDebitGold - statement.totalCreditGold);
      final movementCash = statement == null
          ? 0.0
          : (statement.totalDebitCash - statement.totalCreditCash);
      return (
        openingGold: statement?.openingBalanceGold ?? 0.0,
        openingCash: statement?.openingBalanceCash ?? 0.0,
        movementGold: movementGold,
        movementCash: movementCash,
        closingGold: statement?.effectiveClosingGold ?? 0.0,
        closingCash: statement?.effectiveClosingCash ?? 0.0,
      );
    }

    final range = _dateRange!;
    final bounds = _rangeBounds(range);
    final opening = _openingBalanceAt(bounds.startInclusive);

    double movementGold = 0.0;
    double movementCash = 0.0;

    for (final line in statement.lines) {
      final dt = line.date;
      final inRange =
          !dt.isBefore(bounds.startInclusive) &&
          dt.isBefore(bounds.endExclusive);
      if (!inRange) continue;
      movementGold += line.goldDebit - line.goldCredit;
      movementCash += line.cashDebit - line.cashCredit;
    }

    return (
      openingGold: opening.gold,
      openingCash: opening.cash,
      movementGold: movementGold,
      movementCash: movementCash,
      closingGold: opening.gold + movementGold,
      closingCash: opening.cash + movementCash,
    );
  }

  ({double goldDebit, double goldCredit, double cashDebit, double cashCredit})
  _periodDebitCreditTotals() {
    final statement = _statement;
    if (statement == null || _dateRange == null) {
      return (
        goldDebit: statement?.totalDebitGold ?? 0.0,
        goldCredit: statement?.totalCreditGold ?? 0.0,
        cashDebit: statement?.totalDebitCash ?? 0.0,
        cashCredit: statement?.totalCreditCash ?? 0.0,
      );
    }

    final range = _dateRange!;
    final bounds = _rangeBounds(range);
    double goldDebit = 0.0;
    double goldCredit = 0.0;
    double cashDebit = 0.0;
    double cashCredit = 0.0;

    for (final line in statement.lines) {
      final dt = line.date;
      final inRange =
          !dt.isBefore(bounds.startInclusive) &&
          dt.isBefore(bounds.endExclusive);
      if (!inRange) continue;
      goldDebit += line.goldDebit;
      goldCredit += line.goldCredit;
      cashDebit += line.cashDebit;
      cashCredit += line.cashCredit;
    }

    return (
      goldDebit: goldDebit,
      goldCredit: goldCredit,
      cashDebit: cashDebit,
      cashCredit: cashCredit,
    );
  }

  void _clearFilters() {
    setState(() {
      _dateRange = null;
      _filterType = 'all';
      _filterKarat = null;
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
    _contentScrollController.addListener(_onContentScroll);
    _verticalController.addListener(_onContentScroll);
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
    _contentScrollController.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  void _onContentScroll() {
    // No-op: collapse animation removed; CustomScrollView handles scroll natively.
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
        if (!_resolvedViewModeDefault) {
          _resolvedViewModeDefault = true;
          try {
            final account = await ApiService().getAccountById(widget.accountId);
            if (mounted) {
              setState(() => _viewMode = _defaultViewModeForAccount(account));
            }
          } catch (_) {
            // Keep the default dual view if metadata fetch fails.
          }
        }

        data = await ApiService().getAccountStatement(widget.accountId);
      }

      if (!mounted) return;
      setState(() {
        _statement = AccountStatement.fromJson(data);
        // The heuristic above guesses the default view mode before the
        // statement loads. is_merged is the backend's actual decision (see
        // the NOTE in routes.py's get_account_statement) -- when present,
        // it overrides the guess so a merged cash+gold statement always
        // opens on "مزدوج" instead of hiding half the data behind a
        // single-type default.
        if (data['is_merged'] == true) {
          _viewMode = 0;
        }
        _filterLines(); // This will also handle the initial list
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تحميل كشف الحساب: $e')));
    }
  }

  String _statementTitle() {
    switch (widget.entityType) {
      case 'supplier':
        return 'كشف حساب المورد: ${widget.accountName}';
      case 'customer':
        return 'كشف حساب العميل: ${widget.accountName}';
      default:
        return 'كشف حساب ${widget.accountName}';
    }
  }

  void _filterLines() {
    if (_statement == null) return;

    setState(() {
      final mainKarat = (_statement?.mainKarat ?? 21).toDouble();
      final query = _searchController.text.trim().toLowerCase();
      final bounds = _dateRange == null ? null : _rangeBounds(_dateRange!);

      var filtered = _statement!.lines.where((line) {
        final date = line.date;
        final description = line.description.toLowerCase();

        final matchesDateRange = bounds == null
            ? true
            : (!date.isBefore(bounds.startInclusive) &&
                  date.isBefore(bounds.endExclusive));
        final matchesSearch = query.isEmpty
            ? true
            : description.contains(query) ||
                  _matchesSearch(
                    line: line,
                    query: query,
                    mainKarat: mainKarat,
                  );

        bool matchesFilterType = true;
        if (_filterType == 'credit') {
          matchesFilterType = line.goldCredit > 0 || line.cashCredit > 0;
        } else if (_filterType == 'debit') {
          matchesFilterType = line.goldDebit > 0 || line.cashDebit > 0;
        }

        bool matchesKarat = true;
        if (_filterKarat != null) {
          final k = _filterKarat!;
          matchesKarat = k == 18
              ? (line.debit18k.abs() + line.credit18k.abs()) > 0.0001
              : k == 21
              ? (line.debit21k.abs() + line.credit21k.abs()) > 0.0001
              : k == 22
              ? (line.debit22k.abs() + line.credit22k.abs()) > 0.0001
              : (line.debit24k.abs() + line.credit24k.abs()) > 0.0001;
        }

        final hasGoldMovement =
            (line.goldDebit + line.goldCredit).abs() > 0.0001;
        final hasCashMovement =
            (line.cashDebit + line.cashCredit).abs() > 0.0001;
        final hasMovement = hasGoldMovement || hasCashMovement;

        // In single-mode views, hide lines that have no movement
        // in the selected dimension to avoid confusion.
        var matchesViewMode = true;
        if (_viewMode == 2) {
          matchesViewMode = hasCashMovement || !hasMovement;
        } else if (_viewMode == 1) {
          matchesViewMode = hasGoldMovement || !hasMovement;
        }

        final matchesMovement =
            (!_showOnlyMovement || hasMovement) && matchesViewMode;

        return matchesDateRange &&
            matchesSearch &&
            matchesFilterType &&
            matchesKarat &&
            matchesMovement;
      }).toList();

      // Recalculate running balances for the filtered list
      final openingAtStart = _openingBalanceAt(bounds?.startInclusive);
      double runningGold = openingAtStart.gold;
      double runningCash = openingAtStart.cash;
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

      _applySort(_filteredLines, mainKarat);
    });
  }

  double _goldMovementForLine(StatementLine line, double mainKarat) {
    return _convertToMainKarat(line.debit18k, 18, mainKarat) +
        _convertToMainKarat(line.debit21k, 21, mainKarat) +
        _convertToMainKarat(line.debit22k, 22, mainKarat) +
        _convertToMainKarat(line.debit24k, 24, mainKarat) -
        _convertToMainKarat(line.credit18k, 18, mainKarat) -
        _convertToMainKarat(line.credit21k, 21, mainKarat) -
        _convertToMainKarat(line.credit22k, 22, mainKarat) -
        _convertToMainKarat(line.credit24k, 24, mainKarat);
  }

  double _cashMovementForLine(StatementLine line) {
    return line.cashDebit - line.cashCredit;
  }

  void _applySort(List<StatementLine> lines, double mainKarat) {
    final sortColumn = _sortColumn;
    if (sortColumn == null || lines.length < 2) return;

    final direction = _sortAscending ? 1 : -1;

    int compareLines(StatementLine a, StatementLine b) {
      late final int result;
      switch (sortColumn) {
        case _StatementSortColumn.date:
          result = a.date.compareTo(b.date);
          break;
        case _StatementSortColumn.description:
          result = a.description.toLowerCase().compareTo(
            b.description.toLowerCase(),
          );
          break;
        case _StatementSortColumn.goldMovement:
          result = _goldMovementForLine(
            a,
            mainKarat,
          ).compareTo(_goldMovementForLine(b, mainKarat));
          break;
        case _StatementSortColumn.goldBalance:
          result = (a.runningGoldBalance ?? 0).compareTo(
            b.runningGoldBalance ?? 0,
          );
          break;
        case _StatementSortColumn.cashMovement:
          result = _cashMovementForLine(a).compareTo(_cashMovementForLine(b));
          break;
        case _StatementSortColumn.cashBalance:
          result = (a.runningCashBalance ?? 0).compareTo(
            b.runningCashBalance ?? 0,
          );
          break;
      }

      if (result != 0) return result * direction;

      final dateResult = a.date.compareTo(b.date);
      if (dateResult != 0) return dateResult * direction;

      return a.id.compareTo(b.id) * direction;
    }

    lines.sort(compareLines);
  }

  void _toggleSort(_StatementSortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = column != _StatementSortColumn.date;
      }
    });
    _filterLines();
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

    if (line.journalEntryId != null &&
        line.journalEntryId.toString().contains(normalizedQuery)) {
      return true;
    }

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
    } catch (e, st) {
      debugPrint('Account statement export failed: $e');
      debugPrintStack(stackTrace: st);
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

    final cashLabel = (_statement?.isMerged ?? false) ? 'قيمة' : 'نقد';

    final headers = <String>['التاريخ', 'الوصف'];
    if (_viewMode != 2) {
      headers.addAll(['ذهب مدين', 'ذهب دائن', 'رصيد الذهب']);
    }
    if (_viewMode != 1) {
      headers.addAll(['$cashLabel مدين', '$cashLabel دائن', 'رصيد $cashLabel']);
    }

    final rows = <List<String>>[headers];
    for (final line in _filteredLines) {
      final row = <String>[
        DateFormat('yyyy-MM-dd').format(line.date),
        line.description,
      ];

      if (_viewMode != 2) {
        row
          ..add(line.goldDebit.toStringAsFixed(3))
          ..add(line.goldCredit.toStringAsFixed(3))
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

    final options = await _askPdfOptions();
    if (options == null) return;

    final branding = await _resolvePdfBranding(fetchIfEmpty: true);

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('جارٍ تجهيز الملف...'),
            ],
          ),
        ),
      );
    }
    try {
      final bytes = await _buildStatementPdfBytes(
        options.landscape
            ? pdf.PdfPageFormat.a4.landscape
            : pdf.PdfPageFormat.a4,
        viewModeOverride: options.viewModeOverride,
        includeValuation: options.includeValuation,
        branding: branding,
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<void> _printPdf() async {
    if (_statement == null) return;

    final options = await _askPdfOptions();
    if (options == null) return;

    // IMPORTANT (Web): keep onLayout free of network/context/provider work.
    // Resolve branding once (best-effort, cached only).
    final branding = await _resolvePdfBranding(fetchIfEmpty: false);

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('جارٍ تجهيز الكشف للطباعة...'),
            ],
          ),
        ),
      );
    }
    final filename =
        'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf';
    try {
      await Printing.layoutPdf(
        name: filename,
        onLayout: (format) async {
          final effectiveFormat = options.landscape ? format.landscape : format;
          return _buildStatementPdfBytes(
            effectiveFormat,
            viewModeOverride: options.viewModeOverride,
            includeValuation: options.includeValuation,
            branding: branding,
          );
        },
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Future<({bool includeValuation, int? viewModeOverride, bool landscape})?>
  _askPdfOptions() async {
    final currentViewMode = _viewMode;
    var includeValuation = _pdfIncludeValuation;
    var viewModeOverride = _pdfViewModeOverride;
    var landscape = _pdfLandscape;

    final cashLabel = (_statement?.isMerged ?? false) ? 'قيمة' : 'نقد';

    final result =
        await showDialog<
          ({bool includeValuation, int? viewModeOverride, bool landscape})
        >(
          context: context,
          builder: (context) {
            return StatefulBuilder(
              builder: (context, setStateDialog) {
                final effectiveViewMode = viewModeOverride ?? currentViewMode;
                return AlertDialog(
                  title: const Text('خيارات الطباعة'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: includeValuation,
                        onChanged: (value) {
                          setStateDialog(() {
                            includeValuation = value ?? true;
                          });
                        },
                        title: const Text(
                          'إظهار التقييم المالي للذهب (السعر اللحظي)',
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: landscape,
                        onChanged: (value) {
                          setStateDialog(() {
                            landscape = value;
                          });
                        },
                        title: const Text('طباعة بالعرض (Landscape)'),
                      ),
                      const SizedBox(height: 8),
                      const Text('نمط الطباعة:'),
                      const SizedBox(height: 6),
                      DropdownButton<int>(
                        value: effectiveViewMode,
                        isDense: true,
                        items: [
                          DropdownMenuItem(
                            value: 0,
                            child: Text('ذهب + $cashLabel'),
                          ),
                          const DropdownMenuItem(
                            value: 1,
                            child: Text('ذهب فقط'),
                          ),
                          DropdownMenuItem(
                            value: 2,
                            child: Text('$cashLabel فقط'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setStateDialog(() {
                            viewModeOverride = (value == currentViewMode)
                                ? null
                                : value;
                          });
                        },
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('إلغاء'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop((
                          includeValuation: includeValuation,
                          viewModeOverride: viewModeOverride,
                          landscape: landscape,
                        ));
                      },
                      child: const Text('متابعة'),
                    ),
                  ],
                );
              },
            );
          },
        );

    if (!mounted) return null;
    if (result == null) return null;

    setState(() {
      _pdfIncludeValuation = result.includeValuation;
      _pdfViewModeOverride = result.viewModeOverride;
      _pdfLandscape = result.landscape;
    });

    return result;
  }

  Future<Uint8List> _buildStatementPdfBytes(
    pdf.PdfPageFormat pageFormat, {
    int? viewModeOverride,
    bool includeValuation = true,
    required AccountStatementPdfBranding branding,
  }) async {
    if (_statement == null) return Uint8List(0);

    final statement = _statement!;
    final effectiveViewMode = viewModeOverride ?? _viewMode;

    // Pre-load assets on the main isolate; rootBundle is not available in
    // spawned isolates, so we pass the raw bytes to the builder instead.
    final fontBytes = (await rootBundle.load(
      'assets/fonts/Cairo-Regular.ttf',
    )).buffer.asUint8List();
    final boldFontBytes = (await rootBundle.load(
      'assets/fonts/Cairo-Bold.ttf',
    )).buffer.asUint8List();
    Uint8List? fallbackLogoBytes;
    try {
      final raw = (await rootBundle.load(
        'assets/KHGL.png',
      )).buffer.asUint8List();
      var resized = await _resizeImageBytes(raw, 128);
      fallbackLogoBytes = branding.blackAndWhite ? _toGrayscaleBytes(resized) : resized;
    } catch (_) {}

    // Pre-decode and resize the base64 company logo (main isolate only).
    Uint8List? preloadedLogo;
    if (branding.showCompanyLogo &&
        branding.companyLogoBase64.trim().isNotEmpty) {
      try {
        final b64 = branding.companyLogoBase64.trim();
        final commaIdx = b64.indexOf(',');
        final payload = (b64.startsWith('data:') && commaIdx >= 0)
            ? b64.substring(commaIdx + 1)
            : b64;
        final decoded = base64Decode(payload);
        var resized = await _resizeImageBytes(decoded, 128);
        preloadedLogo = branding.blackAndWhite ? _toGrayscaleBytes(resized) : resized;
      } catch (_) {}
    }

    // Capture primitives so the closure only sends isolate-safe values.
    final fmtW = pageFormat.width;
    final fmtH = pageFormat.height;
    final fmtML = pageFormat.marginLeft;
    final fmtMR = pageFormat.marginRight;
    final fmtMT = pageFormat.marginTop;
    final fmtMB = pageFormat.marginBottom;

    final lines = List<StatementLine>.of(_filteredLines);
    final accountName = widget.accountName;
    final accountId = widget.accountId;
    final rangeStart = _dateRange?.start;
    final rangeEnd = _dateRange?.end;
    final filterType = _filterType;
    final showOnlyMovement = _showOnlyMovement;

    final fmt = pdf.PdfPageFormat(
      fmtW,
      fmtH,
      marginLeft: fmtML,
      marginRight: fmtMR,
      marginTop: fmtMT,
      marginBottom: fmtMB,
    );
    final dateRange = rangeStart != null
        ? DateTimeRange(start: rangeStart, end: rangeEnd!)
        : null;

    Future<Uint8List> buildPdf() => AccountStatementPdfBuilder.build(
      fmt,
      statement: statement,
      tableLines: lines,
      accountName: accountName,
      accountId: accountId,
      viewMode: effectiveViewMode,
      includeValuation: includeValuation,
      dateRange: dateRange,
      filterType: filterType,
      showOnlyMovement: showOnlyMovement,
      branding: branding,
      preloadedRegularFont: fontBytes,
      preloadedBoldFont: boldFontBytes,
      preloadedFallbackLogo: fallbackLogoBytes,
      preloadedLogo: preloadedLogo,
    );

    // dart:isolate is not supported on Flutter Web — run directly there.
    if (kIsWeb) return buildPdf();

    // On native: offload to a background isolate so the spinner animates freely.
    return Isolate.run(buildPdf);
  }

  Future<void> _copySummaryToClipboard() async {
    if (_statement == null) return;

    final statement = _statement!;
    final period = _periodSummary();
    final totals = _periodDebitCreditTotals();
    final summary = StringBuffer()
      ..writeln('كشف حساب: ${widget.accountName}')
      ..writeln('عيار أساسي: ${statement.mainKarat}')
      ..writeln('رصيد افتتاحي ذهب: ${period.openingGold.toStringAsFixed(3)}')
      ..writeln('رصيد افتتاحي نقد: ${period.openingCash.toStringAsFixed(2)}')
      ..writeln('إجمالي ذهب مدين: ${totals.goldDebit.toStringAsFixed(3)}')
      ..writeln('إجمالي ذهب دائن: ${totals.goldCredit.toStringAsFixed(3)}')
      ..writeln('إجمالي نقد مدين: ${totals.cashDebit.toStringAsFixed(2)}')
      ..writeln('إجمالي نقد دائن: ${totals.cashCredit.toStringAsFixed(2)}')
      ..writeln(
        'رصيد ختامي ذهب (حسب الكشف): ${(_dateRange == null ? statement.closingBalanceGoldNormalized : period.closingGold).toStringAsFixed(3)}',
      )
      ..writeln(
        'رصيد ختامي نقد (حسب الكشف): ${(_dateRange == null ? statement.closingBalanceCash : period.closingCash).toStringAsFixed(2)}',
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
      appBar: AppBar(
        title: Text(_statementTitle()),
        actions: [
          IconButton(
            tooltip: _displayMode == _StatementDisplayMode.table
                ? 'عرض البطاقات'
                : 'عرض الجدول',
            icon: Icon(
              _displayMode == _StatementDisplayMode.table
                  ? Icons.view_agenda_outlined
                  : Icons.table_rows_outlined,
            ),
            onPressed: () {
              setState(() {
                _displayMode = _displayMode == _StatementDisplayMode.table
                    ? _StatementDisplayMode.cards
                    : _StatementDisplayMode.table;
              });
              _onContentScroll();
            },
          ),
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _fetchAccountStatement,
          ),
        ],
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
    final isCard = _displayMode == _StatementDisplayMode.cards;
    final filteredLines = _filteredLines;
    final mainKarat = (_statement?.mainKarat ?? 21).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final toolbarWidget = _buildToolbar(constraints.maxWidth);
        final totalsWidget = _buildFilteredTotalsBar();
        _measureStickyHeaderHeight();

        return RefreshIndicator(
          onRefresh: _fetchAccountStatement,
          child: CustomScrollView(
            controller: _contentScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Summary cards — scroll away with page
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _buildSummaryOverview(constraints.maxWidth - 32),
                ),
              ),

              // ── Sticky: Filter toolbar + totals bar ─────────────────
              SliverPersistentHeader(
                pinned: true,
                floating: true,
                delegate: _PinnedWidgetDelegate(
                  height: _stickyHeaderMeasuredHeight,
                  child: KeyedSubtree(
                    key: _stickyHeaderKey,
                    child: Material(
                      elevation: 2,
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: toolbarWidget,
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                            child: totalsWidget,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Transaction list
              if (filteredLines.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: _buildEmptyLinesState(),
                  ),
                )
              else if (isCard)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  sliver: SliverList.separated(
                    itemCount: filteredLines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _buildLineCard(filteredLines[index], mainKarat),
                  ),
                )
              else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: _buildStatementTable(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _buildClosingBreakdownSliver(mainKarat),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _measureStickyHeaderHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _stickyHeaderKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox) return;
      final measuredHeight = renderObject.size.height;
      if (measuredHeight <= 0) return;
      if ((measuredHeight - _stickyHeaderMeasuredHeight).abs() < 0.5) return;
      setState(() {
        _stickyHeaderMeasuredHeight = measuredHeight;
      });
    });
  }


  Widget _buildEmptyLinesState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            'لا توجد حركات مطابقة',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'عدّل الفلاتر أو ابحث بمعايير أخرى لإظهار النتائج',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.56),
            ),
          ),
        ],
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

    final period = _periodSummary();

    final closingTitle = statement.hasEntityBalances
        ? 'الرصيد الحالي (من الملف)'
        : 'رصيد ختامي (موزون)';

    final openingTitle = _dateRange == null
        ? 'رصيد افتتاحي (عيار ${statement.mainKarat})'
        : 'رصيد افتتاحي للفترة (عيار ${statement.mainKarat})';

    final movementTitle = _dateRange == null ? 'إجمالي الحركة' : 'حركة الفترة';

    final cards = <Widget>[
      _SummaryCard(
        title: openingTitle,
        goldValue: period.openingGold,
        cashValue: period.openingCash,
        color: theme.colorScheme.primary,
        icon: Icons.lock_clock,
        mainKarat: statement.mainKarat,
      ),
      _SummaryCard(
        title: movementTitle,
        goldValue: period.movementGold,
        cashValue: period.movementCash,
        color: theme.colorScheme.secondary,
        icon: Icons.sync_alt,
        mainKarat: statement.mainKarat,
      ),
      _SummaryCard(
        title: closingTitle,
        goldValue: _dateRange == null
            ? statement.effectiveClosingGold
            : period.closingGold,
        cashValue: _dateRange == null
            ? statement.effectiveClosingCash
            : period.closingCash,
        color: theme.colorScheme.tertiary,
        icon: Icons.summarize,
        mainKarat: statement.mainKarat,
      ),
    ];

    final hasLivePrice =
        (statement.goldPricePerGramMainKarat ?? 0) > 0 ||
        (statement.valuationTotalValueEstimate ?? 0) != 0;

    if (hasLivePrice) {
      cards.add(
        _ValuationCard(
          mainKarat: statement.mainKarat,
          pricePerGramMainKarat: statement.goldPricePerGramMainKarat,
          priceSource: statement.goldPriceSource,
          priceUpdatedAt: statement.goldPriceUpdatedAt,
          totalValueEstimate: statement.valuationTotalValueEstimate,
          goldValueEstimate: statement.valuationGoldValueEstimate,
        ),
      );
    }

    final isCompact = maxWidth < 720;

    if (isCompact) {
      // Cards scroll horizontally as one row instead of stacking full-width,
      // so they don't push the table/list far below the fold on small screens.
      return SizedBox(
        height: 180,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, index) =>
              SizedBox(width: 280, child: cards[index]),
        ),
      );
    }

    final cardsPerRow = cards.length == 4 ? 2 : 3;
    final cardWidth = (maxWidth - (12 * (cardsPerRow - 1))) / cardsPerRow;

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

  int get _activeFiltersCount {
    int count = 0;
    if (_dateRange != null) count++;
    if (_searchController.text.trim().isNotEmpty) count++;
    if (_filterType != 'all') count++;
    if (_filterKarat != null) count++;
    if (_showOnlyMovement) count++;
    if (!_includeBreakdown) count++;
    if (_viewMode != 0) count++;
    return count;
  }

  Widget _buildToolbar(double maxWidth) {
    final isNarrow = maxWidth < 500;
    final isCompact = maxWidth < 700;

    // View-mode labels
    const viewModeLabels = {0: 'مزدوج', 1: 'ذهب فقط', 2: 'نقدي فقط'};

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildFilterRow(
                  isCompact: isCompact,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'النتائج: ${_filteredLines.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'الفلاتر النشطة: $_activeFiltersCount',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_activeFiltersCount > 0)
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('مسح الفلاتر'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildFilterRow(
            isCompact: isCompact,
            children: [
              SizedBox(
                width: isNarrow ? 180 : (isCompact ? 240 : 420),
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
                    hintText: isNarrow
                        ? 'بحث...'
                        : 'ابحث بالبيان أو المرجع أو رقم القيد أو المبلغ',
                    isDense: isNarrow,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.date_range, size: 18),
                label: Text(
                  _dateRange == null
                      ? 'نطاق التاريخ'
                      : '${DateFormat('dd/MM/yyyy').format(_dateRange!.start)} - ${DateFormat('dd/MM/yyyy').format(_dateRange!.end)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  value: _filterType,
                  decoration: const InputDecoration(
                    labelText: 'النوع',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('الكل')),
                    DropdownMenuItem(value: 'debit', child: Text('مدين')),
                    DropdownMenuItem(value: 'credit', child: Text('دائن')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _filterType = value;
                    });
                    _filterLines();
                  },
                ),
              ),
              if (isNarrow)
                SizedBox(
                  width: 130,
                  child: DropdownButtonFormField<int>(
                    value: _viewMode,
                    decoration: const InputDecoration(
                      labelText: 'العرض',
                      isDense: true,
                    ),
                    items: viewModeLabels.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _viewMode = value);
                      _filterLines();
                    },
                  ),
                )
              else
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('مزدوج')),
                    ButtonSegment(value: 1, label: Text('ذهب فقط')),
                    ButtonSegment(value: 2, label: Text('نقدي فقط')),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (value) {
                    setState(() => _viewMode = value.first);
                    _filterLines();
                  },
                ),
              if (_viewMode == 1 || _viewMode == 0)
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<int?>(
                    value: _filterKarat,
                    decoration: const InputDecoration(
                      labelText: 'العيار',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: null, child: Text('الكل')),
                      DropdownMenuItem(value: 18, child: Text('18')),
                      DropdownMenuItem(value: 21, child: Text('21')),
                      DropdownMenuItem(value: 22, child: Text('22')),
                      DropdownMenuItem(value: 24, child: Text('24')),
                    ],
                    onChanged: (value) {
                      setState(() => _filterKarat = value);
                      _filterLines();
                    },
                  ),
                ),
              FilterChip(
                label: const Text('حركات فقط'),
                selected: _showOnlyMovement,
                onSelected: (value) {
                  setState(() {
                    _showOnlyMovement = value;
                  });
                  _filterLines();
                },
              ),
              FilterChip(
                label: const Text('تفصيل العيارات'),
                selected: _includeBreakdown,
                onSelected: (value) {
                  setState(() {
                    _includeBreakdown = value;
                  });
                },
              ),
              _buildExportMenu(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow({
    required bool isCompact,
    required List<Widget> children,
  }) {
    if (!isCompact) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            children[i],
          ],
        ],
      ),
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
    final cashLabel = (_statement?.isMerged ?? false) ? 'القيمة' : 'النقد';
    final viewportWidth = MediaQuery.sizeOf(context).width - 48;
    final widths = <String, double>{
      'date': 120,
      'description': 340,
      if (_viewMode != 2) 'gold_movement': 150,
      if (_viewMode != 2) 'gold_balance': 140,
      if (_viewMode != 1) 'cash_movement': 150,
      if (_viewMode != 1) 'cash_balance': 150,
      if (_includeBreakdown && _viewMode != 2) 'breakdown': 170,
      'actions': 56,
    };
    final baseWidth = widths.values.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    final tableWidth = viewportWidth > baseWidth ? viewportWidth : baseWidth;
    final extraWidth = tableWidth - baseWidth;
    if (extraWidth > 0) {
      widths['description'] = (widths['description'] ?? 0) + extraWidth;
    }

    Widget headerCell({
      required String label,
      required double width,
      AlignmentGeometry alignment = AlignmentDirectional.centerStart,
      _StatementSortColumn? sortColumn,
    }) {
      final isSortable = sortColumn != null;
      final isActive = sortColumn != null && _sortColumn == sortColumn;
      final indicatorColor = isActive
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);

      return SizedBox(
        width: width,
        height: double.infinity,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isSortable ? () => _toggleSort(sortColumn) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: alignment,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: isActive ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ),
                  if (isSortable) ...[
                    const SizedBox(width: 6),
                    Icon(
                      isActive
                          ? (_sortAscending
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded)
                          : Icons.unfold_more_rounded,
                      size: 16,
                      color: indicatorColor,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget bodyCell({
      required double width,
      required Widget child,
      AlignmentGeometry alignment = AlignmentDirectional.centerStart,
    }) {
      return Container(
        width: width,
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: alignment,
        child: child,
      );
    }

    final tableHeight = (MediaQuery.sizeOf(context).height * 0.55).clamp(
      320.0,
      640.0,
    );

    return SizedBox(
      height: tableHeight,
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Scrollbar(
          controller: _horizontalController,
              thumbVisibility: true,
              notificationPredicate: (notification) =>
                  notification.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: tableWidth,
                  child: Column(
                    children: [
                      Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          border: Border(
                            bottom: BorderSide(
                              color: theme.colorScheme.outline.withValues(
                                alpha: 0.14,
                              ),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            headerCell(
                              label: 'التاريخ',
                              width: widths['date']!,
                              alignment: Alignment.center,
                              sortColumn: _StatementSortColumn.date,
                            ),
                            headerCell(
                              label: 'البيان',
                              width: widths['description']!,
                              sortColumn: _StatementSortColumn.description,
                            ),
                            if (_viewMode != 2)
                              headerCell(
                                label: 'حركة الذهب (+/-)',
                                width: widths['gold_movement']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.goldMovement,
                              ),
                            if (_viewMode != 2)
                              headerCell(
                                label: 'رصيد الذهب',
                                width: widths['gold_balance']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.goldBalance,
                              ),
                            if (_viewMode != 1)
                              headerCell(
                                label: 'حركة $cashLabel (+/-)',
                                width: widths['cash_movement']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.cashMovement,
                              ),
                            if (_viewMode != 1)
                              headerCell(
                                label: 'رصيد $cashLabel',
                                width: widths['cash_balance']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.cashBalance,
                              ),
                            if (_includeBreakdown && _viewMode != 2)
                              headerCell(
                                label: 'العيارات',
                                width: widths['breakdown']!,
                                alignment: Alignment.center,
                              ),
                            headerCell(
                              label: '⋮',
                              width: widths['actions']!,
                              alignment: Alignment.center,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _fetchAccountStatement,
                          child: ListView.builder(
                            controller: _verticalController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: _filteredLines.length,
                            itemBuilder: (context, index) {
                              final line = _filteredLines[index];
                              final goldMovement = _goldMovementForLine(
                                line,
                                mainKarat,
                              );
                              final cashMovement = _cashMovementForLine(line);

                              return Material(
                                color: index.isEven
                                    ? theme.colorScheme.surface
                                    : theme.colorScheme.surfaceContainerHighest
                                          .withValues(alpha: 0.22),
                                child: InkWell(
                                  onTap: () => _handleRowTap(line, mainKarat),
                                  child: Container(
                                    height: 72,
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: theme.colorScheme.outline
                                              .withValues(alpha: 0.08),
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        bodyCell(
                                          width: widths['date']!,
                                          alignment: Alignment.center,
                                          child: Text(
                                            DateFormat(
                                              'yyyy-MM-dd',
                                            ).format(line.date),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                        bodyCell(
                                          width: widths['description']!,
                                          child: _buildDescriptionCell(line),
                                        ),
                                        if (_viewMode != 2)
                                          bodyCell(
                                            width: widths['gold_movement']!,
                                            alignment:
                                                AlignmentDirectional.centerEnd,
                                            child: _signedNumCell(
                                              goldMovement,
                                              positiveColor:
                                                  theme.colorScheme.primary,
                                              negativeColor:
                                                  theme.colorScheme.error,
                                              fractionDigits: 3,
                                            ),
                                          ),
                                        if (_viewMode != 2)
                                          bodyCell(
                                            width: widths['gold_balance']!,
                                            alignment:
                                                AlignmentDirectional.centerEnd,
                                            child: _numCell(
                                              line.runningGoldBalance,
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              fractionDigits: 3,
                                            ),
                                          ),
                                        if (_viewMode != 1)
                                          bodyCell(
                                            width: widths['cash_movement']!,
                                            alignment:
                                                AlignmentDirectional.centerEnd,
                                            child: _signedNumCell(
                                              cashMovement,
                                              positiveColor:
                                                  theme.colorScheme.primary,
                                              negativeColor:
                                                  theme.colorScheme.error,
                                              fractionDigits: 2,
                                            ),
                                          ),
                                        if (_viewMode != 1)
                                          bodyCell(
                                            width: widths['cash_balance']!,
                                            alignment:
                                                AlignmentDirectional.centerEnd,
                                            child: _numCell(
                                              line.runningCashBalance,
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              fractionDigits: 2,
                                            ),
                                          ),
                                        if (_includeBreakdown && _viewMode != 2)
                                          bodyCell(
                                            width: widths['breakdown']!,
                                            alignment: Alignment.center,
                                            child: OutlinedButton(
                                              onPressed: () => _showLineDetails(
                                                line,
                                                mainKarat,
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                minimumSize: const Size(0, 36),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                    ),
                                              ),
                                              child: const Text('تفصيل'),
                                            ),
                                          ),
                                        bodyCell(
                                          width: widths['actions']!,
                                          alignment: Alignment.center,
                                          child: PopupMenuButton<String>(
                                            onSelected: (value) {
                                              if (value == 'details') {
                                                _showLineDetails(
                                                  line,
                                                  mainKarat,
                                                );
                                              } else if (value == 'copy') {
                                                Clipboard.setData(
                                                  ClipboardData(
                                                    text: _buildLineSummary(
                                                      line,
                                                      mainKarat,
                                                    ),
                                                  ),
                                                );
                                                ScaffoldMessenger.of(
                                                  context,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'تم نسخ ملخص الحركة',
                                                    ),
                                                  ),
                                                );
                                              }
                                            },
                                            itemBuilder: (context) => const [
                                              PopupMenuItem(
                                                value: 'details',
                                                child: Text('التفاصيل'),
                                              ),
                                              PopupMenuItem(
                                                value: 'copy',
                                                child: Text('نسخ الملخص'),
                                              ),
                                            ],
                                            child: Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: theme
                                                    .colorScheme
                                                    .surfaceContainerHighest
                                                    .withValues(alpha: 0.7),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: const Icon(
                                                Icons.more_horiz,
                                                size: 18,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
  }

  Widget _buildClosingBreakdownSliver(double mainKarat) {
    if (_statement == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: _buildClosingBreakdown(mainKarat),
    );
  }

  Widget _buildLineCard(StatementLine line, double mainKarat) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final goldMovement =
        _convertToMainKarat(line.debit18k, 18, mainKarat) +
        _convertToMainKarat(line.debit21k, 21, mainKarat) +
        _convertToMainKarat(line.debit22k, 22, mainKarat) +
        _convertToMainKarat(line.debit24k, 24, mainKarat) -
        _convertToMainKarat(line.credit18k, 18, mainKarat) -
        _convertToMainKarat(line.credit21k, 21, mainKarat) -
        _convertToMainKarat(line.credit22k, 22, mainKarat) -
        _convertToMainKarat(line.credit24k, 24, mainKarat);
    final cashMovement = line.cashDebit - line.cashCredit;
    final subtitle = _subtitleForLine(line);

    Widget metricTile({
      required String label,
      required String movement,
      required String balance,
      required Color color,
      required IconData icon,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    Text(
                      movement,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'الرصيد: $balance',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
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

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _handleRowTap(line, mainKarat),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_iconForLine(line), color: colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          line.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${DateFormat('dd/MM/yyyy').format(line.date)}${subtitle.isEmpty ? '' : ' • $subtitle'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'details') {
                        _showLineDetails(line, mainKarat);
                      } else if (value == 'copy') {
                        Clipboard.setData(
                          ClipboardData(
                            text: _buildLineSummary(line, mainKarat),
                          ),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تم نسخ ملخص الحركة')),
                        );
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'details', child: Text('التفاصيل')),
                      PopupMenuItem(value: 'copy', child: Text('نسخ الملخص')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_viewMode != 2)
                    metricTile(
                      label: 'حركة الذهب',
                      movement: goldMovement.toStringAsFixed(3),
                      balance: (line.runningGoldBalance ?? 0).toStringAsFixed(
                        3,
                      ),
                      color: const Color(0xFFD4A017),
                      icon: Icons.auto_awesome_outlined,
                    ),
                  if (_viewMode != 2 && _viewMode != 1)
                    const SizedBox(width: 8),
                  if (_viewMode != 1)
                    metricTile(
                      label: (_statement?.isMerged ?? false)
                          ? 'حركة القيمة'
                          : 'حركة النقد',
                      movement: cashMovement.toStringAsFixed(2),
                      balance: (line.runningCashBalance ?? 0).toStringAsFixed(
                        2,
                      ),
                      color: Colors.green,
                      icon: Icons.payments_outlined,
                    ),
                ],
              ),
              if (_includeBreakdown && _viewMode != 2) ...[
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
            ],
          ),
        ),
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
            Icon(
              Icons.tag,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
    if (line.journalEntryId != null) {
      parts.add('# ${line.journalEntryId}');
    }
    return parts.join(' • ');
  }

  int? _tryExtractInvoiceId(StatementLine line) {
    // Only treat it as an invoice when the backend explicitly marks it so.
    // Parsing invoice numbers from description is ambiguous (often not the DB ID)
    // and causes 404s when calling /api/invoices/<id>.
    if ((line.referenceType ?? '').toLowerCase().trim() != 'invoice') {
      return null;
    }
    return line.referenceId;
  }

  Future<void> _handleRowTap(StatementLine line, double mainKarat) async {
    final refType = (line.referenceType ?? '').toLowerCase().trim();
    final refId   = line.referenceId;

    if (refType == 'invoice' && refId != null) {
      await _showDocumentSheet(
        title: 'فاتورة${line.referenceNumber != null ? "  #${line.referenceNumber}" : ""}',
        icon: Icons.receipt_long,
        future: ApiService().getInvoiceById(refId),
        builder: _buildInvoiceContent,
      );
    } else if (refType == 'voucher' && refId != null) {
      await _showDocumentSheet(
        title: 'سند${line.referenceNumber != null ? "  #${line.referenceNumber}" : ""}',
        icon: Icons.payments,
        future: ApiService().getVoucher(refId),
        builder: _buildVoucherContent,
      );
    } else if (refType == 'invoice_payments' && refId != null) {
      // دفعة نقدية مرتبطة بفاتورة — نعرض الفاتورة بكامل تفاصيلها
      await _showDocumentSheet(
        title: 'دفعة فاتورة${line.referenceNumber != null ? "  #${line.referenceNumber}" : ""}',
        icon: Icons.payments_outlined,
        future: ApiService().getInvoiceById(refId),
        builder: _buildInvoiceContent,
      );
    } else if (refType == 'journal_entry' ||
               (refType.isEmpty && line.journalEntryId != null)) {
      final jeId = refId ?? line.journalEntryId!;
      await _showDocumentSheet(
        title: 'قيد يومية${line.entryNumber != null ? "  #${line.entryNumber}" : ""}',
        icon: Icons.library_books,
        future: ApiService().getJournalEntryById(jeId),
        builder: _buildJournalEntryContent,
      );
    } else {
      _showLineDetails(line, mainKarat);
    }
  }

  // ── عرض وثيقة مصدر في BottomSheet قابل للتمدد ──────────────────────────

  Future<void> _showDocumentSheet({
    required String title,
    required IconData icon,
    required Future<Map<String, dynamic>> future,
    required Widget Function(Map<String, dynamic> data) builder,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Material(
            child: Column(
              children: [
                // ── Handle ──────────────────────────────────────────────
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // ── Header ─────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
                  child: Row(
                    children: [
                      Icon(icon, color: app_theme.AppColors.primaryGold, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // ── Content ────────────────────────────────────────────
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: future,
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError || !snap.hasData) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline, size: 40, color: Colors.red),
                                const SizedBox(height: 12),
                                Text(
                                  'تعذّر تحميل تفاصيل الوثيقة',
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  snap.error?.toString() ?? '',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      return SingleChildScrollView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        child: builder(snap.data!),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── بناء محتوى الفاتورة ──────────────────────────────────────────────────

  Widget _buildInvoiceContent(Map<String, dynamic> inv) {
    final invoiceNumber = inv['invoice_number']?.toString() ?? inv['id']?.toString() ?? '—';
    final invoiceType   = inv['invoice_type']?.toString() ?? '';
    final date          = inv['date']?.toString().substring(0, 10) ?? '—';
    final status        = (inv['is_posted'] == true || inv['status'] == 'posted') ? 'مُرحَّل' : 'مسودة';
    final statusColor   = status == 'مُرحَّل' ? Colors.green : Colors.orange;
    final customerName  = inv['customer_name']?.toString() ?? '';
    final supplierName  = inv['supplier_name']?.toString() ?? '';
    final total         = (inv['total'] as num?)?.toDouble() ?? 0.0;
    final paid          = (inv['amount_paid'] as num?)?.toDouble() ?? 0.0;
    final remaining     = total - paid;
    final totalWeight   = (inv['total_weight'] as num?)?.toDouble();
    final totalTax      = (inv['total_tax'] as num?)?.toDouble() ?? 0.0;
    final postedBy      = inv['posted_by']?.toString() ?? '';
    final notes         = inv['notes']?.toString() ?? '';
    final items         = (inv['items'] as List?) ?? [];
    final currency      = context.read<SettingsProvider>().currencySymbolText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── شريط الحالة ─────────────────────────────────────────────────
        Wrap(
          spacing: 8, runSpacing: 6,
          children: [
            if (invoiceType.isNotEmpty)
              _docChip(invoiceType, app_theme.AppColors.primaryGold),
            _docChip('#$invoiceNumber', Colors.blueGrey),
            _docChip(status, statusColor),
            _docChip(date, Colors.blueGrey),
            if (postedBy.isNotEmpty) _docChip('بواسطة: $postedBy', Colors.blueGrey),
          ],
        ),
        const SizedBox(height: 14),

        // ── الطرف الآخر ─────────────────────────────────────────────────
        if (customerName.isNotEmpty && customerName != 'N/A')
          _docRow(Icons.person_outline, 'العميل', customerName),
        if (supplierName.isNotEmpty && supplierName != 'N/A')
          _docRow(Icons.store_outlined, 'المورد', supplierName),

        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 10),

        // ── الأصناف ─────────────────────────────────────────────────────
        Text(
          'الأصناف (${items.length})',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text('لا توجد أصناف', style: TextStyle(color: Colors.grey.shade500))
        else
          ...items.map((rawItem) {
            if (rawItem is! Map) return const SizedBox.shrink();
            final item = Map<String, dynamic>.from(rawItem);
            final name     = item['name']?.toString() ?? item['item_name']?.toString() ?? 'صنف';
            final karat    = item['karat']?.toString() ?? '';
            final weight   = (item['weight'] as num?)?.toDouble() ?? (item['weight_grams'] as num?)?.toDouble();
            final price    = (item['price'] as num?)?.toDouble() ?? (item['unit_price'] as num?)?.toDouble();
            final wage     = (item['wage'] as num?)?.toDouble() ?? (item['manufacturing_wage'] as num?)?.toDouble() ?? 0.0;
            final tax      = (item['tax'] as num?)?.toDouble() ?? 0.0;
            final lineTotal = (item['total'] as num?)?.toDouble() ?? (item['total_price'] as num?)?.toDouble();
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10, runSpacing: 4,
                    children: [
                      if (karat.isNotEmpty) _infoTag('عيار', karat),
                      if (weight != null) _infoTag('الوزن', '${weight.toStringAsFixed(3)} جم'),
                      if (price != null) _infoTag('السعر', '${price.toStringAsFixed(2)} $currency'),
                      if (wage > 0) _infoTag('الأجرة', '${wage.toStringAsFixed(2)} $currency'),
                      if (tax > 0) _infoTag('الضريبة', '${tax.toStringAsFixed(2)} $currency'),
                      if (lineTotal != null) _infoTag('الإجمالي', '${lineTotal.toStringAsFixed(2)} $currency', bold: true),
                    ],
                  ),
                ],
              ),
            );
          }),

        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 10),

        // ── الإجماليات ──────────────────────────────────────────────────
        Text('الإجماليات', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 8),
        if (totalWeight != null)
          _summaryRow('إجمالي الوزن', '${totalWeight.toStringAsFixed(3)} جم'),
        if (totalTax > 0)
          _summaryRow('الضريبة', '${totalTax.toStringAsFixed(2)} $currency'),
        _summaryRow('الإجمالي الكلي', '${total.toStringAsFixed(2)} $currency', highlight: true),
        _summaryRow('المدفوع', '${paid.toStringAsFixed(2)} $currency', color: Colors.green),
        if (remaining.abs() > 0.01)
          _summaryRow(
            remaining > 0 ? 'المتبقي' : 'زيادة دفع',
            '${remaining.abs().toStringAsFixed(2)} $currency',
            color: remaining > 0 ? Colors.red : Colors.blue,
          ),

        if (notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 8),
          _docRow(Icons.notes_outlined, 'ملاحظات', notes),
        ],
      ],
    );
  }

  // ── بناء محتوى السند ────────────────────────────────────────────────────

  Widget _buildVoucherContent(Map<String, dynamic> v) {
    final currency   = context.read<SettingsProvider>().currencySymbolText;
    final voucherNum = v['voucher_number']?.toString() ?? '—';
    final type       = v['voucher_type']?.toString() ?? '';
    final date       = (v['date']?.toString() ?? '').replaceFirst(RegExp(r'T.*'), '');
    final amountCash = (v['amount_cash'] as num?)?.toDouble() ?? 0.0;
    final amountGold = (v['amount_gold'] as num?)?.toDouble() ?? 0.0;
    final description = v['description']?.toString() ?? '';
    // notes قد يكون JSON — نتجاهله لأن البيان (description) يحمل المعلومة المفيدة
    final createdBy  = v['created_by']?.toString() ?? '';
    final status     = v['status']?.toString() ?? '';
    final refType    = v['reference_type']?.toString() ?? '';
    final refNum     = v['reference_number']?.toString() ?? '';

    // الطرف: عميل أو مورد
    final customer   = v['customer'] as Map?;
    final partyName  = v['party_name']?.toString() ??
        customer?['name']?.toString() ?? '';

    // نوع السند
    final isReceipt = type == 'receipt' || type.contains('قبض') || type.contains('rv') || type.toLowerCase().contains('receipt');
    final typeLabel = isReceipt ? '📥 سند قبض' : '📤 سند صرف';
    final typeColor = isReceipt ? Colors.green : Colors.red;

    // سطور الحسابات (account_lines) — الهيكل الحقيقي من الـ API
    final accountLines = (v['account_lines'] as List?) ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── شريط المعلومات الأساسية ─────────────────────────────────────
        Wrap(
          spacing: 8, runSpacing: 6,
          children: [
            _docChip(typeLabel, typeColor),
            if (voucherNum != '—') _docChip('#$voucherNum', Colors.blueGrey),
            if (date.isNotEmpty) _docChip(date, Colors.blueGrey),
            if (status.isNotEmpty) _docChip(status, Colors.blueGrey),
            if (createdBy.isNotEmpty) _docChip('بواسطة: $createdBy', Colors.blueGrey),
          ],
        ),
        const SizedBox(height: 14),

        // ── المبالغ ──────────────────────────────────────────────────────
        if (amountCash > 0)
          _summaryRow(
            'المبلغ النقدي',
            '${amountCash.toStringAsFixed(2)} $currency',
            highlight: true, color: typeColor,
          ),
        if (amountGold > 0)
          _summaryRow(
            'المبلغ الذهبي',
            '${amountGold.toStringAsFixed(3)} جم',
            highlight: amountCash <= 0, color: typeColor,
          ),

        // ── معلومات السند ─────────────────────────────────────────────
        if (partyName.isNotEmpty)
          _docRow(Icons.person_outline, 'الطرف', partyName),
        if (description.isNotEmpty)
          _docRow(Icons.notes_outlined, 'البيان', description),
        if (refType.isNotEmpty && refNum.isNotEmpty)
          _docRow(Icons.link_outlined, 'المرجع', '$refType #$refNum'),

        // ── سطور الحسابات ─────────────────────────────────────────────
        if (accountLines.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Text(
            'سطور السند (${accountLines.length})',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ...accountLines.map((l) {
            if (l is! Map) return const SizedBox.shrink();
            // اسم الحساب في كائن nested
            final acObj  = l['account'] as Map?;
            final acName = acObj?['name']?.toString() ??
                l['account_name']?.toString() ?? '—';
            final lineType   = l['line_type']?.toString() ?? '';
            final lineAmount = (l['amount'] as num?)?.toDouble() ?? 0.0;
            final amtType    = l['amount_type']?.toString() ?? 'cash';
            final isDebit    = lineType == 'debit';
            final unit       = amtType == 'gold' ? 'جم' : currency;
            final lineDesc   = l['description']?.toString() ?? '';

            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isDebit
                    ? Colors.red.shade50
                    : Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDebit
                      ? Colors.red.shade200
                      : Colors.green.shade200,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isDebit ? Icons.arrow_circle_down_outlined : Icons.arrow_circle_up_outlined,
                    size: 18,
                    color: isDebit ? Colors.red.shade600 : Colors.green.shade600,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(acName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        if (lineDesc.isNotEmpty)
                          Text(lineDesc, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                  Text(
                    '${lineAmount.toStringAsFixed(amtType == 'gold' ? 3 : 2)} $unit',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: isDebit ? Colors.red.shade700 : Colors.green.shade700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDebit ? Colors.red.shade100 : Colors.green.shade100,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isDebit ? 'مدين' : 'دائن',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: isDebit ? Colors.red.shade700 : Colors.green.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }

  // ── بناء محتوى القيد اليومي ─────────────────────────────────────────────

  Widget _buildJournalEntryContent(Map<String, dynamic> je) {
    final entryNum   = je['entry_number']?.toString() ?? je['number']?.toString() ?? '—';
    final date       = je['date']?.toString().substring(0, 10) ?? '—';
    final narration  = je['narration']?.toString() ?? je['description']?.toString() ?? '';
    final status     = je['status']?.toString() ?? '';
    final createdBy  = je['created_by']?.toString() ?? je['posted_by']?.toString() ?? '';
    final currency   = context.read<SettingsProvider>().currencySymbolText;
    final lines      = (je['lines'] as List?) ?? [];

    double totalDebitCash = 0, totalCreditCash = 0;
    double totalDebitGold = 0, totalCreditGold = 0;
    for (final l in lines) {
      if (l is! Map) continue;
      totalDebitCash  += (l['cash_debit']   as num?)?.toDouble() ?? 0;
      totalCreditCash += (l['cash_credit']  as num?)?.toDouble() ?? 0;
      totalDebitGold  += (l['debit_21k'] as num?)?.toDouble() ?? 0;
      totalCreditGold += (l['credit_21k'] as num?)?.toDouble() ?? 0;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8, runSpacing: 6,
          children: [
            _docChip('قيد #$entryNum', app_theme.AppColors.primaryGold),
            _docChip(date, Colors.blueGrey),
            if (status.isNotEmpty) _docChip(status, Colors.blueGrey),
            if (createdBy.isNotEmpty) _docChip('بواسطة: $createdBy', Colors.blueGrey),
          ],
        ),
        const SizedBox(height: 12),

        if (narration.isNotEmpty)
          _docRow(Icons.notes_outlined, 'البيان', narration),

        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 10),

        // ── سطور القيد ───────────────────────────────────────────────
        Text(
          'سطور القيد (${lines.length})',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (lines.isEmpty)
          Text('لا توجد سطور', style: TextStyle(color: Colors.grey.shade500))
        else
          ...lines.map((l) {
            if (l is! Map) return const SizedBox.shrink();
            final acName   = l['account_name']?.toString() ?? '—';
            final cashD    = (l['cash_debit']   as num?)?.toDouble() ?? 0;
            final cashC    = (l['cash_credit']  as num?)?.toDouble() ?? 0;
            final goldD    = (l['debit_21k'] as num?)?.toDouble() ?? 0;
            final goldC    = (l['credit_21k'] as num?)?.toDouble() ?? 0;
            final narr     = l['narration']?.toString() ?? '';
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(acName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  if (narr.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(narr, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                  ],
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8, runSpacing: 4,
                    children: [
                      if (cashD > 0) _infoTag('نقد مدين', '${cashD.toStringAsFixed(2)} $currency', bold: true),
                      if (cashC > 0) _infoTag('نقد دائن', '${cashC.toStringAsFixed(2)} $currency', bold: true),
                      if (goldD > 0) _infoTag('ذهب مدين', '${goldD.toStringAsFixed(3)} جم'),
                      if (goldC > 0) _infoTag('ذهب دائن', '${goldC.toStringAsFixed(3)} جم'),
                    ],
                  ),
                ],
              ),
            );
          }),

        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 8),

        // ── الميزان ──────────────────────────────────────────────────
        Text('ميزان القيد', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        if (totalDebitCash > 0 || totalCreditCash > 0) ...[
          _summaryRow('إجمالي نقد مدين', '${totalDebitCash.toStringAsFixed(2)} $currency'),
          _summaryRow('إجمالي نقد دائن', '${totalCreditCash.toStringAsFixed(2)} $currency'),
        ],
        if (totalDebitGold > 0 || totalCreditGold > 0) ...[
          _summaryRow('إجمالي ذهب مدين', '${totalDebitGold.toStringAsFixed(3)} جم'),
          _summaryRow('إجمالي ذهب دائن', '${totalCreditGold.toStringAsFixed(3)} جم'),
        ],
      ],
    );
  }

  // ── مساعدات العرض ────────────────────────────────────────────────────────

  Widget _docChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: color.withValues(alpha: 0.85),
      ),
    ),
  );

  Widget _docRow(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: Colors.grey.shade500),
        const SizedBox(width: 8),
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _summaryRow(String label, String value, {
    bool highlight = false, Color? color,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: highlight ? FontWeight.w900 : FontWeight.w600,
            color: color ?? (highlight ? app_theme.AppColors.primaryGold : null),
          ),
        ),
      ],
    ),
  );

  Widget _infoTag(String label, String value, {bool bold = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.grey.shade300),
    ),
    child: RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 11.5, color: Colors.black87),
        children: [
          TextSpan(text: '$label: '),
          TextSpan(
            text: value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  void _showLineDetails(StatementLine line, double mainKarat) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (_, scrollController) => SingleChildScrollView(
            controller: scrollController,
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
                if (line.entryNumber != null && line.entryNumber!.isNotEmpty)
                  _buildDetailsRow('رقم القيد', line.entryNumber!),
                _buildDetailsRow('رقم السطر', line.id.toString()),
                if (line.referenceType != null && line.referenceType!.isNotEmpty)
                  _buildDetailsRow(
                    'المرجع',
                    '${_friendlyRefType(line.referenceType!)}${line.referenceNumber != null && line.referenceNumber!.isNotEmpty ? ' • ${line.referenceNumber}' : line.referenceId != null ? ' #${line.referenceId}' : ''}',
                  ),
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
                  _buildDetailsRow('نقد دائن', line.cashCredit.toStringAsFixed(2)),
                ],
                if (line.runningCashBalance != null || line.runningGoldBalance != null) ...[
                  const Divider(height: 24),
                  if (line.runningCashBalance != null)
                    _buildDetailsRow(
                      'الرصيد النقدي',
                      line.runningCashBalance!.toStringAsFixed(2),
                    ),
                  if (line.runningGoldBalance != null)
                    _buildDetailsRow(
                      'الرصيد الذهبي (عيار ${_statement!.mainKarat})',
                      line.runningGoldBalance!.toStringAsFixed(3),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _friendlyRefType(String refType) {
    switch (refType) {
      case 'invoice': return 'فاتورة';
      case 'office_reservation': return 'حجز مكتب';
      case 'voucher': return 'سند';
      case 'voucher_reversal': return 'عكس سند';
      case 'invoice_payment': return 'دفعة فاتورة';
      case 'clearing_settlement': return 'تسوية';
      default: return refType;
    }
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
    final base = app_theme.AppColors.karatColorFor(label);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Chip(
      backgroundColor: base.withValues(alpha: isDark ? 0.20 : 0.12),
      shape: StadiumBorder(
        side: BorderSide(color: base.withValues(alpha: isDark ? 0.55 : 0.35)),
      ),
      label: Text(
        '$label • مدين ${debit.toStringAsFixed(3)} / دائن ${credit.toStringAsFixed(3)}',
        style: TextStyle(color: base, fontWeight: FontWeight.w700),
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
    final goldColor = app_theme.AppColors.primaryGold;
    final cashColor = app_theme.AppColors.success;

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
                    color: goldColor,
                    icon: Icons.scale,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryMetric(
                    label: 'نقد (ر.س)',
                    value: cashValue.toStringAsFixed(2),
                    color: cashColor,
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

class _ValuationCard extends StatelessWidget {
  final int mainKarat;
  final double? pricePerGramMainKarat;
  final String? priceSource;
  final DateTime? priceUpdatedAt;
  final double? totalValueEstimate;
  final double? goldValueEstimate;

  const _ValuationCard({
    required this.mainKarat,
    required this.pricePerGramMainKarat,
    required this.priceSource,
    required this.priceUpdatedAt,
    required this.totalValueEstimate,
    required this.goldValueEstimate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final borderColor = theme.colorScheme.outlineVariant;
    final goldColor = app_theme.AppColors.primaryGold;
    final cashColor = app_theme.AppColors.success;

    String updatedLabel() {
      final local = priceUpdatedAt?.toLocal();
      if (local == null) return '';
      try {
        return DateFormat('yyyy-MM-dd HH:mm').format(local);
      } catch (_) {
        return '';
      }
    }

    final priceText = (pricePerGramMainKarat ?? 0) > 0
        ? pricePerGramMainKarat!.toStringAsFixed(2)
        : '—';
    final totalText = totalValueEstimate?.toStringAsFixed(2) ?? '—';
    final goldValueText = goldValueEstimate?.toStringAsFixed(2);

    final source = (priceSource ?? '').trim();
    final updatedAt = updatedLabel();
    final subtitleParts = <String>['عيار $mainKarat'];
    if (source.isNotEmpty) subtitleParts.add(source);
    if (updatedAt.isNotEmpty) subtitleParts.add(updatedAt);

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
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.price_check,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'السعر اللحظي والتقييم',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitleParts.join(' • '),
                        style: textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryMetric(
                    label: 'سعر الجرام (ر.س)',
                    value: priceText,
                    subtitle: 'مكافئ عيار $mainKarat',
                    color: goldColor,
                    icon: Icons.attach_money,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryMetric(
                    label: 'قيمة تقديرية (ر.س)',
                    value: totalText,
                    subtitle: goldValueText == null
                        ? null
                        : 'ذهب: $goldValueText',
                    color: cashColor,
                    icon: Icons.assessment,
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

// ─────────────────────────────────────────────────────────────────────────────
// Sliver delegate that pins a widget at the top of a CustomScrollView
// ─────────────────────────────────────────────────────────────────────────────
class _PinnedWidgetDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedWidgetDelegate({
    required this.child,
    required this.height,
  });

  final Widget child;
  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(_PinnedWidgetDelegate oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}
