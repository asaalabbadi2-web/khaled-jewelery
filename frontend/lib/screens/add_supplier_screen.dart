import 'package:flutter/material.dart';
import '../api_service.dart';

class AddSupplierScreen extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? supplier;

  const AddSupplierScreen({super.key, required this.api, this.supplier});

  @override
  _AddSupplierScreenState createState() => _AddSupplierScreenState();
}

class _AddSupplierScreenState extends State<AddSupplierScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _emailController;
  late TextEditingController _addressLine1Controller;
  late TextEditingController _addressLine2Controller;
  late TextEditingController _cityController;
  late TextEditingController _stateController;
  late TextEditingController _postalCodeController;
  late TextEditingController _countryController;

  bool get _isEditMode => widget.supplier != null;

  String? _nextSupplierCode;
  int? _remainingCapacity;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.supplier?['name'] ?? '',
    );
    _phoneController = TextEditingController(
      text: widget.supplier?['phone'] ?? '',
    );
    _emailController = TextEditingController(
      text: widget.supplier?['email'] ?? '',
    );
    _addressLine1Controller = TextEditingController(
      text: widget.supplier?['address_line_1'] ?? '',
    );
    _addressLine2Controller = TextEditingController(
      text: widget.supplier?['address_line_2'] ?? '',
    );
    _cityController = TextEditingController(
      text: widget.supplier?['city'] ?? '',
    );
    _stateController = TextEditingController(
      text: widget.supplier?['state'] ?? '',
    );
    _postalCodeController = TextEditingController(
      text: widget.supplier?['postal_code'] ?? '',
    );
    _countryController = TextEditingController(
      text: widget.supplier?['country'] ?? '',
    );

    // Fetch next supplier code if adding new supplier
    if (!_isEditMode) {
      _loadNextSupplierCode();
    }
  }

  Future<void> _loadNextSupplierCode() async {
    try {
      final data = await widget.api.getNextSupplierCode();
      setState(() {
        _nextSupplierCode = data['next_code'];
        _remainingCapacity = data['remaining_capacity'];
      });
    } catch (e) {
      debugPrint('Error loading next supplier code: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressLine1Controller.dispose();
    _addressLine2Controller.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _postalCodeController.dispose();
    _countryController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      final data = {
        'name': _nameController.text,
        'phone': _phoneController.text,
        'email': _emailController.text,
        'address_line_1': _addressLine1Controller.text,
        'address_line_2': _addressLine2Controller.text,
        'city': _cityController.text,
        'state': _stateController.text,
        'postal_code': _postalCodeController.text,
        'country': _countryController.text,
      };

      try {
        if (widget.supplier == null) {
          await widget.api.addSupplier(data);
        } else {
          await widget.api.updateSupplier(widget.supplier!['id'], data);
        }
        Navigator.pop(context, true); // Return true to indicate success
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save supplier: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gold = const Color(0xFFF7C873);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.supplier == null ? 'إضافة مورد جديد' : 'تعديل مورد'),
        backgroundColor: Colors.black,
        foregroundColor: gold,
      ),
      backgroundColor: const Color(0xFF232323),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              // Display next supplier code for new suppliers
              if (!_isEditMode && _nextSupplierCode != null)
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
                            'الكود التالي:',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            _nextSupplierCode!,
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
                            'السعة المتبقية: ${_remainingCapacity!.toStringAsFixed(0)}',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'الاسم'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'الرجاء إدخال اسم المورد';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'رقم الهاتف'),
              ),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
              ),
              TextFormField(
                controller: _addressLine1Controller,
                decoration: const InputDecoration(
                  labelText: 'العنوان - السطر ١',
                ),
              ),
              TextFormField(
                controller: _addressLine2Controller,
                decoration: const InputDecoration(
                  labelText: 'العنوان - السطر ٢',
                ),
              ),
              TextFormField(
                controller: _cityController,
                decoration: const InputDecoration(labelText: 'المدينة'),
              ),
              TextFormField(
                controller: _stateController,
                decoration: const InputDecoration(
                  labelText: 'المنطقة/المحافظة',
                ),
              ),
              TextFormField(
                controller: _postalCodeController,
                decoration: const InputDecoration(labelText: 'الرمز البريدي'),
              ),
              TextFormField(
                controller: _countryController,
                decoration: const InputDecoration(labelText: 'الدولة'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _submit,
                child: Text(widget.supplier == null ? 'إضافة' : 'تحديث'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
