import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../models/category_model.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../services/data_sync_bus.dart';
import 'add_item_screen_enhanced.dart';
import 'barcode_print_screen.dart';
import 'quick_add_items_screen.dart';
import '../utils.dart';

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

  // 🆕 التصنيفات
  List<Category> categories = [];
  bool categoriesLoading = false;

  // Search & Filter
  final TextEditingController _searchController = TextEditingController();
  String _selectedKarat = '';
  int? _selectedCategoryId; // 🆕 فلتر حسب التصنيف
  String _sortBy = 'name'; // name, weight, price, date
  bool _sortAscending = true;

  // 🆕 فلاتر متقدمة
  bool? _hasStones; // null = الكل، true = بأحجار، false = بدون أحجار
  double? _minWeight;
  double? _maxWeight;
  double? _minWage;
  double? _maxWage;
  double? _minPrice;
  double? _maxPrice;

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
    _loadCategories(); // 🆕 تحميل التصنيفات
  }

  // 🆕 تحميل التصنيفات
  Future<void> _loadCategories() async {
    setState(() => categoriesLoading = true);
    try {
      final data = await widget.api.getCategories();
      setState(() {
        categories = data.map((json) => Category.fromJson(json)).toList();
        categoriesLoading = false;
      });
    } catch (e) {
      setState(() => categoriesLoading = false);
      // لا نعرض خطأ هنا لأن التصنيفات اختيارية
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadItems({bool notifyListeners = false}) async {
    setState(() => loading = true);
    try {
      final data = await widget.api.getItems();
      setState(() {
        items = data;
        _applyFilters();
        loading = false;
      });
      if (notifyListeners) {
        DataSyncBus.notifyItemsChanged();
      }
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

        // 🆕 Category filter
        final matchesCategory =
            _selectedCategoryId == null ||
            item['category_id'] == _selectedCategoryId;

        // 🆕 Stones filter
        final matchesStones =
            _hasStones == null || (item['has_stones'] ?? false) == _hasStones;

        // 🆕 Weight range filter
        final weight = double.tryParse(item['weight']?.toString() ?? '0') ?? 0;
        final matchesWeight =
            (_minWeight == null || weight >= _minWeight!) &&
            (_maxWeight == null || weight <= _maxWeight!);

        // 🆕 Wage range filter
        final wage = double.tryParse(item['wage']?.toString() ?? '0') ?? 0;
        final matchesWage =
            (_minWage == null || wage >= _minWage!) &&
            (_maxWage == null || wage <= _maxWage!);

        // 🆕 Price range filter
        final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
        final matchesPrice =
            (_minPrice == null || price >= _minPrice!) &&
            (_maxPrice == null || price <= _maxPrice!);

        return matchesSearch &&
            matchesKarat &&
            matchesCategory &&
            matchesStones &&
            matchesWeight &&
            matchesWage &&
            matchesPrice;
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
        await _loadItems(notifyListeners: true);
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
    final auth = context.watch<AuthProvider>();
    final canCreateItems = auth.hasPermission('items.create');

    return Scaffold(
      appBar: AppBar(
        title: const Text('أصناف الذهب'),
        actions: [
          // 🆕 زر إدارة التصنيفات
          IconButton(
            icon: const Icon(Icons.category_outlined),
            tooltip: 'إدارة التصنيفات',
            onPressed: _showCategoriesManagementDialog,
          ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            tooltip: 'الفلتر',
            onPressed: _showFilterDialog,
          ),
          // 🚀 زر الإضافة السريعة
          if (canCreateItems)
            IconButton(
              icon: const Icon(Icons.flash_on),
              tooltip: 'إضافة سريعة',
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => QuickAddItemsScreen(api: widget.api),
                  ),
                );
                if (result == true) {
                  await _loadItems(notifyListeners: true);
                }
              },
            ),
          if (canCreateItems)
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
                  await _loadItems(notifyListeners: true);
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
    final auth = context.read<AuthProvider>();
    final canCreateItems = auth.hasPermission('items.create');
    final canEditItems = auth.hasPermission('items.edit');
    final canDeleteItems = auth.hasPermission('items.delete');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: theme.cardTheme.elevation ?? 1,
      child: InkWell(
        onTap: canEditItems
            ? () async {
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
                  await _loadItems(notifyListeners: true);
                }
              }
            : null,
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
                                  color: karatBadgeColor.withValues(
                                    alpha: 0.18,
                                  ),
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
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                barcode,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        // 🆕 عرض التصنيف
                        if (item['category_name'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.category,
                                  size: 14,
                                  color: AppColors.primaryGold,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  item['category_name'],
                                  style: textTheme.bodySmall?.copyWith(
                                    color: AppColors.primaryGold,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // 🆕 عرض معلومات الأحجار
                        if (item['has_stones'] == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.diamond,
                                  size: 14,
                                  color: Colors.purple.shade400,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'أحجار: ${item['stones_weight']?.toStringAsFixed(2) ?? '0'} جم',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: Colors.purple.shade400,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${item['stones_value']?.toStringAsFixed(2) ?? '0'} ر.س',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: Colors.purple.shade400,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.scale,
                              size: 14,
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${weight.toStringAsFixed(2)} جم',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              Icons.inventory,
                              size: 14,
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$count قطعة',
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.8,
                                ),
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
                      onPressed: canCreateItems
                          ? () async {
                              // 🔄 استنساخ الصنف بسرعة
                              final result = await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => QuickAddItemsScreen(
                                    api: widget.api,
                                    templateItem: item,
                                  ),
                                ),
                              );
                              if (result == true) {
                                await _loadItems(notifyListeners: true);
                              }
                            }
                          : null,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('استنساخ'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryGold,
                        side: BorderSide(color: AppColors.primaryGold),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: canEditItems
                          ? () async {
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
                                await _loadItems(notifyListeners: true);
                              }
                            }
                          : null,
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('تعديل'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (canDeleteItems)
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
            onPressed:
                (context.read<AuthProvider>().hasPermission('items.create'))
                ? () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddItemScreenEnhanced(api: widget.api),
                      ),
                    );
                    if (result == true) {
                      await _loadItems(notifyListeners: true);
                    }
                  }
                : null,
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
    // Controllers للفلاتر المتقدمة
    final minWeightController = TextEditingController(
      text: _minWeight?.toString() ?? '',
    );
    final maxWeightController = TextEditingController(
      text: _maxWeight?.toString() ?? '',
    );
    final minWageController = TextEditingController(
      text: _minWage?.toString() ?? '',
    );
    final maxWageController = TextEditingController(
      text: _maxWage?.toString() ?? '',
    );
    final minPriceController = TextEditingController(
      text: _minPrice?.toString() ?? '',
    );
    final maxPriceController = TextEditingController(
      text: _maxPrice?.toString() ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'تصفية متقدمة للأصناف',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // العيار
              DropdownButtonFormField<String>(
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
                // ignore: deprecated_member_use
                value: _selectedKarat.isEmpty ? null : _selectedKarat,
              ),
              const SizedBox(height: 16),

              // التصنيف
              DropdownButtonFormField<int?>(
                decoration: const InputDecoration(
                  labelText: 'التصنيف',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('الكل'),
                  ),
                  ...categories.map(
                    (category) => DropdownMenuItem<int?>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedCategoryId = value;
                  });
                },
                // ignore: deprecated_member_use
                value: _selectedCategoryId,
              ),
              const SizedBox(height: 16),

              // الأحجار
              DropdownButtonFormField<bool?>(
                decoration: const InputDecoration(
                  labelText: 'الأحجار الكريمة',
                  prefixIcon: Icon(Icons.diamond),
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem<bool?>(value: null, child: Text('الكل')),
                  DropdownMenuItem<bool?>(
                    value: true,
                    child: Text('يحتوي على أحجار'),
                  ),
                  DropdownMenuItem<bool?>(
                    value: false,
                    child: Text('بدون أحجار'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _hasStones = value;
                  });
                },
                // ignore: deprecated_member_use
                value: _hasStones,
              ),
              const SizedBox(height: 16),

              // مدى الوزن
              const Text(
                'مدى الوزن (جم)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: minWeightController,
                      decoration: const InputDecoration(
                        labelText: 'من',
                        border: OutlineInputBorder(),
                        hintText: '0',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: maxWeightController,
                      decoration: const InputDecoration(
                        labelText: 'إلى',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // مدى المصنعية
              const Text(
                'مدى المصنعية (ر.س)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: minWageController,
                      decoration: const InputDecoration(
                        labelText: 'من',
                        border: OutlineInputBorder(),
                        hintText: '0',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: maxWageController,
                      decoration: const InputDecoration(
                        labelText: 'إلى',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // مدى السعر
              const Text(
                'مدى السعر (ر.س)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: minPriceController,
                      decoration: const InputDecoration(
                        labelText: 'من',
                        border: OutlineInputBorder(),
                        hintText: '0',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: maxPriceController,
                      decoration: const InputDecoration(
                        labelText: 'إلى',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _selectedKarat = '';
                _selectedCategoryId = null;
                _hasStones = null;
                _minWeight = null;
                _maxWeight = null;
                _minWage = null;
                _maxWage = null;
                _minPrice = null;
                _maxPrice = null;
              });
              _applyFilters();
              Navigator.pop(context);
            },
            child: const Text('مسح الكل'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _minWeight = double.tryParse(minWeightController.text);
                _maxWeight = double.tryParse(maxWeightController.text);
                _minWage = double.tryParse(minWageController.text);
                _maxWage = double.tryParse(maxWageController.text);
                _minPrice = double.tryParse(minPriceController.text);
                _maxPrice = double.tryParse(maxPriceController.text);
              });
              _applyFilters();
              Navigator.pop(context);
            },
            child: const Text('تطبيق'),
          ),
        ],
      ),
    );
  }

  // 🆕 Dialog لإدارة التصنيفات
  void _showCategoriesManagementDialog() {
    showDialog(
      context: context,
      builder: (context) => _CategoriesManagementDialog(
        api: widget.api,
        categories: categories,
        onCategoriesChanged: () {
          _loadCategories();
          _loadItems(); // إعادة تحميل الأصناف لتحديث أسماء التصنيفات
        },
      ),
    );
  }
}

// ============================================
// 🆕 Widget لإدارة التصنيفات داخل شاشة الأصناف
// ============================================

class _CategoriesManagementDialog extends StatefulWidget {
  final ApiService api;
  final List<Category> categories;
  final VoidCallback onCategoriesChanged;

  const _CategoriesManagementDialog({
    required this.api,
    required this.categories,
    required this.onCategoriesChanged,
  });

  @override
  State<_CategoriesManagementDialog> createState() =>
      _CategoriesManagementDialogState();
}

class _CategoriesManagementDialogState
    extends State<_CategoriesManagementDialog> {
  late List<Category> _categories;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _categories = List.from(widget.categories);
  }

  Future<void> _addCategory() async {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة تصنيف جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'اسم التصنيف *',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'الوصف',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty) {
      setState(() => _loading = true);
      try {
        final response = await widget.api.addCategory({
          'name': nameController.text,
          'description': descController.text,
        });
        final newCategory = Category.fromJson(response);
        setState(() {
          _categories.add(newCategory);
          _loading = false;
        });
        widget.onCategoriesChanged();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ تم إضافة التصنيف بنجاح'),
            backgroundColor: AppColors.success,
          ),
        );
      } catch (e) {
        setState(() => _loading = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ: ${e.toString()}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _editCategory(Category category) async {
    final nameController = TextEditingController(text: category.name);
    final descController = TextEditingController(text: category.description);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تعديل التصنيف'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'اسم التصنيف *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'الوصف',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty) {
      setState(() => _loading = true);
      try {
        final response = await widget.api.updateCategory(category.id!, {
          'name': nameController.text,
          'description': descController.text,
        });
        final updatedCategory = Category.fromJson(response);
        setState(() {
          final index = _categories.indexWhere((c) => c.id == category.id);
          if (index != -1) {
            _categories[index] = updatedCategory;
          }
          _loading = false;
        });
        widget.onCategoriesChanged();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ تم تعديل التصنيف بنجاح'),
            backgroundColor: AppColors.success,
          ),
        );
      } catch (e) {
        setState(() => _loading = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ: ${e.toString()}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteCategory(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: Text(
          'هل تريد حذف التصنيف "${category.name}"؟\n'
          '${category.itemsCount ?? 0} صنف مرتبط بهذا التصنيف.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _loading = true);
      try {
        await widget.api.deleteCategory(category.id!);
        setState(() {
          _categories.removeWhere((c) => c.id == category.id);
          _loading = false;
        });
        widget.onCategoriesChanged();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ تم حذف التصنيف بنجاح'),
            backgroundColor: AppColors.success,
          ),
        );
      } catch (e) {
        setState(() => _loading = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ: ${e.toString()}'),
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

    return Dialog(
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 600),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primaryGold.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.category, color: AppColors.primaryGold),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'إدارة تصنيفات الأصناف',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Categories List
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _categories.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.category_outlined,
                            size: 64,
                            color: colorScheme.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'لا توجد تصنيفات',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('ابدأ بإضافة تصنيف جديد'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _categories.length,
                      itemBuilder: (context, index) {
                        final category = _categories[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.primaryGold.withValues(
                              alpha: 0.18,
                            ),
                            child: Icon(
                              Icons.category,
                              color: AppColors.primaryGold,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            category.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            category.description ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // عداد الأصناف
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${category.itemsCount ?? 0}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.edit, size: 20),
                                onPressed: () => _editCategory(category),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.delete,
                                  size: 20,
                                  color: AppColors.error,
                                ),
                                onPressed: () => _deleteCategory(category),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),

            // Add Button
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _addCategory,
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة تصنيف جديد'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
