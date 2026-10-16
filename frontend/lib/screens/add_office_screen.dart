import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart';
import '../utils.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

import '../widgets/party_picker_dialog.dart';
import '../widgets/safe_box_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';
import '../widgets/app_feedback.dart';

/// شاشة إضافة أو تعديل مكتب
class AddOfficeScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final Map<String, dynamic>? office; // null = إضافة جديد، موجود = تعديل

  const AddOfficeScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.office,
  });

  @override
  State<AddOfficeScreen> createState() => _AddOfficeScreenState();
}

class _AddOfficeScreenState extends State<AddOfficeScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  // Supplier linking
  String _supplierLinkMode = 'new'; // new | existing
  bool _isLoadingSuppliers = false;
  List<Map<String, dynamic>> _suppliers = const [];
  Map<String, dynamic>? _selectedSupplier;

  // Gold safe linking for existing supplier
  String _goldSafeLinkMode = 'new'; // new | existing
  bool _isLoadingGoldSafeBoxes = false;
  List<SafeBoxModel> _goldSafeBoxes = const [];
  SafeBoxModel? _selectedGoldSafe;

  // Opening balances (used mainly when creating a new supplier)
  final _openingCashController = TextEditingController();
  final _openingGoldMainController = TextEditingController();

  // Controllers
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _contactPersonController = TextEditingController();
  final _addressLine1Controller = TextEditingController();
  final _addressLine2Controller = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _postalCodeController = TextEditingController();
  final _licenseNumberController = TextEditingController();
  final _taxNumberController = TextEditingController();
  final _notesController = TextEditingController();

  String _country = 'Saudi Arabia';
  bool _active = true;

  @override
  void initState() {
    super.initState();
    if (widget.office != null) {
      _loadOfficeData();
    }

    _loadSuppliers();
    _loadGoldSafeBoxes();
  }

  Future<void> _loadSuppliers() async {
    setState(() => _isLoadingSuppliers = true);
    try {
      final rows = await widget.api.getSuppliers();
      if (!mounted) return;
      setState(() {
        _suppliers = rows.whereType<Map<String, dynamic>>().toList();

        final currentId = _parseId(_selectedSupplier?['id']);
        if (currentId != null) {
          final match = _suppliers
              .where((m) => _parseId(m['id']) == currentId)
              .cast<Map<String, dynamic>>()
              .toList();
          if (match.isNotEmpty) {
            _selectedSupplier = match.first;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('خطأ في تحميل الموردين: $e', isError: true);
    } finally {
      if (!mounted) return;
      setState(() => _isLoadingSuppliers = false);
    }
  }

  Future<void> _loadGoldSafeBoxes() async {
    setState(() => _isLoadingGoldSafeBoxes = true);
    try {
      final boxes = await widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
      );
      if (!mounted) return;
      setState(() {
        _goldSafeBoxes = boxes;

        final currentId = _selectedGoldSafe?.id;
        if (currentId != null) {
          final match = _goldSafeBoxes
              .where((sb) => sb.id == currentId)
              .toList();
          if (match.isNotEmpty) {
            _selectedGoldSafe = match.first;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      _showMessage('خطأ في تحميل خزائن الذهب: $e', isError: true);
    } finally {
      if (!mounted) return;
      setState(() => _isLoadingGoldSafeBoxes = false);
    }
  }

  void _loadOfficeData() {
    final office = widget.office!;
    _nameController.text = office['name'] ?? '';
    _phoneController.text = office['phone'] ?? '';
    _emailController.text = office['email'] ?? '';
    _contactPersonController.text = office['contact_person'] ?? '';
    _addressLine1Controller.text = office['address_line_1'] ?? '';
    _addressLine2Controller.text = office['address_line_2'] ?? '';
    _cityController.text = office['city'] ?? '';
    _stateController.text = office['state'] ?? '';
    _postalCodeController.text = office['postal_code'] ?? '';
    _country = office['country'] ?? 'Saudi Arabia';
    _licenseNumberController.text = office['license_number'] ?? '';
    _taxNumberController.text = office['tax_number'] ?? '';
    _notesController.text = office['notes'] ?? '';
    _active = office['active'] ?? true;

    // Default: existing supplier when editing
    final supplierIdRaw = office['supplier_id'];
    final supplierId = supplierIdRaw is int
        ? supplierIdRaw
        : int.tryParse((supplierIdRaw ?? '').toString());
    if (supplierId != null) {
      _supplierLinkMode = 'existing';
      _selectedSupplier = {
        'id': supplierId,
        'name': office['supplier_name'] ?? '',
        'phone': office['phone'] ?? '',
      };
    }

    // Try to preload current gold safe choice (might be set on supplier default)
    final rawSafeBoxId = office['supplier_default_safe_box_id'];
    final safeId = rawSafeBoxId is int
        ? rawSafeBoxId
        : int.tryParse((rawSafeBoxId ?? '').toString());
    if (safeId != null) {
      _goldSafeLinkMode = 'existing';
      _selectedGoldSafe = SafeBoxModel(
        id: safeId,
        name: (office['supplier_default_safe_box_name'] ?? '').toString(),
        safeType: 'gold',
        accountId: 0,
        isDefault: false,
        isActive: true,
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _contactPersonController.dispose();
    _addressLine1Controller.dispose();
    _addressLine2Controller.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _postalCodeController.dispose();
    _licenseNumberController.dispose();
    _taxNumberController.dispose();
    _notesController.dispose();
    _openingCashController.dispose();
    _openingGoldMainController.dispose();
    super.dispose();
  }

  int? _parseId(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  double _parseDoubleOrZero(String s) {
    final v = s.trim();
    if (v.isEmpty) return 0.0;
    return double.tryParse(v) ?? 0.0;
  }

  Future<void> _pickSupplier({required bool isAr}) async {
    if (_isLoadingSuppliers) return;
    if (_suppliers.isEmpty) {
      await _loadSuppliers();
      if (!mounted) return;
    }
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => PartyPickerDialog(
        title: isAr ? 'اختيار مورد' : 'Pick Supplier',
        items: _suppliers,
        selectedId: _parseId(_selectedSupplier?['id']),
        emptyText: isAr ? 'لا يوجد موردون' : 'No suppliers',
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _selectedSupplier = picked;
      });
    }
  }

  Future<void> _pickGoldSafeBox({required bool isAr}) async {
    if (_isLoadingGoldSafeBoxes) return;
    if (_goldSafeBoxes.isEmpty) {
      await _loadGoldSafeBoxes();
      if (!mounted) return;
    }
    final picked = await showDialog<SafeBoxModel>(
      context: context,
      builder: (context) => SafeBoxPickerDialog(
        safeBoxes: _goldSafeBoxes,
        selectedSafeBoxId: _selectedGoldSafe?.id,
        filterSafeType: 'gold',
        excludeGold: false,
      ),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _selectedGoldSafe = picked;
      });
    }
  }

  Future<void> _saveOffice() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_supplierLinkMode == 'existing' && _selectedSupplier == null) {
      _showMessage('الرجاء اختيار مورد', isError: true);
      return;
    }
    if (_supplierLinkMode == 'existing' && _goldSafeLinkMode == 'existing') {
      if (_selectedGoldSafe == null || _selectedGoldSafe!.id == null) {
        _showMessage('الرجاء اختيار خزنة ذهب', isError: true);
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      final openingCash = _parseDoubleOrZero(_openingCashController.text);
      final openingGoldMain = _parseDoubleOrZero(
        _openingGoldMainController.text,
      );

      final officeData = {
        'name': _nameController.text.trim(),
        'phone': _phoneController.text.trim(),
        'email': _emailController.text.trim(),
        'contact_person': _contactPersonController.text.trim(),
        'address_line_1': _addressLine1Controller.text.trim(),
        'address_line_2': _addressLine2Controller.text.trim(),
        'city': _cityController.text.trim(),
        'state': _stateController.text.trim(),
        'postal_code': _postalCodeController.text.trim(),
        'country': _country,
        'license_number': _licenseNumberController.text.trim(),
        'tax_number': _taxNumberController.text.trim(),
        'notes': _notesController.text.trim(),
        'active': _active,

        // Supplier linkage
        'supplier_link_mode': _supplierLinkMode,
        if (_supplierLinkMode == 'existing')
          'supplier_id': _parseId(_selectedSupplier?['id']),

        // Gold SafeBox linkage
        'gold_safe_link_mode': _supplierLinkMode == 'existing'
            ? _goldSafeLinkMode
            : 'new',
        if (_supplierLinkMode == 'existing' && _goldSafeLinkMode == 'existing')
          'gold_safe_box_id': _selectedGoldSafe?.id,

        // Opening balances (cash + gold main-karat equiv)
        if (_supplierLinkMode == 'new') ...{
          'opening_balance_cash': openingCash,
          'opening_balance_gold_main_karat': openingGoldMain,
        },
      };

      if (widget.office == null) {
        // إضافة جديد
        await widget.api.addOffice(officeData);
        _showMessage('تم إضافة المكتب بنجاح', isError: false);
      } else {
        // تعديل
        await widget.api.updateOffice(widget.office!['id'], officeData);
        _showMessage('تم تحديث المكتب بنجاح', isError: false);
      }

      Navigator.pop(context, true);
    } catch (e) {
      _showMessage('خطأ: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showMessage(String message, {required bool isError}) {
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    final isAr = widget.isArabic;
    final isEdit = widget.office != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEdit
              ? (isAr ? 'تعديل مكتب' : 'Edit Office')
              : (isAr ? 'إضافة مكتب جديد' : 'Add New Office'),
        ),
        backgroundColor: AppColors.darkGold,
        foregroundColor: Colors.white,
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
                    // معلومات أساسية
                    _buildSectionTitle(
                      isAr ? 'المعلومات الأساسية' : 'Basic Information',
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: '${isAr ? "اسم المكتب" : "Office Name"} *',
                        prefixIcon: const Icon(Icons.store),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return isAr
                              ? 'الرجاء إدخال اسم المكتب'
                              : 'Please enter office name';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    _buildSectionTitle(
                      isAr ? 'ربط المورد وخزنة الذهب' : 'Supplier & Gold Safe',
                    ),
                    const SizedBox(height: 12),

                    RadioListTile<String>(
                      value: 'new',
                      groupValue: _supplierLinkMode,
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _supplierLinkMode = v;
                          _selectedSupplier = null;
                          _goldSafeLinkMode = 'new';
                          _selectedGoldSafe = null;
                        });
                      },
                      title: Text(
                        isAr ? 'إنشاء مورد جديد' : 'Create new supplier',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<String>(
                      value: 'existing',
                      groupValue: _supplierLinkMode,
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _supplierLinkMode = v;
                          _goldSafeLinkMode = 'new';
                          _selectedGoldSafe = null;
                        });
                      },
                      title: Text(
                        isAr ? 'ربط بمورد موجود' : 'Link existing supplier',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 10),

                    if (_supplierLinkMode == 'existing') ...[
                      SearchablePickerField(
                        labelText: isAr ? 'المورد' : 'Supplier',
                        valueText: (_selectedSupplier?['name'] ?? '')
                            .toString(),
                        hintText: isAr
                            ? 'اضغط لاختيار مورد'
                            : 'Tap to pick supplier',
                        helperText: _isLoadingSuppliers
                            ? (isAr
                                  ? 'جارٍ تحميل الموردين...'
                                  : 'Loading suppliers...')
                            : null,
                        prefixIcon: Icons.person_search,
                        onTap: () => _pickSupplier(isAr: isAr),
                        enabled: !_isLoadingSuppliers,
                      ),
                      const SizedBox(height: 12),

                      RadioListTile<String>(
                        value: 'existing',
                        groupValue: _goldSafeLinkMode,
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _goldSafeLinkMode = v;
                          });
                        },
                        title: Text(
                          isAr
                              ? 'ربط بخزنة ذهب موجودة'
                              : 'Link existing gold safe',
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<String>(
                        value: 'new',
                        groupValue: _goldSafeLinkMode,
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _goldSafeLinkMode = v;
                            _selectedGoldSafe = null;
                          });
                        },
                        title: Text(
                          isAr
                              ? 'إنشاء خزنة ذهب جديدة لهذا المكتب'
                              : 'Create a new gold safe for this office',
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 8),

                      if (_goldSafeLinkMode == 'existing') ...[
                        SearchablePickerField(
                          labelText: isAr ? 'خزنة الذهب' : 'Gold SafeBox',
                          valueText: _selectedGoldSafe?.name,
                          hintText: isAr
                              ? 'اضغط لاختيار خزنة ذهب'
                              : 'Tap to pick gold safe',
                          helperText: _isLoadingGoldSafeBoxes
                              ? (isAr
                                    ? 'جارٍ تحميل خزائن الذهب...'
                                    : 'Loading gold safes...')
                              : null,
                          prefixIcon: Icons.currency_exchange,
                          onTap: () => _pickGoldSafeBox(isAr: isAr),
                          enabled: !_isLoadingGoldSafeBoxes,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ] else ...[
                      TextFormField(
                        controller: _openingCashController,
                        decoration: InputDecoration(
                          labelText: isAr
                              ? 'رصيد افتتاحي نقدي (${context.read<SettingsProvider>().currencySymbolText})'
                              : 'Opening cash balance (${context.read<SettingsProvider>().currencySymbolText})',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: false,
                        ),
                        inputFormatters: [NormalizeNumberFormatter()],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _openingGoldMainController,
                        decoration: InputDecoration(
                          labelText: isAr
                              ? 'رصيد افتتاحي ذهب (جرام مكافئ العيار الرئيسي)'
                              : 'Opening gold (g, main-karat equiv)',
                          prefixIcon: const Icon(Icons.scale_outlined),
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: false,
                        ),
                        inputFormatters: [NormalizeNumberFormatter()],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        isAr
                            ? 'سيتم إنشاء خزنة ذهب تلقائياً وربطها بالمورد.'
                            : 'A gold safe will be auto-created and linked.',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: isAr ? TextAlign.right : TextAlign.left,
                      ),
                      const SizedBox(height: 12),
                    ],

                    TextFormField(
                      controller: _phoneController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'رقم الهاتف' : 'Phone Number',
                        prefixIcon: const Icon(Icons.phone),
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'البريد الإلكتروني' : 'Email',
                        prefixIcon: const Icon(Icons.email),
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _contactPersonController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'الشخص المسؤول' : 'Contact Person',
                        prefixIcon: const Icon(Icons.person),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // العنوان
                    _buildSectionTitle(isAr ? 'العنوان' : 'Address'),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _addressLine1Controller,
                      decoration: InputDecoration(
                        labelText: isAr ? 'العنوان - سطر 1' : 'Address Line 1',
                        prefixIcon: const Icon(Icons.location_on),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _addressLine2Controller,
                      decoration: InputDecoration(
                        labelText: isAr ? 'العنوان - سطر 2' : 'Address Line 2',
                        prefixIcon: const Icon(Icons.location_on_outlined),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _cityController,
                            decoration: InputDecoration(
                              labelText: isAr ? 'المدينة' : 'City',
                              prefixIcon: const Icon(Icons.location_city),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _stateController,
                            decoration: InputDecoration(
                              labelText: isAr ? 'المنطقة' : 'State/Region',
                              prefixIcon: const Icon(Icons.map),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _postalCodeController,
                            decoration: InputDecoration(
                              labelText: isAr ? 'الرمز البريدي' : 'Postal Code',
                              prefixIcon: const Icon(Icons.markunread_mailbox),
                              border: const OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            inputFormatters: [NormalizeNumberFormatter()],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _country,
                            decoration: InputDecoration(
                              labelText: isAr ? 'الدولة' : 'Country',
                              prefixIcon: const Icon(Icons.public),
                              border: const OutlineInputBorder(),
                            ),
                            items:
                                [
                                  'Saudi Arabia',
                                  'UAE',
                                  'Kuwait',
                                  'Bahrain',
                                  'Qatar',
                                  'Oman',
                                ].map((country) {
                                  return DropdownMenuItem(
                                    value: country,
                                    child: Text(country),
                                  );
                                }).toList(),
                            onChanged: (value) {
                              setState(() => _country = value!);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // معلومات رسمية
                    _buildSectionTitle(
                      isAr ? 'المعلومات الرسمية' : 'Official Information',
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _licenseNumberController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'رقم الترخيص' : 'License Number',
                        prefixIcon: const Icon(Icons.badge),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _taxNumberController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'الرقم الضريبي' : 'Tax Number',
                        prefixIcon: const Icon(Icons.receipt_long),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ملاحظات
                    _buildSectionTitle(isAr ? 'ملاحظات' : 'Notes'),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _notesController,
                      decoration: InputDecoration(
                        labelText: isAr ? 'ملاحظات إضافية' : 'Additional Notes',
                        prefixIcon: const Icon(Icons.note),
                        border: const OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 24),

                    // الحالة
                    if (isEdit)
                      SwitchListTile(
                        title: Text(isAr ? 'مكتب نشط' : 'Active Office'),
                        subtitle: Text(
                          isAr ? 'تفعيل/تعطيل المكتب' : 'Enable/Disable office',
                        ),
                        value: _active,
                        onChanged: (value) {
                          setState(() => _active = value);
                        },
                        activeThumbColor: AppColors.primaryGold,
                      ),
                    const SizedBox(height: 24),

                    // زر الحفظ
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : _saveOffice,
                      icon: const Icon(Icons.save),
                      label: Text(
                        isEdit
                            ? (isAr ? 'حفظ التعديلات' : 'Save Changes')
                            : (isAr ? 'إضافة المكتب' : 'Add Office'),
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

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: AppColors.darkGold,
      ),
    );
  }
}
