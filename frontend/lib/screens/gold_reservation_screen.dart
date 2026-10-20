import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart';
import 'office_detail_screen.dart';
import 'weight_closing_settings_screen.dart';
import '../utils.dart';
import '../providers/settings_provider.dart';
import 'package:provider/provider.dart';
import '../widgets/app_feedback.dart';
import '../utils/currency_utils.dart';
import '../utils/bidi.dart';

/// شاشة التسكير - حجز ذهب خام من مكاتب بيع وشراء الذهب
class GoldReservationScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  /// The office it opens on -- from that office's «حجز جديد».
  final int? initialOfficeId;

  const GoldReservationScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.initialOfficeId,
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
  // The main karat until the server says it -- most reservations are in it
  // (the owner, 19 Oct 2026); 24 was a guess.
  int _selectedKarat = 21;
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
  List<SafeBoxModel> _cashBankSafeBoxes = const [];
  List<Map<String, dynamic>> _paymentMethods = []; // وسائل الدفع الفعالة
  int? _selectedPaymentMethodId;
  bool _isLoading = false;

  /// The office's price per gram by karat -- the server's sell price
  /// (prices_per_gram), not one computed here from the ounce and a written
  /// exchange rate. The price field follows the karat chosen.
  Map<int, double> _karatPrices = const {};
  int? _selectedSupplierId;

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _weightController.addListener(_onWeightChanged);
    _priceController.addListener(_onPriceChanged);
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
      final perGram = goldPriceResponse['prices_per_gram'];
      if (perGram is Map) {
        final prices = <int, double>{
          for (final e in perGram.entries)
            if (int.tryParse('${e.key}') != null &&
                e.value is Map &&
                (e.value as Map)['sell'] is num)
              int.parse('${e.key}'): ((e.value as Map)['sell'] as num)
                  .toDouble(),
        };
        final main = goldPriceResponse['main_karat'];
        setState(() {
          _karatPrices = prices;
          if (main is num && prices.containsKey(main.toInt())) {
            _selectedKarat = main.toInt();
          }
          _applyKaratPrice();
        });
      }

      // تحميل قائمة المكاتب والموردين من API
      final offices = await widget.api.getOffices(activeOnly: true);

      // تحميل خزائن الدفع (نقد/بنك) من API
      final safes = await widget.api.getSafeBoxes(
        isActive: true,
        includeAccount: true,
      );
      final cashBankSafes =
          safes
              .where(
                (s) =>
                    (s.safeType == 'cash' || s.safeType == 'bank') &&
                    s.id != null,
              )
              .toList()
            ..sort(
              (a, b) => a.safeType == b.safeType
                  ? a.name.compareTo(b.name)
                  : a.safeType.compareTo(b.safeType),
            );

      // تحميل وسائل الدفع الفعالة — الخزينة التي سيُقيَّد فيها العربون تُشتق
      // من وسيلة الدفع (default_safe_box_id) في الـbackend، وليست اختيارًا حرًا
      final paymentMethods = await widget.api.getActivePaymentMethods();

      setState(() {
        _offices = offices.cast<Map<String, dynamic>>();
        _cashBankSafeBoxes = cashBankSafes;
        _paymentMethods = paymentMethods.cast<Map<String, dynamic>>();
        if (widget.initialOfficeId != null && _selectedOfficeId == null) {
          _selectOffice(widget.initialOfficeId);
        }
      });
    } catch (e) {
      _showMessage('خطأ في تحميل البيانات: $e', isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _safeNameById(int? id) {
    if (id == null) return 'افتراضي (حسب الإعدادات)';
    final found = _cashBankSafeBoxes.where((s) => s.id == id).toList();
    if (found.isEmpty) return 'خزينة غير معروفة (#$id)';
    final sb = found.first;
    final typeLabel = sb.safeType == 'bank' ? 'بنك' : 'نقد';
    return '$typeLabel - ${sb.name}';
  }

  String _paymentMethodNameById(int? id) {
    if (id == null) return '';
    final found = _paymentMethods.where((m) => m['id'] == id).toList();
    return found.isEmpty ? '' : (found.first['name']?.toString() ?? '');
  }

  // الخزينة الفعلية التي سيُقيَّد فيها العربون — تُشتق من
  // PaymentMethod.default_safe_box_id في الـbackend (Phase 9C)، وتُعرض هنا
  // للشفافية فقط، وليست قابلة للاختيار مباشرة.
  int? get _resolvedSafeBoxId {
    if (_selectedPaymentMethodId == null) return null;
    final found = _paymentMethods
        .where((m) => m['id'] == _selectedPaymentMethodId)
        .toList();
    if (found.isEmpty) return null;
    final raw = found.first['default_safe_box_id'];
    if (raw == null) return null;
    return raw is int ? raw : int.tryParse(raw.toString());
  }

  /// The office chosen, and what goes with it: its supplier and contact.
  void _selectOffice(int? value) {
    final selectedOffice = _offices.firstWhere(
      (o) => o['id'] == value,
      orElse: () => <String, dynamic>{},
    );
    if (selectedOffice.isEmpty) return;
    _selectedOfficeId = value;
    _selectedOfficeName = selectedOffice['name'];
    _contactPersonController.text = selectedOffice['contact_person'] ?? '';
    _contactPhoneController.text = selectedOffice['phone'] ?? '';
    _selectedSupplierId = selectedOffice['supplier_id'] as int?;
  }

  /// The chosen karat's price into the price field (the total follows it).
  void _applyKaratPrice() {
    final price = _karatPrices[_selectedKarat];
    if (price == null) return;
    _priceController.text = price.toStringAsFixed(2);
  }

  // The total is the weight times the price (journey release 3): it is
  // read in the summary bar, not typed -- typing it back-calculated the price.
  void _onWeightChanged() => _recompute();
  void _onPriceChanged() => _recompute();

  void _recompute() {
    final weight = double.tryParse(_weightController.text) ?? 0.0;
    final price = double.tryParse(_priceController.text) ?? 0.0;
    setState(() {
      _weight = weight;
      _pricePerGram = price;
      _totalAmount = weight * price;
    });
    _updatePaymentStatus();
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

    // Enforce payment method selection when any amount is paid -- the
    // backend now requires payment_method_id whenever paid_amount > 0
    // (Phase 9C) and derives the settling safe box from it.
    if (_paidAmount > 0 && _selectedPaymentMethodId == null) {
      _showMessage(
        'الرجاء اختيار وسيلة الدفع عند إدخال مبلغ مدفوع',
        isError: true,
      );
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
        if (_selectedPaymentMethodId != null)
          'payment_method_id': _selectedPaymentMethodId,
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
      // From an office (its card or page): back to it. From the menu: on to
      // the office's page, where the reservation waits to be executed.
      final office = _offices.where((o) => o['id'] == _selectedOfficeId).firstOrNull;
      if (widget.initialOfficeId == null && office != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => OfficeDetailScreen(
              api: widget.api,
              office: office,
              isArabic: widget.isArabic,
            ),
          ),
        );
      } else {
        Navigator.pop(context, response);
      }
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
                Text('${isAr ? "الوزن" : "Weight"}: ${_g(_weight)} · ${isAr ? "عيار" : "Karat"} $_selectedKarat'),
                Text('${isAr ? "السعر" : "Price"}: ${_a(_pricePerGram)} / ${isAr ? "جم" : "g"}'),
                Text('${isAr ? "المبلغ الإجمالي" : "Total"}: ${_a(_totalAmount)}'),
                Text('${isAr ? "المبلغ المدفوع" : "Paid"}: ${_a(_paidAmount)}'),
                if (_paidAmount > 0) ...[
                  Text(
                    '${isAr ? "وسيلة الدفع" : "Payment Method"}: ${_paymentMethodNameById(_selectedPaymentMethodId)}',
                  ),
                  Text(
                    '${isAr ? "ستُقيَّد في خزينة" : "Will settle to safe"}: ${_safeNameById(_resolvedSafeBoxId)}',
                  ),
                ],
                if (_totalAmount - _paidAmount > 0)
                  Text(
                    isAr
                        ? 'المتبقي ${_a(_totalAmount - _paidAmount)} يصير دينًا للمكتب عند التنفيذ'
                        : 'Remaining ${_a(_totalAmount - _paidAmount)}, owed on execution',
                    style: TextStyle(
                      color: AppSemanticColors.of(context).warning.fg,
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
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  // ── the form (journey release 3) ──
  // Two columns on a wide screen: the reservation -- office, gold, price -- and
  // what may be added -- a deposit, the details; a bar under the page says
  // the reservation in one line and saves it. What it sends is the form's
  // before (test/payloads/office_reservation_*.json).

  String _g(double v) => '${ltrIsolate(formatGrams(v))} ${widget.isArabic ? 'جم' : 'g'}';
  String _a(double v) => '${ltrIsolate(formatAmount(v))} $_currencySymbol';

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

  Widget _dateField({
    required Key key,
    required String label,
    required DateTime? value,
    required String empty,
    required DateTime first,
    required DateTime last,
    required DateTime initial,
    required ValueChanged<DateTime> onPicked,
  }) {
    return InkWell(
      key: key,
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: first,
          lastDate: last,
        );
        if (picked != null) setState(() => onPicked(picked));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.event_outlined),
        ),
        child: Text(
          value == null ? empty : ltrIsolate(DateFormat('yyyy-MM-dd').format(value)),
        ),
      ),
    );
  }

  List<Widget> _reservationFields(bool isAr, bool wide) {
    final theme = Theme.of(context);
    final market = _karatPrices[_selectedKarat];
    final priceChanged = market != null && (_pricePerGram - market).abs() >= 0.005;
    final karat = DropdownButtonFormField<int>(
      // Rebuilt when the main karat arrives from the server.
      key: ValueKey('reservation-karat-$_selectedKarat'),
      initialValue: _selectedKarat,
      decoration: InputDecoration(
        labelText: isAr ? 'العيار' : 'Karat',
        prefixIcon: const Icon(Icons.verified_outlined),
      ),
      items: [for (final k in const [24, 22, 21, 18])
        DropdownMenuItem(value: k, child: Text('${isAr ? "عيار" : "Karat"} $k'))],
      onChanged: (value) => setState(() {
        _selectedKarat = value!;
        _applyKaratPrice();
      }),
    );
    final weight = TextFormField(
      key: const Key('reservation-weight'),
      controller: _weightController,
      decoration: InputDecoration(
        labelText: isAr ? 'الوزن (جرام)' : 'Weight (grams)',
        prefixIcon: const Icon(Icons.scale_outlined),
        suffixText: isAr ? 'جم' : 'g',
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [NormalizeNumberFormatter()],
      validator: (value) {
        final w = double.tryParse(value ?? '');
        if (w == null || w <= 0) return isAr ? 'أدخل الوزن' : 'Enter the weight';
        return null;
      },
    );
    return [
      DropdownButtonFormField<int>(
        key: ValueKey('office-${_selectedOfficeId ?? 'none'}'),
        initialValue: _selectedOfficeId,
        decoration: InputDecoration(
          labelText: isAr ? 'اختر المكتب' : 'Select Office',
          prefixIcon: const Icon(Icons.store_outlined),
        ),
        isExpanded: true,
        items: [for (final office in _offices)
          DropdownMenuItem<int>(value: office['id'], child: Text(office['name'] ?? ''))],
        onChanged: (value) => setState(() => _selectOffice(value)),
        validator: (value) => value == null ? (isAr ? 'اختر المكتب' : 'Choose the office') : null,
      ),
      const SizedBox(height: AppSpace.md),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: karat),
            const SizedBox(width: AppSpace.md),
            Expanded(child: weight),
          ],
        )
      else ...[
        karat,
        const SizedBox(height: AppSpace.md),
        weight,
      ],
      const SizedBox(height: AppSpace.md),
      TextFormField(
        key: const Key('reservation-price'),
        controller: _priceController,
        decoration: InputDecoration(
          labelText: isAr ? 'السعر للجرام ($_currencySymbol)' : 'Price per gram ($_currencySymbol)',
          prefixIcon: const Icon(Icons.sell_outlined),
          suffixText: _currencySymbol,
          helperText: market == null
              ? null
              : (isAr
                    ? 'سعر السوق لعيار $_selectedKarat: ${ltrIsolate(formatAmount(market))}'
                    : 'Market price, ${_selectedKarat}k: ${formatAmount(market)}'),
          suffixIcon: priceChanged
              ? IconButton(
                  key: const Key('reservation-price-reset'),
                  tooltip: isAr ? 'سعر السوق' : 'Market price',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => setState(_applyKaratPrice),
                )
              : null,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [NormalizeNumberFormatter()],
        validator: (value) {
          final p = double.tryParse(value ?? '');
          if (p == null || p <= 0) return isAr ? 'أدخل السعر' : 'Enter the price';
          return null;
        },
      ),
      const SizedBox(height: AppSpace.md),
      _dateField(
        key: const Key('reservation-date'),
        label: isAr ? 'تاريخ الحجز' : 'Reservation date',
        value: _reservationDate,
        empty: '',
        first: DateTime(2020),
        last: DateTime.now(),
        initial: _reservationDate,
        onPicked: (d) => _reservationDate = d,
      ),
      if (_totalAmount > 0) ...[
        const SizedBox(height: AppSpace.sm),
        Text(
          isAr ? 'الإجمالي ${_a(_totalAmount)}' : 'Total ${_a(_totalAmount)}',
          key: const Key('reservation-total'),
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    ];
  }

  Widget _depositSection(bool isAr) {
    final theme = Theme.of(context);
    final paid = _paidAmount > 0;
    return Card(
      child: ExpansionTile(
        key: const Key('reservation-deposit'),
        initiallyExpanded: paid,
        leading: const Icon(Icons.payments_outlined),
        title: Text(isAr ? 'دفعة مقدّمة (عربون)' : 'Deposit'),
        subtitle: Text(
          paid
              ? (isAr ? 'مدفوع ${_a(_paidAmount)}' : 'Paid ${_a(_paidAmount)}')
              : (isAr ? 'لا عربون — يُسدَّد الثمن بعد التنفيذ' : 'None -- paid after execution'),
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        children: [
          TextFormField(
            controller: _paidAmountController,
            decoration: InputDecoration(
              labelText: isAr ? 'المبلغ المدفوع' : 'Paid Amount',
              prefixIcon: const Icon(Icons.payments),
              suffixText: _currencySymbol,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [NormalizeNumberFormatter()],
          ),
          const SizedBox(height: AppSpace.md),
          // Required when anything is paid: the safe is the method's (Phase 9C).
          DropdownButtonFormField<int>(
            key: ValueKey('payment-method-${_selectedPaymentMethodId ?? 'none'}'),
            initialValue: _selectedPaymentMethodId,
            decoration: InputDecoration(
              labelText: isAr ? 'وسيلة الدفع' : 'Payment Method',
              prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
              helperText: _selectedPaymentMethodId == null
                  ? null
                  : (isAr
                        ? 'تخرج من خزينة: ${_safeNameById(_resolvedSafeBoxId)}'
                        : 'From safe: ${_safeNameById(_resolvedSafeBoxId)}'),
            ),
            isExpanded: true,
            items: [for (final method in _paymentMethods)
              DropdownMenuItem<int>(value: method['id'], child: Text(method['name']?.toString() ?? ''))],
            onChanged: (value) => setState(() => _selectedPaymentMethodId = value),
            validator: (value) => _paidAmount > 0 && value == null
                ? (isAr ? 'اختر وسيلة الدفع' : 'Choose the way to pay')
                : null,
          ),
        ],
      ),
    );
  }

  Widget _detailsSection(bool isAr) {
    return Card(
      child: ExpansionTile(
        key: const Key('reservation-details'),
        leading: const Icon(Icons.notes_outlined),
        title: Text(isAr ? 'تفاصيل إضافية' : 'More details'),
        subtitle: Text(
          isAr ? 'المسؤول والجوال وتاريخ الاستلام والملاحظات' : 'Contact, delivery date, notes',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        children: [
          TextFormField(
            controller: _contactPersonController,
            decoration: InputDecoration(
              labelText: isAr ? 'اسم المسؤول' : 'Contact Person',
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          TextFormField(
            controller: _contactPhoneController,
            decoration: InputDecoration(
              labelText: isAr ? 'رقم الجوال' : 'Phone Number',
              prefixIcon: const Icon(Icons.phone_outlined),
            ),
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: AppSpace.md),
          _dateField(
            key: const Key('reservation-delivery-date'),
            label: isAr ? 'تاريخ الاستلام المتوقع' : 'Expected delivery',
            value: _deliveryDate,
            empty: isAr ? 'غير محدد' : 'Not set',
            first: DateTime.now(),
            last: DateTime.now().add(const Duration(days: 365)),
            initial: _deliveryDate ?? DateTime.now().add(const Duration(days: 7)),
            onPicked: (d) => _deliveryDate = d,
          ),
          const SizedBox(height: AppSpace.md),
          TextFormField(
            controller: _notesController,
            decoration: InputDecoration(
              labelText: isAr ? 'ملاحظات' : 'Notes',
              prefixIcon: const Icon(Icons.note_outlined),
            ),
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  /// The reservation in one line, and its save -- always in sight.
  Widget _summaryBar(bool isAr) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final rest = _totalAmount - _paidAmount;
    final line = _totalAmount > 0
        ? '${_g(_weight)} ${isAr ? 'عيار' : 'K'} $_selectedKarat × ${ltrIsolate(formatAmount(_pricePerGram))} = ${_a(_totalAmount)}'
        : (isAr ? 'أدخل الوزن والسعر' : 'Enter the weight and price');
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      line,
                      key: const Key('reservation-summary'),
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (_totalAmount > 0)
                      Text(
                        isAr
                            ? 'مدفوع ${_a(_paidAmount)} · متبقٍّ ${_a(rest > 0 ? rest : 0)}'
                            : 'Paid ${_a(_paidAmount)} · rest ${_a(rest > 0 ? rest : 0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: rest > 0.005 ? tones.warning.fg : tones.ready.fg,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              FilledButton.icon(
                key: const Key('reservation-save'),
                onPressed: _isLoading ? null : _saveReservation,
                icon: const Icon(Icons.save_outlined),
                label: Text(isAr ? 'حفظ الحجز' : 'Save Reservation'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();
    final isAr = widget.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'التسكير - حجز ذهب خام' : 'Gold Reservation'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_suggest_outlined),
            tooltip: isAr ? 'إعدادات التسكير الآلي' : 'Auto close settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WeightClosingSettingsScreen()),
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
      bottomNavigationBar: _isLoading ? null : _summaryBar(isAr),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: LayoutBuilder(
                builder: (context, c) {
                  final wide = c.maxWidth >= 900;
                  final reservation = _section(
                    isAr ? 'الحجز' : 'Reservation',
                    Icons.lock_clock,
                    _reservationFields(isAr, wide),
                  );
                  final extras = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _depositSection(isAr),
                      const SizedBox(height: AppSpace.md),
                      _detailsSection(isAr),
                    ],
                  );
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpace.lg),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: reservation),
                                  const SizedBox(width: AppSpace.lg),
                                  Expanded(flex: 2, child: extras),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  reservation,
                                  const SizedBox(height: AppSpace.md),
                                  extras,
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
