import 'package:flutter/material.dart';
import '../api_service.dart';
import 'add_customer_screen.dart';
import 'account_statement_screen.dart';

class CustomersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const CustomersScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  late Future<List> _customersFuture;
  List _allCustomers = [];
  List _filteredCustomers = [];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _customersFuture = _loadCustomers();
    _searchController.addListener(_filterCustomers);
  }

  Future<List> _loadCustomers() async {
    try {
      final customers = await widget.api.getCustomers();
      setState(() {
        _allCustomers = customers;
        _filteredCustomers = customers;
      });
      return customers;
    } catch (e) {
      // Handle error appropriately
      debugPrint('Error loading customers: $e');
      return [];
    }
  }

  void _filterCustomers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredCustomers = _allCustomers.where((c) {
        final name = (c['name'] ?? '').toLowerCase();
        final phone = (c['phone'] ?? '').toLowerCase();
        return name.contains(query) || phone.contains(query);
      }).toList();
    });
  }

  void _refreshCustomers() {
    setState(() {
      _customersFuture = _loadCustomers();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool isDark = theme.brightness == Brightness.dark;

    final gold = colorScheme.primary;
    final scaffoldBackgroundColor = theme.scaffoldBackgroundColor;
    final cardColor = theme.cardTheme.color ?? colorScheme.surface;
    final subtitleColor = colorScheme.onSurface.withValues(alpha: isDark ? 0.7 : 0.6);

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'قائمة العملاء' : 'Customers'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: gold),
            onPressed: _refreshCustomers,
            tooltip: isAr ? 'تحديث' : 'Refresh',
          ),
        ],
      ),
      backgroundColor: scaffoldBackgroundColor,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: isAr
                    ? 'بحث بالاسم أو الهاتف...'
                    : 'Search by name or phone...',
                prefixIcon: Icon(Icons.search, color: gold),
                filled: true,
                fillColor: cardColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                hintStyle: textTheme.bodyMedium?.copyWith(color: subtitleColor),
              ),
              style: textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurface,
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List>(
              future: _customersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: gold));
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      isAr ? 'خطأ في تحميل البيانات' : 'Error loading data',
                      style: textTheme.bodyLarge?.copyWith(color: Colors.red),
                    ),
                  );
                }
                if (_filteredCustomers.isEmpty) {
                  return Center(
                    child: Text(
                      isAr ? 'لا يوجد عملاء' : 'No customers found',
                      style: textTheme.headlineSmall?.copyWith(color: gold),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _filteredCustomers.length,
                  itemBuilder: (context, i) {
                    final c = _filteredCustomers[i];
                    return Card(
                      color: cardColor,
                      elevation: theme.cardTheme.elevation ?? 4,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      shape:
                          theme.cardTheme.shape ??
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: gold,
                          child: Icon(
                            Icons.person,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              c['name'] ?? '',
                              style: textTheme.titleMedium?.copyWith(
                                color: gold,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (c['customer_code'] != null) ...[
                              SizedBox(width: 8),
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: gold.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: gold.withValues(alpha: 0.5),
                                  ),
                                ),
                                child: Text(
                                  c['customer_code'],
                                  style: textTheme.bodySmall?.copyWith(
                                    color: gold,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          c['phone'] ?? '',
                          style: textTheme.bodyMedium?.copyWith(
                            color: subtitleColor,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit, color: Colors.blue),
                              tooltip: isAr ? 'تعديل' : 'Edit',
                              onPressed: () async {
                                final result = await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => AddCustomerScreen(
                                      api: widget.api,
                                      customer: c,
                                      isArabic: isAr,
                                    ),
                                  ),
                                );
                                if (result == true) {
                                  _refreshCustomers();
                                }
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.receipt_long,
                                color: Colors.green,
                              ),
                              tooltip: isAr ? 'كشف حساب' : 'Account Statement',
                              onPressed: () {
                                // Use customer ID directly for hybrid system
                                final customerId = c['id'];
                                if (customerId != null) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          AccountStatementScreen(
                                            accountId: customerId,
                                            accountName: c['name'],
                                          ),
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        isAr
                                            ? 'لا يوجد حساب مرتبط بهذا العميل'
                                            : 'No account linked to this customer',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.delete, color: Colors.red),
                              tooltip: isAr ? 'حذف' : 'Delete',
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(
                                      isAr ? 'تأكيد الحذف' : 'Confirm Deletion',
                                    ),
                                    content: Text(
                                      isAr
                                          ? 'هل أنت متأكد من حذف هذا العميل؟'
                                          : 'Are you sure you want to delete this customer?',
                                    ),
                                    actions: [
                                      TextButton(
                                        child: Text(isAr ? 'إلغاء' : 'Cancel'),
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                      ),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),
                                        child: Text(isAr ? 'حذف' : 'Delete'),
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  try {
                                    await widget.api.deleteCustomer(c['id']);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          isAr
                                              ? 'تم حذف العميل بنجاح'
                                              : 'Customer deleted successfully',
                                        ),
                                        backgroundColor: Colors.green,
                                      ),
                                    );
                                    _refreshCustomers();
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '${isAr ? "خطأ في الحذف: " : "Deletion failed: "}${e.toString()}',
                                        ),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  AddCustomerScreen(api: widget.api, isArabic: isAr),
            ),
          );
          if (result == true) {
            _refreshCustomers();
          }
        },
        tooltip: isAr ? 'إضافة عميل' : 'Add Customer',
        child: Icon(Icons.add, color: colorScheme.onPrimary),
      ),
    );
  }
}
