import 'package:flutter/material.dart';
import '../../api_service.dart';
import '../../models/report_catalog.dart';
import '../../models/report_models.dart';
import '../../widgets/report_category_section.dart';
import '../accounts_screen.dart';
import '../general_ledger_screen_v2.dart';
import '../payroll_report_screen.dart';
import '../trial_balance_screen_v2.dart';
import 'inventory_status_report_screen.dart';
import 'inventory_movement_timeline_report_screen.dart';
import 'low_stock_report_screen.dart';
import 'sales_by_customer_report_screen.dart';
import 'sales_by_item_report_screen.dart';
import 'sales_vs_purchases_trend_report_screen.dart';
import 'sales_overview_report_screen.dart';
import 'customer_balances_aging_report_screen.dart';
import 'gold_price_history_report_screen.dart';
import 'gold_position_report_screen.dart';
import 'income_statement_report_screen.dart';
import 'employee_scrap_ledger_report_screen.dart';
import 'analytics_dashboard_screen.dart';
import 'admin_dashboard_screen.dart';

/// مركز التقارير الموحد - قاعدة البناء لجميع تقارير النظام
class ReportsMainScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const ReportsMainScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<ReportsMainScreen> createState() => _ReportsMainScreenState();
}

class _ReportsMainScreenState extends State<ReportsMainScreen> {
  late final List<ReportCategory> _allCategories;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  ReportType? _selectedType;

  @override
  void initState() {
    super.initState();
    _allCategories = ReportCatalog.buildDefaultCatalog();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    setState(() => _searchQuery = _searchController.text.trim());
  }

  void _toggleFilter(ReportType type) {
    setState(() {
      _selectedType = _selectedType == type ? null : type;
    });
  }

  Iterable<ReportCategory> get _filteredCategories sync* {
    for (final category in _allCategories) {
      final filteredReports = category.reports.where((report) {
        final matchesType =
            _selectedType == null || report.type == _selectedType;
        final query = _searchQuery.toLowerCase();
        if (query.isEmpty && matchesType) return true;

        final titleMatches = report
            .localizedTitle(widget.isArabic)
            .toLowerCase()
            .contains(query);
        final descriptionMatches = report
            .localizedDescription(widget.isArabic)
            .toLowerCase()
            .contains(query);
        final categoryMatches = category
            .localizedName(widget.isArabic)
            .toLowerCase()
            .contains(query);

        return matchesType &&
            (titleMatches || descriptionMatches || categoryMatches);
      }).toList();

      if (filteredReports.isEmpty) continue;

      yield ReportCategory(
        id: category.id,
        icon: category.icon,
        accentColor: category.accentColor,
        nameAr: category.nameAr,
        nameEn: category.nameEn,
        reports: filteredReports,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'مركز التقارير' : 'Reports Center'),
          actions: [
            IconButton(
              tooltip: isArabic ? 'تحديث القائمة' : 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() {}),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = constraints.maxWidth > 1024
                  ? 48.0
                  : 16.0;
              final filtered = _filteredCategories.toList();

              return ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: 24,
                ),
                children: [
                  _buildHeader(context, isArabic),
                  const SizedBox(height: 24),
                  _buildSearchBar(context, isArabic),
                  const SizedBox(height: 16),
                  _buildTypeFilters(context, isArabic),
                  const SizedBox(height: 24),
                  if (filtered.isEmpty)
                    _buildEmptyState(context, isArabic)
                  else ...[
                    for (final category in filtered) ...[
                      ReportCategorySection(
                        category: category,
                        isArabic: isArabic,
                        onReportSelected: _handleReportTap,
                      ),
                      const SizedBox(height: 32),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isArabic) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'كل تقاريرك في مكان واحد' : 'All reports in one place',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              isArabic
                  ? 'استعرض تقارير المبيعات والمخزون والمحاسبة والذهب بسهولة، وحدد الفلاتر المناسبة قبل التحليل.'
                  : 'Explore sales, inventory, accounting, and gold reports with tailored filters.',
              style: textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, bool isArabic) {
    final hint = isArabic
        ? 'ابحث عن تقرير أو فئة...'
        : 'Search for a report...';

    return TextField(
      controller: _searchController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear),
                tooltip: isArabic ? 'إزالة البحث' : 'Clear search',
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _buildTypeFilters(BuildContext context, bool isArabic) {
    final types = ReportType.values;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            label: Text(isArabic ? 'الكل' : 'All'),
            selected: _selectedType == null,
            onSelected: (_) {
              setState(() => _selectedType = null);
            },
            selectedColor: Theme.of(context).colorScheme.primary,
            labelStyle: TextStyle(
              color: _selectedType == null
                  ? Theme.of(context).colorScheme.onPrimary
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          ...types.map((type) {
            final selected = _selectedType == type;
            return Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: ChoiceChip(
                label: Text(_localizedTypeLabel(type, isArabic)),
                selected: selected,
                onSelected: (_) => _toggleFilter(type),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: selected
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  String _localizedTypeLabel(ReportType type, bool isArabic) {
    switch (type) {
      case ReportType.financial:
        return isArabic ? 'مالية' : 'Financial';
      case ReportType.sales:
        return isArabic ? 'مبيعات' : 'Sales';
      case ReportType.inventory:
        return isArabic ? 'مخزون' : 'Inventory';
      case ReportType.gold:
        return isArabic ? 'ذهب' : 'Gold';
      case ReportType.payroll:
        return isArabic ? 'رواتب' : 'Payroll';
      case ReportType.accounting:
        return isArabic ? 'محاسبة' : 'Accounting';
      case ReportType.other:
        return isArabic ? 'أخرى' : 'Other';
    }
  }

  Widget _buildEmptyState(BuildContext context, bool isArabic) {
    final headline = isArabic ? 'لا توجد تقارير مطابقة' : 'No reports found';
    final subtitle = isArabic
        ? 'جرّب تغيير كلمات البحث أو إزالة عوامل التصفية.'
        : 'Try adjusting your filters or search keywords.';

    return Column(
      children: [
        const SizedBox(height: 48),
        Icon(Icons.search_off, size: 72, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(headline, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  void _handleReportTap(ReportDescriptor report) {
    _openReport(report);
  }

  Future<void> _openReport(ReportDescriptor report) async {
    Widget? destination;

    switch (report.route) {
      case 'admin_dashboard':
        destination = AdminDashboardScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'analytics_dashboard':
        destination = AnalyticsDashboardScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'sales_overview':
        destination = SalesOverviewReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'income_statement':
        destination = IncomeStatementReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'sales_by_customer':
        destination = SalesByCustomerReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'sales_by_item':
        destination = SalesByItemReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'sales_vs_purchases_trend':
        destination = SalesVsPurchasesTrendReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'customer_balances_aging':
        destination = CustomerBalancesAgingReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'inventory_status':
        destination = InventoryStatusReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'inventory_movement':
        destination = InventoryMovementTimelineReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'low_stock':
        destination = LowStockReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'gold_price_history':
        destination = GoldPriceHistoryReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'gold_position':
        destination = GoldPositionReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'employee_scrap_ledger':
        destination = EmployeeScrapLedgerReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
      case 'trial_balance':
        destination = const TrialBalanceScreenV2();
        break;
      case 'general_ledger':
        destination = const GeneralLedgerScreenV2();
        break;
      case 'account_statement':
        destination = const AccountsScreen(initialOnlyDetailAccounts: true);
        break;
      case 'payroll_report':
        destination = PayrollReportScreen(
          api: widget.api,
          isArabic: widget.isArabic,
        );
        break;
    }

    if (destination == null) {
      final message = widget.isArabic
          ? 'التقرير غير متوفر حالياً'
          : 'This report is not available yet.';

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }

    if (!mounted) return;

    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => destination!));
  }
}
