import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import '../widgets/currency_manager_dialog.dart';
import '../widgets/widgets.dart'; // Import shared widgets
import '../theme/app_theme.dart';
import '../utils.dart';
import 'invoice_print_screen.dart';

/// Screen for creating return invoices (مرتجعات)
/// Supports: مرتجع بيع, مرتجع شراء, مرتجع شراء (مورد)
class AddReturnInvoiceScreen extends StatefulWidget {
  final ApiService api;
  final String returnType; // 'مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)'
  final Map<String, dynamic>? prefilledOriginalInvoice;

  const AddReturnInvoiceScreen({
    super.key,
    required this.api,
    required this.returnType,
    this.prefilledOriginalInvoice,
  });

  @override
  State<AddReturnInvoiceScreen> createState() => _AddReturnInvoiceScreenState();
}

// Data model for return item rows with proportional calculations
class ReturnItemRow {
  final int? originalItemId; // Reference to original invoice item
  final int? itemId; // Inventory item ID (if available)
  final String itemName;
  final double karat;
  final double originalWeight;
  final int originalQuantity;
  final double originalWage;
  final double originalNet;
  final double originalTax;
  final double originalTotal;

  bool isSelected;
  double weight;
  int quantity;
  double wage;
  double net;
  double tax;
  double total;
  double cost;

  ReturnItemRow({
    this.originalItemId,
    this.itemId,
    required this.itemName,
    required this.karat,
    required this.originalWeight,
    required this.originalQuantity,
    required this.originalWage,
    required this.originalNet,
    required this.originalTax,
    required this.originalTotal,
    this.isSelected = true,
  }) : weight = originalWeight,
       quantity = originalQuantity,
       wage = originalWage,
       net = originalNet,
       tax = originalTax,
       total = originalTotal,
       cost = originalNet;

  void updateWeight(double newWeight) {
    weight = newWeight.clamp(0, originalWeight);
    recalculateTotals();
  }

  void updateQuantity(int newQuantity) {
    final clamped = newQuantity.clamp(0, originalQuantity);
    quantity = clamped.toInt();
    recalculateTotals();
  }

  void updateWage(double newWage) {
    wage = newWage;
  }

  void recalculateTotals() {
    final ratios = <double>[];
    if (originalWeight > 0) {
      ratios.add((weight / originalWeight).clamp(0.0, 1.0));
    }
    if (originalQuantity > 0) {
      ratios.add((quantity / originalQuantity).clamp(0.0, 1.0));
    }

    final ratio = ratios.isEmpty
        ? 1.0
        : ratios.reduce((value, element) => element < value ? element : value);

    net = originalNet * ratio;
    tax = originalTax * ratio;
    total = originalTotal * ratio;
    cost = net;
  }

  Map<String, dynamic> toPayload() {
    recalculateTotals();
    return {
      'item_id': itemId,
      'original_invoice_item_id': originalItemId,
      'name': itemName,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'quantity': quantity,
      'cost': cost,
      'net': net,
      'tax': tax,
      'price': total,
    };
  }
}

class _AddReturnInvoiceScreenState extends State<AddReturnInvoiceScreen> {
  // Stepper state
  int _currentStep = 0;

  // Form Keys
  final _selectInvoiceFormKey = GlobalKey<FormState>();
  final _returnReasonFormKey = GlobalKey<FormState>();
  final _paymentFormKey = GlobalKey<FormState>();

  // Controllers
  final _returnReasonController = TextEditingController();

  // Data
  Map<String, dynamic>? selectedOriginalInvoice;
  List<ReturnItemRow> _returnItems = [];
  bool _isLoadingInvoiceDetails = false;
  String? _invoiceDetailsError;
  String returnReason = '';

  // Currency settings
  double exchangeRate = 1.0;
  String currencySymbol = '\$';
  String currencyName = 'USD';

  // Payment
  String paymentMethod = 'cash';
  double amountPaid = 0;

  void _resetAfterSave() {
    setState(() {
      _currentStep = 0;
      selectedOriginalInvoice = null;
      _returnItems = [];
      _isLoadingInvoiceDetails = false;
      _invoiceDetailsError = null;
      returnReason = '';
      paymentMethod = 'cash';
      amountPaid = 0;
      _returnReasonController.clear();
    });
  }

  List<ReturnItemRow> get _selectedItems => _returnItems
      .where(
        (item) => item.isSelected && (item.weight > 0 || item.quantity > 0),
      )
      .toList();

  // Computed totals based on currently selected items
  double get totalWeight =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.weight);
  double get totalCost =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.cost);
  double get totalTax =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.tax);
  double get grandTotal =>
      _selectedItems.fold(0.0, (sum, item) => sum + item.total);
  double get amountDue => (grandTotal - amountPaid).clamp(0, double.infinity);

  double _parseDouble(dynamic value, [double fallback = 0]) {
    if (value == null) return fallback;
    if (value is num) return value.toDouble();
    if (value is String) {
      final normalized = value.replaceAll(',', '.');
      return double.tryParse(normalized) ?? fallback;
    }
    return fallback;
  }

  int _parseInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  int? _parseOptionalInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  ReturnItemRow _mapInvoiceItemToReturnRow(Map<String, dynamic> item) {
    final originalTotal = _parseDouble(item['price']);
    final originalTax = _parseDouble(item['tax']);
    double originalNet = _parseDouble(item['net']);
    final parsedQuantity = _parseInt(item['quantity'], 1);
    final normalizedQuantity = parsedQuantity > 0 ? parsedQuantity : 1;
    if (originalNet == 0 && originalTotal > 0) {
      originalNet = (originalTotal - originalTax).clamp(0, originalTotal);
    }

    return ReturnItemRow(
      originalItemId: _parseOptionalInt(item['id']),
      itemId: _parseOptionalInt(item['item_id']),
      itemName: (item['name'] as String?)?.trim().isNotEmpty == true
          ? item['name']
          : 'صنف بدون اسم',
      karat: _parseDouble(item['karat'], 21),
      originalWeight: _parseDouble(item['weight']),
      originalQuantity: normalizedQuantity,
      originalWage: _parseDouble(item['wage']),
      originalNet: originalNet,
      originalTax: originalTax,
      originalTotal: originalTotal > 0
          ? originalTotal
          : originalNet + originalTax,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrencySettings();

    // If the caller already knows the original invoice, prefill it and load its details.
    final prefilled = widget.prefilledOriginalInvoice;
    if (prefilled != null) {
      selectedOriginalInvoice = Map<String, dynamic>.from(prefilled);
      final invoiceId = _parseOptionalInt(prefilled['id']);
      if (invoiceId != null) {
        // Move to items selection step after details are loaded.
        _currentStep = 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadOriginalInvoiceDetails(invoiceId);
        });
      }
    }
  }

  @override
  void dispose() {
    _returnReasonController.dispose();
    super.dispose();
  }

  String _getReturnTypeDisplayName() {
    switch (widget.returnType) {
      case 'مرتجع بيع':
        return 'مرتجع فاتورة بيع';
      case 'مرتجع شراء':
        return 'مرتجع فاتورة شراء من عميل';
      case 'مرتجع شراء (مورد)':
        return 'مرتجع فاتورة شراء';
      default:
        return widget.returnType;
    }
  }

  String _getReturnTypeDescription() {
    switch (widget.returnType) {
      case 'مرتجع بيع':
        return 'استرجاع ذهب تم بيعه للعميل مع تحديث المخزون والدفعات.';
      case 'مرتجع شراء':
        return 'عكس عملية شراء من عميل وإرجاع الوزن إلى المخزون.';
      case 'مرتجع شراء (مورد)':
        return 'إرجاع ذهب للمورد مع تسوية حسابات المورد والخزينة.';
      default:
        return 'إدارة عمليات الاسترجاع المحاسبية للذهب.';
    }
  }

  String _getOriginalInvoiceType() {
    switch (widget.returnType) {
      case 'مرتجع بيع':
        return 'بيع';
      case 'مرتجع شراء':
        return 'شراء من عميل';
      case 'مرتجع شراء (مورد)':
        return 'شراء';
      default:
        return '';
    }
  }

  Future<void> _loadCurrencySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final String? currenciesString = prefs.getString('currencies');
    if (currenciesString != null) {
      final List<dynamic> currencyList = jsonDecode(currenciesString);
      final activeCurrencyData = currencyList.firstWhere(
        (c) => c['isActive'] == true,
        orElse: () => null,
      );
      if (activeCurrencyData != null) {
        final activeCurrency = Currency.fromJson(activeCurrencyData);
        if (mounted) {
          setState(() {
            currencyName = activeCurrency.name;
            currencySymbol = activeCurrency.symbol;
            exchangeRate = activeCurrency.rate;
          });
        }
      }
    } else {
      if (mounted) {
        setState(() {
          currencyName = 'ريال سعودي';
          currencySymbol = 'ر.س';
          exchangeRate = 3.75;
        });
      }
    }
  }

  // --- Stepper Navigation ---
  void _onStepContinue() {
    bool isStepValid = false;

    switch (_currentStep) {
      case 0: // Select Original Invoice
        if (selectedOriginalInvoice == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الرجاء اختيار الفاتورة الأصلية')),
          );
          isStepValid = false;
        } else {
          isStepValid = true;
        }
        break;

      case 1: // Select Return Items
        if (_selectedItems.isEmpty) {
          final message = _isLoadingInvoiceDetails
              ? 'جاري تحميل أصناف الفاتورة الأصلية...'
              : 'الرجاء اختيار صنف واحد على الأقل للإرجاع';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
          isStepValid = false;
        } else {
          isStepValid = true;
        }
        break;

      case 2: // Return Reason
        if (_returnReasonController.text.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الرجاء إدخال سبب الإرجاع')),
          );
          isStepValid = false;
        } else {
          returnReason = _returnReasonController.text.trim();
          isStepValid = true;
        }
        break;

      case 3: // Payment
        isStepValid = _paymentFormKey.currentState!.validate();
        break;

      case 4: // Review
        _showSaveConfirmationDialog();
        isStepValid = false;
        break;
    }

    if (isStepValid && _currentStep < 4) {
      setState(() {
        _currentStep += 1;
      });
    }
  }

  void _onStepCancel() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep -= 1;
      });
    }
  }

  // --- Show Select Original Invoice Dialog ---
  // This method is now replaced by OriginalInvoiceSelector widget

  Future<void> _loadOriginalInvoiceDetails(int invoiceId) async {
    setState(() {
      _isLoadingInvoiceDetails = true;
      _invoiceDetailsError = null;
      _returnItems.clear();
    });

    try {
      final invoiceDetails = await widget.api.getInvoiceById(invoiceId);

      if (!mounted) return;

      final mergedInvoice = {...?selectedOriginalInvoice, ...invoiceDetails};

      final items = (invoiceDetails['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((item) => _mapInvoiceItemToReturnRow(item))
          .toList();

      setState(() {
        selectedOriginalInvoice = mergedInvoice;
        _returnItems = items;
        // افتراض أن المبلغ المسدد يساوي الإجمالي المبدئي
        if (_selectedItems.isNotEmpty) {
          amountPaid = grandTotal;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _invoiceDetailsError = 'خطأ في تحميل تفاصيل الفاتورة: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في تحميل تفاصيل الفاتورة: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingInvoiceDetails = false;
        });
      }
    }
  }

  // --- Save Return Invoice ---
  Future<void> _saveReturnInvoice() async {
    final selectedItems = _selectedItems;
    if (selectedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء اختيار صنف واحد على الأقل قبل الحفظ'),
        ),
      );
      return;
    }

    final originalBranchId = selectedOriginalInvoice?['branch_id'];
    if (originalBranchId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'الفاتورة الأصلية لا تحتوي على فرع. لا يمكن حفظ المرتجع بدون فرع.',
          ),
        ),
      );
      return;
    }

    final returnItems = selectedItems.map((item) => item.toPayload()).toList();

    final payload = {
      'customer_id': widget.returnType != 'مرتجع شراء (مورد)'
          ? selectedOriginalInvoice!['customer_id']
          : null,
      'supplier_id': widget.returnType == 'مرتجع شراء (مورد)'
          ? selectedOriginalInvoice!['supplier_id']
          : null,
      'branch_id': originalBranchId,
      'date': DateTime.now().toIso8601String(),
      'invoice_type': widget.returnType,
      'original_invoice_id': selectedOriginalInvoice!['id'],
      'return_reason': returnReason,
      'total': grandTotal,
      'total_weight': totalWeight,
      'total_tax': totalTax,
      'total_cost': totalCost,
      'payment_method': paymentMethod,
      'amount_paid': amountPaid,
      'items': returnItems,
    };

    try {
      final response = await widget.api.addInvoice(payload);
      if (!mounted) return;

      final invoiceForPrint = Map<String, dynamic>.from(response);

      if (selectedOriginalInvoice != null) {
        invoiceForPrint['customer_name'] ??=
            selectedOriginalInvoice!['customer_name'] ??
            selectedOriginalInvoice!['name'];
        invoiceForPrint['supplier_name'] ??=
            selectedOriginalInvoice!['supplier_name'] ??
            selectedOriginalInvoice!['name'];
      }

      final shouldPrint = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('تم حفظ المرتجع'),
            content: Text(
              '✅ تم حفظ المرتجع #${invoiceForPrint['id'] ?? ''}\nهل تريد طباعته الآن؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('تم'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.print),
                label: const Text('طباعة'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      if (shouldPrint == true) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                InvoicePrintScreen(invoice: invoiceForPrint, isArabic: true),
          ),
        );
      }

      if (!mounted) return;
      _resetAfterSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
      }
    }
  }

  void _showSaveConfirmationDialog() {
    final original = selectedOriginalInvoice;
    final selected = _selectedItems;

    double originalTotal = 0.0;
    double originalTax = 0.0;
    double originalWeight = 0.0;
    String originalDate = '';
    String originalNumber = '';
    String originalParty = '';

    if (original != null) {
      originalTotal = _parseDouble(
        original['total'] ?? original['total_amount'],
      );
      originalTax = _parseDouble(original['total_tax']);
      originalWeight = _parseDouble(original['total_weight']);
      originalDate = (original['date'] ?? '').toString();
      originalNumber = (original['invoice_number'] ?? original['id'] ?? '')
          .toString();
      originalParty =
          (original['customer_name'] ?? original['supplier_name'] ?? '')
              .toString();
    }

    final returnTotal = grandTotal;
    final returnTax = totalTax;
    final returnWeight = totalWeight;

    final deltaTotal = -returnTotal;
    final deltaTax = -returnTax;
    final deltaWeight = -returnWeight;

    String fmt2(num v) => v.toStringAsFixed(2);
    String fmt3(num v) => v.toStringAsFixed(3);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('تأكيد الحفظ (قبل/بعد)'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getReturnTypeDisplayName(),
                    style: Theme.of(dialogContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  // Original invoice summary
                  if (original != null) ...[
                    Text(
                      'الفاتورة الأصلية',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    _buildInfoRow(
                      'الرقم/المعرف',
                      originalNumber.isEmpty ? '-' : originalNumber,
                    ),
                    if (originalDate.isNotEmpty)
                      _buildInfoRow('التاريخ', originalDate),
                    if (originalParty.isNotEmpty)
                      _buildInfoRow('العميل/المورد', originalParty),
                    _buildInfoRow(
                      'إجمالي الأصل',
                      '${fmt2(originalTotal)} $currencySymbol',
                    ),
                    _buildInfoRow(
                      'ضريبة الأصل',
                      '${fmt2(originalTax)} $currencySymbol',
                    ),
                    _buildInfoRow('وزن الأصل', '${fmt3(originalWeight)} جم'),
                    const SizedBox(height: 12),
                  ],

                  // Return summary
                  Text(
                    'المرتجع (سيتم حفظه)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  _buildInfoRow('عدد الأصناف', selected.length.toString()),
                  _buildInfoRow(
                    'إجمالي المرتجع',
                    '${fmt2(returnTotal)} $currencySymbol',
                  ),
                  _buildInfoRow(
                    'ضريبة المرتجع',
                    '${fmt2(returnTax)} $currencySymbol',
                  ),
                  _buildInfoRow('وزن المرتجع', '${fmt3(returnWeight)} جم'),

                  const SizedBox(height: 12),

                  // Deltas
                  Text(
                    'الأثر (Delta)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  _buildInfoRow(
                    'تغيير الإجمالي',
                    '${fmt2(deltaTotal)} $currencySymbol',
                  ),
                  _buildInfoRow(
                    'تغيير الضريبة',
                    '${fmt2(deltaTax)} $currencySymbol',
                  ),
                  _buildInfoRow('تغيير الوزن', '${fmt3(deltaWeight)} جم'),

                  const SizedBox(height: 12),

                  // Per-item diff
                  Text(
                    'تفاصيل الأصناف (قبل → بعد)',
                    style: Theme.of(dialogContext).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (selected.isEmpty)
                    const Text('لا توجد أصناف محددة')
                  else
                    ...selected.map((it) {
                      final weightChanged =
                          (it.weight - it.originalWeight).abs() > 0.0009;
                      final qtyChanged =
                          (it.quantity - it.originalQuantity).abs() > 0;
                      final changed = weightChanged || qtyChanged;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: changed
                                ? Colors.orange.shade300
                                : Colors.grey.shade300,
                            width: changed ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.itemName,
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            Text('العيار: ${it.karat.toStringAsFixed(0)}'),
                            const SizedBox(height: 4),
                            Text(
                              'الوزن: ${fmt3(it.originalWeight)} → ${fmt3(it.weight)} جم',
                            ),
                            Text(
                              'الكمية: ${it.originalQuantity} → ${it.quantity}',
                            ),
                          ],
                        ),
                      );
                    }),

                  const SizedBox(height: 4),
                  Text(
                    'ملاحظة: يوصى بالمرتجع بدلاً من تعديل الفاتورة الأصلية للحفاظ على دقة المخزون والحسابات.',
                    style: Theme.of(
                      dialogContext,
                    ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('رجوع'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(dialogContext);
                _saveReturnInvoice();
              },
              icon: const Icon(Icons.save),
              label: const Text('اعتماد وحفظ'),
            ),
          ],
        );
      },
    );
  }

  // --- Build Steps ---

  Widget _buildSelectInvoiceStep() {
    return Form(
      key: _selectInvoiceFormKey,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            'اختر الفاتورة الأصلية',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),

          // Use shared widget
          OriginalInvoiceSelector(
            api: widget.api,
            invoiceType: _getOriginalInvoiceType(),
            selectedInvoice: selectedOriginalInvoice,
            onInvoiceSelected: (invoice) {
              setState(() {
                selectedOriginalInvoice = invoice;
              });
              if (invoice['id'] != null) {
                _loadOriginalInvoiceDetails(invoice['id']);
              }
            },
          ),

          // Show invoice details if selected
          if (selectedOriginalInvoice != null) ...[
            const SizedBox(height: 16),
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'تفاصيل الفاتورة',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Divider(),
                    _buildInfoRow(
                      'التاريخ',
                      selectedOriginalInvoice!['date'] ?? 'غير متوفر',
                    ),
                    _buildInfoRow(
                      'المبلغ',
                      '${selectedOriginalInvoice!['total_amount'] ?? 0} $currencySymbol',
                    ),
                    if (selectedOriginalInvoice!['customer_name'] != null)
                      _buildInfoRow(
                        'العميل',
                        selectedOriginalInvoice!['customer_name'],
                      ),
                    if (selectedOriginalInvoice!['supplier_name'] != null)
                      _buildInfoRow(
                        'المورد',
                        selectedOriginalInvoice!['supplier_name'],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(value),
        ],
      ),
    );
  }

  Widget _buildItemSummaryChip({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Chip(
      avatar: Icon(icon, size: 18, color: Colors.black87),
      label: Text('$label: $value'),
      backgroundColor: Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  Widget _buildSelectItemsStep() {
    Widget content;

    if (_isLoadingInvoiceDetails) {
      content = const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_invoiceDetailsError != null) {
      content = Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(
              _invoiceDetailsError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ],
        ),
      );
    } else if (_returnItems.isEmpty) {
      content = const Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'سيتم عرض أصناف الفاتورة الأصلية هنا بعد الاختيار',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    } else {
      content = SizedBox(
        height: 320,
        child: ListView.separated(
          itemCount: _returnItems.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final item = _returnItems[index];
            return Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      value: item.isSelected,
                      contentPadding: EdgeInsets.zero,
                      title: Text(item.itemName),
                      subtitle: Text(
                        'عيار ${item.karat} • وزن أصلي ${item.originalWeight.toStringAsFixed(3)} جم',
                      ),
                      onChanged: (value) {
                        setState(() {
                          item.isSelected = value ?? false;
                          item.recalculateTotals();
                        });
                      },
                    ),
                    if (item.isSelected) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: ValueKey(
                                'weight-${item.originalItemId}-$index',
                              ),
                              initialValue: item.weight.toStringAsFixed(3),
                              decoration: InputDecoration(
                                labelText: 'الوزن المرتجع (جم)',
                                helperText:
                                    'الأقصى ${item.originalWeight.toStringAsFixed(3)} جم',
                                border: const OutlineInputBorder(),
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [NormalizeNumberFormatter()],
                              onChanged: (value) {
                                final newWeight =
                                    double.tryParse(
                                      value.replaceAll(',', '.'),
                                    ) ??
                                    item.weight;
                                setState(() {
                                  item.updateWeight(newWeight);
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (item.originalQuantity > 1)
                            Expanded(
                              child: TextFormField(
                                key: ValueKey(
                                  'qty-${item.originalItemId}-$index',
                                ),
                                initialValue: item.quantity.toString(),
                                decoration: InputDecoration(
                                  labelText: 'الكمية المرتجعة',
                                  helperText: 'الأقصى ${item.originalQuantity}',
                                  border: const OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [NormalizeNumberFormatter()],
                                onChanged: (value) {
                                  final newQty =
                                      int.tryParse(value) ?? item.quantity;
                                  setState(() {
                                    item.updateQuantity(newQty);
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          _buildItemSummaryChip(
                            icon: Icons.scale,
                            label: 'الوزن',
                            value: '${item.weight.toStringAsFixed(3)} جم',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.attach_money,
                            label: 'الصافي',
                            value:
                                '${item.net.toStringAsFixed(2)} $currencySymbol',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.percent,
                            label: 'الضريبة',
                            value:
                                '${item.tax.toStringAsFixed(2)} $currencySymbol',
                          ),
                          _buildItemSummaryChip(
                            icon: Icons.summarize,
                            label: 'الإجمالي',
                            value:
                                '${item.total.toStringAsFixed(2)} $currencySymbol',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'اختر الأصناف المرتجعة',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        content,
        const SizedBox(height: 16),
        ElevatedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('إضافة صنف يدوياً'),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('سيتم إضافة هذه الميزة قريباً')),
            );
          },
        ),
      ],
    );
  }

  Widget _buildReturnReasonStep() {
    return Form(
      key: _returnReasonFormKey,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text('سبب الإرجاع', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),
          // Use shared widget
          ReturnReasonInput(
            controller: _returnReasonController,
            isRequired: true,
            maxLines: 4,
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentStep() {
    return Form(
      key: _paymentFormKey,
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            'طريقة الدفع/الاستلام',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),

          DropdownButtonFormField<String>(
            initialValue: paymentMethod,
            decoration: const InputDecoration(
              labelText: 'طريقة الدفع',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('نقداً')),
              DropdownMenuItem(value: 'card', child: Text('بطاقة')),
              DropdownMenuItem(value: 'transfer', child: Text('تحويل')),
              DropdownMenuItem(value: 'deferred', child: Text('آجل')),
            ],
            onChanged: (value) {
              setState(() {
                paymentMethod = value!;
              });
            },
          ),

          const SizedBox(height: 16),

          TextFormField(
            decoration: InputDecoration(
              labelText: 'المبلغ المدفوع/المستلم',
              border: const OutlineInputBorder(),
              suffixText: currencySymbol,
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [NormalizeNumberFormatter()],
            initialValue: amountPaid.toString(),
            onChanged: (value) {
              setState(() {
                amountPaid = double.tryParse(value) ?? 0;
              });
            },
          ),

          const SizedBox(height: 16),

          Card(
            child: ListTile(
              title: const Text('المتبقي'),
              trailing: Text(
                '${amountDue.toStringAsFixed(2)} $currencySymbol',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewStep() {
    final invoice = selectedOriginalInvoice;
    if (invoice == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('الرجاء اختيار الفاتورة الأصلية قبل المتابعة'),
        ),
      );
    }

    final invoiceDisplayNumber = _getInvoiceDisplayNumber(invoice);
    final invoiceDate = invoice['date'] ?? 'غير متوفر';
    final invoiceTotalRaw = invoice['total_amount'] ?? invoice['total'] ?? 0;
    final invoiceTotal = invoiceTotalRaw is num
        ? invoiceTotalRaw.toStringAsFixed(2)
        : invoiceTotalRaw.toString();
    final invoiceCustomer = invoice['customer_name'];
    final invoiceSupplier = invoice['supplier_name'];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text('مراجعة المرتجع', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),

          // Original Invoice Info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'الفاتورة الأصلية',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  _buildInfoRow('رقم الفاتورة', invoiceDisplayNumber),
                  _buildInfoRow('التاريخ', invoiceDate),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Return Reason
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'سبب الإرجاع',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  Text(returnReason),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          if (_selectedItems.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'الأصناف المرتجعة',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    ..._selectedItems.map(
                      (item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                item.itemName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${item.weight.toStringAsFixed(3)} جم',
                              style: const TextStyle(color: Colors.black54),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${item.total.toStringAsFixed(2)} $currencySymbol',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_selectedItems.isNotEmpty) const SizedBox(height: 16),

          // Totals
          Card(
            color: Colors.amber.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildTotalRow(
                    'الوزن الإجمالي',
                    '${totalWeight.toStringAsFixed(2)} جم',
                  ),
                  _buildTotalRow(
                    'المبلغ',
                    '${totalCost.toStringAsFixed(2)} $currencySymbol',
                  ),
                  _buildTotalRow(
                    'الضريبة',
                    '${totalTax.toStringAsFixed(2)} $currencySymbol',
                  ),
                  const Divider(),
                  _buildTotalRow(
                    'الإجمالي',
                    '${grandTotal.toStringAsFixed(2)} $currencySymbol',
                    isTotal: true,
                  ),
                ],
              ),
            ),
          ),
          if (invoiceCustomer != null || invoiceSupplier != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'الأطراف المرتبطة',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Divider(),
                    if (invoiceCustomer != null)
                      _buildInfoRow('العميل', invoiceCustomer),
                    if (invoiceSupplier != null)
                      _buildInfoRow('المورد', invoiceSupplier),
                    _buildInfoRow(
                      'إجمالي الفاتورة الأصلية',
                      '$invoiceTotal $currencySymbol',
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getInvoiceDisplayNumber(Map<String, dynamic> invoice) {
    final rawNumber = invoice['invoice_number'];
    if (rawNumber != null) {
      final trimmed = rawNumber.toString().trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    final legacyNumber = invoice['number'];
    if (legacyNumber != null) {
      final legacyStr = legacyNumber.toString().trim();
      if (legacyStr.isNotEmpty) {
        return '#$legacyStr';
      }
    }

    final legacyId = invoice['id'];
    return legacyId != null ? '#${legacyId.toString()}' : '#---';
  }

  Widget _buildTotalRow(String label, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 18 : 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 18 : 14,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _getReturnTypeDescription();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_getReturnTypeDisplayName()),
        backgroundColor: AppColors.invoiceReturn,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: InvoiceTypeBanner(
              title: _getReturnTypeDisplayName(),
              subtitle: subtitle,
              color: AppColors.invoiceReturn,
              icon: Icons.undo_rounded,
              trailing: Text('نوع الفاتورة', style: theme.textTheme.labelLarge),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Stepper(
              currentStep: _currentStep,
              onStepContinue: _onStepContinue,
              onStepCancel: _onStepCancel,
              controlsBuilder: (context, details) {
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    children: [
                      ElevatedButton(
                        onPressed: details.onStepContinue,
                        child: Text(_currentStep == 4 ? 'حفظ' : 'التالي'),
                      ),
                      const SizedBox(width: 8),
                      if (_currentStep > 0)
                        TextButton(
                          onPressed: details.onStepCancel,
                          child: const Text('السابق'),
                        ),
                    ],
                  ),
                );
              },
              steps: [
                Step(
                  title: const Text('اختيار الفاتورة'),
                  content: _buildSelectInvoiceStep(),
                  isActive: _currentStep >= 0,
                  state: _currentStep > 0
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('الأصناف المرتجعة'),
                  content: _buildSelectItemsStep(),
                  isActive: _currentStep >= 1,
                  state: _currentStep > 1
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('سبب الإرجاع'),
                  content: _buildReturnReasonStep(),
                  isActive: _currentStep >= 2,
                  state: _currentStep > 2
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('الدفع'),
                  content: _buildPaymentStep(),
                  isActive: _currentStep >= 3,
                  state: _currentStep > 3
                      ? StepState.complete
                      : StepState.indexed,
                ),
                Step(
                  title: const Text('مراجعة'),
                  content: _buildReviewStep(),
                  isActive: _currentStep >= 4,
                  state: StepState.indexed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
