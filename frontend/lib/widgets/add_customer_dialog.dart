import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../utils.dart';

class AddCustomerDialog extends StatefulWidget {
  final ApiService api;
  final String invoiceType;

  const AddCustomerDialog({
    super.key,
    required this.api,
    required this.invoiceType,
  });

  @override
  State<AddCustomerDialog> createState() => _AddCustomerDialogState();
}

class _AddCustomerDialogState extends State<AddCustomerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _idNumberController = TextEditingController();
  final _birthDateController = TextEditingController();
  final _idVersionNumberController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _idNumberController.dispose();
    _birthDateController.dispose();
    _idVersionNumberController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      try {
        final customerData = {
          'name': _nameController.text,
          'phone': normalizeNumber(_phoneController.text),
          'email': _emailController.text,
          'id_number': normalizeNumber(_idNumberController.text),
          'birth_date': _birthDateController.text.isNotEmpty
              ? _birthDateController.text
              : null,
          'id_version_number': normalizeNumber(_idVersionNumberController.text),
          'notes': _notesController.text,
        };

        final response = await widget.api.addCustomer(customerData);

        if (mounted) {
          // Pop with the newly created customer data from the API response
          Navigator.of(context).pop(response);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('فشل حفظ العميل: $e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // CORRECTED: Check for "مشتريات" which is the string passed from the home screen.
    bool isPurchase = widget.invoiceType.contains('مشتريات');

    return AlertDialog(
      title: const Text('إضافة عميل جديد'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'الاسم'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'الرجاء إدخال الاسم';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'رقم الجوال'),
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  NormalizeNumberFormatter(),
                  FilteringTextInputFormatter.digitsOnly,
                ],
                validator: (value) {
                  // Mandatory for Sales invoices, optional for Purchase
                  if (!isPurchase && (value == null || value.isEmpty)) {
                    return 'رقم الجوال إلزامي لفواتير المبيعات';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
              ),
              if (isPurchase) ...[
                TextFormField(
                  controller: _idNumberController,
                  decoration: const InputDecoration(labelText: 'رقم الهوية'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    NormalizeNumberFormatter(),
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  validator: (value) {
                    if (isPurchase && (value == null || value.isEmpty)) {
                      return 'رقم الهوية إلزامي';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  controller: _birthDateController,
                  decoration: const InputDecoration(
                    labelText: 'تاريخ الميلاد (YYYY-MM-DD)',
                  ),
                  validator: (value) {
                    if (isPurchase && (value == null || value.isEmpty)) {
                      return 'تاريخ الميلاد إلزامي';
                    }
                    return null;
                  },
                  onTap: () async {
                    FocusScope.of(context).requestFocus(FocusNode());
                    DateTime? picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      _birthDateController.text =
                          "${picked.year}-${picked.month}-${picked.day}";
                    }
                  },
                ),
                TextFormField(
                  controller: _idVersionNumberController,
                  decoration: const InputDecoration(
                    labelText: 'رقم نسخة الهوية',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    NormalizeNumberFormatter(),
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  validator: (value) {
                    if (isPurchase && (value == null || value.isEmpty)) {
                      return 'رقم نسخة الهوية إلزامي';
                    }
                    return null;
                  },
                ),
              ],
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
                inputFormatters: [
                  // لا نمنع نصوصًا، فقط نحول الأرقام العربية أثناء الإدخال
                  NormalizeNumberFormatter(),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('حفظ')),
      ],
    );
  }
}
