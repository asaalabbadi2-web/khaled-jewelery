import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// شاشة سجل حجوزات الذهب للمكاتب
class GoldReservationsListScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const GoldReservationsListScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<GoldReservationsListScreen> createState() =>
      _GoldReservationsListScreenState();
}

class _GoldReservationsListScreenState
    extends State<GoldReservationsListScreen> {
  final DateFormat _dateFormatter = DateFormat('yyyy-MM-dd HH:mm');

  int _mainKarat = 21;

  bool _isLoading = false;
  List<Map<String, dynamic>> _reservations = [];
  List<Map<String, dynamic>> _offices = [];

  int _currentPage = 1;
  int _perPage = 15;
  int _totalPages = 1;
  int _totalRecords = 0;

  int? _selectedOfficeId;
  String? _selectedStatus;
  String? _selectedPaymentStatus;
  DateTimeRange? _selectedDateRange;

  double _totalWeightMainKarat = 0;
  double _totalPaidAmount = 0;
  double _totalAmount = 0;

  bool _filtersExpanded = true;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.watch<SettingsProvider>();
    final nextMainKarat = settings.mainKarat;
    if (nextMainKarat != _mainKarat) {
      setState(() => _mainKarat = nextMainKarat);
    }
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final officesResponse = await widget.api.getOffices();
      setState(() {
        _offices = officesResponse
            .map((office) => Map<String, dynamic>.from(office as Map))
            .toList();
      });
      await _fetchReservations(page: 1, showLoader: false);
    } catch (e) {
      _showSnack(
        widget.isArabic ? 'تعذر تحميل البيانات: $e' : 'Failed to load data: $e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchReservations({int? page, bool showLoader = true}) async {
    if (showLoader) setState(() => _isLoading = true);
    final targetPage = page ?? _currentPage;

    try {
      final dateFrom = _selectedDateRange != null
          ? DateFormat('yyyy-MM-dd').format(_selectedDateRange!.start)
          : null;
      final dateTo = _selectedDateRange != null
          ? DateFormat('yyyy-MM-dd').format(_selectedDateRange!.end)
          : null;

      final response = await widget.api.getOfficeReservations(
        officeId: _selectedOfficeId,
        status: _selectedStatus,
        paymentStatus: _selectedPaymentStatus,
        dateFrom: dateFrom,
        dateTo: dateTo,
        page: targetPage,
        perPage: _perPage,
        orderBy: 'reservation_date',
        orderDirection: 'desc',
      );

      final data = (response['data'] as List<dynamic>? ?? [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
      final pagination = Map<String, dynamic>.from(
        response['pagination'] ?? <String, dynamic>{},
      );

      double totalWeight = 0;
      double totalPaid = 0;
      double totalAmount = 0;

      for (final entry in data) {
        totalWeight += _toDouble(entry['weight_main_karat']);
        totalPaid += _toDouble(entry['paid_amount']);
        totalAmount += _toDouble(entry['total_amount']);
      }

      if (!mounted) return;
      setState(() {
        _reservations = data;
        _currentPage = pagination['page'] ?? targetPage;
        _perPage = pagination['per_page'] ?? _perPage;
        _totalRecords = pagination['total'] ?? data.length;
        _totalPages = pagination['pages'] ?? 1;
        _totalWeightMainKarat = totalWeight;
        _totalPaidAmount = totalPaid;
        _totalAmount = totalAmount;
      });
    } catch (e) {
      _showSnack(
        widget.isArabic
            ? 'تعذر تحميل الحجوزات: $e'
            : 'Failed to load reservations: $e',
        isError: true,
      );
    } finally {
      if (showLoader && mounted) setState(() => _isLoading = false);
    }
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
      ),
    );
  }

  Future<void> _selectDateRange() async {
    final now = DateTime.now();
    final initialRange =
        _selectedDateRange ??
        DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);

    final result = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 30)),
      initialDateRange: initialRange,
      builder: (context, child) {
        return Directionality(
          textDirection: widget.isArabic
              ? TextDirection.rtl
              : TextDirection.ltr,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );

    if (result != null) {
      setState(() => _selectedDateRange = result);
      _fetchReservations(page: 1);
    }
  }

  void _clearFilters() {
    setState(() {
      _selectedOfficeId = null;
      _selectedStatus = null;
      _selectedPaymentStatus = null;
      _selectedDateRange = null;
    });
    _fetchReservations(page: 1);
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '--';
    try {
      return _dateFormatter.format(DateTime.parse(iso).toLocal());
    } catch (_) {
      return iso;
    }
  }

  Color _statusColor(String? status) {
    switch (status) {
      case 'completed':
        return AppColors.success;
      case 'partial':
        return AppColors.warning;
      case 'cancelled':
        return AppColors.error;
      default:
        return AppColors.darkGold;
    }
  }

  String _statusLabel(String? status) {
    final isAr = widget.isArabic;
    switch (status) {
      case 'completed':
        return isAr ? 'مكتمل' : 'Completed';
      case 'partial':
        return isAr ? 'جزئي' : 'Partial';
      case 'cancelled':
        return isAr ? 'ملغي' : 'Cancelled';
      case 'reserved':
        return isAr ? 'محجوز' : 'Reserved';
      default:
        return isAr ? 'غير معروف' : 'Unknown';
    }
  }

  Color _paymentColor(String? status) {
    switch (status) {
      case 'paid':
        return AppColors.success;
      case 'partial':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }

  String _paymentLabel(String? status) {
    final isAr = widget.isArabic;
    switch (status) {
      case 'paid':
        return isAr ? 'مدفوع' : 'Paid';
      case 'partial':
        return isAr ? 'مدفوع جزئياً' : 'Partially Paid';
      case 'pending':
        return isAr ? 'قيد الدفع' : 'Pending';
      default:
        return isAr ? 'غير محدد' : 'Unknown';
    }
  }

  Widget _buildFiltersCard(bool isAr) {
    final textDirection = isAr ? TextDirection.rtl : TextDirection.ltr;
    return Card(
      elevation: 2,
      child: ExpansionTile(
        initiallyExpanded: _filtersExpanded,
        onExpansionChanged: (expanded) =>
            setState(() => _filtersExpanded = expanded),
        leading: const Icon(
          Icons.filter_alt_outlined,
          color: AppColors.darkGold,
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.all(16),
        title: Text(
          isAr ? 'مرشحات البحث' : 'Filters',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        children: [
          Directionality(
            textDirection: textDirection,
            child: Column(
              children: [
                Wrap(
                  runSpacing: 12,
                  spacing: 12,
                  children: [
                    SizedBox(
                      width: 280,
                      child: DropdownButtonFormField<int?>(
                        // ignore: deprecated_member_use
                        value: _selectedOfficeId,
                        decoration: InputDecoration(
                          labelText: isAr ? 'اختر المكتب' : 'Select Office',
                          prefixIcon: const Icon(Icons.business),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem<int?>(
                            value: null,
                            child: Text(isAr ? 'كل المكاتب' : 'All Offices'),
                          ),
                          ..._offices.map((office) {
                            return DropdownMenuItem<int?>(
                              value: office['id'] as int,
                              child: Text(
                                office['name'] ?? office['office_code'] ?? '-',
                              ),
                            );
                          }),
                        ],
                        onChanged: (value) {
                          setState(() => _selectedOfficeId = value);
                          _fetchReservations(page: 1);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        // ignore: deprecated_member_use
                        value: _selectedStatus,
                        decoration: InputDecoration(
                          labelText: isAr ? 'حالة الحجز' : 'Reservation Status',
                          prefixIcon: const Icon(Icons.verified_user),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(isAr ? 'كل الحالات' : 'All Statuses'),
                          ),
                          ...[
                            'reserved',
                            'partial',
                            'completed',
                            'cancelled',
                          ].map(
                            (status) => DropdownMenuItem<String?>(
                              value: status,
                              child: Text(_statusLabel(status)),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _selectedStatus = value);
                          _fetchReservations(page: 1);
                        },
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String?>(
                        // ignore: deprecated_member_use
                        value: _selectedPaymentStatus,
                        decoration: InputDecoration(
                          labelText: isAr ? 'حالة الدفع' : 'Payment Status',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              isAr ? 'كل حالات الدفع' : 'All payment states',
                            ),
                          ),
                          ...['pending', 'partial', 'paid'].map(
                            (status) => DropdownMenuItem<String?>(
                              value: status,
                              child: Text(_paymentLabel(status)),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _selectedPaymentStatus = value);
                          _fetchReservations(page: 1);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 220,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          _selectedDateRange == null
                              ? (isAr
                                    ? 'تحديد الفترة الزمنية'
                                    : 'Select date range')
                              : '${DateFormat('yyyy-MM-dd').format(_selectedDateRange!.start)} → ${DateFormat('yyyy-MM-dd').format(_selectedDateRange!.end)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: _selectDateRange,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.replay_circle_filled),
                      label: Text(isAr ? 'إعادة التعيين' : 'Reset'),
                      onPressed: _clearFilters,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(bool isAr) {
    return Card(
      color: AppColors.lightGold.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          runSpacing: 12,
          spacing: 32,
          children: [
            _buildSummaryTile(
              icon: Icons.inventory_2,
              title: isAr ? 'إجمالي السجلات' : 'Total records',
              value: '$_totalRecords',
            ),
            _buildSummaryTile(
              icon: Icons.scale,
              title: isAr
                  ? 'الوزن (مكافئ $_mainKarat)'
                  : 'Weight (${_mainKarat}K eq.)',
              value: _totalWeightMainKarat.toStringAsFixed(2),
            ),
            _buildSummaryTile(
              icon: Icons.payments,
              title: isAr ? 'المبالغ المحجوزة' : 'Reserved amount',
              value: _totalAmount.toStringAsFixed(2),
            ),
            _buildSummaryTile(
              icon: Icons.check_circle,
              title: isAr ? 'المبالغ المدفوعة' : 'Paid amount',
              value: _totalPaidAmount.toStringAsFixed(2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryTile({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: AppColors.darkGold),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(value, style: const TextStyle(fontSize: 16)),
          ],
        ),
      ],
    );
  }

  Widget _buildReservationCard(Map<String, dynamic> reservation, bool isAr) {
    final office = reservation['office'] ?? {};
    final weight = _toDouble(reservation['weight_grams']);
    final weightMain = _toDouble(reservation['weight_main_karat']);
    final totalAmount = _toDouble(reservation['total_amount']);
    final paidAmount = _toDouble(reservation['paid_amount']);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        office['name'] ?? office['office_code'] ?? '--',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${isAr ? 'رقم الحجز' : 'Reservation #'} ${reservation['reservation_code'] ?? '--'}',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatDate(reservation['reservation_date'] as String?),
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${weight.toStringAsFixed(2)} g / ${weightMain.toStringAsFixed(2)}g 21K',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                _buildChip(
                  icon: Icons.verified,
                  color: _statusColor(reservation['status'] as String?),
                  label: _statusLabel(reservation['status'] as String?),
                ),
                _buildChip(
                  icon: Icons.payments,
                  color: _paymentColor(
                    reservation['payment_status'] as String?,
                  ),
                  label: _paymentLabel(
                    reservation['payment_status'] as String?,
                  ),
                ),
                _buildChip(
                  icon: Icons.water_drop,
                  color: AppColors.primaryGold,
                  label:
                      '${isAr ? 'العيار' : 'Karat'} ${reservation['karat'] ?? 24}',
                ),
                _buildChip(
                  icon: Icons.inventory,
                  color: AppColors.mediumGold,
                  label:
                      '${isAr ? 'تنفيذات' : 'Executions'} ${reservation['executions_created'] ?? 0}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'المبلغ الإجمالي' : 'Total amount',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      Text(
                        totalAmount.toStringAsFixed(2),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'المبلغ المدفوع' : 'Paid amount',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      Text(
                        paidAmount.toStringAsFixed(2),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: paidAmount >= totalAmount
                              ? AppColors.success
                              : AppColors.warning,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if ((reservation['notes'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                reservation['notes'] ?? '',
                style: TextStyle(color: Colors.grey[700]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChip({
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.18),
        child: Icon(icon, size: 18, color: color),
      ),
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  Widget _buildPagination(bool isAr) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: _currentPage > 1
              ? () => _fetchReservations(page: _currentPage - 1)
              : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          isAr
              ? 'صفحة $_currentPage من $_totalPages'
              : 'Page $_currentPage of $_totalPages',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        IconButton(
          onPressed: _currentPage < _totalPages
              ? () => _fetchReservations(page: _currentPage + 1)
              : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isAr ? 'سجل التسكير - حجوزات الذهب' : 'Gold Reservation History',
          ),
        ),
        body: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _fetchReservations(page: 1),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildFiltersCard(isAr),
                    const SizedBox(height: 12),
                    _buildSummaryCard(isAr),
                    const SizedBox(height: 12),
                    if (_reservations.isEmpty)
                      _EmptyState(isArabic: isAr)
                    else
                      ..._reservations.map(
                        (reservation) =>
                            _buildReservationCard(reservation, isAr),
                      ),
                    const SizedBox(height: 8),
                    _buildPagination(isAr),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isArabic;

  const _EmptyState({required this.isArabic});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 48),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.lightGold),
      ),
      child: Column(
        children: [
          Icon(Icons.history, size: 72, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            isArabic
                ? 'لا توجد حجوزات ضمن معايير البحث.'
                : 'No reservations match the current filters.',
            style: const TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            isArabic
                ? 'جرّب توسيع نطاق التاريخ أو إعادة تعيين المرشحات.'
                : 'Try widening the date range or resetting filters.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
