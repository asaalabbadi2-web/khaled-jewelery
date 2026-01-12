import 'package:flutter/material.dart';
import '../api_service.dart';
import '../utils.dart';

/// شاشة التجديد والتكسير
/// 1. تجديد القطع المستعملة: عند شراء ذهب مستعمل نظيف يُجدد ويُعرض
/// 2. تكسير المخزون الراكد: قطع قديمة في المخزون تُكسر إلى صندوق الكسر
class MeltingRenewalScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const MeltingRenewalScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<MeltingRenewalScreen> createState() => _MeltingRenewalScreenState();
}

class _MeltingRenewalScreenState extends State<MeltingRenewalScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'التجديد والتكسير' : 'Renewal & Melting'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.auto_fix_high),
              text: isAr ? 'تجديد القطع' : 'Renewal',
            ),
            Tab(
              icon: const Icon(Icons.delete_sweep),
              text: isAr ? 'تكسير المخزون' : 'Melting',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _RenewalTab(api: widget.api, isArabic: isAr),
          _MeltingTab(api: widget.api, isArabic: isAr),
        ],
      ),
    );
  }
}

// ==================== تبويب التجديد ====================
class _RenewalTab extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const _RenewalTab({required this.api, required this.isArabic});

  @override
  State<_RenewalTab> createState() => _RenewalTabState();
}

class _RenewalTabState extends State<_RenewalTab> {
  final _formKey = GlobalKey<FormState>();
  int? _selectedCustomerId;
  List<Map<String, dynamic>> _customers = [];
  final List<RenewalItem> _items = [];
  bool _loading = false;
  double _goldPrice = 0.0;
  final TextEditingController _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final customers = await widget.api.getCustomers();
      final goldPriceData = await widget.api.getGoldPrice();

      setState(() {
        _customers = List<Map<String, dynamic>>.from(customers);
        _goldPrice = (goldPriceData['price_21'] as num?)?.toDouble() ?? 0.0;
      });
    } catch (e) {
      _showSnack('خطأ في تحميل البيانات: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  void _addItem() {
    showDialog(
      context: context,
      builder: (context) => _RenewalItemDialog(
        isArabic: widget.isArabic,
        goldPrice: _goldPrice,
        onAdd: (item) {
          setState(() => _items.add(item));
        },
      ),
    );
  }

  void _removeItem(int index) {
    setState(() => _items.removeAt(index));
  }

  double get _totalWeight => _items.fold(0.0, (sum, item) => sum + item.weight);
  double get _totalPurchaseValue =>
      _items.fold(0.0, (sum, item) => sum + item.purchaseValue);

  Future<void> _submitRenewal() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedCustomerId == null) {
      _showSnack(
        widget.isArabic ? 'يجب اختيار العميل' : 'Customer required',
        isError: true,
      );
      return;
    }

    if (_items.isEmpty) {
      _showSnack(
        widget.isArabic ? 'يجب إضافة قطع' : 'Items required',
        isError: true,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'تأكيد التجديد' : 'Confirm Renewal'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.isArabic ? 'عدد القطع' : 'Items'}: ${_items.length}',
            ),
            Text(
              '${widget.isArabic ? 'الوزن الإجمالي' : 'Total Weight'}: ${_totalWeight.toStringAsFixed(3)} جم',
            ),
            Text(
              '${widget.isArabic ? 'قيمة الشراء' : 'Purchase Value'}: ${_totalPurchaseValue.toStringAsFixed(2)} ريال',
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'سيتم إضافة القطع للمخزون كأصناف جديدة للبيع'
                  : 'Items will be added to inventory for sale',
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.isArabic ? 'تأكيد' : 'Confirm'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);

    try {
      final payload = {
        'operation_type': 'renewal',
        'customer_id': _selectedCustomerId,
        'items': _items.map((item) => item.toJson()).toList(),
        'total_weight': _totalWeight,
        'total_value': _totalPurchaseValue,
        'notes': _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      };

      debugPrint('Renewal payload: $payload');

      // TODO: استدعاء API
      // await widget.api.createMeltingRenewal(payload);

      _showSnack(
        widget.isArabic
            ? 'تم تسجيل عملية التجديد بنجاح'
            : 'Renewal recorded successfully',
      );

      _resetForm();
    } catch (e) {
      _showSnack('خطأ: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  void _resetForm() {
    setState(() {
      _selectedCustomerId = null;
      _items.clear();
      _notesController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // معلومات توضيحية
          Card(
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue[700]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isAr
                          ? 'تجديد القطع المستعملة النظيفة المشتراة من العملاء لإعادة عرضها وبيعها'
                          : 'Renew clean used items purchased from customers for resale',
                      style: TextStyle(color: Colors.blue[900], fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // اختيار العميل
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<int>(
                initialValue: _selectedCustomerId,
                decoration: InputDecoration(
                  labelText: isAr ? 'العميل البائع' : 'Seller Customer',
                  prefixIcon: const Icon(Icons.person),
                  border: const OutlineInputBorder(),
                ),
                items: _customers.map((customer) {
                  return DropdownMenuItem<int>(
                    value: customer['id'],
                    child: Text(customer['name'] ?? ''),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedCustomerId = value);
                },
                validator: (value) {
                  if (value == null) {
                    return isAr ? 'اختر العميل' : 'Select customer';
                  }
                  return null;
                },
              ),
            ),
          ),

          const SizedBox(height: 16),

          // القطع المجددة
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isAr ? 'القطع المشتراة للتجديد' : 'Items for Renewal',
                        style: theme.textTheme.titleMedium,
                      ),
                      FilledButton.icon(
                        onPressed: _addItem,
                        icon: const Icon(Icons.add),
                        label: Text(isAr ? 'إضافة قطعة' : 'Add Item'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_items.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          isAr ? 'لم يتم إضافة قطع' : 'No items added',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _items.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.amber[100],
                            child: const Icon(
                              Icons.diamond,
                              color: Colors.amber,
                            ),
                          ),
                          title: Text(item.description),
                          subtitle: Text(
                            '${item.weight.toStringAsFixed(3)} جم × عيار ${item.karat}\n'
                            'سعر الشراء: ${item.purchaseValue.toStringAsFixed(2)} ريال',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _removeItem(index),
                          ),
                        );
                      },
                    ),
                  if (_items.isNotEmpty) ...[
                    const Divider(thickness: 2),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isAr ? 'الإجمالي:' : 'Total:',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${_totalWeight.toStringAsFixed(3)} جم',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '${_totalPurchaseValue.toStringAsFixed(2)} ريال',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ملاحظات
          TextFormField(
            controller: _notesController,
            decoration: InputDecoration(
              labelText: isAr ? 'ملاحظات' : 'Notes',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.note),
            ),
            maxLines: 3,
          ),

          const SizedBox(height: 24),

          // أزرار الحفظ
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetForm,
                  icon: const Icon(Icons.clear),
                  label: Text(isAr ? 'إلغاء' : 'Clear'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _submitRenewal,
                  icon: const Icon(Icons.save),
                  label: Text(isAr ? 'حفظ التجديد' : 'Save Renewal'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==================== تبويب التكسير ====================
class _MeltingTab extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const _MeltingTab({required this.api, required this.isArabic});

  @override
  State<_MeltingTab> createState() => _MeltingTabState();
}

class _MeltingTabState extends State<_MeltingTab> {
  final _formKey = GlobalKey<FormState>();
  List<Map<String, dynamic>> _inventoryItems = [];
  final List<InventoryItem> _selectedItems = [];
  bool _loading = false;
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInventory();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInventory() async {
    setState(() => _loading = true);
    try {
      final items = await widget.api.getItems();
      setState(() {
        _inventoryItems = List<Map<String, dynamic>>.from(items);
      });
    } catch (e) {
      _showSnack('خطأ في تحميل المخزون: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  void _selectItem() {
    showDialog(
      context: context,
      builder: (context) => _SelectInventoryDialog(
        isArabic: widget.isArabic,
        items: _inventoryItems,
        searchController: _searchController,
        onSelect: (item) {
          final inventoryItem = InventoryItem(
            itemId: item['id'],
            itemCode: item['item_code'] ?? '',
            name: item['name'] ?? '',
            weight: (item['weight'] as num?)?.toDouble() ?? 0.0,
            karat: item['karat'] ?? 21,
            quantity: 1, // يمكن تعديله
          );
          setState(() => _selectedItems.add(inventoryItem));
        },
      ),
    );
  }

  void _removeItem(int index) {
    setState(() => _selectedItems.removeAt(index));
  }

  double get _totalWeight => _selectedItems.fold(
    0.0,
    (sum, item) => sum + (item.weight * item.quantity),
  );

  Future<void> _submitMelting() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedItems.isEmpty) {
      _showSnack(
        widget.isArabic ? 'يجب اختيار أصناف للتكسير' : 'Select items to melt',
        isError: true,
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'تأكيد التكسير' : 'Confirm Melting'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.isArabic ? 'عدد الأصناف' : 'Items'}: ${_selectedItems.length}',
            ),
            Text(
              '${widget.isArabic ? 'الوزن الإجمالي' : 'Total Weight'}: ${_totalWeight.toStringAsFixed(3)} جم',
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.isArabic
                          ? 'سيتم حذف هذه الأصناف من المخزون ونقلها لصندوق الكسر'
                          : 'Items will be removed from inventory and moved to melting box',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(widget.isArabic ? 'تأكيد التكسير' : 'Confirm Melting'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);

    try {
      final payload = {
        'operation_type': 'melting',
        'items': _selectedItems.map((item) => item.toJson()).toList(),
        'total_weight': _totalWeight,
        'notes': _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      };

      debugPrint('Melting payload: $payload');

      // TODO: استدعاء API
      // await widget.api.createMeltingRenewal(payload);

      _showSnack(
        widget.isArabic
            ? 'تم تسجيل عملية التكسير بنجاح'
            : 'Melting recorded successfully',
      );

      _resetForm();
      _loadInventory(); // إعادة تحميل المخزون
    } catch (e) {
      _showSnack('خطأ: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  void _resetForm() {
    setState(() {
      _selectedItems.clear();
      _notesController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // معلومات توضيحية
          Card(
            color: Colors.orange[50],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange[700]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isAr
                          ? 'تكسير القطع الراكدة في المخزون ونقلها إلى صندوق الكسر'
                          : 'Melt stagnant inventory items and transfer to melting box',
                      style: TextStyle(color: Colors.orange[900], fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // الأصناف المحددة للتكسير
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isAr ? 'الأصناف المحددة للتكسير' : 'Items to Melt',
                        style: theme.textTheme.titleMedium,
                      ),
                      FilledButton.icon(
                        onPressed: _selectItem,
                        icon: const Icon(Icons.add),
                        label: Text(isAr ? 'اختيار صنف' : 'Select Item'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_selectedItems.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          isAr ? 'لم يتم اختيار أصناف' : 'No items selected',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _selectedItems.length,
                      separatorBuilder: (context, index) => const Divider(),
                      itemBuilder: (context, index) {
                        final item = _selectedItems[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.red[100],
                            child: const Icon(
                              Icons.delete_forever,
                              color: Colors.red,
                            ),
                          ),
                          title: Text(item.name),
                          subtitle: Text(
                            '${item.itemCode}\n'
                            '${item.weight.toStringAsFixed(3)} جم × ${item.quantity} = ${(item.weight * item.quantity).toStringAsFixed(3)} جم\n'
                            'عيار ${item.karat}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () {
                                  if (item.quantity > 1) {
                                    setState(() => item.quantity--);
                                  }
                                },
                              ),
                              Text('${item.quantity}'),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () {
                                  setState(() => item.quantity++);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: () => _removeItem(index),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  if (_selectedItems.isNotEmpty) ...[
                    const Divider(thickness: 2),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isAr ? 'الوزن الإجمالي:' : 'Total Weight:',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${_totalWeight.toStringAsFixed(3)} جم',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ملاحظات
          TextFormField(
            controller: _notesController,
            decoration: InputDecoration(
              labelText: isAr ? 'ملاحظات (سبب التكسير)' : 'Notes (Reason)',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.note),
            ),
            maxLines: 3,
          ),

          const SizedBox(height: 24),

          // أزرار الحفظ
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetForm,
                  icon: const Icon(Icons.clear),
                  label: Text(isAr ? 'إلغاء' : 'Clear'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: _submitMelting,
                  icon: const Icon(Icons.delete_forever),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  label: Text(isAr ? 'تنفيذ التكسير' : 'Execute Melting'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==================== Models ====================

class RenewalItem {
  final String description;
  final double weight;
  final int karat;
  final double purchaseValue;

  RenewalItem({
    required this.description,
    required this.weight,
    required this.karat,
    required this.purchaseValue,
  });

  Map<String, dynamic> toJson() {
    return {
      'description': description,
      'weight': weight,
      'karat': karat,
      'purchase_value': purchaseValue,
    };
  }
}

class InventoryItem {
  final int itemId;
  final String itemCode;
  final String name;
  final double weight;
  final int karat;
  int quantity;

  InventoryItem({
    required this.itemId,
    required this.itemCode,
    required this.name,
    required this.weight,
    required this.karat,
    this.quantity = 1,
  });

  Map<String, dynamic> toJson() {
    return {
      'item_id': itemId,
      'item_code': itemCode,
      'name': name,
      'weight': weight,
      'karat': karat,
      'quantity': quantity,
    };
  }
}

// ==================== Dialogs ====================

class _RenewalItemDialog extends StatefulWidget {
  final bool isArabic;
  final double goldPrice;
  final Function(RenewalItem) onAdd;

  const _RenewalItemDialog({
    required this.isArabic,
    required this.goldPrice,
    required this.onAdd,
  });

  @override
  State<_RenewalItemDialog> createState() => _RenewalItemDialogState();
}

class _RenewalItemDialogState extends State<_RenewalItemDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _weightController = TextEditingController();
  final _purchaseValueController = TextEditingController();
  int _selectedKarat = 21;

  final List<int> _karats = [24, 22, 21, 18, 14, 12];

  @override
  void dispose() {
    _descriptionController.dispose();
    _weightController.dispose();
    _purchaseValueController.dispose();
    super.dispose();
  }

  void _calculateEstimate() {
    final weight = double.tryParse(_weightController.text) ?? 0.0;
    final karatPrice = widget.goldPrice * (_selectedKarat / 24);
    final estimate = weight * karatPrice * 0.85; // خصم 15% للمستعمل
    _purchaseValueController.text = estimate.toStringAsFixed(2);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final item = RenewalItem(
      description: _descriptionController.text,
      weight: double.parse(_weightController.text),
      karat: _selectedKarat,
      purchaseValue: double.parse(_purchaseValueController.text),
    );

    widget.onAdd(item);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    return AlertDialog(
      title: Text(isAr ? 'إضافة قطعة للتجديد' : 'Add Item for Renewal'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: isAr ? 'وصف القطعة' : 'Item Description',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return isAr ? 'أدخل الوصف' : 'Enter description';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _weightController,
                decoration: InputDecoration(
                  labelText: isAr ? 'الوزن (جرام)' : 'Weight (gram)',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.calculate),
                    onPressed: _calculateEstimate,
                    tooltip: isAr ? 'حساب تقديري' : 'Estimate',
                  ),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [NormalizeNumberFormatter()],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return isAr ? 'أدخل الوزن' : 'Enter weight';
                  }
                  if (double.tryParse(value) == null) {
                    return isAr ? 'وزن غير صحيح' : 'Invalid weight';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _selectedKarat,
                decoration: InputDecoration(
                  labelText: isAr ? 'العيار' : 'Karat',
                ),
                items: _karats.map((karat) {
                  return DropdownMenuItem(
                    value: karat,
                    child: Text('عيار $karat'),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedKarat = value ?? 21);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _purchaseValueController,
                decoration: InputDecoration(
                  labelText: isAr
                      ? 'سعر الشراء (ريال)'
                      : 'Purchase Price (SAR)',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [NormalizeNumberFormatter()],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return isAr ? 'أدخل السعر' : 'Enter price';
                  }
                  if (double.tryParse(value) == null) {
                    return isAr ? 'سعر غير صحيح' : 'Invalid price';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(isAr ? 'إضافة' : 'Add')),
      ],
    );
  }
}

class _SelectInventoryDialog extends StatelessWidget {
  final bool isArabic;
  final List<Map<String, dynamic>> items;
  final TextEditingController searchController;
  final Function(Map<String, dynamic>) onSelect;

  const _SelectInventoryDialog({
    required this.isArabic,
    required this.items,
    required this.searchController,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isAr = isArabic;

    return AlertDialog(
      title: Text(isAr ? 'اختيار صنف من المخزون' : 'Select Inventory Item'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            TextField(
              controller: searchController,
              decoration: InputDecoration(
                labelText: isAr ? 'بحث...' : 'Search...',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    leading: const Icon(Icons.inventory_2),
                    title: Text(item['name'] ?? ''),
                    subtitle: Text(
                      '${item['item_code']}\n'
                      '${(item['weight'] as num?)?.toStringAsFixed(3)} جم - عيار ${item['karat']}',
                    ),
                    onTap: () {
                      onSelect(item);
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
      ],
    );
  }
}
