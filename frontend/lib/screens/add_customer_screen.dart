import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../utils.dart';

class AddCustomerScreen extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? customer; // Make customer optional
  final bool isArabic;
  final bool enforceIdentityFields;
  final ValueChanged<Map<String, dynamic>>? onCustomerSaved;

  const AddCustomerScreen({
    super.key,
    required this.api,
    this.customer, // Receive customer data for editing
    this.isArabic = true,
    this.enforceIdentityFields = false,
    this.onCustomerSaved,
  });

  @override
  State<AddCustomerScreen> createState() => _AddCustomerScreenState();
}

class _ResponsiveField {
  const _ResponsiveField({required this.child, this.fullWidth = false});

  final Widget child;
  final bool fullWidth;
}

class _AddCustomerPalette {
  const _AddCustomerPalette({
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

  factory _AddCustomerPalette.resolve(bool isDark) {
    if (isDark) {
      return const _AddCustomerPalette(
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

    return const _AddCustomerPalette(
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

class _AddCustomerScreenState extends State<AddCustomerScreen> {
  final _formKey = GlobalKey<FormState>();
  late _AddCustomerPalette _palette;
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

  bool _ensureAccounts = true;

  String? _nextCustomerCode;
  int? _remainingCapacity;

  @override
  void initState() {
    super.initState();
    final customer = widget.customer;

    _ensureAccounts = true;

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

  bool _validateIdentityFieldsIfNeeded() {
    if (!widget.enforceIdentityFields) {
      return true;
    }

    final missingFields = <String>[];
    if (idController.text.trim().isEmpty) {
      missingFields.add(widget.isArabic ? 'رقم الهوية' : 'ID Number');
    }
    if (idVersionNumberController.text.trim().isEmpty) {
      missingFields.add(
        widget.isArabic ? 'رقم نسخة الهوية' : 'ID Version Number',
      );
    }
    if (birthDateController.text.trim().isEmpty) {
      missingFields.add(widget.isArabic ? 'تاريخ الميلاد' : 'Birth Date');
    }

    if (missingFields.isEmpty) {
      return true;
    }

    final message = widget.isArabic
        ? 'الحقول التالية مطلوبة:\n${missingFields.join('، ')}'
        : 'Please fill the following fields:\n${missingFields.join(', ')}';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.orange),
    );
    return false;
  }

  Future<void> _submitForm() async {
    if (_formKey.currentState!.validate()) {
      if (!_validateIdentityFieldsIfNeeded()) {
        return;
      }
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
        'ensure_accounts': _ensureAccounts,
      };

      try {
        late final Map<String, dynamic> savedCustomer;
        if (_isEditMode) {
          await widget.api.updateCustomer(widget.customer!['id'], customerData);
          savedCustomer = {
            ...?widget.customer,
            ...customerData,
            'id': widget.customer!['id'],
          };
        } else {
          savedCustomer = await widget.api.addCustomer(customerData);
        }

        if (!mounted) return;

        widget.onCustomerSaved?.call(savedCustomer);

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

  Widget _buildHeroBanner(
    BuildContext context,
    bool isAr,
    Color primary,
    _AddCustomerPalette palette,
  ) {
    final title = _isEditMode
        ? (isAr ? 'تحديث ملف العميل' : 'Update customer profile')
        : (isAr ? 'عميل جديد جاهز' : 'New customer ready');
    final subtitle = _isEditMode
        ? (isAr
              ? 'يمكنك تعديل أي معلومة وسيتم حفظ التغييرات فوراً بعد التحديث.'
              : 'Adjust any detail and we will save it right away after you submit.')
        : (isAr
              ? 'أدخل بيانات العميل بدقة لربط المعاملات والحسابات بشكل صحيح.'
              : 'Fill the customer profile carefully to link future transactions.');

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
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Chip(
                avatar: Icon(
                  Icons.verified,
                  color: palette.isDark ? Colors.white : palette.primaryText,
                  size: 18,
                ),
                label: Text(
                  _isEditMode
                      ? (isAr ? 'وضع التعديل' : 'Edit mode')
                      : (isAr ? 'وضع الإضافة' : 'Create mode'),
                ),
                labelStyle: TextStyle(
                  color: palette.isDark ? Colors.white : palette.primaryText,
                ),
                backgroundColor: palette.chipOverlay,
              ),
              Chip(
                avatar: Icon(
                  Icons.schedule,
                  color: palette.isDark ? Colors.white : palette.primaryText,
                  size: 18,
                ),
                label: Text(
                  isAr
                      ? 'آخر تحديث ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}'
                      : 'Updated ${TimeOfDay.now().format(context)}',
                ),
                labelStyle: TextStyle(
                  color: palette.isDark ? Colors.white : palette.primaryText,
                ),
                backgroundColor: palette.chipOverlay,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNextCodeCard(
    bool isAr,
    Color primary,
    _AddCustomerPalette palette,
  ) {
    return Card(
      elevation: 0,
      color: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: primary.withValues(
                    alpha: palette.isDark ? 0.2 : 0.15,
                  ),
                  child: Icon(Icons.tag, color: palette.primaryText),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isAr ? 'الكود التالي للعميل' : 'Next customer code',
                        style: TextStyle(
                          color: palette.primaryText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _nextCustomerCode ?? '--',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: palette.primaryText,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ],
                  ),
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
                    style: TextStyle(color: palette.primaryText),
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
    required String titleAr,
    required String titleEn,
    required List<_ResponsiveField> fields,
    required _AddCustomerPalette palette,
  }) {
    final isAr = widget.isArabic;

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
                  isAr ? titleAr : titleEn,
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

  Widget _buildActionRow(
    Color primary,
    bool isAr,
    _AddCustomerPalette palette,
  ) {
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
            onPressed: () => Navigator.pop(context),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
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
            onPressed: _submitForm,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(isAr ? 'حفظ بيانات العميل' : 'Save customer'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final primary = const Color(0xFFD4AF37);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = _AddCustomerPalette.resolve(isDark);
    _palette = palette;
    final background = palette.background;
    final accent = palette.primaryText;

    final title = _isEditMode
        ? (isAr ? 'تحديث بيانات العميل' : 'Update Customer')
        : (isAr ? 'عميل جديد' : 'New Customer');

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          elevation: 0,
          backgroundColor: background,
          foregroundColor: accent,
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
          child: _isLoading
              ? Center(child: CircularProgressIndicator(color: primary))
              : Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeroBanner(context, isAr, primary, palette),
                        const SizedBox(height: 16),
                        if (!_isEditMode && _nextCustomerCode != null)
                          _buildNextCodeCard(isAr, primary, palette),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.person_outline,
                          titleAr: 'البيانات الأساسية',
                          titleEn: 'Basic Information',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: nameController,
                                label: isAr ? 'اسم العميل' : 'Customer Name',
                                hint: AutofillHints.name,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: phoneController,
                                label: isAr ? 'رقم الهاتف' : 'Phone Number',
                                hint: AutofillHints.telephoneNumber,
                                isNumeric: true,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: emailController,
                                label: isAr ? 'البريد الإلكتروني' : 'Email',
                                hint: AutofillHints.email,
                                keyboardType: TextInputType.emailAddress,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.verified_user_outlined,
                          titleAr: 'بيانات الهوية',
                          titleEn: 'Identity Details',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: idController,
                                label: isAr ? 'رقم الهوية' : 'ID Number',
                                isNumeric: true,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: birthDateController,
                                label: isAr ? 'تاريخ الميلاد' : 'Birth Date',
                                readOnly: true,
                                onTap: _selectDate,
                                suffixIcon: Icon(
                                  Icons.calendar_today,
                                  color: primary,
                                ),
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: idVersionNumberController,
                                label: isAr
                                    ? 'رقم نسخة الهوية'
                                    : 'ID Version Number',
                                isNumeric: true,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.location_on_outlined,
                          titleAr: 'العنوان والاتصال',
                          titleEn: 'Address & Location',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: streetController,
                                label: isAr ? 'الشارع' : 'Street',
                                hint: AutofillHints.streetAddressLine1,
                                margin: EdgeInsets.zero,
                              ),
                              fullWidth: true,
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: buildingController,
                                label: isAr ? 'المبنى' : 'Building',
                                hint: AutofillHints.streetAddressLine2,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: districtController,
                                label: isAr ? 'الحي' : 'District',
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: cityController,
                                label: isAr ? 'المدينة' : 'City',
                                hint: AutofillHints.addressCity,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: postalController,
                                label: isAr ? 'الرمز البريدي' : 'Postal Code',
                                hint: AutofillHints.postalCode,
                                isNumeric: true,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: countryController,
                                label: isAr ? 'الدولة' : 'Country',
                                hint: AutofillHints.countryName,
                                margin: EdgeInsets.zero,
                              ),
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.account_balance_outlined,
                          titleAr: 'الربط المحاسبي',
                          titleEn: 'Accounting Link',
                          fields: [
                            _ResponsiveField(
                              child: SwitchListTile.adaptive(
                                value: _ensureAccounts,
                                onChanged: (value) {
                                  setState(() {
                                    _ensureAccounts = value;
                                  });
                                },
                                contentPadding: EdgeInsets.zero,
                                activeColor: primary,
                                title: Text(
                                  isAr
                                      ? 'إنشاء/ربط الحسابات تلقائياً'
                                      : 'Auto-create/link accounts',
                                  style: TextStyle(
                                    color: palette.primaryText,
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  isAr
                                      ? 'ينشئ حساب مالي وحساب مذكرة وزني (أرصدة ذهب العميل) لضمان القيود الوزنية الصحيحة.'
                                      : 'Creates a financial account + a weight memo account (customer gold balances) for correct weight postings.',
                                  style: TextStyle(
                                    color: palette.secondaryText,
                                    fontFamily: 'Cairo',
                                  ),
                                ),
                              ),
                              fullWidth: true,
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 16),
                        _buildSectionCard(
                          icon: Icons.notes_outlined,
                          titleAr: 'ملاحظات إضافية',
                          titleEn: 'Additional Notes',
                          fields: [
                            _ResponsiveField(
                              child: _buildTextFormField(
                                controller: notesController,
                                label: isAr ? 'ملاحظات' : 'Notes',
                                maxLines: 4,
                                margin: EdgeInsets.zero,
                              ),
                              fullWidth: true,
                            ),
                          ],
                          palette: palette,
                        ),
                        const SizedBox(height: 24),
                        _buildActionRow(primary, isAr, palette),
                      ],
                    ),
                  ),
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
    EdgeInsetsGeometry margin = const EdgeInsets.symmetric(vertical: 8.0),
  }) {
    const primary = Color(0xFFD4AF37);
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: _palette.outline, width: 1.2),
    );

    return Padding(
      padding: margin,
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        onTap: onTap,
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
          suffixIcon: suffixIcon,
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
