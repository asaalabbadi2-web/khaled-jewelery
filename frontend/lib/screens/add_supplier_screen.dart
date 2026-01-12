import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../utils.dart';

class AddSupplierScreen extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? supplier;
  final bool isArabic;
  final ValueChanged<Map<String, dynamic>>? onSupplierSaved;

  const AddSupplierScreen({
    super.key,
    required this.api,
    this.supplier,
    this.isArabic = true,
    this.onSupplierSaved,
  });

  @override
  State<AddSupplierScreen> createState() => _AddSupplierScreenState();
}

class _ResponsiveField {
  const _ResponsiveField({required this.child, this.fullWidth = false});

  final Widget child;
  final bool fullWidth;
}

class _AddSupplierPalette {
  const _AddSupplierPalette({
    required this.isDark,
    required this.background,
    required this.surface,
    required this.surfaceMuted,
    required this.heroBase,
    required this.primaryText,
    required this.secondaryText,
    required this.outline,
    required this.fieldFill,
    required this.fieldText,
    required this.fieldLabel,
    required this.chipOverlay,
    required this.actionOutline,
  });

  final bool isDark;
  final Color background;
  final Color surface;
  final Color surfaceMuted;
  final Color heroBase;
  final Color primaryText;
  final Color secondaryText;
  final Color outline;
  final Color fieldFill;
  final Color fieldText;
  final Color fieldLabel;
  final Color chipOverlay;
  final Color actionOutline;

  factory _AddSupplierPalette.resolve(bool isDark) {
    if (isDark) {
      return const _AddSupplierPalette(
        isDark: true,
        background: Color(0xFF0E0F13),
        surface: Color(0xFF161B22),
        surfaceMuted: Color(0xFF1F2430),
        heroBase: Color(0xFF111827),
        primaryText: Color(0xFFF5F7FB),
        secondaryText: Color(0xFFB5C1D3),
        outline: Color(0xFF2A303B),
        fieldFill: Color(0xFF1F2530),
        fieldText: Colors.white,
        fieldLabel: Color(0xFFB5C1D3),
        chipOverlay: Color(0x33FFFFFF),
        actionOutline: Color(0x4DFFFFFF),
      );
    }

    return const _AddSupplierPalette(
      isDark: false,
      background: Color(0xFFF4F1EA),
      surface: Color(0xFFFFFFFF),
      surfaceMuted: Color(0xFFF8F6F0),
      heroBase: Color(0xFF1F2A37),
      primaryText: Color(0xFF1F2A37),
      secondaryText: Color(0xFF6B7280),
      outline: Color(0xFFE0D3B8),
      fieldFill: Color(0xFFFFFFFF),
      fieldText: Color(0xFF1F2A37),
      fieldLabel: Color(0xFF6B7280),
      chipOverlay: Color(0x1AFFFFFF),
      actionOutline: Color(0x33212532),
    );
  }
}

class _AddSupplierScreenState extends State<AddSupplierScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _emailController;
  late TextEditingController _taxNumberController;
  late TextEditingController _classificationController;
  late TextEditingController _addressLine1Controller;
  late TextEditingController _addressLine2Controller;
  late TextEditingController _cityController;
  late TextEditingController _stateController;
  late TextEditingController _postalCodeController;
  late TextEditingController _countryController;
  late _AddSupplierPalette _palette;

  bool _isSaving = false;

  String _defaultWageType = 'cash';

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
    _taxNumberController = TextEditingController(
      text: (widget.supplier?['tax_number'] ?? '').toString(),
    );
    _classificationController = TextEditingController(
      text: (widget.supplier?['classification'] ?? '').toString(),
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

    final rawWageType = widget.supplier?['default_wage_type'];
    final normalized = (rawWageType ?? 'cash').toString().trim().toLowerCase();
    _defaultWageType = normalized == 'gold' ? 'gold' : 'cash';

    if (!_isEditMode) {
      _loadNextSupplierCode();
    }
  }

  Future<void> _loadNextSupplierCode() async {
    try {
      final data = await widget.api.getNextSupplierCode();
      if (!mounted) return;
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
    _taxNumberController.dispose();
    _classificationController.dispose();
    _addressLine1Controller.dispose();
    _addressLine2Controller.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _postalCodeController.dispose();
    _countryController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);

    final data = {
      'name': _nameController.text.trim(),
      'phone': normalizeNumber(_phoneController.text),
      'email': _emailController.text.trim(),
      'tax_number': _taxNumberController.text.trim().isEmpty
          ? null
          : _taxNumberController.text.trim(),
      'classification': _classificationController.text.trim().isEmpty
          ? null
          : _classificationController.text.trim(),
      'address_line_1': _addressLine1Controller.text.trim(),
      'address_line_2': _addressLine2Controller.text.trim(),
      'city': _cityController.text.trim(),
      'state': _stateController.text.trim(),
      'postal_code': _postalCodeController.text.trim(),
      'country': _countryController.text.trim(),
      'default_wage_type': _defaultWageType,
    };

    try {
      late final Map<String, dynamic> savedSupplier;
      if (_isEditMode) {
        await widget.api.updateSupplier(widget.supplier!['id'], data);
        savedSupplier = {
          ...?widget.supplier,
          ...data,
          'id': widget.supplier!['id'],
        };
      } else {
        savedSupplier = await widget.api.addSupplier(data);
      }

      widget.onSupplierSaved?.call(savedSupplier);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isEditMode
                ? (widget.isArabic
                      ? 'تم تحديث بيانات المورد'
                      : 'Supplier updated')
                : (widget.isArabic ? 'تم إضافة المورد' : 'Supplier added'),
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? 'حدث خطأ أثناء الحفظ: $e'
                : 'Failed to save supplier: $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildHeroBanner(Color primary, _AddSupplierPalette palette) {
    final isAr = widget.isArabic;
    final title = _isEditMode
        ? (isAr ? 'تحديث ملف المورد' : 'Update supplier profile')
        : (isAr ? 'مورد جديد جاهز' : 'New supplier ready');
    final subtitle = _isEditMode
        ? (isAr
              ? 'يمكنك تعديل بيانات المورد وسيتم حفظها بعد التحديث.'
              : 'Adjust any supplier detail and it will be saved once you confirm.')
        : (isAr
              ? 'أدخل بيانات المورد بدقة لربط الفواتير والحركات لاحقاً.'
              : 'Fill the supplier profile carefully to link future purchases.');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.heroBase,
            palette.heroBase.withValues(alpha: palette.isDark ? 0.95 : 0.9),
            primary.withValues(alpha: palette.isDark ? 0.85 : 0.8),
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(
                  Icons.verified,
                  color: palette.primaryText,
                  size: 18,
                ),
                label: Text(
                  _isEditMode
                      ? (isAr ? 'وضع التعديل' : 'Edit mode')
                      : (isAr ? 'وضع الإضافة' : 'Create mode'),
                ),
                labelStyle: TextStyle(color: palette.primaryText),
                backgroundColor: palette.chipOverlay,
              ),
              Chip(
                avatar: Icon(
                  Icons.schedule,
                  color: palette.primaryText,
                  size: 18,
                ),
                label: Text(
                  isAr
                      ? 'آخر تحديث ${TimeOfDay.now().format(context)}'
                      : 'Updated ${TimeOfDay.now().format(context)}',
                ),
                labelStyle: TextStyle(color: palette.primaryText),
                backgroundColor: palette.chipOverlay,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNextCodeCard(Color primary, _AddSupplierPalette palette) {
    if (_nextSupplierCode == null) {
      return const SizedBox.shrink();
    }

    final isAr = widget.isArabic;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      color: palette.surface,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.local_offer_outlined, color: primary),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAr ? 'الكود التالي للمورد' : 'Next supplier code',
                      style: TextStyle(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _nextSupplierCode ?? '--',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: primary,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (_remainingCapacity != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.storage_rounded,
                    color: palette.secondaryText,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isAr
                        ? 'السعة المتبقية: ${_remainingCapacity!.toStringAsFixed(0)} ملف'
                        : 'Remaining capacity: ${_remainingCapacity!.toStringAsFixed(0)} profiles',
                    style: TextStyle(color: palette.secondaryText),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required String title,
    required List<_ResponsiveField> fields,
    required _AddSupplierPalette palette,
  }) {
    return Card(
      elevation: 0,
      color: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: palette.primaryText),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: TextStyle(
                    color: palette.primaryText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 640;
                final double dualWidth = (constraints.maxWidth - 16) / 2;
                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: fields.map((field) {
                    final width = field.fullWidth || !isWide
                        ? constraints.maxWidth
                        : dualWidth;
                    return SizedBox(width: width, child: field.child);
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextFormField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool isNumeric = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    const primary = Color(0xFFD4AF37);
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: _palette.outline, width: 1.2),
    );

    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: isNumeric ? TextInputType.number : keyboardType,
      autofillHints: hint != null ? [hint] : null,
      inputFormatters: isNumeric
          ? [NormalizeNumberFormatter(), FilteringTextInputFormatter.digitsOnly]
          : [NormalizeNumberFormatter()],
      validator: (value) {
        if (controller == _nameController && (value == null || value.isEmpty)) {
          return 'الرجاء إدخال اسم المورد';
        }
        return null;
      },
      style: TextStyle(
        color: _palette.fieldText,
        fontFamily: 'Cairo',
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: _palette.isDark ? _palette.fieldLabel : _palette.primaryText,
        ),
        filled: true,
        fillColor: _palette.fieldFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: baseBorder,
        enabledBorder: baseBorder,
        focusedBorder: baseBorder.copyWith(
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
        errorBorder: baseBorder.copyWith(
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: baseBorder.copyWith(
          borderSide: const BorderSide(color: Colors.redAccent, width: 1.6),
        ),
        hintStyle: TextStyle(color: _palette.secondaryText),
      ),
    );
  }

  Widget _buildActionRow(Color primary, _AddSupplierPalette palette) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.primaryText,
              side: BorderSide(color: palette.actionOutline, width: 1.2),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _isSaving ? null : () => Navigator.pop(context),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _isSaving ? null : _submit,
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
            label: Text(
              _isEditMode
                  ? (widget.isArabic
                        ? 'تحديث بيانات المورد'
                        : 'Update supplier')
                  : (widget.isArabic ? 'حفظ بيانات المورد' : 'Save supplier'),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = const Color(0xFFD4AF37);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = _AddSupplierPalette.resolve(isDark);
    _palette = palette;

    final title = _isEditMode
        ? (widget.isArabic ? 'تعديل بيانات المورد' : 'Edit supplier')
        : (widget.isArabic ? 'مورد جديد' : 'New supplier');

    return Directionality(
      textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: palette.background,
        appBar: AppBar(
          elevation: 0,
          backgroundColor: palette.background,
          foregroundColor: palette.primaryText,
          iconTheme: IconThemeData(color: palette.primaryText),
          titleSpacing: 0,
          title: Text(
            title,
            style: TextStyle(
              color: palette.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: SafeArea(
          child: _isSaving && !_isEditMode
              ? Center(child: CircularProgressIndicator(color: primary))
              : Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeroBanner(primary, palette),
                        const SizedBox(height: 16),
                        if (!_isEditMode && _nextSupplierCode != null)
                          _buildNextCodeCard(primary, palette),
                        if (!_isEditMode && _nextSupplierCode != null)
                          const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.storefront_outlined,
                          title: widget.isArabic
                              ? 'البيانات الأساسية'
                              : 'Basic info',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _nameController,
                                label: widget.isArabic
                                    ? 'اسم المورد'
                                    : 'Supplier name',
                                hint: AutofillHints.name,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _phoneController,
                                label: widget.isArabic
                                    ? 'رقم الهاتف'
                                    : 'Phone number',
                                hint: AutofillHints.telephoneNumber,
                                isNumeric: true,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _emailController,
                                label: widget.isArabic
                                    ? 'البريد الإلكتروني'
                                    : 'Email',
                                hint: AutofillHints.email,
                                keyboardType: TextInputType.emailAddress,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _taxNumberController,
                                label: widget.isArabic
                                    ? 'الرقم الضريبي'
                                    : 'Tax number',
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _classificationController,
                                label: widget.isArabic
                                    ? 'التصنيف'
                                    : 'Classification',
                              ),
                            ),
                            _ResponsiveField(
                              child: DropdownButtonFormField<String>(
                                initialValue: _defaultWageType,
                                decoration: InputDecoration(
                                  labelText: widget.isArabic
                                      ? 'نوع أجور المصنعية الافتراضي'
                                      : 'Default wage type',
                                  border: const OutlineInputBorder(),
                                ),
                                items: [
                                  DropdownMenuItem<String>(
                                    value: 'cash',
                                    child: Text(
                                      widget.isArabic ? 'نقد (ريال)' : 'Cash',
                                    ),
                                  ),
                                  DropdownMenuItem<String>(
                                    value: 'gold',
                                    child: Text(
                                      widget.isArabic ? 'ذهب (وزن)' : 'Gold',
                                    ),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _defaultWageType = value);
                                },
                              ),
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.location_on_outlined,
                          title: widget.isArabic
                              ? 'العنوان وبيانات الاتصال'
                              : 'Address & contact',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _addressLine1Controller,
                                label: widget.isArabic
                                    ? 'العنوان - السطر ١'
                                    : 'Address line 1',
                                hint: AutofillHints.streetAddressLine1,
                              ),
                              fullWidth: true,
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _addressLine2Controller,
                                label: widget.isArabic
                                    ? 'العنوان - السطر ٢'
                                    : 'Address line 2',
                                hint: AutofillHints.streetAddressLine2,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _cityController,
                                label: widget.isArabic ? 'المدينة' : 'City',
                                hint: AutofillHints.addressCity,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _stateController,
                                label: widget.isArabic
                                    ? 'المنطقة / المحافظة'
                                    : 'State / Province',
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _postalCodeController,
                                label: widget.isArabic
                                    ? 'الرمز البريدي'
                                    : 'Postal code',
                                hint: AutofillHints.postalCode,
                                isNumeric: true,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: _countryController,
                                label: widget.isArabic ? 'الدولة' : 'Country',
                                hint: AutofillHints.countryName,
                              ),
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 24),
                        _buildActionRow(primary, palette),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
