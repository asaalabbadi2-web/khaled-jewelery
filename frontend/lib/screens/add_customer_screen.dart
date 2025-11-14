import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../utils.dart';

class AddCustomerScreen extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? customer; // Make customer optional
  final bool isArabic;

  const AddCustomerScreen({
    super.key,
    required this.api,
    this.customer, // Receive customer data for editing
    this.isArabic = true,
  });

  @override
  State<AddCustomerScreen> createState() => _AddCustomerScreenState();
}

class _AddCustomerScreenState extends State<AddCustomerScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController nameController;
  late TextEditingController phoneController;
  late TextEditingController emailController;
  late TextEditingController streetController;
  late TextEditingController buildingController;
  late TextEditingController districtController;
  late TextEditingController cityController;
  late TextEditingController postalController;
  late TextEditingController countryController;
  late TextEditingController notesController;
  late TextEditingController idController;
  late TextEditingController birthDateController;
  late TextEditingController idVersionNumberController;

  bool _isLoading = false;
  bool get _isEditMode => widget.customer != null;

  String? _nextCustomerCode;
  int? _remainingCapacity;

  @override
  void initState() {
    super.initState();
    final customer = widget.customer;

    nameController = TextEditingController(text: customer?['name'] ?? '');
    phoneController = TextEditingController(text: customer?['phone'] ?? '');
    emailController = TextEditingController(text: customer?['email'] ?? '');
    streetController = TextEditingController(
      text: customer?['address_line_1'] ?? '',
    );
    buildingController = TextEditingController(
      text: customer?['address_line_2'] ?? '',
    ); // Assuming building maps to address_line_2
    districtController = TextEditingController(
      text: customer?['district'] ?? '',
    );
    cityController = TextEditingController(text: customer?['city'] ?? '');
    postalController = TextEditingController(
      text: customer?['postal_code'] ?? '',
    );
    countryController = TextEditingController(text: customer?['country'] ?? '');
    notesController = TextEditingController(text: customer?['notes'] ?? '');
    idController = TextEditingController(text: customer?['id_number'] ?? '');
    birthDateController = TextEditingController(
      text: customer?['birth_date'] ?? '',
    );
    idVersionNumberController = TextEditingController(
      text: customer?['id_version_number'] ?? '',
    );

    // Fetch next customer code if adding new customer
    if (!_isEditMode) {
      _loadNextCustomerCode();
    }
  }

  Future<void> _loadNextCustomerCode() async {
    try {
      final data = await widget.api.getNextCustomerCode();
      setState(() {
        _nextCustomerCode = data['next_code'];
        _remainingCapacity = data['remaining_capacity'];
      });
    } catch (e) {
      debugPrint('Error loading next customer code: $e');
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    streetController.dispose();
    buildingController.dispose();
    districtController.dispose();
    cityController.dispose();
    postalController.dispose();
    countryController.dispose();
    notesController.dispose();
    idController.dispose();
    birthDateController.dispose();
    idVersionNumberController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        birthDateController.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _submitForm() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);

      final customerData = {
        'name': nameController.text,
        'phone': normalizeNumber(phoneController.text),
        'email': emailController.text,
        'id_number': normalizeNumber(idController.text),
        'birth_date': birthDateController.text.isNotEmpty
            ? birthDateController.text
            : null,
        'id_version_number': idVersionNumberController.text,
        'address_line_1': streetController.text,
        'address_line_2': buildingController.text,
        'city': cityController.text,
        'state': districtController.text, // Assuming district maps to state
        'postal_code': postalController.text,
        'country': countryController.text,
        'notes': notesController.text,
      };

      try {
        if (_isEditMode) {
          await widget.api.updateCustomer(widget.customer!['id'], customerData);
        } else {
          await widget.api.addCustomer(customerData);
        }

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditMode ? 'تم تحديث العميل بنجاح' : 'تم إضافة العميل بنجاح',
            ),
            backgroundColor: Colors.green,
          ),
        );

        Navigator.pop(context, true); // Return true to indicate success
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('حدث خطأ: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final gold = const Color(0xFFF7C873);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditMode
              ? (isAr ? 'تعديل عميل' : 'Edit Customer')
              : (isAr ? 'إضافة عميل جديد' : 'Add New Customer'),
        ),
        backgroundColor: Colors.black,
        foregroundColor: gold,
      ),
      backgroundColor: const Color(0xFF232323),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: gold))
          : SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Display next customer code for new customers
                    if (!_isEditMode && _nextCustomerCode != null)
                      Container(
                        margin: EdgeInsets.only(bottom: 16),
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: gold, width: 1),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.tag, color: gold, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  isAr ? 'الكود التالي:' : 'Next Code:',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  _nextCustomerCode!,
                                  style: TextStyle(
                                    color: gold,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                            if (_remainingCapacity != null)
                              Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  isAr
                                      ? 'السعة المتبقية: ${_remainingCapacity!.toStringAsFixed(0)}'
                                      : 'Remaining Capacity: ${_remainingCapacity!.toStringAsFixed(0)}',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    _buildTextFormField(
                      controller: nameController,
                      label: isAr ? 'اسم العميل' : 'Customer Name',
                      hint: AutofillHints.name,
                    ),
                    _buildTextFormField(
                      controller: phoneController,
                      label: isAr ? 'رقم الهاتف' : 'Phone Number',
                      hint: AutofillHints.telephoneNumber,
                      isNumeric: true,
                    ),
                    _buildTextFormField(
                      controller: emailController,
                      label: isAr ? 'البريد الإلكتروني' : 'Email',
                      hint: AutofillHints.email,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    _buildTextFormField(
                      controller: idController,
                      label: isAr ? 'رقم الهوية' : 'ID Number',
                      isNumeric: true,
                    ),
                    _buildTextFormField(
                      controller: birthDateController,
                      label: isAr ? 'تاريخ الميلاد' : 'Birth Date',
                      readOnly: true,
                      onTap: _selectDate,
                      suffixIcon: Icon(Icons.calendar_today, color: gold),
                    ),
                    _buildTextFormField(
                      controller: idVersionNumberController,
                      label: isAr ? 'رقم نسخة الهوية' : 'ID Version Number',
                      isNumeric: true,
                    ),
                    _buildTextFormField(
                      controller: streetController,
                      label: isAr ? 'الشارع' : 'Street',
                      hint: AutofillHints.streetAddressLine1,
                    ),
                    _buildTextFormField(
                      controller: buildingController,
                      label: isAr ? 'المبنى' : 'Building',
                      hint: AutofillHints.streetAddressLine2,
                    ),
                    _buildTextFormField(
                      controller: districtController,
                      label: isAr ? 'الحي' : 'District',
                    ),
                    _buildTextFormField(
                      controller: cityController,
                      label: isAr ? 'المدينة' : 'City',
                      hint: AutofillHints.addressCity,
                    ),
                    _buildTextFormField(
                      controller: postalController,
                      label: isAr ? 'الرمز البريدي' : 'Postal Code',
                      hint: AutofillHints.postalCode,
                      isNumeric: true,
                    ),
                    _buildTextFormField(
                      controller: countryController,
                      label: isAr ? 'الدولة' : 'Country',
                      hint: AutofillHints.countryName,
                    ),
                    _buildTextFormField(
                      controller: notesController,
                      label: isAr ? 'ملاحظات' : 'Notes',
                      maxLines: 3,
                    ),
                    SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: gold,
                        foregroundColor: Colors.black,
                        padding: EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _submitForm,
                      child: Text(
                        isAr ? 'حفظ' : 'Save',
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 18),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildTextFormField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool isNumeric = false,
    int maxLines = 1,
    bool readOnly = false,
    VoidCallback? onTap,
    Widget? suffixIcon,
    TextInputType? keyboardType,
  }) {
    final gold = const Color(0xFFF7C873);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        onTap: onTap,
        style: TextStyle(color: Colors.white, fontFamily: 'Cairo'),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: gold, fontFamily: 'Cairo'),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: Colors.grey[850],
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey[700]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: gold),
          ),
        ),
        keyboardType: isNumeric ? TextInputType.number : keyboardType,
        autofillHints: hint != null ? [hint] : null,
        maxLines: maxLines,
        inputFormatters: isNumeric
            ? [
                NormalizeNumberFormatter(),
                FilteringTextInputFormatter.digitsOnly,
              ]
            : [NormalizeNumberFormatter()],
        validator: (value) {
          if (controller == nameController &&
              (value == null || value.isEmpty)) {
            return widget.isArabic
                ? 'الرجاء إدخال اسم العميل'
                : 'Please enter a customer name';
          }
          if (controller == phoneController &&
              (value == null || value.isEmpty)) {
            return widget.isArabic
                ? 'الرجاء إدخال رقم الهاتف'
                : 'Please enter a phone number';
          }
          return null;
        },
      ),
    );
  }
}
