import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';
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
    context.watch<SettingsProvider>();

    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final bool isDark = theme.brightness == Brightness.dark;

    final gold = colorScheme.primary;
    final scaffoldBackgroundColor = theme.scaffoldBackgroundColor;
    final cardColor = theme.cardTheme.color ?? colorScheme.surface;
    final subtitleColor = colorScheme.onSurface.withValues(
      alpha: isDark ? 0.7 : 0.6,
    );

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

                    double toDoubleVal(dynamic v) => (v == null)
                        ? 0.0
                        : double.tryParse(v.toString()) ?? 0.0;

                    final gold18k = toDoubleVal(c['balance_gold_18k']);
                    final gold21k = toDoubleVal(c['balance_gold_21k']);
                    final gold22k = toDoubleVal(c['balance_gold_22k']);
                    final gold24k = toDoubleVal(c['balance_gold_24k']);
                    final cashBalance = toDoubleVal(c['balance_cash']);
                    // The settings' main karat, never a fixed one.
                    final mainKarat = context
                        .read<SettingsProvider>()
                        .mainKarat
                        .toDouble();
                    final goldMain =
                        (gold18k * (18.0 / mainKarat)) +
                        (gold21k * (21.0 / mainKarat)) +
                        (gold22k * (22.0 / mainKarat)) +
                        (gold24k * (24.0 / mainKarat));

                    final nonZeroKarats = <MapEntry<String, double>>[
                      MapEntry('18k', gold18k),
                      MapEntry('21k', gold21k),
                      MapEntry('22k', gold22k),
                      MapEntry('24k', gold24k),
                    ].where((e) => e.value.abs() > 0.0001).toList();
                    final showKaratChips = nonZeroKarats.length >= 2;

                    final hasBalance =
                        goldMain.abs() > 0.0001 || cashBalance.abs() > 0.0001;

                    return Card(
                      color: cardColor,
                      elevation: theme.cardTheme.elevation ?? 4,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      shape:
                          theme.cardTheme.shape ??
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          final customerId = c['id'];
                          if (customerId != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AccountStatementScreen(
                                  accountId: customerId,
                                  accountName: c['name'],
                                  entityType: 'customer',
                                ),
                              ),
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // -- Header row --
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: gold,
                                    child: Icon(
                                      Icons.person,
                                      color: colorScheme.onPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                c['name'] ?? '',
                                                style: textTheme.titleMedium
                                                    ?.copyWith(
                                                      color: gold,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                              ),
                                            ),
                                            if (c['customer_code'] != null) ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: gold.withValues(
                                                    alpha: 0.2,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  border: Border.all(
                                                    color: gold.withValues(
                                                      alpha: 0.5,
                                                    ),
                                                  ),
                                                ),
                                                child: Text(
                                                  c['customer_code'],
                                                  style: textTheme.bodySmall
                                                      ?.copyWith(
                                                        color: gold,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        if ((c['phone'] ?? '')
                                            .toString()
                                            .isNotEmpty)
                                          Text(
                                            c['phone'] ?? '',
                                            style: textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: subtitleColor,
                                                ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  // Actions
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.edit,
                                          color: Colors.blue,
                                        ),
                                        tooltip: isAr ? 'تعديل' : 'Edit',
                                        onPressed: () async {
                                          final result = await Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  AddCustomerScreen(
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
                                        icon: const Icon(
                                          Icons.receipt_long,
                                          color: Colors.green,
                                        ),
                                        tooltip: isAr
                                            ? 'كشف حساب'
                                            : 'Account Statement',
                                        onPressed: () {
                                          final customerId = c['id'];
                                          if (customerId != null) {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    AccountStatementScreen(
                                                      accountId: customerId,
                                                      accountName: c['name'],
                                                      entityType: 'customer',
                                                    ),
                                              ),
                                            );
                                          }
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete,
                                          color: Colors.red,
                                        ),
                                        tooltip: isAr ? 'حذف' : 'Delete',
                                        onPressed: () async {
                                          final confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              title: Text(
                                                isAr
                                                    ? 'تأكيد الحذف'
                                                    : 'Confirm Deletion',
                                              ),
                                              content: Text(
                                                isAr
                                                    ? 'هل أنت متأكد من حذف هذا العميل؟'
                                                    : 'Are you sure you want to delete this customer?',
                                              ),
                                              actions: [
                                                TextButton(
                                                  child: Text(
                                                    isAr ? 'إلغاء' : 'Cancel',
                                                  ),
                                                  onPressed: () =>
                                                      Navigator.pop(ctx, false),
                                                ),
                                                ElevatedButton(
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                        backgroundColor:
                                                            Colors.red,
                                                      ),
                                                  child: Text(
                                                    isAr ? 'حذف' : 'Delete',
                                                  ),
                                                  onPressed: () =>
                                                      Navigator.pop(ctx, true),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm == true) {
                                            try {
                                              await widget.api.deleteCustomer(
                                                c['id'],
                                              );
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
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
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
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
                                ],
                              ),
                              // -- Balance section (only if has balance) --
                              if (hasBalance) ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: theme.colorScheme.outline
                                          .withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (cashBalance.abs() > 0.0001) ...[
                                        Icon(
                                          Icons.payments_outlined,
                                          size: 13,
                                          color: subtitleColor,
                                        ),
                                        const SizedBox(width: 4),
                                        context.read<SettingsProvider>().buildText(
                                          '${cashBalance.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: cashBalance < 0
                                                ? const Color(0xFFD32F2F)
                                                : const Color(0xFF2E7D32),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                      ],
                                      if (goldMain.abs() > 0.0001)
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.diamond_outlined,
                                              size: 13,
                                              color: const Color(0xFFC69214),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '${goldMain.toStringAsFixed(3)} ${isAr ? 'جم' : 'g'}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: goldMain < 0
                                                    ? const Color(0xFFD32F2F)
                                                    : const Color(0xFFC69214),
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                                if (showKaratChips) ...[
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Wrap(
                                      spacing: 5,
                                      runSpacing: 4,
                                      children: nonZeroKarats.map((e) {
                                        const chipColor = Color(0xFFC69214);
                                        return Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: chipColor.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: chipColor.withValues(
                                                alpha: 0.28,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            '${e.key}: ${e.value.abs().toStringAsFixed(3)} ${isAr ? 'جم' : 'g'}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: chipColor,
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ],
                              ],
                            ],
                          ),
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
