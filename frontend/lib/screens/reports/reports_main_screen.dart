import 'reconciliation_findings_screen.dart';
import 'vat_returns_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../api_service.dart';
import '../../providers/auth_provider.dart';
import '../../models/report_catalog.dart';
import '../../models/report_models.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/report_category_section.dart';
import '../accounts_screen.dart';
import '../general_ledger_screen_v2.dart';
import '../payroll_report_screen.dart';
import 'bonus_payables_report_screen.dart';
import 'balance_sheet_report_screen.dart';
import 'cash_flow_report_screen.dart';
import 'purchases_analysis_report_screen.dart';
import 'sales_analysis_report_screen.dart';
import 'trial_balance_report_screen.dart';
import 'category_weight_audit_report_screen.dart';
import 'supplier_aging_report_screen.dart';
import 'gold_price_history_report_screen.dart';
import 'gold_by_place_report_screen.dart';
import 'safe_gold_reconciliation_report_screen.dart';
import 'income_statement_report_screen.dart';
import 'customer_balances_report_screen.dart';
import '../safe_boxes_screen.dart';
import 'analytics_dashboard_screen.dart';
import 'admin_dashboard_screen.dart';
import 'weight_position_screen.dart';

/// The screen a report's route opens (ADR-057 ق٠) -- one place for the
/// reports centre and the home screen's search. Null for a route not built.
Widget? reportDestination(String route, ApiService api, bool isArabic) {
  switch (route) {
    case 'admin_dashboard':
      return AdminDashboardScreen(api: api, isArabic: isArabic);
    case 'weight_position':
      return WeightPositionScreen(api: api, isArabic: isArabic);
    case 'reconciliation_findings':
      return ReconciliationFindingsScreen(api: api, isArabic: isArabic);
    case 'vat_returns':
      return VatReturnsScreen(api: api, isArabic: isArabic);
    case 'analytics_dashboard':
      return AnalyticsDashboardScreen(api: api, isArabic: isArabic);
    case 'cash_flow':
      return CashFlowReportScreen(api: api);
    case 'balance_sheet':
      return BalanceSheetReportScreen(api: api);
    case 'supplier_aging':
      return SupplierAgingReportScreen(api: api);
    case 'sales_analysis':
      return SalesAnalysisReportScreen(api: api);
    case 'purchases_analysis':
      return PurchasesAnalysisReportScreen(api: api);
    case 'income_statement':
      return IncomeStatementReportScreen(api: api, isArabic: isArabic);
    case 'customer_balances':
      return CustomerBalancesReportScreen(api: api);
    case 'category_weight_audit':
      return CategoryWeightAuditReportScreen(api: api, isArabic: isArabic);
    case 'gold_price_history':
      return GoldPriceHistoryReportScreen(api: api);
    case 'gold_by_place':
      return GoldByPlaceReportScreen(api: api);
    case 'safe_gold_reconciliation':
      return SafeGoldReconciliationReportScreen(api: api);
    case 'safe_boxes_screen':
      return SafeBoxesScreen(
        api: api,
        initialFilterType: 'gold',
        lockFilterType: true,
        titleOverride: isArabic
            ? 'جرد صناديق الذهب (عهد الموظفين)'
            : 'Gold Safe Boxes Inventory (Employees)',
      );
    case 'trial_balance':
      return const TrialBalanceReportScreen();
    case 'general_ledger':
      return const GeneralLedgerScreenV2();
    case 'account_statement':
      return const AccountsScreen(initialOnlyDetailAccounts: true);
    case 'payroll_report':
      return PayrollReportScreen(api: api);
    case 'bonus_payables':
      return BonusPayablesReportScreen(api: api);
  }
  return null;
}

/// The reports centre: a search, then the owner's questions and the reports
/// that answer each (REPORTS-HUB, the owner 5 Nov 2026: «حسب السؤال»,
/// «بطاقة مضغوطة»). Nothing above the search: the card «كل تقاريرك في مكان
/// واحد» took the screen and said nothing.
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

  /// The widest the list grows: wider, the eye loses the row.
  static const double _maxWidth = 1200;

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

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  bool _matches(
    ReportCategory category,
    ReportDescriptor report,
    String query,
  ) {
    if (query.isEmpty) return true;
    final isArabic = widget.isArabic;
    return [
      report.localizedTitle(isArabic),
      report.localizedDescription(isArabic),
      category.localizedName(isArabic),
      ...report.keywords,
    ].any((text) => text.toLowerCase().contains(query));
  }

  Iterable<ReportCategory> get _filteredCategories sync* {
    final query = _searchQuery.toLowerCase();
    // The manager's dashboard is the manager's alone (DASH-3, 30 Oct 2026).
    final manager = Provider.of<AuthProvider>(
      context,
      listen: false,
    ).hasPermission('dashboard.admin');
    for (final category in _allCategories) {
      final reports = [
        for (final report in category.reports)
          if ((report.id != 'admin_dashboard' || manager) &&
              _matches(category, report, query))
            report,
      ];
      if (reports.isEmpty) continue;
      yield ReportCategory(
        id: category.id,
        icon: category.icon,
        nameAr: category.nameAr,
        nameEn: category.nameEn,
        reports: reports,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    final filtered = _filteredCategories.toList();

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'مركز التقارير' : 'Reports Center'),
        ),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _buildSearchBar(isArabic),
                  const SizedBox(height: AppSpace.xl),
                  if (filtered.isEmpty)
                    _buildEmptyState(context, isArabic)
                  else
                    for (final category in filtered) ...[
                      ReportCategorySection(
                        category: category,
                        isArabic: isArabic,
                        onReportSelected: _openReport,
                      ),
                      const SizedBox(height: AppSpace.xl),
                    ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isArabic) {
    return TextField(
      controller: _searchController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear),
                tooltip: isArabic ? 'مسح البحث' : 'Clear search',
                onPressed: _clearSearch,
              ),
        hintText: isArabic
            ? 'ابحث عن تقرير: الميزانية، العملاء، الرواتب...'
            : 'Search for a report...',
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isArabic) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xxl),
      child: Column(
        children: [
          Icon(Icons.search_off, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: AppSpace.md),
          Text(
            isArabic ? 'لا توجد تقارير مطابقة' : 'No reports found',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton.icon(
            onPressed: _clearSearch,
            icon: const Icon(Icons.clear),
            label: Text(isArabic ? 'مسح البحث' : 'Clear search'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReport(ReportDescriptor report) async {
    final destination = reportDestination(
      report.route,
      widget.api,
      widget.isArabic,
    );
    // Every listed report opens (test/report_catalog_test.dart).
    if (destination == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => destination));
  }
}
