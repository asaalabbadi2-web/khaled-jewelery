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
import '../utils/party_balance.dart';
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

  double _asDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  /// What is between us and the office, as on the safes' deposit card
  /// (ADR-052): below zero owed to it, above ours with it -- its riyals and
  /// its gold in the same words.
  String _sideText(double amount, String number, String unit, bool isAr, {double least = 0.005}) {
    final value = '${ltrIsolate(number)} $unit';
    if (amount < -least) return isAr ? 'مستحق للمكتب $value' : 'Owed $value';
    if (amount > least) return isAr ? 'لنا عند المكتب $value' : 'Ours $value';
    return isAr ? 'مسوّى' : 'Settled';
  }

  /// The main karat, the settings' -- never a fixed one (the owner, 20 Oct 2026).
  int get _mainKarat => context.read<SettingsProvider>().mainKarat;

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

  /// The office's gold on its supplier account, all karats in the main one.
  double _goldMainEquivalentFromOffice(Map<String, dynamic> office) => goldInMainKarat({
    for (final k in const [18, 21, 22, 24]) k: _asDouble(office['balance_gold_${k}k']),
  }, _mainKarat);

  @override
  void initState() {
    super.initState();
    _loadOffices();
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
      if (!mounted) return;
      setState(() {
        _offices = offices;
        _applyFilters();
      });
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر تحميل المكاتب');
    } finally {
      if (mounted) setState(() => _isLoading = false);
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

  /// Stopping asks first; the server stops only a settled office (the owner,
  /// 20 Oct 2026) and says why it will not.
  Future<void> _toggleOfficeStatus(Map<String, dynamic> office) async {
    final isActive = office['active'] ?? true;
    if (isActive) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('تعطيل «${office['name'] ?? ''}»؟'),
          content: const Text(
            'يُعطَّل المكتب إن لم يبقَ بيننا وبينه شيء: لا ذهب لنا في وديعته، '
            'ولا رصيد نقدي أو ذهبي، ولا حجز لم يُنفَّذ.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
            FilledButton(
              key: const Key('office-stop-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تعطيل'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    try {
      if (isActive) {
        await widget.api.deleteOffice(office['id']);
        _showMessage('تم تعطيل المكتب', isError: false);
      } else {
        await widget.api.activateOffice(office['id']);
        _showMessage('تم تفعيل المكتب', isError: false);
      }
      _loadOffices();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: isActive ? 'لم يُعطَّل المكتب' : 'لم يُفعَّل المكتب');
    }
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
                        _sideText(cashBalance, formatAmount(cashBalance.abs()), currencySymbol, isAr),
                        cashBalance < -0.005
                            ? AppColors.error
                            : AppColors.success,
                      ),
                    ),
                  ),
                  if (goldTotal.abs() >= 0.0005) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: KeyedSubtree(
                        key: Key('office-gold-${office['id']}'),
                        child: _buildBalanceTile(
                          isAr ? 'الحساب الذهبي' : 'Gold account',
                          _sideText(
                            goldTotal,
                            formatGrams(goldTotal.abs()),
                            isAr ? 'جم بالعيار $_mainKarat' : 'g of ${_mainKarat}k',
                            isAr,
                            least: 0.0005,
                          ),
                          AppSemanticColors.of(context).gold.fg,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),

              // الأزرار: الخطوة التالية ظاهرة، والباقي تحت «المزيد» -- في
              // سطر يلتفّ، فلا يخرج «حجز جديد» عن شاشة الجوال (المالك، 20 أكتوبر 2026).
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: Key('office-new-reservation-${office['id']}'),
                    onPressed: isActive ? () => _newReservation(office) : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(isAr ? 'حجز جديد' : 'New reservation'),
                  ),
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
                  PopupMenuButton<String>(
                    key: Key('office-more-${office['id']}'),
                    tooltip: isAr ? 'المزيد' : 'More',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (choice) => choice == 'edit'
                        ? _navigateToEditOffice(office)
                        : _toggleOfficeStatus(office),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit),
                          title: Text(isAr ? 'تعديل' : 'Edit'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'status',
                        child: ListTile(
                          leading: Icon(isActive ? Icons.block : Icons.check_circle),
                          title: Text(
                            isActive ? (isAr ? 'تعطيل' : 'Deactivate') : (isAr ? 'تفعيل' : 'Activate'),
                          ),
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
