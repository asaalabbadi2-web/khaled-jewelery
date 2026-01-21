import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/employee_model.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'voucher_preview_screen.dart';
import '../utils.dart';

/// نموذج لسطر حساب في السند
class AccountLineModel {
  int? accountId;
  String lineType; // 'debit' or 'credit'
  String amountType; // 'cash' or 'gold'
  double amount;
  double? karat;
  String? description;

  AccountLineModel({
    this.accountId,
    required this.lineType,
    required this.amountType,
    this.amount = 0,
    this.karat,
    this.description,
  });

  Map<String, dynamic> toJson() {
    return {
      if (accountId != null) 'account_id': accountId,
      'line_type': lineType,
      'amount_type': amountType,
      'amount': amount,
      if (karat != null) 'karat': karat,
      if (description != null && description!.isNotEmpty)
        'description': description,
    };
  }
}

class AddVoucherScreen extends StatefulWidget {
  final String voucherType; // 'receipt' or 'payment'
  final Map<String, dynamic>? existingVoucher; // optional: edit mode

  const AddVoucherScreen({
    super.key,
    required this.voucherType,
    this.existingVoucher,
  });

  @override
  State<AddVoucherScreen> createState() => _AddVoucherScreenState();
}

class _AddVoucherScreenState extends State<AddVoucherScreen> {
  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _receiverNameController = TextEditingController();

  final List<AccountLineModel> _accountLines = [];
  final List<String> _attachedFileNames = [];

  // Raw incoming account lines from server when opening in edit mode.
  // We store them until accounts/customers/safes are loaded so we can
  // correctly separate party lines from editable account lines.
  List<Map<String, dynamic>>? _incomingAccountLinesRaw;

  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _accounts = [];
  List<SafeBoxModel> _safeBoxes = [];

  final Map<int, double> _safeLedgerCashBalance = {};
  final Set<int> _safeLedgerCashBalanceLoading = {};
  List<EmployeeModel> _employees = [];

  int? _selectedCustomerId;
  int? _selectedSupplierId;
  int? _selectedEmployeeId;
  int? _selectedOtherAccountId;

  bool _isLoading = false;
  bool _isSaving = false;

  String _partyType = 'customer';
  String? _selectedTemplateId;

  DateTime _selectedDate = DateTime.now();

  String _currencySymbol = 'ر.س';
  int _currencyDecimalPlaces = 2;
  int _mainKarat = 21;

  SettingsProvider? _settingsProvider;

  final List<double> _availableKarats = const [24, 22, 21, 18];

  @override
  void initState() {
    super.initState();
    if (widget.voucherType == 'payment') {
      _partyType = 'supplier';
    }
    _accountLines.add(
      AccountLineModel(
        lineType: widget.voucherType == 'receipt' ? 'debit' : 'credit',
        amountType: 'cash',
      ),
    );

    if (widget.existingVoucher != null) {
      _populateFromExisting(widget.existingVoucher!);
    }

    _loadData();
  }

  // Move populate/apply helpers to instance methods so they can be reused
  // after metadata loads.
  void _populateFromExisting(Map<String, dynamic> v) {
    try {
      if (v['date'] != null) {
        _selectedDate = DateTime.tryParse(v['date']) ?? _selectedDate;
      }
      _descriptionController.text = (v['description'] ?? '') as String;
      _notesController.text = (v['notes'] ?? '') as String;
      _receiverNameController.text = (v['receiver_name'] ?? '') as String;

      final partyType = (v['party_type'] ?? '') as String;
      if (partyType.isNotEmpty) {
        _partyType = partyType;
      }
      if (_partyType == 'customer') {
        _selectedCustomerId = v['customer_id'] as int?;
      } else if (_partyType == 'supplier') {
        _selectedSupplierId = v['supplier_id'] as int?;
      } else if (_partyType == 'employee') {
        _selectedEmployeeId = v['employee_id'] as int?;
      }

      final rawLines = (v['account_lines'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      _incomingAccountLinesRaw = rawLines;

      if (_partyType == 'other') {
        final String partyLineType = widget.voucherType == 'receipt'
            ? 'credit'
            : 'debit';
        final Map<String, dynamic> partyLine = rawLines.firstWhere(
          (line) => line['line_type'] == partyLineType,
          orElse: () => <String, dynamic>{},
        );
        final candidateId = _coerceAccountId(partyLine['account_id']);
        if (candidateId != null) {
          _selectedOtherAccountId = candidateId;
        }
      }

      _accountLines.clear();
    } catch (_) {
      // ignore and keep defaults if population fails
    }
  }

  /// After account/safe/customer data is loaded, convert incoming raw lines into
  /// editable `_accountLines`, excluding the party-side lines which are stored on the
  /// voucher but are not user-editable (they are auto-generated from the other lines).
  void _applyIncomingAccountLinesIfNeeded() {
    if (_incomingAccountLinesRaw == null) return;

    try {
      int? partyAccountId;
      if (_partyType == 'customer' && _selectedCustomerId != null) {
        final customer = _findById(_customers, _selectedCustomerId);
        partyAccountId = _coerceAccountId(
          customer?['account_id'] ?? customer?['account_category_id'],
        );
      } else if (_partyType == 'supplier' && _selectedSupplierId != null) {
        final supplier = _findById(_suppliers, _selectedSupplierId);
        partyAccountId = _coerceAccountId(
          supplier?['account_id'] ?? supplier?['account_category_id'],
        );
      } else if (_partyType == 'employee' && _selectedEmployeeId != null) {
        final emp = _findEmployeeById(_selectedEmployeeId);
        partyAccountId = emp?.accountId;
      } else if (_partyType == 'other' && _selectedOtherAccountId != null) {
        partyAccountId = _selectedOtherAccountId;
      }

      if (_partyType == 'other' && partyAccountId == null) {
        final String partyLineType = widget.voucherType == 'receipt'
            ? 'credit'
            : 'debit';
        final Map<String, dynamic> partyLine = _incomingAccountLinesRaw!
            .firstWhere(
              (line) => line['line_type'] == partyLineType,
              orElse: () => <String, dynamic>{},
            );
        final candidateId = _coerceAccountId(partyLine['account_id']);
        if (candidateId != null) {
          partyAccountId = candidateId;
          _selectedOtherAccountId = candidateId;
        }
      }

      final List<AccountLineModel> applied = [];
      for (final map in _incomingAccountLinesRaw!) {
        final mapAccountId = map['account_id'] is num
            ? (map['account_id'] as num).toInt()
            : null;

        if (partyAccountId != null &&
            mapAccountId != null &&
            mapAccountId == partyAccountId) {
          continue;
        }

        final amountType = (map['amount_type'] ?? 'cash') as String;
        final karat = map['karat'] != null
            ? (map['karat'] as num).toDouble()
            : null;
        final amount = (map['amount'] is num)
            ? (map['amount'] as num).toDouble()
            : double.tryParse('${map['amount']}') ?? 0.0;
        applied.add(
          AccountLineModel(
            accountId: mapAccountId,
            lineType: (map['line_type'] ?? 'debit') as String,
            amountType: amountType,
            amount: amount,
            karat: karat,
            description: map['description'] as String?,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        if (applied.isNotEmpty) {
          _accountLines
            ..clear()
            ..addAll(applied);
        } else {
          _accountLines
            ..clear()
            ..add(
              AccountLineModel(
                lineType: widget.voucherType == 'receipt' ? 'debit' : 'credit',
                amountType: 'cash',
              ),
            );
        }
        _incomingAccountLinesRaw = null;
      });
    } catch (_) {
      _incomingAccountLinesRaw = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<SettingsProvider>(context);
    if (_settingsProvider != provider ||
        _currencySymbol != provider.currencySymbol ||
        _currencyDecimalPlaces != provider.decimalPlaces ||
        _mainKarat != provider.mainKarat) {
      setState(() {
        _settingsProvider = provider;
        _currencySymbol = provider.currencySymbol;
        _currencyDecimalPlaces = provider.decimalPlaces;
        _mainKarat = provider.mainKarat;
      });
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _notesController.dispose();
    _receiverNameController.dispose();
    super.dispose();
  }

  double get _totalCash => _accountLines
      .where((line) => line.amountType == 'cash')
      .fold(0.0, (sum, line) => sum + line.amount);

  Map<double, double> get _totalGoldByKarat {
    final Map<double, double> totals = {};
    for (final line in _accountLines) {
      if (line.amountType != 'gold') continue;
      final karat = line.karat ?? _mainKarat.toDouble();
      totals[karat] = (totals[karat] ?? 0) + line.amount;
    }
    return totals;
  }

  double get _balanceDiff {
    double debitTotal = 0;
    double creditTotal = 0;

    for (final line in _accountLines) {
      final normalized = _normalizeLineAmount(line);
      if (line.lineType == 'debit') {
        debitTotal += normalized;
      } else {
        creditTotal += normalized;
      }
    }

    if (debitTotal == 0 || creditTotal == 0) {
      return 0;
    }

    return (debitTotal - creditTotal).abs();
  }

  double _normalizeLineAmount(AccountLineModel line) {
    if (line.amountType == 'gold') {
      final karat = line.karat ?? _mainKarat.toDouble();
      if (_mainKarat <= 0) {
        return line.amount;
      }
      return line.amount * (karat / _mainKarat);
    }
    return line.amount;
  }

  Future<void> _pickFiles() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ميزة إرفاق الملفات غير متاحة حالياً.')),
    );
  }

  Map<String, dynamic>? _findById(List<Map<String, dynamic>> items, int? id) {
    if (id == null) {
      return null;
    }
    try {
      return items.firstWhere((item) => item['id'] == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final customers = await _apiService.getCustomers();
      final suppliers = await _apiService.getSuppliers();
      final employeesData = await _apiService.getEmployees();
      final accounts = await _apiService.getAccounts();

      // تحميل الخزائن النشطة (نقدية وبنكية فقط)
      final safeBoxes = await _apiService.getSafeBoxes(
        safeType: null, // جميع الأنواع
        isActive: true,
        includeAccount: true,
        includeBalance: true,
      );

      setState(() {
        _customers = customers
            .whereType<Map<String, dynamic>>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList();
        _suppliers = suppliers
            .whereType<Map<String, dynamic>>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
        _employees =
            (employeesData['employees'] as List<EmployeeModel>? ??
            <EmployeeModel>[]);
        _accounts = accounts
            .whereType<Map<String, dynamic>>()
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
        _safeBoxes = safeBoxes;
        _isLoading = false;
      });

      _applyIncomingAccountLinesIfNeeded();
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في تحميل البيانات: $e')));
      }
    }
  }

  List<dynamic> _getFilteredAccounts({String? lineType, String? amountType}) {
    // تحديد متى نعرض الخزائن بناءً على نوع السند:
    // - سند القبض: الخزائن مدينة (debit) - نستقبل فيها
    // - سند الصرف: الخزائن دائنة (credit) - نصرف منها
    final bool isReceipt = widget.voucherType == 'receipt';
    final bool shouldShowSafeBoxes =
        (isReceipt && lineType == 'debit') ||
        (!isReceipt && lineType == 'credit');

    if (shouldShowSafeBoxes) {
      // فلترة الخزائن حسب نوع المبلغ
      final filteredSafes = _safeBoxes.where((sb) {
        if (amountType == 'gold') {
          return sb.safeType == 'gold';
        }
        // الوضع الافتراضي (نقد/شيكات/بنك)
        return sb.safeType == 'cash' ||
          sb.safeType == 'bank' ||
          sb.safeType == 'clearing' ||
          sb.safeType == 'check';
      }).toList();

      return filteredSafes
          .map(
            (sb) => {
              'id': sb.accountId,
              'account_number': sb.account?.accountNumber ?? '',
              'name': sb.name, // اسم الخزينة
              'safe_type': sb.safeType, // نوع الخزينة
              'bank_name': sb.bankName, // اسم البنك
              'is_default': sb.isDefault, // افتراضي
              'safe_balance': sb.balance?.cash,
              'safe_weight': sb.balance?.weight,
              'safe_karat': sb.karat,
              'safe_model': sb,
            },
          )
          .toList();
    }

    // للحالات الأخرى: نعرض الحسابات العادية
    final commonAccounts = [
      '1000',
      '1010',
      '1020',
      '1030',
      '1200',
      '1210',
      '1220',
      '1230',
      '1240',
      '1250',
      '1260',
    ];

    // فلترة الحسابات: إظهار الحسابات التفصيلية فقط (4 خانات أو أكثر)
    final detailedAccounts = _accounts.where((acc) {
      final accountNumber = acc['account_number'].toString();
      return accountNumber.length >= 4; // حسابات تفصيلية
    }).toList();

    // ترتيب: الحسابات الأكثر استخداماً في المقدمة
    detailedAccounts.sort((a, b) {
      final aNumber = a['account_number'].toString();
      final bNumber = b['account_number'].toString();

      final aIndex = commonAccounts.indexOf(aNumber);
      final bIndex = commonAccounts.indexOf(bNumber);

      // الحسابات الشائعة في المقدمة
      if (aIndex != -1 && bIndex != -1) {
        return aIndex.compareTo(bIndex);
      } else if (aIndex != -1) {
        return -1; // a قبل b
      } else if (bIndex != -1) {
        return 1; // b قبل a
      } else {
        // ترتيب باقي الحسابات حسب الرقم
        return aNumber.compareTo(bNumber);
      }
    });

    return detailedAccounts;
  }

  SafeBoxModel? _findSafeByAccountId(int? accountId) {
    if (accountId == null) {
      return null;
    }
    try {
      return _safeBoxes.firstWhere((sb) => sb.accountId == accountId);
    } catch (_) {
      return null;
    }
  }

  double _parseLineAmount(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0.0;
    return 0.0;
  }

  Future<void> _ensureSafeLedgerBalanceLoaded(SafeBoxModel safe) async {
    final safeId = safe.id;
    if (safeId == null) {
      return;
    }

    if (_safeLedgerCashBalance.containsKey(safeId)) {
      return;
    }
    if (_safeLedgerCashBalanceLoading.contains(safeId)) {
      return;
    }

    setState(() {
      _safeLedgerCashBalanceLoading.add(safeId);
    });
    try {
      final resp = await _apiService.getSafeBoxLedgerBalance(safeId);
      final bal = (resp['cash_balance'] as num?)?.toDouble() ?? 0.0;
      if (!mounted) return;
      setState(() {
        _safeLedgerCashBalance[safeId] = bal;
      });
    } catch (_) {
      // Best-effort UI hint; ignore failures (permissions/network).
    } finally {
      if (mounted) {
        setState(() {
          _safeLedgerCashBalanceLoading.remove(safeId);
        });
      }
    }
  }

  EmployeeModel? _findEmployeeById(int? employeeId) {
    if (employeeId == null) {
      return null;
    }
    try {
      return _employees.firstWhere((emp) => emp.id == employeeId);
    } catch (_) {
      return null;
    }
  }

  int? _coerceAccountId(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      return int.tryParse(trimmed);
    }
    return null;
  }

  void _ensureFirstLineConfiguration({
    required String amountType,
    double? karat,
    String? description,
  }) {
    if (_accountLines.isEmpty) {
      _addNewLine();
    }

    final firstLine = _accountLines.first;
    firstLine.amountType = amountType;
    if (amountType == 'gold') {
      firstLine.karat = karat ?? _mainKarat.toDouble();
    } else {
      firstLine.karat = null;
    }
    if (description != null &&
        (firstLine.description == null || firstLine.description!.isEmpty)) {
      firstLine.description = description;
    }
  }

  List<Map<String, dynamic>> _getTemplates() {
    if (widget.voucherType == 'receipt') {
      return [
        {
          'id': 'receipt_customer',
          'title': 'دفعة عميل',
          'description': 'تهيئة السند لتحصيل دفعة نقدية من عميل.',
          'icon': Icons.person_add_alt,
        },
        {
          'id': 'receipt_gold',
          'title': 'استلام ذهب',
          'description': 'استلام ذهب من عميل وتحويله لخزينة ذهب.',
          'icon': Icons.diamond_outlined,
        },
        {
          'id': 'receipt_advance_return',
          'title': 'استرداد سلفة',
          'description': 'استرداد سلفة موظف إلى الخزينة.',
          'icon': Icons.assignment_return_outlined,
        },
        {
          'id': 'receipt_safe_transfer',
          'title': 'تحويل لخزينة',
          'description': 'تحضير السند لتحويل رصيد إلى خزينة محددة.',
          'icon': Icons.account_balance_wallet_outlined,
        },
      ];
    }

    return [
      {
        'id': 'payment_supplier',
        'title': 'دفعة لمورد',
        'description': 'تهيئة السند لصرف دفعة نقدية إلى مورد.',
        'icon': Icons.local_shipping_outlined,
      },
      {
        'id': 'payment_salary',
        'title': 'راتب موظف',
        'description': 'تجهيز السند لصرف راتب موظف محدد.',
        'icon': Icons.badge_outlined,
      },
      {
        'id': 'payment_advance',
        'title': 'سلفة موظف',
        'description': 'صرف سلفة لموظف من الخزينة.',
        'icon': Icons.money_off_outlined,
      },
      {
        'id': 'payment_expense',
        'title': 'مصروف تشغيلي',
        'description': 'صرف مصروف تشغيلي من الخزينة.',
        'icon': Icons.receipt_long_outlined,
      },
    ];
  }

  void _applyTemplate(String templateId) {
    setState(() {
      _selectedTemplateId = templateId;

      void clearPartySelections() {
        _selectedCustomerId = null;
        _selectedSupplierId = null;
        _selectedEmployeeId = null;
        _selectedOtherAccountId = null;
      }

      switch (templateId) {
        case 'receipt_customer':
          _partyType = 'customer';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استلام دفعة من العميل'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'تحصيل نقدي',
          );
          break;
        case 'receipt_gold':
          _partyType = 'customer';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استلام ذهب وتسليمه إلى الخزينة'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'gold',
            karat: _mainKarat.toDouble(),
            description: 'ذهب مستلم',
          );
          break;
        case 'receipt_advance_return':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'استرداد سلفة من موظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'حدد حساب السلفة (140xxx) المرتبط بالموظف.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'استرداد سلفة',
          );
          // البحث عن حساب السلف التجميعي
          final advanceAccount = _accounts.firstWhere(
            (acc) => acc['account_number']?.toString() == '1400',
            orElse: () => <String, dynamic>{},
          );
          if (advanceAccount.isNotEmpty) {
            _selectedOtherAccountId = advanceAccount['id'] as int?;
          }
          break;
        case 'receipt_safe_transfer':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'تحويل رصيد إلى خزينة'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'تحويل داخلي',
          );
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر الحساب الداخلي المناسب للتحويل.'
              : _notesController.text;
          break;
        case 'payment_supplier':
          _partyType = 'supplier';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف دفعة للمورد'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'دفعة للمورد',
          );
          break;
        case 'payment_salary':
          _partyType = 'employee';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف راتب موظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'يرجى اختيار الموظف وتحديد الفترة.'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'راتب',
          );
          break;
        case 'payment_advance':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف سلفة لموظف'
              : _descriptionController.text;
          _notesController.text = _notesController.text.isEmpty
              ? 'اختر حساب السلفة التفصيلي للموظف (مثل: 140000 - سلفة أحمد)'
              : _notesController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'سلفة موظف',
          );
          // لا نحدد حساب مسبقاً - المستخدم يختار الحساب التفصيلي للموظف
          _selectedOtherAccountId = null;
          break;
        case 'payment_expense':
          _partyType = 'other';
          clearPartySelections();
          _descriptionController.text = _descriptionController.text.isEmpty
              ? 'صرف مصروف تشغيلي'
              : _descriptionController.text;
          _ensureFirstLineConfiguration(
            amountType: 'cash',
            description: 'مصروف تشغيلي',
          );
          final expenseAccount = _accounts.firstWhere(
            (acc) => acc['account_number']?.toString().startsWith('5') ?? false,
            orElse: () => <String, dynamic>{},
          );
          if (expenseAccount.isNotEmpty) {
            _selectedOtherAccountId = expenseAccount['id'] as int?;
          }
          break;
      }
    });

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('تم تطبيق القالب بنجاح'),
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.primaryGold,
      ),
    );
  }

  Widget _buildStatusChip({
    required IconData icon,
    required Color color,
    required String label,
    String? subtitle,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: color.withValues(alpha: 0.85),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Reusable cluster of status chips to keep the indicators consistent
  /// wherever they are rendered (hero header, status board, etc.).
  Widget _buildStatusChips({
    required bool partyReady,
    required bool accountsReady,
    required bool hasAmounts,
    required bool hasSafeOverdraft,
    required String totalGoldText,
  }) {
    final theme = Theme.of(context);
    final Color successColor = AppColors.success;
    final Color warningColor = AppColors.warning;
    final Color infoColor = AppColors.info;
    final Color neutralColor = theme.colorScheme.outlineVariant;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _buildStatusChip(
          icon: partyReady ? Icons.verified_user : Icons.person_search,
          color: partyReady ? successColor : warningColor,
          label: partyReady ? 'الطرف جاهز' : 'الطرف غير محدد',
          subtitle: partyReady
              ? 'يمكنك متابعة تعبئة السند.'
              : 'حدد الطرف المناسب قبل المتابعة.',
        ),
        _buildStatusChip(
          icon: accountsReady ? Icons.check_circle : Icons.list_alt,
          color: accountsReady ? infoColor : warningColor,
          label: accountsReady ? 'سطور الحسابات مكتملة' : 'أكمل بيانات السطور',
          subtitle: accountsReady
              ? 'كل السطور تحتوي على حساب ومبلغ.'
              : 'تأكد من اختيار الحساب وإدخال المبلغ لكل سطر.',
        ),
        _buildStatusChip(
          icon: Icons.account_balance_wallet,
          color: hasAmounts ? infoColor : neutralColor,
          label: hasAmounts
              ? 'إجمالي النقد: ${_formatCash(_totalCash)}'
              : 'لا يوجد مبلغ مُدخل',
          subtitle: totalGoldText.isNotEmpty ? 'الذهب: $totalGoldText' : null,
        ),
        if (hasSafeOverdraft)
          _buildStatusChip(
            icon: Icons.warning_amber_rounded,
            color: AppColors.error,
            label: 'تحذير أرصدة الخزائن',
            subtitle: 'يوجد سطر يتجاوز الرصيد المتاح للخزينة المختارة.',
          )
        else
          _buildStatusChip(
            icon: Icons.shield_outlined,
            color: successColor,
            label: 'الخزائن ضمن الحدود',
            subtitle: 'لا توجد تجاوزات في أرصدة الخزائن الحالية.',
          ),
      ],
    );
  }

  Widget _buildStatusBoard() {
    final bool partyReady =
        (_partyType == 'customer' && _selectedCustomerId != null) ||
        (_partyType == 'supplier' && _selectedSupplierId != null) ||
        (_partyType == 'employee' && _selectedEmployeeId != null) ||
        (_partyType == 'other' && _selectedOtherAccountId != null);

    final bool accountsReady =
        _accountLines.isNotEmpty &&
        _accountLines.every(
          (line) => line.accountId != null && line.amount > 0,
        );

    final bool hasAmounts =
        _totalCash > 0 || _totalGoldByKarat.values.any((value) => value > 0);

    final bool hasSafeOverdraft = _accountLines.any((line) {
      if (widget.voucherType != 'payment') return false;
      if (line.amountType != 'cash' || line.amount <= 0) return false;
      final safe = _findSafeByAccountId(line.accountId);
      if (safe == null || safe.balance == null) return false;
      final available = safe.balance!.cash;
      return line.amount - available > 0.0001;
    });

    final totalGoldText = _totalGoldByKarat.entries
        .map(
          (entry) =>
              '${_formatWeight(entry.value, includeUnit: false)} جم ع ${entry.key.toInt()}',
        )
        .join(' • ');

    String statusSummary;
    if (!partyReady) {
      statusSummary = 'حدد الطرف لإكمال بيانات السند';
    } else if (!accountsReady) {
      statusSummary = 'أكمل تفاصيل السطور المتبقية';
    } else if (!hasAmounts) {
      statusSummary = 'أدخل المبالغ النقدية أو الذهبية';
    } else if (hasSafeOverdraft) {
      statusSummary = 'تحقق من أرصدة الخزائن قبل الحفظ';
    } else {
      statusSummary = 'السند مكتمل وجاهز للحفظ أو الترحيل';
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: AppColors.lightGold.withValues(alpha: 0.6),
          width: 1.2,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          maintainState: true,
          leading: Icon(
            Icons.dashboard_customize_outlined,
            color: AppColors.primaryGold,
          ),
          title: Text(
            'مؤشرات السند',
            style: TextStyle(
              color: AppColors.deepGold,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              statusSummary,
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            const SizedBox(height: 8),
            _buildStatusChips(
              partyReady: partyReady,
              accountsReady: accountsReady,
              hasAmounts: hasAmounts,
              hasSafeOverdraft: hasSafeOverdraft,
              totalGoldText: totalGoldText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader(
    BuildContext context,
    bool isReceipt,
    Color accentColor,
    IconData icon,
    String title,
  ) {
    final theme = Theme.of(context);
    final dateText = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final totalGoldText = _totalGoldByKarat.entries
        .map(
          (entry) =>
              '${_formatWeight(entry.value, includeUnit: false)} جم ع ${entry.key.toInt()}',
        )
        .join(' • ');
    final bool isBalanced = _balanceDiff <= 0.01;

    Widget buildChip(
      IconData chipIcon,
      String label,
      Color foreground, {
      Color? background,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: background ?? foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: foreground.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(chipIcon, color: foreground, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      shadowColor: accentColor.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: accentColor, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        isReceipt
                            ? 'سجّل عمليات التحصيل النقدي أو الذهب بسهولة مع تتبع الخزائن والعيارات.'
                            : 'إدارة عمليات الصرف للطرف المستفيد مع مراقبة أرصدة الخزائن والعيارات.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          buildChip(
                            Icons.account_balance_wallet,
                            'نقد: ${_formatCash(_totalCash)}',
                            accentColor,
                          ),
                          if (totalGoldText.isNotEmpty)
                            buildChip(
                              Icons.diamond_outlined,
                              'ذهب: $totalGoldText',
                              AppColors.darkGold,
                              background: AppColors.lightGold.withValues(
                                alpha: 0.25,
                              ),
                            ),
                          buildChip(
                            isBalanced
                                ? Icons.verified_outlined
                                : Icons.warning_amber_rounded,
                            isBalanced
                                ? 'السند متوازن'
                                : 'فرق: ${_formatWeight(_balanceDiff)}',
                            isBalanced ? AppColors.success : AppColors.warning,
                          ),
                          buildChip(
                            Icons.list_alt_outlined,
                            '${_accountLines.length} سطور',
                            AppColors.mediumGold,
                            background: AppColors.lightGold.withValues(
                              alpha: 0.25,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _selectVoucherDate(context),
                      icon: const Icon(Icons.event),
                      label: Text(dateText),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: accentColor,
                        side: BorderSide(
                          color: accentColor.withValues(alpha: 0.6),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        textStyle: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isReceipt ? 'نوع السند: تحصيل' : 'نوع السند: صرف',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.mediumGold,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectVoucherDate(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryGold,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (date != null) {
      setState(() => _selectedDate = date);
    }
  }

  Widget _buildPartySelectorCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.lightGold.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.group_outlined, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'الطرف',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _partyType,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'customer', child: Text('عميل')),
                DropdownMenuItem(value: 'supplier', child: Text('مورد')),
                DropdownMenuItem(value: 'employee', child: Text('موظف')),
                DropdownMenuItem(value: 'other', child: Text('آخر')),
              ],
              onChanged: (value) {
                setState(() {
                  _partyType = value!;
                  _selectedCustomerId = null;
                  _selectedSupplierId = null;
                  _selectedEmployeeId = null;
                  _selectedOtherAccountId = null;
                });
              },
            ),
            const SizedBox(height: 16),
            if (_partyType == 'customer')
              DropdownButtonFormField<int>(
                initialValue: _selectedCustomerId,
                decoration: const InputDecoration(
                  labelText: 'العميل *',
                  border: OutlineInputBorder(),
                  helperText: 'سيتم القيد على الحساب التجميعي للعملاء (1100)',
                ),
                items: _customers.map<DropdownMenuItem<int>>((customer) {
                  return DropdownMenuItem<int>(
                    value: customer['id'],
                    child: Text(customer['name']),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedCustomerId = value;
                  });
                },
              ),
            if (_partyType == 'supplier')
              DropdownButtonFormField<int>(
                initialValue: _selectedSupplierId,
                decoration: const InputDecoration(
                  labelText: 'المورد *',
                  border: OutlineInputBorder(),
                  helperText: 'سيتم القيد على الحساب التجميعي للموردين (211)',
                ),
                items: _suppliers.map<DropdownMenuItem<int>>((supplier) {
                  return DropdownMenuItem<int>(
                    value: supplier['id'],
                    child: Text(supplier['name']),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedSupplierId = value;
                  });
                },
              ),
            if (_partyType == 'employee')
              DropdownButtonFormField<int>(
                initialValue: _selectedEmployeeId,
                decoration: const InputDecoration(
                  labelText: 'الموظف *',
                  border: OutlineInputBorder(),
                  helperText: 'اختر الموظف المرتبط بالسند',
                ),
                items: _employees.map<DropdownMenuItem<int>>((employee) {
                  return DropdownMenuItem<int>(
                    value: employee.id,
                    child: Text(
                      employee.name.isNotEmpty
                          ? employee.name
                          : 'موظف ${employee.id ?? ''}',
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedEmployeeId = value;
                  });
                },
              ),
            if (_partyType == 'other')
              DropdownButtonFormField<int>(
                initialValue: _selectedOtherAccountId,
                decoration: const InputDecoration(
                  labelText: 'الحساب *',
                  border: OutlineInputBorder(),
                  helperText: 'اختر الحساب المناسب (مصروف، سلفة، إلخ)',
                ),
                items: _accounts
                    .where((acc) {
                      final accNum = acc['account_number'].toString();
                      return accNum.startsWith('5') ||
                          accNum.startsWith('4') ||
                          accNum.startsWith('140');
                    })
                    .map<DropdownMenuItem<int>>((account) {
                      return DropdownMenuItem<int>(
                        value: account['id'],
                        child: Text(
                          '${account['account_number']} - ${account['name']}',
                        ),
                      );
                    })
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedOtherAccountId = value;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDescriptionCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.description_outlined, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'البيان',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                hintText: 'أدخل وصف السند أو سبب التحصيل/الصرف',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.mediumGold.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.primaryGold,
                    width: 2,
                  ),
                ),
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiverCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person_outline, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                const Text(
                  'اسم المستلم',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _receiverNameController,
              decoration: InputDecoration(
                hintText: 'اسم الشخص المستلم/المسلم للسند',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.mediumGold.withValues(alpha: 0.3),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: AppColors.primaryGold,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentsCard() {
    final hasAttachments = _attachedFileNames.isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.3)),
      ),
      color: AppColors.lightGold.withValues(alpha: 0.12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          maintainState: true,
          initiallyExpanded: hasAttachments,
          leading: Icon(Icons.attach_file, color: AppColors.primaryGold),
          title: Text(
            'المرفقات (اختياري)',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasAttachments
                  ? 'تم إرفاق ${_attachedFileNames.length} ملف/ملفات'
                  : 'أضف صور الفواتير، إيصالات البنك أو أي مستندات داعمة عند الحاجة',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('إرفاق مستند'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGold,
                  foregroundColor: Colors.white,
                ),
                onPressed: _pickFiles,
              ),
            ),
            if (hasAttachments)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _attachedFileNames
                      .map(
                        (f) => Chip(
                          label: Text(f),
                          backgroundColor: Theme.of(context).cardTheme.color,
                          deleteIcon: const Icon(Icons.close, size: 18),
                          onDeleted: () {
                            setState(() {
                              _attachedFileNames.remove(f);
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountLinesHeader() {
    return Row(
      children: [
        Text(
          'سطور الحسابات',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepGold,
          ),
        ),
      ],
    );
  }

  Widget _buildTotalsCard() {
    return Card(
      color: AppColors.lightGold.withValues(alpha: 0.3),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.primaryGold.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.attach_money, color: AppColors.darkGold),
                const SizedBox(width: 8),
                Text(
                  'مجموع النقد: ',
                  style: TextStyle(
                    color: AppColors.darkGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _formatCash(_totalCash),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(Icons.circle, color: AppColors.primaryGold, size: 14),
                const SizedBox(width: 4),
                Text(
                  'مجموع الذهب:',
                  style: TextStyle(
                    color: AppColors.darkGold,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_totalGoldByKarat.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '0 جم',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                    ),
                  )
                else
                  ..._totalGoldByKarat.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '${_formatWeight(e.value)} ع ${e.key.toInt()}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).textTheme.bodyLarge?.color,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '✅ سيتم إضافة سطر الطرف تلقائياً لتوازن القيد',
                    style: TextStyle(
                      color: AppColors.success,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesCard() {
    final hasNotes = _notesController.text.isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          maintainState: true,
          initiallyExpanded: hasNotes,
          leading: Icon(Icons.note_alt_outlined, color: AppColors.primaryGold),
          title: Text(
            'ملاحظات (اختياري)',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).textTheme.titleLarge?.color,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              hasNotes
                  ? 'تمت إضافة ملاحظات للسند'
                  : 'احفظ تفاصيل داخلية بدون إظهارها في الطباعة',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                hintText: 'أضف تفاصيل إضافية أو ملاحظات داخلية',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveSection(Color accentColor) {
    if (_balanceDiff > 0.01) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey),
              child: const Text('حفظ السند', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'لا يمكن الحفظ: السطور غير متوازنة (الفرق: ${_formatWeight(_balanceDiff)})',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (_balanceDiff <= 0.1)
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_accountLines.isNotEmpty) {
                        _accountLines.last.amount += _balanceDiff;
                      }
                    });
                  },
                  child: Text(
                    'تصحيح تلقائي',
                    style: TextStyle(
                      color: AppColors.primaryGold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        onPressed: _isSaving ? null : _saveVoucher,
        style: ElevatedButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        icon: _isSaving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : const Icon(Icons.save_outlined, size: 24),
        label: Text(
          _isSaving ? 'جاري الحفظ...' : 'حفظ السند',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildTemplateSelector() {
    final templates = _getTemplates();
    if (templates.isEmpty) {
      return const SizedBox.shrink();
    }

    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = isReceipt ? AppColors.success : AppColors.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.lightGold.withValues(alpha: 0.2),
            AppColors.lightGold.withValues(alpha: 0.05),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.lightGold.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.flash_on, color: AppColors.primaryGold, size: 20),
          const SizedBox(width: 8),
          Text(
            'سريع:',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.darkGold,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: templates.map((template) {
                  final bool isSelected = template['id'] == _selectedTemplateId;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _applyTemplate(template['id'] as String),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected ? accentColor : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected
                                  ? accentColor
                                  : AppColors.lightGold.withValues(alpha: 0.5),
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                template['icon'] as IconData,
                                color: isSelected
                                    ? Colors.white
                                    : AppColors.primaryGold,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                template['title'] as String,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? Colors.white
                                      : AppColors.darkGold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartyInfoCard() {
    String title;
    String name = '---';
    String? phone;
    String? idNumber;

    Map<String, dynamic>? selected;

    switch (_partyType) {
      case 'customer':
        selected = _findById(_customers, _selectedCustomerId);
        title = 'العميل المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone =
              selected['mobile']?.toString() ?? selected['phone']?.toString();
          idNumber = selected['id_number']?.toString();
        }
        break;
      case 'supplier':
        selected = _findById(_suppliers, _selectedSupplierId);
        title = 'المورد المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone = selected['phone']?.toString();
          idNumber =
              selected['tax_number']?.toString() ??
              selected['id_number']?.toString();
        }
        break;
      case 'employee':
        final employee = _findEmployeeById(_selectedEmployeeId);
        if (employee == null) {
          return const SizedBox.shrink();
        }
        title = 'الموظف المختار';
        name = employee.name;
        phone = employee.phone;
        idNumber = employee.nationalId;
        break;
      case 'other':
        selected = _findById(_accounts, _selectedOtherAccountId);
        title = 'الحساب المختار';
        if (selected != null) {
          name = selected['name']?.toString() ?? name;
          phone =
              selected['mobile']?.toString() ?? selected['phone']?.toString();
          idNumber = selected['id_number']?.toString();
        }
        break;
      default:
        return const SizedBox.shrink();
    }

    if (_partyType != 'employee' && selected == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(top: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.primaryGold),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepGold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (phone != null && phone.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text(phone, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
            if (idNumber != null && idNumber.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.credit_card_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text(idNumber, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSafeBalanceInfo(AccountLineModel line) {
    final safe = _findSafeByAccountId(line.accountId);
    if (safe == null || safe.balance == null) {
      return const SizedBox.shrink();
    }

    final bool isPayment = widget.voucherType == 'payment';
    String message;
    Color bgColor;
    Color borderColor;
    Color textColor;
    bool exceedsBalance;

    if (line.amountType == 'gold') {
      final weightInfo = safe.balance!.weight;
      if (weightInfo == null) {
        return const SizedBox.shrink();
      }

      final int karat = (line.karat ?? _mainKarat.toDouble()).toInt();
      double availableWeight;
      switch (karat) {
        case 24:
          availableWeight = weightInfo.karat24;
          break;
        case 22:
          availableWeight = weightInfo.karat22;
          break;
        case 21:
          availableWeight = weightInfo.karat21;
          break;
        case 18:
          availableWeight = weightInfo.karat18;
          break;
        default:
          availableWeight = weightInfo.total;
      }

      exceedsBalance = isPayment && line.amount > availableWeight + 0.0001;
      bgColor = exceedsBalance ? Colors.red.shade50 : Colors.green.shade50;
      borderColor = exceedsBalance
          ? Colors.red.shade200
          : Colors.green.shade200;
      textColor = exceedsBalance ? Colors.red.shade700 : Colors.green.shade700;

      final String karatLabel = 'عيار ${karat.toString()}';
      final String formattedAvailable = _formatWeight(
        availableWeight,
        includeUnit: true,
      );
      final String formattedRequested = _formatWeight(
        line.amount,
        includeUnit: true,
      );
      message = exceedsBalance
          ? 'تحذير: الوزن المدخل ($formattedRequested) يتجاوز المخزون المتاح $formattedAvailable ${safe.karat != null ? '(عيار ${safe.karat})' : ''} في "${safe.name}".'
          : 'المخزون المتاح في "${safe.name}": $formattedAvailable ($karatLabel).';
    } else {
      final double balance = safe.balance!.cash;
      exceedsBalance = isPayment && line.amount > balance + 0.0001;
      bgColor = exceedsBalance ? Colors.red.shade50 : Colors.green.shade50;
      borderColor = exceedsBalance
          ? Colors.red.shade200
          : Colors.green.shade200;
      textColor = exceedsBalance ? Colors.red.shade700 : Colors.green.shade700;

      message = exceedsBalance
          ? 'تحذير: المبلغ المدخل (${_formatCash(line.amount)}) يتجاوز الرصيد المتاح ${_formatCash(balance)} في "${safe.name}".'
          : 'الرصيد المتاح في "${safe.name}": ${_formatCash(balance)}';
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            exceedsBalance
                ? Icons.warning_amber_rounded
                : Icons.savings_outlined,
            color: textColor,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w600,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _addNewLine() {
    // تحديد نوع السطر بناءً على نوع السند:
    // - سند القبض: السطور مدينة (debit) - الخزائن التي نستقبل فيها
    // - سند الصرف: السطور دائنة (credit) - الخزائن التي نصرف منها
    final lineType = widget.voucherType == 'receipt' ? 'debit' : 'credit';

    setState(() {
      _accountLines.add(
        AccountLineModel(lineType: lineType, amountType: 'cash'),
      );
    });
  }

  void _removeLine(int index) {
    if (_accountLines.length > 1) {
      setState(() {
        _accountLines.removeAt(index);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يجب أن يحتوي السند على سطر واحد على الأقل'),
        ),
      );
    }
  }

  Future<void> _saveVoucher() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // Validate party - مطلوب دائماً لأن سطر الطرف يتم إضافته تلقائياً
    if (_partyType == 'customer' && _selectedCustomerId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار عميل')));
      return;
    }
    if (_partyType == 'supplier' && _selectedSupplierId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار مورد')));
      return;
    }
    if (_partyType == 'employee' && _selectedEmployeeId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار موظف')));
      return;
    }
    if (_partyType == 'other' && _selectedOtherAccountId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('يجب اختيار حساب')));
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Get party account ID - مطلوب دائماً لأن سطر الطرف يتم إضافته تلقائياً
      int? partyAccountId;
      Map<String, dynamic>? selectedCustomer;
      Map<String, dynamic>? selectedSupplier;
      EmployeeModel? selectedEmployee;

      if (_partyType == 'customer') {
        selectedCustomer = _findById(_customers, _selectedCustomerId);
        if (selectedCustomer == null) {
          throw Exception('تعذر العثور على بيانات العميل المحدد');
        }

        final primaryAccountId = _coerceAccountId(
          selectedCustomer['account_id'],
        );
        final categoryAccountId = _coerceAccountId(
          selectedCustomer['account_category_id'],
        );
        partyAccountId = primaryAccountId ?? categoryAccountId;

        if (partyAccountId == null) {
          throw Exception(
            'العميل المختار لا يملك حساباً مرتبطاً أو حساباً تجميعياً',
          );
        }
      } else if (_partyType == 'supplier') {
        selectedSupplier = _findById(_suppliers, _selectedSupplierId);
        if (selectedSupplier == null) {
          throw Exception('تعذر العثور على بيانات المورد المحدد');
        }

        final primaryAccountId = _coerceAccountId(
          selectedSupplier['account_id'],
        );
        final categoryAccountId = _coerceAccountId(
          selectedSupplier['account_category_id'],
        );
        partyAccountId = primaryAccountId ?? categoryAccountId;

        if (partyAccountId == null) {
          throw Exception(
            'المورد المختار لا يملك حساباً مرتبطاً أو حساباً تجميعياً',
          );
        }
      } else if (_partyType == 'employee') {
        // استخدام حساب الموظف الشخصي
        selectedEmployee = _findEmployeeById(_selectedEmployeeId);
        if (selectedEmployee != null && selectedEmployee.accountId != null) {
          partyAccountId = selectedEmployee.accountId;
        } else {
          throw Exception('الموظف المختار ليس لديه حساب مرتبط');
        }
      } else if (_partyType == 'other') {
        // استخدام الحساب المحدد يدوياً
        partyAccountId = _selectedOtherAccountId;
      }

      if (partyAccountId == null) {
        throw Exception('لم يتم تحديد حساب للطرف');
      }

      // Build account lines
      final List<Map<String, dynamic>> allAccountLines = [];
      final bool isReceipt = widget.voucherType == 'receipt';

      // Add user-entered lines (الخزائن)
      // سند قبض: الخزائن مدينة (نستقبل فيها)
      // سند صرف: الخزائن دائنة (نصرف منها)
      for (var line in _accountLines) {
        if (line.amount <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('يجب إدخال مبلغ أكبر من صفر لجميع السطور'),
            ),
          );
          setState(() => _isSaving = false);
          return;
        }

        if (line.accountId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يجب اختيار حساب لجميع السطور')),
          );
          setState(() => _isSaving = false);
          return;
        }

        if (line.amountType == 'gold' && line.karat == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('يجب اختيار العيار لسطور الذهب')),
          );
          setState(() => _isSaving = false);
          return;
        }

        allAccountLines.add({
          'account_id': line.accountId,
          'line_type': line
              .lineType, // يستخدم lineType من السطر (debit للقبض، credit للصرف)
          'amount_type': line.amountType,
          'amount': line.amount,
          if (line.karat != null) 'karat': line.karat,
          'description':
              line.description ?? (line.amountType == 'cash' ? 'نقد' : 'ذهب'),
        });
      }

      // Calculate totals for party account lines
      double totalCash = 0;
      Map<double, double> totalGoldByKarat = {};

      for (var line in _accountLines) {
        if (line.amountType == 'cash') {
          totalCash += line.amount;
        } else if (line.amountType == 'gold') {
          totalGoldByKarat[line.karat!] =
              (totalGoldByKarat[line.karat!] ?? 0) + line.amount;
        }
      }

      // Add party account line (الطرف - عميل أو مورد)
      // سند قبض: الطرف دائن (يدفع لنا)
      // سند صرف: الطرف مدين (نصرف له)
      final partyLineType = isReceipt ? 'credit' : 'debit';

      if (totalCash > 0) {
        allAccountLines.add({
          'account_id': partyAccountId,
          'line_type': partyLineType,
          'amount_type': 'cash',
          'amount': totalCash,
          'description': 'نقد',
        });
      }

      for (var entry in totalGoldByKarat.entries) {
        allAccountLines.add({
          'account_id': partyAccountId,
          'line_type': partyLineType,
          'amount_type': 'gold',
          'amount': entry.value,
          'karat': entry.key,
          'description': 'ذهب عيار ${entry.key.toInt()}',
        });
      }

      // Prepare voucher data
      final Map<String, dynamic> voucherData = {
        'voucher_type': widget.voucherType,
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'party_type': _partyType,
        'description': _descriptionController.text,
        'notes': _notesController.text.isNotEmpty
            ? _notesController.text
            : null,
        'receiver_name': _receiverNameController.text.isNotEmpty
            ? _receiverNameController.text
            : null,
        'account_lines': allAccountLines,
      };

      // Add party
      if (_partyType == 'customer') {
        voucherData['customer_id'] = _selectedCustomerId;
      } else if (_partyType == 'supplier') {
        voucherData['supplier_id'] = _selectedSupplierId;
      } else if (_partyType == 'employee') {
        voucherData['employee_id'] = _selectedEmployeeId;
      }

      // Create or update voucher
      Map<String, dynamic> response;
      if (widget.existingVoucher != null &&
          widget.existingVoucher!['id'] != null) {
        // Update existing
        final int vid = widget.existingVoucher!['id'] is int
            ? widget.existingVoucher!['id'] as int
            : int.tryParse('${widget.existingVoucher!['id']}') ?? 0;
        response = await _apiService.updateVoucher(vid, voucherData);
      } else {
        response = await _apiService.createVoucher(voucherData);
      }

      if (mounted) {
        // add id for preview
        voucherData['id'] = response['id'];
        voucherData['account_lines'] = (voucherData['account_lines'] as List)
            .map((line) {
              final account = _accounts.firstWhere(
                (acc) => acc['id'] == line['account_id'],
                orElse: () => <String, dynamic>{},
              );

              String? accountName = account['name'] as String?;
              if (accountName == null || accountName.isEmpty) {
                if (line['account_id'] == partyAccountId) {
                  if (selectedCustomer != null) {
                    accountName =
                        (selectedCustomer['account_name'] ??
                                selectedCustomer['account_category_name'])
                            as String?;
                  } else if (selectedSupplier != null) {
                    accountName =
                        (selectedSupplier['account_name'] ??
                                selectedSupplier['account_category_name'])
                            as String?;
                  } else if (selectedEmployee != null) {
                    accountName = selectedEmployee.name;
                  }
                }
              }

              accountName ??= account['name'] as String? ?? '---';

              return {...line, 'account_name': accountName};
            })
            .toList();

        // show success message and return to list
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.existingVoucher != null
                  ? 'تم تعديل السند بنجاح'
                  : 'تم إنشاء السند بنجاح',
            ),
            action: SnackBarAction(
              label: 'معاينة',
              textColor: AppColors.primaryGold,
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => VoucherPreviewScreen(
                      voucherData: voucherData,
                      voucherType: widget.voucherType,
                    ),
                  ),
                );
              },
            ),
          ),
        );

        // العودة إلى شاشة السندات بعد الحفظ
        Navigator.of(context).pop(true); // إرسال true للإشارة إلى أنه تم الحفظ

        // إعادة تعيين النموذج للبقاء في نفس الشاشة
        setState(() {
          _isSaving = false;
          _descriptionController.clear();
          _notesController.clear();
          _accountLines.clear();
          _addNewLine(); // إضافة سطر جديد
          _selectedDate = DateTime.now();
        });
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
      }
    }
  }

  Widget _buildAccountLineCard(int index) {
    final line = _accountLines[index];
    final Map<String, dynamic>? selectedAccount = line.accountId != null
        ? _accounts.firstWhere(
            (a) => a['id'] == line.accountId,
            orElse: () => {'account_number': '', 'name': ''},
          )
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.lightGold.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with line number and delete button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.lightGold.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'السطر ${index + 1}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepGold,
                    ),
                  ),
                ),
                if (_accountLines.length > 1)
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: AppColors.error),
                    onPressed: () => _removeLine(index),
                  ),
              ],
            ),
            const Divider(height: 24),
            // Account selection with Autocomplete
            Autocomplete<Map<String, dynamic>>(
              optionsBuilder: (TextEditingValue textEditingValue) {
                final List<Map<String, dynamic>> accounts =
                    List<Map<String, dynamic>>.from(
                      _getFilteredAccounts(
                        lineType: line.lineType,
                        amountType: line.amountType,
                      ),
                    );
                if (textEditingValue.text == '') {
                  return accounts;
                }
                final search = textEditingValue.text.toLowerCase();
                return accounts.where(
                  (acc) =>
                      acc['account_number'].toString().contains(search) ||
                      acc['name'].toString().toLowerCase().contains(search) ||
                      (acc['bank_name'] != null &&
                          acc['bank_name'].toString().toLowerCase().contains(
                            search,
                          )),
                );
              },
              displayStringForOption: (acc) {
                // عرض معلومات الخزينة إذا كانت خزينة
                if (acc['safe_type'] != null) {
                  final safeTypeLabel = acc['safe_type'] == 'cash'
                      ? 'نقدية'
                      : acc['safe_type'] == 'bank'
                      ? 'بنك'
                      : acc['safe_type'] == 'gold'
                      ? 'ذهب'
                      : 'شيكات';
                  final bankInfo = acc['bank_name'] != null
                      ? ' - ${acc['bank_name']}'
                      : '';
                  final karatInfo =
                      acc['safe_type'] == 'gold' && acc['safe_karat'] != null
                      ? ' - عيار ${acc['safe_karat']}'
                      : '';
                  return '${acc['account_number']} - ${acc['name']} ($safeTypeLabel$bankInfo$karatInfo)';
                }
                return '${acc['account_number']} - ${acc['name']}';
              },
              initialValue: selectedAccount != null
                  ? TextEditingValue(
                      text:
                          '${selectedAccount['account_number']} - ${selectedAccount['name']}',
                    )
                  : const TextEditingValue(),
              fieldViewBuilder:
                  (context, controller, focusNode, onFieldSubmitted) {
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: 'الحساب *',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: AppColors.mediumGold.withValues(alpha: 0.3),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: AppColors.primaryGold,
                            width: 2,
                          ),
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: AppColors.primaryGold,
                        ),
                      ),
                      validator: (value) {
                        if (line.accountId == null) {
                          return 'يجب اختيار حساب';
                        }
                        return null;
                      },
                    );
                  },
              onSelected: (acc) {
                setState(() {
                  line.accountId = acc['id'];
                });

                // If selected account is a SafeBox-backed account, load ledger balance.
                final safe = (acc['safe_model'] is SafeBoxModel)
                    ? acc['safe_model'] as SafeBoxModel
                    : _findSafeByAccountId(_coerceAccountId(acc['id']));
                if (safe != null &&
                    (safe.safeType == 'cash' ||
                      safe.safeType == 'bank' ||
                      safe.safeType == 'clearing')) {
                  _ensureSafeLedgerBalanceLoaded(safe);
                }
              },
            ),
            const SizedBox(height: 12),

            Builder(
              builder: (context) {
                final safe = _findSafeByAccountId(line.accountId);
                if (safe == null) return const SizedBox.shrink();
                if (safe.id == null) return const SizedBox.shrink();
                if (!(safe.safeType == 'cash' ||
                  safe.safeType == 'bank' ||
                  safe.safeType == 'clearing')) {
                  return const SizedBox.shrink();
                }

                final safeId = safe.id!;
                final isLoading = _safeLedgerCashBalanceLoading.contains(
                  safeId,
                );
                final bal = _safeLedgerCashBalance[safeId];
                final amount = _parseLineAmount(line.amount);

                final isOutflowFromSafe =
                    widget.voucherType == 'payment' &&
                    line.lineType == 'credit' &&
                    line.amountType == 'cash';
                final insufficient =
                    isOutflowFromSafe && bal != null && amount > bal + 0.01;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isLoading
                            ? 'جاري تحميل رصيد الخزينة...'
                            : (bal == null
                                  ? 'رصيد الخزينة غير متاح'
                                  : 'رصيد الخزينة الحالي: ${bal.toStringAsFixed(2)} ر.س'),
                        style: TextStyle(
                          color: insufficient
                              ? AppColors.error
                              : Colors.grey.shade700,
                          fontWeight: insufficient
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (insufficient)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'تنبيه: الرصيد لا يغطي مبلغ الصرف',
                            style: TextStyle(
                              color: AppColors.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),

            // Amount type (Cash/Gold)
            RadioGroup<String>(
              groupValue: line.amountType,
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  line.amountType = value;
                  if (value == 'gold') {
                    line.karat ??= _mainKarat
                        .toDouble(); // Use main karat from settings
                  }
                });
              },
              child: Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('نقد'),
                      value: 'cash',
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      title: const Text('ذهب'),
                      value: 'gold',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Amount and Karat
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    initialValue: line.amount > 0 ? line.amount.toString() : '',
                    decoration: InputDecoration(
                      labelText: line.amountType == 'cash'
                          ? 'المبلغ (ريال) *'
                          : 'الوزن (جرام) *',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: AppColors.mediumGold.withValues(alpha: 0.3),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: AppColors.primaryGold,
                          width: 2,
                        ),
                      ),
                      prefixIcon: Icon(
                        line.amountType == 'cash'
                            ? Icons.attach_money
                            : Icons.scale,
                        color: AppColors.primaryGold,
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [NormalizeNumberFormatter()],
                    onChanged: (value) {
                      setState(() {
                        line.amount = double.tryParse(value) ?? 0;
                      });
                    },
                  ),
                ),
                if (line.amountType == 'gold') ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<double>(
                      initialValue: line.karat,
                      decoration: InputDecoration(
                        labelText: 'العيار *',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: AppColors.mediumGold.withValues(alpha: 0.3),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: AppColors.primaryGold,
                            width: 2,
                          ),
                        ),
                        prefixIcon: Icon(
                          Icons.diamond,
                          color: AppColors.primaryGold,
                        ),
                      ),
                      items: _availableKarats.map<DropdownMenuItem<double>>((
                        karat,
                      ) {
                        return DropdownMenuItem<double>(
                          value: karat,
                          child: Text(karat.toString()),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() {
                          line.karat = value;
                        });
                      },
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),

            // Description (optional)
            TextFormField(
              initialValue: line.description,
              decoration: const InputDecoration(
                labelText: 'البيان (اختياري)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  line.description = value;
                });
              },
            ),
            _buildSafeBalanceInfo(line),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWideLayout = size.width >= 1100;
    final isReceipt = widget.voucherType == 'receipt';
    final Color accentColor = isReceipt ? AppColors.success : AppColors.error;
    final String title = isReceipt ? 'سند قبض' : 'سند صرف';
    final IconData icon = isReceipt ? Icons.south : Icons.north;

    final List<Widget> leftColumn = [
      // المساعد السريع في أعلى العمود الأيسر
      _buildTemplateSelector(),
      const SizedBox(height: 12),
      _buildStatusBoard(),
      const SizedBox(height: 12),
      _buildPartySelectorCard(),
    ];

    final partyInfo = _buildPartyInfoCard();
    if (partyInfo is! SizedBox) {
      leftColumn
        ..add(const SizedBox(height: 10))
        ..add(partyInfo);
    }

    leftColumn.addAll([
      const SizedBox(height: 12),
      _buildDescriptionCard(),
      const SizedBox(height: 12),
      _buildReceiverCard(),
      const SizedBox(height: 12),
      _buildAttachmentsCard(),
    ]);

    // تم نقل المساعد السريع إلى أعلى الشاشة

    final accountLineCards = _accountLines
        .asMap()
        .entries
        .map((entry) => _buildAccountLineCard(entry.key))
        .toList();

    final List<Widget> rightColumn = [
      _buildAccountLinesHeader(),
      const SizedBox(height: 12),
      ...accountLineCards,
      if (accountLineCards.isNotEmpty) const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.add_circle_outline),
          label: const Text('إضافة سطر'),
          onPressed: _addNewLine,
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: Colors.white,
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _buildTotalsCard(),
      const SizedBox(height: 16),
      _buildNotesCard(),
      const SizedBox(height: 20),
      _buildSaveSection(accentColor),
    ];

    final Widget layoutContent = isWideLayout
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: leftColumn,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rightColumn,
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...leftColumn,
              const SizedBox(height: 24),
              ...rightColumn,
            ],
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: AppColors.deepGold,
        foregroundColor: Colors.white,
        elevation: 2,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeroHeader(
                        context,
                        isReceipt,
                        accentColor,
                        icon,
                        title,
                      ),
                      const SizedBox(height: 24),
                      layoutContent,
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  String _formatCash(double amount, {bool includeSymbol = true}) {
    final formatter = NumberFormat.currency(
      symbol: includeSymbol ? _currencySymbol : '',
      decimalDigits: _currencyDecimalPlaces,
    );
    final formatted = formatter.format(amount).replaceAll('\u00A0', ' ');
    return includeSymbol ? formatted : formatted.trim();
  }

  String _formatWeight(
    double amount, {
    int? decimals,
    bool includeUnit = true,
  }) {
    final effectiveDecimals = decimals ?? (amount.abs() < 1 ? 3 : 2);
    final formatted = amount.toStringAsFixed(effectiveDecimals);
    return includeUnit ? '$formatted جم' : formatted;
  }
}
