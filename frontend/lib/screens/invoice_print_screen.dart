import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../web_file_io.dart' as web_io;

/// شاشة معاينة وطباعة الفواتير
///
/// تدعم:
/// - فواتير البيع والشراء
/// - فواتير المرتجع والخردة
/// - طباعة احترافية مع شعار الشركة
/// - تصدير PDF
class InvoicePrintScreen extends StatefulWidget {
  final Map<String, dynamic> invoice;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;
  final bool autoPrint;
  final bool autoSharePdf;
  final bool autoDownloadPdf;

  const InvoicePrintScreen({
    super.key,
    required this.invoice,
    this.isArabic = true,
    this.printSettings,
    this.autoPrint = false,
    this.autoSharePdf = false,
    this.autoDownloadPdf = false,
  });

  @override
  State<InvoicePrintScreen> createState() => _InvoicePrintScreenState();
}

class _InvoicePrintScreenState extends State<InvoicePrintScreen> {
  bool get _isArabic => widget.isArabic;

  bool _isGenerating = false;
  bool _autoActionTriggered = false;
  // Cache PDFs by format signature. Some preview/print flows request multiple
  // formats; returning a cached PDF for a different format can cause loops.
  final Map<String, Uint8List> _pdfCacheByFormat = {};

  pw.Font? _pdfFontBase;
  pw.Font? _pdfFontBold;
  Future<void>? _pdfFontsLoadFuture;
  bool _pdfFontsReady = false;

  // Template positioning assets must be preloaded outside Printing.onLayout to
  // avoid platform-channel deadlocks on macOS (SharedPreferences/rootBundle).
  Map<String, _TemplateRect>? _cachedTemplateLayout;
  Uint8List? _cachedTemplateBackgroundBytes;
  pw.ImageProvider? _cachedTemplateBackgroundImage;
  Future<void>? _templateAssetsLoadFuture;
  bool _templateAssetsReady = false;

  // بيانات الشركة (ديناميكية من Settings)
  bool _settingsShowCompanyLogo = true;
  String? _companyName;
  String? _companyAddress;
  String? _companyPhone;
  String? _companyTaxNumber;
  Uint8List? _companyLogoBytes;

  // إعدادات الطباعة الافتراضية
  late bool _showLogo;
  late bool _showAddress;
  late bool _showPrices;
  late bool _showTaxInfo;
  late bool _showNotes;
  late String _paperSize;
  late bool _printInColor;

  // Local-only active preset key (used by TemplatePositioningScreen)
  static const String _activePresetKeyStorage = 'template_active_preset_key_v1';

  // Local template background is stored in SharedPreferences as base64.
  static const int _maxBackgroundBytes = 2 * 1024 * 1024; // 2MB

  String _formatCacheKey(PdfPageFormat format) {
    String f(num v) => v.toStringAsFixed(2);
    return [
      f(format.width),
      f(format.height),
      f(format.marginLeft),
      f(format.marginTop),
      f(format.marginRight),
      f(format.marginBottom),
    ].join('x');
  }

  void _invalidatePdfCache() {
    _pdfCacheByFormat.clear();
  }

  Future<Uint8List> _buildPdfForFormat(PdfPageFormat format) async {
    final key = _formatCacheKey(format);
    final cached = _pdfCacheByFormat[key];
    if (cached != null) {
      debugPrint('[PrintDiag] Using cached PDF for format: $key');
      return cached;
    }

    debugPrint('[PrintDiag] Generating new PDF for format: $key');
    try {
      final pdf = await _generatePdf(format);
      _pdfCacheByFormat[key] = pdf;
      debugPrint('[PrintDiag] PDF generation successful for format: $key');
      return pdf;
    } catch (e, s) {
      debugPrint(
        '[PrintDiag] PDF generation FAILED for format: $key. Error: $e\n$s',
      );
      // Always return a valid PDF to prevent PdfPreview/printing loops.
      return await _buildErrorPdf(format, e.toString());
    }
  }

  Future<Uint8List> _buildErrorPdf(PdfPageFormat format, String message) async {
    // IMPORTANT: Never call rootBundle/SharedPreferences here. This method may
    // run inside Printing.onLayout on macOS.
    final doc = pw.Document();
    final theme = (_pdfFontBase != null && _pdfFontBold != null)
        ? pw.ThemeData.withFont(base: _pdfFontBase!, bold: _pdfFontBold!)
        : null;

    doc.addPage(
      pw.Page(
        pageFormat: format,
        theme: theme,
        build: (_) {
          return pw.Padding(
            padding: const pw.EdgeInsets.all(24),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  widget.isArabic
                      ? 'تعذر إنشاء ملف الطباعة'
                      : 'Failed to generate print file',
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 12),
                pw.Text(message, style: const pw.TextStyle(fontSize: 10)),
              ],
            ),
          );
        },
      ),
    );
    return await doc.save();
  }

  Future<void> _printPdf() async {
    debugPrint('[PrintDiag] _printPdf called.');
    if (_isGenerating) {
      debugPrint('[PrintDiag] Already generating, exiting.');
      return;
    }

    try {
      setState(() => _isGenerating = true);

      // Make sure fonts are already loaded on the main isolate.
      await _ensurePdfFontsLoaded();

      // Make sure template layout/background are loaded outside onLayout.
      await _ensureTemplateAssetsLoaded();

      final printName =
          'invoice_${widget.invoice['invoice_type_id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf';

      debugPrint('[PrintDiag] Calling Printing.layoutPdf...');
      await Printing.layoutPdf(
        name: printName,
        onLayout: (format) async {
          debugPrint(
            '[PrintDiag] onLayout started for format: ${format.width}x${format.height}',
          );
          try {
            final pdfBytes = await _buildPdfForFormat(
              format,
            ).timeout(const Duration(seconds: 30));
            debugPrint('[PrintDiag] onLayout completed successfully.');
            return pdfBytes;
          } catch (e, s) {
            debugPrint('[PrintDiag] onLayout FAILED. Error: $e\n$s');
            // Return a minimal error PDF on timeout or failure.
            return await _buildErrorPdf(format, e.toString());
          }
        },
      );
      debugPrint('[PrintDiag] Printing.layoutPdf finished.');

      if (!mounted) return;
    } catch (e, s) {
      debugPrint('[PrintDiag] CRITICAL ERROR in _printPdf: $e\n$s');
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.isArabic ? 'خطأ في الطباعة' : 'Printing Error'),
          content: SingleChildScrollView(
            child: Text(
              '${widget.isArabic ? 'حدث خطأ غير متوقع أثناء محاولة الطباعة:' : 'An unexpected error occurred while trying to print:'}\n\n$e',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.isArabic ? 'موافق' : 'OK'),
            ),
          ],
        ),
      );
    } finally {
      debugPrint('[PrintDiag] _printPdf finished.');
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _ensurePdfFontsLoaded() async {
    if (_pdfFontBase != null && _pdfFontBold != null) {
      _pdfFontsReady = true;
      return;
    }

    // If a load is already in-flight, await it.
    final inFlight = _pdfFontsLoadFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    // Start a single shared load.
    final future = () async {
      final regularData = await rootBundle.load(
        'assets/fonts/Cairo-Regular.ttf',
      );
      final boldData = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
      _pdfFontBase = pw.Font.ttf(regularData);
      _pdfFontBold = pw.Font.ttf(boldData);
      _pdfFontsReady = true;
    }();

    _pdfFontsLoadFuture = future;
    try {
      await future;
    } finally {
      // Keep the future cached if fonts are loaded; otherwise allow retry.
      if (_pdfFontBase == null || _pdfFontBold == null) {
        _pdfFontsLoadFuture = null;
      }
    }
  }

  Future<void> _ensureTemplateAssetsLoaded() async {
    if (_templateAssetsReady) return;

    final inFlight = _templateAssetsLoadFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      final presetKey = await _resolveTemplatePresetKey();
      _cachedTemplateLayout = await _loadTemplateLayoutForPreset(presetKey);
      _cachedTemplateBackgroundBytes =
          await _loadTemplateBackgroundBytesForPreset(presetKey);
      _cachedTemplateBackgroundImage =
          (_cachedTemplateBackgroundBytes != null &&
              _cachedTemplateBackgroundBytes!.isNotEmpty)
          ? pw.MemoryImage(_cachedTemplateBackgroundBytes!)
          : null;
      _templateAssetsReady = true;
    }();

    _templateAssetsLoadFuture = future;
    try {
      await future;
    } finally {
      if (!_templateAssetsReady) {
        _templateAssetsLoadFuture = null;
      }
    }
  }

  double _asDouble(dynamic v, {double fallback = 0}) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    final s = v.toString().trim();
    if (s.isEmpty) return fallback;
    return double.tryParse(s) ?? fallback;
  }

  String _money(dynamic v) => _asDouble(v).toStringAsFixed(2);

  String _weight(dynamic v) {
    final d = _asDouble(v);
    // keep 3 decimals for weights by default
    return d.toStringAsFixed(3);
  }

  Future<Uint8List?> _loadTemplateBackgroundBytesForPreset(
    String? presetKey,
  ) async {
    final key = (presetKey ?? '').trim();
    if (key.isEmpty) return null;

    final include = await _loadTemplateBackgroundIncludeInPrintForPreset(key);
    if (!include) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('template_background_$key');
      if (raw == null || raw.trim().isEmpty) return null;

      final trimmed = raw.trim();
      final commaIndex = trimmed.indexOf(',');
      final data = (trimmed.startsWith('data:') && commaIndex != -1)
          ? trimmed.substring(commaIndex + 1)
          : trimmed;

      final bytes = base64Decode(data);
      if (bytes.lengthInBytes > _maxBackgroundBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _loadTemplateBackgroundIncludeInPrintForPreset(
    String presetKey,
  ) async {
    final key = presetKey.trim();
    if (key.isEmpty) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('template_background_include_in_print_$key') ?? true;
    } catch (_) {
      return true;
    }
  }


  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
    _preloadPdfFonts();
    _preloadTemplateAssets();
    _loadCompanySettings();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerInitialActionIfNeeded();
    });
  }

  Future<void> _triggerInitialActionIfNeeded() async {
    if (_autoActionTriggered) return;
    if (!(widget.autoPrint || widget.autoSharePdf || widget.autoDownloadPdf)) {
      return;
    }
    _autoActionTriggered = true;

    if (widget.autoPrint) {
      await _printPdf();
      return;
    }

    if (widget.autoSharePdf) {
      await _sharePdf();
      return;
    }

    if (widget.autoDownloadPdf) {
      await _downloadPdf();
      return;
    }
  }

  Future<void> _downloadPdf() async {
    if (_isGenerating) {
      return;
    }

    try {
      setState(() => _isGenerating = true);

      await _ensurePdfFontsLoaded();
      await _ensureTemplateAssetsLoaded();

      final format = PdfPageFormat.a4;
      final pdfBytes = await _buildPdfForFormat(
        format,
      ).timeout(const Duration(seconds: 30));

      final rawNumber = (widget.invoice['invoice_number'] ?? '').toString();
      final safeNumber = rawNumber.trim().isNotEmpty
          ? rawNumber.trim().replaceAll('/', '-')
          : DateFormat('yyyyMMdd_HHmm').format(DateTime.now());

      final fileName = 'invoice_$safeNumber.pdf';

      if (kIsWeb) {
        web_io.downloadBytes(fileName, pdfBytes, 'application/pdf');
        return;
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              pdfBytes,
              mimeType: 'application/pdf',
              name: fileName,
            ),
          ],
          text: widget.isArabic ? 'فاتورة $safeNumber' : 'Invoice $safeNumber',
        ),
      );
    } catch (e, s) {
      debugPrint('[PrintDiag] ERROR in _downloadPdf: $e\n$s');
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.isArabic ? 'خطأ في التنزيل' : 'Download Error'),
          content: SingleChildScrollView(
            child: Text(
              '${widget.isArabic ? 'تعذر تنزيل ملف PDF:' : 'Failed to download the PDF:'}\n\n$e',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.isArabic ? 'موافق' : 'OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  Future<void> _sharePdf() async {
    if (_isGenerating) {
      return;
    }

    try {
      setState(() => _isGenerating = true);

      // Ensure assets are loaded on the main isolate.
      await _ensurePdfFontsLoaded();
      await _ensureTemplateAssetsLoaded();

      final format = PdfPageFormat.a4;
      final pdfBytes = await _buildPdfForFormat(
        format,
      ).timeout(const Duration(seconds: 30));

      final rawNumber = (widget.invoice['invoice_number'] ?? '').toString();
      final safeNumber = rawNumber.trim().isNotEmpty
          ? rawNumber.trim().replaceAll('/', '-')
          : DateFormat('yyyyMMdd_HHmm').format(DateTime.now());

      final fileName = 'invoice_$safeNumber.pdf';

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              pdfBytes,
              mimeType: 'application/pdf',
              name: fileName,
            ),
          ],
          text: widget.isArabic ? 'فاتورة $safeNumber' : 'Invoice $safeNumber',
        ),
      );
    } catch (e, s) {
      debugPrint('[PrintDiag] ERROR in _sharePdf: $e\n$s');
      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(widget.isArabic ? 'خطأ في المشاركة' : 'Share Error'),
          content: SingleChildScrollView(
            child: Text(
              '${widget.isArabic ? 'تعذر مشاركة ملف PDF:' : 'Failed to share the PDF:'}\n\n$e',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.isArabic ? 'موافق' : 'OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  void _preloadPdfFonts() {
    // Preload fonts on the main isolate so printing on macOS doesn't hang
    // when onLayout tries to access rootBundle.
    _pdfFontsLoadFuture = _ensurePdfFontsLoaded();
    _pdfFontsLoadFuture!
        .then((_) {
          if (!mounted) return;
          setState(() {
            _pdfFontsReady = true;
          });
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() {
            _pdfFontsReady = false;
          });
        });
  }

  void _preloadTemplateAssets() {
    _templateAssetsLoadFuture = _ensureTemplateAssetsLoaded();
    _templateAssetsLoadFuture!
        .then((_) {
          if (!mounted) return;
          setState(() {
            _templateAssetsReady = true;
          });
        })
        .catchError((_) {
          if (!mounted) return;
          setState(() {
            _templateAssetsReady = false;
          });
        });
  }

  void _loadPrintSettings() {
    final settings = widget.printSettings ?? {};
    _showLogo = settings['showLogo'] ?? true;
    _showAddress = settings['showAddress'] ?? true;
    _showPrices = settings['showPrices'] ?? true;
    _showTaxInfo = settings['showTaxInfo'] ?? true;
    _showNotes = settings['showNotes'] ?? true;
    _paperSize = settings['paperSize'] ?? 'A4';
    _printInColor = settings['printInColor'] ?? true;
  }

  Future<void> _loadCompanySettings() async {
    Map<String, dynamic>? settings;

    bool canFetchRemote = false;
    try {
      canFetchRemote = context.read<AuthProvider>().hasPermission(
        'system.settings',
      );
    } catch (_) {
      // If provider is not available for any reason, default to no remote fetch.
      canFetchRemote = false;
    }

    // 1) Try cache from SettingsProvider/Settings screen
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('app_settings');
      if (cached != null && cached.trim().isNotEmpty) {
        final decoded = json.decode(cached);
        if (decoded is Map<String, dynamic>) {
          settings = decoded;
        } else if (decoded is Map) {
          settings = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {
      // ignore cache failures
    }

    // 2) Best-effort fetch latest from API (only if allowed)
    if (canFetchRemote) {
      try {
        final fetched = await ApiService().getSettings();
        settings = fetched;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('app_settings', json.encode(fetched));
        } catch (_) {
          // ignore caching failures
        }
      } catch (_) {
        // ignore network/auth failures; fallback to cached/defaults
      }
    }

    if (!mounted) return;

    if (settings != null) {
      final logoBase64 = settings['company_logo_base64']?.toString();
      Uint8List? logoBytes;
      if (logoBase64 != null && logoBase64.trim().isNotEmpty) {
        final trimmed = logoBase64.trim();
        final commaIndex = trimmed.indexOf(',');
        final raw = (trimmed.startsWith('data:') && commaIndex != -1)
            ? trimmed.substring(commaIndex + 1)
            : trimmed;
        try {
          logoBytes = base64Decode(raw);
        } catch (_) {
          logoBytes = null;
        }
      }

      setState(() {
        _settingsShowCompanyLogo = (settings?['show_company_logo'] == true);
        _companyName = settings?['company_name']?.toString();
        _companyAddress = settings?['company_address']?.toString();
        _companyPhone = settings?['company_phone']?.toString();
        _companyTaxNumber = settings?['company_tax_number']?.toString();
        _companyLogoBytes = logoBytes;
        _invalidatePdfCache();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isArabic ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isArabic ? 'طباعة الفاتورة' : 'Print Invoice'),
          backgroundColor: const Color(0xFFD4AF37),
          actions: [
            IconButton(
              icon: const Icon(Icons.print),
              onPressed: (_pdfFontsReady && _templateAssetsReady)
                  ? _printPdf
                  : null,
              tooltip: _isArabic ? 'طباعة' : 'Print',
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showPrintSettings,
              tooltip: _isArabic ? 'إعدادات الطباعة' : 'Print Settings',
            ),
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: (_pdfFontsReady && _templateAssetsReady)
                  ? _downloadPdf
                  : null,
              tooltip: _isArabic ? 'تحميل PDF' : 'Download PDF',
            ),
          ],
        ),
        body: (!_pdfFontsReady || !_templateAssetsReady || _isGenerating)
            ? const Center(child: CircularProgressIndicator())
            : PdfPreview(
                build: (format) => _buildPdfForFormat(format),
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                // Enable printing from preview on desktop for better macOS compatibility.
                allowPrinting: !kIsWeb,
                allowSharing: true,
                initialPageFormat: _getPdfPageFormat(),
                pdfFileName:
                    'invoice_${widget.invoice['invoice_type_id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
              ),
      ),
    );
  }

  PdfPageFormat _getPdfPageFormat() {
    switch (_paperSize) {
      case 'A5':
        return PdfPageFormat.a5;
      case 'Letter':
        return PdfPageFormat.letter;
      case 'Thermal':
        // Default thermal size in this app is 80x200mm to match positioning preset.
        return const PdfPageFormat(
          80 * PdfPageFormat.mm,
          200 * PdfPageFormat.mm,
        );
      default:
        return PdfPageFormat.a4;
    }
  }

  Future<String?> _resolveTemplatePresetKey() async {
    final fromSettings = widget.printSettings?['templatePresetKey']?.toString();
    if (fromSettings != null && fromSettings.trim().isNotEmpty) {
      return fromSettings.trim();
    }

    // If the backend provided a per-invoice template preset key, prefer it.
    final fromInvoice = widget.invoice['print_template_preset_key']?.toString();
    if (fromInvoice != null && fromInvoice.trim().isNotEmpty) {
      return fromInvoice.trim();
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final active = prefs.getString(_activePresetKeyStorage);
      if (active != null && active.trim().isNotEmpty) return active.trim();
    } catch (_) {
      // ignore
    }

    // Fallback mapping based on selected paper size.
    switch (_paperSize) {
      case 'A5':
        return 'a5_portrait';
      case 'Thermal':
        return 'thermal_80x200';
      default:
        return 'a4_portrait';
    }
  }

  Future<Map<String, _TemplateRect>?> _loadTemplateLayoutForPreset(
    String? presetKey,
  ) async {
    final key = (presetKey ?? '').trim();
    if (key.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final storageKey = 'template_positioning_$key';
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return null;

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;

    final out = <String, _TemplateRect>{};
    for (final entry in decoded.entries) {
      final v = entry.value;
      if (v is Map<String, dynamic>) {
        final rect = _TemplateRect.fromJson(v);
        out[entry.key] = rect;
      }
    }

    return out.isEmpty ? null : out;
  }

  Future<Uint8List> _generatePdf(PdfPageFormat format) async {
    final doc = pw.Document();

    debugPrint('[PrintDiag|Gen] Starting PDF generation...');
    // IMPORTANT (macOS): Do not load fonts/assets/preferences here.
    // Printing.onLayout can be invoked while a platform channel call is active.
    // Any rootBundle/SharedPreferences call here may deadlock.
    if (_pdfFontBase == null || _pdfFontBold == null) {
      debugPrint(
        '[PrintDiag|Gen] Fonts not ready in _generatePdf; returning error PDF.',
      );
      return await _buildErrorPdf(format, 'PDF fonts not ready');
    }

    final templateLayout = _cachedTemplateLayout;
    final pw.ImageProvider? templateBgImage = _cachedTemplateBackgroundImage;

    doc.addPage(
      pw.Page(
        pageFormat: format,
        textDirection: _isArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(base: _pdfFontBase!, bold: _pdfFontBold!),
        build: (context) {
          debugPrint('[PrintDiag|Gen] Starting page build...');
          if (templateLayout != null) {
            debugPrint('[PrintDiag|Gen] Building templated page...');
            final page = _buildTemplatedInvoicePage(
              context,
              templateLayout,
              backgroundImage: templateBgImage,
            );
            debugPrint('[PrintDiag|Gen] Templated page built.');
            return page;
          }
          debugPrint('[PrintDiag|Gen] Building standard page...');
          final page = pw.Column(
            crossAxisAlignment: _isArabic
                ? pw.CrossAxisAlignment.end
                : pw.CrossAxisAlignment.start,
            children: [
              // رأس الصفحة
              _buildHeader(context),
              pw.SizedBox(height: 20),

              // معلومات الفاتورة الأساسية
              _buildInvoiceInfo(context),
              pw.SizedBox(height: 20),

              // جدول الأصناف
              _buildItemsTable(context),
              pw.SizedBox(height: 20),

              // الإجماليات
              _buildTotals(context),
              pw.SizedBox(height: 20),

              // الملاحظات
              if (_showNotes && widget.invoice['notes'] != null)
                _buildNotes(context),

              pw.Spacer(),

              // ذيل الفاتورة
              _buildFooter(context),
            ],
          );
          debugPrint('[PrintDiag|Gen] Standard page built.');
          return page;
        },
      ),
    );

    debugPrint('[PrintDiag|Gen] Saving document...');
    final result = await doc.save();
    debugPrint('[PrintDiag|Gen] Document saved.');
    return result;
  }

  pw.Widget _buildHeader(pw.Context context) {
    final companyName =
        (_companyName != null && _companyName!.trim().isNotEmpty)
        ? _companyName!.trim()
        : (_isArabic ? 'مجوهرات خالد' : 'Khaled Jewelery');

    final companyAddress = (_companyAddress ?? '').trim();
    final companyPhone = (_companyPhone ?? '').trim();
    final companyTaxNumber = (_companyTaxNumber ?? '').trim();

    final shouldShowLogo = _showLogo && _settingsShowCompanyLogo;

    final companyBlock = pw.Column(
      crossAxisAlignment: _isArabic
          ? pw.CrossAxisAlignment.end
          : pw.CrossAxisAlignment.start,
      children: [
        if (shouldShowLogo)
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (_companyLogoBytes != null && !_isArabic)
                pw.Container(
                  width: 36,
                  height: 36,
                  margin: const pw.EdgeInsets.only(right: 8),
                  child: pw.Image(
                    pw.MemoryImage(_companyLogoBytes!),
                    fit: pw.BoxFit.contain,
                  ),
                ),
              pw.Text(
                companyName,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: _printInColor
                      ? const PdfColor.fromInt(0xFFD4AF37)
                      : PdfColors.black,
                ),
              ),
              if (_companyLogoBytes != null && _isArabic)
                pw.Container(
                  width: 36,
                  height: 36,
                  margin: const pw.EdgeInsets.only(left: 8),
                  child: pw.Image(
                    pw.MemoryImage(_companyLogoBytes!),
                    fit: pw.BoxFit.contain,
                  ),
                ),
            ],
          ),
        if (_showAddress) ...[
          pw.SizedBox(height: 5),
          if (companyAddress.isNotEmpty)
            pw.Text(
              '${_isArabic ? 'العنوان' : 'Address'}: $companyAddress',
              style: const pw.TextStyle(fontSize: 10),
              textAlign: _isArabic ? pw.TextAlign.right : pw.TextAlign.left,
            ),
          if (companyPhone.isNotEmpty)
            pw.Text(
              '${_isArabic ? 'هاتف' : 'Phone'}: $companyPhone',
              style: const pw.TextStyle(fontSize: 10),
              textAlign: _isArabic ? pw.TextAlign.right : pw.TextAlign.left,
            ),
          if (_showTaxInfo && companyTaxNumber.isNotEmpty)
            pw.Text(
              '${_isArabic ? 'الرقم الضريبي' : 'VAT No'}: $companyTaxNumber',
              style: const pw.TextStyle(fontSize: 10),
              textAlign: _isArabic ? pw.TextAlign.right : pw.TextAlign.left,
            ),
        ],
      ],
    );

    final invoiceTypeBlock = pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: _printInColor
            ? const PdfColor.fromInt(0xFFD4AF37)
            : PdfColors.grey300,
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        children: [
          pw.Text(
            _isArabic ? 'فاتورة' : 'Invoice',
            style: pw.TextStyle(
              fontSize: 16,
              fontWeight: pw.FontWeight.bold,
              color: _printInColor ? PdfColors.white : PdfColors.black,
            ),
          ),
          pw.Text(
            '${widget.invoice['invoice_type'] ?? ''}',
            style: pw.TextStyle(
              fontSize: 14,
              color: _printInColor ? PdfColors.white : PdfColors.black,
            ),
          ),
        ],
      ),
    );

    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 2),
        ),
      ),
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: _isArabic
            ? [invoiceTypeBlock, companyBlock]
            : [companyBlock, invoiceTypeBlock],
      ),
    );
  }

  pw.Widget _buildInvoiceInfo(pw.Context context) {
    final dateFormat = DateFormat('yyyy-MM-dd');
    final invoiceDate =
        DateTime.tryParse(widget.invoice['date']?.toString() ?? '') ??
        DateTime.now();

    final infoColumn = pw.Column(
      crossAxisAlignment: _isArabic
          ? pw.CrossAxisAlignment.end
          : pw.CrossAxisAlignment.start,
      children: [
        _buildInfoRow(
          _isArabic ? 'رقم الفاتورة:' : 'Invoice No:',
          '#${widget.invoice['invoice_type_id'] ?? ''}',
        ),
        _buildInfoRow(
          _isArabic ? 'التاريخ:' : 'Date:',
          dateFormat.format(invoiceDate),
        ),
        if (widget.invoice['customer_name'] != null)
          _buildInfoRow(
            _isArabic ? 'العميل:' : 'Customer:',
            widget.invoice['customer_name'] ?? '',
          ),
        if (widget.invoice['supplier_name'] != null)
          _buildInfoRow(
            _isArabic ? 'المورد:' : 'Supplier:',
            widget.invoice['supplier_name'] ?? '',
          ),
      ],
    );

    final postedBadge = (widget.invoice['is_posted'] == true)
        ? pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: pw.BoxDecoration(
              color: _printInColor ? PdfColors.green : PdfColors.grey300,
              borderRadius: pw.BorderRadius.circular(12),
            ),
            child: pw.Text(
              _isArabic ? 'مرحّل' : 'Posted',
              style: pw.TextStyle(
                color: _printInColor ? PdfColors.white : PdfColors.black,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          )
        : null;

    final children = <pw.Widget>[
      infoColumn,
      if (postedBadge != null) postedBadge,
    ];

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: _isArabic ? children.reversed.toList() : children,
    );
  }

  pw.Widget _buildInfoRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Align(
        alignment: _isArabic
            ? pw.Alignment.centerRight
            : pw.Alignment.centerLeft,
        child: pw.RichText(
          textAlign: _isArabic ? pw.TextAlign.right : pw.TextAlign.left,
          text: pw.TextSpan(
            children: [
              pw.TextSpan(
                text: label,
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                ),
              ),
              pw.TextSpan(
                text: ' $value',
                style: const pw.TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  pw.Widget _buildItemsTable(pw.Context context, {int? maxRows}) {
    final items = widget.invoice['items'] as List? ?? [];

    final List itemsToRender;
    final bool truncated;
    if (maxRows != null && maxRows >= 0 && items.length > maxRows) {
      itemsToRender = items.take(maxRows).toList();
      truncated = true;
    } else {
      itemsToRender = items;
      truncated = false;
    }

    final baseColumnWidths = <int, pw.TableColumnWidth>{
      0: const pw.FlexColumnWidth(0.8),
      1: const pw.FlexColumnWidth(3),
      2: const pw.FlexColumnWidth(1.2),
      3: const pw.FlexColumnWidth(1.4),
      if (_showPrices) 4: const pw.FlexColumnWidth(0.9),
      if (_showPrices) 5: const pw.FlexColumnWidth(2.7),
    };

    final columnCount = _showPrices ? 6 : 4;
    final columnWidths = _isArabic
        ? <int, pw.TableColumnWidth>{
            for (var i = 0; i < columnCount; i++)
              i: baseColumnWidths[columnCount - 1 - i]!,
          }
        : baseColumnWidths;

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400),
      columnWidths: columnWidths,
      children: [
        // رأس الجدول
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: _printInColor ? PdfColors.yellow100 : PdfColors.grey300,
          ),
          children: () {
            final headerCells = <pw.Widget>[
              _buildTableCell(widget.isArabic ? '#' : 'No', isHeader: true),
              _buildTableCell(
                widget.isArabic ? 'اسم الصنف' : 'Item Name',
                isHeader: true,
              ),
              _buildTableCell(
                widget.isArabic ? 'العيار' : 'Karat',
                isHeader: true,
              ),
              _buildTableCell(
                widget.isArabic ? 'الوزن (جم)' : 'Weight (g)',
                isHeader: true,
              ),
              if (_showPrices)
                _buildTableCell(
                  widget.isArabic ? 'الكمية' : 'Qty',
                  isHeader: true,
                ),
              if (_showPrices)
                _buildTableCell(
                  widget.isArabic ? 'تفاصيل المبلغ' : 'Amount Details',
                  isHeader: true,
                ),
            ];
            return _isArabic ? headerCells.reversed.toList() : headerCells;
          }(),
        ),

        // بيانات الأصناف
        ...itemsToRender.asMap().entries.map((entry) {
          final index = entry.key;
          final raw = entry.value;
          final item = (raw is Map)
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{};

          final name = (item['name'] ?? item['item_name'] ?? '').toString();
          final karat = (item['karat'] ?? '').toString();
          final rawWeight = item['weight'] ?? item['total_weight'];
          final weight = _weight(rawWeight);

          final qty = _asDouble(item['quantity'], fallback: 1);
          final qtyInt = qty <= 0 ? 1 : qty.round();

          final total = _asDouble(item['price'] ?? item['total']);
          final tax = _asDouble(item['tax']);
          final net = _asDouble(item['net'], fallback: (total - tax));
          final unitPrice = qtyInt > 0 ? (total / qtyInt) : total;

          final wagePerGram = _asDouble(item['wage']);
          final weightPerItem = _asDouble(rawWeight);
          final wageTotal = (wagePerGram > 0 && weightPerItem > 0)
              ? (wagePerGram * weightPerItem * qtyInt)
              : 0.0;

          final cells = <pw.Widget>[
            _buildTableCell('${index + 1}'),
            _buildTableCell(name),
            _buildTableCell(karat),
            _buildTableCell(weight),
            if (_showPrices) _buildTableCell(qtyInt.toString()),
            if (_showPrices)
              _buildAmountDetailsCell(
                unitPrice: unitPrice,
                net: net,
                tax: tax,
                total: total,
                wagePerGram: wagePerGram,
                wageTotal: wageTotal,
              ),
          ];
          return pw.TableRow(
            children: _isArabic ? cells.reversed.toList() : cells,
          );
        }),
        if (truncated)
          pw.TableRow(
            children: () {
              final truncatedCells = <pw.Widget>[
                _buildTableCell('...'),
                _buildTableCell(
                  widget.isArabic ? 'تم اختصار العناصر' : 'Items truncated',
                ),
                _buildTableCell(''),
                _buildTableCell(''),
                if (_showPrices) _buildTableCell(''),
                if (_showPrices) _buildTableCell(''),
              ];
              return _isArabic
                  ? truncatedCells.reversed.toList()
                  : truncatedCells;
            }(),
          ),
      ],
    );
  }

  pw.Widget _buildAmountDetailsCell({
    required double unitPrice,
    required double net,
    required double tax,
    required double total,
    double wagePerGram = 0,
    double wageTotal = 0,
  }) {
    final rows = <pw.Widget>[];

    rows.add(
      pw.Text(
        widget.isArabic
            ? 'وحدة: ${_money(unitPrice)}'
            : 'Unit: ${_money(unitPrice)}',
        style: const pw.TextStyle(fontSize: 9),
        textAlign: pw.TextAlign.center,
      ),
    );

    if (wagePerGram > 0) {
      rows.add(
        pw.Text(
          widget.isArabic
              ? 'مص/جم: ${_money(wagePerGram)}'
              : 'Wage/g: ${_money(wagePerGram)}',
          style: const pw.TextStyle(fontSize: 9),
          textAlign: pw.TextAlign.center,
        ),
      );
    }

    if (wageTotal > 0) {
      rows.add(
        pw.Text(
          widget.isArabic
              ? 'مصنعية: ${_money(wageTotal)}'
              : 'Wage: ${_money(wageTotal)}',
          style: const pw.TextStyle(fontSize: 9),
          textAlign: pw.TextAlign.center,
        ),
      );
    }

    rows.add(
      pw.Text(
        widget.isArabic ? 'صافي: ${_money(net)}' : 'Net: ${_money(net)}',
        style: const pw.TextStyle(fontSize: 9),
        textAlign: pw.TextAlign.center,
      ),
    );
    rows.add(
      pw.Text(
        widget.isArabic ? 'ضريبة: ${_money(tax)}' : 'VAT: ${_money(tax)}',
        style: const pw.TextStyle(fontSize: 9),
        textAlign: pw.TextAlign.center,
      ),
    );
    rows.add(
      pw.Text(
        widget.isArabic
            ? 'إجمالي: ${_money(total)}'
            : 'Total: ${_money(total)}',
        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        textAlign: pw.TextAlign.center,
      ),
    );

    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  pw.Widget _buildTableCell(String text, {bool isHeader = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 11 : 10,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  pw.Widget _buildTotals(pw.Context context) {
    if (!_showPrices) return pw.SizedBox();

    final total = _asDouble(widget.invoice['total']);
    final totalTax = _asDouble(widget.invoice['total_tax']);
    final subtotal = (total - totalTax);

    return pw.Container(
      alignment: _isArabic ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      child: pw.Container(
        width: 200,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
          borderRadius: pw.BorderRadius.circular(8),
        ),
        padding: const pw.EdgeInsets.all(10),
        child: pw.Column(
          children: [
            _buildTotalRow(
              widget.isArabic ? 'المجموع الفرعي:' : 'Subtotal:',
              subtotal.toStringAsFixed(2),
            ),
            if (_showTaxInfo && totalTax > 0) ...[
              pw.SizedBox(height: 5),
              _buildTotalRow(
                widget.isArabic ? 'ضريبة القيمة المضافة:' : 'VAT:',
                totalTax.toStringAsFixed(2),
              ),
            ],
            pw.Divider(color: PdfColors.grey400),
            _buildTotalRow(
              widget.isArabic ? 'الإجمالي:' : 'Total:',
              total.toStringAsFixed(2),
              isBold: true,
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildTotalRow(String label, String value, {bool isBold = false}) {
    final labelW = pw.Text(
      label,
      style: pw.TextStyle(
        fontSize: 10,
        fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    );
    final valueW = pw.Text(
      '$value ${_isArabic ? 'ريال' : 'SAR'}',
      style: pw.TextStyle(
        fontSize: 10,
        fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    );

    final children = _isArabic
        ? <pw.Widget>[valueW, labelW]
        : <pw.Widget>[labelW, valueW];

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: children,
    );
  }

  pw.Widget _buildNotes(pw.Context context) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      padding: const pw.EdgeInsets.all(10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            widget.isArabic ? 'ملاحظات:' : 'Notes:',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            widget.invoice['notes'] ?? '',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildFooter(pw.Context context) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: PdfColors.grey400)),
      ),
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            widget.isArabic
                ? 'شكراً لتعاملكم معنا'
                : 'Thank you for your business',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          pw.Text(
            '${widget.isArabic ? 'تاريخ الطباعة:' : 'Print Date:'} ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
  }

  void _showPrintSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'إعدادات الطباعة' : 'Print Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الشعار' : 'Show Logo'),
                value: _showLogo,
                onChanged: (val) => setState(() {
                  _showLogo = val;
                  _invalidatePdfCache();
                }),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض العنوان' : 'Show Address'),
                value: _showAddress,
                onChanged: (val) => setState(() {
                  _showAddress = val;
                  _invalidatePdfCache();
                }),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الأسعار' : 'Show Prices'),
                value: _showPrices,
                onChanged: (val) => setState(() {
                  _showPrices = val;
                  _invalidatePdfCache();
                }),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'معلومات الضريبة' : 'Tax Info'),
                value: _showTaxInfo,
                onChanged: (val) => setState(() {
                  _showTaxInfo = val;
                  _invalidatePdfCache();
                }),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الملاحظات' : 'Show Notes'),
                value: _showNotes,
                onChanged: (val) => setState(() {
                  _showNotes = val;
                  _invalidatePdfCache();
                }),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'طباعة ملونة' : 'Color Print'),
                value: _printInColor,
                onChanged: (val) => setState(() {
                  _printInColor = val;
                  _invalidatePdfCache();
                }),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isArabic ? 'إغلاق' : 'Close'),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTemplatedInvoicePage(
    pw.Context context,
    Map<String, _TemplateRect> layout, {
    pw.ImageProvider? backgroundImage,
  }) {
    pw.Widget? positioned(String id, pw.Widget child) {
      final rect = layout[id];
      if (rect == null) return null;
      if (rect.visible == false) return null;
      return pw.Positioned(
        left: rect.x,
        top: rect.y,
        child: pw.Container(
          width: rect.width,
          height: rect.height,
          child: child,
        ),
      );
    }

    final dateFormat = DateFormat('yyyy-MM-dd');
    final invoiceDate =
        DateTime.tryParse(widget.invoice['date']?.toString() ?? '') ??
        DateTime.now();

    final invoiceNumber =
        (widget.invoice['invoice_type_id'] ?? widget.invoice['id'] ?? '')
            .toString();

    final customerName =
        (widget.invoice['customer_name'] ??
                widget.invoice['supplier_name'] ??
                '')
            .toString();

    final customerPhone =
        (widget.invoice['customer_phone'] ?? widget.invoice['phone'] ?? '')
            .toString();

    final companyName =
        (_companyName != null && _companyName!.trim().isNotEmpty)
        ? _companyName!.trim()
        : (widget.isArabic ? 'مجوهرات خالد' : 'Khaled Jewelery');

    final widgets = <pw.Widget>[];

    if (backgroundImage != null) {
      widgets.add(
        pw.Positioned.fill(
          child: pw.Image(backgroundImage, fit: pw.BoxFit.fill),
        ),
      );
    }

    final company = positioned(
      'company_name',
      pw.Align(
        alignment: widget.isArabic
            ? pw.Alignment.centerRight
            : pw.Alignment.centerLeft,
        child: pw.Text(
          companyName,
          style: pw.TextStyle(
            fontSize: (layout['company_name']?.fontSize ?? 14).clamp(6, 48),
            fontWeight: pw.FontWeight.bold,
            color: _printInColor
                ? const PdfColor.fromInt(0xFFD4AF37)
                : PdfColors.black,
          ),
          maxLines: 1,
        ),
      ),
    );
    if (company != null) widgets.add(company);

    final logo = positioned(
      'logo',
      (_showLogo && _settingsShowCompanyLogo)
          ? (_companyLogoBytes != null
                ? pw.Container(
                    alignment: pw.Alignment.center,
                    child: pw.Image(
                      pw.MemoryImage(_companyLogoBytes!),
                      fit: pw.BoxFit.contain,
                    ),
                  )
                : pw.Container(
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.grey400),
                    ),
                    alignment: pw.Alignment.center,
                    child: pw.Text(
                      widget.isArabic ? 'شعار' : 'Logo',
                      style: const pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ))
          : pw.SizedBox(),
    );
    if (logo != null) widgets.add(logo);

    final invNo = positioned(
      'invoice_number',
      pw.Text(
        '${widget.isArabic ? 'رقم الفاتورة' : 'Invoice'}: #$invoiceNumber',
        style: pw.TextStyle(
          fontSize: (layout['invoice_number']?.fontSize ?? 11).clamp(6, 24),
          fontWeight: pw.FontWeight.bold,
        ),
        maxLines: 1,
      ),
    );
    if (invNo != null) widgets.add(invNo);

    final date = positioned(
      'date',
      pw.Text(
        '${widget.isArabic ? 'التاريخ' : 'Date'}: ${dateFormat.format(invoiceDate)}',
        style: pw.TextStyle(
          fontSize: (layout['date']?.fontSize ?? 11).clamp(6, 24),
        ),
        maxLines: 1,
      ),
    );
    if (date != null) widgets.add(date);

    int? maxItemRows;
    final itemsRect = layout['items_table'];
    if (itemsRect != null) {
      // Rough sizing to keep table within its slot.
      // Header + padding are accounted for; row height approximated.
      final available = (itemsRect.height - 28).clamp(0, 100000).toDouble();
      const rowHeight = 18.0;
      maxItemRows = (available / rowHeight).floor().clamp(0, 500);
    }

    if (customerName.isNotEmpty) {
      final customer = positioned(
        'customer_name',
        pw.Text(
          '${widget.isArabic ? 'العميل' : 'Customer'}: $customerName',
          style: pw.TextStyle(
            fontSize: (layout['customer_name']?.fontSize ?? 11).clamp(6, 24),
          ),
          maxLines: 1,
        ),
      );
      if (customer != null) widgets.add(customer);
    }

    if (customerPhone.isNotEmpty) {
      final phone = positioned(
        'customer_phone',
        pw.Text(
          '${widget.isArabic ? 'هاتف' : 'Phone'}: $customerPhone',
          style: pw.TextStyle(
            fontSize: (layout['customer_phone']?.fontSize ?? 11).clamp(6, 24),
          ),
          maxLines: 1,
        ),
      );
      if (phone != null) widgets.add(phone);
    }

    final items = positioned(
      'items_table',
      pw.Container(
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
        ),
        padding: const pw.EdgeInsets.all(4),
        child: _buildItemsTable(context, maxRows: maxItemRows),
      ),
    );
    if (items != null) widgets.add(items);

    if (_showPrices) {
      final total = (widget.invoice['total'] ?? 0).toString();
      final tax = (widget.invoice['total_tax'] ?? 0).toString();
      final subtotal =
          ((widget.invoice['total'] ?? 0) - (widget.invoice['total_tax'] ?? 0))
              .toString();

      final subtotalW = positioned(
        'subtotal',
        pw.Text(
          '${widget.isArabic ? 'المجموع الفرعي' : 'Subtotal'}: $subtotal',
          style: pw.TextStyle(
            fontSize: (layout['subtotal']?.fontSize ?? 10).clamp(6, 22),
          ),
          maxLines: 1,
        ),
      );
      if (subtotalW != null) widgets.add(subtotalW);

      final taxW = positioned(
        'tax',
        pw.Text(
          '${widget.isArabic ? 'الضريبة' : 'Tax'}: $tax',
          style: pw.TextStyle(
            fontSize: (layout['tax']?.fontSize ?? 10).clamp(6, 22),
          ),
          maxLines: 1,
        ),
      );
      if (taxW != null) widgets.add(taxW);

      final totalW = positioned(
        'total',
        pw.Text(
          '${widget.isArabic ? 'الإجمالي' : 'Total'}: $total',
          style: pw.TextStyle(
            fontSize: (layout['total']?.fontSize ?? 12).clamp(6, 28),
            fontWeight: pw.FontWeight.bold,
          ),
          maxLines: 1,
        ),
      );
      if (totalW != null) widgets.add(totalW);
    }

    if (_showNotes && widget.invoice['notes'] != null) {
      final notes = positioned(
        'notes',
        pw.Container(
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400),
          ),
          padding: const pw.EdgeInsets.all(6),
          child: pw.Text(
            widget.invoice['notes']?.toString() ?? '',
            style: pw.TextStyle(
              fontSize: (layout['notes']?.fontSize ?? 10).clamp(6, 18),
            ),
          ),
        ),
      );
      if (notes != null) widgets.add(notes);
    }

    final footer = positioned(
      'footer',
      pw.Text(
        widget.isArabic ? 'شكراً لتعاملكم معنا' : 'Thank you for your business',
        style: pw.TextStyle(
          fontSize: (layout['footer']?.fontSize ?? 10).clamp(6, 18),
          color: PdfColors.grey700,
        ),
        maxLines: 1,
      ),
    );
    if (footer != null) widgets.add(footer);

    return pw.Stack(children: widgets);
  }
}

class _TemplateRect {
  final double x;
  final double y;
  final double width;
  final double height;
  final double? fontSize;
  final bool? visible;

  const _TemplateRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.fontSize,
    this.visible,
  });

  factory _TemplateRect.fromJson(Map<String, dynamic> json) {
    double asDouble(dynamic v, double fallback) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? fallback;
      return fallback;
    }

    return _TemplateRect(
      x: asDouble(json['x'], 0),
      y: asDouble(json['y'], 0),
      width: asDouble(json['width'], 0),
      height: asDouble(json['height'], 0),
      fontSize: json['fontSize'] is num
          ? (json['fontSize'] as num).toDouble()
          : (json['fontSize'] is String
                ? double.tryParse(json['fontSize'] as String)
                : null),
      visible: json['visible'] is bool ? json['visible'] as bool : null,
    );
  }
}
