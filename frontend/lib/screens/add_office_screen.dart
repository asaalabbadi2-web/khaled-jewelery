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
import '../widgets/app_leave_guard.dart';

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

  // Whose an opening balance is (journey release 4): +1 ours with the office,
  // -1 owed to it. Asked whenever an amount is typed -- the form took no sign,
  // so an opening owed to the office could not be said at all.
  int? _cashSide;
  int? _goldSide;

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
        // An office's gold safe is its deposit, ours (ADR-052): a safe on a
        // supplier's account is refused by the server, so it is not offered.
        _goldSafeBoxes = boxes
            .where((sb) => sb.stockLocation == 'deposit')
            .toList();

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

    final cashAmount = _parseDoubleOrZero(_openingCashController.text);
    final goldAmount = _parseDoubleOrZero(_openingGoldMainController.text);
    if (_supplierLinkMode == 'new' &&
        ((cashAmount > 0 && _cashSide == null) ||
            (goldAmount > 0 && _goldSide == null))) {
      _showMessage('حدّد لكل رصيد افتتاحي: لنا عنده أم علينا له', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final openingCash = cashAmount * (_cashSide ?? 1);
      final openingGoldMain = goldAmount * (_goldSide ?? 1);

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

  /// Asks before what was typed is lost (ADR-049).
  @override
  Widget build(BuildContext context) => AppLeaveGuard(
    controllers: [_openingCashController, _openingGoldMainController, _nameController, _phoneController, _emailController, _contactPersonController, _addressLine1Controller, _addressLine2Controller, _cityController, _stateController, _postalCodeController, _licenseNumberController, _taxNumberController, _notesController],
    child: _buildForm(context),
  );

  Widget _section(String title, IconData icon, List<Widget> children) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpace.sm),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    String? Function(String?)? validator,
    int maxLines = 1,
    bool number = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
        keyboardType: keyboard,
        validator: validator,
        maxLines: maxLines,
        inputFormatters: number ? [NormalizeNumberFormatter()] : null,
      ),
    );
  }

  /// An amount and whose it is: ours with the office, or owed to it.
  Widget _opening({
    required Key sideKey,
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required int? side,
    required ValueChanged<int> onSide,
    required bool isAr,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: controller,
            decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [NormalizeNumberFormatter()],
          ),
          const SizedBox(height: AppSpace.sm),
          SegmentedButton<int>(
            key: sideKey,
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 1, label: Text(isAr ? 'لنا عنده' : 'Ours with it')),
              ButtonSegment(value: -1, label: Text(isAr ? 'علينا له' : 'Owed to it')),
            ],
            selected: {if (side != null) side},
            onSelectionChanged: (v) {
              if (v.isNotEmpty) setState(() => onSide(v.first));
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _officeFields(bool isAr, bool isEdit) => [
    _field(
      _nameController,
      '${isAr ? "اسم المكتب" : "Office Name"} *',
      Icons.store_outlined,
      validator: (value) => value == null || value.trim().isEmpty
          ? (isAr ? 'الرجاء إدخال اسم المكتب' : 'Please enter office name')
          : null,
    ),
    _field(_phoneController, isAr ? 'رقم الهاتف' : 'Phone Number', Icons.phone_outlined,
        keyboard: TextInputType.phone),
    _field(_contactPersonController, isAr ? 'الشخص المسؤول' : 'Contact Person', Icons.person_outline),
    _field(_emailController, isAr ? 'البريد الإلكتروني' : 'Email', Icons.email_outlined,
        keyboard: TextInputType.emailAddress),
    if (isEdit)
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(isAr ? 'مكتب نشط' : 'Active Office'),
        subtitle: Text(isAr ? 'المكتب المعطّل لا يُحجز منه' : 'An inactive office takes no reservation'),
        value: _active,
        onChanged: (value) => setState(() => _active = value),
      ),
  ];

  List<Widget> _accountFields(bool isAr) {
    final theme = Theme.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    return [
      SegmentedButton<String>(
        key: const Key('office-supplier-mode'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 'new', label: Text(isAr ? 'مورد جديد باسم المكتب' : 'New supplier')),
          ButtonSegment(value: 'existing', label: Text(isAr ? 'ربط بمورد موجود' : 'Existing supplier')),
        ],
        selected: {_supplierLinkMode},
        onSelectionChanged: (v) => setState(() {
          _supplierLinkMode = v.first;
          if (_supplierLinkMode == 'new') _selectedSupplier = null;
          _goldSafeLinkMode = 'new';
          _selectedGoldSafe = null;
        }),
      ),
      const SizedBox(height: AppSpace.md),
      if (_supplierLinkMode == 'existing') ...[
        SearchablePickerField(
          labelText: isAr ? 'المورد' : 'Supplier',
          valueText: (_selectedSupplier?['name'] ?? '').toString(),
          hintText: isAr ? 'اضغط لاختيار مورد' : 'Tap to pick supplier',
          helperText: _isLoadingSuppliers ? (isAr ? 'جارٍ تحميل الموردين...' : 'Loading suppliers...') : null,
          prefixIcon: Icons.person_search,
          onTap: () => _pickSupplier(isAr: isAr),
          enabled: !_isLoadingSuppliers,
        ),
        const SizedBox(height: AppSpace.md),
        SegmentedButton<String>(
          key: const Key('office-deposit-mode'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'new', label: Text(isAr ? 'وديعة جديدة' : 'New deposit')),
            ButtonSegment(value: 'existing', label: Text(isAr ? 'وديعة موجودة' : 'Existing deposit')),
          ],
          selected: {_goldSafeLinkMode},
          onSelectionChanged: (v) => setState(() {
            _goldSafeLinkMode = v.first;
            if (_goldSafeLinkMode == 'new') _selectedGoldSafe = null;
          }),
        ),
        const SizedBox(height: AppSpace.md),
        if (_goldSafeLinkMode == 'existing')
          SearchablePickerField(
            labelText: isAr ? 'وديعة الذهب' : 'Gold deposit',
            valueText: _selectedGoldSafe?.name,
            hintText: isAr ? 'اضغط لاختيار وديعة ذهب' : 'Tap to pick a gold deposit',
            helperText: _isLoadingGoldSafeBoxes ? (isAr ? 'جارٍ تحميل الودائع...' : 'Loading deposits...') : null,
            prefixIcon: Icons.savings_outlined,
            onTap: () => _pickGoldSafeBox(isAr: isAr),
            enabled: !_isLoadingGoldSafeBoxes,
          ),
      ] else ...[
        _opening(
          sideKey: const Key('office-opening-cash-side'),
          controller: _openingCashController,
          label: isAr ? 'رصيد افتتاحي نقدي ($currency)' : 'Opening cash balance ($currency)',
          icon: Icons.payments_outlined,
          side: _cashSide,
          onSide: (v) => _cashSide = v,
          isAr: isAr,
        ),
        _opening(
          sideKey: const Key('office-opening-gold-side'),
          controller: _openingGoldMainController,
          label: isAr ? 'رصيد افتتاحي ذهب (جرام مكافئ العيار الرئيسي)' : 'Opening gold (g, main-karat equiv)',
          icon: Icons.scale_outlined,
          side: _goldSide,
          onSide: (v) => _goldSide = v,
          isAr: isAr,
        ),
      ],
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              _supplierLinkMode == 'new'
                  ? (isAr
                        ? 'يُنشأ للمكتب مورد باسمه، ووديعة ذهب «ذهب مودع لدى …» تلقائيًّا. ذهبه الذي لنا يُحفظ فيها.'
                        : 'A supplier and a gold deposit are made for the office.')
                  : (isAr
                        ? 'الوديعة هي ذهبنا لدى المكتب، والمورد حسابه التجاري.'
                        : 'The deposit is our gold there; the supplier is its trade.'),
              key: const Key('office-account-note'),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _moreSection(bool isAr) {
    return Card(
      child: ExpansionTile(
        key: const Key('office-more'),
        leading: const Icon(Icons.location_on_outlined),
        title: Text(isAr ? 'العنوان والبيانات الرسمية' : 'Address and official details'),
        subtitle: Text(
          isAr ? 'العنوان والمدينة والترخيص والرقم الضريبي والملاحظات' : 'Address, licence, tax number, notes',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        children: [
          _field(_addressLine1Controller, isAr ? 'العنوان - سطر 1' : 'Address Line 1', Icons.location_on_outlined),
          _field(_addressLine2Controller, isAr ? 'العنوان - سطر 2' : 'Address Line 2', Icons.location_on_outlined),
          Row(
            children: [
              Expanded(child: _field(_cityController, isAr ? 'المدينة' : 'City', Icons.location_city_outlined)),
              const SizedBox(width: AppSpace.md),
              Expanded(child: _field(_stateController, isAr ? 'المنطقة' : 'State/Region', Icons.map_outlined)),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _field(_postalCodeController, isAr ? 'الرمز البريدي' : 'Postal Code',
                    Icons.markunread_mailbox_outlined, keyboard: TextInputType.number, number: true),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _country,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الدولة' : 'Country',
                    prefixIcon: const Icon(Icons.public),
                  ),
                  items: [for (final c in const ['Saudi Arabia', 'UAE', 'Kuwait', 'Bahrain', 'Qatar', 'Oman'])
                    DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (value) => setState(() => _country = value!),
                ),
              ),
            ],
          ),
          _field(_licenseNumberController, isAr ? 'رقم الترخيص' : 'License Number', Icons.badge_outlined),
          _field(_taxNumberController, isAr ? 'الرقم الضريبي' : 'Tax Number', Icons.receipt_long_outlined),
          _field(_notesController, isAr ? 'ملاحظات إضافية' : 'Additional Notes', Icons.note_outlined, maxLines: 3),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
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
      ),
      bottomNavigationBar: _isLoading
          ? null
          : Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      FilledButton.icon(
                        key: const Key('office-save'),
                        onPressed: _isLoading ? null : _saveOffice,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          isEdit
                              ? (isAr ? 'حفظ التعديلات' : 'Save Changes')
                              : (isAr ? 'إضافة المكتب' : 'Add Office'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: LayoutBuilder(
                builder: (context, c) {
                  final wide = c.maxWidth >= 900;
                  final office = _section(isAr ? 'المكتب' : 'Office', Icons.store_outlined, _officeFields(isAr, isEdit));
                  final account = _section(
                    isAr ? 'الحساب والذهب' : 'Account and gold',
                    Icons.account_balance_wallet_outlined,
                    _accountFields(isAr),
                  );
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (wide)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: office),
                                  const SizedBox(width: AppSpace.lg),
                                  Expanded(child: account),
                                ],
                              )
                            else ...[
                              office,
                              const SizedBox(height: AppSpace.md),
                              account,
                            ],
                            const SizedBox(height: AppSpace.md),
                            _moreSection(isAr),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
