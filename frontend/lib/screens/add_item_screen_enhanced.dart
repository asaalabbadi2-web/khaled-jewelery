import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../api_service.dart';
import '../utils.dart';
import '../features/invoice/validators/invoice_form_validator.dart';
import '../theme/app_theme.dart';
import '../services/data_sync_bus.dart';
import 'barcode_print_screen.dart';
import 'quick_add_items_screen.dart';

/// شاشة إضافة صنف ذهب محسّنة
///
/// الميزات:
/// - دعم الباركود مع ماسح متكامل
/// - نظام Validation قوي
/// - UI عصري مع Material 3
/// - Chips للعيارات الشائعة
/// - معاينة فورية للبيانات
class AddItemScreenEnhanced extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? itemToEdit; // للتعديل

  const AddItemScreenEnhanced({super.key, required this.api, this.itemToEdit});

  @override
  State<AddItemScreenEnhanced> createState() => _AddItemScreenEnhancedState();
}

enum _AddItemEntryMode { single, quick }

class _AddItemScreenEnhancedState extends State<AddItemScreenEnhanced> {
  final _formKey = GlobalKey<FormState>();

  // Controllers
  late TextEditingController _nameController;
  late TextEditingController _barcodeController;
  late TextEditingController _karatController;
  late TextEditingController _weightController;
  late TextEditingController _countController;
  late TextEditingController _wageController;
  late TextEditingController _descriptionController;
  late TextEditingController _priceController;
  late TextEditingController _stockController;

  bool _isLoading = false;
  bool _isEditMode = false;
  String? _itemCode; // كود الصنف (يُولّد تلقائياً)
  _AddItemEntryMode _entryMode = _AddItemEntryMode.single;
  int _quickAddResetCounter = 0;

  @override
  void initState() {
    super.initState();
    _isEditMode = widget.itemToEdit != null;

    // Initialize controllers
    final item = widget.itemToEdit ?? {};
    _itemCode = item['item_code']?.toString(); // حفظ كود الصنف الحالي
    _nameController = TextEditingController(
      text: item['name']?.toString() ?? '',
    );
    _barcodeController = TextEditingController(
      text: item['barcode']?.toString() ?? '',
    );
    _karatController = TextEditingController(
      text: item['karat']?.toString() ?? '',
    );
    _weightController = TextEditingController(
      text: item['weight']?.toString() ?? '',
    );
    _countController = TextEditingController(
      text: item['count']?.toString() ?? '1',
    );
    _wageController = TextEditingController(
      text: item['wage']?.toString() ?? '0',
    );
    _descriptionController = TextEditingController(
      text: item['description']?.toString() ?? '',
    );
    _priceController = TextEditingController(
      text: item['price']?.toString() ?? '0',
    );
    final initialStockValue = _isEditMode ? _parseStockValue(item['stock']) : 1;
    _stockController = TextEditingController(
      text: initialStockValue.toString(),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _barcodeController.dispose();
    _karatController.dispose();
    _weightController.dispose();
    _countController.dispose();
    _wageController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _stockController.dispose();
    super.dispose();
  }

  void _handleQuickAddSuccess() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ تم حفظ الأصناف السريعة بنجاح'),
        backgroundColor: AppColors.success,
      ),
    );
    setState(() {
      _quickAddResetCounter++;
    });
  }

  void _resetSingleEntryAfterAdd({Map<String, dynamic>? response}) {
    setState(() {
      // بعد الحفظ نُصفّر كود/رقم الصنف حتى لا يبقى ظاهرًا للمدخل التالي
      _itemCode = null;
      _nameController.clear();
      _weightController.clear();
      _descriptionController.clear();
      _countController.text = '1';
      _stockController.text = '1';

      // Keep karat/wage/price as-is for fast repeated entry.
      if (response?['barcode'] != null) {
        _barcodeController.text = response!['barcode'].toString();
      } else {
        _barcodeController.clear();
      }
    });
  }

  Future<void> _scanBarcode() async {
    try {
      final code = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => _BarcodeScannerWidget()),
      );

      if (code != null) {
        setState(() {
          _barcodeController.text = code;
        });

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ تم مسح الباركود: $code'),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في الماسح: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _saveItem() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ يرجى تصحيح الأخطاء أولاً'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      bool itemMutated = false;
      final parsedStock = int.tryParse(_stockController.text.trim());
      final fallbackStock = _isEditMode
          ? _parseStockValue(widget.itemToEdit?['stock'])
          : 1;
      final resolvedStock = parsedStock ?? fallbackStock;

      final itemData = {
        'name': _nameController.text,
        'barcode': _barcodeController.text.isEmpty
            ? null
            : _barcodeController.text,
        'karat': normalizeNumber(_karatController.text),
        'weight': normalizeNumber(_weightController.text),
        'count': int.tryParse(_countController.text) ?? 1,
        'wage': normalizeNumber(_wageController.text),
        'description': _descriptionController.text,
        'price': normalizeNumber(_priceController.text),
        'stock': resolvedStock,
      };

      dynamic response;

      if (_isEditMode) {
        response = await widget.api.updateItem(
          widget.itemToEdit!['id'],
          itemData,
        );
        itemMutated = true;
        // تحديث الباركود إذا تم توليده من السيرفر
        if (response != null && response['barcode'] != null) {
          setState(() {
            _barcodeController.text = response['barcode'];
          });
        }
      } else {
        response = await widget.api.addItem(itemData);
        // حفظ item_code و barcode المُولّدين من السيرفر
        if (response != null) {
          itemMutated = true;
          final createdItemCode = response['item_code']?.toString();
          final createdBarcode = response['barcode']?.toString();
          if (createdBarcode != null && createdBarcode.isNotEmpty) {
            _barcodeController.text = createdBarcode;
          }

          // رسالة نجاح مع تفاصيل التوليد التلقائي
          if (!mounted) return;

          DataSyncBus.notifyItemsChanged();
          _resetSingleEntryAfterAdd(
            response: response is Map
                ? Map<String, dynamic>.from(response)
                : null,
          );

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('✅ تم إضافة الصنف بنجاح'),
                  if (createdItemCode != null && createdItemCode.isNotEmpty)
                    Text(
                      'كود الصنف: $createdItemCode',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (createdBarcode != null && createdBarcode.isNotEmpty)
                    Text(
                      'الباركود: $createdBarcode',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 4),
            ),
          );
          return; // خروج مبكر لأننا أظهرنا الرسالة
        }
      }

      if (!mounted) return;

      if (itemMutated) {
        DataSyncBus.notifyItemsChanged();
      }

      if (!_isEditMode) {
        _resetSingleEntryAfterAdd(
          response: response is Map
              ? Map<String, dynamic>.from(response)
              : null,
        );
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditMode ? '✅ تم تحديث الصنف بنجاح' : '✅ تم إضافة الصنف بنجاح',
          ),
          backgroundColor: AppColors.success,
        ),
      );

      if (_isEditMode) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ: $e'), backgroundColor: AppColors.error),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  int _parseStockValue(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String && value.trim().isNotEmpty) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  void _printBarcode() {
    if (_barcodeController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ لا يوجد باركود لطباعته'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BarcodePrintScreen(
          barcode: _barcodeController.text,
          itemName: _nameController.text,
          itemCode: _itemCode ?? '',
          price: double.tryParse(_priceController.text),
          karat: _karatController.text.isEmpty ? null : _karatController.text,
        ),
      ),
    );
  }

  Widget _buildKaratChip(String karat) {
    final isSelected = _karatController.text == karat;
    return FilterChip(
      label: Text(karat),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _karatController.text = karat;
          });
        }
      },
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
      checkmarkColor: Theme.of(context).colorScheme.onPrimaryContainer,
      labelStyle: TextStyle(
        color: isSelected
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : Theme.of(context).colorScheme.onSurface,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool quickModeAvailable = !_isEditMode;
    final bool isQuickMode =
        quickModeAvailable && _entryMode == _AddItemEntryMode.quick;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_isEditMode ? 'تعديل صنف' : 'إضافة صنف جديد'),
        backgroundColor: AppColors.darkGold,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 2,
        actions: [
          if (!isQuickMode && !_isEditMode)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'مسح باركود',
              onPressed: _scanBarcode,
              color: Colors.white,
            ),
          if (_isEditMode && _barcodeController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.print),
              tooltip: 'طباعة باركود',
              onPressed: _printBarcode,
              color: Colors.white,
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.lightGold.withValues(alpha: 0.25),
              theme.scaffoldBackgroundColor,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            if (quickModeAvailable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: _buildEntryModeToggle(),
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: isQuickMode
                    ? _buildQuickAddEmbedded()
                    : _buildSingleEntryForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleEntryForm() {
    return KeyedSubtree(
      key: const ValueKey('singleEntryForm'),
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // معلومات أساسية
            _buildSectionHeader('المعلومات الأساسية', Icons.info_outline),
            const SizedBox(height: 12),

            // اسم الصنف
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'اسم الصنف *',
                prefixIcon: const Icon(Icons.label_outline),
                border: const OutlineInputBorder(),
                hintText: 'مثال: خاتم ذهب',
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'اسم الصنف مطلوب';
                }
                if (value.length < 2) {
                  return 'الاسم يجب أن يكون حرفين على الأقل';
                }
                return null;
              },
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),

            // عرض كود الصنف (للقراءة فقط)
            if (_itemCode != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.primaryGold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.primaryGold.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.tag, color: AppColors.primaryGold),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'كود الصنف',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          Text(
                            _itemCode!,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primaryGold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'تلقائي',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppColors.success,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_itemCode != null) const SizedBox(height: 16),

            // الباركود
            TextFormField(
              controller: _barcodeController,
              decoration: InputDecoration(
                labelText: 'الباركود (اختياري - يُولّد تلقائياً)',
                prefixIcon: const Icon(Icons.qr_code),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.camera_alt, color: AppColors.info),
                  tooltip: 'مسح بالكاميرا',
                  onPressed: _scanBarcode,
                ),
                border: const OutlineInputBorder(),
                hintText: 'امسح أو أدخل الباركود',
              ),
              validator: (value) {
                // الباركود اختياري
                if (value == null || value.isEmpty) return null;

                if (value.length < 5) {
                  return 'الباركود يجب أن يكون 5 أحرف على الأقل';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // الوصف
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'الوصف (اختياري)',
                prefixIcon: Icon(Icons.description_outlined),
                border: OutlineInputBorder(),
                hintText: 'وصف تفصيلي للصنف',
              ),
              maxLines: 2,
            ),

            const SizedBox(height: 24),

            // مواصفات الذهب
            _buildSectionHeader('مواصفات الذهب', Icons.diamond_outlined),
            const SizedBox(height: 12),

            // العيار مع Chips
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _karatController,
                  decoration: const InputDecoration(
                    labelText: 'العيار *',
                    prefixIcon: Icon(Icons.stars),
                    border: OutlineInputBorder(),
                    hintText: 'مثال: 21',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    NormalizeNumberFormatter(),
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d+\.?\d{0,2}'),
                    ),
                  ],
                  validator: InvoiceFormValidator.validateKarat,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _buildKaratChip('24'),
                    _buildKaratChip('22'),
                    _buildKaratChip('21'),
                    _buildKaratChip('18'),
                    _buildKaratChip('14'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),

            // الوزن
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _weightController,
                    decoration: const InputDecoration(
                      labelText: 'الوزن (جرام) *',
                      prefixIcon: Icon(Icons.scale),
                      border: OutlineInputBorder(),
                      suffixText: 'جم',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      NormalizeNumberFormatter(),
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+\.?\d{0,4}'),
                      ),
                    ],
                    validator: InvoiceFormValidator.validateWeight,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _wageController,
                    decoration: const InputDecoration(
                      labelText: 'المصنعية',
                      prefixIcon: Icon(Icons.build_outlined),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      NormalizeNumberFormatter(),
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d+\.?\d{0,2}'),
                      ),
                    ],
                    validator: (value) => InvoiceFormValidator.validateWage(
                      value,
                      allowZero: true,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // معلومات المخزون
            _buildSectionHeader('المخزون والتسعير', Icons.inventory_outlined),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _countController,
                    decoration: const InputDecoration(
                      labelText: 'العدد *',
                      prefixIcon: Icon(Icons.format_list_numbered),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'العدد مطلوب';
                      }
                      final count = int.tryParse(value);
                      if (count == null || count < 1) {
                        return 'العدد يجب أن يكون على الأقل 1';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _stockController,
                    decoration: const InputDecoration(
                      labelText: 'المخزون',
                      prefixIcon: Icon(Icons.warehouse_outlined),
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // السعر
            TextFormField(
              controller: _priceController,
              decoration: const InputDecoration(
                labelText: 'السعر *',
                prefixIcon: Icon(Icons.attach_money),
                border: OutlineInputBorder(),
                hintText: 'سعر البيع',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                NormalizeNumberFormatter(),
                FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
              ],
              validator: (value) =>
                  InvoiceFormValidator.validatePrice(value, allowZero: true),
            ),

            const SizedBox(height: 32),

            // زر الحفظ
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _saveItem,
              icon: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_isEditMode ? Icons.save : Icons.add),
              label: Text(
                _isLoading
                    ? 'جاري الحفظ...'
                    : (_isEditMode ? 'حفظ التعديلات' : 'إضافة الصنف'),
                style: const TextStyle(fontSize: 16),
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: AppColors.primaryGold,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAddEmbedded() {
    return QuickAddItemsScreen(
      key: ValueKey('quickAddEmbedded_$_quickAddResetCounter'),
      api: widget.api,
      embedded: true,
      onSuccess: _handleQuickAddSuccess,
    );
  }

  Widget _buildEntryModeToggle() {
    final theme = Theme.of(context);

    Widget buildOption({
      required _AddItemEntryMode mode,
      required IconData icon,
      required String title,
      required String subtitle,
      String? badge,
    }) {
      final bool selected = _entryMode == mode;
      return GestureDetector(
        onTap: () => setState(() => _entryMode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? AppColors.primaryGold
                  : AppColors.primaryGold.withValues(alpha: 0.3),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.primaryGold.withValues(alpha: 0.25),
                      offset: const Offset(0, 12),
                      blurRadius: 28,
                    ),
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.primaryGold.withValues(alpha: 0.2)
                          : AppColors.primaryGold.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: AppColors.darkGold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppColors.darkGold,
                    ),
                  ),
                  const Spacer(),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.darkGold
                            : AppColors.darkGold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          color: selected ? Colors.white : AppColors.darkGold,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primaryGold.withValues(alpha: 0.16), Colors.white],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.primaryGold.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryGold.withValues(alpha: 0.12),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.swap_horiz,
                    color: AppColors.darkGold,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'طريقة الإدخال',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.darkGold,
                  ),
                ),
                const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _entryMode == _AddItemEntryMode.single
                            ? Icons.looks_one
                            : Icons.bolt,
                        size: 16,
                        color: AppColors.darkGold,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _entryMode == _AddItemEntryMode.single
                            ? 'قطعة واحدة'
                            : 'إضافة سريعة',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: AppColors.darkGold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: buildOption(
                    mode: _AddItemEntryMode.single,
                    icon: Icons.looks_one,
                    title: 'قطعة واحدة',
                    subtitle: 'ملء كل التفاصيل مع الباركود والمخزون والمصنعية.',
                    badge: 'تفصيلي',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: buildOption(
                    mode: _AddItemEntryMode.quick,
                    icon: Icons.bolt,
                    title: 'إضافة سريعة',
                    subtitle:
                        'الصق أوزان متعددة أو أضف بطاقات موحدة للحفظ دفعة واحدة.',
                    badge: 'الأسرع',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                _entryMode == _AddItemEntryMode.single
                    ? 'يُستخدم لإدخال كل تفاصيل قطعة محددة مع كل الخصائص المتقدمة.'
                    : 'مصمم للتهام الأوزان من الميزان أو ملفات Excel وتسريع إضافة عدة قطع.',
                key: ValueKey(_entryMode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.black87,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.primaryGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: AppColors.primaryGold.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppColors.darkGold, size: 18),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: AppColors.darkGold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Barcode Scanner Widget
class _BarcodeScannerWidget extends StatefulWidget {
  @override
  State<_BarcodeScannerWidget> createState() => _BarcodeScannerWidgetState();
}

class _BarcodeScannerWidgetState extends State<_BarcodeScannerWidget> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح الباركود 📷'),
        backgroundColor: Colors.black87,
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, child) {
                final torchState = value.torchState;
                switch (torchState) {
                  case TorchState.auto:
                  case TorchState.off:
                    return const Icon(Icons.flash_off);
                  case TorchState.on:
                    return const Icon(Icons.flash_on, color: Colors.yellow);
                  case TorchState.unavailable:
                    return const Icon(Icons.flash_off, color: Colors.grey);
                }
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final code = barcodes.first.rawValue;
                if (code != null) {
                  Navigator.pop(context, code);
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.symmetric(horizontal: 32),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '🎯 وجّه الكاميرا نحو الباركود',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
