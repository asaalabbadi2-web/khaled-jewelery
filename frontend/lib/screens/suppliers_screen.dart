import 'package:flutter/material.dart';
import '../api_service.dart';
import 'add_supplier_screen.dart';
import 'supplier_ledger_screen.dart';

class SuppliersScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SuppliersScreen({super.key, required this.api, this.isArabic = true});

  @override
  SuppliersScreenState createState() => SuppliersScreenState();
}

class SuppliersScreenState extends State<SuppliersScreen> {
  late Future<List<dynamic>> _suppliersFuture;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  void _loadSuppliers() {
    setState(() {
      _suppliersFuture = widget.api.getSuppliers();
    });
  }

  Future<void> _deleteSupplier(int id) async {
    try {
      await widget.api.deleteSupplier(id);
      if (!mounted) return;
      _loadSuppliers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete supplier: $e')));
    }
  }

  void _navigateToAddSupplier({Map<String, dynamic>? supplier}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            AddSupplierScreen(api: widget.api, supplier: supplier),
      ),
    );
    if (result == true) {
      if (!mounted) return;
      _loadSuppliers();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'الموردين' : 'Suppliers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _navigateToAddSupplier(),
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _suppliersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('لا يوجد موردين'));
          }

          final suppliers = snapshot.data!;
          return ListView.builder(
            itemCount: suppliers.length,
            itemBuilder: (context, index) {
              final supplier = suppliers[index];
              final isAr = widget.isArabic;
              final gold = const Color(0xFFF7C873);

              return ListTile(
                title: Row(
                  children: [
                    Expanded(child: Text(supplier['name'])),
                    if (supplier['supplier_code'] != null)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: gold.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: gold, width: 1),
                        ),
                        child: Text(
                          supplier['supplier_code'],
                          style: TextStyle(
                            color: gold,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(supplier['phone'] ?? ''),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.receipt_long),
                      tooltip: isAr ? 'كشف حساب المورد' : 'Supplier Ledger',
                      onPressed: () {
                        final supplierId = supplier['id'];
                        if (supplierId != null) {
                          final supplierName = (supplier['name'] ?? '')
                              .toString();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => SupplierLedgerScreen(
                                api: widget.api,
                                supplierId: supplierId,
                                supplierName: supplierName,
                                isArabic: isAr,
                              ),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                isAr
                                    ? 'لا يوجد معرف صالح لهذا المورد'
                                    : 'Supplier is missing a valid id',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () =>
                          _navigateToAddSupplier(supplier: supplier),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () => _deleteSupplier(supplier['id']),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
