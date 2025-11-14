import 'dart:convert';

import 'package:flutter/material.dart';
import '../api_service.dart';

/// شاشة إدارة وسائل الدفع المحسّنة بتصميم احترافي
class PaymentMethodsScreenEnhanced extends StatefulWidget {
  const PaymentMethodsScreenEnhanced({Key? key}) : super(key: key);

  @override
  _PaymentMethodsScreenEnhancedState createState() =>
      _PaymentMethodsScreenEnhancedState();
}

class _PaymentMethodsScreenEnhancedState
    extends State<PaymentMethodsScreenEnhanced> {
  final ApiService apiService = ApiService();
  List<Map<String, dynamic>> _paymentMethods = [];
  List<Map<String, dynamic>> _paymentTypes = [];
  List<Map<String, dynamic>> _invoiceTypeOptions = [];
  List<String> _invoiceTypeDefaultSelection = [];
  bool _isLoading = true;

  // ألوان النظام
  final Color _successColor = const Color(0xFF4CAF50); // أخضر
  final Color _warningColor = const Color(0xFFFF9800); // برتقالي
  final Color _errorColor = const Color(0xFFF44336); // أحمر
  final Color _accentColor = const Color(0xFF1976D2); // أزرق
  final Color _infoColor = const Color(0xFF00BCD4); // سماوي

  // أيقونات طرق الدفع
  final Map<String, IconData> _paymentIcons = {
    'cash': Icons.money,
    'credit_card': Icons.credit_card,
    'debit_card': Icons.payment,
    'bank_transfer': Icons.account_balance,
    'check': Icons.receipt_long,
    'online': Icons.smartphone,
  };

  // ألوان طرق الدفع
  final Map<String, Color> _paymentColors = {
    'cash': Color(0xFF4CAF50),
    'credit_card': Color(0xFF2196F3),
    'debit_card': Color(0xFF9C27B0),
    'bank_transfer': Color(0xFFFF9800),
    'check': Color(0xFF795548),
    'online': Color(0xFF00BCD4),
  };

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final methodsRaw = await apiService.getPaymentMethods();
      final types = await apiService.getPaymentTypes();
      Map<String, dynamic>? invoiceTypesPayload;
      try {
        invoiceTypesPayload = await apiService.getPaymentInvoiceTypeOptions();
      } catch (_) {
        invoiceTypesPayload = null;
      }

      const fallbackPaymentTypes = [
        {'code': 'cash', 'name_ar': 'نقدي', 'icon': '💵'},
        {'code': 'bank_transfer', 'name_ar': 'تحويل بنكي', 'icon': '🏦'},
      ];

      const fallbackInvoiceTypes = [
        {
          'value': 'بيع',
          'name_ar': 'فاتورة بيع',
          'category': 'pos',
          'description': 'بيع ذهب جديد للعميل',
        },
        {
          'value': 'شراء من عميل',
          'name_ar': 'شراء كسر من عميل',
          'category': 'pos',
          'description': 'شراء ذهب كسر من العميل',
        },
        {
          'value': 'مرتجع بيع',
          'name_ar': 'مرتجع بيع',
          'category': 'pos',
          'description': 'استرجاع فاتورة بيع من العميل',
        },
        {
          'value': 'مرتجع شراء',
          'name_ar': 'مرتجع شراء كسر',
          'category': 'pos',
          'description': 'استرجاع مشتريات الكسر من العميل',
        },
        {
          'value': 'شراء من مورد',
          'name_ar': 'شراء من مورد',
          'category': 'accounting',
          'description': 'شراء ذهب جديد من المورد',
        },
        {
          'value': 'مرتجع شراء من مورد',
          'name_ar': 'مرتجع شراء من مورد',
          'category': 'accounting',
          'description': 'استرجاع مشتريات من المورد',
        },
      ];

      final existingTypeCodes = types
          .whereType<Map<String, dynamic>>()
          .map((type) => type['code']?.toString())
          .whereType<String>()
          .toSet();

      final ensuredTypes = List<Map<String, dynamic>>.from(
        types.whereType<Map<String, dynamic>>(),
      );

      for (final fallback in fallbackPaymentTypes) {
        if (!existingTypeCodes.contains(fallback['code'])) {
          ensuredTypes.add(fallback);
        }
      }

      final invoiceOptions = (invoiceTypesPayload?['options'] is List)
          ? (invoiceTypesPayload?['options'] as List)
                .whereType<Map<String, dynamic>>()
                .map((option) => Map<String, dynamic>.from(option))
                .toList()
          : List<Map<String, dynamic>>.from(fallbackInvoiceTypes);

      if (invoiceOptions.isEmpty) {
        invoiceOptions.addAll(
          fallbackInvoiceTypes.map(
            (option) => Map<String, dynamic>.from(option),
          ),
        );
      }

      final defaultInvoiceSelection =
          (invoiceTypesPayload?['default_selection'] is List)
          ? (invoiceTypesPayload?['default_selection'] as List)
                .map((entry) => entry.toString())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList()
          : invoiceOptions
                .map((option) => option['value']?.toString() ?? '')
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList();

      final paymentMethods = methodsRaw
          .whereType<Map<String, dynamic>>()
          .map((method) => Map<String, dynamic>.from(method))
          .toList();

      setState(() {
        _paymentMethods = paymentMethods;
        _paymentTypes = ensuredTypes;
        _invoiceTypeOptions = invoiceOptions;
        _invoiceTypeDefaultSelection = defaultInvoiceSelection;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showMessage('خطأ في جلب البيانات: $e', isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            SizedBox(width: 12),
            Expanded(child: Text(message, style: TextStyle(fontSize: 15))),
          ],
        ),
        backgroundColor: isError ? _errorColor : _successColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  Future<void> _deletePaymentMethod(int id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: _errorColor, size: 28),
            SizedBox(width: 12),
            Text('تأكيد الحذف', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text('هل تريد حذف وسيلة الدفع "$name"؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: _errorColor),
            child: Text('حذف'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await apiService.deletePaymentMethod(id);
        _fetchData();
        _showMessage('✅ تم الحذف بنجاح');
      } catch (e) {
        _showMessage('خطأ في الحذف: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.payment, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Text(
              'إدارة وسائل الدفع',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                color: Colors.white,
              ),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _accentColor,
                Color.lerp(_accentColor, _infoColor, 0.3)!,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _fetchData,
            icon: Icon(Icons.refresh, color: Colors.white),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 20),
                  Text(
                    'جاري تحميل وسائل الدفع...',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
          : _paymentMethods.isEmpty
          ? _buildEmptyState()
          : _buildPaymentMethodsList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showPaymentMethodDialog(),
        backgroundColor: _successColor,
        icon: Icon(Icons.add),
        label: Text(
          'إضافة وسيلة دفع',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.payment_outlined,
                size: 80,
                color: Colors.grey.shade400,
              ),
            ),
            SizedBox(height: 24),
            Text(
              'لا توجد وسائل دفع',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'قم بإضافة أول وسيلة دفع للبدء',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => _showPaymentMethodDialog(),
              icon: Icon(Icons.add, size: 24),
              label: Text(
                'إضافة وسيلة دفع',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _successColor,
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentMethodsList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _paymentMethods.length,
      itemBuilder: (context, index) {
        final method = _paymentMethods[index];
        final paymentType = method['payment_type'] as String? ?? 'cash';
        final isActive = method['is_active'] as bool? ?? true;
        final icon = _paymentIcons[paymentType] ?? Icons.payment;
        final color = _paymentColors[paymentType] ?? _accentColor;

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: 2,
          shadowColor: color.withValues(alpha: 0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isActive ? color.withValues(alpha: 0.3) : Colors.grey.shade300,
              width: 2,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: [
                  isActive ? color.withValues(alpha: 0.05) : Colors.grey.shade100,
                  Colors.white,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // أيقونة وسيلة الدفع
                      Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isActive
                              ? color.withValues(alpha: 0.15)
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          icon,
                          color: isActive ? color : Colors.grey.shade600,
                          size: 28,
                        ),
                      ),
                      SizedBox(width: 16),

                      // اسم الوسيلة
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              method['name'],
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                                color: isActive
                                    ? Colors.grey.shade800
                                    : Colors.grey.shade600,
                              ),
                            ),
                            SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.account_balance,
                                  size: 14,
                                  color: Colors.grey.shade600,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'رقم الحساب: ${method['account_number'] ?? 'غير محدد'}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // شارة الحالة
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? _successColor
                              : Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isActive ? Icons.check_circle : Icons.cancel,
                              color: Colors.white,
                              size: 16,
                            ),
                            SizedBox(width: 4),
                            Text(
                              isActive ? 'نشط' : 'معطل',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // قائمة الخيارات
                      PopupMenuButton(
                        icon: Icon(
                          Icons.more_vert,
                          color: Colors.grey.shade600,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Row(
                              children: [
                                Icon(Icons.edit, size: 20, color: _accentColor),
                                SizedBox(width: 12),
                                Text('تعديل'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete,
                                  size: 20,
                                  color: _errorColor,
                                ),
                                SizedBox(width: 12),
                                Text(
                                  'حذف',
                                  style: TextStyle(color: _errorColor),
                                ),
                              ],
                            ),
                          ),
                        ],
                        onSelected: (value) {
                          if (value == 'edit') {
                            _showPaymentMethodDialog(editingMethod: method);
                          } else if (value == 'delete') {
                            _deletePaymentMethod(method['id'], method['name']);
                          }
                        },
                      ),
                    ],
                  ),

                  SizedBox(height: 12),
                  Divider(),
                  SizedBox(height: 8),

                  // معلومات إضافية
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildInfoChip(
                        Icons.percent,
                        'العمولة',
                        '${method['commission_rate'] ?? 0}%',
                        _warningColor,
                      ),
                      Container(
                        width: 1,
                        height: 30,
                        color: Colors.grey.shade300,
                      ),
                      _buildInfoChip(
                        Icons.calendar_today,
                        'أيام التسوية',
                        '${method['settlement_days'] ?? 0}',
                        _infoColor,
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'الفواتير المسموح بها',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _buildInvoiceTypeChips(method),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoChip(
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _invoiceTypeLabel(String value) {
    if (value.isEmpty) {
      return value;
    }

    final option = _invoiceTypeOptions.firstWhere(
      (opt) => opt['value']?.toString() == value,
      orElse: () => <String, dynamic>{},
    );

    final dynamic labelCandidate =
        option['name_ar'] ?? option['label_ar'] ?? option['value'];
    if (labelCandidate is String && labelCandidate.isNotEmpty) {
      return labelCandidate;
    }

    if (labelCandidate != null) {
      final labelString = labelCandidate.toString();
      if (labelString.isNotEmpty) {
        return labelString;
      }
    }

    return value;
  }

  List<Widget> _buildInvoiceTypeChips(Map<String, dynamic> method) {
    final rawTypes = method['applicable_invoice_types'];
    final extractedTypes = rawTypes is List
        ? rawTypes
              .map((entry) => entry?.toString())
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toList()
        : <String>[];

    final selectedTypes = extractedTypes.isNotEmpty
        ? extractedTypes
        : (_invoiceTypeDefaultSelection.isNotEmpty
              ? List<String>.from(_invoiceTypeDefaultSelection)
              : _invoiceTypeOptions
                    .map((option) => option['value']?.toString() ?? '')
                    .where((value) => value.isNotEmpty)
                    .toList());

    if (selectedTypes.isEmpty) {
      return [
        Chip(label: Text('غير محدد'), backgroundColor: Colors.grey.shade200),
      ];
    }

    return selectedTypes.map((type) {
      return Chip(
        label: Text(_invoiceTypeLabel(type)),
        backgroundColor: Colors.blueGrey.shade50,
        labelStyle: TextStyle(color: Colors.grey.shade800, fontSize: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.grey.shade300),
        ),
      );
    }).toList();
  }

  String _resolveBackendError(Object error) {
    final message = error.toString();
    final start = message.indexOf('{');
    final end = message.lastIndexOf('}');

    if (start != -1 && end != -1 && end > start) {
      final snippet = message.substring(start, end + 1);
      try {
        final parsed = json.decode(snippet);
        if (parsed is Map && parsed['error'] is String) {
          return parsed['error'] as String;
        }
      } catch (_) {
        // تجاهل أخطاء التحويل ونرجع الرسالة الأصلية
      }
    }

    return message;
  }

  void _showPaymentMethodDialog({Map<String, dynamic>? editingMethod}) async {
    final _formKey = GlobalKey<FormState>();
    final _nameController = TextEditingController(
      text: editingMethod?['name'] ?? '',
    );
    final _commissionController = TextEditingController(
      text: (editingMethod?['commission_rate']?.toDouble() ?? 0.0).toString(),
    );
    final _settlementDaysController = TextEditingController(
      text: (editingMethod?['settlement_days'] ?? 0).toString(),
    );

    String? selectedType = editingMethod?['payment_type'];
    bool isActive = editingMethod?['is_active'] ?? true;
    String? invoiceTypesError;

    final allInvoiceTypeValues = _invoiceTypeOptions
        .map((option) => option['value']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();

    final defaultInvoiceSelection = editingMethod == null
        ? (_invoiceTypeDefaultSelection.isNotEmpty
              ? List<String>.from(_invoiceTypeDefaultSelection)
              : List<String>.from(allInvoiceTypeValues))
        : ((editingMethod['applicable_invoice_types'] is List)
                  ? (editingMethod['applicable_invoice_types'] as List)
                        .map((entry) => entry?.toString())
                        .whereType<String>()
                        .where((value) => value.isNotEmpty)
                        .toList()
                  : <String>[])
              .where((value) => value.isNotEmpty)
              .toList();

    final fallbackSelection = _invoiceTypeDefaultSelection.isNotEmpty
        ? _invoiceTypeDefaultSelection
        : allInvoiceTypeValues;

    final initialSelection = defaultInvoiceSelection.isNotEmpty
        ? defaultInvoiceSelection
        : fallbackSelection;

    final Set<String> selectedInvoiceTypes = initialSelection.toSet();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.payment, color: _accentColor),
              ),
              SizedBox(width: 12),
              Text(
                editingMethod == null ? 'إضافة وسيلة دفع' : 'تعديل وسيلة دفع',
                style: TextStyle(fontSize: 18),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // نوع وسيلة الدفع
                  DropdownButtonFormField<String>(
                    value: selectedType,
                    decoration: InputDecoration(
                      labelText: 'نوع وسيلة الدفع *',
                      prefixIcon: Icon(Icons.category, color: _accentColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    items: _paymentTypes.map((type) {
                      final code = type['code'] as String;
                      final icon = _paymentIcons[code] ?? Icons.payment;
                      return DropdownMenuItem(
                        value: code,
                        child: Row(
                          children: [
                            Icon(icon, size: 20),
                            SizedBox(width: 8),
                            Text('${type['name_ar']} ${type['icon']}'),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setDialogState(() {
                        selectedType = value;
                      });
                    },
                    validator: (value) => value == null ? 'مطلوب' : null,
                  ),

                  SizedBox(height: 16),

                  // اسم وسيلة الدفع
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'اسم وسيلة الدفع *',
                      hintText: 'مثال: مدى - بنك الراجحي',
                      prefixIcon: Icon(Icons.text_fields, color: _accentColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    validator: (value) =>
                        value?.isEmpty == true ? 'مطلوب' : null,
                  ),

                  SizedBox(height: 16),

                  // نسبة العمولة
                  TextFormField(
                    controller: _commissionController,
                    decoration: InputDecoration(
                      labelText: 'نسبة العمولة (%)',
                      hintText: '2.5',
                      prefixIcon: Icon(Icons.percent, color: _warningColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    keyboardType: TextInputType.number,
                  ),

                  SizedBox(height: 16),

                  // أيام التسوية
                  TextFormField(
                    controller: _settlementDaysController,
                    decoration: InputDecoration(
                      labelText: 'أيام التسوية',
                      hintText: '0',
                      prefixIcon: Icon(Icons.calendar_today, color: _infoColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    keyboardType: TextInputType.number,
                  ),

                  SizedBox(height: 16),

                  // أنواع الفواتير المسموح بها
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'أنواع الفواتير المسموح بها *',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  if (_invoiceTypeOptions.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () {
                              setDialogState(() {
                                if (selectedInvoiceTypes.length ==
                                    allInvoiceTypeValues.length) {
                                  selectedInvoiceTypes.clear();
                                } else {
                                  selectedInvoiceTypes
                                    ..clear()
                                    ..addAll(allInvoiceTypeValues);
                                }
                                invoiceTypesError = selectedInvoiceTypes.isEmpty
                                    ? 'يجب اختيار نوع فاتورة واحد على الأقل'
                                    : null;
                              });
                            },
                            icon: Icon(
                              selectedInvoiceTypes.length ==
                                      allInvoiceTypeValues.length
                                  ? Icons.remove_done
                                  : Icons.done_all,
                            ),
                            label: Text(
                              selectedInvoiceTypes.length ==
                                      allInvoiceTypeValues.length
                                  ? 'إلغاء تحديد الكل'
                                  : 'تحديد كل الأنواع',
                            ),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _invoiceTypeOptions
                              .map((option) {
                                final value = option['value']?.toString() ?? '';
                                if (value.isEmpty) {
                                  return const SizedBox.shrink();
                                }

                                final label =
                                    option['name_ar']?.toString() ?? value;
                                final isSelected = selectedInvoiceTypes
                                    .contains(value);
                                return FilterChip(
                                  selected: isSelected,
                                  label: Text(label),
                                  avatar: option['category'] == 'pos'
                                      ? const Icon(Icons.storefront, size: 18)
                                      : const Icon(
                                          Icons.account_balance,
                                          size: 18,
                                        ),
                                  onSelected: (_) {
                                    setDialogState(() {
                                      if (isSelected) {
                                        selectedInvoiceTypes.remove(value);
                                      } else {
                                        selectedInvoiceTypes.add(value);
                                      }
                                      invoiceTypesError =
                                          selectedInvoiceTypes.isEmpty
                                          ? 'يجب اختيار نوع فاتورة واحد على الأقل'
                                          : null;
                                    });
                                  },
                                  shape: StadiumBorder(
                                    side: BorderSide(
                                      color: isSelected
                                          ? _accentColor
                                          : Colors.grey.shade300,
                                    ),
                                  ),
                                  selectedColor: _accentColor.withValues(alpha: 0.15),
                                );
                              })
                              .where((chip) => chip is! SizedBox)
                              .cast<Widget>()
                              .toList(),
                        ),
                      ],
                    )
                  else
                    Container(
                      padding: EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blueGrey.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'لم يتم تحميل أنواع الفواتير، سيتم استخدام جميع الأنواع افتراضياً',
                        style: TextStyle(color: Colors.blueGrey.shade700),
                      ),
                    ),

                  if (invoiceTypesError != null) ...[
                    SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        invoiceTypesError!,
                        style: TextStyle(color: _errorColor, fontSize: 12),
                      ),
                    ),
                  ],

                  SizedBox(height: 16),

                  // حالة التفعيل
                  Container(
                    decoration: BoxDecoration(
                      color: isActive
                          ? _successColor.withValues(alpha: 0.1)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isActive ? _successColor : Colors.grey.shade300,
                      ),
                    ),
                    child: SwitchListTile(
                      title: Text(
                        'الحالة: ${isActive ? 'نشط' : 'معطل'}',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        isActive
                            ? 'يمكن استخدامها في الفواتير'
                            : 'لا يمكن استخدامها',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: isActive,
                      activeColor: _successColor,
                      onChanged: (value) {
                        setDialogState(() => isActive = value);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('إلغاء'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                if (_formKey.currentState!.validate()) {
                  try {
                    final name = _nameController.text.trim();
                    final commissionRate =
                        double.tryParse(_commissionController.text) ?? 0.0;
                    final settlementDays =
                        int.tryParse(_settlementDaysController.text) ?? 0; // 🆕
                    final invoiceTypeList = selectedInvoiceTypes.toList();

                    if (invoiceTypeList.isEmpty) {
                      setDialogState(() {
                        invoiceTypesError =
                            'يجب اختيار نوع فاتورة واحد على الأقل';
                      });
                      return;
                    }

                    if (editingMethod == null) {
                      // إضافة جديدة
                      await apiService.createPaymentMethod(
                        paymentType: selectedType!,
                        name: name,
                        defaultSafeBoxId:
                            null, // لن يتم تحديد خزينة افتراضية عند الإضافة
                        commissionRate: commissionRate,
                        settlementDays: settlementDays, // 🆕
                        isActive: isActive,
                        applicableInvoiceTypes: invoiceTypeList,
                      );
                    } else {
                      // تعديل
                      await apiService.updatePaymentMethod(
                        editingMethod['id'],
                        paymentType: selectedType!,
                        name: name,
                        commissionRate: commissionRate,
                        isActive: isActive,
                        applicableInvoiceTypes: invoiceTypeList,
                      );
                    }

                    Navigator.pop(context);
                    _fetchData();
                    _showMessage(
                      editingMethod == null
                          ? '✅ تم الإضافة بنجاح'
                          : '✅ تم التعديل بنجاح',
                    );
                  } catch (e) {
                    final friendlyError = _resolveBackendError(e);
                    setDialogState(() {
                      invoiceTypesError = friendlyError.contains('نوع فاتورة')
                          ? friendlyError
                          : invoiceTypesError;
                    });
                    _showMessage('خطأ: $friendlyError', isError: true);
                  }
                }
              },
              icon: Icon(editingMethod == null ? Icons.add : Icons.save),
              label: Text(editingMethod == null ? 'إضافة' : 'حفظ'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _successColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
