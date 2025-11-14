import 'package:flutter/material.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import 'add_office_screen.dart';

/// شاشة قائمة المكاتب (مكاتب بيع وشراء الذهب الخام)
class OfficesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const OfficesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

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
        final contact = (office['contact_person'] ?? '').toString().toLowerCase();
        final query = _searchQuery.toLowerCase();
        
        return name.contains(query) ||
               code.contains(query) ||
               phone.contains(query) ||
               contact.contains(query);
      }).toList();
    });
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
      ),
    );
  }

  Future<void> _navigateToAddOffice() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddOfficeScreen(api: widget.api, isArabic: widget.isArabic),
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
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              Text('${isAr ? "الكود" : "Code"}: ${balance['office_code']}'),
              const Divider(height: 24),
              
              // النقدي
              Text(
                isAr ? 'الرصيد النقدي' : 'Cash Balance',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('${balance['balance_cash']} ${isAr ? "ر.س" : "SAR"}'),
              const SizedBox(height: 12),
              
              // الذهب
              Text(
                isAr ? 'الرصيد الوزني' : 'Gold Balance',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              ...((balance['balance_gold'] as Map<String, dynamic>).entries
                  .where((e) => e.key != 'total')
                  .map((e) => Text('${isAr ? "عيار" : "Karat"} ${e.key}: ${e.value} ${isAr ? "جم" : "g"}'))),
              Text(
                '${isAr ? "الإجمالي" : "Total"}: ${balance['balance_gold']['total']} ${isAr ? "جم" : "g"}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Divider(height: 24),
              
              // إحصائيات
              Text(
                isAr ? 'الإحصائيات' : 'Statistics',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('${isAr ? "عدد الحجوزات" : "Total Reservations"}: ${balance['statistics']['total_reservations']}'),
              Text('${isAr ? "إجمالي الوزن المشترى" : "Total Weight"}: ${balance['statistics']['total_weight_purchased']} ${isAr ? "جم" : "g"}'),
              Text('${isAr ? "إجمالي المبالغ المدفوعة" : "Total Paid"}: ${balance['statistics']['total_amount_paid']} ${isAr ? "ر.س" : "SAR"}'),
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
          IconButton(
            icon: Icon(_showActiveOnly ? Icons.visibility : Icons.visibility_off),
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
                    style: theme.textTheme.titleSmall?.copyWith(color: AppColors.success),
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
                            Icon(Icons.store_outlined,
                                size: 64, color: Colors.grey.shade400),
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
                          padding: const EdgeInsets.all(16),
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
    final theme = Theme.of(context);
    final isActive = office['active'] ?? true;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: (isActive ? AppColors.success : AppColors.error).withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: InkWell(
        onTap: () => _navigateToEditOffice(office),
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
                    backgroundColor: (isActive ? AppColors.success : AppColors.error)
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
              if (office['contact_person'] != null && office['contact_person'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.person,
                  isAr ? 'المسؤول' : 'Contact',
                  office['contact_person'],
                ),
              if (office['phone'] != null && office['phone'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.phone,
                  isAr ? 'الهاتف' : 'Phone',
                  office['phone'],
                ),
              if (office['city'] != null && office['city'].toString().isNotEmpty)
                _buildInfoRow(
                  Icons.location_on,
                  isAr ? 'المدينة' : 'City',
                  office['city'],
                ),
              
              const Divider(height: 24),
              
              // الأرصدة
              Row(
                children: [
                  Expanded(
                    child: _buildBalanceTile(
                      isAr ? 'النقدي' : 'Cash',
                      '${office['balance_cash']} ${isAr ? "ر.س" : "SAR"}',
                      AppColors.success,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildBalanceTile(
                      isAr ? 'الوزن' : 'Weight',
                      '${office['balance_gold']?['total'] ?? 0} ${isAr ? "جم" : "g"}',
                      AppColors.primaryGold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // الأزرار
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
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
                      foregroundColor:
                          isActive ? AppColors.error : AppColors.success,
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
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
            ),
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
