import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart' as app_theme;
import 'account_statement_screen.dart';
import 'add_supplier_screen.dart';
import 'add_voucher_screen.dart';
import 'purchase_invoice_screen.dart';
import 'supplier_ledger_screen.dart';
import 'supplier_settlements_screen.dart';

enum _SuppliersViewMode { cards, compact }

class SuppliersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SuppliersScreen({super.key, required this.api, this.isArabic = true});

  @override
  SuppliersScreenState createState() => SuppliersScreenState();
}

class SuppliersScreenState extends State<SuppliersScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _topChromeKey = GlobalKey();

  List<Map<String, dynamic>> _allSuppliers = const [];
  List<Map<String, dynamic>> _filteredSuppliers = const [];

  bool _isLoading = true;
  String? _error;

  bool _filterNonZero = false;
  bool _onlyActive = false;
  bool _onlyClosingOffices = false;
  String _sortBy = 'name';
  bool _sortAscending = true;
  _SuppliersViewMode _viewMode = _SuppliersViewMode.cards;

  int _mainKarat = 21;
  double _topChromeHeight = 0;
  double _topChromeCollapseOffset = 0;

  static const double _epsCash = 0.01;
  static const double _epsGold = 0.0005;

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterSuppliers);
    _scrollController.addListener(_onContentScroll);
    _fetchSuppliers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.watch<SettingsProvider>();
    final newMainKarat = settings.mainKarat;
    if (newMainKarat != _mainKarat) {
      _mainKarat = newMainKarat;
      if (_allSuppliers.isNotEmpty) {
        _filterSuppliers();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchSuppliers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final suppliers = await widget.api.getSuppliers();
      if (!mounted) return;

      _allSuppliers = suppliers
          .whereType<Map>()
          .map(
            (entry) =>
                entry.map((key, value) => MapEntry(key.toString(), value)),
          )
          .toList(growable: false);
      _filterSuppliers();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
        _allSuppliers = const [];
        _filteredSuppliers = const [];
      });
    }
  }

  void _onContentScroll() {
    final nextOffset = _scrollController.hasClients
        ? _scrollController.offset.clamp(0.0, _topChromeHeight)
        : 0.0;
    if ((nextOffset - _topChromeCollapseOffset).abs() < 0.5) {
      return;
    }
    setState(() {
      _topChromeCollapseOffset = nextOffset;
    });
  }

  void _measureTopChrome() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _topChromeKey.currentContext;
      if (context == null) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox) return;
      final measuredHeight = renderObject.size.height;
      if (measuredHeight <= 0 ||
          (measuredHeight - _topChromeHeight).abs() < 0.5) {
        return;
      }
      setState(() {
        _topChromeHeight = measuredHeight;
        if (_topChromeCollapseOffset > measuredHeight) {
          _topChromeCollapseOffset = measuredHeight;
        }
      });
    });
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  String _supplierName(Map<String, dynamic> supplier) {
    return (supplier['name'] ?? '').toString().trim();
  }

  String _supplierCode(Map<String, dynamic> supplier) {
    return (supplier['supplier_code'] ?? '').toString().trim();
  }

  String _supplierPhone(Map<String, dynamic> supplier) {
    return (supplier['phone'] ?? '').toString().trim();
  }

  String _supplierTaxNumber(Map<String, dynamic> supplier) {
    return (supplier['tax_number'] ?? '').toString().trim();
  }

  String _defaultSafeBoxName(Map<String, dynamic> supplier) {
    return (supplier['default_safe_box_name'] ?? '').toString().trim();
  }

  bool _isActive(Map<String, dynamic> supplier) {
    return (supplier['active'] ?? true) == true;
  }

  bool _isClosingOffice(Map<String, dynamic> supplier) {
    return (supplier['is_closing_office'] ?? false) == true;
  }

  double _cashBalance(Map<String, dynamic> supplier) {
    return _toDouble(supplier['balance_cash']);
  }

  double _goldMainEquivalent(Map<String, dynamic> supplier) {
    final b18 = _toDouble(supplier['balance_gold_18k']);
    final b21 = _toDouble(supplier['balance_gold_21k']);
    final b22 = _toDouble(supplier['balance_gold_22k']);
    final b24 = _toDouble(supplier['balance_gold_24k']);

    final main = _mainKarat <= 0 ? 21.0 : _mainKarat.toDouble();
    return (b18 * (18.0 / main)) +
        (b21 * (21.0 / main)) +
        (b22 * (22.0 / main)) +
        (b24 * (24.0 / main));
  }

  bool _hasPendingBalance(Map<String, dynamic> supplier) {
    return _cashBalance(supplier).abs() > _epsCash ||
        _goldMainEquivalent(supplier).abs() > _epsGold;
  }

  void _filterSuppliers() {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _allSuppliers
        .where((supplier) {
          final name = _supplierName(supplier).toLowerCase();
          final code = _supplierCode(supplier).toLowerCase();
          final phone = _supplierPhone(supplier).toLowerCase();
          final tax = _supplierTaxNumber(supplier).toLowerCase();
          final safeBox = _defaultSafeBoxName(supplier).toLowerCase();

          final matchesQuery =
              query.isEmpty ||
              name.contains(query) ||
              code.contains(query) ||
              phone.contains(query) ||
              tax.contains(query) ||
              safeBox.contains(query);
          if (!matchesQuery) return false;
          if (_filterNonZero && !_hasPendingBalance(supplier)) return false;
          if (_onlyActive && !_isActive(supplier)) return false;
          if (_onlyClosingOffices && !_isClosingOffice(supplier)) return false;
          return true;
        })
        .toList(growable: false);

    filtered.sort((a, b) {
      int comparison;
      switch (_sortBy) {
        case 'code':
          comparison = _supplierCode(a).compareTo(_supplierCode(b));
          break;
        case 'cash':
          comparison = _cashBalance(a).compareTo(_cashBalance(b));
          break;
        case 'gold':
          comparison = _goldMainEquivalent(a).compareTo(_goldMainEquivalent(b));
          break;
        case 'tax':
          comparison = _supplierTaxNumber(a).compareTo(_supplierTaxNumber(b));
          break;
        case 'status':
          comparison = (_isActive(a) ? 1 : 0).compareTo(_isActive(b) ? 1 : 0);
          break;
        default:
          comparison = _supplierName(a).compareTo(_supplierName(b));
          break;
      }

      if (comparison == 0) {
        comparison = _supplierCode(a).compareTo(_supplierCode(b));
      }
      return _sortAscending ? comparison : -comparison;
    });

    setState(() {
      _filteredSuppliers = filtered;
    });
  }

  int get _activeFiltersCount {
    int count = 0;
    if (_searchController.text.trim().isNotEmpty) count++;
    if (_filterNonZero) count++;
    if (_onlyActive) count++;
    if (_onlyClosingOffices) count++;
    if (_sortBy != 'name' || !_sortAscending) count++;
    return count;
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _filterNonZero = false;
      _onlyActive = false;
      _onlyClosingOffices = false;
      _sortBy = 'name';
      _sortAscending = true;
    });
    _filterSuppliers();
  }

  ({String label, Color color}) _sideLabelForBalance(
    double value, {
    required bool isCash,
  }) {
    final eps = isCash ? _epsCash : _epsGold;
    if (value.abs() <= eps) {
      return (label: '—', color: Theme.of(context).hintColor);
    }
    if (value < 0) {
      return (
        label: widget.isArabic ? 'له' : 'Credit',
        color: app_theme.AppColors.error,
      );
    }
    return (
      label: widget.isArabic ? 'عليه' : 'Due',
      color: app_theme.AppColors.success,
    );
  }

  Widget _buildBalanceMetricCard({
    required IconData icon,
    required String title,
    required double value,
    required String formattedAbsValue,
    required String unit,
    required bool isCash,
  }) {
    final side = _sideLabelForBalance(value, isCash: isCash);
    final theme = Theme.of(context);
    final isZero = (isCash ? _epsCash : _epsGold) >= value.abs();
    final accent = isZero ? theme.hintColor : side.color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 14, color: accent),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                side.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: accent,
              ),
              children: [
                TextSpan(text: formattedAbsValue),
                TextSpan(
                  text: ' $unit',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalancePanel({
    required double cash,
    required double gold,
    required String cashFormatted,
    required String goldFormatted,
    Map<String, double> karatWeights = const {},
    bool isClosingOffice = false,
  }) {
    final theme = Theme.of(context);
    final nonZeroKarats = karatWeights.entries
        .where((e) => e.value.abs() > 0.0001)
        .toList();
    // Show chips when 2+ karats OR when it's a closing office with any karat
    final showChips =
        nonZeroKarats.isNotEmpty &&
        (nonZeroKarats.length >= 2 || isClosingOffice);
    final weightFmt = showChips
        ? NumberFormat('#,##0.00', Localizations.localeOf(context).toString())
        : null;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.16,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 15,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
              ),
              const SizedBox(width: 6),
              Text(
                widget.isArabic ? 'ملخص الرصيد' : 'Balance summary',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildBalanceMetricCard(
                  icon: Icons.payments_outlined,
                  title: widget.isArabic ? 'النقد' : 'Cash',
                  value: cash,
                  formattedAbsValue: cashFormatted,
                  unit: _currencySymbol,
                  isCash: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildBalanceMetricCard(
                  icon: Icons.scale_outlined,
                  title: widget.isArabic ? 'الذهب' : 'Gold',
                  value: gold,
                  formattedAbsValue: goldFormatted,
                  unit: widget.isArabic ? 'جم' : 'g',
                  isCash: false,
                ),
              ),
            ],
          ),
          if (showChips) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                for (int ki = 0; ki < nonZeroKarats.length; ki++) ...[
                  if (ki > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        final e = nonZeroKarats[ki];
                        final isNeg = e.value < 0;
                        final chipColor = isNeg
                            ? app_theme.AppColors.error
                            : const Color(0xFFC69214);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: chipColor.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: chipColor.withValues(alpha: 0.28),
                            ),
                          ),
                          child: Text(
                            '${e.key}: ${weightFmt!.format(e.value)}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: chipColor,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmAndDeleteSupplier(Map<String, dynamic> supplier) async {
    final isAr = widget.isArabic;
    final id = supplier['id'] as int?;
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isAr ? 'تأكيد الإجراء' : 'Confirm action'),
          content: Text(
            isAr
                ? 'سيتم حذف المورد إن لم يكن عليه أي أرصدة أو مسودات. إن كان لديه تاريخ حركات سيتم تعطيله بدلاً من الحذف.'
                : 'Supplier will be deleted if safe; otherwise it will be deactivated when history exists.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(isAr ? 'متابعة' : 'Continue'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      final result = await widget.api.deleteSupplier(id);
      if (!mounted) return;
      await _fetchSuppliers();

      final action = (result['action'] ?? '').toString();
      final msg = action == 'deactivated'
          ? (isAr ? 'تم تعطيل المورد بنجاح' : 'Supplier deactivated')
          : (isAr ? 'تم حذف المورد بنجاح' : 'Supplier deleted');

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'تعذر حذف المورد: $e' : 'Failed to delete supplier: $e',
          ),
        ),
      );
    }
  }

  Future<void> _navigateToAddSupplier({Map<String, dynamic>? supplier}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddSupplierScreen(api: widget.api, supplier: supplier),
      ),
    );
    if (result == true && mounted) {
      await _fetchSuppliers();
    }
  }

  Future<void> _openPurchaseInvoice(Map<String, dynamic> supplier) async {
    final supplierId = supplier['id'] as int?;
    if (supplierId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PurchaseInvoiceScreen(supplierId: supplierId),
      ),
    );
    if (mounted) await _fetchSuppliers();
  }

  Future<void> _openPaymentVoucher(Map<String, dynamic> supplier) async {
    final supplierId = supplier['id'] as int?;
    if (supplierId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddVoucherScreen(
          voucherType: 'payment',
          initialSupplierId: supplierId,
        ),
      ),
    );
    if (mounted) await _fetchSuppliers();
  }

  Future<void> _openSupplierLedger(Map<String, dynamic> supplier) async {
    final supplierId = supplier['id'] as int?;
    if (supplierId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SupplierLedgerScreen(
          api: widget.api,
          supplierId: supplierId,
          supplierName: _supplierName(supplier),
          isArabic: widget.isArabic,
        ),
      ),
    );
  }

  Future<void> _openSupplierSettlements(Map<String, dynamic> supplier) async {
    final supplierId = supplier['id'] as int?;
    if (supplierId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SupplierSettlementsScreen(
          api: widget.api,
          supplierId: supplierId,
          supplierName: _supplierName(supplier),
          isArabic: widget.isArabic,
        ),
      ),
    );
  }

  Future<void> _openSupplierStatement(Map<String, dynamic> supplier) async {
    final supplierId = supplier['id'] as int?;
    if (supplierId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountStatementScreen(
          accountId: supplierId,
          accountName: _supplierName(supplier),
          entityType: 'supplier',
        ),
      ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 360),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.58),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatisticsSection() {
    final localeName = Localizations.localeOf(context).toString();
    final moneyFmt = NumberFormat('#,##0.00', localeName);
    final weightFmt = NumberFormat('#,##0.000', localeName);

    final totalSuppliers = _filteredSuppliers.length;
    final activeSuppliers = _filteredSuppliers.where(_isActive).length;
    final suppliersWithBalance = _filteredSuppliers
        .where(_hasPendingBalance)
        .length;
    final totalCashCredit = _filteredSuppliers.fold<double>(0.0, (
      sum,
      supplier,
    ) {
      final value = _cashBalance(supplier);
      return value < 0 ? sum + (-value) : sum;
    });
    final totalGoldCredit = _filteredSuppliers.fold<double>(0.0, (
      sum,
      supplier,
    ) {
      final value = _goldMainEquivalent(supplier);
      return value < 0 ? sum + (-value) : sum;
    });

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _buildSummaryCard(
          title: widget.isArabic ? 'الموردون المطابقون' : 'Matching suppliers',
          value: '$totalSuppliers',
          subtitle: widget.isArabic
              ? 'بعد الفلاتر الحالية'
              : 'After current filters',
          icon: Icons.groups_2_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        _buildSummaryCard(
          title: widget.isArabic ? 'الموردون النشطون' : 'Active suppliers',
          value: '$activeSuppliers',
          subtitle: widget.isArabic
              ? 'جاهزون للحركة والشراء'
              : 'Ready for transactions',
          icon: Icons.verified_user_outlined,
          color: Colors.blue,
        ),
        _buildSummaryCard(
          title: widget.isArabic ? 'إجمالي النقد الدائن' : 'Total cash credit',
          value: moneyFmt.format(totalCashCredit),
          subtitle: widget.isArabic ? 'مستحق للموردين' : 'Due to suppliers',
          icon: Icons.payments_outlined,
          color: Colors.green,
        ),
        _buildSummaryCard(
          title: widget.isArabic
              ? 'إجمالي الذهب الدائن (مكافئ $_mainKarat)'
              : 'Total gold credit ($_mainKarat equiv)',
          value: weightFmt.format(totalGoldCredit),
          subtitle: widget.isArabic
              ? 'موردون بأرصدة وزنية'
              : 'Weighted supplier balances',
          icon: Icons.scale_outlined,
          color: const Color(0xFFD4A017),
        ),
        _buildSummaryCard(
          title: widget.isArabic ? 'موردون برصيد' : 'Suppliers with balance',
          value: '$suppliersWithBalance',
          subtitle: widget.isArabic ? 'نقدي أو ذهبي' : 'Cash or gold balances',
          icon: Icons.account_balance_wallet_outlined,
          color: Colors.teal,
        ),
      ],
    );
  }

  Widget _buildCollapsibleTopChrome() {
    final content = KeyedSubtree(
      key: _topChromeKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: _buildStatisticsSection(),
      ),
    );

    _measureTopChrome();

    if (_topChromeHeight <= 0) {
      return content;
    }

    final collapse = _topChromeCollapseOffset.clamp(0.0, _topChromeHeight);
    final visibleHeight = (_topChromeHeight - collapse).clamp(
      0.0,
      _topChromeHeight,
    );
    if (visibleHeight <= 0) {
      return const SizedBox.shrink();
    }

    return ClipRect(
      child: SizedBox(
        height: visibleHeight,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: _topChromeHeight,
          maxHeight: _topChromeHeight,
          child: Transform.translate(
            offset: Offset(0, -collapse),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildManagementToolbar() {
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
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: Text(
                        widget.isArabic ? 'برصيد فقط' : 'With balance',
                      ),
                      selected: _filterNonZero,
                      onSelected: (value) {
                        setState(() {
                          _filterNonZero = value;
                        });
                        _filterSuppliers();
                      },
                    ),
                    FilterChip(
                      label: Text(widget.isArabic ? 'نشط فقط' : 'Active only'),
                      selected: _onlyActive,
                      onSelected: (value) {
                        setState(() {
                          _onlyActive = value;
                        });
                        _filterSuppliers();
                      },
                    ),
                    FilterChip(
                      label: Text(
                        widget.isArabic ? 'مكاتب تسكير فقط' : 'Closing offices',
                      ),
                      selected: _onlyClosingOffices,
                      onSelected: (value) {
                        setState(() {
                          _onlyClosingOffices = value;
                        });
                        _filterSuppliers();
                      },
                    ),
                  ],
                ),
              ),
              if (_activeFiltersCount > 0)
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.close, size: 16),
                  label: Text(
                    widget.isArabic ? 'مسح الفلاتر' : 'Clear filters',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 420,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: widget.isArabic
                        ? 'ابحث بالاسم أو الكود أو الهاتف أو الرقم الضريبي أو الخزنة'
                        : 'Search by name, code, phone, tax or safe box',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchController.text.trim().isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _filterSuppliers();
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<String>(
                  value: _sortBy,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'الترتيب' : 'Sort by',
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'name',
                      child: Text(widget.isArabic ? 'الاسم' : 'Name'),
                    ),
                    DropdownMenuItem(
                      value: 'code',
                      child: Text(widget.isArabic ? 'الكود' : 'Code'),
                    ),
                    DropdownMenuItem(
                      value: 'cash',
                      child: Text(
                        widget.isArabic ? 'الرصيد النقدي' : 'Cash balance',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'gold',
                      child: Text(
                        widget.isArabic ? 'الرصيد الذهبي' : 'Gold balance',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'status',
                      child: Text(widget.isArabic ? 'الحالة' : 'Status'),
                    ),
                    DropdownMenuItem(
                      value: 'tax',
                      child: Text(
                        widget.isArabic ? 'الرقم الضريبي' : 'Tax number',
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _sortBy = value;
                    });
                    _filterSuppliers();
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _sortAscending = !_sortAscending;
                  });
                  _filterSuppliers();
                },
                icon: Icon(
                  _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18,
                ),
                label: Text(
                  _sortAscending
                      ? (widget.isArabic ? 'تصاعدي' : 'Ascending')
                      : (widget.isArabic ? 'تنازلي' : 'Descending'),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.55,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.isArabic
                      ? 'النتائج: ${_filteredSuppliers.length}'
                      : 'Results: ${_filteredSuppliers.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSupplierTag({
    required String label,
    required Color color,
    IconData? icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSupplierAction(
    String value,
    Map<String, dynamic> supplier,
  ) async {
    if (value == 'purchase') {
      await _openPurchaseInvoice(supplier);
    } else if (value == 'voucher') {
      await _openPaymentVoucher(supplier);
    } else if (value == 'statement') {
      await _openSupplierStatement(supplier);
    } else if (value == 'ledger') {
      await _openSupplierLedger(supplier);
    } else if (value == 'settlements') {
      await _openSupplierSettlements(supplier);
    } else if (value == 'edit') {
      await _navigateToAddSupplier(supplier: supplier);
    } else if (value == 'delete') {
      await _confirmAndDeleteSupplier(supplier);
    }
  }

  Widget _buildSupplierActions(Map<String, dynamic> supplier) {
    return PopupMenuButton<String>(
      tooltip: widget.isArabic ? 'الإجراءات' : 'Actions',
      onSelected: (value) => _handleSupplierAction(value, supplier),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'purchase',
          child: Text(widget.isArabic ? 'فاتورة شراء' : 'Purchase invoice'),
        ),
        PopupMenuItem(
          value: 'voucher',
          child: Text(widget.isArabic ? 'سند صرف' : 'Payment voucher'),
        ),
        PopupMenuItem(
          value: 'statement',
          child: Text(widget.isArabic ? 'كشف الحساب' : 'Statement'),
        ),
        PopupMenuItem(
          value: 'ledger',
          child: Text(widget.isArabic ? 'حركات المورد' : 'Supplier ledger'),
        ),
        PopupMenuItem(
          value: 'settlements',
          child: Text(widget.isArabic ? 'التسويات' : 'Settlements'),
        ),
        PopupMenuItem(
          value: 'edit',
          child: Text(widget.isArabic ? 'تعديل' : 'Edit'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(widget.isArabic ? 'حذف/تعطيل' : 'Delete/Deactivate'),
        ),
      ],
    );
  }

  Widget _buildSupplierCard(Map<String, dynamic> supplier) {
    final theme = Theme.of(context);
    final localeName = Localizations.localeOf(context).toString();
    final moneyFmt = NumberFormat('#,##0.00', localeName);
    final weightFmt = NumberFormat('#,##0.000', localeName);

    final supplierName = _supplierName(supplier);
    final supplierCode = _supplierCode(supplier);
    final phone = _supplierPhone(supplier);
    final tax = _supplierTaxNumber(supplier);
    final active = _isActive(supplier);
    final isClosingOffice = _isClosingOffice(supplier);
    final safeBoxName = _defaultSafeBoxName(supplier);
    final cash = _cashBalance(supplier);
    final gold = _goldMainEquivalent(supplier);
    final gold18k = _toDouble(supplier['balance_gold_18k']);
    final gold21k = _toDouble(supplier['balance_gold_21k']);
    final gold22k = _toDouble(supplier['balance_gold_22k']);
    final gold24k = _toDouble(supplier['balance_gold_24k']);
    final cashFormatted = moneyFmt.format(cash.abs());
    final goldFormatted = weightFmt.format(gold.abs());
    final karatWeights = {
      '18k': gold18k,
      '21k': gold21k,
      '22k': gold22k,
      '24k': gold24k,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openSupplierLedger(supplier),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 900;

              final detailsColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.business_outlined,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              supplierName.isEmpty
                                  ? (widget.isArabic ? 'بدون اسم' : 'Unnamed')
                                  : supplierName,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: active ? null : theme.disabledColor,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              supplierCode.isEmpty
                                  ? (widget.isArabic ? 'بدون كود' : 'No code')
                                  : supplierCode,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.62,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _buildSupplierActions(supplier),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildSupplierTag(
                        label: active
                            ? (widget.isArabic ? 'نشط' : 'Active')
                            : (widget.isArabic ? 'معطل' : 'Inactive'),
                        color: active ? Colors.green : Colors.grey,
                        icon: active
                            ? Icons.check_circle_outline
                            : Icons.block_outlined,
                      ),
                      if (isClosingOffice)
                        _buildSupplierTag(
                          label: widget.isArabic
                              ? 'مكتب تسكير'
                              : 'Closing office',
                          color: Colors.blue,
                          icon: Icons.apartment_outlined,
                        ),
                      if (safeBoxName.isNotEmpty)
                        _buildSupplierTag(
                          label: widget.isArabic
                              ? 'الخزنة: $safeBoxName'
                              : 'Safe box: $safeBoxName',
                          color: theme.colorScheme.primary,
                          icon: Icons.inventory_2_outlined,
                        ),
                    ],
                  ),
                  if (phone.isNotEmpty || tax.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        if (phone.isNotEmpty)
                          Text(
                            widget.isArabic
                                ? 'الهاتف: $phone'
                                : 'Phone: $phone',
                            style: theme.textTheme.bodyMedium,
                          ),
                        if (tax.isNotEmpty)
                          Text(
                            widget.isArabic
                                ? 'الرقم الضريبي: $tax'
                                : 'Tax: $tax',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.62,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              );

              final balancePanel = _buildBalancePanel(
                cash: cash,
                gold: gold,
                cashFormatted: cashFormatted,
                goldFormatted: goldFormatted,
                karatWeights: karatWeights,
                isClosingOffice: isClosingOffice,
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isWide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: detailsColumn),
                        const SizedBox(width: 12),
                        SizedBox(width: 360, child: balancePanel),
                      ],
                    )
                  else ...[
                    detailsColumn,
                    const SizedBox(height: 12),
                    balancePanel,
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _openSupplierStatement(supplier),
                          icon: const Icon(Icons.assessment_outlined, size: 18),
                          label: Text(
                            widget.isArabic ? 'كشف الحساب' : 'Statement',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openPaymentVoucher(supplier),
                          icon: const Icon(Icons.call_made_outlined, size: 18),
                          label: Text(widget.isArabic ? 'سند صرف' : 'Payment'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openPurchaseInvoice(supplier),
                          icon: const Icon(
                            Icons.shopping_cart_outlined,
                            size: 18,
                          ),
                          label: Text(widget.isArabic ? 'شراء' : 'Purchase'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCompactRow(Map<String, dynamic> supplier) {
    final theme = Theme.of(context);
    final localeName = Localizations.localeOf(context).toString();
    final moneyFmt = NumberFormat('#,##0.00', localeName);
    final weightFmt = NumberFormat('#,##0.000', localeName);

    final cash = _cashBalance(supplier);
    final gold = _goldMainEquivalent(supplier);
    final active = _isActive(supplier);

    return Material(
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: () => _openSupplierLedger(supplier),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _supplierName(supplier).isEmpty
                          ? (widget.isArabic ? 'بدون اسم' : 'Unnamed')
                          : _supplierName(supplier),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: active ? null : theme.disabledColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _supplierCode(supplier).isEmpty
                          ? (widget.isArabic ? 'بدون كود' : 'No code')
                          : _supplierCode(supplier),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.62,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: context.read<SettingsProvider>().buildText(
                  '${moneyFmt.format(cash)} $_currencySymbol',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Text(
                  '${weightFmt.format(gold)} ${widget.isArabic ? 'جم' : 'g'}',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFD4A017),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildSupplierActions(supplier),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.groups_2_outlined,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            _activeFiltersCount > 0
                ? (widget.isArabic
                      ? 'لا توجد نتائج مطابقة'
                      : 'No matching suppliers')
                : (widget.isArabic
                      ? 'لا يوجد موردون للعرض'
                      : 'No suppliers to display'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isArabic
                ? 'جرّب تعديل البحث أو إزالة بعض الفلاتر الحالية'
                : 'Try adjusting the search or clearing some filters',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.isArabic
                  ? 'تعذر تحميل الموردين'
                  : 'Unable to load suppliers',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(_error ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _fetchSuppliers,
              icon: const Icon(Icons.refresh),
              label: Text(widget.isArabic ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _filteredSuppliers.isEmpty) {
      return _buildErrorState();
    }

    if (_filteredSuppliers.isEmpty) {
      return _buildEmptyState();
    }

    if (_viewMode == _SuppliersViewMode.compact) {
      return RefreshIndicator(
        onRefresh: _fetchSuppliers,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          children: [
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.12),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.45),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Text(
                            widget.isArabic ? 'المورد' : 'Supplier',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            widget.isArabic ? 'نقد' : 'Cash',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: Text(
                            widget.isArabic ? 'ذهب' : 'Gold',
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 44),
                      ],
                    ),
                  ),
                  ..._filteredSuppliers.map(_buildCompactRow),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchSuppliers,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        itemCount: _filteredSuppliers.length,
        itemBuilder: (context, index) =>
            _buildSupplierCard(_filteredSuppliers[index]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'الموردين' : 'Suppliers'),
        actions: [
          IconButton(
            tooltip: _viewMode == _SuppliersViewMode.cards
                ? (widget.isArabic ? 'عرض مضغوط' : 'Compact view')
                : (widget.isArabic ? 'عرض البطاقات' : 'Cards view'),
            icon: Icon(
              _viewMode == _SuppliersViewMode.cards
                  ? Icons.table_rows_outlined
                  : Icons.view_agenda_outlined,
            ),
            onPressed: () {
              setState(() {
                _viewMode = _viewMode == _SuppliersViewMode.cards
                    ? _SuppliersViewMode.compact
                    : _SuppliersViewMode.cards;
              });
            },
          ),
          IconButton(
            tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _fetchSuppliers,
          ),
          IconButton(
            tooltip: widget.isArabic ? 'إضافة مورد' : 'Add supplier',
            icon: const Icon(Icons.add),
            onPressed: () => _navigateToAddSupplier(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildCollapsibleTopChrome(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildManagementToolbar(),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }
}
