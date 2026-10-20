import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'add_office_screen.dart';
import 'gold_reservation_screen.dart';
import 'gold_reservations_list_screen.dart';
import 'office_detail_screen.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';

/// شاشة قائمة مكاتب التسكير (تسكير الذهب)
class OfficesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const OfficesScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<OfficesScreen> createState() => _OfficesScreenState();
}

class _OfficesScreenState extends State<OfficesScreen> {
  List<dynamic> _offices = [];
  List<dynamic> _filteredOffices = [];
  bool _isLoading = false;
  bool _showActiveOnly = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  int _mainKarat = 21;

  double _asDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  String _formatSigned(
    double amount, {
    required bool isArabic,
    required String unitAr,
    required String unitEn,
    int decimals = 2,
  }) {
    final absValue = amount.abs().toStringAsFixed(decimals);
    final unit = isArabic ? unitAr : unitEn;

    // Convention: positive = "عليه" (debit / receivable), negative = "له" (credit / payable)
    final direction = isArabic
        ? (amount < 0 ? 'له' : 'عليه')
        : (amount < 0 ? 'Payable' : 'Receivable');

    return '$direction $absValue $unit';
  }

  /// The office's riyals as on the safes' deposit card (ADR-052): below zero
  /// owed to it, above ours with it.
  String _officeCashText(double amount, String currency, bool isAr) {
    final value = '${ltrIsolate(formatAmount(amount.abs()))} $currency';
    if (amount < -0.005) return isAr ? 'مستحق للمكتب $value' : 'Owed $value';
    if (amount > 0.005) return isAr ? 'لنا عند المكتب $value' : 'Ours $value';
    return isAr ? 'مسوّى' : 'Settled';
  }

  Future<void> _newReservation(Map<String, dynamic> office) async {
    final officeId = office['id'] is int ? office['id'] as int : int.tryParse('${office['id']}');
    final saved = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GoldReservationScreen(
          api: widget.api,
          isArabic: widget.isArabic,
          initialOfficeId: officeId,
        ),
      ),
    );
    if (saved != null && mounted) {
      await _loadOffices();
      if (mounted) _openOffice(office);
    }
  }

  /// One office's page: its balances, its reservations, their next steps.
  Future<void> _openOffice(Map<String, dynamic> office) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OfficeDetailScreen(
          api: widget.api,
          office: office,
          isArabic: widget.isArabic,
        ),
      ),
    );
    if (mounted) await _loadOffices();
  }

  double _convertToMainKarat(double grams, int karat) {
    if (grams == 0.0) return 0.0;
    final mk = _mainKarat > 0 ? _mainKarat : 21;
    return grams * (karat / mk);
  }

  double _goldMainEquivalentFromOffice(Map<String, dynamic> office) {
    final b18 = _asDouble(office['balance_gold_18k']);
    final b21 = _asDouble(office['balance_gold_21k']);
    final b22 = _asDouble(office['balance_gold_22k']);
    final b24 = _asDouble(office['balance_gold_24k']);

    return _convertToMainKarat(b18, 18) +
        _convertToMainKarat(b21, 21) +
        _convertToMainKarat(b22, 22) +
        _convertToMainKarat(b24, 24);
  }

  double _goldMainEquivalentFromGoldMap(Map<String, dynamic> gold) {
    final b18 = _asDouble(gold['18k']);
    final b21 = _asDouble(gold['21k']);
    final b22 = _asDouble(gold['22k']);
    final b24 = _asDouble(gold['24k']);

    return _convertToMainKarat(b18, 18) +
        _convertToMainKarat(b21, 21) +
        _convertToMainKarat(b22, 22) +
        _convertToMainKarat(b24, 24);
  }

  @override
  void initState() {
    super.initState();
    _loadOffices();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mk = context.watch<SettingsProvider>().mainKarat;
    if (mk > 0 && mk != _mainKarat) {
      setState(() => _mainKarat = mk);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadOffices() async {
    setState(() => _isLoading = true);
    try {
      final offices = await widget.api.getOffices(
        activeOnly: _showActiveOnly ? true : null,
      );
      setState(() {
        _offices = offices;
        _applyFilters();
      });
    } catch (e) {
      _showMessage('خطأ في تحميل المكاتب: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _applyFilters() {
    setState(() {
      _filteredOffices = _offices.where((office) {
        if (_searchQuery.isEmpty) return true;

        final name = (office['name'] ?? '').toString().toLowerCase();
        final code = (office['office_code'] ?? '').toString().toLowerCase();
        final phone = (office['phone'] ?? '').toString().toLowerCase();
        final contact = (office['contact_person'] ?? '')
            .toString()
            .toLowerCase();
        final query = _searchQuery.toLowerCase();

        return name.contains(query) ||
            code.contains(query) ||
            phone.contains(query) ||
            contact.contains(query);
      }).toList();
    });
  }

  void _showMessage(String message, {required bool isError}) {
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  Future<void> _navigateToAddOffice() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AddOfficeScreen(api: widget.api, isArabic: widget.isArabic),
      ),
    );

    if (result == true) {
      _loadOffices();
    }
  }

  Future<void> _navigateToEditOffice(Map<String, dynamic> office) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddOfficeScreen(
          api: widget.api,
          isArabic: widget.isArabic,
          office: office,
        ),
      ),
    );

    if (result == true) {
      _loadOffices();
    }
  }

  Future<void> _toggleOfficeStatus(Map<String, dynamic> office) async {
    try {
      final isActive = office['active'] ?? true;
      if (isActive) {
        await widget.api.deleteOffice(office['id']);
        _showMessage('تم تعطيل المكتب', isError: false);
      } else {
        await widget.api.activateOffice(office['id']);
        _showMessage('تم تفعيل المكتب', isError: false);
      }
      _loadOffices();
    } catch (e) {
      _showMessage('خطأ في تغيير حالة المكتب: $e', isError: true);
    }
  }

  Future<void> _viewOfficeBalance(Map<String, dynamic> office) async {
    try {
      final balance = await widget.api.getOfficeBalance(office['id']);
      _showBalanceDialog(balance);
    } catch (e) {
      _showMessage('خطأ في تحميل الرصيد: $e', isError: true);
    }
  }

  void _showBalanceDialog(Map<String, dynamic> balance) {
    final isAr = widget.isArabic;
    final currencySymbol = context.read<SettingsProvider>().currencySymbolText;

    final cashBalance = _asDouble(balance['balance_cash']);
    final goldMap = (balance['balance_gold'] is Map)
        ? Map<String, dynamic>.from(balance['balance_gold'])
        : <String, dynamic>{};
    final goldTotalMain = _goldMainEquivalentFromGoldMap(goldMap);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAr ? 'رصيد المكتب' : 'Office Balance'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                balance['office_name'] ?? '',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              Text('${isAr ? "الكود" : "Code"}: ${balance['office_code']}'),

              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final kpis = (balance['kpis'] is Map)
                      ? Map<String, dynamic>.from(balance['kpis'])
                      : <String, dynamic>{};

                  final outstanding = _asDouble(
                    kpis['outstanding_weight_main_karat'],
                  );
                  final avgPrice = _asDouble(
                    kpis['avg_closing_price_per_gram'],
                  );

                  Widget kpiCard({
                    required String title,
                    required String value,
                    required IconData icon,
                  }) {
                    final theme = Theme.of(context);
                    return Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(icon, color: AppColors.darkGold),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(value),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: kpiCard(
                          title: isAr
                              ? 'الوزن المعلق (مكافئ العيار الرئيسي $_mainKarat)'
                              : 'Outstanding (${_mainKarat}k eq)',
                          value:
                              '${outstanding.toStringAsFixed(3)} ${isAr ? "جم" : "g"}',
                          icon: Icons.pending_actions,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: kpiCard(
                          title: isAr
                              ? 'متوسط تكلفة التسكير'
                              : 'Avg Closing Cost',
                          value:
                              '${avgPrice.toStringAsFixed(2)} $currencySymbol/${isAr ? "جم" : "g"}',
                          icon: Icons.price_change,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const Divider(height: 24),

              // النقدي
              Text(
                isAr ? 'الرصيد النقدي' : 'Cash Balance',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                _formatSigned(
                  cashBalance,
                  isArabic: isAr,
                  unitAr: currencySymbol,
                  unitEn: currencySymbol,
                  decimals: 2,
                ),
              ),
              const SizedBox(height: 12),

              // الذهب
              Text(
                isAr ? 'الرصيد الوزني' : 'Gold Balance',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              ...((balance['balance_gold'] as Map<String, dynamic>).entries
                  .where((e) => e.key != 'total')
                  .map(
                    (e) => Text(
                      '${isAr ? "عيار" : "Karat"} ${e.key}: ${_formatSigned(_asDouble(e.value), isArabic: isAr, unitAr: 'جم', unitEn: 'g', decimals: 3)}',
                    ),
                  )),
              Text(
                '${isAr ? "الإجمالي (مكافئ العيار الرئيسي $_mainKarat)" : "Total (${_mainKarat}k eq)"}: ${_formatSigned(goldTotalMain, isArabic: isAr, unitAr: 'جم', unitEn: 'g', decimals: 3)}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Divider(height: 24),

              // إحصائيات
              Text(
                isAr ? 'الإحصائيات' : 'Statistics',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '${isAr ? "عدد الحجوزات" : "Total Reservations"}: ${balance['statistics']['total_reservations']}',
              ),
              Text(
                '${isAr ? "إجمالي الوزن المشترى" : "Total Weight"}: ${balance['statistics']['total_weight_purchased']} ${isAr ? "جم" : "g"}',
              ),
              Text(
                '${isAr ? "إجمالي المبالغ المدفوعة" : "Total Paid"}: ${balance['statistics']['total_amount_paid']} $currencySymbol',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isAr ? 'إغلاق' : 'Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'المكاتب' : 'Offices'),
        backgroundColor: AppColors.darkGold,
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            key: const Key('offices-all-reservations'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GoldReservationsListScreen(api: widget.api, isArabic: isAr),
              ),
            ),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onPrimary),
            icon: const Icon(Icons.list_alt),
            label: Text(isAr ? 'كل الحجوزات' : 'All reservations'),
          ),
          IconButton(
            icon: Icon(
              _showActiveOnly ? Icons.visibility : Icons.visibility_off,
            ),
            onPressed: () {
              setState(() => _showActiveOnly = !_showActiveOnly);
              _loadOffices();
            },
            tooltip: isAr
                ? (_showActiveOnly ? 'إظهار الكل' : 'إظهار النشطة فقط')
                : (_showActiveOnly ? 'Show All' : 'Show Active Only'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOffices,
            tooltip: isAr ? 'تحديث' : 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // شريط البحث
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: isAr ? 'بحث' : 'Search',
                hintText: isAr
                    ? 'ابحث بالاسم، الكود، الهاتف...'
                    : 'Search by name, code, phone...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                          _applyFilters();
                        },
                      )
                    : null,
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
                _applyFilters();
              },
            ),
          ),

          // إحصائيات سريعة
          if (!_isLoading)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${isAr ? "العدد" : "Total"}: ${_filteredOffices.length}',
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${isAr ? "نشط" : "Active"}: ${_filteredOffices.where((o) => o['active'] == true).length}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
            ),

          // القائمة
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredOffices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.store_outlined,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isAr ? 'لا توجد مكاتب' : 'No offices found',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadOffices,
                    child: ListView.builder(
                      // Room under the last card for «إضافة مكتب», which covered its «تعديل».
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      itemCount: _filteredOffices.length,
                      itemBuilder: (context, index) {
                        final office = _filteredOffices[index];
                        return _buildOfficeCard(office);
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddOffice,
        backgroundColor: AppColors.primaryGold,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'إضافة مكتب' : 'Add Office'),
      ),
    );
  }

  Widget _buildOfficeCard(Map<String, dynamic> office) {
    final isAr = widget.isArabic;
    final currencySymbol = context.read<SettingsProvider>().currencySymbolText;
    final theme = Theme.of(context);
    final isActive = office['active'] ?? true;

    final cashBalance = _asDouble(office['balance_cash']);
    final goldTotal = _goldMainEquivalentFromOffice(office);
    // Our gold held there (ADR-052) -- the supplier balances beside it are the trade.
    final deposit = office['deposit'] is Map ? office['deposit'] as Map : null;
    final openCount = office['open_reservations'] is Map
        ? ((office['open_reservations'] as Map)['count'] as num? ?? 0).toInt()
        : 0;
    final depositGrams = _asDouble(deposit?['main_karat_total']);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: (isActive ? AppColors.success : AppColors.error).withValues(
            alpha: 0.4,
          ),
          width: 2,
        ),
      ),
      child: InkWell(
        onTap: () => _openOffice(office),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // الرأس
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        (isActive ? AppColors.success : AppColors.error)
                            .withValues(alpha: 0.12),
                    child: Icon(
                      Icons.store,
                      color: isActive ? AppColors.success : AppColors.error,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          office['name'] ?? '',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          office['office_code'] ?? '',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: (isActive ? AppColors.success : AppColors.error)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isActive
                          ? (isAr ? 'نشط' : 'Active')
                          : (isAr ? 'معطل' : 'Inactive'),
                      style: TextStyle(
                        color: isActive ? AppColors.success : AppColors.error,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // التفاصيل
              if (office['contact_person'] != null &&
                  office['contact_person'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.person,
                  isAr ? 'المسؤول' : 'Contact',
                  office['contact_person'],
                ),
              if (office['phone'] != null &&
                  office['phone'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.phone,
                  isAr ? 'الهاتف' : 'Phone',
                  office['phone'],
                ),
              if (office['city'] != null &&
                  office['city'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.location_on,
                  isAr ? 'المدينة' : 'City',
                  office['city'],
                ),

              const Divider(height: 24),

              // الأرصدة: ذهبنا المودع أولًا، ثم ما بيننا وبين المكتب (ADR-052)
              Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: Key('office-deposit-${office['id']}'),
                      child: _buildBalanceTile(
                        isAr ? 'وديعة الذهب' : 'Gold deposit',
                        deposit == null
                            ? (isAr ? 'لا وديعة' : 'No deposit')
                            : '${ltrIsolate(formatGrams(depositGrams))} ${isAr ? 'جم' : 'g'}',
                        AppColors.primaryGold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: KeyedSubtree(
                      key: Key('office-cash-${office['id']}'),
                      child: _buildBalanceTile(
                        isAr ? 'الحساب النقدي' : 'Cash',
                        _officeCashText(cashBalance, currencySymbol, isAr),
                        cashBalance < -0.005
                            ? AppColors.error
                            : AppColors.success,
                      ),
                    ),
                  ),
                  if (goldTotal.abs() >= 0.0005) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildBalanceTile(
                        isAr ? 'ذهب الحساب التجاري' : 'Trade gold',
                        _formatSigned(
                          goldTotal,
                          isArabic: isAr,
                          unitAr: 'جم',
                          unitEn: 'g',
                          decimals: 3,
                        ),
                        AppSemanticColors.of(context).gold.fg,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),

              // الأزرار: الخطوة التالية ظاهرة، لا خلف الضغط على البطاقة
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    key: Key('office-new-reservation-${office['id']}'),
                    onPressed: isActive ? () => _newReservation(office) : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(isAr ? 'حجز جديد' : 'New reservation'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: Key('office-reservations-${office['id']}'),
                    onPressed: () => _openOffice(office),
                    icon: const Icon(Icons.lock_clock, size: 18),
                    label: Text(
                      openCount > 0
                          ? (isAr
                                ? 'الحجوزات · ${ltrIsolate('$openCount')} مفتوحة'
                                : 'Reservations · $openCount open')
                          : (isAr ? 'الحجوزات' : 'Reservations'),
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _viewOfficeBalance(office),
                    icon: const Icon(Icons.account_balance_wallet, size: 18),
                    label: Text(isAr ? 'الرصيد' : 'Balance'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _navigateToEditOffice(office),
                    icon: const Icon(Icons.edit, size: 18),
                    label: Text(isAr ? 'تعديل' : 'Edit'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _toggleOfficeStatus(office),
                    icon: Icon(
                      isActive ? Icons.block : Icons.check_circle,
                      size: 18,
                    ),
                    label: Text(
                      isActive
                          ? (isAr ? 'تعطيل' : 'Deactivate')
                          : (isAr ? 'تفعيل' : 'Activate'),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: isActive
                          ? AppColors.error
                          : AppColors.success,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          Expanded(
            child: Text(
              value?.toString() ?? '',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
