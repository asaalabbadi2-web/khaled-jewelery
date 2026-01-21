import 'dart:async';
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
import 'package:provider/provider.dart';

class VouchersListScreen extends StatefulWidget {
  const VouchersListScreen({super.key});

  @override
  State<VouchersListScreen> createState() => _VouchersListScreenState();
}

class _VouchersListScreenState extends State<VouchersListScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  List<dynamic> _vouchers = [];
  bool _isLoading = true;
  String? _error;
  int _currentPage = 1;
  int _totalPages = 1;
  bool _isFetchingMore = false;
  Timer? _debounce;

  // Filters
  String _selectedType = 'all'; // all, receipt, payment, adjustment
  String _selectedStatus = 'all'; // all, active, cancelled
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _searchQuery = '';

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'ar');
  final NumberFormat _goldFormat = NumberFormat('#,##0.000', 'ar');

  late TabController _tabController;
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    _scrollController.addListener(_onScroll);
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
      _loadStats();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isFetchingMore &&
        _currentPage < _totalPages) {
      _loadVouchers(page: _currentPage + 1);
    }
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (_searchQuery != _searchController.text) {
        setState(() {
          _searchQuery = _searchController.text;
        });
        _loadVouchers();
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
        }
      });
      _loadVouchers();
    }
  }

  Future<void> _loadVouchers({int page = 1}) async {
    if (page == 1) {
      setState(() {
        _isLoading = true;
        _vouchers.clear();
        _currentPage = 1;
        _error = null;
        _isFetchingMore = true;
      });
    }

    try {
      final data = await _apiService.getVouchers(
        page: page,
        type: _selectedType,
        status: _selectedStatus,
        dateFrom: _dateFrom?.toIso8601String(),
        dateTo: _dateTo?.toIso8601String(),
        search: _searchQuery,
      );

      if (!mounted) return;

      setState(() {
        if (page == 1) {
          _vouchers = data['vouchers'];
        } else {
          _vouchers.addAll(data['vouchers']);
        }
        _currentPage = data['current_page'];
        _totalPages = data['pages'];
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
          _isFetchingMore = false;
        });
      }
    }
  }

  Future<void> _loadStats() async {
    try {
      final stats = await _apiService.getVouchersStats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
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
    await _loadStats();
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
      return status != 'approved' && status != 'cancelled';
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
      floatingActionButton: _buildFloatingActions(),
    );
  }

  PreferredSizeWidget _buildAppBar(ThemeData themeData) {
    final isLight = themeData.brightness == Brightness.light;

    return AppBar(
      elevation: 0,
      titleSpacing: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: isLight ? Colors.black : Colors.white,
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
        icon: Icon(
          Icons.arrow_back,
          color: isLight ? Colors.black : Colors.white,
        ),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: SafeArea(
        top: true,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'السندات',
                style: themeData.textTheme.headlineSmall?.copyWith(
                  color: isLight ? Colors.black87 : Colors.white,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                'تحكم كامل بسندات القبض والصرف',
                style: themeData.textTheme.bodyMedium?.copyWith(
                  color: isLight
                      ? _withAlpha(Colors.black, 0.6)
                      : _withAlpha(Colors.white, 0.8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
      bottom: PreferredSize(
        preferredSize: Size.fromHeight(
          100 + MediaQuery.of(context).padding.top,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: isLight
                  ? _withAlpha(Colors.black, 0.06)
                  : _withAlpha(Colors.white, 0.2),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: TabBar(
                controller: _tabController,
                // Polished visuals: gold gradient pill indicator, bold labels,
                // and material icons instead of emoji. Colors adapt to light/dark.
                labelColor: themeData.brightness == Brightness.light
                    ? theme.AppColors.darkGold
                    : Colors.white,
                unselectedLabelColor: themeData.brightness == Brightness.light
                    ? Colors.black54
                    : _withAlpha(Colors.white, 0.85),
                labelStyle: themeData.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: themeData.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                // Gradient pill indicator
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
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                indicatorPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 6,
                ),
                // Make indicator cover the full tab (pill)
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: [
                  Tab(icon: Icon(Icons.list_alt), text: 'الكل'),
                  Tab(icon: Icon(Icons.call_received), text: 'قبض'),
                  Tab(icon: Icon(Icons.call_made), text: 'صرف'),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'الفلاتر',
          icon: const Icon(Icons.filter_alt_outlined),
          onPressed: _showFiltersDialog,
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

    return RefreshIndicator(
      onRefresh: _refresh,
      color: theme.AppColors.primaryGold,
      displacement: 80,
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildHeaderSection(themeData)),
          if (_vouchers.isEmpty)
            SliverToBoxAdapter(child: _buildEmptyState(themeData))
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index >= _vouchers.length) {
                  return _buildPaginationLoader();
                }
                return _buildVoucherCard(_vouchers[index], themeData);
              }, childCount: _vouchers.length + (_isFetchingMore ? 1 : 0)),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.AppColors.primaryGold, theme.AppColors.mediumGold],
          begin: _gradientBegin(),
          end: _gradientEnd(),
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // adapt header text color based on sampled background luminance
          Builder(
            builder: (context) {
              final headerSample = _sampleColor(
                theme.AppColors.primaryGold,
                theme.AppColors.mediumGold,
                0.5,
              );
              final headerTextColor = _contrastOn(headerSample);
              return Text(
                'نظرة سريعة',
                style: themeData.textTheme.titleLarge?.copyWith(
                  color: headerTextColor,
                  fontWeight: FontWeight.w700,
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (_stats != null) ...[
            _buildStatsOverview(themeData),
            const SizedBox(height: 16),
          ],
          _buildSearchCard(themeData),
          const SizedBox(height: 14),
          _buildStatusFilters(themeData),
        ],
      ),
    );
  }

  Widget _buildStatsOverview(ThemeData themeData) {
    // Backend returns keys like: total_receipt, total_payment, total_adjustment
    // Map those into the frontend's stats tiles so we don't show zeros when keys differ.
    final int totalReceipt = (_stats?['total_receipt'] is int)
        ? _stats!['total_receipt'] as int
        : (_stats?['total_receipt'] is double)
        ? (_stats!['total_receipt'] as double).round()
        : 0;
    final int totalPayment = (_stats?['total_payment'] is int)
        ? _stats!['total_payment'] as int
        : (_stats?['total_payment'] is double)
        ? (_stats!['total_payment'] as double).round()
        : 0;
    final int totalAdjustment = (_stats?['total_adjustment'] is int)
        ? _stats!['total_adjustment'] as int
        : (_stats?['total_adjustment'] is double)
        ? (_stats!['total_adjustment'] as double).round()
        : 0;

    final int totalCount = totalReceipt + totalPayment + totalAdjustment;

    final List<Map<String, dynamic>> statsData = [
      {
        'label': 'الإجمالي',
        'value': totalCount,
        'icon': Icons.receipt_long,
        'color': Colors.white,
      },
      {
        'label': 'قبض',
        'value': totalReceipt,
        'icon': Icons.south,
        'color': theme.AppColors.success,
      },
      {
        'label': 'صرف',
        'value': totalPayment,
        'icon': Icons.north,
        'color': theme.AppColors.error,
      },
      {
        'label': 'تعديلات',
        'value': totalAdjustment,
        'icon': Icons.adjust,
        'color': theme.AppColors.info,
      },
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: statsData.map((stat) {
        final String value = '${stat['value']}';
        return _buildStatTile(
          themeData: themeData,
          label: stat['label'] as String,
          value: value,
          icon: stat['icon'] as IconData,
          color: stat['color'] as Color,
        );
      }).toList(),
    );
  }

  Widget _buildStatTile({
    required ThemeData themeData,
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCirc,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: _withAlpha(Colors.white, 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _withAlpha(Colors.white, 0.18)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 12),
            Text(
              value,
              style: themeData.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: themeData.textTheme.bodySmall?.copyWith(
                color: _withAlpha(Colors.white, 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchCard(ThemeData themeData) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: themeData.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _withAlpha(Colors.black, 0.12),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'بحث سريع',
            style: themeData.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'ابحث برقم السند، البيان أو اسم العميل',
              prefixIcon: Icon(Icons.search, color: theme.AppColors.darkGold),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'مسح البحث',
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusFilters(ThemeData themeData) {
    final statuses = [
      {'value': 'all', 'label': 'كل الحالات', 'icon': Icons.all_inclusive},
      {'value': 'active', 'label': 'نشط', 'icon': Icons.verified_outlined},
      {'value': 'cancelled', 'label': 'ملغى', 'icon': Icons.cancel_outlined},
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
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
                size: 18,
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
            });
            _loadVouchers();
          },
          backgroundColor: background,
          selectedColor: Colors.white,
          pressElevation: 0,
          elevation: 0,
          labelPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape: StadiumBorder(
            side: BorderSide(
              color: _withAlpha(Colors.white, selected ? 0 : 0.3),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildVoucherCard(Map<String, dynamic> voucher, ThemeData themeData) {
    final String voucherType = (voucher['voucher_type'] ?? 'unknown')
        .toString();
    final String status = (voucher['status'] ?? 'active').toString();
    final bool isCancelled = status == 'cancelled';
    final bool isActive = status == 'active';

    final _VoucherVisuals visuals = _resolveVoucherVisuals(voucherType);

    final String voucherNumber = (voucher['voucher_number'] ?? '—').toString();
    final String dateText = _formatDate(voucher['date']);
    final String? cashAmount = _formatCurrency(voucher['amount_cash']);
    final String? goldAmount = _formatGold(voucher['amount_gold']);

    final String partyName =
        (voucher['customer']?['name'] ?? voucher['supplier']?['name'] ?? '')
            .toString();
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
            color: _withAlpha(visuals.color, 0.35),
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
                              '$cashAmount ر.س',
                              style: themeData.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: visuals.color,
                              ),
                            ),
                          if (goldAmount != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '$goldAmount غرام',
                                style: themeData.textTheme.bodyMedium?.copyWith(
                                  color: theme.AppColors.darkGold,
                                  fontWeight: FontWeight.w700,
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
                        child: _buildStatusBadges(
                          themeData,
                          isActive: isActive,
                          isCancelled: isCancelled,
                        ),
                      ),
                      if (!isCancelled)
                        Wrap(
                          spacing: 12,
                          children: [
                            // Edit button: only when voucher is editable
                            // (not approved, not cancelled, not voided)
                            if ((voucher['status'] ?? '') != 'approved' &&
                                (voucher['status'] ?? '') != 'cancelled' &&
                                (voucher['status'] ?? '') != 'voided')
                              TextButton.icon(
                                onPressed: () =>
                                    _navigateToEditVoucher(voucher),
                                icon: const Icon(Icons.edit, size: 18),
                                label: const Text('تعديل'),
                                style: TextButton.styleFrom(
                                  foregroundColor: theme.AppColors.darkGold,
                                ),
                              ),
                            // Approve button for pending vouchers
                            if ((voucher['status'] ?? '') != 'approved')
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

  Widget _buildStatusBadges(
    ThemeData themeData, {
    required bool isActive,
    required bool isCancelled,
  }) {
    final List<Widget> badges = [];

    if (isActive) {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.verified_outlined,
          label: 'نشط',
          color: theme.AppColors.success,
        ),
      );
    }

    if (isCancelled) {
      badges.add(
        _buildStatusBadge(
          themeData: themeData,
          icon: Icons.cancel_outlined,
          label: 'ملغى',
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

  Widget _buildPaginationLoader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            color: theme.AppColors.primaryGold,
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingActions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildExtendedFab(
          heroTag: 'clearing_settlement',
          label: 'تسوية تحصيل',
          icon: Icons.swap_horiz,
          backgroundColor: theme.AppColors.warning,
          onPressed: () async {
            final changed = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (_) => const ClearingSettlementScreen()),
            );
            if (changed == true) {
              _refresh();
            }
          },
        ),
        const SizedBox(height: 10),
        _buildExtendedFab(
          heroTag: 'receipt',
          label: 'سند قبض',
          icon: Icons.south,
          backgroundColor: theme.AppColors.success,
          onPressed: () => _navigateToAddVoucher('receipt'),
        ),
        const SizedBox(height: 10),
        _buildExtendedFab(
          heroTag: 'payment',
          label: 'سند صرف',
          icon: Icons.north,
          backgroundColor: theme.AppColors.error,
          onPressed: () => _navigateToAddVoucher('payment'),
        ),
      ],
    );
  }

  Widget _buildExtendedFab({
    required String heroTag,
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return FloatingActionButton.extended(
      heroTag: heroTag,
      onPressed: onPressed,
      backgroundColor: backgroundColor,
      foregroundColor: Colors.white,
      icon: Icon(icon),
      label: Text(label),
      elevation: 4,
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
      });
      _loadVouchers();
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

  void _showFiltersDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('فلاتر البحث'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status Filter
              const Text('الحالة:'),
              DropdownButton<String>(
                value: _selectedStatus,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('الكل')),
                  DropdownMenuItem(value: 'active', child: Text('نشط')),
                  DropdownMenuItem(value: 'cancelled', child: Text('ملغى')),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedStatus = value ?? 'all';
                  });
                },
              ),
              const SizedBox(height: 16),

              // Date Range
              const Text('الفترة الزمنية:'),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _dateFrom ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (date != null) {
                          setState(() {
                            _dateFrom = date;
                          });
                        }
                      },
                      child: Text(
                        _dateFrom != null
                            ? DateFormat('yyyy-MM-dd').format(_dateFrom!)
                            : 'من تاريخ',
                      ),
                    ),
                  ),
                  const Text(' - '),
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _dateTo ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (date != null) {
                          setState(() {
                            _dateTo = date;
                          });
                        }
                      },
                      child: Text(
                        _dateTo != null
                            ? DateFormat('yyyy-MM-dd').format(_dateTo!)
                            : 'إلى تاريخ',
                      ),
                    ),
                  ),
                ],
              ),

              // Clear Filters
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedStatus = 'all';
                    _dateFrom = null;
                    _dateTo = null;
                  });
                },
                child: const Text('مسح الفلاتر'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _loadVouchers();
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    );
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
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VoucherDetailsScreen(voucherId: id),
      ),
    );
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
