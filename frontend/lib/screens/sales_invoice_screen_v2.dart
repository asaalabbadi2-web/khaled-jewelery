import 'package:flutter/material.dart';
import 'package:flutter/services.dart';  // 🆕 للـ FilteringTextInputFormatter
import 'package:mobile_scanner/mobile_scanner.dart';
import '../api_service.dart';
import '../theme/app_theme.dart';
import '../models/safe_box_model.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/auth_provider.dart';
import 'add_customer_screen.dart';
import '../widgets/invoice_type_banner.dart';
import 'settings_screen_enhanced.dart';
import '../utils/arabic_number_formatter.dart';
import 'invoice_print_screen.dart';

enum _PreSaveDecision { cancel, proceed, proceedSuppressWarning }

/// شاشة فاتورة البيع - النسخة الهجينة المحسّنة
/// تجمع بين Smart Input (Progressive) و DataTable (Professional)
class SalesInvoiceScreenV2 extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> customers;

  const SalesInvoiceScreenV2({
    super.key,
    required this.items,
    required this.customers,
  });

  @override
  State<SalesInvoiceScreenV2> createState() => _SalesInvoiceScreenV2State();
}

class _SalesInvoiceScreenV2State extends State<SalesInvoiceScreenV2> {
  // ==================== State Variables ====================
  final _smartInputController = TextEditingController();
  final _smartInputFocus = FocusNode();
  final _customAmountController = TextEditingController(); // 🆕 للمبلغ المخصص

  // Customer
  int? _selectedCustomerId;

  // Office / Branch (Dimensions)
  List<Map<String, dynamic>> _branches = [];
  bool _isLoadingBranches = false;
  String? _branchesLoadingError;
  int? _selectedBranchId;

  // Items List
  final List<InvoiceItem> _items = [];
  List<Map<String, dynamic>> _availableItems = [];
  bool _isLoadingItems = false;
  String? _itemsLoadingError;

  // Categories (for category-only invoice lines)
  List<Map<String, dynamic>> _categories = [];
  bool _isLoadingCategories = false;
  String? _categoriesLoadingError;

  // Gold Price & Settings
  double _goldPrice24k = 0.0;

  // Settings - accessible throughout the class
  late SettingsProvider _settingsProvider;

  // Payment - 🆕 وسائل دفع متعددة
  List<Map<String, dynamic>> _paymentMethods = [];
  final List<PaymentEntry> _payments = []; // 🆕 قائمة الدفعات المadded
  int? _selectedPaymentMethodId; // للـ Dropdown

  // 🆕 Gold barter (scrap) inside payments
  bool _enableBarter = false;
  final List<_BarterLine> _barterLines = [];
  // 🆕 Barter gold deposit safe (when employee has no linked gold safe)
  List<SafeBoxModel> _barterGoldDepositSafeBoxes = [];
  int? _selectedBarterGoldDepositSafeBoxId;
  bool _isLoadingBarterGoldDepositSafeBoxes = false;

  // Safe Boxes - 🆕 الخزائن المتاحة للدفع
  List<SafeBoxModel> _safeBoxes = [];
  int? _selectedSafeBoxId; // الخزينة المختارة للدفعة الحالية
  bool _showAdvancedPaymentOptions = false; // 🎯 للتحكم في إظهار الخزائن

  // Gold Costing Snapshot (Moving Average)
  bool _didBootstrapCosting = false;
  bool _isLoadingCosting = false;
  String? _costingError;
  double _avgGoldCostPerMainGram = 0.0;
  double _avgManufacturingCostPerMainGram = 0.0;
  double _avgTotalCostPerMainGram = 0.0;
  double _inventoryWeightMain = 0.0;
  String? _costingMethod;
  DateTime? _costingLastUpdated;

  double _invoiceWeightMain = 0.0;
  double _invoiceCostGoldComponent = 0.0;
  double _invoiceCostManufacturingComponent = 0.0;
  double _invoiceCostTotal = 0.0;

  void _resetAfterSave() {
    setState(() {
      _selectedCustomerId = null;
      _items.clear();
      _payments.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null;
      _showAdvancedPaymentOptions = false;
      _smartInputController.clear();
      _customAmountController.clear();

      _enableBarter = false;
      for (final line in _barterLines) {
        line.dispose();
      }
      _barterLines.clear();
      _barterGoldDepositSafeBoxes = [];
      _selectedBarterGoldDepositSafeBoxId = null;
      _isLoadingBarterGoldDepositSafeBoxes = false;

      _invoiceWeightMain = 0.0;
      _invoiceCostGoldComponent = 0.0;
      _invoiceCostManufacturingComponent = 0.0;
      _invoiceCostTotal = 0.0;
    });
    _smartInputFocus.requestFocus();
  }

  Future<void> _loadBarterGoldDepositSafeBoxesIfNeeded() async {
    if (_isLoadingBarterGoldDepositSafeBoxes) return;

    final employeeGoldSafesEnabled =
        _settingsProvider.settings['employee_gold_safes_enabled'] == true;
    if (!employeeGoldSafesEnabled) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final employeeGoldSafeId =
        authProvider.currentUser?.employee?.goldSafeBoxId;

    // If the employee has a linked gold safe, backend will deposit there.
    if (employeeGoldSafeId != null) return;

    setState(() {
      _isLoadingBarterGoldDepositSafeBoxes = true;
    });

    try {
      final apiService = ApiService();
      final all = await apiService.getSafeBoxes();
      final goldBoxes = all
          .where((b) => b.safeType == 'gold' && b.id != null && b.isActive)
          .toList();

      int? picked = _selectedBarterGoldDepositSafeBoxId;
      if (picked != null && goldBoxes.any((b) => b.id == picked)) {
        // keep
      } else {
        final mainScrapIdRaw =
            _settingsProvider.settings['main_scrap_gold_safe_box_id'];
        final mainScrapId = mainScrapIdRaw is int
            ? mainScrapIdRaw
            : int.tryParse(mainScrapIdRaw?.toString() ?? '');
        if (mainScrapId != null && goldBoxes.any((b) => b.id == mainScrapId)) {
          picked = mainScrapId;
        } else {
          picked = goldBoxes.isNotEmpty ? goldBoxes.first.id : null;
        }
      }

      if (!mounted) return;
      setState(() {
        _barterGoldDepositSafeBoxes = goldBoxes;
        _selectedBarterGoldDepositSafeBoxId = picked;
        _isLoadingBarterGoldDepositSafeBoxes = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingBarterGoldDepositSafeBoxes = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _availableItems = widget.items
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (_availableItems.isEmpty) {
      _loadAvailableItems();
    }
    _loadSettings();
    _loadBranches();
    _loadPaymentMethods(); // 🆕 جلب وسائل الدفع
    _smartInputFocus.requestFocus();
  }

  @override
  void didUpdateWidget(covariant SalesInvoiceScreenV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.items, oldWidget.items)) {
      _availableItems = widget.items
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (_availableItems.isEmpty && !_isLoadingItems) {
        _loadAvailableItems();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settingsProvider = Provider.of<SettingsProvider>(context, listen: false);
    if (!_didBootstrapCosting) {
      _didBootstrapCosting = true;
      _loadGoldCostingSnapshot();
    }
  }

  @override
  void dispose() {
    _smartInputController.dispose();
    _smartInputFocus.dispose();
    _customAmountController.dispose(); // 🆕
    for (final line in _barterLines) {
      line.dispose();
    }
    super.dispose();
  }

  // ==================== Data Loading ====================
  Future<void> _loadSettings() async {
    try {
      final apiService = ApiService();
      final priceData = await apiService.getGoldPrice();
      if (!mounted) return;
      setState(() {
        _goldPrice24k = _parseDouble(priceData['price_24k']);
      });
    } catch (e) {
      _showError('فشل تحميل سعر الذهب: $e');
    }
  }

  Future<void> _loadBranches() async {
    if (_isLoadingBranches) return;
    setState(() {
      _isLoadingBranches = true;
      _branchesLoadingError = null;
    });

    try {
      final apiService = ApiService();
      final raw = await apiService.getBranches(activeOnly: true);
      if (!mounted) return;

      final branches = raw
          .whereType<Map>()
          .map((b) => Map<String, dynamic>.from(b))
          .toList();

      setState(() {
        _branches = branches;
        if (_selectedBranchId == null && _branches.length == 1) {
          _selectedBranchId = _parseInt(_branches.first['id']);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _branchesLoadingError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingBranches = false;
        });
      }
    }
  }

  int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  Future<void> _loadAvailableItems() async {
    if (_isLoadingItems) return;
    setState(() {
      _isLoadingItems = true;
      _itemsLoadingError = null;
    });

    try {
      final apiService = ApiService();
      final fetched = await apiService.getItems(inStockOnly: true);
      final normalized = fetched
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (mounted) {
        setState(() {
          _availableItems = normalized;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _itemsLoadingError = 'فشل تحميل الأصناف: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingItems = false;
        });
      }
    }
  }

  // 🆕 جلب وسائل الدفع النشطة
  Future<void> _loadPaymentMethods() async {
    try {
      final apiService = ApiService();
      final methods = await apiService
          .getActivePaymentMethods(); // ✅ استخدام getActivePaymentMethods بدلاً من getPaymentMethods
      if (!mounted) return;

      final normalizedMethods = methods
          .whereType<Map<String, dynamic>>()
          .map<Map<String, dynamic>>((method) {
            final map = Map<String, dynamic>.from(method);
            final id = _parseInt(map['id']);
            final commission = _parseDouble(map['commission_rate']);
            final settlement = _parseInt(map['settlement_days']) ?? 0;
            final displayOrder = _parseInt(map['display_order']) ?? 999;

            return {
              ...map,
              'id': id,
              'commission_rate': commission,
              'settlement_days': settlement,
              'display_order': displayOrder,
            };
          })
          .where((method) => method['id'] != null)
          .toList();

      normalizedMethods.sort((a, b) {
        final aOrder = a['display_order'] as int;
        final bOrder = b['display_order'] as int;
        return aOrder.compareTo(bOrder);
      });

      setState(() {
        _paymentMethods = normalizedMethods;

        if (_paymentMethods.isNotEmpty) {
          final defaultMethod = _paymentMethods.firstWhere(
            (m) => (m['name'] ?? '').toString().trim() == 'نقداً',
            orElse: () => _paymentMethods.first,
          );
          _selectedPaymentMethodId = defaultMethod['id'] as int?;
        } else {
          _selectedPaymentMethodId = null;
        }
      });

      // 🆕 تحميل الخزائن عند اختيار طريقة الدفع
      if (_selectedPaymentMethodId != null) {
        await _loadSafeBoxesForPaymentMethod(_selectedPaymentMethodId!);
      }
    } catch (e) {
      _showError('فشل تحميل وسائل الدفع: $e');
    }
  }

  // 🆕 تحميل الخزائن بناءً على طريقة الدفع
  Future<void> _loadSafeBoxesForPaymentMethod(int paymentMethodId) async {
    try {
      final method = _paymentMethods.firstWhere(
        (m) => m['id'] == paymentMethodId,
        orElse: () => {},
      );

      if (method.isEmpty) return;

      final paymentType = method['payment_type'] as String?;
      if (paymentType == null) return;

      // Receivable methods represent on-account settlement; no safe box should be required.
      if (paymentType == 'receivable') {
        if (!mounted) return;
        setState(() {
          _safeBoxes = [];
          _selectedSafeBoxId = null;
          _showAdvancedPaymentOptions = false;
        });
        return;
      }

      final defaultSafeBoxId = method['default_safe_box_id'];

      final apiService = ApiService();
      final allBoxes = await apiService.getSafeBoxes();
      List<SafeBoxModel> boxes;

      // ✅ قواعد التوافق (الأفضل والمعمول به غالباً):
      // - cash => خزائن نقدية فقط
      // - باقي الأنواع (بطاقات/BNPL/محافظ/تحويل) => خزائن بنكية (وأحياناً شيكات)
      final isCash = paymentType == 'cash';
      final isCheck = paymentType == 'check';
      final isBankLike = !isCash;

      switch (paymentType) {
        case 'cash':
          boxes = allBoxes.where((box) => box.safeType == 'cash').toList();
          break;
        default:
          if (isCheck) {
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'bank' || box.safeType == 'check',
                )
                .toList();
          } else if (isBankLike) {
            // Cards/BNPL/wallets commonly settle later => allow clearing + bank.
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'bank' || box.safeType == 'clearing',
                )
                .toList();
          } else {
            boxes = allBoxes
                .where(
                  (box) => box.safeType == 'cash' || box.safeType == 'bank',
                )
                .toList();
          }
      }

      if (!mounted) return;

      setState(() {
        _safeBoxes = boxes;
        // اختيار الخزينة الافتراضية
        if (_safeBoxes.isNotEmpty) {
          SafeBoxModel? picked;

          // If employee cash safes are enabled, default cash payments to the
          // logged-in employee cash safe (when available).
          if (isCash) {
            try {
              final employeeCashSafesEnabled =
                  _settingsProvider.settings['employee_cash_safes_enabled'] ==
                      true;
              if (employeeCashSafesEnabled) {
                final authProvider =
                    Provider.of<AuthProvider>(context, listen: false);
                final employeeCashSafeId =
                    authProvider.currentUser?.employee?.cashSafeBoxId;
                if (employeeCashSafeId != null) {
                  picked = _safeBoxes.firstWhere(
                    (box) => box.id == employeeCashSafeId,
                    orElse: () => _safeBoxes.first,
                  );
                }
              }
            } catch (_) {
              // ignore and fall back to the standard selection logic
            }
          }

          final defId = defaultSafeBoxId is int
              ? defaultSafeBoxId
              : int.tryParse(defaultSafeBoxId?.toString() ?? '');

          if (picked == null && defId != null) {
            picked = _safeBoxes.firstWhere(
              (box) => box.id == defId,
              orElse: () => _safeBoxes.first,
            );
          } else if (picked == null) {
            // Prefer clearing safes when available for non-cash methods.
            final clearingBoxes = _safeBoxes
                .where((box) => (box.safeType).toLowerCase() == 'clearing')
                .toList();
            if (clearingBoxes.isNotEmpty) {
              picked = clearingBoxes.firstWhere(
                (box) => box.isDefault == true,
                orElse: () => clearingBoxes.first,
              );
            } else {
            picked = _safeBoxes.firstWhere(
              (box) => box.isDefault == true,
              orElse: () => _safeBoxes.first,
            );
            }
          }

          _selectedSafeBoxId = picked.id;
        } else {
          _selectedSafeBoxId = null;
        }
      });
    } catch (e) {
      _showError('فشل تحميل الخزائن: $e');
    }
  }

  // ==================== Gold Costing Snapshot ====================
  Future<void> _loadGoldCostingSnapshot({bool showFeedback = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoadingCosting = true;
      if (!showFeedback) {
        _costingError = null;
      }
    });

    try {
      final apiService = ApiService();
      final response = await apiService.getGoldCostingSnapshot();
      final snapshot = Map<String, dynamic>.from(response['snapshot'] ?? {});
      final config = Map<String, dynamic>.from(response['config'] ?? {});

      final avgGold = _parseDouble(snapshot['avg_gold']);
      final avgManufacturing = _parseDouble(snapshot['avg_manufacturing']);
      final avgTotal = _parseDouble(snapshot['avg_total']);
      final inventoryWeight = _parseDouble(config['total_inventory_weight']);
      final costingMethod = config['costing_method']?.toString();
      final updatedAt = _parseDateTime(config['last_updated']);

      if (!mounted) return;
      setState(() {
        _avgGoldCostPerMainGram = avgGold;
        _avgManufacturingCostPerMainGram = avgManufacturing;
        _avgTotalCostPerMainGram = avgTotal;
        _inventoryWeightMain = inventoryWeight;
        _costingMethod = costingMethod;
        _costingLastUpdated = updatedAt;
        _costingError = null;
      });

      _applySnapshotToItems();

      if (showFeedback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('✅ تم تحديث متوسط التكلفة المتحرك'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _costingError = 'تعذر تحميل متوسط التكلفة: $e';
      });
      if (showFeedback) {
        _showError('فشل تحديث متوسط التكلفة: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCosting = false;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _recomputeGoldCosting() async {
    final confirm =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('إعادة بناء متوسط التكلفة'),
              content: const Text(
                'سيتم إعادة احتساب متوسط التكلفة المتحرك بناءً على فواتير الشراء المسجلة. '
                'قد يستغرق ذلك بعض الوقت حسب حجم البيانات. هل تريد المتابعة؟',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.warning,
                  ),
                  child: const Text('متابعة'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirm) return;

    try {
      if (mounted) {
        setState(() {
          _isLoadingCosting = true;
        });
      }
      final apiService = ApiService();
      await apiService.recomputeGoldCosting();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('تمت إعادة بناء متوسط التكلفة بنجاح'),
          backgroundColor: AppColors.success,
        ),
      );
      await _loadGoldCostingSnapshot();
    } catch (e) {
      _showError('فشل إعادة بناء المتوسط: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingCosting = false;
        });
      }
    }
  }

  void _applySnapshotToItems() {
    if (_items.isEmpty) {
      _recomputeCostingPreview();
      return;
    }
    for (final item in _items) {
      item.updateCostingSnapshot(
        avgGoldPerMainGram: _avgGoldCostPerMainGram,
        avgManufacturingPerMainGram: _avgManufacturingCostPerMainGram,
      );
    }
    _recomputeCostingPreview();
  }

  void _recomputeCostingPreview() {
    final totalWeightMain = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weightInMainKarat,
    );
    final goldComponent = totalWeightMain * _avgGoldCostPerMainGram;
    final manufacturingComponent =
        totalWeightMain * _avgManufacturingCostPerMainGram;
    final totalCost = goldComponent + manufacturingComponent;

    if (!mounted) return;
    setState(() {
      _invoiceWeightMain = totalWeightMain;
      _invoiceCostGoldComponent = goldComponent;
      _invoiceCostManufacturingComponent = manufacturingComponent;
      _invoiceCostTotal = totalCost;
    });
  }

  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.parse(value.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'لم يتم التحديث بعد';
    final date = value;
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    final hh = date.hour.toString().padLeft(2, '0');
    final mm = date.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  String _formatWeight(double grams) {
    if (grams.abs() >= 1000) {
      return '${(grams / 1000).toStringAsFixed(3)} كجم';
    }
    return '${grams.toStringAsFixed(3)} جم';
  }

  String _formatCurrency(double amount) {
    return '${amount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}';
  }

  String get _costingMethodLabel {
    final method = (_costingMethod ?? 'moving_average').toLowerCase();
    switch (method) {
      case 'moving_average':
        return 'متوسط متحرك';
      case 'fifo':
        return 'الوارد أولاً (FIFO)';
      default:
        return method.isEmpty ? 'غير محدد' : method;
    }
  }

  // ignore: unused_element
  Widget _buildCostingMetricTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
    Color? accentColor,
  }) {
    final colorScheme = theme.colorScheme;
    final accent = accentColor ?? colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
        color: accent.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.15 : 0.1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.08 : 0.85,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactMetric(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
    Color accentColor,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: accentColor.withValues(alpha: isDark ? 0.15 : 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.9),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accentColor.withValues(alpha: 0.8),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCostingInfoChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.25 : 0.7,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCostingDetailRow(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String value,
  }) {
    final colorScheme = theme.colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  // 🆕 إضافة دفعة جديدة
  void _addPayment({double? customAmount}) {
    if (_selectedPaymentMethodId == null) {
      _showError('اختر وسيلة الدفع');
      return;
    }

    final method = _paymentMethods.firstWhere(
      (m) => m['id'] == _selectedPaymentMethodId,
    );

    final total = _calculateGrandTotal();
    final barterTotal = _barterTotal;
    if (barterTotal > total + 0.01) {
      _showError('قيمة المقايضة أكبر من إجمالي الفاتورة');
      return;
    }
    final alreadyPaid = _payments.fold<double>(0, (sum, p) => sum + p.amount);
    final remaining = double.parse(
      (total - alreadyPaid - barterTotal).toStringAsFixed(2),
    ); // تقريب لتجنب مشاكل الدقة

    if (remaining <= 0.01) {
      // استخدام threshold بدلاً من 0
      _showError('تم دفع المبلغ بالكامل');
      return;
    }

    // استخدام المبلغ المخصص أو المتبقي
    final amount = customAmount ?? remaining;

    if (amount > remaining + 0.01) {
      // إضافة tolerance صغير
      _showError(
        'المبلغ أكبر من المتبقي (${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbol})',
      );
      return;
    }

    if (amount <= 0) {
      _showError('المبلغ يجب أن يكون أكبر من صفر');
      return;
    }

    // ✅ استخدام commission_rate بدلاً من commission
    final rate = (method['commission_rate'] ?? 0.0) is String
        ? double.tryParse(method['commission_rate'].toString()) ?? 0.0
        : (method['commission_rate'] ?? 0.0).toDouble();

    // تقريب العمولة لمنزلتين عشريتين لتجنب مشاكل الدقة
    final commission = double.parse((amount * (rate / 100)).toStringAsFixed(2));
    // حساب ضريبة القيمة المضافة على العمولة بحسب الإعدادات
    final commissionVat = double.parse(
      (commission * _settingsProvider.taxRate).toStringAsFixed(2),
    );
    // الصافي = المبلغ - العمولة - ضريبة العمولة
    final net = double.parse(
      (amount - commission - commissionVat).toStringAsFixed(2),
    );

    setState(() {
      _payments.add(
        PaymentEntry(
          paymentMethodId: method['id'],
          paymentMethodName: method['name'],
          amount: amount,
          commissionRate: rate,
          commissionAmount: commission,
          commissionVat: commissionVat,
          netAmount: net,
          settlementDays: method['settlement_days'] ?? 0,
          safeBoxId: _selectedSafeBoxId, // 🆕 إضافة معرف الخزينة
        ),
      );

      // إعادة تعيين الحقول
      _customAmountController.clear();
      _selectedPaymentMethodId = null;
      _selectedSafeBoxId = null; // 🆕 إعادة تعيين الخزينة
      _safeBoxes = []; // 🆕 مسح قائمة الخزائن
    });
  }

  // 🆕 حذف دفعة
  void _removePayment(int index) {
    setState(() {
      _payments.removeAt(index);
    });
  }

  // 🆕 حساب إجماليات الدفعات
  double get _totalPayments =>
      _payments.fold<double>(0, (sum, p) => sum + p.amount);
  double get _totalCommission =>
      _payments.fold<double>(0, (sum, p) => sum + p.commissionAmount);
  double get _totalCommissionVAT =>
      _payments.fold<double>(0, (sum, p) => sum + p.commissionVat);
  double get _totalNet =>
      _payments.fold<double>(0, (sum, p) => sum + p.netAmount);

  double get _barterTotal {
    if (!_enableBarter) return 0.0;
    final total = _barterLines.fold<double>(
      0.0,
      (sum, line) => sum + line.value(_parseDouble, _goldPrice24k),
    );
    return double.parse(total.toStringAsFixed(2));
  }

  double get _barterTotalWeightNet {
    if (!_enableBarter) return 0.0;
    return _barterLines.fold<double>(
      0.0,
      (sum, line) => sum + line.netWeight(_parseDouble),
    );
  }

  void _ensureAtLeastOneBarterLine() {
    if (_barterLines.isNotEmpty) return;
    _barterLines.add(_BarterLine(karat: 21));
  }

  void _addBarterLine() {
    setState(() {
      _barterLines.add(_BarterLine(karat: 21));
    });
  }

  void _removeBarterLine(int index) {
    setState(() {
      final line = _barterLines.removeAt(index);
      line.dispose();
      if (_barterLines.isEmpty) {
        _enableBarter = false;
      }
    });
  }

  double get _remainingAmount {
    final remaining = _calculateGrandTotal() - _totalPayments - _barterTotal;
    // تجاهل الفروقات الصغيرة (أقل من 0.01 ريال)
    return remaining.abs() < 0.01 ? 0.0 : remaining;
  }

  // ==================== Smart Input Processing ====================
  Map<String, dynamic>? _findItemBySmartInput(String input) {
    final normalizedInput = input.toLowerCase();
    final strategies = <bool Function(Map<String, dynamic>)>[
      (item) {
        final barcode = item['barcode']?.toString().toLowerCase();
        return barcode != null && barcode == normalizedInput;
      },
      (item) {
        final code = item['item_code']?.toString().toLowerCase();
        return code != null && code == normalizedInput;
      },
      (item) {
        final name = item['name']?.toString().toLowerCase();
        return name?.contains(normalizedInput) ?? false;
      },
    ];

    for (final matches in strategies) {
      for (final item in _availableItems) {
        if (matches(item)) {
          return item;
        }
      }
    }

    return null;
  }

  Future<void> _processSmartInput(String input) async {
    final normalizedInput = input.trim();
    if (normalizedInput.isEmpty) return;

    if (_availableItems.isEmpty) {
      await _loadAvailableItems();
      if (_availableItems.isEmpty) {
        final message =
            _itemsLoadingError ??
            'قائمة الأصناف غير متاحة حالياً. حاول مجدداً.';
        _showError(message);
        return;
      }
    }

    try {
      final foundItem = _findItemBySmartInput(normalizedInput);

      if (foundItem != null && foundItem.isNotEmpty) {
        await _addItemFromData(foundItem);
        _smartInputController.clear();
        _smartInputFocus.requestFocus();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ تمت إضافة: ${foundItem['name']}'),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        _showError('⚠️ لم يتم العثور على الصنف');
      }
    } catch (e) {
      _showError('خطأ في البحث: $e');
    }
  }

  Future<void> _addItemFromData(Map<String, dynamic> itemData) async {
    if (!mounted) return;

    // الحصول على الإعدادات بشكل آمن
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    // تحديث سعر الذهب قبل إضافة الصنف
    try {
      final apiService = ApiService();
      final priceData = await apiService.getGoldPrice();
      final newPrice = _parseDouble(priceData['price_24k']);
      if (newPrice > 0) {
        if (mounted) {
          setState(() {
            _goldPrice24k = newPrice;
          });
        }
      }
    } catch (_) {
      // الاستمرار باستخدام السعر الحالي في حال فشل التحديث
    }

    // 🆕 محاولة جلب العيار من التصنيف إذا كان موجوداً
    double karat = _parseDouble(itemData['karat']);
    final categoryId = _parseInt(itemData['category_id']);
    if (karat <= 0) {
      // إذا لم يكن للصنف عيار، نحاول استخدام عيار التصنيف
      if (categoryId != null) {
        try {
          await _ensureCategoriesLoaded();
          final category = _categories.firstWhere(
            (c) => _parseInt(c['id']) == categoryId,
            orElse: () => <String, dynamic>{},
          );
          if (category.isNotEmpty && category['karat'] != null) {
            karat = _parseDouble(category['karat']);
          }
        } catch (_) {
          // في حالة الفشل، نستخدم العيار الافتراضي
        }
      }
      // إذا لم ينجح أي من ما سبق، استخدم العيار الافتراضي
      if (karat <= 0) karat = settings.mainKarat.toDouble();
    }

    double wage = _parseDouble(itemData['wage']);

    // تحويل آمن للوزن
    double weight = _parseDouble(itemData['weight']);
    if (weight <= 0) weight = 10.0; // افتراضي إذا لم يكن موجود

    if (!mounted) return;

    final itemId = _parseInt(itemData['id']);
    String? categoryName = itemData['category_name'] as String?;
    if ((categoryName == null || categoryName.trim().isEmpty) &&
        categoryId != null) {
      try {
        await _ensureCategoriesLoaded();
        final category = _categories.firstWhere(
          (c) => _parseInt(c['id']) == categoryId,
          orElse: () => <String, dynamic>{},
        );
        final resolvedName = (category['name'] ?? '').toString().trim();
        if (resolvedName.isNotEmpty) {
          categoryName = resolvedName;
        }
      } catch (_) {
        // ignore
      }
    }

    setState(() {
      _items.add(
        InvoiceItem(
          id: itemId,
          name: itemData['name'] ?? '',
          barcode: itemData['barcode'] ?? '',
          karat: karat,
          weight: weight, // استخدام الوزن الفعلي من قاعدة البيانات
          wage: wage,
          categoryId: categoryId,
          categoryName: categoryName,
          goldPrice24k: _goldPrice24k,
          mainKarat: settings.mainKarat,
          taxRate: settings.taxRateForKarat(karat),
          avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
          avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
        ),
      );
    });

    _recomputeCostingPreview();
  }

  Future<void> _showManualItemDialog() async {
    if (!_settingsProvider.allowManualInvoiceItems) {
      _showError(
        'هذه الميزة معطلة من الإعدادات. فعّل خيار "السماح بإضافة صنف يدوي" أولاً.',
      );
      return;
    }

    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final barcodeController = TextEditingController();
    final countController = TextEditingController(text: '1');  // 🆕 عدد القطع
    final weightController = TextEditingController(text: '1.0');
    final wageController = TextEditingController(text: '0');
    final totalController = TextEditingController();

    weightController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: weightController.text.length,
    );
    wageController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: wageController.text.length,
    );
    int selectedKarat = _settingsProvider.mainKarat;

    double? tryParseOptionalDouble(String value) {
      final normalized = value.trim().replaceAll(',', '.');
      if (normalized.isEmpty) return null;
      return double.tryParse(normalized);
    }

    Map<String, dynamic>? manualData;

    if (!mounted) {
      nameController.dispose();
      barcodeController.dispose();
      weightController.dispose();
      wageController.dispose();
      totalController.dispose();
      return;
    }

    manualData = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submit() {
              if (!(formKey.currentState?.validate() ?? false)) {
                return;
              }

              final weight =
                  tryParseOptionalDouble(weightController.text) ?? 0;
              final wage = tryParseOptionalDouble(wageController.text) ?? 0;
              final count = int.tryParse(countController.text) ?? 1;
              final manualTotal = tryParseOptionalDouble(
                totalController.text,
              );

              Navigator.pop(dialogContext, {
                'name': nameController.text.trim(),
                'barcode': barcodeController.text.trim(),
                'count': count,
                'karat': selectedKarat.toDouble(),
                'weight': weight,
                'wage': wage,
                'total_with_tax': manualTotal,
              });
            }

            return AlertDialog(
              title: const Text('إضافة صنف يدوي'),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'اسم الصنف',
                          prefixIcon: Icon(Icons.label_outline),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'يرجى إدخال اسم الصنف';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: barcodeController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'الباركود / رقم الصنف (اختياري)',
                          prefixIcon: Icon(Icons.qr_code_2),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: countController,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'العدد (الكمية)',
                          prefixIcon: Icon(Icons.numbers),
                          helperText: 'عدد القطع لهذا الصنف',
                        ),
                        validator: (value) {
                          final count = int.tryParse(value ?? '');
                          if (count == null || count < 1) {
                            return 'أدخل عدداً صحيحاً أكبر من صفر';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: selectedKarat,
                        decoration: const InputDecoration(
                          labelText: 'العيار',
                          prefixIcon: Icon(Icons.diamond_outlined),
                        ),
                        items: const [18, 21, 22, 24]
                            .map(
                              (karat) => DropdownMenuItem<int>(
                                value: karat,
                                child: Text('عيار $karat'),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() => selectedKarat = value);
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: weightController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'الوزن بالجرام',
                          prefixIcon: Icon(Icons.scale),
                        ),
                        validator: (value) {
                          final parsed = tryParseOptionalDouble(value ?? '');
                          if (parsed == null || parsed <= 0) {
                            return 'أدخل وزناً صحيحاً أكبر من صفر';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: wageController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'أجرة المصنعية للجرام (اختياري)',
                          prefixIcon: Icon(Icons.handyman_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: totalController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          ArabicNumberTextInputFormatter(
                            allowDecimal: true,
                            allowNegative: false,
                          ),
                        ],
                        onFieldSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: 'الإجمالي مع الضريبة (اختياري)',
                          prefixIcon: const Icon(Icons.attach_money),
                          helperText:
                              'اترك الحقل فارغاً ليتم احتساب السعر تلقائياً',
                          suffixText: _settingsProvider.currencySymbol,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('إلغاء'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('إضافة'),
                  onPressed: submit,
                ),
              ],
            );
          },
        );
      },
    );

    // نتجنب التخلص المباشر من المتحكمات لأن عناصر الحوار قد تستدعي إطاراً إضافياً
    // بعد الإغلاق. تركها لجمع القمامة آمن للاستخدام المؤقت هنا.

    if (manualData == null) return;

    final manualItem = InvoiceItem(
      id: null,
      name: manualData['name'] as String? ?? 'صنف يدوي',
      barcode: manualData['barcode'] as String? ?? '',
      karat: _parseDouble(manualData['karat']),
      weight: _parseDouble(manualData['weight']),
      wage: _parseDouble(manualData['wage']),
      count: manualData['count'] as int? ?? 1,  // 🆕
      goldPrice24k: _goldPrice24k,
      mainKarat: _settingsProvider.mainKarat,
      taxRate: _settingsProvider.taxRateForKarat(
        _parseDouble(manualData['karat']),
      ),
      avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
      avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
    );

    final manualTotal = manualData['total_with_tax'];
    if (manualTotal is num && manualTotal > 0) {
      manualItem.setManualTotal(manualTotal.toDouble());
    }

    setState(() {
      _items.add(manualItem);
    });

    _recomputeCostingPreview();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('✅ تمت إضافة صنف يدوي إلى الفاتورة'),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  Future<void> _ensureCategoriesLoaded() async {
    if (_isLoadingCategories) return;
    if (_categories.isNotEmpty) return;

    setState(() {
      _isLoadingCategories = true;
      _categoriesLoadingError = null;
    });

    try {
      final api = ApiService();
      final raw = await api.getCategories();
      final parsed = raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      parsed.sort(
        (a, b) => ('${a['name'] ?? ''}').compareTo('${b['name'] ?? ''}'),
      );

      if (!mounted) return;
      setState(() {
        _categories = parsed;
        _isLoadingCategories = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _categories = [];
        _isLoadingCategories = false;
        _categoriesLoadingError = e.toString();
      });
    }
  }

  Future<void> _showCategoryLineDialog() async {
    await _ensureCategoriesLoaded();
    if (!mounted) return;

    if (_categories.isEmpty) {
      _showError(
        _categoriesLoadingError ??
            'لا توجد تصنيفات. أنشئ تصنيفاً أولاً من شاشة الأصناف.',
      );
      return;
    }

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (dialogContext) => _CategoryLineDialog(
        categories: _categories,
        mainKarat: _settingsProvider.mainKarat,
      ),
    );

    if (result == null || !mounted) return;

    final categoryId = result['categoryId'] as int?;
    final categoryName = result['categoryName'] as String? ?? '';
    final selectedKarat =
        result['karat'] as int? ?? _settingsProvider.mainKarat;
    final weight = result['weight'] as double? ?? 0;
    final wage = result['wage'] as double? ?? 0;

    if (categoryId == null || weight <= 0) return;

    setState(() {
      _items.add(
        InvoiceItem(
          id: null,
          name: categoryName.isNotEmpty ? categoryName : 'تصنيف',
          barcode: '',
          karat: selectedKarat.toDouble(),
          weight: weight,
          wage: wage,
          goldPrice24k: _goldPrice24k,
          mainKarat: _settingsProvider.mainKarat,
          taxRate: _settingsProvider.taxRateForKarat(selectedKarat.toDouble()),
          avgGoldCostPerMainGram: _avgGoldCostPerMainGram,
          avgManufacturingCostPerMainGram: _avgManufacturingCostPerMainGram,
          categoryId: categoryId,
          categoryName: categoryName,
        ),
      );
    });

    _recomputeCostingPreview();
  }

  Future<void> _showManualItemFeatureGuide() async {
    if (!mounted) return;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final shouldOpenSettings =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.info_outline, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'تفعيل الصنف اليدوي',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'لإضافة صنف يدوي يجب تفعيل الخيار من شاشة الإعدادات > الشركة والفواتير.',
                  ),
                  SizedBox(height: 8),
                  Text(
                    'بعد التفعيل سيظهر زر "صنف يدوي" دائماً داخل شاشة الفاتورة.',
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('لاحقاً'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.settings),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  label: const Text('فتح الإعدادات'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldOpenSettings || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const SettingsScreenEnhanced(initialTabIndex: 1),
      ),
    );
  }

  // ==================== Item Actions ====================
  void _updateItem(int index, String field, double value) {
    setState(() {
      final item = _items[index];
      bool requiresManualTargetRecalculation = false;

      switch (field) {
        case 'karat':
          item.karat = value;
          item.taxRate = _settingsProvider.taxRateForKarat(value);
          requiresManualTargetRecalculation = true;
          break;
        case 'weight':
          item.weight = value;
          requiresManualTargetRecalculation = true;
          break;
        case 'wage':
          item.wage = value;
          requiresManualTargetRecalculation = true;
          break;
        case 'total':
          item.setManualTotal(value);
          break;
      }

      if (requiresManualTargetRecalculation) {
        _recalculateManualTargetIfNeeded(item);
      }
    });

    _recomputeCostingPreview();
  }

  void _recalculateManualTargetIfNeeded(InvoiceItem item) {
    if (item.hasManualTotal) {
      _recalculateFieldsForTarget(item);
    }
  }

  // إعادة حساب الحقول للوصول للإجمالي المستهدف
  void _recalculateFieldsForTarget(InvoiceItem item) {
    final manualTarget = item.manualTargetTotal;
    if (!item.hasManualTotal || manualTarget == null) return;

    final targetNet = manualTarget / (1 + item.taxRate);
    final requiredProfit = targetNet - item.cost;
    item.profit = requiredProfit;
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
    });

    _recomputeCostingPreview();
  }

  // ==================== Auto Distribution ====================
  Future<void> _showAutoDistributeDialog() async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('توزيع تلقائي للمبلغ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'الإجمالي الحالي: ${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                final target = double.tryParse(controller.text);
                if (target != null && target > 0) {
                  _distributeAmount(target);
                  Navigator.pop(dialogContext);
                }
              },
              decoration: InputDecoration(
                labelText: 'المبلغ المستهدف',
                suffixText: _settingsProvider.currencySymbol,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final target = double.tryParse(controller.text);
              if (target != null && target > 0) {
                _distributeAmount(target);
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('توزيع'),
          ),
        ],
      ),
    );
  }

  void _distributeAmount(double targetTotal) {
    if (_items.isEmpty) return;

    // الخطوة 1: حساب إجمالي التكاليف
    final totalCosts = _items.fold<double>(0.0, (sum, item) => sum + item.cost);

    // الخطوة 2: حساب المبلغ بدون ضريبة
    final amountWithoutTax = targetTotal / (1 + _settingsProvider.taxRate);

    // الخطوة 3: حساب الربح المتاح للتوزيع
    final profitPool = amountWithoutTax - totalCosts;

    // الخطوة 4: حساب إجمالي الأوزان
    final totalWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );

    if (totalWeight == 0) return;

    // الخطوة 5: توزيع الربح حسب نسبة الوزن
    setState(() {
      for (var item in _items) {
        // 🔥 إزالة حالة التعديل اليدوي قبل التوزيع التلقائي
        item.clearManualTotal();

        // توزيع الربح بناءً على نسبة وزن الصنف من الوزن الكلي
        item.profit = (item.weight / totalWeight) * profitPool;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '✅ تم توزيع $targetTotal ${_settingsProvider.currencySymbol} على ${_items.length} صنف\n'
          'التكاليف: ${totalCosts.toStringAsFixed(2)} • الربح الموزع: ${profitPool.toStringAsFixed(2)}',
        ),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ==================== Submit Invoice ====================
  Future<void> _submitInvoice() async {
    if (_items.isEmpty) {
      _showError('يرجى إضافة أصناف للفاتورة');
      return;
    }

    if (_selectedBranchId == null) {
      _showError('يرجى اختيار الفرع لإكمال الفاتورة.');
      return;
    }

    final allowPartialPayments = _settingsProvider.allowPartialInvoicePayments;

    // 🆕 Barter validation
    final barterTotal = _barterTotal;
    if (_enableBarter) {
      if (_barterLines.isEmpty) {
        _showError('يرجى إضافة سطر مقايضة واحد على الأقل');
        return;
      }

      for (final line in _barterLines) {
        if (!{18, 21, 22, 24}.contains(line.karat)) {
          _showError('يرجى اختيار عيار صحيح للمقايضة');
          return;
        }

        final standing = line.standingWeight(_parseDouble);
        final stones = line.stonesWeight(_parseDouble);
        final net = line.netWeight(_parseDouble);
        final enteredPrice = line.pricePerGram(_parseDouble);
        final effectivePrice = line.effectivePricePerGram(
          _parseDouble,
          _goldPrice24k,
        );

        if (standing <= 0) {
          _showError('يرجى إدخال الوزن القائم لكل سطر مقايضة');
          return;
        }
        if (stones < 0) {
          _showError('وزن الفصوص لا يمكن أن يكون سالباً');
          return;
        }
        if (stones > standing + 1e-9) {
          _showError('وزن الفصوص لا يمكن أن يتجاوز الوزن القائم');
          return;
        }
        if (net <= 0) {
          _showError('الصافي يجب أن يكون أكبر من صفر');
          return;
        }
        if (enteredPrice <= 0 && _goldPrice24k <= 0) {
          _showError('يرجى إدخال سعر الذهب أو سعر شراء/جرام للمقايضة');
          return;
        }
        if (effectivePrice <= 0) {
          _showError('سعر الجرام غير صالح للمقايضة');
          return;
        }
      }
    }

    // 🆕 التحقق من الدفع (مع دعم البيع الآجل عند تفعيل الإعداد)
    final total = _calculateGrandTotal();
    if (barterTotal > total + 0.01) {
      _showError('قيمة المقايضة أكبر من إجمالي الفاتورة');
      return;
    }

    final totalPaidCash = _totalPayments;
    final totalPaid = totalPaidCash + barterTotal;
    final remaining = total - totalPaid;

    final totalCost = _items.fold<double>(0.0, (sum, item) => sum + item.cost);
    final paidBelowCost = totalPaid + 0.01 < totalCost;
    final saleBelowCost = total + 0.01 < totalCost;

    var suppressPostSaveApprovalWarning = false;
    var shownDeferredDialog = false;

    final hasAnySettlement = _payments.isNotEmpty || barterTotal > 0.01;

    if (!hasAnySettlement) {
      if (!allowPartialPayments) {
        _showError('يرجى إضافة وسيلة دفع واحدة على الأقل');
        return;
      }

      final proceed = await _confirmDeferredInvoiceSave(
        total: total,
        totalPaid: totalPaid,
        remaining: total,
        totalCost: totalCost,
        paidBelowCost: paidBelowCost,
        saleBelowCost: saleBelowCost,
      );
      shownDeferredDialog = true;
      if (proceed == _PreSaveDecision.cancel) return;
      suppressPostSaveApprovalWarning =
          proceed == _PreSaveDecision.proceedSuppressWarning;
    } else {
      // منع الدفع الزائد
      if (remaining < -0.01) {
        _showError('مجموع الدفعات أكبر من إجمالي الفاتورة');
        return;
      }

      if (remaining > 0.01) {
        if (!allowPartialPayments) {
          _showError(
            'المبلغ المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}\nيرجى إكمال الدفع',
          );
          return;
        }

        final proceed = await _confirmDeferredInvoiceSave(
          total: total,
          totalPaid: totalPaid,
          remaining: remaining,
          totalCost: totalCost,
          paidBelowCost: paidBelowCost,
          saleBelowCost: saleBelowCost,
        );
        shownDeferredDialog = true;
        if (proceed == _PreSaveDecision.cancel) return;
        suppressPostSaveApprovalWarning =
            proceed == _PreSaveDecision.proceedSuppressWarning;
      }
    }

    if (!shownDeferredDialog &&
        totalCost > 0 &&
        (paidBelowCost || saleBelowCost)) {
      final decision = await _confirmBelowCostInvoiceSave(
        total: total,
        totalPaid: totalPaid,
        totalCost: totalCost,
        paidBelowCost: paidBelowCost,
        saleBelowCost: saleBelowCost,
      );
      if (decision == _PreSaveDecision.cancel) return;
      suppressPostSaveApprovalWarning =
          decision == _PreSaveDecision.proceedSuppressWarning;
    }

    try {
      final apiService = ApiService();

      // إذا لم يتم اختيار عميل، استخدم عميل "نقدي" (ID = 1)
      int customerId = _selectedCustomerId ?? 1;

      Map<String, dynamic>? cashCustomer = _findCashCustomer();

      if (_selectedCustomerId == null) {
        final proceedWithCash = await _confirmUseCashCustomer();
        if (!proceedWithCash) {
          _showError(
            'يرجى اختيار عميل لإكمال الفاتورة أو الاستمرار مع العميل النقدي.',
          );
          return;
        }

        cashCustomer ??= await _getOrCreateCashCustomer(promptIfMissing: false);
        if (cashCustomer == null || cashCustomer['id'] == null) {
          _showError(
            'لا يوجد عميل نقدي متاح. يرجى إنشاء عميل نقدي أو اختيار عميل محدد للمتابعة.',
          );
          return;
        }

        customerId = cashCustomer['id'];
        if (mounted) {
          setState(() {
            _selectedCustomerId = customerId;
          });
        }
      }

      // حساب الإجماليات
      final totalAmount = _calculateGrandTotal();
      final totalWeight = _items.fold<double>(
        0.0,
        (sum, item) => sum + item.weight,
      );
      final totalCost = _items.fold<double>(
        0.0,
        (sum, item) => sum + item.cost,
      );
      final totalTax = _items.fold<double>(0.0, (sum, item) => sum + item.tax);

      if (!mounted) return;

      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final sellerName = authProvider.fullName;
      final sellerEmployeeId = authProvider.currentUser?.employeeId;

      final invoiceData = {
        'customer_id': customerId,
        'branch_id': _selectedBranchId,
        'invoice_type': 'بيع',
        'transaction_type': 'sell',
        if (sellerName.isNotEmpty) 'posted_by': sellerName,
        if (sellerEmployeeId != null) 'employee_id': sellerEmployeeId,
        'date': DateTime.now().toIso8601String(),
        'total': totalAmount,
        'total_weight': totalWeight,
        'total_cost': totalCost,
        'total_tax': totalTax,
        if (_enableBarter && barterTotal > 0.01) 'barter_total': barterTotal,
        'payments': _payments
            .map((p) => p.toJson())
            .toList(), // 🆕 إرسال array من الدفعات
        'amount_paid': _totalPayments, // 🆕 إجمالي المدفوع
        'items': _items.map((item) => item.toJson()).toList(),
      };

      final response = await apiService.addInvoice(invoiceData);

      final approvalRequired = response['approval_required'] == true;
      final approvalReasons = (response['approval_reasons'] is List)
          ? List<String>.from(response['approval_reasons'])
          : <String>[
              if (response['approval_reason'] != null)
                response['approval_reason'].toString(),
            ];

      String? approvalWarning;
      if (approvalRequired && !suppressPostSaveApprovalWarning) {
        final parts = <String>[];
        if (approvalReasons.contains('below_cost')) {
          final below = (response['below_cost'] is Map)
              ? Map<String, dynamic>.from(response['below_cost'])
              : const <String, dynamic>{};
          final saleExVat = (below['effective_sale_cash_ex_vat'] is num)
              ? (below['effective_sale_cash_ex_vat'] as num).toDouble()
              : double.tryParse(
                      '${below['effective_sale_cash_ex_vat'] ?? 0}',
                    ) ??
                    0.0;
          final costCash = (below['cost_cash'] is num)
              ? (below['cost_cash'] as num).toDouble()
              : double.tryParse('${below['cost_cash'] ?? 0}') ?? 0.0;
          final profitEst = (below['profit_cash_estimate'] is num)
              ? (below['profit_cash_estimate'] as num).toDouble()
              : double.tryParse('${below['profit_cash_estimate'] ?? 0}') ?? 0.0;
          parts.add(
            '⚠️ بيع تحت التكلفة: صافي ${saleExVat.toStringAsFixed(2)} مقابل تكلفة ${costCash.toStringAsFixed(2)} (فرق ${profitEst.toStringAsFixed(2)})',
          );
        }
        if (approvalReasons.contains('large_discount')) {
          final discountPct = (response['discount_pct'] is num)
              ? (response['discount_pct'] as num).toDouble()
              : double.tryParse('${response['discount_pct'] ?? 0}') ?? 0.0;
          final thresholdPct = (response['threshold_pct'] is num)
              ? (response['threshold_pct'] as num).toDouble()
              : double.tryParse('${response['threshold_pct'] ?? 0}') ?? 0.0;
          parts.add(
            '⚠️ خصم كبير: ${discountPct.toStringAsFixed(2)}% (الحد ${thresholdPct.toStringAsFixed(2)}%)',
          );
        }

        approvalWarning = parts.isNotEmpty
            ? '${parts.join('\n')}\nسيتم حفظ الفاتورة لكن لن تُرحَّل حتى اعتماد المدير.'
            : '⚠️ تم حفظ الفاتورة لكن تحتاج اعتماد مدير قبل الترحيل.';

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(approvalWarning),
              backgroundColor: Colors.orange.shade800,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }

      // 🆕 Auto-create linked scrap purchase invoice for barter (offset)
      if (_enableBarter && barterTotal > 0.01) {
        final saleInvoiceId = response['id'];

        final barterItems = _barterLines
            .map((line) {
              final standing = line.standingWeight(_parseDouble);
              final stones = line.stonesWeight(_parseDouble);
              final net = line.netWeight(_parseDouble);
              final pricePerGram = line.effectivePricePerGram(
                _parseDouble,
                _goldPrice24k,
              );
              final value = line.value(_parseDouble, _goldPrice24k);
              if (net <= 0 || pricePerGram <= 0) return null;
              return <String, dynamic>{
                'name': 'ذهب كسر (مقايضة)',
                'karat': line.karat,
                // weight should be NET weight to keep downstream totals consistent
                'weight': net,
                'standing_weight': standing,
                'stones_weight': stones,
                'direct_purchase_price_per_gram': pricePerGram,
                // price per item = cash-equivalent value of this line
                'price': value,
                'tax': 0.0,
                'wage': 0.0,
                'quantity': 1,
              };
            })
            .whereType<Map<String, dynamic>>()
            .toList();

        final barterWeightNet = _barterTotalWeightNet;

        // الحصول على خزينة الذهب للموظف الحالي
        final employeeGoldSafeId =
          authProvider.currentUser?.employee?.goldSafeBoxId;

        final scrapInvoiceData = {
          'customer_id': customerId,
          'branch_id': _selectedBranchId,
          'invoice_type': 'شراء من عميل',
          'gold_type': 'scrap',
          'transaction_type': 'buy',
          if (sellerName.isNotEmpty) 'posted_by': sellerName,
          if (sellerEmployeeId != null) 'employee_id': sellerEmployeeId,
          if (sellerEmployeeId != null)
            'scrap_holder_employee_id': sellerEmployeeId,
          if (employeeGoldSafeId != null)
            'safe_box_id': employeeGoldSafeId
          else if (_selectedBarterGoldDepositSafeBoxId != null)
            'safe_box_id': _selectedBarterGoldDepositSafeBoxId,
          'date': DateTime.now().toIso8601String(),
          'total': barterTotal,
          'total_weight': barterWeightNet,
          'total_cost': barterTotal,
          'total_tax': 0.0,
          'payments': <Map<String, dynamic>>[],
          'amount_paid': 0.0,
          'settlement_method': 'offset',
          'barter_sale_invoice_id': saleInvoiceId,
          'items': barterItems,
        };

        try {
          await apiService.addInvoice(scrapInvoiceData);
        } catch (e) {
          if (mounted) {
            _showError(
              'تم حفظ فاتورة البيع، لكن فشل إنشاء فاتورة شراء الكسر للمقايضة: $e',
            );
          }
        }
      }

      if (!mounted) return;

      final invoiceForPrint = Map<String, dynamic>.from(response);
      // Best-effort enrichment for print header.
      try {
        final match = widget.customers.firstWhere(
          (c) => c['id'].toString() == customerId.toString(),
        );
        invoiceForPrint['customer_name'] ??=
            match['name'] ?? match['customer_name'];
        invoiceForPrint['customer_phone'] ??=
            match['phone'] ?? match['customer_phone'];
      } catch (_) {
        // ignore
      }

      final shouldPrint = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              approvalRequired
                  ? 'تم حفظ الفاتورة (تحتاج اعتماد)'
                  : 'تم حفظ الفاتورة',
            ),
            content: Text(
              '✅ تم حفظ الفاتورة #${invoiceForPrint['id'] ?? ''}'
              '${approvalWarning != null ? "\n\n$approvalWarning" : ""}'
              '\n\nهل تريد طباعتها الآن؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('تم'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.print),
                label: const Text('طباعة'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      if (shouldPrint == true) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                InvoicePrintScreen(invoice: invoiceForPrint, isArabic: true),
          ),
        );
      }

      if (!mounted) return;
      _resetAfterSave();
    } catch (e) {
      _showError('فشل حفظ الفاتورة: $e');
    }
  }

  Future<_PreSaveDecision> _confirmDeferredInvoiceSave({
    required double total,
    required double totalPaid,
    required double remaining,
    required double totalCost,
    required bool paidBelowCost,
    required bool saleBelowCost,
  }) async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final lines = <String>[
      'إجمالي الفاتورة: ${total.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
      'المدفوع: ${totalPaid.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
      'المتبقي: ${remaining.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
    ];

    if (paidBelowCost || saleBelowCost) {
      lines.add('');
      lines.add('⚠️ تحذير:');
      if (saleBelowCost) {
        lines.add(
          'سعر البيع أقل من تكلفة الأصناف (التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbol})',
        );
      } else if (paidBelowCost) {
        lines.add(
          'المدفوع أقل من تكلفة الأصناف (التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbol})',
        );
      }
    }

    final content = lines.join('\n');

    return await showDialog<_PreSaveDecision>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_amber,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'حفظ كفاتورة آجل؟',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Text(content, style: theme.textTheme.bodyMedium),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, _PreSaveDecision.cancel),
                  child: Text(
                    'إلغاء',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.secondary,
                    ),
                  ),
                ),
                if (paidBelowCost || saleBelowCost)
                  TextButton(
                    onPressed: () => Navigator.pop(
                      dialogContext,
                      _PreSaveDecision.proceedSuppressWarning,
                    ),
                    child: const Text('حفظ بدون تحذير'),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () =>
                      Navigator.pop(dialogContext, _PreSaveDecision.proceed),
                  child: const Text('حفظ'),
                ),
              ],
            );
          },
        ) ??
        _PreSaveDecision.cancel;
  }

  Future<_PreSaveDecision> _confirmBelowCostInvoiceSave({
    required double total,
    required double totalPaid,
    required double totalCost,
    required bool paidBelowCost,
    required bool saleBelowCost,
  }) async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final lines = <String>[
      'إجمالي الفاتورة: ${total.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
      'المدفوع: ${totalPaid.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
      'التكلفة: ${totalCost.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
      '',
      '⚠️ تحذير قبل الحفظ:',
      if (saleBelowCost) 'سعر البيع أقل من تكلفة الأصناف.',
      if (!saleBelowCost && paidBelowCost) 'المدفوع أقل من تكلفة الأصناف.',
      '',
      'يمكنك المتابعة، وسيتم حفظ الفاتورة لكن قد تحتاج اعتماد مدير قبل الترحيل.',
    ];

    return await showDialog<_PreSaveDecision>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_amber,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'تحذير قبل الحفظ',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Text(
                lines.join('\n'),
                style: theme.textTheme.bodyMedium,
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, _PreSaveDecision.cancel),
                  child: Text(
                    'إلغاء',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.secondary,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _PreSaveDecision.proceedSuppressWarning,
                  ),
                  child: const Text('حفظ بدون تحذير'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () =>
                      Navigator.pop(dialogContext, _PreSaveDecision.proceed),
                  child: const Text('حفظ'),
                ),
              ],
            );
          },
        ) ??
        _PreSaveDecision.cancel;
  }

  // ==================== Calculations ====================
  double _calculateGrandTotal() {
    return _items.fold<double>(0.0, (sum, item) => sum + item.totalWithTax);
  }

  // حساب إجمالي الضريبة من الأصناف
  double _calculateTotalVAT() {
    return _items.fold<double>(0.0, (sum, item) => sum + item.tax);
  }

  // ==================== Helpers ====================
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  Map<String, dynamic>? _findCashCustomer() {
    for (final customer in widget.customers) {
      final rawId = customer['id'];
      final id = rawId is int ? rawId : int.tryParse(rawId.toString());
      if (id == null) continue;

      if (_isCashCustomerEntry(customer)) {
        return {...customer, 'id': id};
      }
    }
    return null;
  }

  bool _isCashCustomerEntry(Map<String, dynamic>? customer) {
    if (customer == null) return false;
    final name = customer['name']?.toString().toLowerCase() ?? '';
    final code = customer['customer_code']?.toString().toLowerCase() ?? '';
    return _containsCashKeyword(name) || _containsCashKeyword(code);
  }

  bool _containsCashKeyword(String value) {
    if (value.isEmpty) return false;
    return value.contains('نقد') ||
        value.contains('كاش') ||
        value.contains('cash');
  }

  Future<Map<String, dynamic>?> _getOrCreateCashCustomer({
    bool promptIfMissing = true,
  }) async {
    final existing = _findCashCustomer();
    if (existing != null) return existing;

    if (!promptIfMissing) {
      return _createCashCustomerRecord();
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final shouldCreate =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Text(
                'لا يوجد عميل نقدي',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Text(
                'لا يوجد عميل نقدي في قائمة العملاء الحالية. هل ترغب في إنشاء عميل نقدي افتراضي الآن؟',
                style: theme.textTheme.bodyMedium,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('إلغاء', style: theme.textTheme.bodyMedium),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('إنشاء عميل نقدي'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!shouldCreate) {
      return null;
    }

    return _createCashCustomerRecord();
  }

  Future<Map<String, dynamic>?> _createCashCustomerRecord() async {
    try {
      final api = ApiService();
      final payload = {
        'name': 'عميل نقدي',
        'phone': '',
        'address_line_1': 'إنشاء تلقائي',
        'notes': 'تم إنشاؤه تلقائياً للاستخدام كعميل نقدي',
        'active': true,
      };

      final response = await api.addCustomer(payload);
      if (!mounted) return response;
      setState(() {
        widget.customers.add(response);
      });
      return response;
    } catch (e) {
      _showError('فشل إنشاء عميل نقدي: $e');
      return null;
    }
  }

  Future<bool> _confirmUseCashCustomer() async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: colorScheme.surface,
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.warning_amber,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'لم يتم اختيار عميل',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: Text(
                'لم يتم اختيار عميل لهذه الفاتورة. يمكنك العودة لاختيار العميل الصحيح أو الاستمرار وتقييد الفاتورة باسم العميل النقدي.',
                style: theme.textTheme.bodyMedium,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                    'تراجع',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.secondary,
                    ),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('استمرار مع عميل نقدي'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // 🆕 Helper methods لأيقونات وألوان طرق الدفع
  IconData _getPaymentIcon(String paymentType) {
    switch (paymentType) {
      case 'cash':
        return Icons.money;
      case 'bank_transfer':
        return Icons.account_balance;
      case 'credit_card':
        return Icons.credit_card;
      case 'mada':
        return Icons.credit_card;
      case 'check':
        return Icons.receipt_long;
      case 'other':
        return Icons.more_horiz;
      default:
        return Icons.payment;
    }
  }

  Color _getPaymentColor(String paymentType) {
    switch (paymentType) {
      case 'cash':
        return AppColors.success;
      case 'bank_transfer':
        return AppColors.info;
      case 'credit_card':
        return AppColors.karat24;
      case 'mada':
        return AppColors.karat22;
      case 'check':
        return AppColors.warning;
      case 'other':
        return Colors.grey;
      default:
        return AppColors.primaryGold;
    }
  }

  // Open AddCustomerScreen for adding a new customer (no identity enforcement for standard sales)
  Future<void> _addNewCustomer() async {
    final result = await Navigator.push<bool?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddCustomerScreen(
          api: ApiService(),
          enforceIdentityFields: false,
          onCustomerSaved: (saved) {
            if (!mounted) return;
            setState(() {
              widget.customers.add(saved);
              final rawId = saved['id'];
              _selectedCustomerId = rawId is int
                  ? rawId
                  : int.tryParse(rawId.toString());
            });
          },
        ),
      ),
    );

    if (result == true) {
      debugPrint('Customer added via AddCustomerScreen (sales)');
    }
  }

  Future<void> _openCameraScanner() async {
    final barcode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => _BarcodeScannerPlaceholder()),
    );

    if (barcode != null && barcode.isNotEmpty && mounted) {
      _smartInputController.text = barcode;
      await _processSmartInput(barcode);
      _smartInputFocus.requestFocus(); // إعادة التركيز للإدخال
    }
  }

  Future<void> _showItemSelectionDialog() async {
    if (_availableItems.isEmpty && !_isLoadingItems) {
      await _loadAvailableItems();
    }

    if (!mounted) return;

    if (_isLoadingItems) {
      _showError('جاري تحميل قائمة الأصناف، يرجى المحاولة بعد لحظات.');
      return;
    }

    if (_availableItems.isEmpty) {
      _showError(
        _itemsLoadingError ?? 'لا توجد أصناف متاحة حالياً، حدث البيانات أولاً.',
      );
      return;
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String searchQuery = '';
    String? karatFilter;
    String sortMode = 'weight_desc';

    String? normalizeKarat(dynamic value) {
      if (value == null) return null;
      if (value is num) {
        return value.round().toString();
      }
      final parsed = double.tryParse(value.toString());
      if (parsed == null) return null;
      return parsed.round().toString();
    }

    bool matchesSearch(Map<String, dynamic> item, String query) {
      if (query.isEmpty) return true;
      final normalized = query.toLowerCase();
      final fields = [
        item['name'],
        item['barcode'],
        item['item_code'],
        item['category_name'],
      ];
      for (final field in fields) {
        final text = field?.toString().toLowerCase();
        if (text != null && text.contains(normalized)) {
          return true;
        }
      }
      return false;
    }

    List<Map<String, dynamic>> buildFilteredItems() {
      final filtered = _availableItems.where((item) {
        final matches = matchesSearch(item, searchQuery);
        final itemKarat = normalizeKarat(item['karat']);
        final karatMatches = karatFilter == null || karatFilter == itemKarat;
        return matches && karatMatches;
      }).toList();

      int compareByWeight(Map<String, dynamic> a, Map<String, dynamic> b) {
        final weightA = _parseDouble(a['weight']);
        final weightB = _parseDouble(b['weight']);
        return weightA.compareTo(weightB);
      }

      int compareByName(Map<String, dynamic> a, Map<String, dynamic> b) {
        final nameA = (a['name'] ?? '').toString();
        final nameB = (b['name'] ?? '').toString();
        return nameA.compareTo(nameB);
      }

      switch (sortMode) {
        case 'weight_asc':
          filtered.sort(compareByWeight);
          break;
        case 'name':
          filtered.sort(compareByName);
          break;
        case 'weight_desc':
        default:
          filtered.sort((a, b) => compareByWeight(b, a));
          break;
      }

      return filtered;
    }

    final availableKarats =
        _availableItems
            .map((item) => normalizeKarat(item['karat']))
            .where((value) => value != null)
            .cast<String>()
            .toSet()
          ..removeWhere((element) => element.trim().isEmpty);
    final sortedKarats = availableKarats.toList()
      ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredItems = buildFilteredItems();
            return AlertDialog(
              title: Text(
                'اختر صنف',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 460,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        labelText: 'بحث بالاسم، الكود أو الباركود',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  setDialogState(() => searchQuery = '');
                                },
                              )
                            : null,
                      ),
                      onChanged: (value) =>
                          setDialogState(() => searchQuery = value.trim()),
                    ),
                    const SizedBox(height: 12),
                    if (availableKarats.isNotEmpty) ...[
                      Text(
                        'تصفية حسب العيار',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            FilterChip(
                              label: const Text('الكل'),
                              selected: karatFilter == null,
                              onSelected: (_) =>
                                  setDialogState(() => karatFilter = null),
                            ),
                            const SizedBox(width: 8),
                            ...sortedKarats.map(
                              (karat) => Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: 8,
                                ),
                                child: FilterChip(
                                  label: Text('عيار $karat'),
                                  selected: karatFilter == karat,
                                  onSelected: (_) =>
                                      setDialogState(() => karatFilter = karat),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      'ترتيب النتائج',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('وزن أعلى'),
                          selected: sortMode == 'weight_desc',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'weight_desc'),
                        ),
                        ChoiceChip(
                          label: const Text('وزن أقل'),
                          selected: sortMode == 'weight_asc',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'weight_asc'),
                        ),
                        ChoiceChip(
                          label: const Text('أبجدي'),
                          selected: sortMode == 'name',
                          onSelected: (_) =>
                              setDialogState(() => sortMode = 'name'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filteredItems.isEmpty
                          ? Center(
                              child: Text(
                                'لا توجد أصناف مطابقة لخيارات البحث الحالية',
                                style: theme.textTheme.bodySmall,
                              ),
                            )
                          : ListView.builder(
                              itemCount: filteredItems.length,
                              itemBuilder: (context, index) {
                                final item = filteredItems[index];
                                final weight = _parseDouble(item['weight']);
                                final karatLabel =
                                    item['karat']?.toString() ?? '-';
                                final barcode =
                                    item['barcode']?.toString() ?? '';
                                final code =
                                    item['item_code']?.toString() ?? '';

                                return Card(
                                  elevation: 0,
                                  color: theme
                                      .colorScheme
                                      .surfaceContainerHighest
                                      .withValues(alpha: 0.4),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: colorScheme.primary
                                          .withValues(alpha: 0.12),
                                      child: Text(
                                        karatLabel,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: colorScheme.primary,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                    ),
                                    title: Text(
                                      item['name']?.toString() ?? 'بدون اسم',
                                    ),
                                    subtitle: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (code.isNotEmpty)
                                          Text(
                                            'الكود: $code',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        if (barcode.isNotEmpty)
                                          Text(
                                            'الباركود: $barcode',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                      ],
                                    ),
                                    trailing: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${weight.toStringAsFixed(3)} جم',
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _addItemFromData(item);
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==================== UI Build ====================
  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        final size = MediaQuery.of(context).size;
        final isWideLayout = size.width >= 1100;

        final hasAnySettlement = _payments.isNotEmpty || _barterTotal > 0.01;

        final bodyContent = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InvoiceTypeBanner(
              title: 'فاتورة بيع ذهب جديدة',
              subtitle:
                  'لبيع الذهب الجديد مع ضريبة القيمة المضافة ووسائل الدفع المتعددة',
              color: AppColors.invoiceSaleNew,
              icon: Icons.point_of_sale_rounded,
              trailing: Text('نوع الفاتورة', style: theme.textTheme.labelLarge),
            ),
            const SizedBox(height: 16),
            _buildCustomerSection(theme),
            const SizedBox(height: 24),
            if (isWideLayout)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 7,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSmartInputSection(),
                        const SizedBox(height: 24),
                        _buildDataTable(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildActionButtons(),
                        const SizedBox(height: 24),
                        _buildPaymentSection(),
                        const SizedBox(height: 20),
                        // زر الحفظ أسفل بطاقة الإجماليات
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed:
                                _items.isEmpty ||
                                    !hasAnySettlement ||
                                    _remainingAmount > 0.01
                                ? null
                                : _submitInvoice,
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 24,
                            ),
                            label: Text(
                              _remainingAmount > 0.01
                                  ? 'أكمل الدفع (${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol} متبقية)'
                                  : 'حفظ الفاتورة',
                            ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                vertical: 18,
                                horizontal: 24,
                              ),
                              textStyle: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              backgroundColor: colorScheme.primary,
                              foregroundColor: colorScheme.onPrimary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else ...[
              _buildSmartInputSection(),
              const SizedBox(height: 24),
              _buildDataTable(),
              const SizedBox(height: 24),
              _buildActionButtons(),
              const SizedBox(height: 24),
              _buildPaymentSection(),
              const SizedBox(height: 20),
              // زر الحفظ مباشرة أسفل بطاقة الإجماليات
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      _items.isEmpty ||
                          !hasAnySettlement ||
                          _remainingAmount > 0.01
                      ? null
                      : _submitInvoice,
                  icon: const Icon(Icons.check_circle_outline, size: 24),
                  label: Text(
                    _remainingAmount > 0.01
                        ? 'أكمل الدفع (${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol} متبقية)'
                        : 'حفظ الفاتورة',
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      vertical: 18,
                      horizontal: 24,
                    ),
                    textStyle: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
            _buildCostingInsightCard(theme),
          ],
        );

        return Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.invoiceSaleNew,
            foregroundColor: Colors.white,
            iconTheme: const IconThemeData(color: Colors.white),
            title: const Text('فاتورة البيع '),
            actions: [
              IconButton(
                tooltip: 'تحديث سعر الذهب',
                onPressed: _loadSettings,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: bodyContent,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCostingInsightCard(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final hasSnapshot =
        _avgTotalCostPerMainGram > 0 || _inventoryWeightMain > 0;
    final invoiceRawWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: AppColors.lightGold.withValues(alpha: 0.4)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          maintainState: true,
          initiallyExpanded: false,
          leading: Icon(
            Icons.insights,
            color: AppColors.invoiceSaleNew,
            size: 28,
          ),
          title: Text(
            'معلومات التكلفة والتسعير',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: AppColors.deepGold,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              hasSnapshot
                  ? 'متوسط: ${_formatCurrency(_avgTotalCostPerMainGram)}/جم${_invoiceCostTotal > 0 ? ' • تكلفة الفاتورة: ${_formatCurrency(_invoiceCostTotal)}' : ''}'
                  : 'اضغط لعرض تفاصيل التكلفة والمتوسط المتحرك',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          iconColor: AppColors.primaryGold,
          collapsedIconColor: AppColors.primaryGold,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header with Title and Main Cost
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'متوسط التكلفة',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                hasSnapshot
                                    ? _formatCurrency(_avgTotalCostPerMainGram)
                                    : '--',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.invoiceSaleNew,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '/ جم',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.invoiceSaleNew,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_invoiceCostTotal > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.invoiceSaleNew.withValues(
                            alpha: 0.05,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.invoiceSaleNew.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'تكلفة الفاتورة',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.invoiceSaleNew,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _formatCurrency(_invoiceCostTotal),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: AppColors.invoiceSaleNew,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),

                if (_isLoadingCosting) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(minHeight: 2),
                ],

                if (_costingError != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 20,
                          color: colorScheme.error,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _costingError!,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Details Grid
                Row(
                  children: [
                    Expanded(
                      child: _buildCompactMetric(
                        theme,
                        'ذهب / جم',
                        hasSnapshot
                            ? _formatCurrency(_avgGoldCostPerMainGram)
                            : '--',
                        Icons.grid_goldenratio,
                        AppColors.invoiceSaleNew,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildCompactMetric(
                        theme,
                        'مصنعية / جم',
                        hasSnapshot
                            ? _formatCurrency(_avgManufacturingCostPerMainGram)
                            : '--',
                        Icons.handyman,
                        AppColors.warning,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Footer Info
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _buildCostingInfoChip(
                      theme,
                      icon: Icons.style,
                      label: 'المنهجية: $_costingMethodLabel',
                    ),
                    _buildCostingInfoChip(
                      theme,
                      icon: Icons.inventory_2,
                      label: 'المخزون: ${_formatWeight(_inventoryWeightMain)}',
                    ),
                    _buildCostingInfoChip(
                      theme,
                      icon: Icons.schedule,
                      label: 'تحديث: ${_formatTimestamp(_costingLastUpdated)}',
                    ),
                  ],
                ),

                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: AppColors.invoiceSaleNew.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.invoiceSaleNew.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.assignment,
                            color: AppColors.invoiceSaleNew,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'التكلفة التقديرية للفاتورة الحالية',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_items.isEmpty)
                        Text(
                          'أضف أصنافاً لرؤية التكلفة بناءً على المتوسط المتحرك.',
                          style: theme.textTheme.bodyMedium,
                        )
                      else ...[
                        _buildCostingDetailRow(
                          theme,
                          icon: Icons.scale,
                          title: 'إجمالي الوزن الفعلي',
                          value: _formatWeight(invoiceRawWeight),
                        ),
                        const SizedBox(height: 6),
                        _buildCostingDetailRow(
                          theme,
                          icon: Icons.compass_calibration,
                          title:
                              'الوزن المكافئ (${_settingsProvider.mainKarat}K)',
                          value: _formatWeight(_invoiceWeightMain),
                        ),
                        const Divider(height: 24, thickness: 1.2),
                        _buildCostingDetailRow(
                          theme,
                          icon: Icons.local_fire_department,
                          title: 'تكلفة الذهب المتوقع',
                          value: _formatCurrency(_invoiceCostGoldComponent),
                        ),
                        const SizedBox(height: 6),
                        _buildCostingDetailRow(
                          theme,
                          icon: Icons.handyman,
                          title: 'تكلفة المصنعية المتراكمة',
                          value: _formatCurrency(
                            _invoiceCostManufacturingComponent,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 14,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: theme.brightness == Brightness.dark
                                  ? 0.05
                                  : 0.7,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'التكلفة الإجمالية المتوقعة',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                _formatCurrency(_invoiceCostTotal),
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.invoiceSaleNew,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerSection(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    Map<String, dynamic>? selectedCustomer;
    if (_selectedCustomerId != null) {
      selectedCustomer = widget.customers.firstWhere((customer) {
        final rawId = customer['id'];
        if (rawId == null) return false;
        final parsed = rawId is int ? rawId : int.tryParse(rawId.toString());
        return parsed == _selectedCustomerId;
      }, orElse: () => {});
      if (selectedCustomer.isEmpty) {
        selectedCustomer = null;
      }
    }

    return Card(
      elevation: isDark ? 2 : 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.25 : 0.08),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(
                      alpha: isDark ? 0.18 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.person_outline, color: colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'بيانات العميل',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'اختر العميل أو أضف عميلًا جديدًا لإتمام الفاتورة.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _addNewCustomer,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('عميل جديد'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    textStyle: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (widget.customers.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: isDark ? 0.25 : 0.5,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'لا يوجد عملاء مسجلون بعد، أضف عميلًا للمتابعة.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              DropdownButtonFormField<int>(
                initialValue: _selectedCustomerId,
                items: widget.customers
                    .map((customer) {
                      final rawId = customer['id'];
                      if (rawId == null) return null;
                      final id = rawId is int
                          ? rawId
                          : int.tryParse(rawId.toString());
                      if (id == null) return null;
                      final name = (customer['name'] ?? 'عميل').toString();
                      final phone =
                          (customer['phone'] ?? customer['phone_number'] ?? '')
                              .toString();
                      final isCashCustomer = name.trim() == 'نقدي';
                      final accentColor = isCashCustomer
                          ? AppColors.success
                          : colorScheme.primary;

                      return DropdownMenuItem<int>(
                        value: id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.badge, color: accentColor, size: 20),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                name,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (phone.isNotEmpty)
                              Flexible(
                                child: Text(
                                  phone,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      );
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedCustomerId = value;
                  });
                },
                decoration: InputDecoration(
                  labelText: 'اختر العميل',
                  prefixIcon: Icon(Icons.people, color: colorScheme.primary),
                ),
                dropdownColor: theme.cardColor,
                icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
              ),

            const SizedBox(height: 14),
            if (_isLoadingBranches)
              const LinearProgressIndicator(minHeight: 2)
            else if (_branchesLoadingError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'فشل تحميل الفروع: $_branchesLoadingError',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _loadBranches,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة'),
                    ),
                  ],
                ),
              )
            else
              DropdownButtonFormField<int>(
                initialValue: _selectedBranchId,
                items: _branches
                    .map((branch) {
                      final id = _parseInt(branch['id']);
                      if (id == null) return null;
                      final name = (branch['name'] ?? 'فرع').toString();
                      return DropdownMenuItem<int>(
                        value: id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.account_tree,
                              color: colorScheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                name,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    })
                    .whereType<DropdownMenuItem<int>>()
                    .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedBranchId = value;
                  });
                },
                decoration: InputDecoration(
                  labelText: 'اختر الفرع',
                  prefixIcon: Icon(
                    Icons.account_tree,
                    color: colorScheme.primary,
                  ),
                ),
                dropdownColor: theme.cardColor,
                icon: Icon(Icons.arrow_drop_down, color: colorScheme.primary),
              ),
            if (selectedCustomer != null) ...[
              const SizedBox(height: 16),
              _buildSelectedCustomerDetails(theme, selectedCustomer),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerInfoChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedCustomerDetails(
    ThemeData theme,
    Map<String, dynamic> customer,
  ) {
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final name = (customer['name'] ?? '').toString();
    final phone = (customer['phone'] ?? customer['phone_number'] ?? '')
        .toString();
    final address = (customer['address'] ?? customer['address_line_1'] ?? '')
        .toString();
    final code = customer['customer_code']?.toString();

    final infoChips = <Widget>[];
    if (phone.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(theme, icon: Icons.phone_iphone, label: phone),
      );
    }
    if (address.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(
          theme,
          icon: Icons.location_on_outlined,
          label: address,
        ),
      );
    }
    if (code != null && code.isNotEmpty) {
      infoChips.add(
        _buildCustomerInfoChip(
          theme,
          icon: Icons.qr_code_2,
          label: 'رمز: $code',
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user, color: colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (infoChips.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, children: infoChips),
          ],
        ],
      ),
    );
  }

  // ==================== Smart Input Section ====================
  Widget _buildSmartInputSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final allowManualItems = _settingsProvider.allowManualInvoiceItems;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary.withValues(alpha: 0.15),
            theme.colorScheme.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.qr_code_scanner,
                  color: colorScheme.onSurface,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'إدخال سريع',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'باركود • اسم • رقم صنف',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              _buildQuickButton(
                Icons.camera_alt,
                AppColors.info,
                'كاميرا',
                _openCameraScanner,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.list_alt,
                AppColors.success,
                'قائمة',
                _showItemSelectionDialog,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.edit_note,
                allowManualItems ? AppColors.warning : theme.disabledColor,
                allowManualItems
                    ? 'إضافة صنف يدوي'
                    : 'فعّل من الإعدادات لإضافة صنف يدوي',
                allowManualItems
                    ? _showManualItemDialog
                    : _showManualItemFeatureGuide,
              ),
              const SizedBox(width: 8),
              _buildQuickButton(
                Icons.category,
                allowManualItems ? AppColors.primaryGold : theme.disabledColor,
                allowManualItems
                    ? 'سطر تصنيف'
                    : 'فعّل من الإعدادات لإضافة سطر تصنيف',
                allowManualItems
                    ? _showCategoryLineDialog
                    : _showManualItemFeatureGuide,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Smart Input Field
          TextField(
            controller: _smartInputController,
            focusNode: _smartInputFocus,
            autofocus: true,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              labelText: 'امسح الباركود أو ابحث...',
              labelStyle: theme.textTheme.bodyMedium,
              hintText: 'YAS000001 • اسم الصنف • I-000001',
              hintStyle: theme.textTheme.bodySmall,
              prefixIcon: Icon(Icons.search, color: colorScheme.primary),
              suffixIcon: _smartInputController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, color: theme.iconTheme.color),
                      onPressed: () {
                        _smartInputController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: colorScheme.primary, width: 2),
              ),
            ),
            onChanged: (value) => setState(() {}),
            onSubmitted: _processSmartInput,
          ),
          if (_isLoadingItems)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'جاري تحميل قائمة الأصناف...',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            )
          else if (_itemsLoadingError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _itemsLoadingError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickButton(
    IconData icon,
    Color color,
    String tooltip,
    VoidCallback onPressed,
  ) {
    final theme = Theme.of(context);
    final backgroundOpacity = theme.brightness == Brightness.dark ? 0.2 : 0.1;
    final borderOpacity = theme.brightness == Brightness.dark ? 0.5 : 0.3;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: backgroundOpacity),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: borderOpacity)),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }

  // ==================== Data Table ====================
  Widget _buildDataTable() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final dividerColor = theme.dividerColor;

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dividerColor.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.3 : 0.06,
            ),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.table_chart,
                  color: colorScheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الأصناف المضافة',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_items.isNotEmpty)
                      Text(
                        '${_items.length} صنف',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Table or Empty State
          if (_items.isEmpty) _buildEmptyState() else _buildTable(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: theme.brightness == Brightness.dark
              ? [
                  colorScheme.surfaceContainerHighest,
                  theme.scaffoldBackgroundColor,
                ]
              : [colorScheme.surface, theme.scaffoldBackgroundColor],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.6),
          width: 2,
        ),
      ),
      child: Center(
        child: Column(
          children: [
            Icon(
              Icons.shopping_cart_outlined,
              size: 64,
              color: colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'لم تتم إضافة أصناف بعد',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color:
                    theme.textTheme.titleLarge?.color ?? colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'ابدأ بمسح الباركود أو البحث عن الأصناف',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final headerStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    final cellStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(
          colorScheme.primary.withValues(alpha: 0.15),
        ),
        dataRowColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.1);
          }
          return theme.cardColor;
        }),
        columns: [
          DataColumn(label: Text('#', style: headerStyle)),
          DataColumn(label: Text('الاسم', style: headerStyle)),
          DataColumn(label: Text('العيار', style: headerStyle)),
          DataColumn(label: Text('الوزن (جم)', style: headerStyle)),
          DataColumn(label: Text('المصنعية', style: headerStyle)),
          DataColumn(label: Text('السعر/جم', style: headerStyle)),
          DataColumn(label: Text('التكلفة', style: headerStyle)),
          DataColumn(label: Text('الصافي', style: headerStyle)),
          DataColumn(label: Text('الضريبة', style: headerStyle)),
          DataColumn(label: Text('الإجمالي', style: headerStyle)),
          DataColumn(label: Text('إجراءات', style: headerStyle)),
        ],
        rows: _items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;

          return DataRow(
            cells: [
              DataCell(Text('${index + 1}', style: cellStyle)),
              DataCell(Text(item.name, style: cellStyle)),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'karat', item.karat),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.info.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.info.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      item.karat.toStringAsFixed(0),
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'weight', item.weight),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      item.weight.toStringAsFixed(2),
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => _showEditDialog(index, 'wage', item.wage),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(item.wage.toStringAsFixed(2), style: cellStyle),
                  ),
                ),
              ),
              DataCell(
                Text(
                  item.calculateSellingPricePerGram().toStringAsFixed(2),
                  style: cellStyle,
                ),
              ),
              DataCell(Text(item.cost.toStringAsFixed(2), style: cellStyle)),
              DataCell(Text(item.net.toStringAsFixed(2), style: cellStyle)),
              DataCell(Text(item.tax.toStringAsFixed(2), style: cellStyle)),
              DataCell(
                InkWell(
                  onTap: () =>
                      _showEditDialog(index, 'total', item.totalWithTax),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.karat24.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.karat24.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${item.totalWithTax.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                      style: cellStyle,
                    ),
                  ),
                ),
              ),
              DataCell(
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.delete,
                        size: 22,
                        color: AppColors.error,
                      ),
                      onPressed: () => _removeItem(index),
                      tooltip: 'حذف',
                    ),
                  ],
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Future<void> _showEditDialog(
    int index,
    String field,
    double currentValue,
  ) async {
    final controller = TextEditingController(text: currentValue.toString());
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String title = '';
    String label = '';

    switch (field) {
      case 'karat':
        title = 'تعديل العيار';
        label = 'العيار';
        break;
      case 'weight':
        title = 'تعديل الوزن';
        label = 'الوزن (جم)';
        break;
      case 'wage':
        title = 'تعديل المصنعية';
        label = 'المصنعية (للجرام)';
        break;
      case 'total':
        title = 'تعديل الإجمالي';
        label = 'الإجمالي';
        break;
    }

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onSubmitted: (value) {
            final numValue = double.tryParse(value);
            if (numValue != null) {
              _updateItem(index, field, numValue);
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = double.tryParse(controller.text);
              if (value != null) {
                _updateItem(index, field, value);
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  // ==================== Action Buttons ====================
  Widget _buildActionButtons() {
    final grandTotal = _calculateGrandTotal();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final totalWeight = _items.fold<double>(
      0.0,
      (sum, item) => sum + item.weight,
    );
    final totalWeight24kEq = _items.fold<double>(
      0.0,
      (sum, item) => sum + (item.weight * (item.karat / 24.0)),
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  colorScheme.surfaceContainerHighest,
                  theme.scaffoldBackgroundColor,
                ]
              : [colorScheme.surface, theme.scaffoldBackgroundColor],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Auto Distribute Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _items.isEmpty ? null : _showAutoDistributeDialog,
              icon: const Icon(Icons.auto_awesome, size: 22),
              label: Text(
                'توزيع تلقائي للمبلغ',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 56),
                backgroundColor: isDark
                    ? AppColors.karat24
                    : AppColors.primaryGold,
                foregroundColor: isDark ? Colors.white : Colors.black,
                disabledBackgroundColor: theme.disabledColor.withValues(
                  alpha: 0.2,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Grand Total
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colorScheme.primary, AppColors.lightGold],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.primary.withValues(
                    alpha: isDark ? 0.35 : 0.4,
                  ),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'الإجمالي الكلي',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                        shadows: !isDark
                            ? [
                                Shadow(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  blurRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    Text(
                      '${_items.length} صنف',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.9)
                            : Colors.black87,
                        fontWeight: FontWeight.w500,
                        shadows: !isDark
                            ? [
                                Shadow(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  blurRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'الوزن: ${totalWeight.toStringAsFixed(3)} جم • معادل 24: ${totalWeight24kEq.toStringAsFixed(3)} جم',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.9)
                            : Colors.black87,
                        fontWeight: FontWeight.w600,
                        shadows: !isDark
                            ? [
                                Shadow(
                                  color: Colors.white.withValues(alpha: 0.8),
                                  blurRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${grandTotal.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                    shadows: !isDark
                        ? [
                            Shadow(
                              color: Colors.white.withValues(alpha: 0.9),
                              blurRadius: 3,
                            ),
                          ]
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Payment Section ====================
  Widget _buildPaymentSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final totalAmount = _calculateGrandTotal();
    final dividerColor = theme.dividerColor.withValues(alpha: 0.6);
    final isDark = theme.brightness == Brightness.dark;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final employeeGoldSafesEnabled =
      _settingsProvider.settings['employee_gold_safes_enabled'] == true;
    final employeeGoldSafeId =
      authProvider.currentUser?.employee?.goldSafeBoxId;
    final hideBarterGoldDepositSafe =
      employeeGoldSafesEnabled && employeeGoldSafeId != null;
    final showBarterGoldDepositSafeDropdown =
      employeeGoldSafesEnabled && employeeGoldSafeId == null;

    final mainScrapIdRaw = _settingsProvider.settings['main_scrap_gold_safe_box_id'];
    final mainScrapGoldSafeBoxId = mainScrapIdRaw is int
        ? mainScrapIdRaw
        : int.tryParse(mainScrapIdRaw?.toString() ?? '');

    String? safeNameById(int? id) {
      if (id == null) return null;
      for (final b in _barterGoldDepositSafeBoxes) {
        if (b.id == id) return b.name;
      }
      return null;
    }

    final selectedDepositSafeName =
        safeNameById(_selectedBarterGoldDepositSafeBoxId);
    final mainScrapSafeName = safeNameById(mainScrapGoldSafeBoxId);
    final resolvedDepositSafeName =
        selectedDepositSafeName ?? mainScrapSafeName ?? 'الخزنة الرئيسية للكسر';

    return Card(
      elevation: 2,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.payment, color: colorScheme.primary, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      'وسائل الدفع',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(
                      alpha: isDark ? 0.2 : 0.12,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    'الإجمالي: ${totalAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 🆕 جدول الدفعات المضافة
            if (_payments.isNotEmpty) ...[
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: colorScheme.primary.withValues(alpha: 0.4),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            colorScheme.primary.withValues(
                              alpha: isDark ? 0.25 : 0.3,
                            ),
                            AppColors.lightGold.withValues(
                              alpha: isDark ? 0.2 : 0.35,
                            ),
                          ],
                        ),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(6),
                          topRight: Radius.circular(6),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              'الوسيلة',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'المبلغ',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'عمولة',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'صافي',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              'حذف',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                                shadows: !isDark
                                    ? [
                                        Shadow(
                                          color: Colors.white.withValues(
                                            alpha: 0.8,
                                          ),
                                          blurRadius: 2,
                                        ),
                                      ]
                                    : null,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Rows
                    ...List.generate(_payments.length, (index) {
                      final payment = _payments[index];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: index % 2 == 0
                              ? theme.colorScheme.surface
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: isDark ? 0.3 : 0.5),
                          border: Border(
                            bottom: BorderSide(color: dividerColor, width: 1),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    payment.paymentMethodName,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (payment.commissionRate > 0)
                                    Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.warning.withValues(
                                          alpha: isDark ? 0.2 : 0.25,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'عمولة ${payment.commissionRate}%',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 11,
                                              color: AppColors.warning,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '${payment.amount.toStringAsFixed(2)} ر.س',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                payment.commissionAmount > 0
                                    ? '${payment.commissionAmount.toStringAsFixed(2)} ر.س'
                                    : '-',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: payment.commissionAmount > 0
                                      ? AppColors.error
                                      : theme.disabledColor,
                                  fontWeight: FontWeight.w600,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                '${payment.netAmount.toStringAsFixed(2)} ر.س',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.info,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            SizedBox(
                              width: 45,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.delete_forever,
                                  size: 22,
                                ),
                                color: AppColors.error,
                                tooltip: 'حذف',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _removePayment(index),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 🆕 مقايضة ذهب كسر داخل وسائل الدفع
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.primaryGold.withValues(
                  alpha: isDark ? 0.12 : 0.10,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primaryGold.withValues(alpha: 0.35),
                  width: 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.swap_horiz,
                            color: AppColors.primaryGold,
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'مقايضة ذهب كسر',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: _enableBarter,
                        onChanged: (value) {
                          setState(() {
                            _enableBarter = value;
                            if (value) {
                              _ensureAtLeastOneBarterLine();
                            } else {
                              for (final line in _barterLines) {
                                line.dispose();
                              }
                              _barterLines.clear();
                            }
                          });

                          if (value) {
                            _loadBarterGoldDepositSafeBoxesIfNeeded();
                          }
                        },
                      ),
                    ],
                  ),
                  if (_enableBarter) ...[
                    const SizedBox(height: 12),
                    if (hideBarterGoldDepositSafe)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: isDark ? 0.25 : 0.35),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 18,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'سيتم إيداع الذهب في خزنتك الشخصية تلقائياً',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (showBarterGoldDepositSafeDropdown) ...[
                      if (!hideBarterGoldDepositSafe)
                        const SizedBox(height: 10),
                      if (_isLoadingBarterGoldDepositSafeBoxes)
                        const LinearProgressIndicator(minHeight: 3),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                        value: _selectedBarterGoldDepositSafeBoxId,
                        decoration: const InputDecoration(
                          labelText: 'خزينة إيداع ذهب المقايضة',
                          border: OutlineInputBorder(),
                        ),
                        items: _barterGoldDepositSafeBoxes
                            .where((b) => b.id != null)
                            .map(
                              (box) => DropdownMenuItem<int>(
                                value: box.id!,
                                child: Text(box.name),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedBarterGoldDepositSafeBoxId = value;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(
                            alpha: isDark ? 0.18 : 0.12,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'سيتم الإيداع في: $resolvedDepositSafeName لعدم وجود خزنة ذهب خاصة بك.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        onPressed: _addBarterLine,
                        icon: const Icon(Icons.add),
                        label: const Text('إضافة ذهب مقايضة'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...List.generate(_barterLines.length, (index) {
                      final line = _barterLines[index];
                      final net = line.netWeight(_parseDouble);
                      final value = line.value(_parseDouble, _goldPrice24k);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.primaryGold.withValues(
                              alpha: 0.25,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: line.karat,
                                    decoration: const InputDecoration(
                                      labelText: 'العيار',
                                    ),
                                    items: const [18, 21, 22, 24]
                                        .map(
                                          (k) => DropdownMenuItem<int>(
                                            value: k,
                                            child: Text('$k'),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(() {
                                        line.karat = value;
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                IconButton(
                                  tooltip: 'حذف',
                                  onPressed: _barterLines.length <= 1
                                      ? null
                                      : () => _removeBarterLine(index),
                                  icon: const Icon(Icons.delete_outline),
                                  color: AppColors.error,
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: line.standingController,
                                    decoration: const InputDecoration(
                                      labelText: 'الوزن القائم (جم)',
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: line.stonesController,
                                    decoration: const InputDecoration(
                                      labelText: 'وزن الفصوص (جم)',
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: line.pricePerGramController,
                                    decoration: InputDecoration(
                                      labelText: 'سعر الشراء/جرام',
                                      suffixText:
                                          _settingsProvider.currencySymbol,
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (value) {
                                      setState(() {
                                        // حساب المبلغ الإجمالي من السعر/جرام
                                        final price = _parseDouble(value);
                                        if (price > 0 && net > 0) {
                                          line.totalAmountController.text =
                                              (price * net).toStringAsFixed(2);
                                        }
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: line.totalAmountController,
                                    decoration: InputDecoration(
                                      labelText: 'المبلغ الإجمالي',
                                      suffixText:
                                          _settingsProvider.currencySymbol,
                                    ),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    onChanged: (value) {
                                      setState(() {
                                        // حساب السعر/جرام من المبلغ الإجمالي
                                        final total = _parseDouble(value);
                                        if (total > 0 && net > 0) {
                                          line.pricePerGramController.text =
                                              (total / net).toStringAsFixed(2);
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'الصافي: ${net.toStringAsFixed(3)} جم',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'القيمة: ${value.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryGold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'إجمالي المقايضة:',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${_barterTotal.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryGold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            // 🆕 إضافة وسيلة دفع جديدة
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(
                  alpha: isDark ? 0.15 : 0.12,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'إضافة وسيلة دفع',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Row 1: وسيلة الدفع
                  Row(
                    children: [
                      // Dropdown وسيلة الدفع
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.primary.withValues(alpha: 0.5),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.primary.withValues(
                                  alpha: 0.16,
                                ),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: _selectedPaymentMethodId,
                              hint: Row(
                                children: [
                                  Icon(
                                    Icons.payment,
                                    color: theme.iconTheme.color,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'اختر وسيلة الدفع',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              isExpanded: true,
                              dropdownColor: theme.colorScheme.surface,
                              icon: Icon(
                                Icons.arrow_drop_down,
                                color: colorScheme.primary,
                                size: 28,
                              ),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              selectedItemBuilder: (BuildContext context) {
                                return _paymentMethods.map<Widget>((method) {
                                  return Row(
                                    children: [
                                      Icon(
                                        _getPaymentIcon(
                                          method['payment_type'] ?? '',
                                        ),
                                        color: _getPaymentColor(
                                          method['payment_type'] ?? '',
                                        ),
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          method['name'] ?? '',
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  );
                                }).toList();
                              },
                              items: _paymentMethods.map((method) {
                                final commission =
                                    method['commission_rate'] ?? 0.0;

                                return DropdownMenuItem<int>(
                                  value: method['id'],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                      horizontal: 4,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _getPaymentIcon(
                                            method['payment_type'] ?? '',
                                          ),
                                          color: _getPaymentColor(
                                            method['payment_type'] ?? '',
                                          ),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            method['name'] ?? '',
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                        if (commission > 0)
                                          Flexible(
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                left: 4,
                                              ),
                                              child: Text(
                                                '($commission%)',
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: AppColors.warning,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) async {
                                setState(() {
                                  _selectedPaymentMethodId = value;
                                });
                                // 🆕 تحميل الخزائن عند تغيير طريقة الدفع
                                if (value != null) {
                                  await _loadSafeBoxesForPaymentMethod(value);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      // 🎯 زر الإعدادات المتقدمة (إظهار/إخفاء الخزائن)
                      if (_selectedPaymentMethodId != null &&
                          _safeBoxes.isNotEmpty)
                        Tooltip(
                          message: _showAdvancedPaymentOptions
                              ? 'إخفاء الخيارات المتقدمة'
                              : 'إظهار الخيارات المتقدمة (اختيار الخزينة)',
                          child: IconButton(
                            icon: Icon(
                              _showAdvancedPaymentOptions
                                  ? Icons.settings
                                  : Icons.settings_outlined,
                              color: _showAdvancedPaymentOptions
                                  ? Colors.amber.shade700
                                  : Colors.grey.shade600,
                              size: 22,
                            ),
                            onPressed: () {
                              setState(() {
                                _showAdvancedPaymentOptions =
                                    !_showAdvancedPaymentOptions;
                              });
                            },
                            splashRadius: 20,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Row 2: الخزينة (تظهر فقط عند تفعيل الخيارات المتقدمة)
                  if (_selectedPaymentMethodId != null &&
                      _safeBoxes.isNotEmpty &&
                      _showAdvancedPaymentOptions)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.amber.shade600,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.amber.withValues(alpha: 0.1),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  value: _selectedSafeBoxId,
                                  hint: Row(
                                    children: [
                                      Icon(
                                        Icons.account_balance_wallet,
                                        color: Colors.amber.shade600,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'اختر الخزينة',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: theme.hintColor),
                                      ),
                                    ],
                                  ),
                                  isExpanded: true,
                                  dropdownColor: theme.colorScheme.surface,
                                  icon: Icon(
                                    Icons.arrow_drop_down,
                                    color: Colors.amber.shade600,
                                    size: 24,
                                  ),
                                  items: _safeBoxes.map((box) {
                                    return DropdownMenuItem<int>(
                                      value: box.id,
                                      child: Row(
                                        children: [
                                          Icon(
                                            box.icon,
                                            color: box.typeColor,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              box.name,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (box.isDefault == true)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 2,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withValues(
                                                  alpha: 0.2,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                'افتراضي',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: Colors.green,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (value) {
                                    setState(() {
                                      _selectedSafeBoxId = value;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // المسافة بعد dropdown الخزينة (تظهر فقط إذا كانت الخزينة ظاهرة)
                  if (_selectedPaymentMethodId != null &&
                      _safeBoxes.isNotEmpty &&
                      _showAdvancedPaymentOptions)
                    const SizedBox(height: 8),

                  // Row 2: المبلغ وزر الإضافة (في صف واحد)
                  Row(
                    children: [
                      // حقل المبلغ مع أيقونة ملء باقي المبلغ
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _remainingAmount > 0
                                  ? colorScheme.primary
                                  : dividerColor,
                              width: _remainingAmount > 0 ? 2 : 1,
                            ),
                            boxShadow: _remainingAmount > 0
                                ? [
                                    BoxShadow(
                                      color: colorScheme.primary.withValues(
                                        alpha: 0.25,
                                      ),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _customAmountController,
                                  decoration: InputDecoration(
                                    labelText: 'المبلغ',
                                    labelStyle: theme.textTheme.bodyMedium
                                        ?.copyWith(
                                          color: colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                    hintText: _remainingAmount.toStringAsFixed(
                                      0,
                                    ),
                                    hintStyle: theme.textTheme.bodySmall,
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    suffixText: 'ر.س',
                                    suffixStyle: theme.textTheme.bodySmall
                                        ?.copyWith(fontWeight: FontWeight.w500),
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              if (_remainingAmount > 0)
                                Container(
                                  decoration: BoxDecoration(
                                    border: Border(
                                      right: BorderSide(
                                        color: colorScheme.primary.withValues(
                                          alpha: 0.4,
                                        ),
                                      ),
                                    ),
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.playlist_add_check,
                                      color: colorScheme.primary,
                                      size: 24,
                                    ),
                                    tooltip:
                                        'ملء باقي المبلغ (${_remainingAmount.toStringAsFixed(2)})',
                                    onPressed: () {
                                      setState(() {
                                        _customAmountController.text =
                                            _remainingAmount.toStringAsFixed(2);
                                      });
                                    },
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // زر الإضافة
                      ElevatedButton.icon(
                        onPressed: () {
                          if (_safeBoxes.isNotEmpty &&
                              _selectedSafeBoxId == null) {
                            _showError('اختر الخزينة أولاً');
                            return;
                          }

                          final customAmount = double.tryParse(
                            _customAmountController.text,
                          );
                          _addPayment(customAmount: customAmount);
                        },
                        icon: const Icon(Icons.add_circle, size: 20),
                        label: Text(
                          'إضافة',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 18,
                          ),
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                          elevation: 3,
                          shadowColor: colorScheme.primary.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(
                        alpha: isDark ? 0.18 : 0.12,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppColors.warning.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: AppColors.warning,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'المتبقي: ${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            color: AppColors.warning,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 🆕 ملخص النهائي
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _remainingAmount > 0
                      ? [
                          colorScheme.error.withValues(
                            alpha: isDark ? 0.16 : 0.12,
                          ),
                          colorScheme.error.withValues(
                            alpha: isDark ? 0.28 : 0.2,
                          ),
                        ]
                      : [
                          AppColors.success.withValues(
                            alpha: isDark ? 0.16 : 0.12,
                          ),
                          AppColors.success.withValues(
                            alpha: isDark ? 0.28 : 0.2,
                          ),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _remainingAmount > 0
                      ? colorScheme.error.withValues(alpha: 0.5)
                      : AppColors.success.withValues(alpha: 0.5),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (_remainingAmount > 0
                                ? colorScheme.error
                                : AppColors.success)
                            .withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // إجمالي الفاتورة مع ضريبة القيمة المضافة
                  if (_items.isNotEmpty) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.receipt,
                              size: 18,
                              color: theme.iconTheme.color,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'إجمالي الفاتورة:',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                        Text(
                          '${_calculateGrandTotal().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.description,
                              size: 16,
                              color: AppColors.info,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ضريبة القيمة المضافة:',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        Text(
                          '${_calculateTotalVAT().toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.info,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 16, thickness: 1),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.account_balance_wallet,
                            size: 20,
                            color: theme.iconTheme.color,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'المدفوع:',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${_totalPayments.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (_totalCommission > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.percent,
                              size: 18,
                              color: AppColors.warning,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'إجمالي العمولات:',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                        Text(
                          '${_totalCommission.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.warning,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.receipt_long,
                              size: 16,
                              color: AppColors.info,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'ضريبة العمولات (15%):',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        Text(
                          '${_totalCommissionVAT.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppColors.info,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              size: 18,
                              color: AppColors.success,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'صافي المستلم:',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${_totalNet.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColors.success,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 20, thickness: 1.5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _remainingAmount > 0
                                ? Icons.warning_amber_rounded
                                : Icons.check_circle_outline,
                            size: 22,
                            color: _remainingAmount > 0
                                ? colorScheme.error
                                : AppColors.success,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _remainingAmount > 0
                                ? 'المتبقي:'
                                : '✓ تم الدفع بالكامل',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: _remainingAmount > 0
                                  ? colorScheme.error
                                  : AppColors.success,
                            ),
                          ),
                        ],
                      ),
                      if (_remainingAmount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.error,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_remainingAmount.toStringAsFixed(2)} ${_settingsProvider.currencySymbol}',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onError,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== Invoice Item Model ====================
class InvoiceItem {
  final int? id;
  final String name;
  final String barcode;
  double karat;
  double weight;
  double wage; // أجور المصنعية للجرام الواحد
  final int? categoryId;
  final String? categoryName;
  final double goldPrice24k;
  final int mainKarat;
  double taxRate;
  int count;  // 🆕 عدد القطع لهذا الصنف
  double _avgGoldCostPerMainGram;
  double _avgManufacturingCostPerMainGram;

  // الربح الموزع (يتم حسابه في _distributeAmount)
  double profit = 0.0;

  // علامة لتتبع إذا تم تحديد الإجمالي يدوياً
  bool _hasManualTotal = false;
  double? _targetTotal;

  bool get hasManualTotal => _hasManualTotal && _targetTotal != null;
  double? get manualTargetTotal => _targetTotal;

  InvoiceItem({
    this.id,
    required this.name,
    required this.barcode,
    required this.karat,
    required this.weight,
    required this.wage,
    this.categoryId,
    this.categoryName,
    this.count = 1,  // 🆕 افتراضي عدد 1
    required this.goldPrice24k,
    required this.mainKarat,
    required this.taxRate,
    required double avgGoldCostPerMainGram,
    required double avgManufacturingCostPerMainGram,
  }) : _avgGoldCostPerMainGram = avgGoldCostPerMainGram,
       _avgManufacturingCostPerMainGram = avgManufacturingCostPerMainGram;

  // حساب سعر الجرام الخام (سعر الذهب فقط حسب العيار)
  double calculatePricePerGram() {
    return goldPrice24k * (karat / 24.0);
  }

  double get weightInMainKarat {
    if (mainKarat <= 0) return weight;
    return weight * (karat / mainKarat);
  }

  // التكلفة = الوزن × (سعر الذهب للجرام + المصنعية للجرام)
  double get cost {
    final totalAvg = _avgGoldCostPerMainGram + _avgManufacturingCostPerMainGram;
    if (totalAvg > 0) {
      return weightInMainKarat * totalAvg;
    }
    return weight * (calculatePricePerGram() + wage);
  }

  // الصافي = التكلفة + الربح الموزع
  double get net {
    if (_hasManualTotal && _targetTotal != null) {
      // إذا تم تحديد إجمالي يدوي، احسب الصافي من الإجمالي
      return _targetTotal! / (1 + taxRate);
    }
    return cost + profit;
  }

  // الضريبة 15% على الصافي
  double get tax {
    return net * taxRate;
  }

  // الإجمالي مع الضريبة
  double get totalWithTax {
    if (_hasManualTotal && _targetTotal != null) {
      return _targetTotal!;
    }
    return net + tax;
  }

  // حساب سعر البيع للجرام (للعرض فقط)
  double calculateSellingPricePerGram() {
    if (weight == 0) return 0;
    return net / weight;
  }

  // تحديد إجمالي يدوي
  void setManualTotal(double total) {
    _hasManualTotal = true;
    _targetTotal = total;
    // إعادة حساب الربح بناءً على الإجمالي الجديد
    final targetNet = total / (1 + taxRate);
    profit = targetNet - cost;
  }

  // مسح الإجمالي اليدوي عند تعديل الحقول
  void clearManualTotal() {
    _hasManualTotal = false;
    _targetTotal = null;
  }

  void updateCostingSnapshot({
    required double avgGoldPerMainGram,
    required double avgManufacturingPerMainGram,
  }) {
    _avgGoldCostPerMainGram = avgGoldPerMainGram;
    _avgManufacturingCostPerMainGram = avgManufacturingPerMainGram;
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'item_id': id,
      'name': name,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      if (categoryId != null) 'category_id': categoryId,
      'cost': cost,
      'profit': profit,
      'net': net,
      'tax': tax,
      'price': totalWithTax, // الـ backend يتوقع 'price' بدلاً من 'total'
      'quantity': count,  // 🆕 عدد فعلي
      'calculated_selling_price_per_gram': calculateSellingPricePerGram(),
    };
  }
}

// ==================== Category Line Dialog Widget ====================
class _CategoryLineDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final int mainKarat;

  const _CategoryLineDialog({
    required this.categories,
    required this.mainKarat,
  });

  @override
  State<_CategoryLineDialog> createState() => _CategoryLineDialogState();
}

class _CategoryLineDialogState extends State<_CategoryLineDialog> {
  final _formKey = GlobalKey<FormState>();
  final _categorySearchController = TextEditingController();
  final _weightController = TextEditingController(text: '1.0');
  final _wageController = TextEditingController(text: '0');

  Map<String, dynamic>? _selectedCategory;
  late int _selectedKarat;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selectedKarat = widget.mainKarat;
  }

  @override
  void dispose() {
    _categorySearchController.dispose();
    _weightController.dispose();
    _wageController.dispose();
    super.dispose();
  }

  double _tryParseDouble(String value, double fallback) {
    final normalized = value.trim().replaceAll(',', '.');
    return double.tryParse(normalized) ?? fallback;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final categoryId = (_selectedCategory?['id'] is num)
        ? (_selectedCategory?['id'] as num).toInt()
        : int.tryParse('${_selectedCategory?['id']}');
    final categoryName = (_selectedCategory?['name'] ?? '').toString().trim();
    final weight = _tryParseDouble(_weightController.text, 0);
    final wage = _tryParseDouble(_wageController.text, 0);

    if (categoryId == null || weight <= 0) return;

    Navigator.pop(context, {
      'categoryId': categoryId,
      'categoryName': categoryName,
      'karat': _selectedKarat,
      'weight': weight,
      'wage': wage,
    });
  }

  int? _tryParseCategoryKarat(Map<String, dynamic> category) {
    final raw = category['karat'];
    final parsed = int.tryParse('${raw ?? ''}');
    if (parsed == null) return null;
    if (const [18, 21, 22, 24].contains(parsed)) return parsed;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _searchQuery.isEmpty
        ? widget.categories
        : widget.categories.where((c) {
            final name = (c['name'] ?? '').toString().trim().toLowerCase();
            return name.contains(_searchQuery);
          }).toList();

    final limited = filtered.take(100).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 550, maxHeight: 680),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFD4AF37).withValues(alpha: 0.15),
                      const Color(0xFFD4AF37).withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD4AF37),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.category,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 16),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'إضافة سطر تصنيف',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'اختر تصنيفاً وحدد التفاصيل',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Content
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Search field
                      TextFormField(
                        controller: _categorySearchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'ابحث عن التصنيف',
                          hintText: 'اكتب لتصفية النتائج...',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.search, size: 22),
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                        ),
                        onChanged: (v) {
                          setState(() {
                            _searchQuery = v.trim().toLowerCase();
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      // Categories list
                      FormField<int>(
                        validator: (_) =>
                            _selectedCategory == null ? 'الرجاء اختيار تصنيف' : null,
                        builder: (state) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'التصنيفات المتاحة (${limited.length})',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 220,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  border: Border.all(
                                    color: state.hasError
                                        ? theme.colorScheme.error
                                        : theme.dividerColor.withValues(alpha: 0.3),
                                    width: 1.5,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: limited.isEmpty
                                    ? Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.search_off,
                                              size: 56,
                                              color: theme.disabledColor,
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              'لا توجد نتائج',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                color: theme.disabledColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              'جرب البحث بكلمة أخرى',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                color: theme.disabledColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(8),
                                        itemCount: limited.length,
                                        itemBuilder: (_, index) {
                                          final opt = limited[index];
                                          final id = (opt['id'] is num)
                                              ? (opt['id'] as num).toInt()
                                              : int.tryParse('${opt['id']}');
                                          final name =
                                              (opt['name'] ?? '').toString();

                                          final isSelected =
                                              _selectedCategory != null &&
                                                  id != null &&
                                                  ((_selectedCategory?['id']
                                                          is num)
                                                      ? (_selectedCategory?['id']
                                                                  as num)
                                                              .toInt() ==
                                                          id
                                                      : int.tryParse(
                                                              '${_selectedCategory?['id']}') ==
                                                          id);

                                          return Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 6),
                                            child: Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                onTap: () {
                                                  setState(() {
                                                    _selectedCategory = opt;
                                                    final categoryKarat =
                                                        _tryParseCategoryKarat(opt);
                                                    if (categoryKarat != null) {
                                                      _selectedKarat = categoryKarat;
                                                    }
                                                  });
                                                  state.didChange(id);
                                                },
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: AnimatedContainer(
                                                  duration: const Duration(
                                                      milliseconds: 200),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 14,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: isSelected
                                                        ? const Color(0xFFD4AF37)
                                                            .withValues(
                                                                alpha: 0.2)
                                                        : theme.colorScheme
                                                            .surfaceContainerHighest
                                                            .withValues(
                                                                alpha: 0.3),
                                                    border: Border.all(
                                                      color: isSelected
                                                          ? const Color(
                                                              0xFFD4AF37)
                                                          : Colors.transparent,
                                                      width: 2,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            10),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.all(
                                                                6),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: isSelected
                                                              ? const Color(
                                                                      0xFFD4AF37)
                                                                  .withValues(
                                                                      alpha: 0.3)
                                                              : theme.colorScheme
                                                                  .surface,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(6),
                                                        ),
                                                        child: Icon(
                                                          Icons.label,
                                                          size: 18,
                                                          color: isSelected
                                                              ? const Color(
                                                                  0xFFD4AF37)
                                                              : theme.iconTheme
                                                                  .color,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          name,
                                                          style: TextStyle(
                                                            fontSize: 15,
                                                            fontWeight:
                                                                isSelected
                                                                    ? FontWeight
                                                                        .bold
                                                                    : FontWeight
                                                                        .w500,
                                                            color: isSelected
                                                                ? theme
                                                                    .colorScheme
                                                                    .onSurface
                                                                : null,
                                                          ),
                                                        ),
                                                      ),
                                                      if (isSelected)
                                                        Container(
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(2),
                                                          decoration:
                                                              const BoxDecoration(
                                                            color: Color(
                                                                0xFFD4AF37),
                                                            shape:
                                                                BoxShape.circle,
                                                          ),
                                                          child: const Icon(
                                                            Icons.check,
                                                            color: Colors.white,
                                                            size: 18,
                                                          ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                            ),
                            if (state.hasError) ...[
                              const SizedBox(height: 8),
                              Text(
                                state.errorText!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                      const SizedBox(height: 20),
                      // Karat, Weight, Wage in a grid
                      Text(
                        'تفاصيل الصنف',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: _selectedKarat,
                        decoration: InputDecoration(
                          labelText: 'العيار',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.diamond, size: 20),
                          filled: true,
                          fillColor: theme.colorScheme.surface,
                        ),
                        items: const [18, 21, 22, 24]
                            .map(
                              (k) => DropdownMenuItem<int>(
                                value: k,
                                child: Text('عيار $k'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() {
                          _selectedKarat = v ?? _selectedKarat;
                        }),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _weightController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: InputDecoration(
                                labelText: 'الوزن (جرام)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.scale, size: 20),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                              validator: (v) {
                                final val = _tryParseDouble(v ?? '', 0);
                                if (val <= 0) return 'وزن غير صحيح';
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _wageController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: InputDecoration(
                                labelText: 'المصنعية/جرام',
                                hintText: '0',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                prefixIcon: const Icon(Icons.build, size: 20),
                                filled: true,
                                fillColor: theme.colorScheme.surface,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4AF37).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFD4AF37).withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD4AF37).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Color(0xFFD4AF37),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'لا يتطلب باركود • يُستخدم للتتبع حسب التصنيف فقط',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Actions
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.5),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(20),
                  ),
                  border: Border(
                    top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('إلغاء'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.check, size: 20),
                      label: const Text('إضافة السطر'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4AF37),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        elevation: 2,
                        shadowColor:
                            const Color(0xFFD4AF37).withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== Barcode Scanner Widget ====================
class _BarcodeScannerPlaceholder extends StatefulWidget {
  @override
  State<_BarcodeScannerPlaceholder> createState() =>
      _BarcodeScannerPlaceholderState();
}

class _BarcodeScannerPlaceholderState
    extends State<_BarcodeScannerPlaceholder> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _isProcessing = false; // منع تكرار المسح

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'مسح الباركود 📷',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, child) {
                final torchState = value.torchState;
                switch (torchState) {
                  case TorchState.auto:
                  case TorchState.off:
                    return const Icon(Icons.flash_off, color: Colors.white);
                  case TorchState.on:
                    return const Icon(Icons.flash_on, color: Colors.yellow);
                  case TorchState.unavailable:
                    return const Icon(Icons.flash_off, color: Colors.grey);
                }
              },
            ),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_isProcessing) return; // منع التكرار

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final code = barcodes.first.rawValue;
                if (code != null && code.isNotEmpty) {
                  _isProcessing = true; // تعليم كـ "قيد المعالجة"
                  Navigator.pop(context, code);
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.symmetric(horizontal: 32),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '🎯 وجّه الكاميرا نحو الباركود',
                style: TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 🆕 Class لتخزين معلومات الدفعة
class PaymentEntry {
  int paymentMethodId;
  String paymentMethodName;
  double amount;
  double commissionRate;
  double commissionAmount;
  double commissionVat; // ضريبة القيمة المضافة على العمولة
  double netAmount;
  int settlementDays;
  String? notes;
  int? safeBoxId; // 🆕 معرف الخزينة

  PaymentEntry({
    required this.paymentMethodId,
    required this.paymentMethodName,
    required this.amount,
    required this.commissionRate,
    required this.commissionAmount,
    required this.commissionVat,
    required this.netAmount,
    required this.settlementDays,
    this.notes,
    this.safeBoxId, // 🆕
  });

  Map<String, dynamic> toJson() {
    return {
      'payment_method_id': paymentMethodId,
      'amount': amount,
      'commission_rate': commissionRate,
      'commission_amount': commissionAmount,
      'commission_vat': commissionVat,
      'net_amount': netAmount,
      'notes': notes,
      if (safeBoxId != null) 'safe_box_id': safeBoxId, // 🆕
    };
  }
}

class _BarterLine {
  int karat;
  final TextEditingController standingController = TextEditingController();
  final TextEditingController stonesController = TextEditingController();
  final TextEditingController pricePerGramController = TextEditingController();
  final TextEditingController totalAmountController = TextEditingController();

  _BarterLine({required this.karat});

  double standingWeight(double Function(dynamic) parseDouble) =>
      parseDouble(standingController.text);

  double stonesWeight(double Function(dynamic) parseDouble) =>
      parseDouble(stonesController.text);

  double netWeight(double Function(dynamic) parseDouble) {
    final standing = standingWeight(parseDouble);
    final stones = stonesWeight(parseDouble);
    final net = standing - stones;
    return net < 0 ? 0.0 : net;
  }

  double pricePerGram(double Function(dynamic) parseDouble) =>
      parseDouble(pricePerGramController.text);

  double effectivePricePerGram(
    double Function(dynamic) parseDouble,
    double goldPrice24k,
  ) {
    final entered = pricePerGram(parseDouble);
    if (entered > 0) return entered;
    if (goldPrice24k <= 0) return 0.0;
    return goldPrice24k * (karat / 24.0);
  }

  double value(double Function(dynamic) parseDouble, double goldPrice24k) {
    final v =
        netWeight(parseDouble) *
        effectivePricePerGram(parseDouble, goldPrice24k);
    return double.tryParse(v.toStringAsFixed(2)) ?? 0.0;
  }

  void dispose() {
    standingController.dispose();
    stonesController.dispose();
    pricePerGramController.dispose();
    totalAmountController.dispose();
  }
}
