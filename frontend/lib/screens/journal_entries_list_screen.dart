import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import 'journal_entry_form.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// Enhanced Journal Entries List Screen with professional features
class JournalEntriesListScreen extends StatefulWidget {
  final bool isArabic;

  const JournalEntriesListScreen({Key? key, this.isArabic = true})
    : super(key: key);

  @override
  State<JournalEntriesListScreen> createState() =>
      _JournalEntriesListScreenState();
}

class _JournalEntriesListScreenState extends State<JournalEntriesListScreen> {
  final ApiService _apiService = ApiService();
  List<dynamic> _allEntries = [];
  List<dynamic> _filteredEntries = [];
  List<dynamic> _accounts = [];
  bool _isLoading = true;
  int _mainKarat = 21;
  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;

  // Search & Filters
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  // Advanced Filters
  DateTimeRange? _dateRange;
  int? _selectedAccountId;
  double? _minAmount;
  double? _maxAmount;
  String _sortBy =
      'date_desc'; // date_desc, date_asc, amount_desc, amount_asc, id_desc, id_asc

  // Statistics
  double _totalCash = 0.0;
  double _totalGold = 0.0;
  int _totalEntries = 0;

  @override
  void initState() {
    super.initState();
    _refreshData();
    _searchController.addListener(_applyFilters);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final newSymbol = settings.currencySymbol;
    final newDecimals = settings.decimalPlaces;
    final newMainKarat = settings.mainKarat;
    final needsUpdate =
        newSymbol != _currencySymbol ||
        newDecimals != _currencyDecimalPlaces ||
        newMainKarat != _mainKarat;

    if (needsUpdate) {
      setState(() {
        _currencySymbol = newSymbol;
        _currencyDecimalPlaces = newDecimals;
        _mainKarat = newMainKarat;
      });

      if (_allEntries.isNotEmpty) {
        _applyFilters();
      }
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_applyFilters);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final results = await Future.wait([
        _apiService.getJournalEntries(),
        _apiService.getAccounts(),
      ]);

      final List<dynamic> entries = results[0];
      final List<dynamic> accounts = results[1];

      if (mounted) {
        setState(() {
          _allEntries = entries;
          _accounts = accounts;
          _isLoading = false;
        });
        _applyFilters();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBar('فشل تحميل البيانات: ${e.toString()}', isError: true);
      }
    }
  }

  void _applyFilters() {
    List<dynamic> filtered = List.from(_allEntries);

    // Search filter
    final query = _searchController.text.toLowerCase();
    if (query.isNotEmpty) {
      filtered = filtered.where((entry) {
        final description = (entry['description'] as String? ?? '')
            .toLowerCase();
        final date = (entry['date'] as String? ?? '').toLowerCase();
        final id = (entry['id'] as int? ?? 0).toString();
        return description.contains(query) ||
            date.contains(query) ||
            id.contains(query);
      }).toList();
    }

    // Date range filter
    if (_dateRange != null) {
      filtered = filtered.where((entry) {
        final entryDate = DateTime.parse(entry['date']);
        return entryDate.isAfter(
              _dateRange!.start.subtract(Duration(days: 1)),
            ) &&
            entryDate.isBefore(_dateRange!.end.add(Duration(days: 1)));
      }).toList();
    }

    // Account filter
    if (_selectedAccountId != null) {
      filtered = filtered.where((entry) {
        final lines = entry['lines'] as List<dynamic>? ?? [];
        return lines.any((line) => line['account_id'] == _selectedAccountId);
      }).toList();
    }

    // Amount filter
    if (_minAmount != null || _maxAmount != null) {
      filtered = filtered.where((entry) {
        final totals = _calculateEntryTotals(entry);
        final totalCash = totals['cash']!;

        if (_minAmount != null && totalCash < _minAmount!) return false;
        if (_maxAmount != null && totalCash > _maxAmount!) return false;
        return true;
      }).toList();
    }

    // Sort
    _sortEntries(filtered);

    // Calculate statistics
    _calculateStatistics(filtered);

    setState(() {
      _filteredEntries = filtered;
    });
  }

  void _sortEntries(List<dynamic> entries) {
    switch (_sortBy) {
      case 'date_desc':
        entries.sort(
          (a, b) =>
              DateTime.parse(b['date']).compareTo(DateTime.parse(a['date'])),
        );
        break;
      case 'date_asc':
        entries.sort(
          (a, b) =>
              DateTime.parse(a['date']).compareTo(DateTime.parse(b['date'])),
        );
        break;
      case 'amount_desc':
        entries.sort((a, b) {
          final totalA = _calculateEntryTotals(a)['cash']!;
          final totalB = _calculateEntryTotals(b)['cash']!;
          return totalB.compareTo(totalA);
        });
        break;
      case 'amount_asc':
        entries.sort((a, b) {
          final totalA = _calculateEntryTotals(a)['cash']!;
          final totalB = _calculateEntryTotals(b)['cash']!;
          return totalA.compareTo(totalB);
        });
        break;
      case 'id_desc':
        entries.sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
        break;
      case 'id_asc':
        entries.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
        break;
    }
  }

  void _calculateStatistics(List<dynamic> entries) {
    double totalCash = 0.0;
    double totalGold = 0.0;

    for (var entry in entries) {
      final totals = _calculateEntryTotals(entry);
      totalCash += totals['cash']!;
      totalGold += totals['gold']!;
    }

    _totalCash = totalCash;
    _totalGold = totalGold;
    _totalEntries = entries.length;
  }

  String _formatCash(double amount, {bool includeSymbol = true}) {
    final format = NumberFormat.currency(
      symbol: includeSymbol ? _currencySymbol : '',
      decimalDigits: _currencyDecimalPlaces,
    );
    final formatted = format.format(amount);
    return includeSymbol ? formatted : formatted.trim();
  }

  String _formatAmountForChip(double amount) {
    // Replace non-breaking spaces that NumberFormat may introduce
    return _formatCash(amount).replaceAll('\u00A0', ' ');
  }

  Map<String, double> _calculateEntryTotals(dynamic entry) {
    double totalCash = 0;
    double totalGoldNormalized = 0;
    final lines = entry['lines'] as List<dynamic>? ?? [];

    for (var line in lines) {
      totalCash += (line['cash_debit'] as double? ?? 0.0);
      totalGoldNormalized += _convertToMainKarat(
        line['debit_18k'] as double? ?? 0.0,
        18,
      );
      totalGoldNormalized += _convertToMainKarat(
        line['debit_21k'] as double? ?? 0.0,
        21,
      );
      totalGoldNormalized += _convertToMainKarat(
        line['debit_22k'] as double? ?? 0.0,
        22,
      );
      totalGoldNormalized += _convertToMainKarat(
        line['debit_24k'] as double? ?? 0.0,
        24,
      );
    }

    return {'cash': totalCash, 'gold': totalGoldNormalized};
  }

  double _convertToMainKarat(double weight, int fromKarat) {
    if (fromKarat == 0 || _mainKarat == 0) return 0;
    return (weight * fromKarat) / _mainKarat;
  }

  Color _getEntryTypeColor(String? entryType) {
    switch (entryType) {
      case 'افتتاحي':
        return Colors.blue;
      case 'دوري':
        return Colors.purple;
      case 'إقفال':
        return Colors.red;
      case 'تسوية':
        return Colors.orange;
      case 'تعديل':
        return Colors.teal;
      default:
        return Colors.grey;
    }
  }

  Future<void> _deleteEntry(int id, String description) async {
    // خطوة 1: طلب سبب الحذف
    final reason = await _showDeleteReasonDialog();
    if (reason == null || reason.trim().isEmpty) return;

    // خطوة 2: تأكيد الحذف
    final confirmed = await _showDeleteConfirmation(description, reason);
    if (!confirmed) return;

    try {
      // استخدام الحذف الآمن
      final result = await _apiService.softDeleteJournalEntry(
        id,
        'المستخدم الحالي',
        reason,
      );
      _showSnackBar(
        result['message'] ?? 'تم حذف القيد بنجاح (يمكن الاسترجاع)',
        isError: false,
      );
      await _refreshData();
    } catch (e) {
      _showSnackBar('فشل حذف القيد: ${e.toString()}', isError: true);
    }
  }

  Future<String?> _showDeleteReasonDialog() async {
    final controller = TextEditingController();
    final isAr = widget.isArabic;

    return await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final dialogTheme = Theme.of(dialogContext);
        final colorScheme = dialogTheme.colorScheme;
        final hintColor = colorScheme.onSurface.withValues(alpha: 0.45);

        return AlertDialog(
          backgroundColor: colorScheme.surface,
          title: Text(
            isAr ? 'سبب الحذف' : 'Deletion Reason',
            style: dialogTheme.textTheme.titleLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAr
                    ? 'الرجاء كتابة سبب حذف هذا القيد:'
                    : 'Please enter the reason for deleting this entry:',
                style: dialogTheme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.75),
                ),
              ),
              SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                style: dialogTheme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText:
                      isAr ? 'مثال: خطأ في الإدخال' : 'e.g: Input error',
                  hintStyle: dialogTheme.textTheme.bodyMedium?.copyWith(
                    color: hintColor,
                  ),
                  filled: true,
                  fillColor: colorScheme.surfaceVariant.withValues(alpha: 0.35),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.primary.withValues(alpha: 0.4)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.primary.withValues(alpha: 0.4)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.primary, width: 2),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                isAr ? 'إلغاء' : 'Cancel',
                style: dialogTheme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(dialogContext, controller.text.trim());
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
              ),
              child: Text(isAr ? 'متابعة' : 'Continue'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _showDeleteConfirmation(
    String description,
    String reason,
  ) async {
    final isAr = widget.isArabic;

    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dialogTheme = Theme.of(dialogContext);
            final colorScheme = dialogTheme.colorScheme;

            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.warning,
                    size: 28,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isAr ? 'تأكيد الحذف' : 'Confirm Deletion',
                      style: dialogTheme.textTheme.titleLarge?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isAr ? 'القيد:' : 'Entry:',
                    style: dialogTheme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '"$description"',
                    style: dialogTheme.textTheme.titleMedium,
                  ),
                  SizedBox(height: 12),
                  Text(
                    isAr ? 'السبب:' : 'Reason:',
                    style: dialogTheme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    reason,
                    style: dialogTheme.textTheme.bodyMedium,
                  ),
                  SizedBox(height: 16),
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.info.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: AppColors.info, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isAr
                                ? 'يمكن استرجاع القيد لاحقاً من قائمة المحذوفات'
                                : 'Entry can be restored later from deleted list',
                            style: dialogTheme.textTheme.bodySmall?.copyWith(
                              color: AppColors.info,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                    isAr ? 'إلغاء' : 'Cancel',
                    style: dialogTheme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(isAr ? 'حذف' : 'Delete'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  void _showSnackBar(String message, {required bool isError}) {
    final theme = Theme.of(context);
    final backgroundColor = isError ? AppColors.error : AppColors.success;
    final foreground = isError
        ? theme.colorScheme.onError
        : theme.colorScheme.onPrimary;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _navigateToAddEditScreen([dynamic entry]) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (context) => AddEditJournalEntryScreen(entry: entry),
          ),
        )
        .then((value) {
          if (value == true) {
            _refreshData();
          }
        });
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (context) => _FilterDialog(
        dateRange: _dateRange,
        selectedAccountId: _selectedAccountId,
        minAmount: _minAmount,
        maxAmount: _maxAmount,
        accounts: _accounts,
        isArabic: widget.isArabic,
        currencySymbol: _currencySymbol,
        currencyDecimalPlaces: _currencyDecimalPlaces,
        onApply: (dateRange, accountId, minAmt, maxAmt) {
          setState(() {
            _dateRange = dateRange;
            _selectedAccountId = accountId;
            _minAmount = minAmt;
            _maxAmount = maxAmt;
          });
          _applyFilters();
        },
        onClear: () {
          setState(() {
            _dateRange = null;
            _selectedAccountId = null;
            _minAmount = null;
            _maxAmount = null;
          });
          _applyFilters();
        },
      ),
    );
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final dialogTheme = Theme.of(dialogContext);
        final colorScheme = dialogTheme.colorScheme;
        return AlertDialog(
          backgroundColor: colorScheme.surface,
          title: Text(
            'ترتيب حسب',
            style: dialogTheme.textTheme.titleLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSortOption('التاريخ (الأحدث أولاً)', 'date_desc'),
              _buildSortOption('التاريخ (الأقدم أولاً)', 'date_asc'),
              _buildSortOption('المبلغ (الأعلى أولاً)', 'amount_desc'),
              _buildSortOption('المبلغ (الأقل أولاً)', 'amount_asc'),
              _buildSortOption('الرقم (الأعلى أولاً)', 'id_desc'),
              _buildSortOption('الرقم (الأقل أولاً)', 'id_asc'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSortOption(String label, String value) {
    return RadioListTile<String>(
      title: Text(label),
      value: value,
      groupValue: _sortBy,
      activeColor: AppColors.primaryGold,
      onChanged: (newValue) {
        setState(() => _sortBy = newValue!);
        _applyFilters();
        Navigator.pop(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final gold = colorScheme.primary;
    final background = theme.scaffoldBackgroundColor;
    final appBarForeground =
        theme.appBarTheme.foregroundColor ?? colorScheme.onPrimary;

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        foregroundColor: appBarForeground,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'بحث بالوصف، التاريخ، أو الرقم...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: appBarForeground.withValues(alpha: 0.6)),
                ),
                style: TextStyle(color: appBarForeground),
              )
            : Text(isAr ? 'قيود اليومية' : 'Journal Entries'),
        actions: [
          if (_isSearching)
            IconButton(
              icon: Icon(Icons.close),
              color: appBarForeground,
              onPressed: () {
                if (_searchController.text.isEmpty) {
                  setState(() => _isSearching = false);
                } else {
                  _searchController.clear();
                }
              },
            )
          else ...[
            IconButton(
              icon: Icon(Icons.search),
              tooltip: isAr ? 'بحث' : 'Search',
              color: appBarForeground,
              onPressed: () => setState(() => _isSearching = true),
            ),
            IconButton(
              icon: Icon(Icons.filter_list),
              tooltip: isAr ? 'فلتر' : 'Filter',
              color: appBarForeground,
              onPressed: _showFilterDialog,
            ),
            IconButton(
              icon: Icon(Icons.sort),
              tooltip: isAr ? 'ترتيب' : 'Sort',
              color: appBarForeground,
              onPressed: _showSortDialog,
            ),
            IconButton(
              icon: Icon(Icons.add),
              tooltip: isAr ? 'إضافة قيد' : 'Add Entry',
              color: appBarForeground,
              onPressed: () => _navigateToAddEditScreen(),
            ),
          ],
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: gold))
          : Column(
              children: [
                // Statistics Summary Card
                _buildStatisticsCard(theme, isAr),

                // Active Filters Chips
                if (_hasActiveFilters())
                  _buildActiveFiltersChips(theme, gold),

                // Entries List
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshData,
                    color: gold,
                    child: _filteredEntries.isEmpty
                        ? _buildEmptyState(isAr, theme)
                        : _buildEntriesList(theme, isAr),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildStatisticsCard(
    ThemeData theme,
    bool isAr,
  ) {
    final colorScheme = theme.colorScheme;
    final onSurface = colorScheme.onSurface;

    return Container(
      margin: EdgeInsets.all(12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            colorScheme.primary.withValues(alpha: 0.18),
            colorScheme.primary.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.25), width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(
            theme,
            Icons.receipt_long,
            _totalEntries.toString(),
            isAr ? 'قيد' : 'Entries',
            colorScheme.primary,
            onSurface,
          ),
          _buildStatItem(
            theme,
            Icons.monetization_on,
            _formatCash(_totalCash),
            isAr ? 'نقد' : 'Cash',
            AppColors.success,
            onSurface,
          ),
          _buildStatItem(
            theme,
            Icons.balance,
            '${_totalGold.toStringAsFixed(2)} ${isAr ? 'غ' : 'g'}',
            isAr ? 'ذهب' : 'Gold',
            AppColors.darkGold,
            onSurface,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    ThemeData theme,
    IconData icon,
    String value,
    String label,
    Color iconColor,
    Color textColor,
  ) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 28),
        SizedBox(height: 6),
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            color: textColor,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: textColor.withValues(alpha: 0.65),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  bool _hasActiveFilters() {
    return _dateRange != null ||
        _selectedAccountId != null ||
        _minAmount != null ||
        _maxAmount != null;
  }

  Widget _buildActiveFiltersChips(ThemeData theme, Color gold) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_dateRange != null)
            _buildFilterChip(
              theme,
              '${DateFormat('yyyy-MM-dd').format(_dateRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_dateRange!.end)}',
              gold,
              () {
                setState(() => _dateRange = null);
                _applyFilters();
              },
            ),
          if (_selectedAccountId != null)
            _buildFilterChip(
              theme,
              _accounts.firstWhere(
                (a) => a['id'] == _selectedAccountId,
              )['name'],
              gold,
              () {
                setState(() => _selectedAccountId = null);
                _applyFilters();
              },
            ),
          if (_minAmount != null || _maxAmount != null)
            _buildFilterChip(
              theme,
              '${_minAmount != null ? _formatAmountForChip(_minAmount!) : _formatAmountForChip(0)} - ${_maxAmount != null ? _formatAmountForChip(_maxAmount!) : '∞'}',
              gold,
              () {
                setState(() {
                  _minAmount = null;
                  _maxAmount = null;
                });
                _applyFilters();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(
    ThemeData theme,
    String label,
    Color gold,
    VoidCallback onDelete,
  ) {
    final onSurface = theme.colorScheme.onSurface;
    return Chip(
      label: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      deleteIcon: Icon(Icons.close, size: 18, color: gold),
      onDeleted: onDelete,
      backgroundColor: gold.withValues(alpha: 0.1),
      side: BorderSide(color: gold.withValues(alpha: 0.6), width: 1),
    );
  }

  Widget _buildEmptyState(bool isAr, ThemeData theme) {
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          SizedBox(height: 16),
          Text(
            _isSearching || _hasActiveFilters()
                ? (isAr ? 'لا توجد نتائج مطابقة' : 'No matching results')
                : (isAr ? 'لا توجد قيود' : 'No entries'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: muted,
              fontSize: 18,
            ),
          ),
          SizedBox(height: 8),
          Text(
            isAr ? 'قم بإضافة قيد جديد' : 'Add a new entry',
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntriesList(ThemeData theme, bool isAr) {
    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _filteredEntries.length,
      itemBuilder: (context, index) {
        final entry = _filteredEntries[index];
        return _buildEntryCard(theme, entry, isAr);
      },
    );
  }

  Widget _buildEntryCard(ThemeData theme, dynamic entry, bool isAr) {
    final colorScheme = theme.colorScheme;
    final gold = colorScheme.primary;
    final cardBg = theme.cardColor;
    final mutedText = colorScheme.onSurface.withValues(alpha: 0.6);
    final totals = _calculateEntryTotals(entry);
    final totalCash = totals['cash']!;
    final totalGold = totals['gold']!;
    final date = DateTime.parse(entry['date']);
    final dateStr = DateFormat('yyyy-MM-dd').format(date);

    return Dismissible(
      key: ValueKey(entry['id']),
      direction: DismissDirection.endToStart,
      confirmDismiss: (direction) async {
        return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dialogTheme = Theme.of(dialogContext);
            final dialogScheme = dialogTheme.colorScheme;
            return AlertDialog(
              backgroundColor: dialogScheme.surface,
              title: Text(
                'تأكيد الحذف',
                style: dialogTheme.textTheme.titleLarge?.copyWith(
                  color: AppColors.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                'هل تريد حذف القيد "${entry['description']}"؟',
                style: dialogTheme.textTheme.bodyMedium,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(
                    'إلغاء',
                    style: dialogTheme.textTheme.bodyMedium?.copyWith(
                      color: dialogScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: dialogScheme.onError,
                  ),
                  child: Text('حذف'),
                ),
              ],
            );
          },
        );
      },
      onDismissed: (direction) {
        _deleteEntry(entry['id'], entry['description']);
      },
      background: Container(
        margin: EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.error,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: EdgeInsets.only(right: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'حذف',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete, color: Colors.white, size: 28),
          ],
        ),
      ),
      child: Card(
        margin: EdgeInsets.symmetric(vertical: 4),
        elevation: 4,
        color: cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: gold.withValues(alpha: 0.2), width: 1),
        ),
        child: InkWell(
          onTap: () => _navigateToAddEditScreen(entry),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        // ID Badge
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: gold.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: gold, width: 1),
                          ),
                          child: Text(
                            '#${entry['id']}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: gold,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (entry['entry_type'] != null && entry['entry_type'] != 'عادي') ...[
                          SizedBox(width: 8),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: _getEntryTypeColor(entry['entry_type']).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _getEntryTypeColor(entry['entry_type']),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              entry['entry_type'],
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _getEntryTypeColor(entry['entry_type']),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // Date
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: 14,
                          color: mutedText,
                        ),
                        SizedBox(width: 4),
                        Text(
                          dateStr,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: mutedText,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: 12),

                // Description
                Text(
                  entry['description'] ?? (isAr ? 'بلا وصف' : 'No description'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 12),

                // Amounts Row
                Row(
                  children: [
                    if (totalCash > 0) ...[
                      Icon(
                        Icons.monetization_on_outlined,
                        size: 18,
                        color: AppColors.success,
                      ),
                      SizedBox(width: 6),
                      Text(
                        _formatCash(totalCash),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.success,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(width: 16),
                    ],
                    if (totalGold > 0) ...[
                      Icon(Icons.balance, size: 18, color: AppColors.darkGold),
                      SizedBox(width: 6),
                      Text(
                        '${totalGold.toStringAsFixed(3)} ${isAr ? 'غ' : 'g'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.darkGold,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Filter Dialog Widget
class _FilterDialog extends StatefulWidget {
  final DateTimeRange? dateRange;
  final int? selectedAccountId;
  final double? minAmount;
  final double? maxAmount;
  final List<dynamic> accounts;
  final bool isArabic;
  final String currencySymbol;
  final int currencyDecimalPlaces;
  final Function(DateTimeRange?, int?, double?, double?) onApply;
  final VoidCallback onClear;

  const _FilterDialog({
    required this.dateRange,
    required this.selectedAccountId,
    required this.minAmount,
    required this.maxAmount,
    required this.accounts,
    required this.isArabic,
    required this.currencySymbol,
    required this.currencyDecimalPlaces,
    required this.onApply,
    required this.onClear,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  DateTimeRange? _dateRange;
  int? _selectedAccountId;
  TextEditingController _minAmountController = TextEditingController();
  TextEditingController _maxAmountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _dateRange = widget.dateRange;
    _selectedAccountId = widget.selectedAccountId;
    _minAmountController.text = widget.minAmount != null
        ? widget.minAmount!.toStringAsFixed(widget.currencyDecimalPlaces)
        : '';
    _maxAmountController.text = widget.maxAmount != null
        ? widget.maxAmount!.toStringAsFixed(widget.currencyDecimalPlaces)
        : '';
  }

  @override
  void dispose() {
    _minAmountController.dispose();
    _maxAmountController.dispose();
    super.dispose();
  }

  Future<void> _selectDateRange() async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(Duration(days: 365)),
      initialDateRange: _dateRange,
      builder: (context, child) {
        return Theme(
          data: theme.copyWith(
            colorScheme: colorScheme.copyWith(
              primary: colorScheme.primary,
              onPrimary: colorScheme.onPrimary,
              surface: colorScheme.surface,
              onSurface: colorScheme.onSurface,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
              ),
            ),
          ),
          child: child ?? SizedBox.shrink(),
        );
      },
    );

    if (picked != null) {
      setState(() => _dateRange = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final gold = colorScheme.primary;
    final onSurface = colorScheme.onSurface;
    final hintColor = onSurface.withValues(alpha: 0.5);
    final sortedAccounts = List<dynamic>.from(widget.accounts)
      ..sort((a, b) {
        final aNum = int.tryParse(a['account_number']?.toString() ?? '0') ?? 0;
        final bNum = int.tryParse(b['account_number']?.toString() ?? '0') ?? 0;
        return aNum.compareTo(bNum);
      });

    return AlertDialog(
      backgroundColor: colorScheme.surface,
      title: Text(
        isAr ? 'تصفية القيود' : 'Filter Entries',
        style: theme.textTheme.titleLarge?.copyWith(
          color: gold,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date Range
            Text(
              isAr ? 'نطاق التاريخ' : 'Date Range',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: onSurface.withValues(alpha: 0.75),
              ),
            ),
            SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _selectDateRange,
              icon: Icon(Icons.calendar_today, color: gold, size: 18),
              label: Text(
                _dateRange == null
                    ? (isAr ? 'اختر الفترة' : 'Select Period')
                    : '${DateFormat('yyyy-MM-dd').format(_dateRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_dateRange!.end)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: onSurface,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: gold),
                foregroundColor: gold,
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            SizedBox(height: 16),

            // Account Filter
            Text(
              isAr ? 'الحساب' : 'Account',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: onSurface.withValues(alpha: 0.75),
              ),
            ),
            SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: _selectedAccountId,
              dropdownColor: colorScheme.surface,
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: isAr ? 'جميع الحسابات (اكتب رقم الحساب للبحث السريع)' : 'All Accounts (Type account number for quick search)',
                hintStyle: theme.textTheme.bodySmall?.copyWith(
                  color: hintColor,
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: gold),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: gold, width: 2),
                ),
              ),
              items: [
                DropdownMenuItem<int>(
                  value: null,
                  child: Text(
                    isAr ? 'جميع الحسابات' : 'All Accounts',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hintColor,
                    ),
                  ),
                ),
                // ترتيب الحسابات أبجدياً حسب رقم الحساب وإظهار تفاصيل إضافية
                ...sortedAccounts.map<DropdownMenuItem<int>>((account) {
                  return DropdownMenuItem<int>(
                    value: account['id'],
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${account['account_number']} - ${account['name']}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            account['transaction_type'] == 'cash' 
                              ? (isAr ? 'حساب نقدي' : 'Cash Account')
                              : account['transaction_type'] == 'gold'
                                ? (isAr ? 'حساب ذهبي' : 'Gold Account')
                                : (isAr ? 'حساب مختلط' : 'Mixed Account'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hintColor,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ],
              onChanged: (value) {
                setState(() => _selectedAccountId = value);
              },
            ),
            SizedBox(height: 16),

            // Amount Range
            Text(
              isAr ? 'نطاق المبلغ النقدي' : 'Cash Amount Range',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: onSurface.withValues(alpha: 0.75),
              ),
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _minAmountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      labelText: isAr ? 'من' : 'Min',
                      labelStyle: theme.textTheme.bodySmall?.copyWith(
                        color: hintColor,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: gold),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: gold, width: 2),
                      ),
                      suffixText: widget.currencySymbol,
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _maxAmountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      labelText: isAr ? 'إلى' : 'Max',
                      labelStyle: theme.textTheme.bodySmall?.copyWith(
                        color: hintColor,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: gold),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: gold, width: 2),
                      ),
                      suffixText: widget.currencySymbol,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onClear();
            Navigator.pop(context);
          },
          child: Text(
            isAr ? 'مسح الكل' : 'Clear All',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.error,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            isAr ? 'إلغاء' : 'Cancel',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: onSurface.withValues(alpha: 0.7),
            ),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            final minAmt = double.tryParse(_minAmountController.text);
            final maxAmt = double.tryParse(_maxAmountController.text);
            widget.onApply(_dateRange, _selectedAccountId, minAmt, maxAmt);
            Navigator.pop(context);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: gold,
            foregroundColor: colorScheme.onPrimary,
          ),
          child: Text(isAr ? 'تطبيق' : 'Apply'),
        ),
      ],
    );
  }
}
