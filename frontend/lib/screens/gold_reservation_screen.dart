import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import 'weight_closing_settings_screen.dart';
import '../utils.dart';

/// شاشة التسكير - حجز ذهب خام من مكاتب بيع وشراء الذهب
class GoldReservationScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const GoldReservationScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<GoldReservationScreen> createState() => _GoldReservationScreenState();
}

class _GoldReservationScreenState extends State<GoldReservationScreen> {
  final _formKey = GlobalKey<FormState>();

  // بيانات الحجز
  DateTime _reservationDate = DateTime.now();
  int? _selectedOfficeId; // معرف المكتب المحجوز منه
  String? _selectedOfficeName; // اسم المكتب
  int _selectedKarat = 24; // العيار (افتراضي 24 للذهب الخام)
  double _weight = 0.0; // الوزن بالجرام
  double _pricePerGram = 0.0; // السعر للجرام الواحد
  double _totalAmount = 0.0; // المبلغ الإجمالي
  String _paymentStatus = 'pending'; // حالة الدفع: pending, partial, paid
  double _paidAmount = 0.0; // المبلغ المدفوع
  DateTime? _deliveryDate; // تاريخ الاستلام المتوقع

  // Controllers
  final _weightController = TextEditingController();
  final _priceController = TextEditingController();
  final _notesController = TextEditingController();
  final _contactPersonController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _paidAmountController = TextEditingController();

  // بيانات
  List<Map<String, dynamic>> _offices = []; // قائمة المكاتب
  bool _isLoading = false;
  double _currentGoldPrice = 0.0;
  int? _selectedSupplierId;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _weightController.addListener(_calculateTotal);
    _priceController.addListener(_calculateTotal);
    _paidAmountController.addListener(_updatePaymentStatus);
  }

  @override
  void dispose() {
    _weightController.dispose();
    _priceController.dispose();
    _notesController.dispose();
    _contactPersonController.dispose();
    _contactPhoneController.dispose();
    _paidAmountController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      // تحميل سعر الذهب الحالي
      final goldPriceResponse = await widget.api.getGoldPrice();
      if (goldPriceResponse['price_usd_per_oz'] != null) {
        final pricePerOz = (goldPriceResponse['price_usd_per_oz'] as num)
            .toDouble();
        // تحويل من أونصة إلى جرام (1 أونصة = 31.1035 جرام)
        // وتحويل من دولار إلى ريال (افترض سعر صرف 3.75)
        setState(() {
          _currentGoldPrice = (pricePerOz / 31.1035) * 3.75;
          _priceController.text = _currentGoldPrice.toStringAsFixed(2);
        });
      }

      // تحميل قائمة المكاتب والموردين من API
      final offices = await widget.api.getOffices(activeOnly: true);
      setState(() {
        _offices = offices.cast<Map<String, dynamic>>();
      });
    } catch (e) {
      _showMessage('خطأ في تحميل البيانات: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _calculateTotal() {
    final weight = double.tryParse(_weightController.text) ?? 0.0;
    final price = double.tryParse(_priceController.text) ?? 0.0;
    setState(() {
      _weight = weight;
      _pricePerGram = price;
      _totalAmount = weight * price;
    });
  }

  void _updatePaymentStatus() {
    final paid = double.tryParse(_paidAmountController.text) ?? 0.0;
    setState(() {
      _paidAmount = paid;
      if (paid >= _totalAmount && _totalAmount > 0) {
        _paymentStatus = 'paid';
      } else if (paid > 0) {
        _paymentStatus = 'partial';
      } else {
        _paymentStatus = 'pending';
      }
    });
  }

  Future<void> _saveReservation() async {
    if (!_formKey.currentState!.validate()) {
      _showMessage('الرجاء إكمال جميع الحقول المطلوبة', isError: true);
      return;
    }

    if (_selectedOfficeId == null) {
      _showMessage('الرجاء اختيار المكتب', isError: true);
      return;
    }

    if (_weight <= 0) {
      _showMessage('الرجاء إدخال وزن صحيح', isError: true);
      return;
    }

    final confirmed = await _showConfirmDialog();
    if (!confirmed) return;

    setState(() => _isLoading = true);
    try {
      // إنشاء بيانات الحجز
      final reservationData = {
        'reservation_date': _reservationDate.toIso8601String(),
        'office_id': _selectedOfficeId,
        'office_name': _selectedOfficeName,
        'karat': _selectedKarat,
        'weight': _weight,
        'price_per_gram': _pricePerGram,
        'execution_price_per_gram': _pricePerGram,
        'total_amount': _totalAmount,
        'paid_amount': _paidAmount,
        'payment_status': _paymentStatus,
        'contact_person': _contactPersonController.text.trim().isEmpty
            ? null
            : _contactPersonController.text.trim(),
        'contact_phone': _contactPhoneController.text.trim().isEmpty
            ? null
            : _contactPhoneController.text.trim(),
        'notes': _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        'delivery_date': _deliveryDate?.toIso8601String(),
        'status': 'reserved',
        'created_by': 'flutter_app',
        if (_selectedSupplierId != null) 'supplier_id': _selectedSupplierId,
      };

      final response = await widget.api.createOfficeReservation(
        reservationData,
      );

      if (!mounted) return;

      final code = response['reservation_code'] ?? '';
      final invoiceId =
          response['purchase_invoice_id'] ?? response['invoice_id'];
      String successMessage;
      if (invoiceId != null) {
        successMessage = code is String && code.isNotEmpty
            ? 'تم حفظ الحجز بنجاح (رقم $code) - فاتورة: #$invoiceId'
            : 'تم حفظ الحجز بنجاح - فاتورة: #$invoiceId';
      } else {
        successMessage = code is String && code.isNotEmpty
            ? 'تم حفظ الحجز بنجاح (رقم $code)'
            : 'تم حفظ الحجز بنجاح';
      }

      _showMessage(successMessage, isError: false);
      Navigator.pop(context, response);
    } catch (e) {
      if (!mounted) return;
      _showMessage('فشل حفظ الحجز: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<bool> _showConfirmDialog() async {
    final isAr = widget.isArabic;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(isAr ? 'تأكيد الحجز' : 'Confirm Reservation'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isAr ? "المكتب" : "Office"}: ${_selectedOfficeName ?? ""}',
                ),
                Text(
                  '${isAr ? "الوزن" : "Weight"}: ${_weight.toStringAsFixed(3)} ${isAr ? "جرام" : "grams"}',
                ),
                Text('${isAr ? "العيار" : "Karat"}: $_selectedKarat'),
                Text(
                  '${isAr ? "المبلغ الإجمالي" : "Total"}: ${_totalAmount.toStringAsFixed(2)} ر.س',
                ),
                Text(
                  '${isAr ? "المبلغ المدفوع" : "Paid"}: ${_paidAmount.toStringAsFixed(2)} ر.س',
                ),
                if (_totalAmount - _paidAmount > 0)
                  Text(
                    '${isAr ? "المتبقي" : "Remaining"}: ${(_totalAmount - _paidAmount).toStringAsFixed(2)} ر.س',
                    style: const TextStyle(
                      color: AppColors.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(isAr ? 'إلغاء' : 'Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(isAr ? 'تأكيد' : 'Confirm'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.error : AppColors.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'التسكير - حجز ذهب خام' : 'Gold Reservation'),
        backgroundColor: AppColors.darkGold,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_suggest_outlined),
            tooltip: isAr ? 'إعدادات التسكير الآلي' : 'Auto close settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const WeightClosingSettingsScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfoDialog(),
            tooltip: isAr ? 'معلومات' : 'Info',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // بطاقة معلومات السعر الحالي
                    Card(
                      color: AppColors.lightGold.withValues(alpha: 0.4),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.monetization_on,
                              color: AppColors.mediumGold,
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isAr
                                      ? 'سعر الذهب الحالي'
                                      : 'Current Gold Price',
                                  style: theme.textTheme.labelSmall,
                                ),
                                Text(
                                  '${_currentGoldPrice.toStringAsFixed(2)} ${isAr ? "ر.س/جم" : "SAR/g"}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.mediumGold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // التاريخ
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.calendar_today),
                        title: Text(isAr ? 'تاريخ الحجز' : 'Reservation Date'),
                        subtitle: Text(
                          DateFormat('yyyy-MM-dd').format(_reservationDate),
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _reservationDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now(),
                          );
                          if (picked != null) {
                            setState(() => _reservationDate = picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),

                    // اختيار المكتب
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr ? 'المكتب' : 'Office',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<int>(
                              key: ValueKey(
                                'office-${_selectedOfficeId ?? 'none'}',
                              ),
                              initialValue: _selectedOfficeId,
                              decoration: InputDecoration(
                                labelText: isAr
                                    ? 'اختر المكتب'
                                    : 'Select Office',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.store),
                              ),
                              isExpanded: true,
                              icon: const Icon(
                                Icons.arrow_drop_down_circle_outlined,
                              ),
                              items: _offices.map((office) {
                                return DropdownMenuItem<int>(
                                  value: office['id'],
                                  child: Text(office['name'] ?? ''),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _selectedOfficeId = value;
                                  final selectedOffice = _offices.firstWhere(
                                    (o) => o['id'] == value,
                                    orElse: () => {},
                                  );
                                  _selectedOfficeName = selectedOffice['name'];
                                  _contactPersonController.text =
                                      selectedOffice['contact_person'] ?? '';
                                  _contactPhoneController.text =
                                      selectedOffice['phone'] ?? '';
                                  _selectedSupplierId =
                                      selectedOffice['supplier_id'] as int?;
                                });
                              },
                              validator: (value) {
                                if (value == null) {
                                  return isAr
                                      ? 'الرجاء اختيار المكتب'
                                      : 'Please select office';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // بيانات الاتصال
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr ? 'بيانات الاتصال' : 'Contact Information',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _contactPersonController,
                              decoration: InputDecoration(
                                labelText: isAr
                                    ? 'اسم المسؤول'
                                    : 'Contact Person',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.person),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _contactPhoneController,
                              decoration: InputDecoration(
                                labelText: isAr ? 'رقم الجوال' : 'Phone Number',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.phone),
                              ),
                              keyboardType: TextInputType.phone,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // بيانات الذهب
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr ? 'بيانات الذهب' : 'Gold Details',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            // العيار
                            DropdownButtonFormField<int>(
                              initialValue: _selectedKarat,
                              decoration: InputDecoration(
                                labelText: isAr ? 'العيار' : 'Karat',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.verified),
                              ),
                              items: [24, 22, 21, 18].map((karat) {
                                return DropdownMenuItem(
                                  value: karat,
                                  child: Text(
                                    '${isAr ? "عيار" : "Karat"} $karat',
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() => _selectedKarat = value!);
                              },
                            ),
                            const SizedBox(height: 12),
                            // الوزن
                            TextFormField(
                              controller: _weightController,
                              decoration: InputDecoration(
                                labelText: isAr
                                    ? 'الوزن (جرام)'
                                    : 'Weight (grams)',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.scale),
                                suffixText: isAr ? 'جم' : 'g',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [NormalizeNumberFormatter()],
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return isAr
                                      ? 'الرجاء إدخال الوزن'
                                      : 'Please enter weight';
                                }
                                final weight = double.tryParse(value);
                                if (weight == null || weight <= 0) {
                                  return isAr
                                      ? 'الرجاء إدخال وزن صحيح'
                                      : 'Please enter valid weight';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            // السعر للجرام
                            TextFormField(
                              controller: _priceController,
                              decoration: InputDecoration(
                                labelText: isAr
                                    ? 'السعر للجرام (ر.س)'
                                    : 'Price per gram (SAR)',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.attach_money),
                                suffixText: isAr ? 'ر.س' : 'SAR',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [NormalizeNumberFormatter()],
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return isAr
                                      ? 'الرجاء إدخال السعر'
                                      : 'Please enter price';
                                }
                                final price = double.tryParse(value);
                                if (price == null || price <= 0) {
                                  return isAr
                                      ? 'الرجاء إدخال سعر صحيح'
                                      : 'Please enter valid price';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // الدفع
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr ? 'الدفع' : 'Payment',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            // المبلغ الإجمالي
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppColors.lightGold.withValues(
                                  alpha: 0.35,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppColors.mediumGold.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    isAr ? 'المبلغ الإجمالي' : 'Total Amount',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  Text(
                                    '${_totalAmount.toStringAsFixed(2)} ${isAr ? "ر.س" : "SAR"}',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.mediumGold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            // المبلغ المدفوع
                            TextFormField(
                              controller: _paidAmountController,
                              decoration: InputDecoration(
                                labelText: isAr
                                    ? 'المبلغ المدفوع'
                                    : 'Paid Amount',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.payments),
                                suffixText: isAr ? 'ر.س' : 'SAR',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: [NormalizeNumberFormatter()],
                            ),
                            const SizedBox(height: 12),
                            // المتبقي
                            if (_totalAmount - _paidAmount > 0)
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.error.withValues(
                                    alpha: 0.08,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: AppColors.error.withValues(
                                      alpha: 0.35,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      isAr ? 'المبلغ المتبقي' : 'Remaining',
                                      style: theme.textTheme.bodyLarge,
                                    ),
                                    Text(
                                      '${(_totalAmount - _paidAmount).toStringAsFixed(2)} ${isAr ? "ر.س" : "SAR"}',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.error,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // تاريخ الاستلام المتوقع
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.event),
                        title: Text(
                          isAr
                              ? 'تاريخ الاستلام المتوقع'
                              : 'Expected Delivery Date',
                        ),
                        subtitle: Text(
                          _deliveryDate != null
                              ? DateFormat('yyyy-MM-dd').format(_deliveryDate!)
                              : (isAr ? 'غير محدد' : 'Not set'),
                        ),
                        trailing: const Icon(Icons.edit),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now().add(
                              const Duration(days: 7),
                            ),
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (picked != null) {
                            setState(() => _deliveryDate = picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ملاحظات
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextFormField(
                          controller: _notesController,
                          decoration: InputDecoration(
                            labelText: isAr ? 'ملاحظات' : 'Notes',
                            border: const OutlineInputBorder(),
                            prefixIcon: const Icon(Icons.note),
                          ),
                          maxLines: 3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // زر الحفظ
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _saveReservation,
                      icon: const Icon(Icons.save),
                      label: Text(
                        isAr ? 'حفظ الحجز' : 'Save Reservation',
                        style: const TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: AppColors.primaryGold,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  void _showInfoDialog() {
    final isAr = widget.isArabic;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isAr ? 'ما هو التسكير؟' : 'What is Gold Reservation?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAr
                    ? 'التسكير هو عملية حجز ذهب خام (غير مصنع) من مكاتب بيع وشراء الذهب.'
                    : 'Gold reservation is the process of reserving raw (unmanufactured) gold from gold trading offices.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(isAr ? 'الاستخدامات:' : 'Uses:'),
              Text(
                isAr
                    ? '• حجز ذهب لتصنيعه لاحقاً'
                    : '• Reserve gold for later manufacturing',
              ),
              Text(
                isAr
                    ? '• التعامل مع مكاتب الذهب الخام'
                    : '• Deal with raw gold offices',
              ),
              Text(
                isAr
                    ? '• تسجيل الدفعات والمبالغ المتبقية'
                    : '• Record payments and remaining amounts',
              ),
              Text(
                isAr ? '• متابعة تواريخ الاستلام' : '• Track delivery dates',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(isAr ? 'حسناً' : 'OK'),
          ),
        ],
      ),
    );
  }
}
