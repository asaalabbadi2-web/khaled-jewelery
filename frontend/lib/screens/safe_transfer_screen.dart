import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart';

class SafeTransferScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final String initialMode; // gold | cash
  final int? initialFromSafeId;
  final int? initialToSafeId;
  final String? initialNotes;
  final bool popOnSuccess;

  const SafeTransferScreen({
    super.key,
    required this.api,
    this.isArabic = true,
    this.initialMode = 'gold',
    this.initialFromSafeId,
    this.initialToSafeId,
    this.initialNotes,
    this.popOnSuccess = false,
  });

  @override
  State<SafeTransferScreen> createState() => _SafeTransferScreenState();
}

class _SafeTransferScreenState extends State<SafeTransferScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _mode; // gold | cash | karat_correction

  List<SafeBoxModel> _safes = <SafeBoxModel>[];
  final Map<int, SafeBoxModel> _safeById = <int, SafeBoxModel>{};
  bool _isLoadingSafes = false;

  // Stones balance per safe: safeId -> {total, 18, 21, 22, 24}
  Map<int, Map<String, double>> _stonesBalance = {};

  int? _fromSafeId;
  int? _toSafeId;

  // karat_correction fields
  int _corrFromKarat = 21;
  int _corrToKarat = 18;
  final _corrWeightController = TextEditingController();

  final _amountCashController = TextEditingController();

  final _weight24kController = TextEditingController();
  final _weight22kController = TextEditingController();
  final _weight21kController = TextEditingController();
  final _weight18kController = TextEditingController();

  // Stones weight inputs per karat
  final _stones24kController = TextEditingController();
  final _stones22kController = TextEditingController();
  final _stones21kController = TextEditingController();
  final _stones18kController = TextEditingController();

  final _notesController = TextEditingController();

  bool _isSubmitting = false;

  static const double _epsilon = 0.0001;
  static const List<int> _karats = [24, 22, 21, 18];

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _notesController.text = widget.initialNotes ?? '';

    _amountCashController.addListener(_onInputChanged);
    _weight24kController.addListener(_onInputChanged);
    _weight22kController.addListener(_onInputChanged);
    _weight21kController.addListener(_onInputChanged);
    _weight18kController.addListener(_onInputChanged);
    _stones24kController.addListener(_onInputChanged);
    _stones22kController.addListener(_onInputChanged);
    _stones21kController.addListener(_onInputChanged);
    _stones18kController.addListener(_onInputChanged);
    _corrWeightController.addListener(_onInputChanged);

    _loadSafes();
  }

  void _onInputChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _amountCashController.dispose();
    _weight24kController.dispose();
    _weight22kController.dispose();
    _weight21kController.dispose();
    _weight18kController.dispose();
    _stones24kController.dispose();
    _stones22kController.dispose();
    _stones21kController.dispose();
    _stones18kController.dispose();
    _corrWeightController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String _typeLabel(String? safeType) {
    final isAr = widget.isArabic;
    switch ((safeType ?? '').toLowerCase()) {
      case 'gold':
        return isAr ? 'ذهب' : 'Gold';
      case 'cash':
        return isAr ? 'نقدي' : 'Cash';
      case 'bank':
        return isAr ? 'بنك' : 'Bank';
      case 'clearing':
        return isAr ? 'تحصيل' : 'Clearing';
      case 'check':
        return isAr ? 'شيكات' : 'Checks';
      default:
        return isAr ? 'أخرى' : 'Other';
    }
  }

  Future<void> _loadSafes() async {
    setState(() => _isLoadingSafes = true);
    try {
      // Prefer ledger-based balances so we can show available balance per safe.
      final rows = await widget.api.getSafeBoxBalances(
        type: _mode == 'gold' ? 'gold' : null,
        isActive: true,
      );

      // Load stones balance alongside safes
      widget.api.getStonesBalance().then((sb) {
        if (mounted) setState(() => _stonesBalance = sb);
      }).catchError((_) {});

      final usable = rows.where((s) => s.id != null).toList();
      final filtered = (_mode == 'gold' || _mode == 'karat_correction')
          ? usable.where((s) => s.safeType.toLowerCase() == 'gold').toList()
          : usable.where((s) => s.safeType.toLowerCase() != 'gold').toList();

      filtered.sort((a, b) {
        if (_mode == 'gold') {
          final ka = a.karat ?? 0;
          final kb = b.karat ?? 0;
          final byKarat = ka.compareTo(kb);
          if (byKarat != 0) return byKarat;
          return a.name.compareTo(b.name);
        }

        final ta = a.safeType.toLowerCase();
        final tb = b.safeType.toLowerCase();
        final byType = ta.compareTo(tb);
        if (byType != 0) return byType;
        return a.name.compareTo(b.name);
      });

      if (!mounted) return;
      setState(() {
        _safes = filtered;
        _safeById
          ..clear()
          ..addEntries(
            filtered
                .where((s) => s.id != null)
                .map((s) => MapEntry<int, SafeBoxModel>(s.id!, s)),
          );
        final filteredIds = filtered
            .where((s) => s.id != null)
            .map((s) => s.id!)
            .toSet();
        if (_fromSafeId == null &&
            widget.initialFromSafeId != null &&
            filteredIds.contains(widget.initialFromSafeId)) {
          _fromSafeId = widget.initialFromSafeId;
        }
        if (_toSafeId == null &&
            widget.initialToSafeId != null &&
            filteredIds.contains(widget.initialToSafeId) &&
            widget.initialToSafeId != _fromSafeId) {
          _toSafeId = widget.initialToSafeId;
        }
        _isLoadingSafes = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSafes = false);
      _showSnack(
        widget.isArabic ? 'فشل تحميل الخزائن: $e' : 'Failed to load safes: $e',
        isError: true,
      );
    }
  }

  SafeBoxModel? _safeByIdOrNull(int? id) {
    if (id == null) return null;
    return _safeById[id];
  }

  String _fmtCash(double value) {
    return value.toStringAsFixed(2);
  }

  String _fmtWeight(double value) {
    return value.toStringAsFixed(3);
  }

  Widget _balanceCard({required String title, required SafeBoxModel safe}) {
    final isAr = widget.isArabic;
    final stonesInfo = _stonesBalance[safe.id] ?? {};
    final totalStones = stonesInfo['total'] ?? 0.0;

    final content = _mode == 'cash'
        ? Text(
            isAr
                ? 'الرصيد المتاح: ${_fmtCash(safe.cashBalance)} ر.س'
                : 'Available: ${_fmtCash(safe.cashBalance)}',
            style: TextStyle(color: Colors.grey.shade800),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAr ? 'الرصيد المتاح (غرام):' : 'Available (g):',
                style: TextStyle(color: Colors.grey.shade800),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _karatChip(
                    '24k',
                    safe.goldBalance24k,
                    Colors.yellow.shade800,
                  ),
                  _karatChip(
                    '22k',
                    safe.goldBalance22k,
                    Colors.yellow.shade700,
                  ),
                  _karatChip(
                    '21k',
                    safe.goldBalance21k,
                    Colors.yellow.shade600,
                  ),
                  _karatChip(
                    '18k',
                    safe.goldBalance18k,
                    Colors.yellow.shade500,
                  ),
                ],
              ),
              // ── Stones balance ────────────────────────────
              if (totalStones > 0.0001) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.diamond_outlined, size: 12, color: Color(0xFFB56A2F)),
                  const SizedBox(width: 4),
                  Text(
                    '${_fmtWeight(totalStones)} جم',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB56A2F)),
                  ),
                ]),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 4, runSpacing: 3,
                  children: [
                    for (final k in ['18', '21', '22', '24'])
                      if ((stonesInfo[k] ?? 0.0) > 0.0001)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB56A2F).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFB56A2F).withValues(alpha: 0.25)),
                          ),
                          child: Text(
                            '$k: ${_fmtWeight(stonesInfo[k] ?? 0.0)}',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFFB56A2F)),
                          ),
                        ),
                  ],
                ),
              ],
            ],
          );

    return Card(
      color: AppColors.lightGold.withOpacity(0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.darkGold,
              ),
            ),
            const SizedBox(height: 8),
            content,
          ],
        ),
      ),
    );
  }

  Widget _karatChip(String label, double value, Color color) {
    return Chip(
      avatar: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      label: Text(
        '$label: ${_fmtWeight(value)}',
        style: const TextStyle(
          color: Colors.black87,
          fontWeight: FontWeight.w700,
        ),
      ),
      backgroundColor: color.withValues(alpha: 0.22),
      side: BorderSide(color: color.withValues(alpha: 0.85), width: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      visualDensity: VisualDensity.compact,
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  double _parseDouble(String value) {
    try {
      return double.parse(value.trim());
    } catch (_) {
      return 0.0;
    }
  }

  bool _validateGoldWeights() {
    final w24 = _parseDouble(_weight24kController.text);
    final w22 = _parseDouble(_weight22kController.text);
    final w21 = _parseDouble(_weight21kController.text);
    final w18 = _parseDouble(_weight18kController.text);
    return (w24 + w22 + w21 + w18) > 0;
  }

  String? _cashOverdraftError() {
    if (_mode != 'cash') return null;
    final fromSafe = _safeByIdOrNull(_fromSafeId);
    if (fromSafe == null) return null;
    final amount = _parseDouble(_amountCashController.text);
    if (amount <= 0) return null;
    if (amount > fromSafe.cashBalance + _epsilon) {
      return widget.isArabic
          ? 'المبلغ أكبر من الرصيد المتاح (${_fmtCash(fromSafe.cashBalance)} ر.س)'
          : 'Exceeds available (${_fmtCash(fromSafe.cashBalance)})';
    }
    return null;
  }

  String? _goldOverdraftError(String karat) {
    if (_mode != 'gold') return null;
    final fromSafe = _safeByIdOrNull(_fromSafeId);
    if (fromSafe == null) return null;

    final entered = switch (karat) {
      '24k' => _parseDouble(_weight24kController.text),
      '22k' => _parseDouble(_weight22kController.text),
      '21k' => _parseDouble(_weight21kController.text),
      '18k' => _parseDouble(_weight18kController.text),
      _ => 0.0,
    };
    if (entered <= 0) return null;

    final available = switch (karat) {
      '24k' => fromSafe.goldBalance24k,
      '22k' => fromSafe.goldBalance22k,
      '21k' => fromSafe.goldBalance21k,
      '18k' => fromSafe.goldBalance18k,
      _ => 0.0,
    };

    if (entered > available + _epsilon) {
      return widget.isArabic
          ? 'أكبر من المتاح (${_fmtWeight(available)} g)'
          : 'Exceeds (${_fmtWeight(available)} g)';
    }
    return null;
  }

  /// رصيد العيار المصدر في خزينة التصحيح
  double _corrAvailableBalance() {
    final safe = _safeByIdOrNull(_fromSafeId);
    if (safe == null) return 0.0;
    return switch (_corrFromKarat) {
      24 => safe.goldBalance24k,
      22 => safe.goldBalance22k,
      21 => safe.goldBalance21k,
      18 => safe.goldBalance18k,
      _ => 0.0,
    };
  }

  String? _corrOverdraftError() {
    if (_mode != 'karat_correction') return null;
    final weight = _parseDouble(_corrWeightController.text);
    if (weight <= 0) return null;
    final available = _corrAvailableBalance();
    if (weight > available + _epsilon) {
      return widget.isArabic
          ? 'أكبر من المتاح (${_fmtWeight(available)} جم)'
          : 'Exceeds available (${_fmtWeight(available)} g)';
    }
    return null;
  }

  // ── Stones balance validation ──────────────────────────
  String? _stonesOverdraftError(String karat) {
    if (_mode != 'gold') return null;
    final fromSafe = _safeByIdOrNull(_fromSafeId);
    if (fromSafe == null) return null;

    final stonesInfo = _stonesBalance[fromSafe.id] ?? {};
    final entered = switch (karat) {
      '24k' => _parseDouble(_stones24kController.text),
      '22k' => _parseDouble(_stones22kController.text),
      '21k' => _parseDouble(_stones21kController.text),
      '18k' => _parseDouble(_stones18kController.text),
      _ => 0.0,
    };
    if (entered <= 0) return null;

    final available = switch (karat) {
      '24k' => stonesInfo['24'] ?? 0.0,
      '22k' => stonesInfo['22'] ?? 0.0,
      '21k' => stonesInfo['21'] ?? 0.0,
      '18k' => stonesInfo['18'] ?? 0.0,
      _ => 0.0,
    };

    if (entered > available + _epsilon) {
      return widget.isArabic
          ? 'أكبر من المتاح (${_fmtWeight(available)} g)'
          : 'Exceeds (${_fmtWeight(available)} g)';
    }
    return null;
  }

  Future<void> _submitTransfer() async {
    if (!_formKey.currentState!.validate()) return;

    // ── تصحيح العيار ──
    if (_mode == 'karat_correction') {
      if (_fromSafeId == null) {
        _showSnack(
          widget.isArabic ? 'يجب اختيار الخزينة' : 'Select a safe',
          isError: true,
        );
        return;
      }
      if (_corrFromKarat == _corrToKarat) {
        _showSnack(
          widget.isArabic
              ? 'العيار الأصلي والمصحَّح متطابقان'
              : 'Karats must differ',
          isError: true,
        );
        return;
      }
      final weight = _parseDouble(_corrWeightController.text);
      if (weight <= 0) {
        _showSnack(
          widget.isArabic ? 'يجب إدخال وزن صحيح' : 'Enter a valid weight',
          isError: true,
        );
        return;
      }
      if (_corrOverdraftError() != null) {
        _showSnack(_corrOverdraftError()!, isError: true);
        return;
      }

      setState(() => _isSubmitting = true);
      try {
        final result = await widget.api.correctSafeBoxKarat(
          safeBoxId: _fromSafeId!,
          fromKarat: _corrFromKarat,
          toKarat: _corrToKarat,
          weight: weight,
          notes: _notesController.text.trim().isNotEmpty
              ? _notesController.text.trim()
              : null,
        );

        if (!mounted) return;
        _showSnack(
          widget.isArabic ? 'تم تصحيح العيار بنجاح' : 'Karat corrected',
        );
        setState(() {
          _fromSafeId = null;
          _corrWeightController.clear();
          _notesController.clear();
        });

        final voucher = result['voucher'] as Map<String, dynamic>?;
        final correction = result['correction'] as Map<String, dynamic>?;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              widget.isArabic ? 'تم تصحيح العيار' : 'Karat Corrected',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isArabic
                      ? 'رقم السند: ${voucher?['voucher_number'] ?? '-'}'
                      : 'Voucher: ${voucher?['voucher_number'] ?? '-'}',
                ),
                const SizedBox(height: 6),
                Text(
                  widget.isArabic
                      ? 'الخزينة:  ${correction?['safe_name'] ?? '-'}'
                      : 'Safe: ${correction?['safe_name'] ?? '-'}',
                ),
                Text(
                  widget.isArabic
                      ? 'من عيار:  ${correction?['from_karat']}k → إلى عيار: ${correction?['to_karat']}k'
                      : 'From: ${correction?['from_karat']}k → To: ${correction?['to_karat']}k',
                ),
                Text(
                  widget.isArabic
                      ? 'الوزن:  ${correction?['weight']} جم'
                      : 'Weight: ${correction?['weight']} g',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(widget.isArabic ? 'حسناً' : 'OK'),
              ),
            ],
          ),
        );
      } catch (e) {
        if (!mounted) return;
        _showSnack(
          widget.isArabic ? 'فشل تصحيح العيار: $e' : 'Failed: $e',
          isError: true,
        );
      } finally {
        if (mounted) setState(() => _isSubmitting = false);
      }
      return;
    }

    // ── التحويل بين الخزائن (gold / cash) ──
    if (_fromSafeId == null || _toSafeId == null) {
      _showSnack(
        widget.isArabic
            ? 'يجب اختيار خزينة المصدر والوجهة'
            : 'Select both source and destination',
        isError: true,
      );
      return;
    }

    if (_fromSafeId == _toSafeId) {
      _showSnack(
        widget.isArabic
            ? 'لا يمكن التحويل إلى نفس الخزينة'
            : 'Cannot transfer to the same safe',
        isError: true,
      );
      return;
    }

    if (_mode == 'gold' && !_validateGoldWeights()) {
      _showSnack(
        widget.isArabic
            ? 'يجب إدخال وزن واحد على الأقل'
            : 'Enter at least one weight',
        isError: true,
      );
      return;
    }

    if (_mode == 'cash') {
      final amount = _parseDouble(_amountCashController.text);
      if (amount <= 0) {
        _showSnack(
          widget.isArabic ? 'يجب إدخال مبلغ صحيح' : 'Enter a valid amount',
          isError: true,
        );
        return;
      }

      final fromSafe = _safeByIdOrNull(_fromSafeId);
      if (fromSafe != null && amount > fromSafe.cashBalance + 0.0001) {
        _showSnack(
          widget.isArabic
              ? 'المبلغ أكبر من رصيد الخزينة المتاح (${_fmtCash(fromSafe.cashBalance)} ر.س)'
              : 'Amount exceeds available balance (${_fmtCash(fromSafe.cashBalance)})',
          isError: true,
        );
        return;
      }
    }

    if (_mode == 'gold') {
      final fromSafe = _safeByIdOrNull(_fromSafeId);
      if (fromSafe != null) {
        final w24 = _parseDouble(_weight24kController.text);
        final w22 = _parseDouble(_weight22kController.text);
        final w21 = _parseDouble(_weight21kController.text);
        final w18 = _parseDouble(_weight18kController.text);

        final short = fromSafe.karatsShortFor(
            {'24k': w24, '22k': w22, '21k': w21, '18k': w18});

        if (short.isNotEmpty) {
          _showSnack(
            widget.isArabic
                ? 'أحد الأوزان المدخلة أكبر من الرصيد المتاح في خزينة المصدر'
                : 'One of the entered weights exceeds available balance',
            isError: true,
          );
          return;
        }

        // Validate stones
        final s24 = _parseDouble(_stones24kController.text);
        final s22 = _parseDouble(_stones22kController.text);
        final s21 = _parseDouble(_stones21kController.text);
        final s18 = _parseDouble(_stones18kController.text);

        if ((s24 + s22 + s21 + s18) > 0) {
          final sOver24 = _stonesOverdraftError('24k') != null;
          final sOver22 = _stonesOverdraftError('22k') != null;
          final sOver21 = _stonesOverdraftError('21k') != null;
          final sOver18 = _stonesOverdraftError('18k') != null;

          if (sOver24 || sOver22 || sOver21 || sOver18) {
            _showSnack(
              widget.isArabic
                  ? 'أحد أوزان الفصوص أكبر من الرصيد المتاح'
                  : 'One of the stones weights exceeds available balance',
              isError: true,
            );
            return;
          }
        }
      }
    }

    setState(() => _isSubmitting = true);

    try {
      final notes = _notesController.text.trim().isNotEmpty
          ? _notesController.text.trim()
          : null;

      Map<String, dynamic> result;
      if (_mode == 'gold') {
        final weights = <String, double>{};
        final stones = <String, double>{};

        final w24 = _parseDouble(_weight24kController.text);
        final w22 = _parseDouble(_weight22kController.text);
        final w21 = _parseDouble(_weight21kController.text);
        final w18 = _parseDouble(_weight18kController.text);

        if (w24 > 0) weights['24k'] = w24;
        if (w22 > 0) weights['22k'] = w22;
        if (w21 > 0) weights['21k'] = w21;
        if (w18 > 0) weights['18k'] = w18;

        final s24 = _parseDouble(_stones24kController.text);
        final s22 = _parseDouble(_stones22kController.text);
        final s21 = _parseDouble(_stones21kController.text);
        final s18 = _parseDouble(_stones18kController.text);

        if (s24 > 0) stones['24k'] = s24;
        if (s22 > 0) stones['22k'] = s22;
        if (s21 > 0) stones['21k'] = s21;
        if (s18 > 0) stones['18k'] = s18;

        result = await widget.api.createSafeBoxTransferVoucher(
          fromSafeBoxId: _fromSafeId!,
          toSafeBoxId: _toSafeId!,
          weights: weights,
          stonesWeights: stones.isNotEmpty ? stones : null,
          notes: notes,
          date: DateTime.now(),
        );
      } else {
        final amount = _parseDouble(_amountCashController.text);
        result = await widget.api.createSafeBoxTransferVoucher(
          fromSafeBoxId: _fromSafeId!,
          toSafeBoxId: _toSafeId!,
          amountCash: amount,
          notes: notes,
          date: DateTime.now(),
        );
      }

      if (!mounted) return;

      _showSnack(
        widget.isArabic
            ? 'تم إنشاء سند التحويل بنجاح'
            : 'Transfer voucher created',
      );

      // Reset
      setState(() {
        _fromSafeId = null;
        _toSafeId = null;
        _amountCashController.clear();
        _weight24kController.clear();
        _weight22kController.clear();
        _weight21kController.clear();
        _weight18kController.clear();
        _stones24kController.clear();
        _stones22kController.clear();
        _stones21kController.clear();
        _stones18kController.clear();
        _notesController.clear();
      });

      await showDialog<void>(
        context: context,
        builder: (context) {
          final voucher = result['voucher'] as Map<String, dynamic>?;
          final transfer = result['transfer'] as Map<String, dynamic>?;
          return AlertDialog(
            title: Text(
              widget.isArabic
                  ? 'تم إنشاء سند التحويل'
                  : 'Transfer Voucher Created',
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.isArabic
                        ? 'رقم السند: ${voucher?['voucher_number'] ?? '-'}'
                        : 'Voucher: ${voucher?['voucher_number'] ?? '-'}',
                  ),
                  const SizedBox(height: 8),
                  if (_mode == 'cash')
                    Text(
                      widget.isArabic
                          ? 'المبلغ: ${transfer?['amount_cash'] ?? '-'} ر.س'
                          : 'Amount: ${transfer?['amount_cash'] ?? '-'}',
                    ),
                  if (_mode == 'gold') ...[
                    Text(widget.isArabic ? 'الأوزان:' : 'Weights:'),
                    const SizedBox(height: 4),
                    Text(
                      '24k: ${(transfer?['weights']?['24k'] ?? 0).toString()}',
                    ),
                    Text(
                      '22k: ${(transfer?['weights']?['22k'] ?? 0).toString()}',
                    ),
                    Text(
                      '21k: ${(transfer?['weights']?['21k'] ?? 0).toString()}',
                    ),
                    Text(
                      '18k: ${(transfer?['weights']?['18k'] ?? 0).toString()}',
                    ),
                    if ((transfer?['stones'] as Map<String, dynamic>?)?.isNotEmpty ?? false) ...[
                      const SizedBox(height: 8),
                      Text(widget.isArabic ? 'الفصوص:' : 'Stones:'),
                      const SizedBox(height: 4),
                      Text(
                        '24k: ${(transfer?['stones']?['24k'] ?? 0).toString()}',
                      ),
                      Text(
                        '22k: ${(transfer?['stones']?['22k'] ?? 0).toString()}',
                      ),
                      Text(
                        '21k: ${(transfer?['stones']?['21k'] ?? 0).toString()}',
                      ),
                      Text(
                        '18k: ${(transfer?['stones']?['18k'] ?? 0).toString()}',
                      ),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(widget.isArabic ? 'حسناً' : 'OK'),
              ),
            ],
          );
        },
      );

      if (widget.popOnSuccess && mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        widget.isArabic
            ? 'فشل إنشاء سند التحويل: $e'
            : 'Failed to create transfer: $e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    final fromSafe = _safeByIdOrNull(_fromSafeId);
    final toSafe = _mode != 'karat_correction'
        ? _safeByIdOrNull(_toSafeId)
        : null;

    final cashOverdraft = _cashOverdraftError();
    final goldOver24 = _goldOverdraftError('24k');
    final goldOver22 = _goldOverdraftError('22k');
    final goldOver21 = _goldOverdraftError('21k');
    final goldOver18 = _goldOverdraftError('18k');
    final corrOverdraft = _corrOverdraftError();

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'إدارة الخزائن' : 'Safe Management'),
        backgroundColor: AppColors.darkGold,
      ),
      body: _isLoadingSafes
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      color: AppColors.lightGold.withOpacity(0.1),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: AppColors.darkGold),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                isAr
                                    ? 'يمكنك التحويل بين خزائن الذهب (بالوزن)، أو بين الخزائن النقدية/البنكية (بالمبلغ)، أو تصحيح عيار مُدخَل خطأً في نفس الخزينة'
                                    : 'Transfer between gold safes (weights), cash/bank safes (amount), or correct a mis-recorded karat in the same safe',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    DropdownButtonFormField<String>(
                      value: _mode,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        prefixIcon: Icon(
                          Icons.swap_horiz,
                          color: AppColors.darkGold,
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        labelText: isAr ? 'نوع العملية' : 'Operation Type',
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'gold',
                          child: Text(
                            isAr
                                ? 'تحويل ذهب بين الخزائن (بالوزن)'
                                : 'Gold transfer (weights)',
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'cash',
                          child: Text(
                            isAr
                                ? 'تحويل نقدي/بنكي (بالمبلغ)'
                                : 'Cash/Bank transfer (amount)',
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'karat_correction',
                          child: Text(
                            isAr
                                ? 'تصحيح عيار (خطأ تسجيل)'
                                : 'Karat correction (entry error)',
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null || value == _mode) return;
                        setState(() {
                          _mode = value;
                          _fromSafeId = null;
                          _toSafeId = null;
                          _amountCashController.clear();
                          _weight24kController.clear();
                          _weight22kController.clear();
                          _weight21kController.clear();
                          _weight18kController.clear();
                          _stones24kController.clear();
                          _stones22kController.clear();
                          _stones21kController.clear();
                          _stones18kController.clear();
                          _corrWeightController.clear();
                        });
                        _loadSafes();
                      },
                    ),

                    const SizedBox(height: 16),

                    DropdownButtonFormField<int>(
                      value: _fromSafeId,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        prefixIcon: Icon(
                          Icons.inventory_2,
                          color: AppColors.darkGold,
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade50,
                        labelText: isAr ? 'من خزينة' : 'From Safe',
                      ),
                      items: _safes
                          .map(
                            (safe) => DropdownMenuItem<int>(
                              value: safe.id!,
                              child: Text(
                                _mode == 'cash'
                                    ? '${safe.name} (${_typeLabel(safe.safeType)})'
                                    : safe.name,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => _fromSafeId = value),
                      validator: (value) =>
                          value == null ? (isAr ? 'مطلوب' : 'Required') : null,
                    ),

                    if (fromSafe != null) ...[
                      const SizedBox(height: 10),
                      _balanceCard(
                        title: isAr ? 'رصيد خزينة المصدر' : 'Source Balance',
                        safe: fromSafe,
                      ),
                    ],

                    // ── تصحيح العيار: لا نحتاج "إلى خزينة" ──
                    if (_mode != 'karat_correction') ...[
                      const SizedBox(height: 16),

                      DropdownButtonFormField<int>(
                        value: _toSafeId,
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.inventory_2_outlined,
                            color: AppColors.darkGold,
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          labelText: isAr ? 'إلى خزينة' : 'To Safe',
                        ),
                        items: _safes
                            .map(
                              (safe) => DropdownMenuItem<int>(
                                value: safe.id!,
                                child: Text(
                                  _mode == 'cash'
                                      ? '${safe.name} (${_typeLabel(safe.safeType)})'
                                      : safe.name,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => _toSafeId = value),
                        validator: (value) {
                          if (_mode == 'karat_correction') return null;
                          if (value == null) return isAr ? 'مطلوب' : 'Required';
                          if (value == _fromSafeId) {
                            return isAr
                                ? 'لا يمكن نفس الخزينة'
                                : 'Cannot be same safe';
                          }
                          return null;
                        },
                      ),

                      if (toSafe != null) ...[
                        const SizedBox(height: 10),
                        _balanceCard(
                          title: isAr
                              ? 'رصيد خزينة الوجهة'
                              : 'Destination Balance',
                          safe: toSafe,
                        ),
                      ],
                    ],

                    const SizedBox(height: 16),

                    // ── حقول تصحيح العيار ──
                    if (_mode == 'karat_correction') ...[
                      Card(
                        color: Colors.orange.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.orange.shade700,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isAr
                                      ? 'يُستخدم هذا الوضع لتصحيح عيار مُسجَّل خطأً. الوزن لا يتغير — فقط خانة العيار تتصحح.'
                                      : 'Use this to fix a mis-recorded karat. The weight stays the same — only the karat column is corrected.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.orange.shade800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _corrFromKarat,
                              decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                labelText: isAr
                                    ? 'العيار الخاطئ (من)'
                                    : 'Wrong karat (from)',
                                prefixIcon: Icon(
                                  Icons.remove_circle_outline,
                                  color: Colors.red.shade400,
                                ),
                              ),
                              items: _karats
                                  .map(
                                    (k) => DropdownMenuItem(
                                      value: k,
                                      child: Text('$k k'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _corrFromKarat = v);
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Icon(
                              Icons.arrow_forward,
                              color: AppColors.darkGold,
                            ),
                          ),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: _corrToKarat,
                              decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                labelText: isAr
                                    ? 'العيار الصحيح (إلى)'
                                    : 'Correct karat (to)',
                                prefixIcon: Icon(
                                  Icons.add_circle_outline,
                                  color: Colors.green.shade600,
                                ),
                              ),
                              items: _karats
                                  .map(
                                    (k) => DropdownMenuItem(
                                      value: k,
                                      child: Text('$k k'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _corrToKarat = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        controller: _corrWeightController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'الوزن (غرام)' : 'Weight (g)',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.scale,
                            color: AppColors.darkGold,
                          ),
                          errorText: corrOverdraft,
                          helperText: fromSafe != null
                              ? (isAr
                                    ? 'المتاح من عيار ${_corrFromKarat}k: ${_fmtWeight(_corrAvailableBalance())} جم'
                                    : 'Available ${_corrFromKarat}k: ${_fmtWeight(_corrAvailableBalance())} g')
                              : null,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    if (_mode == 'cash') ...[
                      TextField(
                        controller: _amountCashController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'المبلغ (ر.س)' : 'Amount',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.payments,
                            color: AppColors.darkGold,
                          ),
                          errorText: cashOverdraft,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    if (_mode == 'gold') ...[
                      Text(
                        isAr ? 'الأوزان (غرام)' : 'Weights (g)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _weight24kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 24' : '24k',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond,
                            color: Colors.yellow.shade800,
                          ),
                          errorText: goldOver24,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _weight22kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 22' : '22k',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond,
                            color: Colors.yellow.shade700,
                          ),
                          errorText: goldOver22,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _weight21kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 21' : '21k',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond,
                            color: Colors.yellow.shade600,
                          ),
                          errorText: goldOver21,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _weight18kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 18' : '18k',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond,
                            color: Colors.yellow.shade500,
                          ),
                          errorText: goldOver18,
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Stones weights (optional) ──────────────────────
                      Text(
                        isAr ? 'الفصوص (اختياري)' : 'Stones (optional)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _stones24kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 24 - فصوص' : '24k Stones',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond_outlined,
                            color: Colors.orange.shade400,
                          ),
                          errorText: _stonesOverdraftError('24k'),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _stones22kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 22 - فصوص' : '22k Stones',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond_outlined,
                            color: Colors.orange.shade400,
                          ),
                          errorText: _stonesOverdraftError('22k'),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _stones21kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 21 - فصوص' : '21k Stones',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond_outlined,
                            color: Colors.orange.shade400,
                          ),
                          errorText: _stonesOverdraftError('21k'),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _stones18kController,
                        decoration: InputDecoration(
                          labelText: isAr ? 'عيار 18 - فصوص' : '18k Stones',
                          border: const OutlineInputBorder(),
                          prefixIcon: Icon(
                            Icons.diamond_outlined,
                            color: Colors.orange.shade400,
                          ),
                          errorText: _stonesOverdraftError('18k'),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    TextField(
                      controller: _notesController,
                      decoration: InputDecoration(
                        labelText: isAr
                            ? 'ملاحظات (اختياري)'
                            : 'Notes (optional)',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.note),
                      ),
                      maxLines: 3,
                    ),

                    const SizedBox(height: 24),

                    ElevatedButton.icon(
                      onPressed: _isSubmitting ? null : _submitTransfer,
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Icon(Icons.swap_horiz),
                      label: Text(
                        _isSubmitting
                            ? (isAr ? 'جاري التنفيذ...' : 'Processing...')
                            : _mode == 'karat_correction'
                            ? (isAr ? 'تصحيح العيار' : 'Correct Karat')
                            : (isAr
                                  ? 'إنشاء سند التحويل'
                                  : 'Create Transfer Voucher'),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.darkGold,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
