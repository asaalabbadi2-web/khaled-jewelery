import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../api_service.dart';
// import 'add_invoice_screen.dart'; // TODO: Uncomment when implementing add invoice

class InvoicesListScreen extends StatefulWidget {
  final bool isArabic;

  const InvoicesListScreen({super.key, this.isArabic = true});

  @override
  State<InvoicesListScreen> createState() => _InvoicesListScreenState();
}

class _InvoicesListScreenState extends State<InvoicesListScreen> {
  final ApiService _apiService = ApiService();
  List<dynamic> _invoices = [];
  List<dynamic> _filteredInvoices = [];
  bool _isLoading = false;

  // Filters
  String _searchQuery = '';
  String _selectedInvoiceType = 'all';
  String _selectedStatus = 'all';
  DateTimeRange? _dateRange;
  String _sortBy = 'date';
  bool _sortAscending = false;

  // Statistics
  Map<String, dynamic> _statistics = {
    'total_invoices': 0,
    'total_amount': 0.0,
    'paid_amount': 0.0,
    'unpaid_amount': 0.0,
  };

  static const Map<String, String> _invoicePrefixLookup = {
    'بيع': 'SELL',
    'sell': 'SELL',
    'sale': 'SELL',
    'شراء من عميل': 'BUY',
    'شراء': 'BUY',
    'buy': 'BUY',
    'purchase': 'BUY',
    'مرتجع بيع': 'RETSELL',
    'sales return': 'RETSELL',
    'مرتجع شراء': 'RETBUY',
    'purchase return': 'RETBUY',
    'شراء من مورد': 'SUPP',
    'supplier purchase': 'SUPP',
    'مرتجع شراء من مورد': 'RETSUPP',
    'supplier purchase return': 'RETSUPP',
  };

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  Future<void> _loadInvoices() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final data = await _apiService.getInvoices();

      if (!mounted) return;

      // Process data
      final invoices = data is List ? data : (data['invoices'] ?? []);

      if (!mounted) return;

      setState(() {
        _invoices = invoices;
        _applyFilters();
        _calculateStatistics();
      });
    } catch (e) {
      if (mounted) {
        _showSnackBar('خطأ في تحميل الفواتير: ${e.toString()}', isError: true);
      }
      debugPrint('❌ Error loading invoices: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilters() {
    if (_invoices.isEmpty) {
      _filteredInvoices = [];
      return;
    }

    try {
      _filteredInvoices = _invoices.where((invoice) {
        // Search filter
        if (_searchQuery.isNotEmpty) {
          final searchLower = _searchQuery.toLowerCase();
          final customerName = (invoice['customer_name'] ?? '')
              .toString()
              .toLowerCase();
          final invoiceNumber =
              _getInvoiceDisplayNumber(invoice).toLowerCase();
          if (!customerName.contains(searchLower) &&
              !invoiceNumber.contains(searchLower)) {
            return false;
          }
        }

        // Invoice type filter
        if (_selectedInvoiceType != 'all') {
          final invoiceType = (invoice['invoice_type'] ?? '').toString().trim();
          if (invoiceType != _selectedInvoiceType) {
            return false;
          }
        }

        if (_selectedStatus != 'all') {
          final normalizedStatus = _normalizeStatus(
            (invoice['status'] ?? '').toString(),
          );
          if (normalizedStatus != _selectedStatus) {
            return false;
          }
        }

        // Date range filter
        if (_dateRange != null && invoice['date'] != null) {
          try {
            final invoiceDate = DateTime.parse(invoice['date'].toString());
            if (invoiceDate.isBefore(_dateRange!.start) ||
                invoiceDate.isAfter(_dateRange!.end)) {
              return false;
            }
          } catch (e) {
            debugPrint('⚠️ خطأ في تحليل التاريخ: $e');
            return true; // اترك الفاتورة إذا فشل parsing التاريخ
          }
        }

        return true;
      }).toList();

      // Apply sorting
      if (_filteredInvoices.isNotEmpty) {
        _filteredInvoices.sort((a, b) {
          int comparison = 0;
          try {
            switch (_sortBy) {
              case 'date':
                final dateA = a['date'] != null
                    ? DateTime.parse(a['date'].toString())
                    : DateTime.now();
                final dateB = b['date'] != null
                    ? DateTime.parse(b['date'].toString())
                    : DateTime.now();
                comparison = dateA.compareTo(dateB);
                break;
              case 'customer':
                comparison = (a['customer_name'] ?? '').toString().compareTo(
                  (b['customer_name'] ?? '').toString(),
                );
                break;
              case 'amount':
                final aTotal = ((a['total'] ?? 0) as num).toDouble();
                final bTotal = ((b['total'] ?? 0) as num).toDouble();
                comparison = aTotal.compareTo(bTotal);
                break;
              case 'number':
                final aPrefix = _extractInvoicePrefix(a);
                final bPrefix = _extractInvoicePrefix(b);
                comparison = aPrefix.compareTo(bPrefix);
                if (comparison == 0) {
                  final aYear = _extractInvoiceYear(a);
                  final bYear = _extractInvoiceYear(b);
                  comparison = aYear.compareTo(bYear);
                  if (comparison == 0) {
                    final aSeq = _extractInvoiceSequence(a);
                    final bSeq = _extractInvoiceSequence(b);
                    comparison = aSeq.compareTo(bSeq);
                  }
                }
                break;
            }
          } catch (e) {
            debugPrint('⚠️ خطأ في الترتيب: $e');
            comparison = 0;
          }
          return _sortAscending ? comparison : -comparison;
        });
      }
    } catch (e) {
      debugPrint('❌ خطأ في تطبيق الفلاتر: $e');
      _filteredInvoices = _invoices;
    }
  }

  void _calculateStatistics() {
    try {
      _statistics['total_invoices'] = _filteredInvoices.length;

      _statistics['total_amount'] = _filteredInvoices.fold(0.0, (sum, invoice) {
        try {
          return sum + ((invoice['total'] ?? 0) as num).toDouble();
        } catch (e) {
          debugPrint('⚠️ خطأ في حساب الإجمالي: $e');
          return sum;
        }
      });

      _statistics['paid_amount'] = _filteredInvoices
          .where((inv) {
            try {
              final normalized = _normalizeStatus(
                (inv['status'] ?? '').toString(),
              );
              return normalized == 'paid';
            } catch (e) {
              debugPrint('⚠️ خطأ في فحص الحالة: $e');
              return false;
            }
          })
          .fold(0.0, (sum, invoice) {
            try {
              return sum + ((invoice['total'] ?? 0) as num).toDouble();
            } catch (e) {
              debugPrint('⚠️ خطأ في حساب المدفوع: $e');
              return sum;
            }
          });

      _statistics['unpaid_amount'] =
          _statistics['total_amount'] - _statistics['paid_amount'];
    } catch (e) {
      debugPrint('❌ خطأ في حساب الإحصائيات: $e');
      // قيم افتراضية في حالة الخطأ
      _statistics['total_invoices'] = 0;
      _statistics['total_amount'] = 0.0;
      _statistics['paid_amount'] = 0.0;
      _statistics['unpaid_amount'] = 0.0;
    }
  }

  String _normalizeStatus(String? rawStatus) {
    if (rawStatus == null) {
      return 'unknown';
    }

    final trimmed = rawStatus.trim();
    if (trimmed.isEmpty) {
      return 'unknown';
    }

    final lower = trimmed.toLowerCase();

    if (lower == 'paid' || trimmed == 'مدفوعة') {
      return 'paid';
    }
    if (lower == 'unpaid' || trimmed == 'غير مدفوعة') {
      return 'unpaid';
    }
    if (lower == 'partially_paid' ||
        lower == 'partially paid' ||
        trimmed == 'مدفوعة جزئياً') {
      return 'partially_paid';
    }
    if (lower == 'draft' || trimmed == 'مسودة') {
      return 'draft';
    }
    if (lower == 'cancelled' || lower == 'canceled' || trimmed == 'ملغاة') {
      return 'cancelled';
    }

    return lower;
  }

  String _getInvoiceDisplayNumber(Map<String, dynamic> invoice) {
    final rawNumberValue = invoice['invoice_number'];
    if (rawNumberValue != null) {
      final trimmed = rawNumberValue.toString().trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    final fallback = _buildFallbackInvoiceNumber(invoice);
    if (fallback != null) {
      return fallback;
    }

    final legacyId = invoice['id'];
    return legacyId != null ? '#${legacyId.toString()}' : '#---';
  }

  String? _buildFallbackInvoiceNumber(Map<String, dynamic> invoice) {
    try {
      final invoiceType = (invoice['invoice_type'] ?? '').toString().trim();
      if (invoiceType.isEmpty) {
        return null;
      }

      final sequenceValue = invoice['invoice_type_id'];
      int? sequence;
      if (sequenceValue is int) {
        sequence = sequenceValue;
      } else if (sequenceValue != null) {
        sequence = int.tryParse(sequenceValue.toString());
      }
      if (sequence == null || sequence <= 0) {
        return null;
      }

      final prefix = _resolveInvoicePrefix(invoiceType);
      final rawDateValue = invoice['date'];
      final rawDate = rawDateValue != null ? rawDateValue.toString() : null;
      final parsedDate = rawDate != null ? DateTime.tryParse(rawDate) : null;
      final year = parsedDate?.year ?? DateTime.now().year;

      final digits = sequence >= 1000 ? 4 : 3;
      final sequenceStr = sequence.toString().padLeft(digits, '0');

      return '$prefix-$year-$sequenceStr';
    } catch (e) {
      debugPrint('⚠️ فشل بناء رقم فاتورة بديل: $e');
      return null;
    }
  }

  String _resolveInvoicePrefix(String invoiceType) {
    final trimmed = invoiceType.trim();
    if (trimmed.isEmpty) {
      return 'INV';
    }

    final lower = trimmed.toLowerCase();
    if (_invoicePrefixLookup.containsKey(trimmed)) {
      return _invoicePrefixLookup[trimmed]!;
    }
    if (_invoicePrefixLookup.containsKey(lower)) {
      return _invoicePrefixLookup[lower]!;
    }

    return 'INV';
  }

  String _extractInvoicePrefix(Map<String, dynamic> invoice) {
    final rawNumberValue = invoice['invoice_number'];
    final rawNumber = rawNumberValue != null ? rawNumberValue.toString() : null;
    if (rawNumber != null) {
      final parts = rawNumber.split('-');
      if (parts.length >= 1 && parts.first.trim().isNotEmpty) {
        return parts.first.trim();
      }
    }
    final invoiceType = (invoice['invoice_type'] ?? '').toString();
    return _resolveInvoicePrefix(invoiceType);
  }

  int _extractInvoiceYear(Map<String, dynamic> invoice) {
    final rawNumberValue = invoice['invoice_number'];
    final rawNumber = rawNumberValue != null ? rawNumberValue.toString() : null;
    if (rawNumber != null) {
      final parts = rawNumber.split('-');
      if (parts.length >= 2) {
        final year = int.tryParse(parts[1]);
        if (year != null) {
          return year;
        }
      }
    }

    final rawDateValue = invoice['date'];
    final rawDate = rawDateValue != null ? rawDateValue.toString() : null;
    final parsedDate = rawDate != null ? DateTime.tryParse(rawDate) : null;
    return parsedDate?.year ?? DateTime.now().year;
  }

  int _extractInvoiceSequence(Map<String, dynamic> invoice) {
    final rawNumberValue = invoice['invoice_number'];
    final rawNumber = rawNumberValue != null ? rawNumberValue.toString() : null;
    if (rawNumber != null) {
      final parts = rawNumber.split('-');
      if (parts.isNotEmpty) {
        final sequence = int.tryParse(parts.last);
        if (sequence != null) {
          return sequence;
        }
      }
    }

    final sequenceValue = invoice['invoice_type_id'];
    if (sequenceValue is int) {
      return sequenceValue;
    }

    final parsed = sequenceValue != null ? int.tryParse(sequenceValue.toString()) : null;
    if (parsed != null) {
      return parsed;
    }

    final legacyId = invoice['id'];
    if (legacyId is int) {
      return legacyId;
    }

    return int.tryParse(legacyId?.toString() ?? '') ?? 0;
  }

  String _translateStatus(String? status, bool isArabic) {
    if (status == null || status.isEmpty) {
      return isArabic ? 'غير محدد' : 'N/A';
    }

    final normalized = _normalizeStatus(status);
    switch (normalized) {
      case 'paid':
        return isArabic ? 'مدفوعة' : 'Paid';
      case 'unpaid':
        return isArabic ? 'غير مدفوعة' : 'Unpaid';
      case 'partially_paid':
        return isArabic ? 'مدفوعة جزئياً' : 'Partially Paid';
      case 'draft':
        return isArabic ? 'مسودة' : 'Draft';
      case 'cancelled':
        return isArabic ? 'ملغاة' : 'Cancelled';
      default:
        return status;
    }
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _clearFilters() {
    setState(() {
      _searchQuery = '';
      _selectedInvoiceType = 'all';
      _selectedStatus = 'all';
      _dateRange = null;
      _applyFilters();
      _calculateStatistics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final primary = colorScheme.primary;
    final scaffoldBackground = theme.scaffoldBackgroundColor;

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: scaffoldBackground,
        appBar: AppBar(
          title: Text(isAr ? 'قائمة الفواتير' : 'Invoices List'),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh, color: primary),
              onPressed: _loadInvoices,
              tooltip: isAr ? 'تحديث' : 'Refresh',
            ),
            IconButton(
              icon: Icon(Icons.filter_list_off, color: primary),
              onPressed: _clearFilters,
              tooltip: isAr ? 'إزالة الفلاتر' : 'Clear Filters',
            ),
          ],
        ),
        body: Column(
          children: [
            // Statistics Cards
            _buildStatisticsSection(),

            // Filters Section
            _buildFiltersSection(),

            // Invoices List
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(primary),
                      ),
                    )
                  : _filteredInvoices.isEmpty
                  ? _buildEmptyState()
                  : _buildInvoicesList(),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: primary,
          foregroundColor: colorScheme.onPrimary,
          onPressed: () => _navigateToAddInvoice(),
          icon: Icon(Icons.add),
          label: Text(isAr ? 'فاتورة جديدة' : 'New Invoice'),
        ),
      ),
    );
  }

  Widget _buildStatisticsSection() {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final statsBackground = colorScheme.surfaceVariant.withValues(alpha: 
      isDark ? 0.35 : 0.2,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statsBackground,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAr ? '📊 الإحصائيات' : '📊 Statistics',
            style: textTheme.titleLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Icons.receipt_long,
                  title: isAr ? 'إجمالي الفواتير' : 'Total Invoices',
                  value: _statistics['total_invoices'].toString(),
                  highlightColor: Colors.blue,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.attach_money,
                  title: isAr ? 'المبلغ الكلي' : 'Total Amount',
                  value: NumberFormat(
                    '#,##0',
                    isAr ? 'ar' : 'en',
                  ).format(_statistics['total_amount']),
                  highlightColor: colorScheme.primary,
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Icons.check_circle,
                  title: isAr ? 'المدفوع' : 'Paid',
                  value: NumberFormat(
                    '#,##0',
                    isAr ? 'ar' : 'en',
                  ).format(_statistics['paid_amount']),
                  highlightColor: Colors.green,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.pending,
                  title: isAr ? 'المتبقي' : 'Unpaid',
                  value: NumberFormat(
                    '#,##0',
                    isAr ? 'ar' : 'en',
                  ).format(_statistics['unpaid_amount']),
                  highlightColor: Colors.orange,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color highlightColor,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      elevation: theme.cardTheme.elevation ?? 2,
      color: theme.cardTheme.color ?? colorScheme.surface,
      shape:
          theme.cardTheme.shape ??
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: highlightColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: highlightColor, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: textTheme.headlineSmall?.copyWith(
                color: highlightColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFiltersSection() {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool isDark = theme.brightness == Brightness.dark;
    final filterBackground = colorScheme.surfaceVariant.withValues(alpha: 
      isDark ? 0.4 : 0.7,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: filterBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          // Search and Date Range
          Row(
            children: [
              Expanded(
                child: TextField(
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: isAr
                        ? '🔍 بحث برقم الفاتورة أو اسم العميل...'
                        : '🔍 Search by number or customer...',
                    hintStyle: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    filled: true,
                    fillColor: colorScheme.surface.withValues(alpha: 
                      isDark ? 0.35 : 0.9,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: colorScheme.outline.withValues(alpha: 0.1),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                      _applyFilters();
                      _calculateStatistics();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  Icons.date_range,
                  color: _dateRange != null
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(Duration(days: 365)),
                    initialDateRange: _dateRange,
                  );
                  if (picked != null) {
                    setState(() {
                      _dateRange = picked;
                      _applyFilters();
                      _calculateStatistics();
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Dropdowns and Sort
          Row(
            children: [
              Expanded(
                child: _buildDropdown(
                  value: _selectedInvoiceType,
                  hint: isAr ? 'نوع الفاتورة' : 'Invoice Type',
                  items: _buildInvoiceTypeItems(isAr),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedInvoiceType = value;
                      _applyFilters();
                      _calculateStatistics();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDropdown(
                  value: _selectedStatus,
                  hint: isAr ? 'الحالة' : 'Status',
                  items: _buildStatusItems(isAr),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedStatus = value;
                      _applyFilters();
                      _calculateStatistics();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDropdown(
                  value: _sortBy,
                  hint: isAr ? 'ترتيب حسب' : 'Sort By',
                  items: [
                    {'value': 'date', 'label': isAr ? 'التاريخ' : 'Date'},
                    {
                      'value': 'customer',
                      'label': isAr ? 'العميل' : 'Customer',
                    },
                    {'value': 'amount', 'label': isAr ? 'المبلغ' : 'Amount'},
                    {'value': 'number', 'label': isAr ? 'الرقم' : 'Number'},
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _sortBy = value;
                      _applyFilters();
                      _calculateStatistics();
                    });
                  },
                ),
              ),
              IconButton(
                icon: Icon(
                  _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                  color: colorScheme.primary,
                ),
                onPressed: () {
                  setState(() {
                    _sortAscending = !_sortAscending;
                    _applyFilters();
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Map<String, String>> _buildStatusItems(bool isArabic) {
    return [
      {'value': 'all', 'label': isArabic ? 'الكل' : 'All'},
      {'value': 'paid', 'label': isArabic ? 'مدفوعة' : 'Paid'},
      {
        'value': 'partially_paid',
        'label': isArabic ? 'مدفوعة جزئياً' : 'Partially Paid',
      },
      {'value': 'unpaid', 'label': isArabic ? 'غير مدفوعة' : 'Unpaid'},
      {'value': 'draft', 'label': isArabic ? 'مسودة' : 'Draft'},
      {'value': 'cancelled', 'label': isArabic ? 'ملغاة' : 'Cancelled'},
    ];
  }

  List<Map<String, String>> _buildInvoiceTypeItems(bool isArabic) {
    const defaultOrder = [
      'شراء',
      'شراء من مورد',
      'شراء من عميل',
      'شراء خردة',
      'شراء مستعمل',
      'بيع',
      'بيع جديد',
      'بيع مستعمل',
      'مرتجع شراء',
      'مرتجع شراء من مورد',
      'مرتجع شراء من عميل',
      'مرتجع بيع',
      'مرتجع بيع خردة',
      'مقايضة',
    ];

    const englishLabels = {
      'شراء': 'Purchase',
      'شراء من مورد': 'Purchase (Supplier)',
      'شراء من عميل': 'Purchase (Customer)',
      'شراء خردة': 'Scrap Purchase',
      'شراء مستعمل': 'Used Gold Purchase',
      'بيع': 'Sale',
      'بيع جديد': 'New Sale',
      'بيع مستعمل': 'Used Sale',
      'مرتجع شراء': 'Purchase Return',
      'مرتجع شراء من مورد': 'Supplier Purchase Return',
      'مرتجع شراء من عميل': 'Customer Purchase Return',
      'مرتجع بيع': 'Sales Return',
      'مرتجع بيع خردة': 'Scrap Sales Return',
      'مقايضة': 'Exchange',
    };

    final collectedTypes = <String>{
      for (final invoice in _invoices)
        if (((invoice['invoice_type'] ?? '').toString().trim()).isNotEmpty)
          (invoice['invoice_type'] ?? '').toString().trim(),
    };

    final orderedTypes = <String>[];
    for (final type in defaultOrder) {
      if (collectedTypes.contains(type) || collectedTypes.isEmpty) {
        orderedTypes.add(type);
        collectedTypes.remove(type);
      }
    }

    final remaining = collectedTypes.toList()..sort();
    orderedTypes.addAll(remaining);

    final items = <Map<String, String>>[
      {'value': 'all', 'label': isArabic ? 'الكل' : 'All'},
    ];

    for (final type in orderedTypes) {
      final label = isArabic ? type : (englishLabels[type] ?? type);
      items.add({'value': type, 'label': label});
    }

    return items;
  }

  Widget _buildDropdown({
    required String value,
    required String hint,
    required List<Map<String, String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool isDark = theme.brightness == Brightness.dark;

    final hasMatch = items.any((item) => item['value'] == value);
    final fallbackValue = items.isNotEmpty
        ? (items.first['value'] ?? value)
        : value;
    final effectiveValue = hasMatch ? value : fallbackValue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: isDark ? 0.35 : 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: effectiveValue,
          hint: Text(
            hint,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          dropdownColor: theme.cardTheme.color ?? colorScheme.surface,
          style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurface),
          isExpanded: true,
          items: items.map((item) {
            return DropdownMenuItem<String>(
              value: item['value']!,
              child: Text(item['label']!, style: textTheme.bodyMedium),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildInvoicesList() {
    final colorScheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _loadInvoices,
      color: colorScheme.primary,
      backgroundColor: colorScheme.surface,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _filteredInvoices.length,
        // Performance optimizations
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        cacheExtent: 500,
        itemBuilder: (context, index) {
          try {
            final invoice = _filteredInvoices[index];
            return _buildInvoiceCard(invoice);
          } catch (e, stackTrace) {
            debugPrint('❌ خطأ في بناء بطاقة الفاتورة $index: $e');
            debugPrint('Stack: $stackTrace');
            return SizedBox.shrink();
          }
        },
      ),
    );
  }

  Widget _buildInvoiceCard(Map<String, dynamic> invoice) {
    try {
      final isAr = widget.isArabic;
      final status = (invoice['status'] ?? '').toString().toLowerCase();
      final bool isPaid = (status == 'paid' || status == 'مدفوعة');
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      final textTheme = theme.textTheme;
      final statusColor = isPaid ? Colors.green : Colors.orange;
      final invoiceType = (invoice['invoice_type'] ?? '').toString();
      final bool isPurchase =
          invoiceType == 'شراء' || invoiceType.toLowerCase() == 'buy';
      final Color typeColor = isPurchase ? Colors.blue : colorScheme.primary;
      final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);

      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: theme.cardTheme.color ?? colorScheme.surface,
        shape:
            theme.cardTheme.shape ??
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: () => _viewInvoiceDetails(invoice),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        invoiceDisplayNumber,
                        style: textTheme.titleSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: typeColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        invoiceType,
                        style: textTheme.bodySmall?.copyWith(
                          color: typeColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isPaid ? Icons.check_circle : Icons.pending,
                            color: statusColor,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _translateStatus(status, isAr),
                            style: textTheme.bodySmall?.copyWith(
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Customer and Date
                Row(
                  children: [
                    Icon(
                      Icons.person,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        invoice['customer_name']?.toString() ??
                            (isAr ? 'غير محدد' : 'N/A'),
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.calendar_today,
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _formatDate(invoice['date'], isAr),
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Amount
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceVariant.withValues(alpha: 
                      theme.brightness == Brightness.dark ? 0.35 : 0.8,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isAr ? 'الإجمالي:' : 'Total:',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      Text(
                        '${NumberFormat('#,##0.00', isAr ? 'ar' : 'en').format(((invoice['total'] ?? 0) as num).toDouble())} ${isAr ? 'ريال' : 'SAR'}',
                        style: textTheme.titleLarge?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Actions
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _viewInvoiceDetails(invoice),
                        icon: const Icon(Icons.visibility, size: 18),
                        label: Text(isAr ? 'عرض' : 'View'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.primary,
                          side: BorderSide(color: colorScheme.primary),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _editInvoice(invoice),
                        icon: const Icon(Icons.edit, size: 18),
                        label: Text(isAr ? 'تعديل' : 'Edit'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue,
                          side: const BorderSide(color: Colors.blue),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => _deleteInvoice(invoice),
                      icon: Icon(Icons.delete, color: colorScheme.error),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('❌ خطأ في بناء بطاقة الفاتورة: $e');
      debugPrint('Stack: $stackTrace');
      final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
      // Return simple error card
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: Colors.red.withValues(alpha: 0.15),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'خطأ في عرض الفاتورة $invoiceDisplayNumber',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.red),
          ),
        ),
      );
    }
  }

  String _formatDate(dynamic date, bool isAr) {
    try {
      if (date == null) return isAr ? 'غير محدد' : 'N/A';
      final dateTime = DateTime.parse(date.toString());
      return DateFormat('yyyy-MM-dd').format(dateTime);
    } catch (e) {
      return isAr ? 'غير محدد' : 'N/A';
    }
  }

  Widget _buildEmptyState() {
    final isAr = widget.isArabic;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long,
            size: 80,
            color: colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            isAr ? 'لا توجد فواتير' : 'No Invoices',
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isAr ? 'ابدأ بإضافة فاتورة جديدة' : 'Start by adding a new invoice',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  void _viewInvoiceDetails(Map<String, dynamic> invoice) {
    // TODO: Navigate to invoice details screen
    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
    _showSnackBar(
      'عرض تفاصيل الفاتورة: $invoiceDisplayNumber',
      isError: false,
    );
  }

  void _editInvoice(Map<String, dynamic> invoice) {
    // TODO: Navigate to edit invoice screen
    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
    _showSnackBar('تعديل الفاتورة: $invoiceDisplayNumber', isError: false);
  }

  Future<void> _deleteInvoice(Map<String, dynamic> invoice) async {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Text(
              isAr ? 'تأكيد الحذف' : 'Confirm Delete',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
        content: Text(
          isAr
              ? 'هل أنت متأكد من حذف الفاتورة رقم $invoiceDisplayNumber؟'
              : 'Are you sure you want to delete invoice $invoiceDisplayNumber?',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              isAr ? 'إلغاء' : 'Cancel',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(isAr ? 'حذف' : 'Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // TODO: Call API to delete invoice
        // await _apiService.deleteInvoice(invoice['id']);
        _showSnackBar(
          isAr ? 'تم حذف الفاتورة بنجاح' : 'Invoice deleted successfully',
          isError: false,
        );
        _loadInvoices();
      } catch (e) {
        _showSnackBar(
          isAr
              ? 'فشل حذف الفاتورة: ${e.toString()}'
              : 'Failed to delete: ${e.toString()}',
          isError: true,
        );
      }
    }
  }

  void _navigateToAddInvoice() async {
    // TODO: Navigate to add invoice screen with proper parameters
    _showSnackBar('إضافة فاتورة جديدة قريباً', isError: false);
    // Navigator.push(
    //   context,
    //   MaterialPageRoute(
    //     builder: (context) => AddInvoiceScreen(...),
    //   ),
    // ).then((_) => _loadInvoices());
  }
}
