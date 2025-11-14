import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import 'add_item_screen_enhanced.dart';
import 'barcode_print_screen.dart';

/// شاشة قائمة الأصناف المحسّنة
///
/// الميزات:
/// - بحث متقدم وفلترة قوية
/// - بطاقات عصرية للأصناف
/// - إحصائيات فورية
/// - دعم الباركود
/// - تصدير واستيراد
class ItemsScreenEnhanced extends StatefulWidget {
  final ApiService api;
  const ItemsScreenEnhanced({super.key, required this.api});

  @override
  State<ItemsScreenEnhanced> createState() => _ItemsScreenEnhancedState();
}

class _ItemsScreenEnhancedState extends State<ItemsScreenEnhanced> {
  List items = [];
  List filteredItems = [];
  bool loading = true;

  // Search & Filter
  final TextEditingController _searchController = TextEditingController();
  String _selectedKarat = '';
  String _sortBy = 'name'; // name, weight, price, date
  bool _sortAscending = true;

  // Statistics
  int get totalItems => filteredItems.length;
  int get totalCount => filteredItems.fold(
    0,
    (sum, item) => sum + (int.tryParse(item['count']?.toString() ?? '0') ?? 0),
  );
  double get totalWeight => filteredItems.fold(
    0.0,
    (sum, item) =>
        sum + (double.tryParse(item['weight']?.toString() ?? '0') ?? 0.0),
  );
  double get totalValue => filteredItems.fold(0.0, (sum, item) {
    final count = int.tryParse(item['count']?.toString() ?? '0') ?? 0;
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0.0;
    return sum + (count * price);
  });

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    setState(() => loading = true);
    try {
      final data = await widget.api.getItems();
      setState(() {
        items = data;
        _applyFilters();
        loading = false;
      });
    } catch (e) {
      setState(() => loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في تحميل الأصناف: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  void _applyFilters() {
    final searchTerm = _searchController.text.toLowerCase();

    setState(() {
      filteredItems = items.where((item) {
        // Search filter
        final matchesSearch =
            searchTerm.isEmpty ||
            (item['name']?.toString().toLowerCase().contains(searchTerm) ??
                false) ||
            (item['barcode']?.toString().toLowerCase().contains(searchTerm) ??
                false) ||
            (item['description']?.toString().toLowerCase().contains(
                  searchTerm,
                ) ??
                false);

        // Karat filter
        final matchesKarat =
            _selectedKarat.isEmpty ||
            item['karat']?.toString() == _selectedKarat;

        return matchesSearch && matchesKarat;
      }).toList();

      // Apply sorting
      _applySorting();
    });
  }

  void _applySorting() {
    filteredItems.sort((a, b) {
      int comparison = 0;

      switch (_sortBy) {
        case 'name':
          comparison = (a['name'] ?? '').toString().compareTo(
            (b['name'] ?? '').toString(),
          );
          break;
        case 'weight':
          final weightA = double.tryParse(a['weight']?.toString() ?? '0') ?? 0;
          final weightB = double.tryParse(b['weight']?.toString() ?? '0') ?? 0;
          comparison = weightA.compareTo(weightB);
          break;
        case 'price':
          final priceA = double.tryParse(a['price']?.toString() ?? '0') ?? 0;
          final priceB = double.tryParse(b['price']?.toString() ?? '0') ?? 0;
          comparison = priceA.compareTo(priceB);
          break;
        case 'karat':
          final karatA = double.tryParse(a['karat']?.toString() ?? '0') ?? 0;
          final karatB = double.tryParse(b['karat']?.toString() ?? '0') ?? 0;
          comparison = karatA.compareTo(karatB);
          break;
      }

      return _sortAscending ? comparison : -comparison;
    });
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return AlertDialog(
          title: Text('تأكيد الحذف', style: theme.textTheme.titleMedium),
          content: Text(
            'هل تريد حذف "${item['name']}"؟',
            style: theme.textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'إلغاء',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
              child: const Text('حذف'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        await widget.api.deleteItem(item['id']);
        await _loadItems();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ تم حذف الصنف بنجاح'),
            backgroundColor: AppColors.success,
          ),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في الحذف: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('أصناف الذهب'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'الفلتر',
            onPressed: _showFilterDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'إضافة صنف جديد',
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddItemScreenEnhanced(api: widget.api),
                ),
              );
              if (result == true) {
                _loadItems();
              }
            },
          ),
        ],
      ),
      body: loading
          ? Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadItems,
              child: Column(
                children: [
                  // Statistics Cards
                  _buildStatisticsSection(),

                  // Search Bar
                  _buildSearchBar(),

                  // Sort Bar
                  _buildSortBar(),

                  // Items List
                  Expanded(
                    child: filteredItems.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: filteredItems.length,
                            itemBuilder: (context, index) {
                              final item = filteredItems[index];
                              return _buildItemCard(item);
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatisticsSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(12),
      color: colorScheme.surface.withValues(alpha: isDark ? 0.35 : 0.2),
      child: Row(
        children: [
          Expanded(
            child: _buildStatCard(
              'الأصناف',
              totalItems.toString(),
              Icons.inventory_2_outlined,
              AppColors.info,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStatCard(
              'الوزن',
              '${totalWeight.toStringAsFixed(1)}جم',
              Icons.scale,
              colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStatCard(
              'القيمة',
              NumberFormat.compact().format(totalValue),
              Icons.attach_money,
              AppColors.success,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      elevation: theme.cardTheme.elevation ?? 2,
      color: theme.cardTheme.color ?? colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              value,
              style: textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          labelText: 'بحث (الاسم، الباركود، الوصف)',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _applyFilters();
                  },
                )
              : null,
          border: const OutlineInputBorder(),
        ),
        onChanged: (value) => _applyFilters(),
      ),
    );
  }

  Widget _buildSortBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Text('الترتيب:'),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('الاسم'),
            selected: _sortBy == 'name',
            onSelected: (selected) {
              setState(() {
                _sortBy = 'name';
                _applyFilters();
              });
            },
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            label: const Text('الوزن'),
            selected: _sortBy == 'weight',
            onSelected: (selected) {
              setState(() {
                _sortBy = 'weight';
                _applyFilters();
              });
            },
          ),
          const SizedBox(width: 4),
          ChoiceChip(
            label: const Text('السعر'),
            selected: _sortBy == 'price',
            onSelected: (selected) {
              setState(() {
                _sortBy = 'price';
                _applyFilters();
              });
            },
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            ),
            onPressed: () {
              setState(() {
                _sortAscending = !_sortAscending;
                _applyFilters();
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final itemCode = item['item_code']?.toString();
    final name = item['name']?.toString() ?? 'غير محدد';
    final barcode = item['barcode']?.toString();
    final karat = item['karat']?.toString() ?? '0';
    final weight = double.tryParse(item['weight']?.toString() ?? '0') ?? 0.0;
    final count = int.tryParse(item['count']?.toString() ?? '0') ?? 0;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final karatBadgeColor = AppColors.primaryGold;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: theme.cardTheme.elevation ?? 1,
      child: InkWell(
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  AddItemScreenEnhanced(api: widget.api, itemToEdit: item),
            ),
          );
          if (result == true) {
            _loadItems();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Icon with karat
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.diamond_outlined,
                          color: colorScheme.primary,
                        ),
                        Text(
                          karat,
                          style: textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Item info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                style: textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ),
                            if (itemCode != null)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: karatBadgeColor.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  itemCode,
                                  style: textTheme.bodySmall?.copyWith(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: karatBadgeColor,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (barcode != null && barcode.isNotEmpty)
                          Row(
                            children: [
                              Icon(
                                Icons.qr_code,
                                size: 14,
                                color: colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                barcode,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.scale,
                              size: 14,
                              color: colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${weight.toStringAsFixed(2)} جم',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.8),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              Icons.inventory,
                              size: 14,
                              color: colorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$count قطعة',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // أزرار الإجراءات
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _printBarcode(item),
                      icon: const Icon(Icons.print, size: 16),
                      label: const Text('طباعة'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.primary),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddItemScreenEnhanced(
                              api: widget.api,
                              itemToEdit: item,
                            ),
                          ),
                        );
                        if (result == true) {
                          _loadItems();
                        }
                      },
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('تعديل'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _deleteItem(item),
                    icon: const Icon(
                      Icons.delete,
                      color: AppColors.error,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _printBarcode(Map<String, dynamic> item) {
    final itemCode = item['item_code']?.toString();
    final barcode = item['barcode']?.toString();
    final name = item['name']?.toString() ?? 'غير محدد';
    final price = double.tryParse(item['price']?.toString() ?? '0');
    final karat = item['karat']?.toString();

    if (barcode == null || barcode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ هذا الصنف لا يحتوي على باركود'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BarcodePrintScreen(
          barcode: barcode,
          itemName: name,
          itemCode: itemCode ?? '',
          price: price,
          karat: karat,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 80,
            color: colorScheme.onSurface.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 16),
          Text(
            _searchController.text.isNotEmpty || _selectedKarat.isNotEmpty
                ? 'لا توجد نتائج للبحث'
                : 'لا توجد أصناف بعد',
            style: textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddItemScreenEnhanced(api: widget.api),
                ),
              );
              if (result == true) {
                _loadItems();
              }
            },
            icon: const Icon(Icons.add),
            label: Text(
              'إضافة صنف جديد',
              style: textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'تصفية الأصناف',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _selectedKarat.isEmpty ? null : _selectedKarat,
              decoration: const InputDecoration(
                labelText: 'العيار',
                border: OutlineInputBorder(),
              ),
              items: ['', '14', '18', '21', '22', '24']
                  .map(
                    (k) => DropdownMenuItem(
                      value: k,
                      child: Text(k.isEmpty ? 'الكل' : 'عيار $k'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedKarat = value ?? '';
                });
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _selectedKarat = '';
              });
              _applyFilters();
              Navigator.pop(context);
            },
            child: const Text('مسح الفلتر'),
          ),
          ElevatedButton(
            onPressed: () {
              _applyFilters();
              Navigator.pop(context);
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    );
  }
}
