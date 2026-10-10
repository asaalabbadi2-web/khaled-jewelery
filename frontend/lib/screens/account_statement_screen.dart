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
import '../web_file_io.dart' as web_io;
import '../models/account_statement_model.dart';
import '../models/statement_period.dart';
import '../pdf/account_statement_pdf_builder.dart';
import '../widgets/cancelled_vouchers_bar.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' as cu;
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

  /// The server; tests pass a fake.
  final ApiService? apiService;

  const AccountStatementScreen({
    super.key,
    required this.accountId,
    required this.accountName,
    this.entityType =
        'account', // default to account for backward compatibility
    this.apiService,
  });

  @override
  State<AccountStatementScreen> createState() => _AccountStatementScreenState();
}

class _AccountStatementScreenState extends State<AccountStatementScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  bool _isLoading = true;

  /// Cancelled vouchers and their reversals are hidden by default; the bar
  /// above the lines shows them (the owner, 9 Oct 2026).
  bool _includeCancelled = false;
  AccountStatement? _statement;
  List<StatementLine> _filteredLines = [];
  DateTimeRange? _dateRange;
  final TextEditingController _searchController = TextEditingController();
  String _filterType = 'all'; // 'all', 'credit', 'debit'
  int? _filterKarat; // null=all, 18, 21, 22, 24
  // int? _expandedTransactionId; // Removed: unused


  final ScrollController _horizontalController = ScrollController();

  int _viewMode = 0; // 0: dual, 1: gold, 2: cash
  _StatementDisplayMode _displayMode = _StatementDisplayMode.table;
  bool _showOnlyMovement = false;
  bool _includeBreakdown = true;
  bool _isExporting = false;
  // Default: newest transactions first
  // (field kept for future use)
  bool _resolvedViewModeDefault = false;
  _StatementSortColumn? _sortColumn = _StatementSortColumn.date;
  bool _sortAscending = false; // newest first by default (the owner, 10 Oct 2026)

  /// The order a viewer chose, kept on this device for the next statement.
  static const _oldestFirstKey = 'account_statement_oldest_first';

  /// Why the statement did not load -- said as such, never as an empty one.
  String? _loadError;

  /// The less-used filters' panel, closed until asked for.
  bool _filtersOpen = false;

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

  StatementPeriod _periodSummary() {
    final statement = _statement;
    if (statement == null) {
      return (openingGold: 0.0, openingCash: 0.0, movementGold: 0.0, movementCash: 0.0,
              closingGold: 0.0, closingCash: 0.0);
    }
    return statementPeriod(statement, _dateRange);
  }

  StatementTotals _periodDebitCreditTotals() {
    final statement = _statement;
    if (statement == null) {
      return (goldDebit: 0.0, goldCredit: 0.0, cashDebit: 0.0, cashCredit: 0.0);
    }
    return statementTotals(statement, _dateRange);
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
    // Once, after the first frame (it reads the theme): didChangeDependencies
    // ran again on every window resize and fetched the whole statement anew.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _restoreOrder();
      if (mounted) _fetchAccountStatement();
    });
    _searchController.addListener(_filterLines);
  }

  @override
  void dispose() {
    // Dispose controllers to avoid leaks
    _searchController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }


  Future<void> _restoreOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldestFirst = prefs.getBool(_oldestFirstKey);
      if (oldestFirst != null && mounted) {
        setState(() {
          _sortColumn = _StatementSortColumn.date;
          _sortAscending = oldestFirst;
        });
      }
    } catch (_) {
      // The default order stands.
    }
  }

  bool get _byDate => _sortColumn == _StatementSortColumn.date;

  Future<void> _setOrder({required bool oldestFirst}) async {
    setState(() {
      _sortColumn = _StatementSortColumn.date;
      _sortAscending = oldestFirst;
    });
    _filterLines();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_oldestFirstKey, oldestFirst);
    } catch (_) {
      // Not remembered on this device; the choice holds for this statement.
    }
  }

  /// Ready periods, so a month is one tap and not a calendar.
  void _setPeriod(String key) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final DateTimeRange? range = switch (key) {
      'today' => DateTimeRange(start: today, end: today),
      'this_month' => DateTimeRange(start: DateTime(now.year, now.month, 1), end: today),
      'last_month' => DateTimeRange(
          start: DateTime(now.year, now.month - 1, 1),
          end: DateTime(now.year, now.month, 0),
        ),
      'this_year' => DateTimeRange(start: DateTime(now.year, 1, 1), end: today),
      _ => null,
    };
    setState(() => _dateRange = range);
    _filterLines();
  }

  Future<void> _fetchAccountStatement() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      Map<String, dynamic> data;

      // Call appropriate API based on entity type
      if (widget.entityType == 'customer') {
        data = await _api.getCustomerStatement(
          widget.accountId,
          includeCancelled: _includeCancelled,
        );
      } else if (widget.entityType == 'supplier') {
        data = await _api.getSupplierStatement(
          widget.accountId,
          includeCancelled: _includeCancelled,
        );
      } else {
        if (!_resolvedViewModeDefault) {
          _resolvedViewModeDefault = true;
          try {
            final account = await _api.getAccountById(widget.accountId);
            if (mounted) {
              setState(() => _viewMode = _defaultViewModeForAccount(account));
            }
          } catch (_) {
            // Keep the default dual view if metadata fetch fails.
          }
        }

        data = await _api.getAccountStatement(
          widget.accountId,
          includeCancelled: _includeCancelled,
        );
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
      setState(() {
        _isLoading = false;
        _loadError = e.toString().replaceFirst('Exception: ', '');
      });
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
      final bounds = _dateRange == null ? null : statementRangeBounds(_dateRange!);

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

      // A filter hides lines; each keeps the balance the server gave it.
      _filteredLines = filtered;

      _applySort(_filteredLines, mainKarat);
    });
  }

  double _goldMovementForLine(StatementLine line, double mainKarat) {
    return line.goldDebit - line.goldCredit;
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
        line.goldDebit;
    final creditMain =
        line.goldCredit;

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
    final fileName =
        'account_statement_${widget.accountId}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';
    if (kIsWeb) {
      // The browser downloads it: a temporary directory and opening a file
      // do not exist there, so the export did nothing in production (10 Oct
      // 2026). The BOM lets Excel read the Arabic as UTF-8.
      web_io.downloadBytes(fileName, [0xEF, 0xBB, 0xBF, ...utf8.encode(csvData)], 'text/csv;charset=utf-8');
      return;
    }
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/$fileName');
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
            ? _buildLoadingSkeleton()
            : _loadError != null
            ? _buildLoadErrorState()
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

        // One scroll (10 Oct 2026): the summary is the page's head and scrolls
        // away first, then the lines -- they used to sit in a box 55 % of the
        // screen tall inside a page that scrolled too. The toolbar heads the
        // body, so it stays above the lines.
        return NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _buildSummaryOverview(constraints.maxWidth - 32),
              ),
            ),
            if ((_statement?.cancelledCount ?? 0) + (_statement?.correctionCount ?? 0) > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _buildCancelledBar(),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
          body: Column(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 8), child: toolbarWidget),
                    if (_activeFiltersCount > 0)
                      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: totalsWidget),
                  ],
                ),
              ),
              Expanded(
                child: filteredLines.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                        child: _buildEmptyLinesState(),
                      )
                    : isCard
                    ? RefreshIndicator(
                        onRefresh: _fetchAccountStatement,
                        child: ListView.separated(
                          primary: true,
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                          itemCount: filteredLines.length + (_byDate ? 2 : 0),
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (context, rawIndex) {
                            if (_byDate && rawIndex == 0) {
                              return _buildBoundaryCard(opening: _sortAscending);
                            }
                            if (_byDate && rawIndex == filteredLines.length + 1) {
                              return _buildBoundaryCard(opening: !_sortAscending);
                            }
                            return _buildLineCard(
                                filteredLines[_byDate ? rawIndex - 1 : rawIndex], mainKarat);
                          },
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: _buildStatementTable(),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCancelledBar() => CancelledVouchersBar(
        count: _statement?.cancelledCount ?? 0,
        corrections: _statement?.correctionCount ?? 0,
        hidden: _statement?.cancelledHidden ?? false,
        busy: _isLoading,
        onToggle: () {
          setState(() => _includeCancelled = !_includeCancelled);
          _fetchAccountStatement();
        },
      );

  /// The page's shape while it loads -- the summary cards, the toolbar and a
  /// few rows -- instead of a lone spinner (the statement took 11 s once).
  Widget _buildLoadingSkeleton() {
    final scheme = Theme.of(context).colorScheme;
    Widget block(double height, {double? width}) => Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(10),
          ),
        );
    return Padding(
      key: const Key('statement-skeleton'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: block(92)),
            ],
          ]),
          const SizedBox(height: 16),
          block(52),
          const SizedBox(height: 16),
          for (var i = 0; i < 6; i++) ...[block(44), const SizedBox(height: 8)],
          const SizedBox(height: 4),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }

  /// A failed load says it failed and offers to try again -- it used to read
  /// «لا توجد سجلات», as if the account had no movement.
  Widget _buildLoadErrorState() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const Key('statement-load-error'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('تعذّر تحميل الكشف', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              _loadError ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _fetchAccountStatement,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
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

  /// What the filtered lines add up to -- only while a filter works: without
  /// one it repeated the summary's movement in seven chips.
  Widget _buildFilteredTotalsBar() {
    if (_statement == null || _activeFiltersCount == 0) return const SizedBox.shrink();
    double goldDebit = 0, goldCredit = 0, cashDebit = 0, cashCredit = 0;
    for (final line in _filteredLines) {
      goldDebit += line.goldDebit;
      goldCredit += line.goldCredit;
      cashDebit += line.cashDebit;
      cashCredit += line.cashCredit;
    }
    final theme = Theme.of(context);
    final parts = [
      'النتائج: ${ltrIsolate('${_filteredLines.length}')}',
      if (_viewMode != 2)
        'ذهب — مدين ${ltrIsolate(_goldFmt.format(goldDebit))} · دائن ${ltrIsolate(_goldFmt.format(goldCredit))}',
      if (_viewMode != 1)
        'نقد — مدين ${ltrIsolate(_cashFmt.format(cashDebit))} · دائن ${ltrIsolate(_cashFmt.format(cashCredit))}',
    ];
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        parts.join('    |    '),
        key: const Key('statement-filtered-totals'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontFeatures: const [ui.FontFeature.tabularFigures()],
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

  static final NumberFormat _cashFmt = NumberFormat('#,##0.00', 'en_US');
  static final NumberFormat _goldFmt = NumberFormat('#,##0.000', 'en_US');

  /// A figure with its side, as the statement's columns say it.
  String _withSide(double value, NumberFormat fmt, String unit, {bool movement = false}) {
    final side = movement
        ? (value.abs() < 0.0005 ? '' : (value > 0 ? 'مدين' : 'دائن'))
        : _balanceSide(value);
    final unitPart = unit.isEmpty ? '' : ' $unit';
    return '${ltrIsolate(fmt.format(value.abs()))}$unitPart${side.isEmpty ? '' : ' $side'}';
  }

  Widget _summaryLine(String label, String value, Color color, {bool cash = false}) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      color: color,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(
            child: cash
                ? cu.SarAwareText(value,
                    isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                    textAlign: TextAlign.end, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)
                : Text(value, textAlign: TextAlign.end, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile({
    required Key key,
    required String title,
    required List<Widget> lines,
    bool emphasized = false,
    String? footnote,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: emphasized ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: emphasized ? scheme.primary.withValues(alpha: 0.35) : scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant)),
          ...lines,
          if (footnote != null && footnote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(footnote,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  /// Opening, movement, closing and the live valuation: one light row on a
  /// wide screen, two by two on a narrow one (the owner, 10 Oct 2026 -- four
  /// heavy cards, boxes in boxes, split three and one).
  Widget _buildSummaryOverview(double maxWidth) {
    final statement = _statement!;
    final tones = AppSemanticColors.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final period = _periodSummary();
    final showGold = _viewMode != 2;
    final showCash = _viewMode != 1;
    final ranged = _dateRange != null;

    List<Widget> figures(double gold, double cash, {bool movement = false}) => [
          if (showGold)
            _summaryLine('ذهب ع${statement.mainKarat}', _withSide(gold, _goldFmt, 'جم', movement: movement), tones.gold.fg),
          if (showCash)
            _summaryLine(statement.isMerged ? 'قيمة' : 'نقد', _withSide(cash, _cashFmt, currency, movement: movement),
                tones.cash.fg, cash: true),
        ];

    final karats = !ranged && showGold
        ? statement.closingBalanceGoldDetails.entries
            .where((e) => e.value.abs() >= 0.0005)
            .map((e) => '${e.key.replaceAll('k', '')}: ${ltrIsolate(_goldFmt.format(e.value))}')
            .join('  ·  ')
        : '';

    final tiles = <Widget>[
      _summaryTile(
        key: const Key('summary-opening'),
        title: ranged ? 'رصيد أول الفترة' : 'الرصيد الافتتاحي',
        lines: figures(period.openingGold, period.openingCash),
      ),
      _summaryTile(
        key: const Key('summary-movement'),
        title: ranged ? 'حركة الفترة' : 'حركة الكشف',
        lines: figures(period.movementGold, period.movementCash, movement: true),
      ),
      _summaryTile(
        key: const Key('summary-closing'),
        title: ranged ? 'رصيد آخر الفترة' : 'الرصيد الختامي',
        lines: figures(period.closingGold, period.closingCash),
        emphasized: true,
        footnote: karats.isEmpty ? null : 'بالعيار: $karats',
      ),
    ];

    final price = statement.goldPricePerGramMainKarat ?? 0;
    final value = statement.valuationTotalValueEstimate;
    if (price > 0 || (value ?? 0) != 0) {
      final at = statement.goldPriceUpdatedAt;
      tiles.add(_summaryTile(
        key: const Key('summary-valuation'),
        title: 'التقييم الحيّ (تقديري)',
        lines: [
          if (value != null) _summaryLine('القيمة', '${ltrIsolate(_cashFmt.format(value))} $currency', tones.cash.fg, cash: true),
          if (price > 0)
            _summaryLine('جرام ع${statement.mainKarat}', '${ltrIsolate(_cashFmt.format(price))} $currency', tones.gold.fg,
                cash: true),
        ],
        // §13: a live price, not a frozen figure of the statement.
        footnote: 'بسعر لحظي${at == null ? '' : ' ${DateFormat('HH:mm').format(at.toLocal())}'} — يتغيّر ولا يُجمَّد',
      ));
    }

    const gap = 12.0;
    final columns = maxWidth >= 1000 ? tiles.length : 2;
    final width = (maxWidth - gap * (columns - 1)) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [for (final t in tiles) SizedBox(width: width, child: t)],
    );
  }

  int get _activeFiltersCount {
    int count = 0;
    if (_dateRange != null) count++;
    if (_searchController.text.trim().isNotEmpty) count++;
    if (_filterType != 'all') count++;
    if (_filterKarat != null) count++;
    if (_showOnlyMovement) count++;
    // The view (dual / gold / cash) and the karat column are how lines are
    // shown, not which: not filters, and «مسح الفلاتر» leaves them.
    return count;
  }

  /// The filters behind «فلاتر»: how many hide lines now.
  int get _panelFiltersCount =>
      (_filterType != 'all' ? 1 : 0) + (_filterKarat != null ? 1 : 0) + (_showOnlyMovement ? 1 : 0);

  String get _periodLabel {
    final r = _dateRange;
    if (r == null) return 'كل الفترات';
    final f = DateFormat('dd/MM/yyyy');
    return r.start == r.end ? f.format(r.start) : '${f.format(r.start)} – ${f.format(r.end)}';
  }

  Widget _buildToolbar(double maxWidth) {
    final isNarrow = maxWidth < 500;
    final isCompact = maxWidth < 700;
    final theme = Theme.of(context);
    // The panel is open when asked, or when a filter in it hides lines -- a
    // filter at work is never out of sight.
    final panelOpen = _filtersOpen || _panelFiltersCount > 0;
    const segmentStyle = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
              // One control for the period: the ready ones, or a range.
              PopupMenuButton<String>(
                key: const Key('statement-periods'),
                tooltip: 'الفترة',
                onSelected: (key) => key == 'custom' ? _pickDateRange() : _setPeriod(key),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'today', child: Text('اليوم')),
                  PopupMenuItem(value: 'this_month', child: Text('هذا الشهر')),
                  PopupMenuItem(value: 'last_month', child: Text('الشهر الماضي')),
                  PopupMenuItem(value: 'this_year', child: Text('هذه السنة')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'custom', child: Text('نطاق مخصص…')),
                  PopupMenuItem(value: 'all', child: Text('كل الفترات')),
                ],
                child: IgnorePointer(
                  child: OutlinedButton.icon(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.event_note, size: 18),
                    label: Text(_periodLabel, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              SegmentedButton<bool>(
                key: const Key('statement-order'),
                style: segmentStyle,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('الأحدث أولًا'), icon: Icon(Icons.south, size: 16)),
                  ButtonSegment(value: true, label: Text('الأقدم أولًا'), icon: Icon(Icons.north, size: 16)),
                ],
                selected: {_byDate ? _sortAscending : false},
                emptySelectionAllowed: !_byDate,
                onSelectionChanged: (choice) {
                  if (choice.isNotEmpty) _setOrder(oldestFirst: choice.first);
                },
              ),
              if (!isNarrow)
                SegmentedButton<int>(
                  style: segmentStyle,
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, label: Text('مزدوج')),
                    ButtonSegment(value: 1, label: Text('ذهب')),
                    ButtonSegment(value: 2, label: Text('نقد')),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (value) {
                    setState(() => _viewMode = value.first);
                    _filterLines();
                  },
                ),
              TextButton.icon(
                key: const Key('statement-filters-toggle'),
                onPressed: () => setState(() => _filtersOpen = !panelOpen),
                icon: Icon(panelOpen ? Icons.expand_less : Icons.tune, size: 18),
                label: Text(_activeFiltersCount > 0 ? 'فلاتر ($_activeFiltersCount)' : 'فلاتر'),
              ),
              if (_activeFiltersCount > 0)
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('مسح'),
                ),
              _buildExportMenu(),
            ],
          ),
          if (panelOpen) ...[
            const SizedBox(height: 8),
            _buildFilterRow(
              isCompact: isCompact,
              children: [
                if (isNarrow)
                  SizedBox(
                    width: 130,
                    child: DropdownButtonFormField<int>(
                      value: _viewMode,
                      decoration: const InputDecoration(labelText: 'العرض', isDense: true),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('مزدوج')),
                        DropdownMenuItem(value: 1, child: Text('ذهب فقط')),
                        DropdownMenuItem(value: 2, child: Text('نقدي فقط')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _viewMode = value);
                        _filterLines();
                      },
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
              ],
            ),
          ],
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
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
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
      if (_viewMode != 2) 'gold_debit': 115,
      if (_viewMode != 2) 'gold_credit': 115,
      if (_viewMode != 2) 'gold_balance': 160,
      if (_viewMode != 1) 'cash_debit': 125,
      if (_viewMode != 1) 'cash_credit': 125,
      if (_viewMode != 1) 'cash_balance': 170,
      if (_includeBreakdown && _viewMode != 2) 'breakdown': 64,
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

    // Debit, credit and the balance after -- the columns an accountant reads.
    List<Widget> amountCells({
      required double goldDebit,
      required double goldCredit,
      required double? goldBalance,
      required double cashDebit,
      required double cashCredit,
      required double? cashBalance,
      bool bold = false,
    }) {
      return [
        if (_viewMode != 2) ...[
          bodyCell(width: widths['gold_debit']!, alignment: AlignmentDirectional.centerEnd,
              child: _numCell(goldDebit, color: theme.colorScheme.onSurface, fractionDigits: 3)),
          bodyCell(width: widths['gold_credit']!, alignment: AlignmentDirectional.centerEnd,
              child: _numCell(goldCredit, color: theme.colorScheme.onSurface, fractionDigits: 3)),
          bodyCell(width: widths['gold_balance']!, alignment: AlignmentDirectional.centerEnd,
              child: _balanceCell(goldBalance, fractionDigits: 3, bold: bold)),
        ],
        if (_viewMode != 1) ...[
          bodyCell(width: widths['cash_debit']!, alignment: AlignmentDirectional.centerEnd,
              child: _numCell(cashDebit, color: theme.colorScheme.onSurface, fractionDigits: 2)),
          bodyCell(width: widths['cash_credit']!, alignment: AlignmentDirectional.centerEnd,
              child: _numCell(cashCredit, color: theme.colorScheme.onSurface, fractionDigits: 2)),
          bodyCell(width: widths['cash_balance']!, alignment: AlignmentDirectional.centerEnd,
              child: _balanceCell(cashBalance, fractionDigits: 2, bold: bold)),
        ],
      ];
    }

    // The period's opening and closing as rows of the table, where an
    // accountant looks for them: the closing on top when the newest comes
    // first, the opening on top when the oldest does. Only when the lines are
    // in date order -- sorted by an amount, there is no «before» and «after».
    final period = _periodSummary();
    Widget boundaryRow({required bool opening}) {
      final label = opening
          ? (_dateRange == null ? 'الرصيد الافتتاحي' : 'رصيد أول الفترة')
          : (_dateRange == null ? 'الرصيد الختامي' : 'رصيد آخر الفترة');
      return Container(
        key: Key(opening ? 'statement-opening-row' : 'statement-closing-row'),
        height: 52,
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
          border: Border(bottom: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.14))),
        ),
        child: Row(
          children: [
            bodyCell(width: widths['date']!, alignment: Alignment.center, child: const SizedBox.shrink()),
            bodyCell(
              width: widths['description']!,
              child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            ...amountCells(
              goldDebit: 0, goldCredit: 0,
              goldBalance: opening ? period.openingGold : period.closingGold,
              cashDebit: 0, cashCredit: 0,
              cashBalance: opening ? period.openingCash : period.closingCash,
              bold: true,
            ),
            if (_includeBreakdown && _viewMode != 2)
              bodyCell(width: widths['breakdown']!, child: const SizedBox.shrink()),
            bodyCell(width: widths['actions']!, child: const SizedBox.shrink()),
          ],
        ),
      );
    }
    final withBoundaries = _byDate;

    return SizedBox.expand(
      key: const Key('statement-table'),
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
                                label: 'ذهب مدين',
                                width: widths['gold_debit']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.goldMovement,
                              ),
                            if (_viewMode != 2)
                              headerCell(
                                label: 'ذهب دائن',
                                width: widths['gold_credit']!,
                                alignment: AlignmentDirectional.centerEnd,
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
                                label: '$cashLabel مدين',
                                width: widths['cash_debit']!,
                                alignment: AlignmentDirectional.centerEnd,
                                sortColumn: _StatementSortColumn.cashMovement,
                              ),
                            if (_viewMode != 1)
                              headerCell(
                                label: '$cashLabel دائن',
                                width: widths['cash_credit']!,
                                alignment: AlignmentDirectional.centerEnd,
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
                                label: 'عيارات',
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
                            primary: true,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: _filteredLines.length + (withBoundaries ? 2 : 0),
                            itemBuilder: (context, rawIndex) {
                              if (withBoundaries && rawIndex == 0) {
                                return boundaryRow(opening: _sortAscending);
                              }
                              if (withBoundaries && rawIndex == _filteredLines.length + 1) {
                                return boundaryRow(opening: !_sortAscending);
                              }
                              final index = withBoundaries ? rawIndex - 1 : rawIndex;
                              final line = _filteredLines[index];

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
                                        ...amountCells(
                                          goldDebit: line.goldDebit,
                                          goldCredit: line.goldCredit,
                                          goldBalance: line.runningGoldBalance,
                                          cashDebit: line.cashDebit,
                                          cashCredit: line.cashCredit,
                                          cashBalance: line.runningCashBalance,
                                        ),
                                        if (_includeBreakdown && _viewMode != 2)
                                          bodyCell(
                                            width: widths['breakdown']!,
                                            alignment: Alignment.center,
                                            child: IconButton(
                                              tooltip: 'تفصيل العيارات',
                                              visualDensity: VisualDensity.compact,
                                              icon: const Icon(Icons.scale_outlined, size: 18),
                                              onPressed: () => _showLineDetails(line, mainKarat),
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

  /// The period's opening or closing, as a card in the narrow layout -- the
  /// same rows the table shows, in the same place for the order chosen.
  Widget _buildBoundaryCard({required bool opening}) {
    final theme = Theme.of(context);
    final period = _periodSummary();
    final label = opening
        ? (_dateRange == null ? 'الرصيد الافتتاحي' : 'رصيد أول الفترة')
        : (_dateRange == null ? 'الرصيد الختامي' : 'رصيد آخر الفترة');
    final gold = opening ? period.openingGold : period.closingGold;
    final cash = opening ? period.openingCash : period.closingCash;
    return Card(
      key: Key(opening ? 'statement-opening-row' : 'statement-closing-row'),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            if (_viewMode != 2) _balanceCell(gold, fractionDigits: 3, bold: true),
            if (_viewMode == 0) const SizedBox(width: 16),
            if (_viewMode != 1) _balanceCell(cash, fractionDigits: 2, bold: true),
          ],
        ),
      ),
    );
  }

  Widget _buildLineCard(StatementLine line, double mainKarat) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final goldMovement =
        line.goldDebit - line.goldCredit;
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

  Widget _numCell(double? value, {Color? color, int fractionDigits = 3}) {
    if (value == null || value.abs() < 0.0001) {
      return const Text('', textAlign: TextAlign.end);
    }

    return Text(
      (fractionDigits == 3 ? _goldFmt : _cashFmt).format(value),
      textAlign: TextAlign.end,
      style: TextStyle(
        color: color ?? Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w500,
        fontFeatures: const [ui.FontFeature.tabularFigures()],
      ),
    );
  }

  /// Which side a balance is on: «عليه / له» in a customer's or supplier's
  /// statement, «مدين / دائن» in any account's.
  String _balanceSide(double value) {
    if (value.abs() < 0.0005) return '';
    final party = widget.entityType == 'customer' || widget.entityType == 'supplier';
    if (value > 0) return party ? 'عليه' : 'مدين';
    return party ? 'له' : 'دائن';
  }

  Widget _balanceCell(double? value, {int fractionDigits = 3, bool bold = false}) {
    if (value == null) return const Text('', textAlign: TextAlign.end);
    final theme = Theme.of(context);
    final side = _balanceSide(value);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: (fractionDigits == 3 ? _goldFmt : _cashFmt).format(value.abs()),
          style: TextStyle(
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
        if (side.isNotEmpty)
          TextSpan(
            text: ' $side',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ]),
      textAlign: TextAlign.end,
      textDirection: ui.TextDirection.rtl,
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
        future: _api.getInvoiceById(refId),
        builder: _buildInvoiceContent,
      );
    } else if (refType == 'voucher' && refId != null) {
      await _showDocumentSheet(
        title: 'سند${line.referenceNumber != null ? "  #${line.referenceNumber}" : ""}',
        icon: Icons.payments,
        future: _api.getVoucher(refId),
        builder: _buildVoucherContent,
      );
    } else if (refType == 'invoice_payments' && refId != null) {
      // دفعة نقدية مرتبطة بفاتورة — نعرض الفاتورة بكامل تفاصيلها
      await _showDocumentSheet(
        title: 'دفعة فاتورة${line.referenceNumber != null ? "  #${line.referenceNumber}" : ""}',
        icon: Icons.payments_outlined,
        future: _api.getInvoiceById(refId),
        builder: _buildInvoiceContent,
      );
    } else if (refType == 'journal_entry' ||
               (refType.isEmpty && line.journalEntryId != null)) {
      final jeId = refId ?? line.journalEntryId!;
      await _showDocumentSheet(
        title: 'قيد يومية${line.entryNumber != null ? "  #${line.entryNumber}" : ""}',
        icon: Icons.library_books,
        future: _api.getJournalEntryById(jeId),
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
                    line.goldDebit.toStringAsFixed(3),
                  ),
                  _buildDetailsRow(
                    'ذهب دائن (عيار ${_statement!.mainKarat})',
                    line.goldCredit.toStringAsFixed(3),
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
          'ذهب مدين (عيار ${_statement!.mainKarat}): ${line.goldDebit.toStringAsFixed(3)}',
        )
        ..writeln(
          'ذهب دائن (عيار ${_statement!.mainKarat}): ${line.goldCredit.toStringAsFixed(3)}',
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

// ─────────────────────────────────────────────────────────────────────────────
// Sliver delegate that pins a widget at the top of a CustomScrollView
// ─────────────────────────────────────────────────────────────────────────────
