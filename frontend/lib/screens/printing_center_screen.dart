import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import 'accounts_screen.dart';
import 'barcode_print_screen.dart';
import 'customers_screen.dart';
import 'invoice_print_screen.dart';
import 'voucher_print_screen.dart';
import 'journal_entry_print_screen.dart';
import 'general_ledger_screen_v2.dart';
import 'reports/inventory_status_report_screen.dart';
import 'reports/sales_overview_report_screen.dart';
import 'template_studio_screen.dart';
import 'trial_balance_screen_v2.dart';

class PrintingCenterScreen extends StatefulWidget {
  final bool isArabic;

  const PrintingCenterScreen({super.key, this.isArabic = true});

  @override
  State<PrintingCenterScreen> createState() => _PrintingCenterScreenState();
}

class _PrintingCenterScreenState extends State<PrintingCenterScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();

  static const String _topMarginKey = 'printing_top_margin';
  static const String _bottomMarginKey = 'printing_bottom_margin';
  static const String _leftMarginKey = 'printing_left_margin';
  static const String _rightMarginKey = 'printing_right_margin';
  static const String _scalingKey = 'printing_scaling';
  static const String _watermarkEnabledKey = 'printing_include_watermark';
  static const String _watermarkTextKey = 'printing_watermark_text';
  static const String _emailCopyKey = 'printing_email_copy';
  static const String _secureModeKey = 'printing_secure_mode';
  static const String _presetListKey = 'printing_presets';

  SharedPreferences? _preferences;

  double _topMargin = 5;
  double _bottomMargin = 5;
  double _leftMargin = 5;
  double _rightMargin = 5;
  double _scaling = 100;
  bool _includeWatermark = true;
  bool _emailCustomerCopy = true;
  bool _secureMode = false;
  String _selectedWatermark = 'Official Copy';
  String _searchQuery = '';
  String? _selectedCategory;
  List<Map<String, dynamic>> _savedPresets = [];

  bool _showLogo = true;
  bool _showAddress = true;
  bool _showPrices = true;
  bool _showTaxInfo = true;
  bool _showNotes = true;
  String _paperSize = 'A4';
  String _orientation = 'portrait';
  int _copies = 1;
  bool _printInColor = true;
  bool _autoOpenPrintDialog = true;

  final Set<String> _favoriteActions = {
    'print_sales_invoice',
    'print_receipt_voucher',
    'print_sales_report',
  };

  final List<Map<String, dynamic>> _recentPrints = [
    {
      'titleAr': 'فاتورة بيع #1421',
      'titleEn': 'Sales Invoice #1421',
      'date': '12 Mar · 10:25',
      'status': 'completed',
      'action': 'print_sales_invoice',
    },
    {
      'titleAr': 'ميزان مراجعة فبراير',
      'titleEn': 'February Trial Balance',
      'date': '11 Mar · 18:40',
      'status': 'exported',
      'action': 'print_trial_balance',
    },
    {
      'titleAr': 'سند قبض #882',
      'titleEn': 'Receipt Voucher #882',
      'date': '11 Mar · 12:11',
      'status': 'completed',
      'action': 'print_receipt_voucher',
    },
  ];

  final List<Map<String, String>> _scheduledReminders = [
    {
      'titleAr': 'تقرير المبيعات اليومي',
      'titleEn': 'Daily sales report',
      'timeAr': 'يومياً 7:30 م',
      'timeEn': 'Daily 7:30 PM',
      'action': 'print_sales_report',
    },
    {
      'titleAr': 'كشف حساب الموردين',
      'titleEn': 'Supplier statement',
      'timeAr': 'كل خميس 4:00 م',
      'timeEn': 'Thu 4:00 PM',
      'action': 'print_account_statement',
    },
    {
      'titleAr': 'تقرير المخزون الأسبوعي',
      'titleEn': 'Weekly inventory report',
      'timeAr': 'كل إثنين 8:00 ص',
      'timeEn': 'Mon 8:00 AM',
      'action': 'print_inventory_report',
    },
  ];

  final List<Map<String, dynamic>> _templateShortcuts = [
    {
      'titleAr': 'استديو القوالب',
      'titleEn': 'Template studio',
      'descriptionAr': 'قوالب جاهزة بمقاسات طباعة + تصميم قالب جديد',
      'descriptionEn': 'Ready presets + design new templates',
      'icon': Icons.auto_awesome_mosaic_outlined,
      'route': 'studio',
    },
    {
      'titleAr': 'نسخ تلقائي بالبريد الإلكتروني',
      'titleEn': 'Automated email copies',
      'descriptionAr': 'اربط القالب بحساب البريد وارسِل نسخ PDF',
      'descriptionEn': 'Link templates with automated email PDF copies',
      'icon': Icons.email_outlined,
      'route': 'automations',
    },
  ];

  final List<Map<String, dynamic>> _quickActions = [
    {
      'action': 'print_sales_invoice',
      'titleAr': 'فاتورة فورية',
      'titleEn': 'Instant invoice',
      'icon': Icons.receipt_long,
    },
    {
      'action': 'print_receipt_voucher',
      'titleAr': 'سند قبض',
      'titleEn': 'Receipt voucher',
      'icon': Icons.arrow_downward,
    },
    {
      'action': 'print_trial_balance',
      'titleAr': 'ميزان مراجعة',
      'titleEn': 'Trial balance',
      'icon': Icons.balance,
    },
    {
      'action': 'design_template',
      'titleAr': 'تصميم قالب',
      'titleEn': 'Design template',
      'icon': Icons.design_services,
    },
    {
      'action': 'print_single_barcode',
      'titleAr': 'باركود فوري',
      'titleEn': 'Quick barcode',
      'icon': Icons.qr_code,
    },
  ];

  final List<Map<String, String>> _kpiCards = [
    {
      'value': '18',
      'trend': '+12%',
      'titleAr': 'طلبات طباعة اليوم',
      'titleEn': 'Print jobs today',
      'icon': 'print',
    },
    {
      'value': '07:15',
      'trend': 'أسرع بـ 4 دقائق',
      'titleAr': 'متوسط زمن التجهيز',
      'titleEn': 'Avg prep time',
      'icon': 'speed',
    },
    {
      'value': '4',
      'trend': '3 مهام مجدولة',
      'titleAr': 'مهام أوتوماتيكية',
      'titleEn': 'Automation jobs',
      'icon': 'bolt',
    },
  ];

  final List<Map<String, dynamic>> _workflowSteps = [
    {
      'key': 'collect',
      'icon': Icons.playlist_add_check,
      'titleAr': 'تجميع الوثائق',
      'titleEn': 'Collect documents',
      'subtitleAr': 'استيراد الفواتير والقيود المختارة',
      'subtitleEn': 'Import selected invoices and entries',
      'status': 'done',
    },
    {
      'key': 'configure',
      'icon': Icons.tune,
      'titleAr': 'ضبط الإعدادات',
      'titleEn': 'Configure settings',
      'subtitleAr': 'تم تطبيق الهوامش والعلامة المائية',
      'subtitleEn': 'Margins and watermark applied',
      'status': 'in-progress',
    },
    {
      'key': 'preview',
      'icon': Icons.visibility_outlined,
      'titleAr': 'معاينة ذكية',
      'titleEn': 'Smart preview',
      'subtitleAr': 'بث مباشر لمخرجات PDF',
      'subtitleEn': 'Live PDF output previews',
      'status': 'pending',
    },
    {
      'key': 'dispatch',
      'icon': Icons.cloud_upload_outlined,
      'titleAr': 'إرسال ومشاركة',
      'titleEn': 'Dispatch & share',
      'subtitleAr': 'أرشفة تلقائية وإرسال عبر البريد',
      'subtitleEn': 'Auto archive and email copies',
      'status': 'pending',
    },
  ];

  final List<Map<String, dynamic>> _printQueue = [];

  Map<String, dynamic>? _selectedPreviewAction;
  final List<String> _batchSelection = [];
  bool _autoScheduleEmailsAutomation = true;
  bool _autoArchivePdfCopies = true;
  bool _smartRetryOnFailure = true;
  bool _notifyOnWhatsapp = false;

  final List<Map<String, dynamic>> _bundleSuggestions = [
    {
      'titleAr': 'دفعة نهاية اليوم',
      'titleEn': 'End-of-day pack',
      'descriptionAr': 'فواتير اليوم + تقرير المبيعات + ميزان مراجعة مختصر',
      'descriptionEn': 'Daily invoices + sales report + trial balance snapshot',
      'etaAr': '3 دقائق تجهيز',
      'etaEn': 'Ready in 3 min',
      'actions': [
        'print_sales_invoice',
        'print_sales_report',
        'print_trial_balance',
      ],
    },
    {
      'titleAr': 'مستندات الموردين',
      'titleEn': 'Supplier paperwork',
      'descriptionAr': 'سندات الصرف + كشف حساب المورد',
      'descriptionEn': 'Payment vouchers + supplier statement',
      'etaAr': '90 ثانية',
      'etaEn': '90 seconds',
      'actions': ['print_payment_voucher', 'print_supplier_statement'],
    },
    {
      'titleAr': 'باركود وتجهيز معروضات',
      'titleEn': 'Barcode & showcase prep',
      'descriptionAr': 'باركود فردي + باركود متعدد + فاتورة كسر احتياطية',
      'descriptionEn': 'Single barcode + bulk barcodes + backup scrap invoice',
      'etaAr': 'دقيقة واحدة',
      'etaEn': '1 minute',
      'actions': [
        'print_single_barcode',
        'print_bulk_barcodes',
        'print_scrap_invoice',
      ],
    },
  ];

  @override
  void initState() {
    super.initState();
    _initializeSettings();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initializeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPresets = prefs.getStringList(_presetListKey) ?? [];
    if (!mounted) return;
    setState(() {
      _preferences = prefs;
      _topMargin = prefs.getDouble(_topMarginKey) ?? _topMargin;
      _bottomMargin = prefs.getDouble(_bottomMarginKey) ?? _bottomMargin;
      _leftMargin = prefs.getDouble(_leftMarginKey) ?? _leftMargin;
      _rightMargin = prefs.getDouble(_rightMarginKey) ?? _rightMargin;
      _scaling = prefs.getDouble(_scalingKey) ?? _scaling;
      _includeWatermark =
          prefs.getBool(_watermarkEnabledKey) ?? _includeWatermark;
      _selectedWatermark =
          prefs.getString(_watermarkTextKey) ?? _selectedWatermark;
      _emailCustomerCopy = prefs.getBool(_emailCopyKey) ?? _emailCustomerCopy;
      _secureMode = prefs.getBool(_secureModeKey) ?? _secureMode;
      _savedPresets = savedPresets
          .map((entry) {
            try {
              return Map<String, dynamic>.from(jsonDecode(entry));
            } catch (_) {
              return null;
            }
          })
          .whereType<Map<String, dynamic>>()
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isArabic = widget.isArabic;
    final theme = Theme.of(context);
    final allOptions = _getPrintingOptions(isArabic);

    var filtered = List<Map<String, dynamic>>.from(allOptions);
    if (_selectedCategory != null && _selectedCategory != 'all') {
      filtered = filtered
          .where((opt) => opt['category'] == _selectedCategory)
          .toList();
    }

    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((opt) {
        final titleAr = (opt['titleAr'] as String).toLowerCase();
        final titleEn = (opt['titleEn'] as String).toLowerCase();
        final descAr = (opt['descriptionAr'] as String).toLowerCase();
        final descEn = (opt['descriptionEn'] as String).toLowerCase();
        return titleAr.contains(query) ||
            titleEn.contains(query) ||
            descAr.contains(query) ||
            descEn.contains(query);
      }).toList();
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final option in filtered) {
      final category = option['category'] as String;
      grouped.putIfAbsent(category, () => []).add(option);
    }

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'مركز الطباعة' : 'Printing Center'),
          actions: [
            IconButton(
              tooltip: isArabic ? 'استديو القوالب' : 'Template studio',
              icon: const Icon(Icons.view_carousel_outlined),
              onPressed: () => _openTemplateStudio(isArabic: isArabic),
            ),
            IconButton(
              tooltip: isArabic ? 'إعدادات الطباعة' : 'Print settings',
              icon: const Icon(Icons.local_printshop_outlined),
              onPressed: _showPrintSettings,
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _showQuickPresetDialog(isArabic: isArabic),
          icon: const Icon(Icons.auto_fix_high),
          label: Text(isArabic ? 'حفظ إعداد مفضل' : 'Save preset'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeroCard(theme, isArabic),
              const SizedBox(height: 16),
              _buildKpiSection(theme, isArabic),
              const SizedBox(height: 16),
              // Category filters removed at user's request
              const SizedBox(height: 16),
              _buildQuickActions(theme, isArabic),
              const SizedBox(height: 16),
              _buildWorkflowTimeline(context, theme, isArabic),
              const SizedBox(height: 16),
              _buildQueueAndPreview(theme, isArabic),
              const SizedBox(height: 16),
              _buildAdvancedSettingsCard(theme, isArabic),
              const SizedBox(height: 16),
              _buildFavoritesSection(theme, isArabic),
              const SizedBox(height: 16),
              _buildBatchBuilder(theme, isArabic),
              const SizedBox(height: 16),
              _buildAutomationPanel(theme, isArabic),
              const SizedBox(height: 16),
              _buildRecentAndReminders(theme, isArabic),
              const SizedBox(height: 16),
              _buildTemplateShortcuts(theme, isArabic),
              const SizedBox(height: 20),
              ...grouped.entries.map(
                (entry) => _buildCategorySection(
                  context,
                  entry.key,
                  entry.value,
                  isArabic,
                ),
              ),
              if (grouped.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 48,
                          color: theme.colorScheme.secondary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isArabic
                              ? 'لا توجد نتائج مطابقة'
                              : 'No matching results',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeroCard(ThemeData theme, bool isArabic) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isArabic ? 'مركز الطباعة' : 'Gold printing control hub',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isArabic
                ? 'إدارة احترافية لكل الفواتير والتقارير والباركود من مكان واحد'
                : 'Manage invoices, vouchers, reports, and barcodes in one place.',
            style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value.trim()),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              hintText: isArabic
                  ? 'ابحث عن نوع الطباعة أو التقرير'
                  : 'Search for any print or report',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkflowTimeline(
    BuildContext context,
    ThemeData theme,
    bool isArabic,
  ) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.timeline,
              title: isArabic
                  ? 'مسار الطباعة الذكي'
                  : 'Intelligent print journey',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _workflowSteps
                  .map((step) => _buildWorkflowStepCard(step, theme, isArabic))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkflowStepCard(
    Map<String, dynamic> step,
    ThemeData theme,
    bool isArabic,
  ) {
    final status = step['status'] as String? ?? 'pending';
    final color = _workflowStatusColor(status, theme);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(step['icon'] as IconData, color: color),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _workflowStatusLabel(status, isArabic),
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            isArabic ? step['titleAr'] as String : step['titleEn'] as String,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isArabic
                ? step['subtitleAr'] as String
                : step['subtitleEn'] as String,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Color _workflowStatusColor(String status, ThemeData theme) {
    switch (status) {
      case 'done':
        return Colors.green;
      case 'in-progress':
        return theme.colorScheme.primary;
      case 'pending':
      default:
        return Colors.amber.shade700;
    }
  }

  String _workflowStatusLabel(String status, bool isArabic) {
    switch (status) {
      case 'done':
        return isArabic ? 'منجز' : 'Done';
      case 'in-progress':
        return isArabic ? 'قيد التنفيذ' : 'In progress';
      default:
        return isArabic ? 'الخطوة التالية' : 'Next up';
    }
  }

  Widget _buildQueueAndPreview(ThemeData theme, bool isArabic) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final children = [
          _buildQueueCard(theme, isArabic),
          const SizedBox(height: 16, width: 16),
          _buildPreviewCard(theme, isArabic),
        ];
        if (constraints.maxWidth > 1000) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: children[0]),
              const SizedBox(width: 16),
              Expanded(child: children[2]),
            ],
          );
        }
        return Column(children: children);
      },
    );
  }

  Widget _buildQueueCard(ThemeData theme, bool isArabic) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildSectionTitle(
                  icon: Icons.pending_actions,
                  title: isArabic
                      ? 'قائمة الانتظار الذكية'
                      : 'Smart print queue',
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _printQueue.isEmpty
                      ? null
                      : () => _handlePrintQueue(isArabic),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(isArabic ? 'تشغيل الآن' : 'Run now'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_printQueue.isEmpty)
              Text(
                isArabic
                    ? 'لا توجد مهام معلقة — أضف بعض المهام من الإجراءات السريعة.'
                    : 'Queue is empty — trigger print tasks from quick actions.',
                style: theme.textTheme.bodyMedium,
              )
            else
              ..._printQueue.map(
                (job) => _buildQueueTile(job, theme, isArabic),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueTile(
    Map<String, dynamic> job,
    ThemeData theme,
    bool isArabic,
  ) {
    final status = job['status'] as String;
    final progress = job['progress'] as double;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() => _selectedPreviewAction = job),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                  child: Icon(_getCategoryIcon(job['category'] as String)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic
                            ? job['titleAr'] as String
                            : job['titleEn'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        isArabic
                            ? job['etaAr'] as String
                            : job['etaEn'] as String,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: isArabic ? 'تخطي' : 'Skip',
                  onPressed: () => _skipQueueJob(job['id'] as String),
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
            const SizedBox(height: 8),
            Row(
              children: [
                Chip(
                  avatar: const Icon(Icons.label, size: 16),
                  label: Text(_workflowStatusLabel(status, isArabic)),
                ),
                const SizedBox(width: 8),
                Text(
                  job['id'] as String,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: isArabic ? 'إعادة المحاولة' : 'Retry',
                  onPressed: status == 'failed'
                      ? () => _retryQueueJob(job['id'] as String)
                      : null,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard(ThemeData theme, bool isArabic) {
    final previewAction = _selectedPreviewAction;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.visibility,
              title: isArabic ? 'معاينة فورية' : 'Instant preview',
            ),
            const SizedBox(height: 12),
            if (previewAction == null)
              Column(
                children: [
                  const Icon(
                    Icons.picture_as_pdf,
                    size: 72,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isArabic
                        ? 'اختر عملية من قائمة الانتظار لمعاينتها هنا'
                        : 'Select a queue item to preview it here',
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isArabic
                        ? previewAction['titleAr'] as String
                        : previewAction['titleEn'] as String,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.black.withValues(alpha: 0.04),
                    ),
                    child: const Center(
                      child: Icon(Icons.picture_as_pdf, size: 84),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _handleAction(previewAction['action'] as String),
                          icon: const Icon(Icons.open_in_new),
                          label: Text(isArabic ? 'فتح الشاشة' : 'Open screen'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _dispatchPreview(previewAction),
                          icon: const Icon(Icons.send),
                          label: Text(isArabic ? 'إرسال' : 'Dispatch'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchBuilder(ThemeData theme, bool isArabic) {
    final options = _getPrintingOptions(isArabic);
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildSectionTitle(
                  icon: Icons.layers_outlined,
                  title: isArabic
                      ? 'دفعات الطباعة الذكية'
                      : 'Intelligent batch runs',
                ),
                const Spacer(),
                TextButton(
                  onPressed: _batchSelection.isEmpty
                      ? null
                      : () => _runBatch(isArabic),
                  child: Text(isArabic ? 'طباعة الكل' : 'Print all'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: options.map((option) {
                final action = option['action'] as String;
                final selected = _batchSelection.contains(action);
                return FilterChip(
                  selected: selected,
                  label: Text(
                    isArabic
                        ? option['titleAr'] as String
                        : option['titleEn'] as String,
                  ),
                  avatar: Icon(
                    option['icon'] as IconData,
                    color: selected
                        ? theme.colorScheme.onPrimary
                        : option['color'] as Color,
                  ),
                  onSelected: (_) => _toggleBatchAction(action),
                );
              }).toList(),
            ),
            if (_bundleSuggestions.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                isArabic ? 'اقتراحات جاهزة' : 'Ready-made bundles',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _bundleSuggestions
                      .map((bundle) => _buildBundleCard(bundle, isArabic))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBundleCard(Map<String, dynamic> bundle, bool isArabic) {
    return Container(
      width: 280,
      margin: const EdgeInsetsDirectional.only(end: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.black.withValues(alpha: 0.03),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isArabic
                ? bundle['titleAr'] as String
                : bundle['titleEn'] as String,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            isArabic
                ? bundle['descriptionAr'] as String
                : bundle['descriptionEn'] as String,
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: (bundle['actions'] as List<String>)
                .map(
                  (action) =>
                      Chip(label: Text(action.replaceAll('print_', ''))),
                )
                .toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                isArabic
                    ? bundle['etaAr'] as String
                    : bundle['etaEn'] as String,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _applyBundle(bundle),
                icon: const Icon(Icons.auto_awesome),
                label: Text(isArabic ? 'تفعيل' : 'Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAutomationPanel(ThemeData theme, bool isArabic) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.bolt,
              title: isArabic
                  ? 'أتمتة الإرسال والمشاركة'
                  : 'Dispatch automations',
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: Text(isArabic ? 'جدولة البريد' : 'Schedule emails'),
              subtitle: Text(
                isArabic
                    ? 'إرسال نسخة PDF تلقائياً بعد اكتمال الطباعة'
                    : 'Email PDFs automatically after printing',
              ),
              value: _autoScheduleEmailsAutomation,
              onChanged: (value) => setState(() {
                _autoScheduleEmailsAutomation = value;
              }),
            ),
            SwitchListTile(
              title: Text(isArabic ? 'أرشفة سحابية' : 'Cloud archiving'),
              subtitle: Text(
                isArabic
                    ? 'حفظ نسخة في مجلد الأرشيف الذهبي'
                    : 'Archive a copy in the gold vault folder',
              ),
              value: _autoArchivePdfCopies,
              onChanged: (value) => setState(() {
                _autoArchivePdfCopies = value;
              }),
            ),
            SwitchListTile(
              title: Text(isArabic ? 'إعادة المحاولة الذكية' : 'Smart retries'),
              subtitle: Text(
                isArabic
                    ? 'إعادة المحاولة تلقائياً عند فشل الطباعة'
                    : 'Automatically retry failed print jobs',
              ),
              value: _smartRetryOnFailure,
              onChanged: (value) => setState(() {
                _smartRetryOnFailure = value;
              }),
            ),
            SwitchListTile(
              title: Text(isArabic ? 'تنبيه واتساب' : 'WhatsApp alert'),
              subtitle: Text(
                isArabic
                    ? 'إرسال إشعار مختصر إلى المسؤول'
                    : 'Send a quick WhatsApp update to admins',
              ),
              value: _notifyOnWhatsapp,
              onChanged: (value) => setState(() {
                _notifyOnWhatsapp = value;
              }),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleBatchAction(String action) {
    setState(() {
      if (_batchSelection.contains(action)) {
        _batchSelection.remove(action);
      } else {
        _batchSelection.add(action);
      }
    });
  }

  void _applyBundle(Map<String, dynamic> bundle) {
    final actions = List<String>.from(bundle['actions'] as List);
    setState(() {
      for (final action in actions) {
        if (!_batchSelection.contains(action)) {
          _batchSelection.add(action);
        }
      }
    });
  }

  void _runBatch(bool isArabic) {
    if (_batchSelection.isEmpty) return;
    final count = _batchSelection.length;
    _showSnack(
      isArabic ? 'جارٍ تجهيز $count وثيقة' : 'Preparing $count documents',
    );
  }

  void _handlePrintQueue(bool isArabic) {
    if (_printQueue.isEmpty) return;
    final current = _printQueue.first;
    setState(() {
      _selectedPreviewAction = current;
    });
    _showSnack(
      isArabic
          ? 'تم تفعيل ${current['titleAr']}'
          : 'Activated ${current['titleEn']}',
    );
  }

  Map<String, dynamic>? _findPrintOptionByAction(String action) {
    for (final option in _getPrintingOptions(true)) {
      if (option['action'] == action) {
        return option;
      }
    }
    return null;
  }

  void _registerPrintJob({
    required String action,
    required String jobId,
    required String titleAr,
    required String titleEn,
    String? etaAr,
    String? etaEn,
    Map<String, String>? metaAr,
    Map<String, String>? metaEn,
    double progress = 0.25,
    String status = 'in-progress',
  }) {
    final option = _findPrintOptionByAction(action);
    final category = option?['category'] as String? ?? 'general';
    final jobMetaAr = metaAr != null
        ? Map<String, String>.from(metaAr)
        : <String, String>{};
    final jobMetaEn = metaEn != null
        ? Map<String, String>.from(metaEn)
        : <String, String>{};

    setState(() {
      _printQueue.removeWhere((job) => job['id'] == jobId);
      _printQueue.insert(0, {
        'id': jobId,
        'titleAr': titleAr,
        'titleEn': titleEn,
        'etaAr': etaAr ?? 'جارٍ التحضير',
        'etaEn': etaEn ?? 'Preparing document',
        'status': status,
        'progress': progress,
        'action': action,
        'category': category,
        'metaAr': jobMetaAr,
        'metaEn': jobMetaEn,
        'createdAt': DateTime.now().toIso8601String(),
      });
      while (_printQueue.length > 6) {
        _printQueue.removeLast();
      }
      _selectedPreviewAction = _printQueue.first;
    });
  }

  String _formatRecentTimestamp(bool isArabic) {
    final locale = isArabic ? 'ar' : 'en';
    final formatter = intl.DateFormat('d MMM · HH:mm', locale);
    return formatter.format(DateTime.now());
  }

  void _markQueueJobCompleted(String jobId) {
    final index = _printQueue.indexWhere((job) => job['id'] == jobId);
    if (index == -1) return;

    final job = _printQueue[index];
    final updatedJob = {
      ...job,
      'status': 'done',
      'progress': 1.0,
      'etaAr': 'اكتملت للتو',
      'etaEn': 'Completed just now',
    };
    final recentRecord = {
      'titleAr': job['titleAr'],
      'titleEn': job['titleEn'],
      'date': _formatRecentTimestamp(widget.isArabic),
      'status': 'completed',
      'action': job['action'],
    };

    setState(() {
      _printQueue[index] = updatedJob;
      if (_selectedPreviewAction != null &&
          _selectedPreviewAction?['id'] == jobId) {
        _selectedPreviewAction = updatedJob;
      }
      _recentPrints.insert(0, recentRecord);
      while (_recentPrints.length > 6) {
        _recentPrints.removeLast();
      }
    });
  }

  String _generateJobId(String prefix) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '#$prefix-$timestamp';
  }

  Map<String, String> _resolveActionTitles(
    String action, {
    required String fallbackAr,
    required String fallbackEn,
  }) {
    final option = _findPrintOptionByAction(action);
    final ar = option?['titleAr'] as String? ?? fallbackAr;
    final en = option?['titleEn'] as String? ?? fallbackEn;
    return {'ar': ar, 'en': en};
  }

  Future<void> _launchTrackedScreen({
    required String action,
    required String jobId,
    required String titleAr,
    required String titleEn,
    required WidgetBuilder builder,
    Map<String, String>? metaAr,
    Map<String, String>? metaEn,
    String? etaAr,
    String? etaEn,
    double progress = 0.25,
  }) async {
    _registerPrintJob(
      action: action,
      jobId: jobId,
      titleAr: titleAr,
      titleEn: titleEn,
      etaAr: etaAr,
      etaEn: etaEn,
      metaAr: metaAr,
      metaEn: metaEn,
      progress: progress,
    );

    try {
      await Navigator.of(context).push(MaterialPageRoute(builder: builder));
    } finally {
      if (!mounted) return;
      _markQueueJobCompleted(jobId);
    }
  }

  void _skipQueueJob(String id) {
    setState(() {
      final removedSelected =
          _selectedPreviewAction != null && _selectedPreviewAction?['id'] == id;
      _printQueue.removeWhere((job) => job['id'] == id);
      if (removedSelected) {
        _selectedPreviewAction = _printQueue.isNotEmpty
            ? _printQueue.first
            : null;
      }
    });
  }

  void _retryQueueJob(String id) {
    final index = _printQueue.indexWhere((job) => job['id'] == id);
    if (index == -1) return;
    setState(() {
      _printQueue[index] = {
        ..._printQueue[index],
        'status': 'in-progress',
        'progress': 0.25,
        'etaAr': 'جارٍ إعادة المحاولة',
        'etaEn': 'Retrying now',
      };
    });
  }

  void _dispatchPreview(Map<String, dynamic> previewAction) {
    _showSnack(
      widget.isArabic
          ? 'تم إرسال ${previewAction['titleAr']}'
          : '${previewAction['titleEn']} dispatched',
    );
  }

  Widget _buildKpiSection(ThemeData theme, bool isArabic) {
    return SizedBox(
      height: 170,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _kpiCards.length,
        separatorBuilder: (context, index) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          final kpi = _kpiCards[index];
          return Container(
            width: 220,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                  child: Icon(
                    _getKpiIcon(kpi['icon']!),
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  kpi['value']!,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isArabic ? kpi['titleAr']! : kpi['titleEn']!,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  kpi['trend']!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  IconData _getKpiIcon(String key) {
    switch (key) {
      case 'print':
        return Icons.print_outlined;
      case 'speed':
        return Icons.speed;
      case 'bolt':
        return Icons.bolt;
      default:
        return Icons.auto_graph;
    }
  }

  // Category filters were removed per user request.

  // removed _scrollToCategory helper - no longer used

  Widget _buildQuickActions(ThemeData theme, bool isArabic) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.flash_on,
              title: isArabic ? 'إجراءات سريعة' : 'Quick actions',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _quickActions.map((action) {
                final label = isArabic
                    ? action['titleAr'] as String
                    : action['titleEn'] as String;
                final icon = action['icon'] as IconData;

                return Tooltip(
                  message: label,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.02),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Material(
                        color: theme.cardColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: theme.dividerColor),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () =>
                              _handleQuickAction(action['action'] as String),
                          overlayColor: WidgetStateProperty.resolveWith((
                            states,
                          ) {
                            if (states.contains(WidgetState.pressed)) {
                              return theme.colorScheme.primary.withValues(
                                alpha: 0.12,
                              );
                            } else if (states.contains(WidgetState.hovered)) {
                              return theme.colorScheme.primary.withValues(
                                alpha: 0.06,
                              );
                            }
                            return null;
                          }),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: theme.colorScheme.primary
                                        .withValues(alpha: 0.12),
                                  ),
                                  child: Icon(
                                    icon,
                                    color: theme.colorScheme.primary,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  label,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedSettingsCard(ThemeData theme, bool isArabic) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.tune,
              title: isArabic
                  ? 'إعدادات الطباعة المتقدمة'
                  : 'Advanced print settings',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 18,
              runSpacing: 18,
              children: [
                _buildMarginSlider(
                  isArabic ? 'هامش علوي' : 'Top margin',
                  _topMargin,
                  (value) {
                    setState(() => _topMargin = value);
                    _persistPreference(_topMarginKey, value);
                  },
                ),
                _buildMarginSlider(
                  isArabic ? 'هامش سفلي' : 'Bottom margin',
                  _bottomMargin,
                  (value) {
                    setState(() => _bottomMargin = value);
                    _persistPreference(_bottomMarginKey, value);
                  },
                ),
                _buildMarginSlider(
                  isArabic ? 'هامش أيمن' : 'Right margin',
                  _rightMargin,
                  (value) {
                    setState(() => _rightMargin = value);
                    _persistPreference(_rightMarginKey, value);
                  },
                ),
                _buildMarginSlider(
                  isArabic ? 'هامش أيسر' : 'Left margin',
                  _leftMargin,
                  (value) {
                    setState(() => _leftMargin = value);
                    _persistPreference(_leftMarginKey, value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildScalingSlider(isArabic),
            const Divider(height: 32),
            _buildSwitchRow(
              isArabic ? 'علامة مائية' : 'Watermark',
              _includeWatermark,
              (value) {
                setState(() => _includeWatermark = value);
                _persistPreference(_watermarkEnabledKey, value);
              },
              subtitle: isArabic
                  ? 'إظهار شعار الشركة على كل الصفحات'
                  : 'Show company watermark on all pages',
            ),
            if (_includeWatermark)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 12),
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedWatermark,
                  decoration: InputDecoration(
                    labelText: isArabic ? 'نوع العلامة' : 'Watermark text',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Official Copy',
                      child: Text('Official Copy'),
                    ),
                    DropdownMenuItem(
                      value: 'Customer Copy',
                      child: Text('Customer Copy'),
                    ),
                    DropdownMenuItem(
                      value: 'Draft Copy',
                      child: Text('Draft Copy'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedWatermark = value);
                      _persistPreference(_watermarkTextKey, value);
                    }
                  },
                ),
              ),
            const SizedBox(height: 12),
            _buildSwitchRow(
              isArabic ? 'إرسال نسخة بالبريد' : 'Email PDF copy',
              _emailCustomerCopy,
              (value) {
                setState(() => _emailCustomerCopy = value);
                _persistPreference(_emailCopyKey, value);
              },
              subtitle: isArabic
                  ? 'إرسال نسخة تلقائية للعميل بعد الطباعة'
                  : 'Automatically email the customer after printing',
            ),
            const SizedBox(height: 12),
            _buildSwitchRow(
              isArabic ? 'وضع الحماية' : 'Secure mode',
              _secureMode,
              (value) {
                setState(() => _secureMode = value);
                _persistPreference(_secureModeKey, value);
              },
              subtitle: isArabic
                  ? 'إخفاء البيانات الحساسة عند المشاركة'
                  : 'Mask sensitive data when sharing documents',
            ),
            if (_savedPresets.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                isArabic ? 'الإعدادات المحفوظة' : 'Saved presets',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _savedPresets.map((preset) {
                  final name = preset['name'] as String? ?? '';
                  return InputChip(
                    avatar: const Icon(Icons.auto_awesome),
                    label: Text(name),
                    onPressed: () => _applyPreset(preset),
                    deleteIcon: const Icon(Icons.delete_outline),
                    onDeleted: () => _deletePreset(name),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMarginSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          Slider(
            value: value,
            min: 0,
            max: 20,
            divisions: 20,
            label: '${value.toStringAsFixed(0)} mm',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildScalingSlider(bool isArabic) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isArabic ? 'حجم المخرجات' : 'Output scaling',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Slider(
          value: _scaling,
          min: 80,
          max: 120,
          divisions: 8,
          label: '${_scaling.toInt()}%',
          onChanged: (value) {
            setState(() => _scaling = value);
            _persistPreference(_scalingKey, value);
          },
        ),
      ],
    );
  }

  Widget _buildSwitchRow(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle != null ? Text(subtitle) : null,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildFavoritesSection(ThemeData theme, bool isArabic) {
    final options = _getPrintingOptions(
      isArabic,
    ).where((option) => _favoriteActions.contains(option['action'])).toList();

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.star,
              title: isArabic ? 'المفضلة الذكية' : 'Smart favorites',
            ),
            const SizedBox(height: 12),
            if (options.isEmpty)
              Text(
                isArabic
                    ? 'ابدأ بإضافة خيارات للوصول السريع.'
                    : 'Mark options as favorites for one-tap access.',
                style: theme.textTheme.bodyMedium,
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: options
                    .map((option) => _buildFavoriteChip(option, isArabic))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoriteChip(Map<String, dynamic> option, bool isArabic) {
    final action = option['action'] as String;
    final available = option['available'] as bool? ?? true;
    return FilterChip(
      label: Text(isArabic ? option['titleAr'] : option['titleEn']),
      avatar: Icon(option['icon'] as IconData),
      selected: true,
      onSelected: available ? (_) => _handleAction(action) : null,
      deleteIcon: const Icon(Icons.close),
      onDeleted: () => _toggleFavorite(action),
    );
  }

  Widget _buildRecentAndReminders(ThemeData theme, bool isArabic) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = [
          _buildRecentPrintsCard(theme, isArabic),
          _buildRemindersCard(theme, isArabic),
        ];
        if (constraints.maxWidth < 900) {
          return Column(
            children: [
              ...content.map(
                (widget) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: widget,
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content[0]),
            const SizedBox(width: 16),
            Expanded(child: content[1]),
          ],
        );
      },
    );
  }

  Widget _buildRecentPrintsCard(ThemeData theme, bool isArabic) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.history,
              title: isArabic ? 'آخر عمليات الطباعة' : 'Recent prints',
            ),
            const SizedBox(height: 12),
            ..._recentPrints.map((printJob) {
              final action = printJob['action'] as String;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                  child: const Icon(Icons.print_outlined),
                ),
                title: Text(
                  isArabic
                      ? printJob['titleAr'] as String
                      : printJob['titleEn'] as String,
                ),
                subtitle: Text(printJob['date'] as String),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: isArabic ? 'إعادة الطباعة' : 'Reprint',
                  onPressed: () => _handleAction(action),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildRemindersCard(ThemeData theme, bool isArabic) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.schedule,
              title: isArabic ? 'تذكيرات مجدولة' : 'Scheduled reminders',
            ),
            const SizedBox(height: 12),
            ..._scheduledReminders.map((reminder) {
              final action = reminder['action']!;
              return Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  title: Text(
                    isArabic ? reminder['titleAr']! : reminder['titleEn']!,
                  ),
                  subtitle: Text(
                    isArabic ? reminder['timeAr']! : reminder['timeEn']!,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.play_circle_fill),
                    onPressed: () => _handleAction(action),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildTemplateShortcuts(ThemeData theme, bool isArabic) {
    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle(
              icon: Icons.design_services,
              title: isArabic
                  ? 'القوالب الذكية والإعدادات'
                  : 'Smart templates & presets',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _templateShortcuts.map((template) {
                return SizedBox(
                  width: 260,
                  child: Card(
                    color: theme.colorScheme.surfaceContainerHighest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _handleTemplateShortcut(template, isArabic),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              backgroundColor: theme.colorScheme.primary
                                  .withValues(alpha: 0.15),
                              child: Icon(
                                template['icon'] as IconData,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              isArabic
                                  ? template['titleAr'] as String
                                  : template['titleEn'] as String,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isArabic
                                  ? template['descriptionAr'] as String
                                  : template['descriptionEn'] as String,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategorySection(
    BuildContext context,
    String category,
    List<Map<String, dynamic>> options,
    bool isArabic,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: _getCategoryIcon(category),
            title: _getCategoryLabel(category, isArabic),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: options
                .map((option) => _buildPrintOptionCard(option, isArabic))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintOptionCard(Map<String, dynamic> option, bool isArabic) {
    final bool available = option['available'] as bool? ?? true;
    final action = option['action'] as String;
    final isFavorite = _favoriteActions.contains(action);

    return SizedBox(
      width: 320,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: (option['color'] as Color).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      option['icon'] as IconData,
                      color: option['color'] as Color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isArabic ? option['titleAr'] : option['titleEn'],
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isArabic
                              ? option['descriptionAr']
                              : option['descriptionEn'],
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      isFavorite ? Icons.star : Icons.star_border,
                      color: isFavorite
                          ? option['color'] as Color
                          : Colors.grey,
                    ),
                    onPressed: () => _toggleFavorite(action),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  Chip(
                    label: Text(
                      _getCategoryLabel(option['category'], isArabic),
                    ),
                    backgroundColor: (option['color'] as Color).withValues(
                      alpha: 0.15,
                    ),
                  ),
                  if (!available)
                    const Chip(
                      label: Text('قريباً / Coming soon'),
                      avatar: Icon(Icons.lock_clock, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: available ? () => _handleAction(action) : null,
                  child: Text(
                    available
                        ? (isArabic ? 'بدء الطباعة' : 'Start printing')
                        : (isArabic ? 'قريباً' : 'Soon'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle({required IconData icon, required String title}) {
    return Row(
      children: [
        Icon(icon, color: Colors.amber.shade700),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ],
    );
  }

  Future<void> _persistPreference(String key, Object value) async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    _preferences = prefs;
    if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  Map<String, dynamic> _currentPresetData() {
    return {
      'topMargin': _topMargin,
      'bottomMargin': _bottomMargin,
      'leftMargin': _leftMargin,
      'rightMargin': _rightMargin,
      'scaling': _scaling,
      'includeWatermark': _includeWatermark,
      'selectedWatermark': _selectedWatermark,
      'emailCustomerCopy': _emailCustomerCopy,
      'secureMode': _secureMode,
    };
  }

  Future<void> _savePreset(String name) async {
    final preset = {
      'name': name,
      'savedAt': DateTime.now().toIso8601String(),
      'data': _currentPresetData(),
    };

    setState(() {
      _savedPresets.removeWhere((element) {
        final existing = (element['name'] as String?) ?? '';
        return existing.toLowerCase() == name.toLowerCase();
      });
      _savedPresets.insert(0, preset);
      if (_savedPresets.length > 5) {
        _savedPresets = _savedPresets.sublist(0, 5);
      }
    });

    await _persistSavedPresets();
    _showSnack(
      widget.isArabic
          ? 'تم حفظ الإعداد "$name" للاستخدام السريع'
          : 'Preset "$name" saved for quick reuse',
    );
  }

  Future<void> _persistSavedPresets() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    _preferences = prefs;
    final encoded = _savedPresets.map(jsonEncode).toList();
    await prefs.setStringList(_presetListKey, encoded);
  }

  void _applyPreset(Map<String, dynamic> preset) {
    final data = Map<String, dynamic>.from(preset['data'] as Map);
    setState(() {
      _topMargin = _valueAsDouble(data['topMargin'], _topMargin);
      _bottomMargin = _valueAsDouble(data['bottomMargin'], _bottomMargin);
      _leftMargin = _valueAsDouble(data['leftMargin'], _leftMargin);
      _rightMargin = _valueAsDouble(data['rightMargin'], _rightMargin);
      _scaling = _valueAsDouble(data['scaling'], _scaling);
      _includeWatermark = _valueAsBool(
        data['includeWatermark'],
        _includeWatermark,
      );
      _selectedWatermark =
          (data['selectedWatermark'] as String?) ?? _selectedWatermark;
      _emailCustomerCopy = _valueAsBool(
        data['emailCustomerCopy'],
        _emailCustomerCopy,
      );
      _secureMode = _valueAsBool(data['secureMode'], _secureMode);
    });
    _persistAllSettings();
    final name = preset['name'] as String? ?? '';
    final label = name.isEmpty
        ? (widget.isArabic ? 'الإعداد المحدد' : 'Preset')
        : '"$name"';
    _showSnack(widget.isArabic ? 'تم تطبيق $label' : '$label applied');
  }

  Future<void> _deletePreset(String name) async {
    setState(() {
      _savedPresets.removeWhere((preset) {
        final existing = (preset['name'] as String?) ?? '';
        return existing.toLowerCase() == name.toLowerCase();
      });
    });
    await _persistSavedPresets();
    final label = name.isEmpty
        ? (widget.isArabic ? 'الإعداد المحدد' : 'Preset')
        : '"$name"';
    _showSnack(widget.isArabic ? 'تم حذف $label' : '$label removed');
  }

  Future<void> _persistAllSettings() async {
    await _persistPreference(_topMarginKey, _topMargin);
    await _persistPreference(_bottomMarginKey, _bottomMargin);
    await _persistPreference(_leftMarginKey, _leftMargin);
    await _persistPreference(_rightMarginKey, _rightMargin);
    await _persistPreference(_scalingKey, _scaling);
    await _persistPreference(_watermarkEnabledKey, _includeWatermark);
    await _persistPreference(_watermarkTextKey, _selectedWatermark);
    await _persistPreference(_emailCopyKey, _emailCustomerCopy);
    await _persistPreference(_secureModeKey, _secureMode);
  }

  double _valueAsDouble(dynamic input, double fallback) {
    if (input is num) return input.toDouble();
    if (input is String) return double.tryParse(input) ?? fallback;
    return fallback;
  }

  bool _valueAsBool(dynamic input, bool fallback) {
    if (input is bool) return input;
    if (input is String) {
      return input.toLowerCase() == 'true';
    }
    return fallback;
  }

  void _toggleFavorite(String action) {
    setState(() {
      if (_favoriteActions.contains(action)) {
        _favoriteActions.remove(action);
      } else {
        _favoriteActions.add(action);
      }
    });
  }

  Future<void> _handleQuickAction(String action) async {
    if (action == 'design_template') {
      _openTemplateStudio(isArabic: widget.isArabic);
      return;
    }
    await _handleAction(action);
  }

  void _handleTemplateShortcut(Map<String, dynamic> shortcut, bool isArabic) {
    switch (shortcut['route']) {
      case 'studio':
        _openTemplateStudio(isArabic: isArabic);
        break;
      default:
        _showSnack(
          isArabic
              ? 'سيتم إضافة الربط قريباً'
              : 'Automation shortcut coming soon',
        );
    }
  }

  void _openTemplateStudio({required bool isArabic}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TemplateStudioScreen(isArabic: isArabic),
      ),
    );
  }

  Future<void> _showQuickPresetDialog({required bool isArabic}) async {
    final controller = TextEditingController(
      text: isArabic ? 'القالب الذهبي' : 'Golden Template',
    );
    final presetName = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Directionality(
          textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isArabic ? 'حفظ الإعدادات الحالية' : 'Save current preset',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  isArabic
                      ? 'اختر اسماً يسهل تذكره لإعدادات الهوامش والعلامة المائية.'
                      : 'Give this mix of margins and watermark settings a memorable name.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    labelText: isArabic ? 'اسم الإعداد' : 'Preset name',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(isArabic ? 'إلغاء' : 'Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.save_alt),
                        onPressed: () {
                          final value = controller.text.trim();
                          if (value.isEmpty) {
                            _showSnack(
                              isArabic
                                  ? 'يرجى إدخال اسم الإعداد'
                                  : 'Please enter a preset name',
                            );
                            return;
                          }
                          Navigator.pop(context, value);
                        },
                        label: Text(isArabic ? 'حفظ الآن' : 'Save preset'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();

    if (presetName != null && presetName.trim().isNotEmpty) {
      await _savePreset(presetName.trim());
    }
  }

  Future<void> _handleAction(String action) async {
    switch (action) {
      case 'print_sales_invoice':
      case 'print_purchase_invoice':
      case 'print_return_invoice':
      case 'print_scrap_invoice':
        await _showInvoicePickerAndPrint(action);
        break;
      case 'print_receipt_voucher':
      case 'print_payment_voucher':
        await _showVoucherPickerAndPrint(action);
        break;
      case 'print_journal_entry':
        await _showJournalEntryPickerAndPrint();
        break;
      case 'print_sales_report':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'تقرير المبيعات',
            fallbackEn: 'Sales report',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('RPT-SALES'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'يتم فتح استوديو تقرير المبيعات',
            etaEn: 'Opening sales report studio',
            metaAr: {
              'آخر فترة': 'آخر 30 يومًا (يمكن تعديلها لاحقًا)',
              'الوضع': 'تجهيز تقرير تفاعلي مع الطباعة',
            },
            metaEn: {
              'Recent range': 'Last 30 days (adjustable later)',
              'Mode': 'Interactive report workspace',
            },
            builder: (_) => SalesOverviewReportScreen(
              api: _apiService,
              isArabic: widget.isArabic,
            ),
          );
          break;
        }
      case 'print_inventory_report':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'تقرير المخزون',
            fallbackEn: 'Inventory report',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('RPT-INV'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'جارٍ تحميل مخزون مكاتب التسكير',
            etaEn: 'Loading inventory workspace',
            metaAr: {
              'التفاصيل': 'اضبط الأعيرة والفرز داخل الشاشة',
              'النطاق': 'يعرض الأصناف البطيئة والمتحركة',
            },
            metaEn: {
              'Details': 'Configure karats & sorting inside the screen',
              'Scope': 'Highlights slow vs active items',
            },
            builder: (_) => InventoryStatusReportScreen(
              api: _apiService,
              isArabic: widget.isArabic,
            ),
          );
          break;
        }
      case 'print_trial_balance':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'ميزان المراجعة',
            fallbackEn: 'Trial balance',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('RPT-TB'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'جارٍ تجهيز ميزان المراجعة',
            etaEn: 'Preparing trial balance',
            metaAr: {
              'ملاحظة': 'اختر فترة التقرير وتفاصيل العيارات داخل الشاشة',
              'الدقة': 'يعرض الأوزان والأرصدة بدقة كاملة',
            },
            metaEn: {
              'Note': 'Pick the reporting period & karat detail inside',
              'Precision': 'Shows full gold & cash balances',
            },
            builder: (_) => const TrialBalanceScreenV2(),
          );
          break;
        }
      case 'print_general_ledger':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'دفتر الأستاذ',
            fallbackEn: 'General ledger',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('RPT-GL'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'يتم تحميل دفتر الأستاذ المتقدم',
            etaEn: 'Loading advanced ledger',
            metaAr: {
              'التوجيه': 'حدد الحساب والفترة من داخل الشاشة',
              'المخرجات': 'تصدير PDF/Excel بعد التصفية',
            },
            metaEn: {
              'Guidance': 'Select account & period from the screen',
              'Output': 'Export PDF/Excel after filtering',
            },
            builder: (_) => const GeneralLedgerScreenV2(),
          );
          break;
        }
      case 'print_single_barcode':
        await _showBarcodeItemPicker(action);
        break;
      case 'print_bulk_barcodes':
        _showSnack(
          widget.isArabic
              ? 'ميزة الطباعة المتعددة قيد التطوير'
              : 'Bulk barcode printing is coming soon',
        );
        break;
      case 'print_account_statement':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'كشف حساب تفصيلي',
            fallbackEn: 'Account statement',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('STM-ACC'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'اختر الحساب ثم اطبع من داخل الشاشة',
            etaEn: 'Pick the account then print inside the screen',
            metaAr: {
              'ملاحظة': 'استخدم زر كشف الحساب ثم تصدير PDF',
              'التوجيه': 'يمكن تصفية النتائج حسب التاريخ والعيار',
            },
            metaEn: {
              'Note': 'Use the statement button then export PDF',
              'Hint': 'Filter by date & karat before printing',
            },
            builder: (_) =>
                const AccountsScreen(initialOnlyDetailAccounts: true),
          );
          break;
        }
      case 'print_customer_statement':
        {
          final titles = _resolveActionTitles(
            action,
            fallbackAr: 'كشف حساب العملاء',
            fallbackEn: 'Customer statement',
          );
          await _launchTrackedScreen(
            action: action,
            jobId: _generateJobId('STM-CUS'),
            titleAr: titles['ar']!,
            titleEn: titles['en']!,
            etaAr: 'يتم تحميل قائمة العملاء مع كشوفاتهم',
            etaEn: 'Loading customers with statements',
            metaAr: {
              'التوجيه': 'اختر العميل واضغط كشف الحساب ثم طباعة',
              'معلومة': 'يمكن البحث بالاسم أو الهاتف',
            },
            metaEn: {
              'Guidance': 'Select the customer then open statement > print',
              'Tip': 'Search by name or phone to narrow results',
            },
            builder: (_) =>
                CustomersScreen(api: _apiService, isArabic: widget.isArabic),
          );
          break;
        }
      default:
        _showSnack(
          widget.isArabic
              ? 'سيتم ربط هذا الخيار قريباً'
              : 'This option will be linked soon',
        );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showInvoicePickerAndPrint(String action) async {
    try {
      final response = await _apiService.getInvoices(page: 1, perPage: 50);
      if (!mounted) return;
      final invoices = response['invoices'] as List<dynamic>? ?? [];

      if (invoices.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد فواتير متاحة'
              : 'There are no invoices to print yet',
        );
        return;
      }

      // تصفية حسب نوع الفاتورة المطلوب
      List<dynamic> filteredInvoices = invoices;
      String filterType = '';

      switch (action) {
        case 'print_sales_invoice':
          filterType = widget.isArabic ? 'بيع' : 'sell';
          break;
        case 'print_purchase_invoice':
          filterType = widget.isArabic ? 'شراء' : 'buy';
          break;
        case 'print_return_invoice':
          filterType = widget.isArabic ? 'مرتجع' : 'return';
          break;
        case 'print_scrap_invoice':
          filterType = widget.isArabic ? 'كسر' : 'scrap';
          break;
      }

      if (filterType.isNotEmpty) {
        filteredInvoices = invoices.where((invoice) {
          final type = (invoice['invoice_type'] ?? '').toString().toLowerCase();
          return type.contains(filterType.toLowerCase());
        }).toList();
      }

      if (filteredInvoices.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد فواتير من هذا النوع'
              : 'No invoices of this type available',
        );
        return;
      }

      final selectedInvoice = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) =>
            _buildInvoicePickerDialog(filteredInvoices, action),
      );

      if (selectedInvoice != null && mounted) {
        final invoiceNumber =
            selectedInvoice['invoice_type_id']?.toString() ??
            selectedInvoice['id']?.toString() ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final option = _findPrintOptionByAction(action);
        final baseTitleAr = option?['titleAr'] as String? ?? 'فاتورة';
        final baseTitleEn = option?['titleEn'] as String? ?? 'Invoice';
        final partyName =
            (selectedInvoice['customer_name'] ??
                    selectedInvoice['supplier_name'] ??
                    (widget.isArabic ? 'غير محدد' : 'Not specified'))
                .toString();
        final totalValue = _parseDouble(selectedInvoice['total']) ?? 0.0;
        final metaAr = <String, String>{
          'الجهة': partyName,
          'الإجمالي':
              '${intl.NumberFormat('#,##0.00', 'ar').format(totalValue)} ر.س',
          'التاريخ': selectedInvoice['date']?.toString() ?? '',
        };
        final metaEn = <String, String>{
          'Party': partyName,
          'Total':
              '${intl.NumberFormat('#,##0.00', 'en').format(totalValue)} SAR',
          'Date': selectedInvoice['date']?.toString() ?? '',
        };

        final jobId = '#INV-$invoiceNumber';

        _registerPrintJob(
          action: action,
          jobId: jobId,
          titleAr: '$baseTitleAr #$invoiceNumber',
          titleEn: '$baseTitleEn #$invoiceNumber',
          etaAr: 'جارٍ إنشاء نسخة PDF',
          etaEn: 'Generating PDF copy',
          metaAr: metaAr,
          metaEn: metaEn,
          progress: 0.35,
        );

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => InvoicePrintScreen(
              invoice: selectedInvoice,
              isArabic: widget.isArabic,
              printSettings: _getPrintSettings(),
            ),
          ),
        );

        if (!mounted) return;
        _markQueueJobCompleted(jobId);
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          widget.isArabic
              ? 'تعذر تحميل الفواتير: $e'
              : 'Failed to load invoices: $e',
        );
      }
    }
  }

  Widget _buildInvoicePickerDialog(List<dynamic> invoices, String action) {
    String title = widget.isArabic
        ? 'اختر فاتورة للطباعة'
        : 'Select invoice to print';

    switch (action) {
      case 'print_sales_invoice':
        title = widget.isArabic ? 'اختر فاتورة بيع' : 'Select sales invoice';
        break;
      case 'print_purchase_invoice':
        title = widget.isArabic
            ? 'اختر فاتورة شراء'
            : 'Select purchase invoice';
        break;
      case 'print_return_invoice':
        title = widget.isArabic ? 'اختر فاتورة مرتجع' : 'Select return invoice';
        break;
      case 'print_scrap_invoice':
        title = widget.isArabic ? 'اختر فاتورة كسر' : 'Select scrap invoice';
        break;
    }

    return Dialog(
      child: SizedBox(
        width: 580,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long, color: Color(0xFFD4AF37)),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: invoices.length,
                itemBuilder: (context, index) {
                  final invoice = invoices[index] as Map<String, dynamic>;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(
                        0xFFD4AF37,
                      ).withValues(alpha: 0.15),
                      child: Text(
                        '#${invoice['invoice_type_id']}',
                        style: const TextStyle(
                          color: Color(0xFFD4AF37),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      '${invoice['invoice_type']} — '
                      '${invoice['customer_name'] ?? invoice['supplier_name'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${invoice['date'] ?? ''} · '
                      '${invoice['total'] ?? ''}',
                    ),
                    trailing: invoice['is_posted'] == true
                        ? Chip(
                            label: Text(
                              widget.isArabic ? 'مُرحّل' : 'Posted',
                              style: const TextStyle(fontSize: 12),
                            ),
                            side: BorderSide.none,
                            color: WidgetStatePropertyAll(
                              Colors.green.withValues(alpha: 0.15),
                            ),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, invoice),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVoucherPickerAndPrint(String action) async {
    final auth = context.read<AuthProvider>();
    if (!auth.hasPermission('vouchers.view')) {
      _showSnack(
        widget.isArabic
            ? 'ليس لديك صلاحية لعرض السندات'
            : 'You do not have permission to view vouchers',
      );
      return;
    }

    try {
      final response = await _apiService.getVouchers(page: 1, perPage: 50);
      if (!mounted) return;
      final vouchers = response['vouchers'] as List<dynamic>? ?? [];

      if (vouchers.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد سندات متاحة'
              : 'No vouchers available to print',
        );
        return;
      }

      // تصفية حسب النوع
      final filteredVouchers = action == 'print_receipt_voucher'
          ? vouchers.where((v) => v['voucher_type'] == 'receipt').toList()
          : vouchers.where((v) => v['voucher_type'] == 'payment').toList();

      if (filteredVouchers.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد سندات من هذا النوع'
              : 'No vouchers of this type available',
        );
        return;
      }

      final selectedVoucher = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildVoucherPickerDialog(
          filteredVouchers,
          action == 'print_receipt_voucher',
        ),
      );

      if (selectedVoucher != null && mounted) {
        final isReceipt = action == 'print_receipt_voucher';
        final option = _findPrintOptionByAction(action);
        final baseTitleAr =
            option?['titleAr'] as String? ??
            (isReceipt ? 'سند قبض' : 'سند صرف');
        final baseTitleEn =
            option?['titleEn'] as String? ??
            (isReceipt ? 'Receipt voucher' : 'Payment voucher');
        final voucherId =
            selectedVoucher['id']?.toString() ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final jobId = '#VCH-$voucherId';

        final accountName =
            (selectedVoucher['account_name'] ??
                    selectedVoucher['description'] ??
                    (widget.isArabic ? 'غير محدد' : 'Not specified'))
                .toString();
        final cashAmount = _parseDouble(selectedVoucher['amount_cash']) ?? 0.0;
        final goldAmount = _parseDouble(selectedVoucher['amount_gold']) ?? 0.0;

        final metaAr = <String, String>{
          'الحساب': accountName,
          'التاريخ': selectedVoucher['date']?.toString() ?? '',
        };
        final metaEn = <String, String>{
          'Account': accountName,
          'Date': selectedVoucher['date']?.toString() ?? '',
        };
        if (cashAmount != 0) {
          metaAr['المبلغ النقدي'] =
              '${intl.NumberFormat('#,##0.00', 'ar').format(cashAmount)} ر.س';
          metaEn['Cash amount'] =
              '${intl.NumberFormat('#,##0.00', 'en').format(cashAmount)} SAR';
        }
        if (goldAmount != 0) {
          metaAr['وزن الذهب'] =
              '${intl.NumberFormat('#,##0.000', 'ar').format(goldAmount)} جم';
          metaEn['Gold weight'] =
              '${intl.NumberFormat('#,##0.000', 'en').format(goldAmount)} g';
        }

        _registerPrintJob(
          action: action,
          jobId: jobId,
          titleAr: '$baseTitleAr #$voucherId',
          titleEn: '$baseTitleEn #$voucherId',
          etaAr: isReceipt ? 'جارٍ تجهيز سند القبض' : 'جارٍ تجهيز سند الصرف',
          etaEn: isReceipt
              ? 'Preparing receipt voucher'
              : 'Preparing payment voucher',
          metaAr: metaAr,
          metaEn: metaEn,
          progress: 0.3,
        );

        final printSettings = {
          'showLogo': true,
          'showAddress': true,
          'paperSize': _paperSize,
          'printInColor': true,
        };

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VoucherPrintScreen(
              voucher: selectedVoucher,
              isArabic: widget.isArabic,
              printSettings: printSettings,
            ),
          ),
        );

        if (!mounted) return;
        _markQueueJobCompleted(jobId);
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          widget.isArabic
              ? 'تعذر تحميل السندات: $e'
              : 'Failed to load vouchers: $e',
        );
      }
    }
  }

  Widget _buildVoucherPickerDialog(List<dynamic> vouchers, bool isReceipt) {
    return Dialog(
      child: SizedBox(
        width: 580,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    isReceipt ? Icons.arrow_downward : Icons.arrow_upward,
                    color: const Color(0xFFD4AF37),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    widget.isArabic
                        ? (isReceipt ? 'اختر سند قبض' : 'اختر سند صرف')
                        : (isReceipt
                              ? 'Select receipt voucher'
                              : 'Select payment voucher'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: vouchers.length,
                itemBuilder: (context, index) {
                  final voucher = vouchers[index] as Map<String, dynamic>;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          (isReceipt ? Colors.green : Colors.orange)
                              .withValues(alpha: 0.15),
                      child: Icon(
                        isReceipt ? Icons.arrow_downward : Icons.arrow_upward,
                        color: isReceipt ? Colors.green : Colors.orange,
                      ),
                    ),
                    title: Text(
                      '${widget.isArabic ? 'سند' : 'Voucher'} #${voucher['id']} — '
                      '${voucher['account_name'] ?? voucher['description'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${voucher['date'] ?? ''} · '
                      '${voucher['amount_cash'] ?? '0'} ${widget.isArabic ? 'ريال' : 'SAR'}',
                    ),
                    trailing: voucher['is_posted'] == true
                        ? Chip(
                            label: Text(
                              widget.isArabic ? 'مُرحّل' : 'Posted',
                              style: const TextStyle(fontSize: 12),
                            ),
                            side: BorderSide.none,
                            color: WidgetStatePropertyAll(
                              Colors.green.withValues(alpha: 0.15),
                            ),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, voucher),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showJournalEntryPickerAndPrint() async {
    try {
      final entries = await _apiService.getJournalEntries();
      if (!mounted) return;

      if (entries.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد قيود يومية متاحة'
              : 'No journal entries available to print',
        );
        return;
      }

      final selectedEntry = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildJournalEntryPickerDialog(entries),
      );

      if (selectedEntry != null && mounted) {
        final entryId =
            selectedEntry['id']?.toString() ??
            DateTime.now().millisecondsSinceEpoch.toString();
        final entryType =
            selectedEntry['entry_type']?.toString() ??
            (widget.isArabic ? 'قيد عام' : 'General entry');
        final titles = _resolveActionTitles(
          'print_journal_entry',
          fallbackAr: 'قيد يومية',
          fallbackEn: 'Journal entry',
        );
        final jobId = '#JRN-$entryId';
        final metaAr = <String, String>{
          'الوصف': selectedEntry['description']?.toString() ?? '—',
          'النوع': entryType,
          'التاريخ': selectedEntry['date']?.toString() ?? '',
        };
        final metaEn = <String, String>{
          'Description': selectedEntry['description']?.toString() ?? '—',
          'Type': entryType,
          'Date': selectedEntry['date']?.toString() ?? '',
        };

        _registerPrintJob(
          action: 'print_journal_entry',
          jobId: jobId,
          titleAr: '${titles['ar']} #$entryId',
          titleEn: '${titles['en']} #$entryId',
          etaAr: 'جارٍ تجهيز القيد للمراجعة',
          etaEn: 'Preparing journal entry preview',
          metaAr: metaAr,
          metaEn: metaEn,
          progress: 0.32,
        );

        final printSettings = {'showLogo': true, 'paperSize': _paperSize};

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JournalEntryPrintScreen(
              journalEntry: selectedEntry,
              isArabic: widget.isArabic,
              printSettings: printSettings,
            ),
          ),
        );

        if (!mounted) return;
        _markQueueJobCompleted(jobId);
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          widget.isArabic
              ? 'تعذر تحميل القيود: $e'
              : 'Failed to load journal entries: $e',
        );
      }
    }
  }

  Widget _buildJournalEntryPickerDialog(List<dynamic> entries) {
    return Dialog(
      child: SizedBox(
        width: 580,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.swap_horiz, color: Color(0xFFD4AF37)),
                  const SizedBox(width: 12),
                  Text(
                    widget.isArabic ? 'اختر قيد يومية' : 'Select journal entry',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index] as Map<String, dynamic>;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.teal.withValues(alpha: 0.15),
                      child: const Icon(Icons.swap_horiz, color: Colors.teal),
                    ),
                    title: Text(
                      '${widget.isArabic ? 'قيد' : 'Entry'} #${entry['id']} — '
                      '${entry['description'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${entry['date'] ?? ''} · '
                      '${entry['entry_type'] ?? ''}',
                    ),
                    trailing: entry['is_posted'] == true
                        ? Chip(
                            label: Text(
                              widget.isArabic ? 'مُرحّل' : 'Posted',
                              style: const TextStyle(fontSize: 12),
                            ),
                            side: BorderSide.none,
                            color: WidgetStatePropertyAll(
                              Colors.green.withValues(alpha: 0.15),
                            ),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, entry),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBarcodeItemPicker(String action) async {
    try {
      final items = await _apiService.getItems();
      if (!mounted) return;
      if (items.isEmpty) {
        _showSnack(
          widget.isArabic
              ? 'لا توجد أصناف للطباعة'
              : 'No items available for printing',
        );
        return;
      }

      final selectedItem = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildItemPickerDialog(items),
      );

      if (selectedItem != null && mounted) {
        final barcode =
            selectedItem['barcode']?.toString() ??
            selectedItem['item_code']?.toString() ??
            (selectedItem['id']?.toString() ?? 'BAR-0001');
        final itemId = selectedItem['id']?.toString() ?? barcode;
        final karat = selectedItem['karat']?.toString() ?? '21K';
        final price = _parseDouble(selectedItem['price']);
        final titles = _resolveActionTitles(
          action,
          fallbackAr: 'باركود صنف واحد',
          fallbackEn: 'Single barcode',
        );

        final metaAr = <String, String>{
          'الصنف': selectedItem['name']?.toString() ?? karat,
          'العيار': karat,
          'الرمز': barcode,
        };
        final metaEn = <String, String>{
          'Item': selectedItem['name']?.toString() ?? karat,
          'Karat': karat,
          'Code': barcode,
        };
        if (price != null) {
          metaAr['السعر'] =
              '${intl.NumberFormat('#,##0.00', 'ar').format(price)} ر.س';
          metaEn['Price'] =
              '${intl.NumberFormat('#,##0.00', 'en').format(price)} SAR';
        }

        final jobId = '#BAR-$itemId';
        _registerPrintJob(
          action: action,
          jobId: jobId,
          titleAr: '${titles['ar']} ($karat)',
          titleEn: '${titles['en']} ($karat)',
          etaAr: 'جارٍ تجهيز تسمية الباركود',
          etaEn: 'Preparing barcode label',
          metaAr: metaAr,
          metaEn: metaEn,
          progress: 0.3,
        );

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BarcodePrintScreen(
              barcode: barcode,
              itemName: selectedItem['name']?.toString() ?? '',
              itemCode: selectedItem['item_code']?.toString() ?? '',
              price: price ?? 0,
              karat: karat,
            ),
          ),
        );

        if (!mounted) return;
        _markQueueJobCompleted(jobId);
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          widget.isArabic
              ? 'خطأ في تحميل الأصناف: $e'
              : 'Failed to load items: $e',
        );
      }
    }
  }

  Widget _buildItemPickerDialog(List<dynamic> items) {
    return AlertDialog(
      title: Text(widget.isArabic ? 'اختر الصنف' : 'Select an item'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index] as Map<String, dynamic>;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.blue.withValues(alpha: 0.1),
                child: Text(item['karat']?.toString() ?? '21K'),
              ),
              title: Text(item['name']?.toString() ?? ''),
              subtitle: Text(
                '${widget.isArabic ? 'الكود' : 'Code'}: '
                "${item['item_code'] ?? item['id']}",
              ),
              trailing: const Icon(Icons.qr_code),
              onTap: () => Navigator.pop(context, item),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
        ),
      ],
    );
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Map<String, dynamic> _getPrintSettings() {
    return {
      'showLogo': _showLogo,
      'showAddress': _showAddress,
      'showPrices': _showPrices,
      'showTaxInfo': _showTaxInfo,
      'showNotes': _showNotes,
      'paperSize': _paperSize,
      'orientation': _orientation,
      'copies': _copies,
      'printInColor': _printInColor,
      'autoOpenPrintDialog': _autoOpenPrintDialog,
    };
  }

  void _showPrintSettings() {
    showDialog(
      context: context,
      builder: (context) {
        bool showLogo = _showLogo;
        bool showAddress = _showAddress;
        bool showPrices = _showPrices;
        bool showTaxInfo = _showTaxInfo;
        bool showNotes = _showNotes;
        String paperSize = _paperSize;
        String orientation = _orientation;
        int copies = _copies;
        bool printInColor = _printInColor;
        bool autoOpenPrintDialog = _autoOpenPrintDialog;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.print, color: Color(0xFFD4AF37)),
                  const SizedBox(width: 12),
                  Text(widget.isArabic ? 'إعدادات الطباعة' : 'Print settings'),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPrintSwitch(
                      title: widget.isArabic ? 'عرض الشعار' : 'Show logo',
                      subtitle: widget.isArabic
                          ? 'إظهار شعار الشركة في رأس الصفحة'
                          : 'Display your brand logo in the header',
                      value: showLogo,
                      onChanged: (value) =>
                          setDialogState(() => showLogo = value),
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic
                          ? 'بيانات العنوان'
                          : 'Address block',
                      subtitle: widget.isArabic
                          ? 'إظهار عنوان المتجر ووسائل التواصل'
                          : 'Show store address and contact info',
                      value: showAddress,
                      onChanged: (value) =>
                          setDialogState(() => showAddress = value),
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic ? 'عرض الأسعار' : 'Show prices',
                      subtitle: widget.isArabic
                          ? 'عرض الأسعار والإجماليات'
                          : 'Display line prices and totals',
                      value: showPrices,
                      onChanged: (value) =>
                          setDialogState(() => showPrices = value),
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic
                          ? 'البيانات الضريبية'
                          : 'Tax details',
                      subtitle: widget.isArabic
                          ? 'رقم التسجيل والضريبة'
                          : 'VAT number and tax summary',
                      value: showTaxInfo,
                      onChanged: (value) =>
                          setDialogState(() => showTaxInfo = value),
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic ? 'الملاحظات' : 'Notes section',
                      subtitle: widget.isArabic
                          ? 'عرض شروط وملاحظات إضافية'
                          : 'Show optional notes/terms block',
                      value: showNotes,
                      onChanged: (value) =>
                          setDialogState(() => showNotes = value),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: paperSize,
                      decoration: InputDecoration(
                        labelText: widget.isArabic ? 'حجم الورق' : 'Paper size',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'A4', child: Text('A4')),
                        DropdownMenuItem(value: 'A5', child: Text('A5')),
                        DropdownMenuItem(
                          value: 'Letter',
                          child: Text('Letter'),
                        ),
                        DropdownMenuItem(
                          value: 'Thermal',
                          child: Text('Thermal 80mm'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => paperSize = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: orientation,
                      decoration: InputDecoration(
                        labelText: widget.isArabic
                            ? 'اتجاه الصفحة'
                            : 'Orientation',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'portrait',
                          child: Text(widget.isArabic ? 'عمودي' : 'Portrait'),
                        ),
                        DropdownMenuItem(
                          value: 'landscape',
                          child: Text(widget.isArabic ? 'أفقي' : 'Landscape'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => orientation = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(widget.isArabic ? 'عدد النسخ' : 'Copies'),
                        const Spacer(),
                        IconButton(
                          onPressed: copies > 1
                              ? () => setDialogState(() => copies--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text('$copies'),
                        IconButton(
                          onPressed: () => setDialogState(() => copies++),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic ? 'طباعة ملونة' : 'Color mode',
                      subtitle: widget.isArabic
                          ? 'استخدم الألوان الكاملة في المستند'
                          : 'Use full-color output',
                      value: printInColor,
                      onChanged: (value) =>
                          setDialogState(() => printInColor = value),
                    ),
                    _buildPrintSwitch(
                      title: widget.isArabic
                          ? 'فتح نافذة الطباعة مباشرة'
                          : 'Auto open print dialog',
                      subtitle: widget.isArabic
                          ? 'تشغيل نافذة الطباعة بمجرد التحميل'
                          : 'Show system print dialog immediately',
                      value: autoOpenPrintDialog,
                      onChanged: (value) =>
                          setDialogState(() => autoOpenPrintDialog = value),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      showLogo = true;
                      showAddress = true;
                      showPrices = true;
                      showTaxInfo = true;
                      showNotes = true;
                      paperSize = 'A4';
                      orientation = 'portrait';
                      copies = 1;
                      printInColor = true;
                      autoOpenPrintDialog = true;
                    });
                  },
                  child: Text(widget.isArabic ? 'إعادة ضبط' : 'Reset'),
                ),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _showLogo = showLogo;
                      _showAddress = showAddress;
                      _showPrices = showPrices;
                      _showTaxInfo = showTaxInfo;
                      _showNotes = showNotes;
                      _paperSize = paperSize;
                      _orientation = orientation;
                      _copies = copies;
                      _printInColor = printInColor;
                      _autoOpenPrintDialog = autoOpenPrintDialog;
                    });
                    Navigator.pop(context);
                    _showSnack(
                      widget.isArabic
                          ? 'تم حفظ إعدادات الطباعة'
                          : 'Print settings saved',
                    );
                  },
                  child: Text(widget.isArabic ? 'حفظ' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPrintSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case 'invoices':
        return Icons.receipt_long;
      case 'vouchers':
        return Icons.swap_vert_circle_outlined;
      case 'reports':
        return Icons.assessment;
      case 'barcodes':
        return Icons.qr_code;
      case 'statements':
        return Icons.account_balance_wallet;
      default:
        return Icons.print;
    }
  }

  String _getCategoryLabel(String category, bool isArabic) {
    switch (category) {
      case 'invoices':
        return isArabic ? 'الفواتير' : 'Invoices';
      case 'vouchers':
        return isArabic ? 'السندات / القيود' : 'Vouchers & entries';
      case 'reports':
        return isArabic ? 'التقارير' : 'Reports';
      case 'barcodes':
        return isArabic ? 'الباركود' : 'Barcodes';
      case 'statements':
        return isArabic ? 'الكشوف' : 'Statements';
      default:
        return isArabic ? 'أخرى' : 'Others';
    }
  }

  List<Map<String, dynamic>> _getPrintingOptions(bool isArabic) {
    return [
      {
        'category': 'invoices',
        'icon': Icons.receipt_long,
        'color': Colors.green,
        'titleAr': 'فاتورة بيع',
        'titleEn': 'Sales Invoice',
        'descriptionAr': 'طباعة فاتورة بيع مع تفاصيل الأصناف والأوزان',
        'descriptionEn': 'Print sales invoice with item details and weights',
        'action': 'print_sales_invoice',
        'available': true,
      },
      {
        'category': 'invoices',
        'icon': Icons.shopping_cart,
        'color': Colors.orange,
        'titleAr': 'فاتورة شراء',
        'titleEn': 'Purchase Invoice',
        'descriptionAr': 'طباعة فاتورة شراء أو عميل',
        'descriptionEn': 'Print purchase invoice from supplier or customer',
        'action': 'print_purchase_invoice',
        'available': true,
      },
      {
        'category': 'invoices',
        'icon': Icons.assignment_return,
        'color': Colors.red,
        'titleAr': 'فاتورة مرتجع',
        'titleEn': 'Return Invoice',
        'descriptionAr': 'طباعة فاتورة مرتجع (بيع أو شراء)',
        'descriptionEn': 'Print return invoice (sales or purchase)',
        'action': 'print_return_invoice',
        'available': true,
      },
      {
        'category': 'invoices',
        'icon': Icons.recycling,
        'color': Colors.amber,
        'titleAr': 'فاتورة كسر',
        'titleEn': 'Scrap Invoice',
        'descriptionAr': 'طباعة فاتورة بيع أو شراء كسر ذهب',
        'descriptionEn': 'Print gold scrap buy/sell invoice',
        'action': 'print_scrap_invoice',
        'available': true,
      },
      {
        'category': 'vouchers',
        'icon': Icons.arrow_downward,
        'color': Colors.blue,
        'titleAr': 'سند قبض',
        'titleEn': 'Receipt Voucher',
        'descriptionAr': 'طباعة سند قبض نقدي أو ذهبي',
        'descriptionEn': 'Print cash or gold receipt voucher',
        'action': 'print_receipt_voucher',
        'available': true,
      },
      {
        'category': 'vouchers',
        'icon': Icons.arrow_upward,
        'color': Colors.purple,
        'titleAr': 'سند صرف',
        'titleEn': 'Payment Voucher',
        'descriptionAr': 'طباعة سند صرف نقدي أو ذهبي',
        'descriptionEn': 'Print cash or gold payment voucher',
        'action': 'print_payment_voucher',
        'available': true,
      },
      {
        'category': 'vouchers',
        'icon': Icons.swap_horiz,
        'color': Colors.teal,
        'titleAr': 'قيد يومية',
        'titleEn': 'Journal Entry',
        'descriptionAr': 'طباعة قيد يومية محاسبي',
        'descriptionEn': 'Print accounting journal entry',
        'action': 'print_journal_entry',
        'available': true,
      },
      {
        'category': 'reports',
        'icon': Icons.assessment,
        'color': Colors.indigo,
        'titleAr': 'تقرير المبيعات',
        'titleEn': 'Sales Report',
        'descriptionAr': 'طباعة تقرير المبيعات حسب الفترة',
        'descriptionEn': 'Print sales report by period',
        'action': 'print_sales_report',
        'available': true,
      },
      {
        'category': 'reports',
        'icon': Icons.inventory,
        'color': Colors.brown,
        'titleAr': 'تقرير المخزون',
        'titleEn': 'Inventory Report',
        'descriptionAr': 'طباعة تقرير حالة المخزون',
        'descriptionEn': 'Print inventory status report',
        'action': 'print_inventory_report',
        'available': true,
      },
      {
        'category': 'reports',
        'icon': Icons.balance,
        'color': Colors.deepPurple,
        'titleAr': 'ميزان المراجعة',
        'titleEn': 'Trial Balance',
        'descriptionAr': 'طباعة ميزان المراجعة بتفاصيل العيارات',
        'descriptionEn': 'Print trial balance with karat details',
        'action': 'print_trial_balance',
        'available': true,
      },
      {
        'category': 'reports',
        'icon': Icons.menu_book,
        'color': Colors.cyan,
        'titleAr': 'دفتر الأستاذ',
        'titleEn': 'General Ledger',
        'descriptionAr': 'طباعة دفتر الأستاذ العام',
        'descriptionEn': 'Print general ledger',
        'action': 'print_general_ledger',
        'available': true,
      },
      {
        'category': 'barcodes',
        'icon': Icons.qr_code_2,
        'color': Colors.deepOrange,
        'titleAr': 'باركود صنف واحد',
        'titleEn': 'Single Item Barcode',
        'descriptionAr': 'طباعة ملصق باركود لصنف واحد',
        'descriptionEn': 'Print barcode label for single item',
        'action': 'print_single_barcode',
        'available': true,
      },
      {
        'category': 'barcodes',
        'icon': Icons.view_module,
        'color': Colors.lime,
        'titleAr': 'باركود متعدد',
        'titleEn': 'Bulk Barcodes',
        'descriptionAr': 'طباعة ملصقات باركود لعدة أصناف',
        'descriptionEn': 'Print barcode labels for multiple items',
        'action': 'print_bulk_barcodes',
        'available': false,
      },
      {
        'category': 'statements',
        'icon': Icons.account_tree,
        'color': Colors.pink,
        'titleAr': 'كشف حساب',
        'titleEn': 'Account Statement',
        'descriptionAr': 'طباعة كشف حساب تفصيلي',
        'descriptionEn': 'Print detailed account statement',
        'action': 'print_account_statement',
        'available': true,
      },
      {
        'category': 'statements',
        'icon': Icons.people,
        'color': Colors.lightGreen,
        'titleAr': 'كشف حساب عميل',
        'titleEn': 'Customer Statement',
        'descriptionAr': 'طباعة كشف حساب عميل بالذهب والنقد',
        'descriptionEn': 'Print customer statement with gold and cash',
        'action': 'print_customer_statement',
        'available': true,
      },
      {
        'category': 'statements',
        'icon': Icons.local_shipping,
        'color': Colors.blueGrey,
        'titleAr': 'كشف حساب مورد',
        'titleEn': 'Supplier Statement',
        'descriptionAr': 'طباعة كشف حساب مورد بالتفاصيل',
        'descriptionEn': 'Print supplier statement with full breakdown',
        'action': 'print_supplier_statement',
        'available': false,
      },
    ];
  }
}

/* Legacy printing center implementation kept for reference

  Widget _buildPrintOptionCard(
    BuildContext context,
    Map<String, dynamic> option,
    bool isArabic, {
    bool isFavorite = false,
  }) {
    final isAvailable = option['available'] as bool? ?? false;
    final action = option['action'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: isAvailable && action != null
            ? () => _handlePrintAction(action)
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (option['color'] as Color).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  option['icon'] as IconData,
                  color: option['color'] as Color,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),

              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            option['title'] as String,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (action != null)
                          IconButton(
                            icon: Icon(
                              isFavorite
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              color: isFavorite
                                  ? const Color(0xFFD4AF37)
                                  : Colors.grey,
                              size: 20,
                            ),
                            onPressed: () => _toggleFavorite(action, option),
                            tooltip: isFavorite
                                ? (isArabic ? 'إزالة من المفضلة' : 'Remove favorite')
                                : (isArabic
                                    ? 'إضافة للمفضلة'
                                    : 'Add to favorites'),
                          ),
                        if (!isAvailable)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isArabic ? 'قريباً' : 'Coming Soon',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade700,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      option['description'] as String,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),

              // Arrow
              if (isAvailable)
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: Colors.grey.shade400,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, bool isArabic) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: isArabic ? 'ابحث عن نوع طباعة...' : 'Search print type...',
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          fillColor: Colors.grey.shade50,
        ),
      ),
    );
  }

  Widget _buildCategoryFilters(BuildContext context, bool isArabic) {
    final categories = [
      {'id': 'all', 'nameAr': 'الكل', 'nameEn': 'All', 'icon': Icons.apps},
      {'id': 'invoices', 'nameAr': 'الفواتير', 'nameEn': 'Invoices', 'icon': Icons.receipt},
      {'id': 'vouchers', 'nameAr': 'السندات', 'nameEn': 'Vouchers', 'icon': Icons.description},
      {'id': 'reports', 'nameAr': 'التقارير', 'nameEn': 'Reports', 'icon': Icons.assessment},
      {'id': 'barcodes', 'nameAr': 'الباركود', 'nameEn': 'Barcodes', 'icon': Icons.qr_code},
      {'id': 'statements', 'nameAr': 'الكشوف', 'nameEn': 'Statements', 'icon': Icons.account_balance_wallet},
    ];

    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = categories[index];
          final categoryId = category['id'] as String;
          final isSelected = _selectedCategory == null
              ? categoryId == 'all'
              : _selectedCategory == categoryId;

          return FilterChip(
            selected: isSelected,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  category['icon'] as IconData,
                  size: 16,
                  color: isSelected ? Colors.white : Colors.grey.shade700,
                ),
                const SizedBox(width: 6),
                Text(
                  isArabic ? category['nameAr'] as String : category['nameEn'] as String,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ],
            ),
            onSelected: (selected) {
              setState(() {
                _selectedCategory = categoryId == 'all' ? null : categoryId;
              });
            },
            selectedColor: Colors.blue.shade700,
            backgroundColor: Colors.grey.shade100,
            showCheckmark: false,
          );
        },
      ),
    );
  }

  Widget _buildPrintingOptions(BuildContext context, bool isArabic) {
    final allOptions = _getPrintingOptions(isArabic);
    
    // Filter by category
    var filtered = allOptions;
    if (_selectedCategory != null) {
      filtered = allOptions.where((opt) => opt['category'] == _selectedCategory).toList();
    }

    // Filter by search
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((opt) {
        final title = (opt['title'] as String).toLowerCase();
        final description = (opt['description'] as String).toLowerCase();
        return title.contains(query) || description.contains(query);
      }).toList();
    }

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.print_disabled, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              isArabic ? 'لا توجد خيارات طباعة مطابقة' : 'No matching print options',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final option = filtered[index];
        final isFavorite = _favoriteActions.contains(option['action']);
        return _buildPrintOptionCard(
          context,
          option,
          isArabic,
          isFavorite: isFavorite,
        );
      },
    );
  }


  void _handlePrintAction(String action) async {
    switch (action) {
      // ===== الفواتير =====
      case 'print_sales_invoice':
      case 'print_purchase_invoice':
      case 'print_return_invoice':
      case 'print_scrap_invoice':
        await _showInvoicePickerAndPrint(action);
        break;

      // ===== السندات =====
      case 'print_receipt_voucher':
      case 'print_payment_voucher':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VouchersListScreen(),
          ),
        );
        break;

      case 'print_journal_entry':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JournalEntriesListScreen(),
          ),
        );
        break;

      // ===== التقارير =====
      case 'print_sales_report':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SalesOverviewReportScreen(
              api: widget.api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;

      case 'print_inventory_report':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => InventoryStatusReportScreen(
              api: widget.api,
              isArabic: widget.isArabic,
            ),
          ),
        );
        break;

      case 'print_trial_balance':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const TrialBalanceScreenV2(),
          ),
        );
        break;

      case 'print_general_ledger':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const GeneralLedgerScreenV2(),
          ),
        );
        break;

      // ===== الباركود =====
      case 'print_single_barcode':
        await _showBarcodeItemPicker();
        break;

      case 'print_bulk_barcodes':
        _showComingSoonMessage('طباعة الباركود المتعدد');
        break;

      // ===== الكشوف =====
      case 'print_account_statement':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const AccountsScreen(),
          ),
        );
        break;

      case 'print_customer_statement':
      case 'print_supplier_statement':
        _showComingSoonMessage(
          action == 'print_customer_statement'
              ? 'كشف حساب العميل'
              : 'كشف حساب المورد',
        );
        break;

      default:
        _showComingSoonMessage('هذه الميزة');
        break;
    }
  }

  void _showComingSoonMessage(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.isArabic
              ? 'قريباً: $feature'
              : 'Coming soon: $feature',
        ),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showInvoicePickerAndPrint(String action) async {
    try {
      // جلب الفواتير من API
      final response = await widget.api.getInvoices(page: 1, perPage: 50);
      final invoices = response['invoices'] as List;
      
      if (!mounted) return;

      if (invoices.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'لا توجد فواتير متاحة'
                  : 'No invoices available',
            ),
          ),
        );
        return;
      }

      // عرض قائمة اختيار الفاتورة
      final selectedInvoice = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildInvoicePickerDialog(invoices),
      );

      if (selectedInvoice != null && mounted) {
        // الانتقال لشاشة الطباعة
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => InvoicePrintScreen(
              invoice: selectedInvoice,
              isArabic: widget.isArabic,
              printSettings: _getPrintSettings(),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'خطأ في جلب الفواتير: $e'
                  : 'Error loading invoices: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildInvoicePickerDialog(List invoices) {
    return Dialog(
      child: Container(
        width: 600,
        height: 500,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // العنوان
            Row(
              children: [
                const Icon(Icons.receipt_long, color: Color(0xFFD4AF37)),
                const SizedBox(width: 12),
                Text(
                  widget.isArabic ? 'اختر فاتورة للطباعة' : 'Select Invoice to Print',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            
            // قائمة الفواتير
            Expanded(
              child: ListView.builder(
                itemCount: invoices.length,
                itemBuilder: (context, index) {
                  final invoice = invoices[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFD4AF37)
                            .withValues(alpha: 0.2),
                        child: Text(
                          '#${invoice['invoice_type_id']}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFD4AF37),
                          ),
                        ),
                      ),
                      title: Text(
                        '${invoice['invoice_type']} - ${invoice['customer_name'] ?? invoice['supplier_name'] ?? 'N/A'}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        '${invoice['date']} | ${invoice['total']} ريال',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: invoice['is_posted'] == true
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.shade100,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                widget.isArabic ? 'مرحّل' : 'Posted',
                                style: TextStyle(
                                  color: Colors.green.shade700,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            )
                          : null,
                      onTap: () => Navigator.pop(context, invoice),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBarcodeItemPicker() async {
    // Load items from API
    try {
      final items = await widget.api.getItems();
      
      if (!mounted) return;

      if (items.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'لا توجد أصناف متاحة'
                  : 'No items available',
            ),
          ),
        );
        return;
      }

      // Show item picker dialog
      final selectedItem = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => _buildItemPickerDialog(items),
      );

      if (selectedItem != null && mounted) {
        // Navigate to barcode print screen
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BarcodePrintScreen(
              barcode: selectedItem['barcode']?.toString() ?? 
                      selectedItem['item_code']?.toString() ?? 
                      selectedItem['id'].toString(),
              itemName: selectedItem['name']?.toString() ?? '',
              itemCode: selectedItem['item_code']?.toString() ?? '',
              price: _parseDouble(selectedItem['price']),
              karat: selectedItem['karat']?.toString(),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'خطأ في تحميل الأصناف: $e'
                  : 'Error loading items: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildItemPickerDialog(List items) {
    return AlertDialog(
      title: Text(widget.isArabic ? 'اختر الصنف' : 'Select Item'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.blue.shade100,
                child: Text(
                  item['karat']?.toString() ?? '?',
                  style: TextStyle(
                    color: Colors.blue.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              title: Text(item['name']?.toString() ?? ''),
              subtitle: Text(
                'الكود: ${item['item_code']?.toString() ?? item['id'].toString()}',
              ),
              trailing: const Icon(Icons.qr_code),
              onTap: () => Navigator.pop(context, item),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
        ),
      ],
    );
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  /// Get current print settings as a map (for future use in print screens)
  /// This can be passed to individual print screens to apply user preferences
  Map<String, dynamic> _getPrintSettings() {
    return {
      'showLogo': _showLogo,
      'showAddress': _showAddress,
      'showPrices': _showPrices,
      'showTaxInfo': _showTaxInfo,
      'showNotes': _showNotes,
      'paperSize': _paperSize,
      'orientation': _orientation,
      'copies': _copies,
      'printInColor': _printInColor,
      'autoOpenPrintDialog': _autoOpenPrintDialog,
    };
  }

  void _showPrintSettings() {
    showDialog(
      context: context,
      builder: (context) {
        // Local state for dialog
        bool showLogo = _showLogo;
        bool showAddress = _showAddress;
        bool showPrices = _showPrices;
        bool showTaxInfo = _showTaxInfo;
        bool showNotes = _showNotes;
        String paperSize = _paperSize;
        String orientation = _orientation;
        int copies = _copies;
        bool printInColor = _printInColor;
        bool autoOpenPrintDialog = _autoOpenPrintDialog;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(
                    Icons.print_rounded,
                    color: Color(0xFFD4AF37),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.isArabic ? 'إعدادات الطباعة' : 'Print Settings',
                    style: const TextStyle(fontSize: 20),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 400,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Section: محتوى الطباعة
                      Text(
                        widget.isArabic ? 'محتوى الطباعة' : 'Print Content',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFD4AF37),
                        ),
                      ),
                      const Divider(),
                      SwitchListTile(
                        title: Text(widget.isArabic ? 'عرض الشعار' : 'Show Logo'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إظهار شعار الشركة في المستند'
                              : 'Display company logo on document',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: showLogo,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => showLogo = val);
                        },
                      ),
                      SwitchListTile(
                        title: Text(widget.isArabic ? 'عرض العنوان' : 'Show Address'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إظهار عنوان الشركة ومعلومات الاتصال'
                              : 'Display company address and contact info',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: showAddress,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => showAddress = val);
                        },
                      ),
                      SwitchListTile(
                        title: Text(widget.isArabic ? 'عرض الأسعار' : 'Show Prices'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إظهار الأسعار والإجماليات'
                              : 'Display prices and totals',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: showPrices,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => showPrices = val);
                        },
                      ),
                      SwitchListTile(
                        title: Text(widget.isArabic ? 'معلومات الضريبة' : 'Tax Info'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إظهار الضرائب والرقم الضريبي'
                              : 'Display tax details and VAT number',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: showTaxInfo,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => showTaxInfo = val);
                        },
                      ),
                      SwitchListTile(
                        title: Text(widget.isArabic ? 'عرض الملاحظات' : 'Show Notes'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إظهار الملاحظات والشروط'
                              : 'Display notes and terms',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: showNotes,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => showNotes = val);
                        },
                      ),

                      const SizedBox(height: 16),

                      // Section: إعدادات الورق
                      Text(
                        widget.isArabic ? 'إعدادات الورق' : 'Paper Settings',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFD4AF37),
                        ),
                      ),
                      const Divider(),
                      
                      ListTile(
                        title: Text(widget.isArabic ? 'حجم الورق' : 'Paper Size'),
                        subtitle: DropdownButton<String>(
                          value: paperSize,
                          isExpanded: true,
                          items: [
                            DropdownMenuItem(
                              value: 'A4',
                              child: Text('A4 (210×297mm)'),
                            ),
                            DropdownMenuItem(
                              value: 'A5',
                              child: Text('A5 (148×210mm)'),
                            ),
                            DropdownMenuItem(
                              value: 'Thermal',
                              child: Text(
                                widget.isArabic ? 'حراري (80mm)' : 'Thermal (80mm)',
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'Letter',
                              child: Text('Letter (8.5×11 in)'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() => paperSize = val);
                            }
                          },
                        ),
                      ),

                      ListTile(
                        title: Text(widget.isArabic ? 'اتجاه الصفحة' : 'Orientation'),
                        subtitle: DropdownButton<String>(
                          value: orientation,
                          isExpanded: true,
                          items: [
                            DropdownMenuItem(
                              value: 'portrait',
                              child: Text(widget.isArabic ? 'عمودي' : 'Portrait'),
                            ),
                            DropdownMenuItem(
                              value: 'landscape',
                              child: Text(widget.isArabic ? 'أفقي' : 'Landscape'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() => orientation = val);
                            }
                          },
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Section: خيارات الطباعة
                      Text(
                        widget.isArabic ? 'خيارات الطباعة' : 'Print Options',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFD4AF37),
                        ),
                      ),
                      const Divider(),

                      ListTile(
                        title: Text(widget.isArabic ? 'عدد النسخ' : 'Number of Copies'),
                        subtitle: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: copies > 1
                                  ? () {
                                      setDialogState(() => copies--);
                                    }
                                  : null,
                            ),
                            Text(
                              '$copies',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: copies < 10
                                  ? () {
                                      setDialogState(() => copies++);
                                    }
                                  : null,
                            ),
                          ],
                        ),
                      ),

                      SwitchListTile(
                        title: Text(widget.isArabic ? 'طباعة ملونة' : 'Color Print'),
                        subtitle: Text(
                          widget.isArabic
                              ? 'طباعة بالألوان الكاملة'
                              : 'Print in full color',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: printInColor,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => printInColor = val);
                        },
                      ),

                      SwitchListTile(
                        title: Text(
                          widget.isArabic
                              ? 'فتح نافذة الطباعة تلقائياً'
                              : 'Auto-open Print Dialog',
                        ),
                        subtitle: Text(
                          widget.isArabic
                              ? 'فتح نافذة الطباعة مباشرة عند العرض'
                              : 'Open print dialog immediately on preview',
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: autoOpenPrintDialog,
                        activeColor: const Color(0xFFD4AF37),
                        onChanged: (val) {
                          setDialogState(() => autoOpenPrintDialog = val);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    // Reset to defaults
                    setDialogState(() {
                      showLogo = true;
                      showAddress = true;
                      showPrices = true;
                      showTaxInfo = true;
                      showNotes = true;
                      paperSize = 'A4';
                      orientation = 'portrait';
                      copies = 1;
                      printInColor = true;
                      autoOpenPrintDialog = true;
                    });
                  },
                  child: Text(widget.isArabic ? 'إعادة تعيين' : 'Reset'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4AF37),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _showLogo = showLogo;
                      _showAddress = showAddress;
                      _showPrices = showPrices;
                      _showTaxInfo = showTaxInfo;
                      _showNotes = showNotes;
                      _paperSize = paperSize;
                      _orientation = orientation;
                      _copies = copies;
                      _printInColor = printInColor;
                      _autoOpenPrintDialog = autoOpenPrintDialog;
                    });
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          widget.isArabic
                              ? '✓ تم حفظ إعدادات الطباعة'
                              : '✓ Print settings saved',
                        ),
                        backgroundColor: Colors.green,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  child: Text(widget.isArabic ? 'حفظ' : 'Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
*/
