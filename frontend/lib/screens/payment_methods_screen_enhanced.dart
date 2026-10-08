import 'dart:convert';

import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/settlement_schedule_editor.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart';
import '../widgets/safe_box_picker_dialog.dart';

/// شاشة إدارة وسائل الدفع المحسّنة بتصميم احترافي
class PaymentMethodsScreenEnhanced extends StatefulWidget {
  /// The server; a test hands its own.
  final ApiService? apiService;

  const PaymentMethodsScreenEnhanced({super.key, this.apiService});

  @override
  State<PaymentMethodsScreenEnhanced> createState() =>
      _PaymentMethodsScreenEnhancedState();
}

class _PaymentMethodsScreenEnhancedState
    extends State<PaymentMethodsScreenEnhanced> {
  late final ApiService apiService = widget.apiService ?? ApiService();
  List<Map<String, dynamic>> _paymentMethods = [];
  List<Map<String, dynamic>> _paymentTypes = [];
  List<Map<String, dynamic>> _invoiceTypeOptions = [];
  List<String> _invoiceTypeDefaultSelection = [];
  List<SafeBoxModel> _availableSafeBoxes = [];
  List<Map<String, dynamic>> _accounts = [];
  bool _isLoading = true;

  // ألوان النظام
  final Color _successColor = AppColors.success;
  final Color _warningColor = AppColors.warning;
  final Color _errorColor = AppColors.error;
  final Color _accentColor = AppColors.darkGold;
  final Color _infoColor = AppColors.info;

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
    'cash': AppColors.success,
    'credit_card': AppColors.info,
    'debit_card': AppColors.info,
    'mada': AppColors.info,
    'visa': AppColors.info,
    'mastercard': AppColors.info,
    'stc_pay': Color(0xFF00897B),
    'apple_pay': Color(0xFF455A64),
    'tabby': Color(0xFF6A1B9A),
    'tamara': Color(0xFFAD1457),
    'bank_transfer': AppColors.darkGold,
    'check': Color(0xFF795548),
    'online': Color(0xFF00838F),
    'receivable': AppColors.darkGold,
  };

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _screenBackground =>
      _isDark ? const Color(0xFF10161D) : const Color(0xFFF7F8FA);
  Color get _panelColor => _isDark ? const Color(0xFF1D2630) : Colors.white;
  Color get _primaryText => _isDark ? Colors.white : const Color(0xFF1F2937);
  Color get _secondaryText =>
      _isDark ? Colors.white70 : const Color(0xFF6B7280);

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  String _suggestedSafeTypeForPaymentType(String? paymentType) {
    final pt = (paymentType ?? '').trim().toLowerCase();
    if (pt == 'cash') return 'cash';
    if (pt == 'check') return 'check';
    if (pt == 'bank_transfer' ||
        pt.contains('transfer') ||
        pt.contains('bank')) {
      return 'bank';
    }
    // bank_transfer / credit_card / debit_card / online / BNPL... => bank
    // Card networks / BNPL / wallets usually settle later -> clearing
    return 'clearing';
  }

  String _safeTypeLabelAr(String safeType) {
    switch (safeType.trim().toLowerCase()) {
      case 'cash':
        return 'نقدي';
      case 'bank':
        return 'بنكي';
      case 'clearing':
        return 'مستحقات تحصيل';
      case 'check':
        return 'شيكات';
      case 'gold':
        return 'ذهبي';
      default:
        return safeType;
    }
  }

  bool _isSafeTypeCompatible(String? paymentType, String safeType) {
    final pt = (paymentType ?? '').trim().toLowerCase();
    final st = safeType.trim().toLowerCase();
    if (st == 'gold') return false;
    if (pt == 'cash') return st == 'cash';
    if (pt == 'check') return st == 'check' || st == 'bank';
    if (pt == 'bank_transfer' ||
        pt.contains('transfer') ||
        pt.contains('bank')) {
      return st == 'bank';
    }
    // Card networks/BNPL: prefer clearing, but allow bank if you want direct posting.
    return st == 'clearing' || st == 'bank';
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final methodsRaw = await apiService.getPaymentMethods();
      final types = await apiService.getPaymentTypes();
      List<SafeBoxModel> safeBoxes = <SafeBoxModel>[];
      try {
        safeBoxes = await apiService.getSafeBoxes(
          isActive: true,
          includeAccount: false,
          includeBalance: false,
        );
      } catch (_) {
        safeBoxes = <SafeBoxModel>[];
      }
      Map<String, dynamic>? invoiceTypesPayload;
      try {
        invoiceTypesPayload = await apiService.getPaymentInvoiceTypeOptions();
      } catch (_) {
        invoiceTypesPayload = null;
      }

      const fallbackPaymentTypes = [
        {'code': 'cash', 'name_ar': 'نقدي', 'icon': '💵'},
        {'code': 'mada', 'name_ar': 'بطاقة مدى', 'icon': '💳'},
        {'code': 'visa', 'name_ar': 'بطاقة فيزا', 'icon': '💳'},
        {'code': 'mastercard', 'name_ar': 'بطاقة ماستركارد', 'icon': '💳'},
        {'code': 'stc_pay', 'name_ar': 'STC Pay', 'icon': '📱'},
        {'code': 'apple_pay', 'name_ar': 'Apple Pay', 'icon': '📱'},
        {'code': 'tabby', 'name_ar': 'تابي', 'icon': '🛍️'},
        {'code': 'tamara', 'name_ar': 'تمارا', 'icon': '🛍️'},
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
          'value': 'شراء',
          'name_ar': 'شراء',
          'category': 'accounting',
          'description': 'شراء ذهب جديد من المورد',
        },
        {
          'value': 'مرتجع شراء (مورد)',
          'name_ar': 'مرتجع شراء (مورد)',
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

      // Ensure dropdown items are unique by code (Dropdown asserts on duplicates).
      final dedupedTypesByCode = <String, Map<String, dynamic>>{};
      for (final type in ensuredTypes) {
        final code = type['code']?.toString();
        if (code == null || code.trim().isEmpty) continue;
        dedupedTypesByCode.putIfAbsent(code, () => type);
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

      List<Map<String, dynamic>> accounts = [];
      try {
        final rawAccounts = await apiService.getAccounts();
        accounts = rawAccounts
            .whereType<Map<String, dynamic>>()
            .where((a) {
              final hasChildren =
                  (a['sub_accounts'] as List?)?.isNotEmpty == true;
              return !hasChildren; // detail accounts only
            })
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
      } catch (_) {
        accounts = [];
      }

      setState(() {
        _paymentMethods = paymentMethods;
        _paymentTypes = dedupedTypesByCode.values.toList();
        _invoiceTypeOptions = invoiceOptions;
        _invoiceTypeDefaultSelection = defaultInvoiceSelection;
        _availableSafeBoxes = safeBoxes;
        _accounts = accounts;
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
        final result = await apiService.deletePaymentMethod(id);
        _fetchData();
        final msg = (result['message']?.toString().trim().isNotEmpty ?? false)
            ? result['message'].toString()
            : '✅ تم تنفيذ العملية بنجاح';
        _showMessage('✅ $msg');
      } catch (e) {
        _showMessage('خطأ في الحذف: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _screenBackground,
      appBar: AppBar(
        elevation: 0,
        centerTitle: false,
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
              colors: [AppColors.deepGold, AppColors.darkGold],
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
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppColors.primaryGold,
                    ),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 20),
                  Text(
                    'جاري تحميل وسائل الدفع...',
                    style: TextStyle(
                      fontSize: 16,
                      color: _secondaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
          : _paymentMethods.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: _fetchData,
              color: AppColors.primaryGold,
              child: Column(
                children: [
                  _buildSummaryStrip(),
                  Expanded(child: _buildPaymentMethodsList()),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showPaymentMethodDialog(),
        backgroundColor: AppColors.primaryGold,
        foregroundColor: Colors.black,
        elevation: 3,
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
                color: AppColors.primaryGold.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.payment_outlined,
                size: 80,
                color: AppColors.darkGold,
              ),
            ),
            SizedBox(height: 24),
            Text(
              'لا توجد وسائل دفع',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _primaryText,
              ),
            ),
            SizedBox(height: 12),
            Text(
              'قم بإضافة أول وسيلة دفع للبدء',
              style: TextStyle(fontSize: 16, color: _secondaryText),
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
                backgroundColor: AppColors.primaryGold,
                foregroundColor: Colors.black,
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

  Widget _buildSummaryStrip() {
    final total = _paymentMethods.length;
    final active = _paymentMethods
        .where((pm) => (pm['is_active'] as bool?) ?? false)
        .length;
    final autoSettlement = _paymentMethods
        .where((pm) => (pm['auto_settlement_enabled'] as bool?) ?? false)
        .length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.primaryGold.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSummaryCard(
              title: 'الإجمالي',
              value: '$total',
              icon: Icons.layers,
              color: AppColors.darkGold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildSummaryCard(
              title: 'النشطة',
              value: '$active',
              icon: Icons.check_circle,
              color: AppColors.success,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildSummaryCard(
              title: 'تلقائية',
              value: '$autoSettlement',
              icon: Icons.sync,
              color: AppColors.info,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    color: _secondaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    color: _primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Moves a method one place and saves the whole order; on failure the
  /// list goes back as it was and says so.
  Future<void> _moveMethod(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _paymentMethods.length) return;
    final before = List<Map<String, dynamic>>.from(_paymentMethods);
    setState(() {
      final moved = _paymentMethods.removeAt(index);
      _paymentMethods.insert(target, moved);
      for (var i = 0; i < _paymentMethods.length; i++) {
        _paymentMethods[i]['display_order'] = i + 1;
      }
    });
    try {
      await apiService.updatePaymentMethodsOrder(_paymentMethods);
    } catch (e) {
      if (!mounted) return;
      setState(() => _paymentMethods = before);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('لم يُحفظ الترتيب: $e')));
    }
  }

  Widget _buildPaymentMethodsList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _paymentMethods.length,
      itemBuilder: (context, index) {
        final method = _paymentMethods[index];
        final paymentType = method['payment_type'] as String? ?? 'cash';
        final isActive = method['is_active'] as bool? ?? true;
        final icon = _paymentIcons[paymentType] ?? Icons.payment;
        final color = _paymentColors[paymentType] ?? _accentColor;

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isActive
                  ? color.withValues(alpha: 0.5)
                  : Colors.grey.withValues(alpha: 0.3),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _isDark ? 0.25 : 0.06),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: _isDark ? 0.28 : 0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        icon,
                        color: isActive ? color : Colors.grey,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            method['name']?.toString() ?? '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 18,
                              color: isActive ? _primaryText : _secondaryText,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.account_balance_outlined,
                                size: 14,
                                color: _secondaryText,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'رقم الحساب: ${method['account_number'] ?? 'غير محدد'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: _secondaryText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppColors.success.withValues(alpha: 0.18)
                            : Colors.grey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isActive
                              ? AppColors.success.withValues(alpha: 0.35)
                              : Colors.grey.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        isActive ? 'نشط' : 'معطل',
                        style: TextStyle(
                          color: isActive ? AppColors.success : _secondaryText,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // The order the invoice screens show their pay buttons in
                    // (PAY-ORDER-1): it was stored, but nothing set it.
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'الترتيب ${index + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _secondaryText,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('order-up-${method['id']}'),
                              tooltip: 'أعلى',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.arrow_upward),
                              onPressed: index == 0
                                  ? null
                                  : () => _moveMethod(index, -1),
                            ),
                            IconButton(
                              key: Key('order-down-${method['id']}'),
                              tooltip: 'أسفل',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.arrow_downward),
                              onPressed: index == _paymentMethods.length - 1
                                  ? null
                                  : () => _moveMethod(index, 1),
                            ),
                          ],
                        ),
                      ],
                    ),
                    PopupMenuButton(
                      icon: Icon(Icons.more_vert, color: _secondaryText),
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
                              Icon(Icons.delete, size: 20, color: _errorColor),
                              SizedBox(width: 12),
                              Text('حذف', style: TextStyle(color: _errorColor)),
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
                const SizedBox(height: 14),
                Divider(color: Colors.grey.withValues(alpha: 0.25), height: 1),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _buildInfoChip(
                      Icons.percent,
                      'العمولة (%)',
                      '${method['commission_rate'] ?? 0}%',
                      _warningColor,
                    ),
                    _buildInfoChip(
                      Icons.payments_outlined,
                      'عمولة ثابتة',
                      '${method['commission_fixed_amount'] ?? 0}',
                      _warningColor,
                    ),
                  ],
                ),
                // The schedule as the server reads it (ADR-037).
                if (method['auto_settlement_enabled'] == true &&
                    (method['schedule_summary'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.event_available, size: 18, color: _infoColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          method['schedule_summary'].toString(),
                          style: TextStyle(fontSize: 12, color: _secondaryText),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'الفواتير المسموح بها',
                  style: TextStyle(
                    fontSize: 12,
                    color: _secondaryText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _buildInvoiceTypeChips(method),
                ),
              ],
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
    return Container(
      constraints: const BoxConstraints(minWidth: 116),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: _isDark ? 0.22 : 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, color: _secondaryText),
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
      ),
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
        Chip(
          label: Text('غير محدد'),
          backgroundColor: Colors.grey.shade200,
          visualDensity: VisualDensity.compact,
        ),
      ];
    }

    return selectedTypes.map((type) {
      return Chip(
        label: Text(_invoiceTypeLabel(type)),
        backgroundColor: AppColors.primaryGold.withValues(alpha: 0.12),
        labelStyle: TextStyle(color: _primaryText, fontSize: 12),
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: AppColors.primaryGold.withValues(alpha: 0.28),
          ),
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
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: editingMethod?['name'] ?? '',
    );
    final commissionController = TextEditingController(
      text: (editingMethod?['commission_rate']?.toDouble() ?? 0.0).toString(),
    );
    final commissionFixedController = TextEditingController(
      text: (editingMethod?['commission_fixed_amount']?.toDouble() ?? 0.0)
          .toString(),
    );
    final settlementDaysController = TextEditingController(
      text: (editingMethod?['settlement_days'] ?? 0).toString(),
    );
    final rawAutoSettlement = editingMethod?['auto_settlement_enabled'];
    bool autoSettlementEnabled =
        rawAutoSettlement == true ||
        (rawAutoSettlement?.toString().trim().toLowerCase() == 'true');

    // The settlement and deposit schedule (ADR-037): one value, edited by
    // SettlementScheduleEditor, previewed by the server.
    SettlementScheduleValue schedule = SettlementScheduleValue.fromMethod(
      editingMethod,
    );

    int? settlementBankSafeBoxId;
    try {
      final raw = editingMethod?['settlement_bank_safe_box_id'];
      settlementBankSafeBoxId = raw is int
          ? raw
          : int.tryParse(raw?.toString() ?? '');
    } catch (_) {
      settlementBankSafeBoxId = null;
    }

    int? feeExpenseAccountId;
    try {
      final raw = editingMethod?['fee_expense_account_id'];
      feeExpenseAccountId = raw is int
          ? raw
          : int.tryParse(raw?.toString() ?? '');
    } catch (_) {
      feeExpenseAccountId = null;
    }

    String selectedCommissionTiming =
        (editingMethod?['commission_timing']?.toString().trim().toLowerCase() ??
        'invoice');
    if (selectedCommissionTiming != 'invoice' &&
        selectedCommissionTiming != 'settlement') {
      selectedCommissionTiming = 'invoice';
    }

    // One settlement mode: a provider's deposit settles its payments together
    // (the owner, 6 Oct 2026). The per-transaction option is gone.
    const selectedSettlementMode = 'bulk';

    String? selectedType = editingMethod?['payment_type'];
    bool isActive = editingMethod?['is_active'] ?? true;
    String? invoiceTypesError;

    // Guard: when editing a method with a legacy/unknown type (or before types are loaded),
    // DropdownButton will assert if initialValue is not present in items.
    String? paymentTypeWarning;
    final availableTypeCodes = _paymentTypes
        .map((t) => t['code']?.toString())
        .whereType<String>()
        .where((v) => v.trim().isNotEmpty)
        .toSet();
    if (selectedType != null && !availableTypeCodes.contains(selectedType)) {
      paymentTypeWarning =
          'تنبيه: نوع وسيلة الدفع الحالية غير موجود ضمن القائمة. الرجاء اختيار نوع صحيح.';
      selectedType = null;
    }

    int? selectedDefaultSafeBoxId;
    try {
      final raw = editingMethod?['default_safe_box_id'];
      selectedDefaultSafeBoxId = raw is int
          ? raw
          : int.tryParse(raw?.toString() ?? '');
    } catch (_) {
      selectedDefaultSafeBoxId = null;
    }

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
    final dialogSurface = _isDark ? const Color(0xFF1B232D) : Colors.white;
    final formFieldFill = _isDark
        ? const Color(0xFF27313B)
        : const Color(0xFFF9FAFB);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: dialogSurface,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 20,
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Row(
            children: [
              Container(
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.darkGold, AppColors.primaryGold],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.payment, color: Colors.white),
              ),
              SizedBox(width: 12),
              Text(
                editingMethod == null ? 'إضافة وسيلة دفع' : 'تعديل وسيلة دفع',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: _primaryText,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // نوع وسيلة الدفع
                    DropdownButtonFormField<String>(
                      initialValue: selectedType,
                      decoration: InputDecoration(
                        labelText: 'نوع وسيلة الدفع *',
                        prefixIcon: Icon(Icons.category, color: _accentColor),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: formFieldFill,
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
                          paymentTypeWarning = null;

                          // If the chosen safe box no longer matches the new type, clear it.
                          if (selectedDefaultSafeBoxId != null) {
                            SafeBoxModel? sb;
                            try {
                              sb = _availableSafeBoxes.firstWhere(
                                (e) => e.id == selectedDefaultSafeBoxId,
                              );
                            } catch (_) {
                              sb = null;
                            }

                            if (sb != null &&
                                !_isSafeTypeCompatible(
                                  selectedType,
                                  sb.safeType,
                                )) {
                              selectedDefaultSafeBoxId = null;
                            }
                          }
                        });
                      },
                      validator: (value) => value == null ? 'مطلوب' : null,
                    ),

                    if (paymentTypeWarning != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          paymentTypeWarning!,
                          style: TextStyle(color: _warningColor, fontSize: 12),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],

                    SizedBox(height: 16),

                    // اسم وسيلة الدفع
                    TextFormField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: 'اسم وسيلة الدفع *',
                        hintText: 'مثال: مدى - بنك الراجحي',
                        prefixIcon: Icon(
                          Icons.text_fields,
                          color: _accentColor,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: formFieldFill,
                      ),
                      validator: (value) =>
                          value?.isEmpty == true ? 'مطلوب' : null,
                    ),

                    SizedBox(height: 16),

                    // نسبة العمولة
                    TextFormField(
                      controller: commissionController,
                      decoration: InputDecoration(
                        labelText: 'نسبة العمولة (%)',
                        hintText: '2.5',
                        prefixIcon: Icon(Icons.percent, color: _warningColor),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: formFieldFill,
                      ),
                      keyboardType: TextInputType.number,
                    ),

                    SizedBox(height: 16),

                    // عمولة ثابتة لكل عملية
                    TextFormField(
                      controller: commissionFixedController,
                      decoration: InputDecoration(
                        labelText: 'عمولة ثابتة لكل عملية',
                        hintText: '0.0',
                        prefixIcon: Icon(
                          Icons.payments_outlined,
                          color: _warningColor,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: formFieldFill,
                      ),
                      keyboardType: TextInputType.number,
                    ),

                    SizedBox(height: 16),

                    // متى تُسجل العمولة؟
                    DropdownButtonFormField<String>(
                      initialValue: selectedCommissionTiming,
                      decoration: InputDecoration(
                        labelText: 'تسجيل العمولة',
                        prefixIcon: Icon(Icons.receipt_long, color: _infoColor),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: formFieldFill,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'invoice',
                          child: Text('ضمن الفاتورة (لا تخصم عند التسوية)'),
                        ),
                        DropdownMenuItem(
                          value: 'settlement',
                          child: Text('عند التسوية (لا تخصم ضمن الفاتورة)'),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedCommissionTiming = value ?? 'invoice';
                        });
                      },
                    ),

                    SizedBox(height: 16),

                    // التسوية التلقائية
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('تسوية تلقائية (مستحقات → بنك)'),
                            subtitle: const Text(
                              'تقوم الخدمة بإنشاء سند تسوية تلقائياً حسب الجدول.',
                              textAlign: TextAlign.right,
                            ),
                            value: autoSettlementEnabled,
                            activeColor: _successColor,
                            onChanged: (value) {
                              setDialogState(() {
                                autoSettlementEnabled = value;
                              });
                            },
                          ),
                          if (autoSettlementEnabled) ...[
                            const SizedBox(height: 12),
                            SettlementScheduleEditor(
                              initial: schedule,
                              api: apiService,
                              fieldFill: formFieldFill,
                              onChanged: (v) => schedule = v,
                            ),
                            const SizedBox(height: 12),

                            Builder(
                              builder: (context) {
                                SafeBoxModel? selectedBankSb;
                                if (settlementBankSafeBoxId != null) {
                                  try {
                                    selectedBankSb = _availableSafeBoxes
                                        .firstWhere(
                                          (sb) =>
                                              sb.id == settlementBankSafeBoxId,
                                        );
                                  } catch (_) {
                                    selectedBankSb = null;
                                  }
                                }

                                final bankBoxes = _availableSafeBoxes
                                    .where(
                                      (sb) =>
                                          sb.safeType.trim().toLowerCase() ==
                                          'bank',
                                    )
                                    .toList();

                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: Text(
                                        'الخزينة البنكية المستهدفة *',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    InkWell(
                                      onTap: bankBoxes.isEmpty
                                          ? null
                                          : () async {
                                              final picked =
                                                  await showDialog<
                                                    SafeBoxModel
                                                  >(
                                                    context: context,
                                                    builder: (_) =>
                                                        SafeBoxPickerDialog(
                                                          safeBoxes: bankBoxes,
                                                          selectedSafeBoxId:
                                                              settlementBankSafeBoxId,
                                                          filterSafeType:
                                                              'bank',
                                                          excludeGold: true,
                                                        ),
                                                  );
                                              if (picked != null) {
                                                setDialogState(() {
                                                  settlementBankSafeBoxId =
                                                      picked.id;
                                                });
                                              }
                                            },
                                      borderRadius: BorderRadius.circular(12),
                                      child: InputDecorator(
                                        decoration: InputDecoration(
                                          labelText: 'خزينة البنك',
                                          prefixIcon: Icon(
                                            Icons.account_balance,
                                            color: _accentColor,
                                          ),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          filled: true,
                                          fillColor: formFieldFill,
                                          suffixIcon: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (settlementBankSafeBoxId !=
                                                  null)
                                                IconButton(
                                                  tooltip: 'مسح الربط',
                                                  onPressed: () =>
                                                      setDialogState(() {
                                                        settlementBankSafeBoxId =
                                                            null;
                                                      }),
                                                  icon: Icon(
                                                    Icons.close,
                                                    color: Colors.grey.shade700,
                                                  ),
                                                ),
                                              Icon(
                                                Icons.arrow_drop_down,
                                                color: bankBoxes.isEmpty
                                                    ? Colors.grey.shade400
                                                    : Colors.grey.shade700,
                                              ),
                                              const SizedBox(width: 6),
                                            ],
                                          ),
                                        ),
                                        child: Text(
                                          selectedBankSb == null
                                              ? (bankBoxes.isEmpty
                                                    ? 'لا توجد خزائن بنكية'
                                                    : 'اختر خزينة بنكية')
                                              : '${selectedBankSb.name} (${selectedBankSb.typeNameAr})',
                                          style: TextStyle(
                                            color: selectedBankSb == null
                                                ? Colors.grey.shade700
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'ملاحظة: يجب أن تكون الخزينة الافتراضية من نوع مستحقات تحصيل (clearing).',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                      textAlign: TextAlign.right,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),

                    // الخزينة الافتراضية (اختياري)
                    Builder(
                      builder: (context) {
                        final suggestedType = _suggestedSafeTypeForPaymentType(
                          selectedType,
                        );

                        SafeBoxModel? selectedSb;
                        if (selectedDefaultSafeBoxId != null) {
                          try {
                            selectedSb = _availableSafeBoxes.firstWhere(
                              (sb) => sb.id == selectedDefaultSafeBoxId,
                            );
                          } catch (_) {
                            selectedSb = null;
                          }
                        }

                        final hasBoxes = _availableSafeBoxes.isNotEmpty;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                'الخزينة الافتراضية (اختياري)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: !hasBoxes
                                  ? null
                                  : () async {
                                      final picked =
                                          await showDialog<SafeBoxModel>(
                                            context: context,
                                            builder: (_) => SafeBoxPickerDialog(
                                              safeBoxes: _availableSafeBoxes,
                                              selectedSafeBoxId:
                                                  selectedDefaultSafeBoxId,
                                              filterSafeType: suggestedType,
                                              excludeGold: true,
                                            ),
                                          );
                                      if (picked != null) {
                                        if (!_isSafeTypeCompatible(
                                          selectedType,
                                          picked.safeType,
                                        )) {
                                          _showMessage(
                                            '⚠️ نوع الخزينة غير مناسب لنوع وسيلة الدفع',
                                            isError: true,
                                          );
                                          return;
                                        }
                                        setDialogState(() {
                                          selectedDefaultSafeBoxId = picked.id;
                                        });
                                      }
                                    },
                              borderRadius: BorderRadius.circular(12),
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: 'الخزينة',
                                  prefixIcon: Icon(
                                    Icons.account_balance_wallet,
                                    color: _accentColor,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  filled: true,
                                  fillColor: formFieldFill,
                                  suffixIcon: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (selectedDefaultSafeBoxId != null)
                                        IconButton(
                                          tooltip: 'مسح الربط',
                                          onPressed: () => setDialogState(() {
                                            selectedDefaultSafeBoxId = null;
                                          }),
                                          icon: Icon(
                                            Icons.close,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      Icon(
                                        Icons.arrow_drop_down,
                                        color: hasBoxes
                                            ? Colors.grey.shade700
                                            : Colors.grey.shade400,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                  ),
                                ),
                                child: Text(
                                  selectedSb == null
                                      ? (hasBoxes
                                            ? 'اختر خزينة (اقتراح: ${_safeTypeLabelAr(suggestedType)})'
                                            : 'لا توجد خزائن متاحة')
                                      : '${selectedSb.name} (${selectedSb.typeNameAr})',
                                  style: TextStyle(
                                    color: selectedSb == null
                                        ? Colors.grey.shade700
                                        : Colors.black87,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'إذا لم يتم تحديد خزينة هنا، سيختار النظام الخزينة عند تسجيل الدفعة حسب الفاتورة/الإعدادات.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ],
                        );
                      },
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
                                  invoiceTypesError =
                                      selectedInvoiceTypes.isEmpty
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
                                  final value =
                                      option['value']?.toString() ?? '';
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
                                    selectedColor: _accentColor.withValues(
                                      alpha: 0.15,
                                    ),
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

                    SizedBox(height: 16),

                    // حساب مصروف العمولة (للتسوية)
                    Builder(
                      builder: (context) {
                        Map<String, dynamic>? selectedFeeAccount;
                        if (feeExpenseAccountId != null) {
                          try {
                            selectedFeeAccount = _accounts.firstWhere(
                              (a) => a['id'] == feeExpenseAccountId,
                            );
                          } catch (_) {
                            selectedFeeAccount = null;
                          }
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                'حساب مصروف العمولة (للتسوية)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: _accounts.isEmpty
                                  ? null
                                  : () async {
                                      final picked =
                                          await showDialog<
                                            Map<String, dynamic>
                                          >(
                                            context: context,
                                            builder: (_) =>
                                                _AccountPickerDialog(
                                                  accounts: _accounts,
                                                  selectedId:
                                                      feeExpenseAccountId,
                                                ),
                                          );
                                      if (picked != null) {
                                        setDialogState(() {
                                          feeExpenseAccountId =
                                              picked['id'] as int?;
                                        });
                                      }
                                    },
                              borderRadius: BorderRadius.circular(12),
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: 'حساب المصروف',
                                  prefixIcon: Icon(
                                    Icons.account_tree_outlined,
                                    color: _warningColor,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  filled: true,
                                  fillColor: formFieldFill,
                                  suffixIcon: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (feeExpenseAccountId != null)
                                        IconButton(
                                          tooltip: 'مسح الربط',
                                          onPressed: () => setDialogState(() {
                                            feeExpenseAccountId = null;
                                          }),
                                          icon: Icon(
                                            Icons.close,
                                            color: Colors.grey.shade700,
                                          ),
                                        ),
                                      Icon(
                                        Icons.arrow_drop_down,
                                        color: _accounts.isEmpty
                                            ? Colors.grey.shade400
                                            : Colors.grey.shade700,
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                  ),
                                ),
                                child: Text(
                                  selectedFeeAccount == null
                                      ? (_accounts.isEmpty
                                            ? 'لا توجد حسابات'
                                            : 'اختر حساب مصروف العمولة (اختياري)')
                                      : '${selectedFeeAccount['name']} (${selectedFeeAccount['account_number'] ?? ''})',
                                  style: TextStyle(
                                    color: selectedFeeAccount == null
                                        ? Colors.grey.shade600
                                        : Colors.black87,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'يُستخدم عند إنشاء قيد تسوية المستحقات تلقائياً لتسجيل مصروف عمولة وسيلة الدفع.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ],
                        );
                      },
                    ),

                    SizedBox(height: 16),

                    // حالة التفعيل
                    Container(
                      decoration: BoxDecoration(
                        color: isActive
                            ? _successColor.withValues(alpha: 0.1)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isActive
                              ? _successColor
                              : Colors.grey.shade300,
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
                        activeThumbColor: _successColor,
                        onChanged: (value) {
                          setDialogState(() => isActive = value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: _secondaryText),
              onPressed: () => Navigator.pop(context),
              child: Text('إلغاء'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  try {
                    final name = nameController.text.trim();
                    final commissionRate =
                        double.tryParse(commissionController.text) ?? 0.0;
                    final commissionFixedAmount =
                        double.tryParse(commissionFixedController.text) ?? 0.0;
                    final settlementDays =
                        int.tryParse(settlementDaysController.text) ?? 0; // 🆕
                    final invoiceTypeList = selectedInvoiceTypes.toList();

                    if (autoSettlementEnabled) {
                      if (settlementBankSafeBoxId == null) {
                        _showMessage(
                          '⚠️ اختر خزينة بنكية للتسوية التلقائية',
                          isError: true,
                        );
                        return;
                      }
                    }

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
                        defaultSafeBoxId: selectedDefaultSafeBoxId,
                        commissionRate: commissionRate,
                        commissionFixedAmount: commissionFixedAmount,
                        commissionTiming: selectedCommissionTiming,
                        settlementDays: settlementDays, // 🆕
                        autoSettlementEnabled: autoSettlementEnabled,
                        settlementScheduleType: schedule.batchPeriod,
                        settlementWeekday: schedule.batchPeriod == 'weekday'
                            ? schedule.closeWeekday
                            : null,
                        settlementBankSafeBoxId: settlementBankSafeBoxId,
                        feeExpenseAccountId: feeExpenseAccountId,
                        minSettlementAmount: schedule.minSettlementAmount,
                        settlementMode: selectedSettlementMode,
                        depositDelayDays: schedule.depositRule == 'days'
                            ? schedule.depositDays
                            : 0,
                        depositScheduleType: schedule.depositRule,
                        depositWeekday: schedule.depositRule == 'weekday'
                            ? schedule.depositWeekday
                            : null,
                        bankWeekendDays: schedule.bankWeekend.toList()..sort(),
                        skipPublicHolidays: schedule.skipPublicHolidays,
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
                        commissionFixedAmount: commissionFixedAmount,
                        commissionTiming: selectedCommissionTiming,
                        settlementDays: settlementDays,
                        autoSettlementEnabled: autoSettlementEnabled,
                        settlementScheduleType: schedule.batchPeriod,
                        settlementWeekday: schedule.batchPeriod == 'weekday'
                            ? schedule.closeWeekday
                            : null,
                        settlementBankSafeBoxId: settlementBankSafeBoxId,
                        feeExpenseAccountId: feeExpenseAccountId,
                        minSettlementAmount: schedule.minSettlementAmount,
                        settlementMode: selectedSettlementMode,
                        depositDelayDays: schedule.depositRule == 'days'
                            ? schedule.depositDays
                            : 0,
                        depositScheduleType: schedule.depositRule,
                        depositWeekday: schedule.depositRule == 'weekday'
                            ? schedule.depositWeekday
                            : null,
                        bankWeekendDays: schedule.bankWeekend.toList()..sort(),
                        skipPublicHolidays: schedule.skipPublicHolidays,
                        isActive: isActive,
                        defaultSafeBoxId: selectedDefaultSafeBoxId,
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
                backgroundColor: AppColors.primaryGold,
                foregroundColor: Colors.black,
                minimumSize: const Size(112, 44),
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
}

/// حوار اختيار حساب من القائمة مع دعم البحث
class _AccountPickerDialog extends StatefulWidget {
  final List<Map<String, dynamic>> accounts;
  final int? selectedId;

  const _AccountPickerDialog({required this.accounts, this.selectedId});

  @override
  State<_AccountPickerDialog> createState() => _AccountPickerDialogState();
}

class _AccountPickerDialogState extends State<_AccountPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.accounts.where((a) {
      final name = (a['name'] ?? '').toString().toLowerCase();
      final number = (a['account_number'] ?? '').toString();
      final q = _query.trim().toLowerCase();
      return q.isEmpty || name.contains(q) || number.contains(q);
    }).toList();

    return AlertDialog(
      title: const Text('اختر حساب المصروف'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'بحث باسم أو رقم الحساب...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final acc = filtered[index];
                  final isSelected = acc['id'] == widget.selectedId;
                  return ListTile(
                    selected: isSelected,
                    selectedTileColor: const Color(
                      0xFF1976D2,
                    ).withValues(alpha: 0.08),
                    leading: Icon(
                      Icons.account_tree_outlined,
                      color: isSelected ? const Color(0xFF1976D2) : null,
                    ),
                    title: Text(acc['name']?.toString() ?? ''),
                    subtitle: Text(acc['account_number']?.toString() ?? ''),
                    onTap: () => Navigator.pop(context, acc),
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
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}
