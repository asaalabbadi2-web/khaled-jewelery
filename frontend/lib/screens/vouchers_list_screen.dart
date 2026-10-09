import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:excel/excel.dart' as excel;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:share_plus/share_plus.dart';
import '../api_service.dart';
import 'clearing_settlement_screen.dart';
import 'voucher_details_screen.dart';
import 'add_voucher_screen.dart';
import '../theme/app_theme.dart' as theme;
import '../providers/auth_provider.dart';
import '../widgets/cancelled_vouchers_bar.dart';
import '../widgets/widgets.dart';
import 'package:provider/provider.dart';

class VouchersListScreen extends StatefulWidget {
  const VouchersListScreen({super.key});

  @override
  State<VouchersListScreen> createState() => _VouchersListScreenState();
}

enum _VoucherListView { table, cards }

class _VouchersListScreenState extends State<VouchersListScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _voucherTableHorizontalController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final GlobalKey _toolbarKey = GlobalKey();

  List<dynamic> _vouchers = [];
  Map<String, dynamic> _currentSummary = const {};
  List<String> _availableParties = const [];
  List<String> _availableCreators = const [];
  bool _isLoading = true;
  String? _error;
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalVouchers = 0;
  int _perPage = 20;
  Timer? _debounce;

  // Filters
  String _selectedType = 'all'; // all, receipt, payment, adjustment
  String _selectedStatus = 'all';

  // Cancelled vouchers: hidden by default when no status is chosen (the
  // owner, 9 Oct 2026); the bar above the list shows them.
  bool _includeCancelled = false;
  int _cancelledCount = 0;
  bool _cancelledHidden = false;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _searchQuery = '';
  String _selectedSearchType = 'all';
  String? _selectedCreator;
  String? _selectedParty;
  String _sortBy = 'date';
  bool _sortAscending = false;
  _VoucherListView _viewMode = _VoucherListView.table;
  double _toolbarHeight = 104; // +8 safety margin, see _measureToolbarHeight

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'ar');
  final NumberFormat _goldFormat = NumberFormat('#,##0.000', 'ar');

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    _searchController.addListener(_onSearchChanged);

    // Avoid 403 spam for users without vouchers permissions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (!auth.hasPermission('vouchers.view')) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _error = 'ليس لديك صلاحية لعرض السندات';
        });
        return;
      }
      _loadVouchers();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    _voucherTableHorizontalController.dispose();
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _measureToolbarHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _toolbarKey.currentContext;
      if (context == null) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox) return;
      // Small safety margin for sub-pixel rounding only -- safe here
      // because the measured child is wrapped in an OverflowBox (see
      // _buildPinnedToolbarSliver), so this always reflects the content's
      // true natural height, not whatever _toolbarHeight currently is.
      const heightSafetyMargin = 8.0;
      final measuredHeight = renderObject.size.height + heightSafetyMargin;
      if (measuredHeight <= 0) return;
      if ((measuredHeight - _toolbarHeight).abs() < 0.5) return;
      setState(() {
        _toolbarHeight = measuredHeight;
      });
    });
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (_searchQuery != _searchController.text) {
        setState(() {
          _searchQuery = _searchController.text;
          _currentPage = 1;
        });
        _loadVouchers(page: 1);
      }
    });
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) {
      setState(() {
        switch (_tabController.index) {
          case 0:
            _selectedType = 'all';
            break;
          case 1:
            _selectedType = 'receipt';
            break;
          case 2:
            _selectedType = 'payment';
            break;
          case 3:
            _selectedType = 'adjustment';
            break;
        }
        _currentPage = 1;
      });
      _loadVouchers(page: 1);
    }
  }

  Future<void> _loadVouchers({int page = 1}) async {
    setState(() {
      _isLoading = true;
      if (page == 1) {
        _error = null;
      }
    });

    try {
      final data = await _apiService.getVouchers(
        page: page,
        perPage: _perPage,
        type: _selectedType,
        status: _selectedStatus,
        dateFrom: _dateFrom?.toIso8601String(),
        dateTo: _dateTo?.toIso8601String(),
        search: _searchQuery,
        searchType: _selectedSearchType,
        creator: _selectedCreator,
        party: _selectedParty,
        sortBy: _sortBy,
        sortOrder: _sortAscending ? 'asc' : 'desc',
        includeCancelled: _includeCancelled,
      );

      if (!mounted) return;

      final cancelled = data['cancelled_hidden'] as Map<String, dynamic>?;
      final vouchers = data['vouchers'] is List
          ? List<dynamic>.from(data['vouchers'] as List)
          : <dynamic>[];
      final summary = data['current_summary'] is Map
          ? Map<String, dynamic>.from(data['current_summary'] as Map)
          : <String, dynamic>{};

      final availableParties =
          (data['available_parties'] as List?)
              ?.whereType<Map>()
              .map((entry) => (entry['name'] ?? '').toString().trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList() ??
          <String>[];
      final availableCreators =
          (data['available_creators'] as List?)
              ?.whereType<Map>()
              .map((entry) => (entry['name'] ?? '').toString().trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList() ??
          <String>[];
      availableParties.sort();
      availableCreators.sort();

      setState(() {
        _vouchers = vouchers;
        _cancelledCount = (cancelled?['count'] as num?)?.toInt() ?? 0;
        _cancelledHidden = cancelled?['hidden'] == true;
        _currentPage = (data['current_page'] as num?)?.toInt() ?? page;
        _totalPages = ((data['pages'] as num?)?.toInt() ?? 1).clamp(1, 999999);
        _totalVouchers = (data['total'] as num?)?.toInt() ?? vouchers.length;
        _perPage = (data['per_page'] as num?)?.toInt() ?? _perPage;
        _currentSummary = summary;
        _availableParties = availableParties;
        _availableCreators = availableCreators;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    await _loadVouchers();
  }

  Future<void> _cancelVoucher(int id) async {
    String? reason;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء السند'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('الرجاء إدخال سبب الإلغاء:'),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                hintText: 'سبب الإلغاء',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => reason = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('إلغاء السند'),
          ),
        ],
      ),
    );

    if (confirm == true && reason != null && reason!.isNotEmpty) {
      try {
        await _apiService.cancelVoucher(id, reason!);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم إلغاء السند بنجاح')));
        _refresh();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الإلغاء: $e')));
      }
    } else if (confirm == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب إدخال سبب الإلغاء')));
    }
  }

  Future<void> _deleteVoucher(int id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف السند'),
        content: const Text(
          'هل أنت متأكد من رغبتك في حذف هذا السند نهائياً؟ هذا الإجراء لا يمكن التراجع عنه.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _apiService.deleteVoucher(id);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حذف السند بنجاح')));
        _refresh();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الحذف: $e')));
      }
    }
  }

  Future<void> _approveVoucher(int id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد السند'),
        content: const Text(
          'هل تريد اعتماد (ترحيل) هذا السند الآن؟ سيتم إنشاء قيد محاسبي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('اعتماد'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _apiService.approveVoucher(id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم اعتماد السند')));
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('خطأ في اعتماد السند: $e')));
    }
  }

  Future<void> _approveAllPending() async {
    final pending = _vouchers.where((v) {
      final status = (v['status'] ?? '').toString();
      return status == 'pending';
    }).toList();

    if (pending.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد سندات معلقة للاعتماد')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد الكل'),
        content: Text(
          'هل تريد اعتماد ${pending.length} سند الآن؟ سيتم إنشاء قيود محاسبية.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('اعتماد'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: const AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('جاري اعتماد السندات...')),
            ],
          ),
        ),
      ),
    );

    int success = 0;
    int failed = 0;

    for (final v in pending) {
      try {
        await _apiService.approveVoucher(v['id']);
        success += 1;
      } catch (_) {
        failed += 1;
      }
    }

    // Close progress
    if (mounted) Navigator.pop(context);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تم اعتماد $success من ${pending.length} سند. فشل: $failed',
        ),
      ),
    );

    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);

    return Scaffold(
      backgroundColor: themeData.scaffoldBackgroundColor,
      appBar: _buildAppBar(themeData),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _withAlpha(theme.AppColors.lightGold, 0.32),
              themeData.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: _buildBodyContent(themeData),
      ),
      bottomNavigationBar: _buildBottomQuickActions(themeData),
    );
  }

  PreferredSizeWidget _buildAppBar(ThemeData themeData) {
    final Color appBarForeground = Colors.black87;

    return AppBar(
      elevation: 0,
      titleSpacing: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: appBarForeground,
      iconTheme: IconThemeData(color: appBarForeground),
      actionsIconTheme: IconThemeData(color: appBarForeground),
      flexibleSpace: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.AppColors.primaryGold, theme.AppColors.darkGold],
            begin: _gradientBegin(),
            end: _gradientEnd(),
          ),
        ),
      ),
      leading: IconButton(
        icon: Icon(Icons.arrow_back, color: appBarForeground),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: SafeArea(
        top: true,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'السندات',
                style: themeData.textTheme.headlineSmall?.copyWith(
                  color: appBarForeground,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                'تحكم كامل بسندات القبض والصرف',
                style: themeData.textTheme.bodyMedium?.copyWith(
                  color: _withAlpha(Colors.black, 0.65),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(58 + MediaQuery.of(context).padding.top),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _withAlpha(Colors.white, 0.22),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: TabBar(
                controller: _tabController,
                labelColor: theme.AppColors.darkGold,
                unselectedLabelColor: _withAlpha(Colors.black, 0.68),
                labelStyle: themeData.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: themeData.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                indicator: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.AppColors.lightGold,
                      theme.AppColors.darkGold,
                    ],
                    begin: _gradientBegin(),
                    end: _gradientEnd(),
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: _withAlpha(Colors.black, 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                indicatorPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                tabAlignment: TabAlignment.fill,
                tabs: [
                  Tab(
                    icon: Icon(Icons.list_alt, size: 17),
                    height: 42,
                    text: 'الكل',
                  ),
                  Tab(
                    icon: Icon(Icons.call_received, size: 17),
                    height: 42,
                    text: 'قبض',
                  ),
                  Tab(
                    icon: Icon(Icons.call_made, size: 17),
                    height: 42,
                    text: 'صرف',
                  ),
                  Tab(
                    icon: Icon(Icons.balance, size: 17),
                    height: 42,
                    text: 'تسوية',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: _viewMode == _VoucherListView.table
              ? 'عرض بطاقات'
              : 'عرض جدول',
          icon: Icon(
            _viewMode == _VoucherListView.table
                ? Icons.view_agenda_outlined
                : Icons.table_rows_outlined,
          ),
          onPressed: () {
            setState(() {
              _viewMode = _viewMode == _VoucherListView.table
                  ? _VoucherListView.cards
                  : _VoucherListView.table;
            });
          },
        ),
        IconButton(
          tooltip: 'تحديث',
          icon: const Icon(Icons.refresh),
          onPressed: _refresh,
        ),
        IconButton(
          tooltip: 'اعتماد الكل',
          icon: const Icon(Icons.done_all_outlined),
          onPressed: _approveAllPending,
        ),
        PopupMenuButton<String>(
          tooltip: 'تصدير',
          icon: const Icon(Icons.file_download_outlined),
          onSelected: (value) {
            if (value == 'pdf') {
              _exportToPdf();
            } else if (value == 'excel') {
              _exportToExcel();
            }
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'pdf',
              child: Row(
                children: [
                  Icon(Icons.picture_as_pdf, color: theme.AppColors.error),
                  const SizedBox(width: 8),
                  const Text('تصدير PDF'),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'excel',
              child: Row(
                children: [
                  Icon(Icons.table_chart, color: theme.AppColors.success),
                  const SizedBox(width: 8),
                  const Text('تصدير Excel'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBodyContent(ThemeData themeData) {
    if (_isLoading && _vouchers.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _buildErrorState(themeData);
    }

    return NestedScrollView(
      controller: _scrollController,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.45,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeaderSection(themeData),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _buildSummarySection(themeData),
                ),
                if (_cancelledCount > 0 && _selectedStatus == 'all')
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: CancelledVouchersBar(
                      count: _cancelledCount,
                      hidden: _cancelledHidden,
                      busy: _isLoading,
                      withReversals: false,
                      onToggle: () {
                        setState(() => _includeCancelled = !_includeCancelled);
                        _loadVouchers();
                      },
                    ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        _buildPinnedToolbarSliver(themeData),
      ],
      body: _viewMode == _VoucherListView.table
          ? Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                children: [
                  Expanded(
                    child: _vouchers.isEmpty
                        ? _buildEmptyState(themeData)
                        : _buildVoucherTable(themeData),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: 8,
                      bottom: MediaQuery.of(context).padding.bottom + 8,
                    ),
                    child: _buildPaginationStrip(themeData),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              color: theme.AppColors.primaryGold,
              displacement: 80,
              child: ListView(
                primary: true,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  left: 16,
                  top: 8,
                  right: 16,
                  bottom: MediaQuery.of(context).padding.bottom + 24,
                ),
                children: [
                  if (_isLoading && _vouchers.isNotEmpty)
                    _buildPaginationLoader(),
                  if (_vouchers.isEmpty)
                    _buildEmptyState(themeData)
                  else
                    _buildResultsSection(themeData),
                  _buildPaginationStrip(themeData),
                ],
              ),
            ),
    );
  }

  Widget _buildPinnedToolbarSliver(ThemeData themeData) {
    _measureToolbarHeight();
    return SliverPersistentHeader(
      pinned: true,
      floating: true,
      delegate: PinnedHeaderDelegate(
        height: _toolbarHeight,
        backgroundColor: themeData.scaffoldBackgroundColor,
        // OverflowBox lets the measured child report its own true natural
        // height instead of being forced to exactly _toolbarHeight (the
        // sliver gives its child a *tight* height constraint -- min==max).
        // Without this, _toolbarKey's RenderBox always measures back
        // whatever _toolbarHeight already is, so any added margin (or
        // rounding) keeps re-triggering setState with height+margin,
        // forever -- the toolbar growing without bound on every frame
        // ("auto-expanding"/sliding down), which is what a fixed +8px
        // margin here previously caused.
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: 0,
          maxHeight: double.infinity,
          child: KeyedSubtree(
            key: _toolbarKey,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _buildManagementToolbar(themeData),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(ThemeData themeData) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 52, color: theme.AppColors.error),
            const SizedBox(height: 16),
            Text(
              'حدث خطأ أثناء تحميل السندات',
              style: themeData.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              style: themeData.textTheme.bodyMedium?.copyWith(
                color: _withAlpha(themeData.colorScheme.onSurface, 0.65),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderSection(ThemeData themeData) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.AppColors.primaryGold, theme.AppColors.mediumGold],
          begin: _gradientBegin(),
          end: _gradientEnd(),
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_buildStatusFilters(themeData)],
      ),
    );
  }

  Widget _buildToolbarSearchField(ThemeData themeData) {
    final searchType = _selectedSearchType;

    return SizedBox(
      width: 430,
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) {
          _debounce?.cancel();
          setState(() {
            _searchQuery = _searchController.text;
            _currentPage = 1;
          });
          _loadVouchers(page: 1);
        },
        decoration: InputDecoration(
          hintText: _searchHint(searchType),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          hintStyle: themeData.textTheme.bodyMedium?.copyWith(
            color: _withAlpha(themeData.colorScheme.onSurface, 0.42),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 164),
          prefixIcon: Padding(
            padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search, color: theme.AppColors.darkGold, size: 18),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: 'نوع البحث',
                  initialValue: searchType,
                  onSelected: (value) async {
                    setState(() {
                      _selectedSearchType = value;
                      _currentPage = 1;
                    });
                    await _loadVouchers(page: 1);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(value: 'all', child: Text('الكل')),
                    PopupMenuItem<String>(
                      value: 'number',
                      child: Text('رقم السند'),
                    ),
                    PopupMenuItem<String>(value: 'party', child: Text('الطرف')),
                    PopupMenuItem<String>(
                      value: 'description',
                      child: Text('البيان'),
                    ),
                    PopupMenuItem<String>(
                      value: 'amount',
                      child: Text('المبلغ'),
                    ),
                    PopupMenuItem<String>(
                      value: 'reference',
                      child: Text('المرجع'),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: themeData.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: themeData.colorScheme.outline.withValues(
                          alpha: 0.16,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _searchTypeLabel(searchType),
                          style: themeData.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _withAlpha(
                              themeData.colorScheme.onSurface,
                              0.78,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: _withAlpha(
                            themeData.colorScheme.onSurface,
                            0.65,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'مسح البحث',
                  onPressed: _clearSearch,
                ),
        ),
      ),
    );
  }

  Widget _buildStatusFilters(ThemeData themeData) {
    final statuses = [
      {'value': 'all', 'label': 'كل الحالات', 'icon': Icons.all_inclusive},
      {
        'value': 'pending',
        'label': 'معلق',
        'icon': Icons.pending_actions_outlined,
      },
      {'value': 'approved', 'label': 'معتمد', 'icon': Icons.verified_outlined},
      {'value': 'cancelled', 'label': 'ملغى', 'icon': Icons.cancel_outlined},
      {'value': 'rejected', 'label': 'مرفوض', 'icon': Icons.gpp_bad_outlined},
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: statuses.map((status) {
        final bool selected = _selectedStatus == status['value'];
        // Make the label text gold for all status chips per request.
        final Color foreground = theme.AppColors.darkGold;
        final Color background = selected
            ? Colors.white
            : _withAlpha(Colors.white, 0.12);

        return ChoiceChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                status['icon'] as IconData,
                size: 16,
                color: selected
                    ? theme.AppColors.darkGold
                    : _withAlpha(theme.AppColors.darkGold, 0.9),
              ),
              const SizedBox(width: 6),
              Text(
                status['label'] as String,
                style: themeData.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
          selected: selected,
          onSelected: (value) {
            if (!value || _selectedStatus == status['value']) return;
            setState(() {
              _selectedStatus = status['value'] as String;
              _currentPage = 1;
            });
            _loadVouchers(page: 1);
          },
          backgroundColor: background,
          selectedColor: Colors.white,
          pressElevation: 0,
          elevation: 0,
          labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          shape: StadiumBorder(
            side: BorderSide(
              color: _withAlpha(Colors.white, selected ? 0 : 0.3),
            ),
          ),
        );
      }).toList(),
    );
  }

  int get _activeFiltersCount {
    int count = 0;
    if (_searchController.text.isNotEmpty) count++;
    if (_selectedSearchType != 'all') count++;
    if (_selectedStatus != 'all') count++;
    if (_selectedParty != null) count++;
    if (_selectedCreator != null) count++;
    if (_dateFrom != null || _dateTo != null) count++;
    if (_sortBy != 'date' || _sortAscending) count++;
    return count;
  }

  List<int> _buildPageNumbers() {
    if (_totalPages <= 7) {
      return List.generate(_totalPages, (i) => i + 1);
    }
    final pages = <int>[1];
    final start = (_currentPage - 2).clamp(2, _totalPages - 1);
    final end = (_currentPage + 2).clamp(2, _totalPages - 1);
    if (start > 2) pages.add(-1);
    for (int page = start; page <= end; page++) {
      pages.add(page);
    }
    if (end < _totalPages - 1) pages.add(-1);
    pages.add(_totalPages);
    return pages;
  }

  Widget _buildSummarySection(ThemeData themeData) {
    final totalVouchers =
        (_currentSummary['total_vouchers'] as num?)?.toInt() ?? _totalVouchers;
    final totalCash = _toDouble(_currentSummary['total_cash']) ?? 0.0;
    final totalGold =
        _toDouble(_currentSummary['total_gold_main_karat']) ??
        _toDouble(_currentSummary['total_gold']) ??
        0.0;
    final pendingCount =
        (_currentSummary['pending_count'] as num?)?.toInt() ?? 0;

    final cards = [
      _buildSummaryCard(
        themeData,
        title: 'إجمالي السندات',
        value: '$totalVouchers',
        subtitle: 'بعد الفلاتر الحالية',
        icon: Icons.receipt_long_outlined,
        color: theme.AppColors.darkGold,
      ),
      _buildSummaryCard(
        themeData,
        title: 'إجمالي النقد',
        value: '${_currencyFormat.format(totalCash)} ر.س',
        subtitle: 'لكل النتائج المطابقة',
        icon: Icons.payments_outlined,
        color: const Color(0xFF2F80ED),
      ),
      _buildSummaryCard(
        themeData,
        title: 'إجمالي الذهب',
        value: '${_goldFormat.format(totalGold)} غ',
        subtitle: 'بالمكافئ على العيار الرئيسي',
        icon: Icons.scale_outlined,
        color: const Color(0xFFD4A017),
        emphasize: true,
      ),
      _buildSummaryCard(
        themeData,
        title: 'سندات معلقة',
        value: '$pendingCount',
        subtitle: 'جاهزة للمراجعة والاعتماد',
        icon: Icons.pending_actions_outlined,
        color: theme.AppColors.info,
      ),
    ];

    final isCompact = MediaQuery.sizeOf(context).width < 700;
    if (!isCompact) {
      return Wrap(spacing: 10, runSpacing: 10, children: cards);
    }

    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) => cards[index],
      ),
    );
  }

  Widget _buildSummaryCard(
    ThemeData themeData, {
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool emphasize = false,
  }) {
    final isCompact = MediaQuery.sizeOf(context).width < 700;

    final card = Container(
      padding: EdgeInsets.all(isCompact ? 10 : 14),
      decoration: BoxDecoration(
        gradient: emphasize
            ? LinearGradient(
                colors: [
                  _withAlpha(color, 0.14),
                  themeData.colorScheme.surface,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: emphasize ? null : themeData.colorScheme.surface,
        borderRadius: BorderRadius.circular(isCompact ? 14 : 18),
        border: Border.all(color: _withAlpha(color, emphasize ? 0.28 : 0.16)),
        boxShadow: [
          BoxShadow(
            color: _withAlpha(Colors.black, 0.06),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Container(
            width: isCompact ? 30 : 40,
            height: isCompact ? 30 : 40,
            decoration: BoxDecoration(
              color: _withAlpha(color, 0.12),
              borderRadius: BorderRadius.circular(isCompact ? 9 : 12),
            ),
            child: Icon(icon, color: color, size: isCompact ? 15 : 20),
          ),
          SizedBox(width: isCompact ? 8 : 10),
          isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: themeData.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      value,
                      style: themeData.textTheme.titleSmall?.copyWith(
                        fontWeight: emphasize
                            ? FontWeight.w900
                            : FontWeight.w800,
                        color: color,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                )
              : Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: themeData.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        style: themeData.textTheme.titleMedium?.copyWith(
                          fontWeight: emphasize
                              ? FontWeight.w900
                              : FontWeight.w800,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: themeData.textTheme.bodySmall?.copyWith(
                          color: _withAlpha(
                            themeData.colorScheme.onSurface,
                            0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ],
      ),
    );

    if (isCompact) {
      return SizedBox(width: 170, child: card);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 250),
      child: card,
    );
  }

  Widget _buildManagementToolbar(ThemeData themeData) {
    final isCompact = MediaQuery.sizeOf(context).width < 700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: themeData.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: themeData.colorScheme.outline.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFilterRow(
            isCompact: isCompact,
            children: [
              Text(
                'إدارة النتائج: $_totalVouchers سجل',
                style: themeData.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: themeData.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'الفلاتر النشطة: $_activeFiltersCount',
                  style: themeData.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _withAlpha(themeData.colorScheme.onSurface, 0.72),
                  ),
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
          const SizedBox(height: 10),
          _buildFilterRow(
            isCompact: isCompact,
            children: [
              _buildToolbarSearchField(themeData),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  value: _selectedParty,
                  decoration: _compactFilterDecoration('الطرف'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('الكل'),
                    ),
                    ..._availableParties.map(
                      (party) => DropdownMenuItem<String?>(
                        value: party,
                        child: SizedBox(
                          width: 180,
                          child: Text(
                            party,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _selectedParty = value;
                      _currentPage = 1;
                    });
                    await _loadVouchers(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  value: _selectedCreator,
                  decoration: _compactFilterDecoration('المنشئ'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('الكل'),
                    ),
                    ..._availableCreators.map(
                      (creator) => DropdownMenuItem<String?>(
                        value: creator,
                        child: SizedBox(
                          width: 180,
                          child: Text(
                            creator,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _selectedCreator = value;
                      _currentPage = 1;
                    });
                    await _loadVouchers(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 160,
                child: DropdownButtonFormField<String>(
                  value: _sortBy,
                  isExpanded: true,
                  decoration: _compactFilterDecoration('الترتيب'),
                  items: const [
                    DropdownMenuItem(value: 'date', child: Text('التاريخ')),
                    DropdownMenuItem(value: 'number', child: Text('رقم السند')),
                    DropdownMenuItem(value: 'party', child: Text('الطرف')),
                    DropdownMenuItem(value: 'creator', child: Text('المنشئ')),
                    DropdownMenuItem(
                      value: 'cash',
                      child: Text('المبلغ النقدي'),
                    ),
                    DropdownMenuItem(value: 'gold', child: Text('الذهب')),
                    DropdownMenuItem(value: 'status', child: Text('الحالة')),
                    DropdownMenuItem(value: 'type', child: Text('النوع')),
                    DropdownMenuItem(value: 'reference', child: Text('المرجع')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() {
                      _sortBy = value;
                      _currentPage = 1;
                    });
                    await _loadVouchers(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 100,
                child: DropdownButtonFormField<int>(
                  value: _perPage,
                  decoration: _compactFilterDecoration('الصفوف'),
                  items: const [10, 20, 50, 100]
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) async {
                    if (value == null || value == _perPage) return;
                    setState(() {
                      _perPage = value;
                      _currentPage = 1;
                    });
                    await _loadVouchers(page: 1);
                  },
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  minimumSize: const Size(0, 44),
                ),
                onPressed: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDateRange: _dateFrom != null && _dateTo != null
                        ? DateTimeRange(start: _dateFrom!, end: _dateTo!)
                        : null,
                  );
                  if (picked == null) return;
                  setState(() {
                    _dateFrom = picked.start;
                    _dateTo = picked.end;
                    _currentPage = 1;
                  });
                  await _loadVouchers(page: 1);
                },
                icon: const Icon(Icons.date_range_outlined, size: 18),
                label: Text(
                  _dateFrom == null || _dateTo == null
                      ? 'من - إلى'
                      : '${DateFormat('dd/MM/yyyy').format(_dateFrom!)} - ${DateFormat('dd/MM/yyyy').format(_dateTo!)}',
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  minimumSize: const Size(0, 44),
                ),
                onPressed: () async {
                  setState(() {
                    _sortAscending = !_sortAscending;
                    _currentPage = 1;
                  });
                  await _loadVouchers(page: 1);
                },
                icon: Icon(
                  _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18,
                ),
                label: Text(_sortAscending ? 'تصاعدي' : 'تنازلي'),
              ),
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

  InputDecoration _compactFilterDecoration(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  Widget _buildResultsSection(ThemeData themeData) {
    if (_viewMode == _VoucherListView.cards) {
      return Column(
        children: _vouchers
            .map(
              (voucher) => _buildVoucherCard(
                Map<String, dynamic>.from(voucher as Map),
                themeData,
              ),
            )
            .toList(),
      );
    }

    return _buildVoucherTable(themeData);
  }

  Widget _buildVoucherTable(ThemeData themeData) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = <String, double>{
          'number': 138,
          'party': 168,
          'creator': 112,
          'date': 116,
          'type': 100,
          'cash': 146,
          'gold': 156,
          'status': 108,
          'reference': 146,
          'actions': 56,
        };
        final viewportWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 36;
        final tableContentWidth = widths.values.fold<double>(
          0,
          (sum, width) => sum + width,
        );
        final tableWidth = math.max(viewportWidth, tableContentWidth);
        final extraWidth = tableWidth - tableContentWidth;
        if (extraWidth > 0) {
          widths['party'] = widths['party']! + (extraWidth * 0.45);
          widths['reference'] = widths['reference']! + (extraWidth * 0.35);
          widths['creator'] = widths['creator']! + (extraWidth * 0.20);
        }

        final tableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 480.0;

        return Container(
          decoration: BoxDecoration(
            color: themeData.colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: themeData.colorScheme.outline.withValues(alpha: 0.12),
            ),
          ),
          child: SingleChildScrollView(
            controller: _voucherTableHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              height: tableHeight,
              child: Column(
                children: [
                  _buildVoucherStickyHeader(themeData, widths),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      color: theme.AppColors.primaryGold,
                      child: ListView.builder(
                        primary: true,
                        padding: EdgeInsets.zero,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _vouchers.length,
                        itemBuilder: (context, rowIndex) {
                          final voucher = Map<String, dynamic>.from(
                            _vouchers[rowIndex] as Map,
                          );
                          return _buildVoucherStickyRow(
                            themeData: themeData,
                            voucher: voucher,
                            rowIndex: rowIndex,
                            widths: widths,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVoucherStickyHeader(
    ThemeData themeData,
    Map<String, double> widths,
  ) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: themeData.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        border: Border(
          bottom: BorderSide(
            color: themeData.colorScheme.outline.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Row(
        children: [
          _buildVoucherHeaderCell(
            label: 'رقم',
            width: widths['number']!,
            onTap: () =>
                _changeSort('number', !(_sortBy == 'number' && _sortAscending)),
            isActive: _sortBy == 'number',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'الطرف',
            width: widths['party']!,
            onTap: () =>
                _changeSort('party', !(_sortBy == 'party' && _sortAscending)),
            isActive: _sortBy == 'party',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'المنشئ',
            width: widths['creator']!,
            onTap: () => _changeSort(
              'creator',
              !(_sortBy == 'creator' && _sortAscending),
            ),
            isActive: _sortBy == 'creator',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'التاريخ',
            width: widths['date']!,
            onTap: () =>
                _changeSort('date', !(_sortBy == 'date' && _sortAscending)),
            isActive: _sortBy == 'date',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'النوع',
            width: widths['type']!,
            onTap: () =>
                _changeSort('type', !(_sortBy == 'type' && _sortAscending)),
            isActive: _sortBy == 'type',
            ascending: _sortAscending,
          ),
          _buildVoucherMetricHeaderCell(
            label: 'النقد',
            unit: 'ر.س',
            width: widths['cash']!,
            icon: Icons.payments_outlined,
            color: const Color(0xFF2F80ED),
            onTap: () =>
                _changeSort('cash', !(_sortBy == 'cash' && _sortAscending)),
            isActive: _sortBy == 'cash',
            ascending: _sortAscending,
          ),
          _buildVoucherMetricHeaderCell(
            label: 'وزن الذهب',
            unit: 'غ',
            width: widths['gold']!,
            icon: Icons.scale_outlined,
            color: const Color(0xFFD4A017),
            onTap: () =>
                _changeSort('gold', !(_sortBy == 'gold' && _sortAscending)),
            isActive: _sortBy == 'gold',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'الحالة',
            width: widths['status']!,
            onTap: () =>
                _changeSort('status', !(_sortBy == 'status' && _sortAscending)),
            isActive: _sortBy == 'status',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: 'المرجع',
            width: widths['reference']!,
            onTap: () => _changeSort(
              'reference',
              !(_sortBy == 'reference' && _sortAscending),
            ),
            isActive: _sortBy == 'reference',
            ascending: _sortAscending,
          ),
          _buildVoucherHeaderCell(
            label: '⋮',
            width: widths['actions']!,
            alignment: Alignment.center,
          ),
        ],
      ),
    );
  }

  Widget _buildVoucherStickyRow({
    required ThemeData themeData,
    required Map<String, dynamic> voucher,
    required int rowIndex,
    required Map<String, double> widths,
  }) {
    final status = (voucher['status'] ?? 'pending').toString();
    final statusVisuals = _resolveVoucherStatusVisuals(status);
    final visuals = _resolveVoucherVisuals(
      (voucher['voucher_type'] ?? '').toString(),
    );

    return Material(
      color: rowIndex.isEven
          ? _withAlpha(themeData.colorScheme.surfaceContainerHighest, 0.14)
          : themeData.colorScheme.surface,
      child: InkWell(
        onTap: () => _navigateToVoucherDetails((voucher['id'] as num).toInt()),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: themeData.colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
          ),
          child: Row(
            children: [
              _buildVoucherBodyCell(
                width: widths['number']!,
                child: Text(
                  (voucher['voucher_number'] ?? '—').toString(),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: themeData.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: themeData.colorScheme.primary,
                  ),
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['party']!,
                child: Text(
                  _resolveVoucherPartyName(voucher).isEmpty
                      ? '—'
                      : _resolveVoucherPartyName(voucher),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: themeData.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['creator']!,
                child: Text(
                  _resolveVoucherCreatorName(voucher),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: themeData.textTheme.bodySmall,
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['date']!,
                child: Text(
                  _formatDate(voucher['date']),
                  textAlign: TextAlign.center,
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['type']!,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(visuals.icon, size: 16, color: visuals.color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        visuals.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              _buildVoucherMetricValueCell(
                width: widths['cash']!,
                value: _formatCurrency(voucher['amount_cash']) ?? '—',
                icon: Icons.payments_outlined,
                color: const Color(0xFF2F80ED),
                emphasize: false,
              ),
              _buildVoucherMetricValueCell(
                width: widths['gold']!,
                value:
                    _formatPrimaryGoldDisplay(voucher) ??
                    '—',
                icon: Icons.scale_outlined,
                color: const Color(0xFFD4A017),
                emphasize: true,
              ),
              _buildVoucherBodyCell(
                width: widths['status']!,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _withAlpha(statusVisuals.color, 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusVisuals.label,
                    style: themeData.textTheme.bodySmall?.copyWith(
                      color: statusVisuals.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['reference']!,
                child: Text(
                  _buildVoucherReferenceLabel(voucher),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: themeData.textTheme.bodySmall,
                ),
              ),
              _buildVoucherBodyCell(
                width: widths['actions']!,
                alignment: Alignment.center,
                child: _buildVoucherRowActions(voucher),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoucherHeaderCell({
    required String label,
    required double width,
    AlignmentGeometry alignment = Alignment.center,
    VoidCallback? onTap,
    bool isActive = false,
    bool ascending = false,
  }) {
    final child = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: isActive ? theme.AppColors.darkGold : null,
              ),
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 4),
            Icon(
              ascending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: theme.AppColors.darkGold,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }

  Widget _buildVoucherMetricHeaderCell({
    required String label,
    required String unit,
    required double width,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool isActive = false,
    bool ascending = false,
  }) {
    final themeData = Theme.of(context);
    final child = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: _withAlpha(color, 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _withAlpha(color, isActive ? 0.30 : 0.18)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: themeData.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isActive ? color : themeData.colorScheme.onSurface,
                      height: 1.0,
                    ),
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 4),
                  Icon(
                    ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 13,
                    color: color,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              unit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: themeData.textTheme.labelSmall?.copyWith(
                color: _withAlpha(color, 0.92),
                fontWeight: FontWeight.w700,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );

    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }

  Widget _buildVoucherBodyCell({
    required double width,
    required Widget child,
    AlignmentGeometry alignment = Alignment.center,
  }) {
    return Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: child,
    );
  }

  Widget _buildVoucherMetricValueCell({
    required double width,
    required String value,
    required IconData icon,
    required Color color,
    required bool emphasize,
  }) {
    return _buildVoucherBodyCell(
      width: width,
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _withAlpha(color, emphasize ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _withAlpha(color, emphasize ? 0.26 : 0.14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoucherRowActions(Map<String, dynamic> voucher) {
    final status = (voucher['status'] ?? 'pending').toString();
    final isEditable =
        status != 'approved' && status != 'cancelled' && status != 'voided';
    final canApprove = status == 'pending';
    final voucherId = (voucher['id'] as num).toInt();

    return PopupMenuButton<String>(
      tooltip: 'إجراءات',
      onSelected: (value) {
        switch (value) {
          case 'details':
            _navigateToVoucherDetails(voucherId);
            break;
          case 'edit':
            _navigateToEditVoucher(voucher);
            break;
          case 'approve':
            _approveVoucher(voucherId);
            break;
          case 'cancel':
            _cancelVoucher(voucherId);
            break;
          case 'delete':
            _deleteVoucher(voucherId);
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: 'details',
          child: Text('عرض التفاصيل'),
        ),
        if (isEditable)
          const PopupMenuItem<String>(value: 'edit', child: Text('تعديل')),
        if (canApprove)
          const PopupMenuItem<String>(value: 'approve', child: Text('اعتماد')),
        if (status != 'cancelled')
          const PopupMenuItem<String>(value: 'cancel', child: Text('إلغاء')),
        const PopupMenuItem<String>(value: 'delete', child: Text('حذف')),
      ],
    );
  }

  Widget _buildPaginationStrip(ThemeData themeData) {
    if (_totalVouchers == 0 || _totalPages <= 1) {
      return const SizedBox.shrink();
    }

    final pageNumbers = _buildPageNumbers();
    final start = ((_currentPage - 1) * _perPage) + 1;
    final end = (_currentPage * _perPage) > _totalVouchers
        ? _totalVouchers
        : (_currentPage * _perPage);

    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text(
              'عرض $start-$end من $_totalVouchers',
              style: themeData.textTheme.bodySmall?.copyWith(
                color: _withAlpha(themeData.colorScheme.onSurface, 0.65),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.chevron_left, size: 18),
                onPressed: (_isLoading || _currentPage <= 1)
                    ? null
                    : () => _loadVouchers(page: _currentPage - 1),
              ),
            ),
            ...pageNumbers.map((page) {
              if (page == -1) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '…',
                    style: themeData.textTheme.labelSmall?.copyWith(
                      color: _withAlpha(themeData.colorScheme.onSurface, 0.4),
                    ),
                  ),
                );
              }

              final isActive = page == _currentPage;
              return GestureDetector(
                onTap: (_isLoading || isActive)
                    ? null
                    : () => _loadVouchers(page: page),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 30,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isActive
                        ? theme.AppColors.darkGold
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: isActive
                        ? null
                        : Border.all(
                            color: themeData.colorScheme.outline.withValues(
                              alpha: 0.35,
                            ),
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$page',
                    style: themeData.textTheme.labelSmall?.copyWith(
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isActive
                          ? Colors.white
                          : _withAlpha(themeData.colorScheme.onSurface, 0.7),
                    ),
                  ),
                ),
              );
            }),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.chevron_right, size: 18),
                onPressed: (_isLoading || _currentPage >= _totalPages)
                    ? null
                    : () => _loadVouchers(page: _currentPage + 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeSort(String sortBy, bool ascending) async {
    setState(() {
      _sortBy = sortBy;
      _sortAscending = ascending;
      _currentPage = 1;
    });
    await _loadVouchers(page: 1);
  }

  Future<void> _clearFilters() async {
    _debounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _selectedSearchType = 'all';
      _selectedStatus = 'all';
      _selectedParty = null;
      _selectedCreator = null;
      _dateFrom = null;
      _dateTo = null;
      _sortBy = 'date';
      _sortAscending = false;
      _currentPage = 1;
    });
    await _loadVouchers(page: 1);
  }

  String _searchTypeLabel(String value) {
    switch (value) {
      case 'number':
        return 'رقم السند';
      case 'party':
        return 'الطرف';
      case 'description':
        return 'البيان';
      case 'amount':
        return 'المبلغ';
      case 'reference':
        return 'المرجع';
      default:
        return 'الكل';
    }
  }

  String _searchHint(String value) {
    switch (value) {
      case 'number':
        return 'رقم السند...';
      case 'party':
        return 'اسم العميل أو المورد أو الطرف...';
      case 'description':
        return 'البيان أو الملاحظات...';
      case 'amount':
        return 'المبلغ النقدي أو الذهبي...';
      case 'reference':
        return 'رقم المرجع أو نوعه...';
      default:
        return 'ابحث برقم السند، الطرف، البيان أو المرجع';
    }
  }

  String _resolveVoucherPartyName(Map<String, dynamic> voucher) {
    final customerName = (voucher['customer']?['name'] ?? '').toString().trim();
    if (customerName.isNotEmpty) return customerName;
    final supplierName = (voucher['supplier']?['name'] ?? '').toString().trim();
    if (supplierName.isNotEmpty) return supplierName;
    final employeeName = (voucher['employee']?['name'] ?? '').toString().trim();
    if (employeeName.isNotEmpty) return employeeName;
    final partyName = (voucher['party_name'] ?? '').toString().trim();
    if (partyName.isNotEmpty) return partyName;
    // Fallback for 'other' party_type: use account name from the party-side line.
    final partyType = (voucher['party_type'] ?? '').toString().trim();
    if (partyType == 'other') {
      final voucherType = (voucher['voucher_type'] ?? '').toString();
      final partyLineType = voucherType == 'receipt' ? 'credit' : 'debit';
      final lines = (voucher['account_lines'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final line in lines) {
        if ((line['line_type'] ?? '') == partyLineType) {
          final accName =
              (line['account']?['name'] ?? '').toString().trim();
          if (accName.isNotEmpty) return accName;
        }
      }
    }
    return '';
  }

  String _resolveVoucherCreatorName(Map<String, dynamic> voucher) {
    final createdBy = (voucher['created_by'] ?? '').toString().trim();
    return createdBy.isEmpty ? '—' : createdBy;
  }

  String _buildVoucherReferenceLabel(Map<String, dynamic> voucher) {
    final referenceNumber = (voucher['reference_number'] ?? '')
        .toString()
        .trim();
    final referenceType = (voucher['reference_type'] ?? '').toString().trim();
    final referenceId = (voucher['reference_id'] ?? '').toString().trim();

    if (referenceNumber.isNotEmpty) {
      return referenceNumber;
    }
    if (referenceType.isNotEmpty && referenceId.isNotEmpty) {
      return '$referenceType #$referenceId';
    }
    if (referenceType.isNotEmpty) {
      return referenceType;
    }
    return '—';
  }

  _VoucherStatusVisuals _resolveVoucherStatusVisuals(String status) {
    switch (status) {
      case 'approved':
        return const _VoucherStatusVisuals(label: 'معتمد', color: Colors.green);
      case 'cancelled':
        return const _VoucherStatusVisuals(label: 'ملغى', color: Colors.red);
      case 'rejected':
        return const _VoucherStatusVisuals(
          label: 'مرفوض',
          color: Colors.redAccent,
        );
      default:
        return const _VoucherStatusVisuals(label: 'معلق', color: Colors.orange);
    }
  }

  Widget _buildVoucherCard(Map<String, dynamic> voucher, ThemeData themeData) {
    final String voucherType = (voucher['voucher_type'] ?? 'unknown')
        .toString();
    final String status = (voucher['status'] ?? 'pending').toString();
    final bool isCancelled = status == 'cancelled';
    final bool isEditable =
        status != 'approved' && status != 'cancelled' && status != 'voided';
    final bool canApprove = status == 'pending';

    final bool isAutoGenerated = _isAutoGeneratedVoucher(voucher);

    final _VoucherVisuals visuals = _resolveVoucherVisuals(voucherType);

    final String voucherNumber = (voucher['voucher_number'] ?? '—').toString();
    final String dateText = _formatDate(voucher['date']);
    final String? cashAmount = _formatCurrency(voucher['amount_cash']);
    final String? goldPrimary = _formatPrimaryGoldDisplay(voucher);
    final String? goldEquivalent = _formatEquivalentGold(voucher);
    final String? goldBreakdown = _formatGoldBreakdown(voucher);

    final String partyName = _resolveVoucherPartyName(voucher);
    final String description = (voucher['description'] ?? '').toString();

    // Sample the card background (gradient between white and a light gold)
    final Color cardBgStart = Colors.white;
    final Color cardBgEnd = _withAlpha(theme.AppColors.lightGold, 0.08);
    final Color cardBgSample = _sampleColor(cardBgStart, cardBgEnd, 0.5);
    final bool cardBgIsLight = cardBgSample.computeLuminance() > 0.5;
    final Color titleColor = _contrastOn(cardBgSample);
    final Color secondaryTextColor = cardBgIsLight
        ? _withAlpha(Colors.black, 0.6)
        : _withAlpha(Colors.white, 0.85);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [Colors.white, _withAlpha(theme.AppColors.lightGold, 0.08)],
            begin: _gradientBegin(),
            end: _gradientEnd(),
          ),
          border: Border.all(
            color: _withAlpha(
              isAutoGenerated ? theme.AppColors.info : visuals.color,
              0.35,
            ),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: _withAlpha(Colors.black, 0.08),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => _navigateToVoucherDetails(voucher['id']),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 48,
                        width: 48,
                        decoration: BoxDecoration(
                          color: _withAlpha(visuals.color, 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          visuals.icon,
                          color: visuals.color,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    voucherNumber,
                                    style: themeData.textTheme.titleLarge
                                        ?.copyWith(
                                          color: titleColor,
                                          fontWeight: FontWeight.w800,
                                          decoration: isCancelled
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _withAlpha(visuals.color, 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    visuals.label,
                                    style: themeData.textTheme.bodySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: visuals.color,
                                        ),
                                  ),
                                ),
                                if (isAutoGenerated) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _withAlpha(
                                        theme.AppColors.info,
                                        0.12,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: _withAlpha(
                                          theme.AppColors.info,
                                          0.25,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.auto_awesome,
                                          size: 14,
                                          color: theme.AppColors.info,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'تلقائي',
                                          style: themeData.textTheme.bodySmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                color: theme.AppColors.info,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  Icons.calendar_month_outlined,
                                  size: 16,
                                  color: _withAlpha(
                                    themeData.colorScheme.onSurface,
                                    0.6,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  dateText,
                                  style: themeData.textTheme.bodySmall
                                      ?.copyWith(color: secondaryTextColor),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (cashAmount != null)
                            Text(
                              'نقداً: $cashAmount ر.س',
                              style: themeData.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF2F80ED),
                              ),
                            ),
                          if (goldPrimary != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                goldPrimary,
                                style: themeData.textTheme.bodyMedium?.copyWith(
                                  color: const Color(0xFFD4A017),
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          if (goldEquivalent != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                goldEquivalent,
                                style: themeData.textTheme.bodySmall?.copyWith(
                                  color: secondaryTextColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (goldBreakdown != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: SizedBox(
                                width: 220,
                                child: Text(
                                  goldBreakdown,
                                  textAlign: TextAlign.end,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: themeData.textTheme.bodySmall
                                      ?.copyWith(
                                        color: secondaryTextColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                  if (partyName.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 18,
                          color: _withAlpha(
                            themeData.colorScheme.onSurface,
                            0.6,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            partyName,
                            style: themeData.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: secondaryTextColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: themeData.textTheme.bodySmall?.copyWith(
                        color: secondaryTextColor,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatusBadges(themeData, status: status),
                      ),
                      if (!isCancelled)
                        Wrap(
                          spacing: 12,
                          children: [
                            if (isEditable)
                              TextButton.icon(
                                onPressed: () =>
                                    _navigateToEditVoucher(voucher),
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('تعديل'),
                                style: TextButton.styleFrom(
                                  foregroundColor: theme.AppColors.darkGold,
                                ),
                              ),
                            if (canApprove)
                              TextButton.icon(
                                onPressed: () => _approveVoucher(voucher['id']),
                                icon: const Icon(
                                  Icons.check_circle_outline,
                                  size: 18,
                                ),
                                label: const Text('اعتماد'),
                                style: TextButton.styleFrom(
                                  foregroundColor: theme.AppColors.success,
                                ),
                              ),
                            TextButton.icon(
                              onPressed: () => _cancelVoucher(voucher['id']),
                              icon: const Icon(Icons.cancel_outlined, size: 18),
                              label: const Text('إلغاء'),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.AppColors.error,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => _deleteVoucher(voucher['id']),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                              ),
                              label: const Text('حذف'),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.AppColors.error,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadges(ThemeData themeData, {required String status}) {
    final List<Widget> badges = [];

    if (status == 'pending') {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.pending_actions_outlined,
          label: 'معلق',
          color: theme.AppColors.warning,
        ),
      );
    }

    if (status == 'approved') {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.verified_outlined,
          label: 'معتمد',
          color: theme.AppColors.success,
        ),
      );
    }

    if (status == 'cancelled') {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.cancel_outlined,
          label: 'ملغى',
          color: theme.AppColors.error,
        ),
      );
    }

    if (status == 'rejected') {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.gpp_bad_outlined,
          label: 'مرفوض',
          color: theme.AppColors.error,
        ),
      );
    }

    if (badges.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(spacing: 8, runSpacing: 4, children: badges);
  }

  Widget _buildStatusBadge({
    required ThemeData themeData,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _withAlpha(color, 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: _withAlpha(color, 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: themeData.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData themeData) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: themeData.colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: _withAlpha(Colors.black, 0.08),
              blurRadius: 18,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 58,
              color: theme.AppColors.darkGold,
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد سندات مطابقة',
              style: themeData.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'يمكنك تعديل إعدادات البحث أو إنشاء سند جديد فوراً.',
              textAlign: TextAlign.center,
              style: themeData.textTheme.bodyMedium?.copyWith(
                color: _withAlpha(themeData.colorScheme.onSurface, 0.65),
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => _navigateToAddVoucher('receipt'),
              icon: const Icon(Icons.add),
              label: const Text('إنشاء سند'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.AppColors.darkGold,
                backgroundColor: theme.AppColors.lightGold,
                side: BorderSide.none,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomQuickActions(ThemeData themeData) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          color: themeData.scaffoldBackgroundColor,
          boxShadow: [
            BoxShadow(
              color: _withAlpha(Colors.black, 0.08),
              blurRadius: 18,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildQuickActionButton(
                label: 'تسوية تحصيل',
                icon: Icons.swap_horiz,
                backgroundColor: theme.AppColors.warning,
                onPressed: () async {
                  final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const ClearingSettlementScreen(),
                    ),
                  );
                  if (changed == true) {
                    _refresh();
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildQuickActionButton(
                label: 'سند قبض',
                icon: Icons.south,
                backgroundColor: theme.AppColors.success,
                onPressed: () => _navigateToAddVoucher('receipt'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildQuickActionButton(
                label: 'سند صرف',
                icon: Icons.north,
                backgroundColor: theme.AppColors.error,
                onPressed: () => _navigateToAddVoucher('payment'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionButton({
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      height: 46,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        icon: Icon(icon, size: 18),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1),
        ),
      ),
    );
  }

  Widget _buildPaginationLoader() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      ),
    );
  }

  void _clearSearch() {
    _debounce?.cancel();
    if (_searchQuery.isEmpty && _searchController.text.isEmpty) {
      return;
    }
    _searchController.clear();
    if (_searchQuery.isNotEmpty) {
      setState(() {
        _searchQuery = '';
        _currentPage = 1;
      });
      _loadVouchers(page: 1);
    }
  }

  // Return gradient begin/end that respect current text direction so
  // the light/dark ends swap automatically when switching LTR/RTL.
  Alignment _gradientBegin() {
    final isRtl = Directionality.of(context) == ui.TextDirection.rtl;
    return isRtl ? Alignment.topLeft : Alignment.topRight;
  }

  Alignment _gradientEnd() {
    final isRtl = Directionality.of(context) == ui.TextDirection.rtl;
    return isRtl ? Alignment.bottomRight : Alignment.bottomLeft;
  }

  Color _withAlpha(Color color, double opacity) {
    final double normalized = opacity.clamp(0, 1);
    final int alphaValue = (normalized * 255).round();
    return color.withAlpha(alphaValue);
  }

  // Sample a color between two colors at t (0.0..1.0)
  Color _sampleColor(Color a, Color b, double t) {
    return Color.lerp(a, b, t.clamp(0.0, 1.0)) ?? a;
  }

  // Relative luminance (sRGB) used to decide readable foreground color.
  double _relativeLuminance(Color c) {
    double channel(int v) {
      final vSrgb = v / 255.0;
      return vSrgb <= 0.03928
          ? vSrgb / 12.92
          : math.pow((vSrgb + 0.055) / 1.055, 2.4).toDouble();
    }

    final int r = (c.r * 255).round();
    final int g = (c.g * 255).round();
    final int b = (c.b * 255).round();

    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  }

  // Return either black or white depending on background luminance to maximize contrast.
  Color _contrastOn(Color background) {
    final lum = _relativeLuminance(background);
    return lum > 0.5 ? Colors.black : Colors.white;
  }

  bool _isAutoGeneratedVoucher(Map<String, dynamic> voucher) {
    try {
      final referenceType = (voucher['reference_type'] ?? '').toString();
      if (referenceType != 'invoice') return false;

      final notes = (voucher['notes'] ?? '').toString().trim();
      if (notes.isEmpty) return false;

      if (notes.startsWith('{')) {
        final parsed = json.decode(notes);
        if (parsed is Map) {
          final source = (parsed['source'] ?? '').toString();
          return source == 'invoice_payment';
        }
      }

      return notes.contains('invoice_payment');
    } catch (_) {
      return false;
    }
  }

  String _formatDate(dynamic value) {
    if (value == null) {
      return '—';
    }
    final String raw = value.toString();
    if (raw.isEmpty) {
      return '—';
    }
    try {
      final DateTime parsed = DateTime.parse(raw);
      return DateFormat('yyyy/MM/dd', 'ar').format(parsed);
    } catch (_) {
      return raw;
    }
  }

  String? _formatCurrency(dynamic value) {
    final double? amount = _toDouble(value);
    if (amount == null || amount == 0) {
      return null;
    }
    return _currencyFormat.format(amount);
  }

  String? _formatGold(dynamic value) {
    final double? amount = _toDouble(value);
    if (amount == null || amount == 0) {
      return null;
    }
    return _goldFormat.format(amount);
  }

  String? _formatPrimaryGoldDisplay(Map<String, dynamic> voucher) {
    final String? gold = _formatGold(voucher['amount_gold']);
    if (gold == null) {
      return null;
    }

    final karat = (voucher['gold_karat'] ?? '').toString().trim();
    if (karat.isEmpty || karat == 'متعدد') {
      return '$gold غ';
    }
    return '$gold غ عيار $karat';
  }

  String? _formatEquivalentGold(Map<String, dynamic> voucher) {
    final double? amount = _toDouble(voucher['amount_gold_main_karat']);
    if (amount == null || amount == 0) {
      return null;
    }

    final int mainKarat = (_toDouble(voucher['main_karat']) ?? 21).round();
    return 'المكافئ عيار $mainKarat: ${_goldFormat.format(amount)} غ';
  }

  String? _formatGoldBreakdown(Map<String, dynamic> voucher) {
    final raw = voucher['gold_breakdown'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .whereType<Map>()
          .map((entry) {
            final weight = _formatGold(entry['weight']) ?? '0.000';
            final karat = _toDouble(entry['karat'])?.round() ?? entry['karat'];
            return '• عيار $karat: $weight غ';
          })
          .join('\n');
    }

    final rawGold = _formatGold(voucher['amount_gold']);
    if (rawGold == null) {
      return null;
    }

    final karat = voucher['gold_karat'];
    if (karat == null || karat.toString().isEmpty || karat == 'متعدد') {
      return '• إجمالي الذهب: $rawGold غ';
    }
    return '• عيار ${_toDouble(karat)?.round() ?? karat}: $rawGold غ';
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString());
  }

  _VoucherVisuals _resolveVoucherVisuals(String type) {
    switch (type) {
      case 'receipt':
        return _VoucherVisuals(
          label: 'قبض',
          color: theme.AppColors.success,
          icon: Icons.south,
        );
      case 'payment':
        return _VoucherVisuals(
          label: 'صرف',
          color: theme.AppColors.error,
          icon: Icons.north,
        );
      case 'adjustment':
        return _VoucherVisuals(
          label: 'تسوية',
          color: theme.AppColors.warning,
          icon: Icons.balance,
        );
      default:
        return const _VoucherVisuals(
          label: 'غير محدد',
          color: Colors.grey,
          icon: Icons.help_outline,
        );
    }
  }

  void _navigateToAddVoucher(String type) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddVoucherScreen(voucherType: type),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _navigateToEditVoucher(Map<String, dynamic> voucher) async {
    final status = (voucher['status'] ?? '').toString();
    if (status == 'approved' || status == 'cancelled' || status == 'voided') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا يمكن تعديل هذا السند في حالته الحالية.'),
        ),
      );
      return;
    }
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddVoucherScreen(
          voucherType: (voucher['voucher_type'] ?? 'receipt').toString(),
          existingVoucher: voucher,
        ),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _navigateToVoucherDetails(int id) async {
    final result = await showVoucherDetailsSheet(context, voucherId: id);
    if (result == true) {
      _refresh();
    }
  }

  Future<void> _exportToPdf() async {
    if (_vouchers.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد بيانات لتصديرها')),
        );
      }
      return;
    }

    final pdf = pw.Document();

    // Load the font that supports Arabic characters.
    final fontData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final ttf = pw.Font.ttf(fontData.buffer.asByteData());
    final boldFontData = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    final boldTtf = pw.Font.ttf(boldFontData.buffer.asByteData());

    final headers = ['المبلغ', 'البيان', 'النوع', 'التاريخ', 'الرقم'];

    final data = _vouchers.map((voucher) {
      final type = voucher['voucher_type'] == 'receipt' ? 'قبض' : 'صرف';
      final amount = (voucher['amount_cash'] ?? 0.0).toStringAsFixed(2);
      return [
        amount,
        voucher['description'] ?? '',
        type,
        voucher['date'] ?? '',
        voucher['voucher_number'] ?? '',
      ];
    }).toList();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: ttf, bold: boldTtf),
        header: (context) => pw.Header(
          level: 0,
          child: pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Text(
              'قائمة السندات',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ),
        build: (context) => [
          pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.TableHelper.fromTextArray(
              headers: headers,
              data: data,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerRight,
              headerAlignment: pw.Alignment.centerRight,
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.grey300,
              ),
              cellStyle: const pw.TextStyle(),
              rowDecoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey200),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    try {
      final output = await getTemporaryDirectory();
      final file = File('${output.path}/vouchers.pdf');
      await file.writeAsBytes(await pdf.save());
      if (mounted) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: 'تقرير السندات',
            title:
                'تقرير السندات بتاريخ ${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في تصدير PDF: $e')));
      }
    }
  }

  Future<void> _exportToExcel() async {
    if (_vouchers.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا توجد بيانات لتصديرها')));
      return;
    }

    final excelFile = excel.Excel.createExcel();
    final sheet = excelFile['Vouchers'];

    // Add header row and data rows (set cells individually to avoid API mismatch)
    final headers = ['الرقم', 'التاريخ', 'النوع', 'البيان', 'المبلغ'];
    int rowIndex = 0;
    for (int c = 0; c < headers.length; c++) {
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: c,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          headers[c];
    }
    // Add data rows
    for (final voucher in _vouchers) {
      rowIndex++;
      final type = voucher['voucher_type'] == 'receipt' ? 'قبض' : 'صرف';
      final amount = voucher['amount_cash'] ?? 0.0;
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: 0,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          voucher['voucher_number'] ?? '';
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: 1,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          voucher['date'] ?? '';
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: 2,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          type;
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: 3,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          voucher['description'] ?? '';
      sheet
              .cell(
                excel.CellIndex.indexByColumnRow(
                  columnIndex: 4,
                  rowIndex: rowIndex,
                ),
              )
              .value =
          amount;
    }

    try {
      final output = await getTemporaryDirectory();
      final fileName =
          'vouchers_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.xlsx';
      final file = File('${output.path}/$fileName');

      final bytes = excelFile.save();
      if (bytes != null) {
        await file.writeAsBytes(bytes);
        if (!mounted) return;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: 'تقرير السندات',
            title:
                'تقرير السندات بتاريخ ${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('خطأ في تصدير Excel: $e')));
    }
  }
}

class _VoucherVisuals {
  final String label;
  final Color color;
  final IconData icon;

  const _VoucherVisuals({
    required this.label,
    required this.color,
    required this.icon,
  });
}

class _VoucherStatusVisuals {
  final String label;
  final Color color;

  const _VoucherStatusVisuals({required this.label, required this.color});
}
