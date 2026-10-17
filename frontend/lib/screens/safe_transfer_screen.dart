import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_leave_guard.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import 'voucher_details_screen.dart';

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

  /// The safes were loaded once: a later load (a mode changed) keeps the page
  /// and shows a thin bar, not the whole screen's skeleton.
  bool _loadedOnce = false;

  /// Karats shown beyond those the source holds («عيار آخر»).
  final Set<int> _extraKarats = {};
  bool _showStones = false;
  bool _showNotes = false;

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
      widget.api
          .getStonesBalance()
          .then((sb) {
            if (mounted) setState(() => _stonesBalance = sb);
          })
          .catchError((_) {});

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
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingSafes = false);
      AppFeedback.error(
        context,
        e,
        title: widget.isArabic ? 'فشل تحميل الخزائن' : 'Failed to load safes',
      );
    }
  }

  SafeBoxModel? _safeByIdOrNull(int? id) {
    if (id == null) return null;
    return _safeById[id];
  }

  String _fmtCash(double value) => ltrIsolate(formatAmount(value));

  /// Grams as Arabic reads them: the number whole and left-to-right, then
  /// its unit after it.
  String _fmtWeight(double value) =>
      '${ltrIsolate(formatGrams(value))} ${widget.isArabic ? 'جم' : 'g'}';

  void _showSnack(String message, {bool isError = false}) {
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
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

  String _gramsText(double grams) =>
      ltrIsolate('${formatGrams(grams)} ${widget.isArabic ? 'جم' : 'g'}');

  /// Says the voucher is posted, its number, and «عرض السند» to open it
  /// (ADR-050, خ٢) -- in place of a dialog that listed what was just typed.
  void _announcePosted(Map<String, dynamic>? voucher, String done) {
    final number = (voucher?['voucher_number'] ?? '').toString();
    final id = voucher?['id'];
    final navigator = Navigator.of(context);
    AppFeedback.success(
      context,
      number.isEmpty ? done : '$done: ${ltrIsolate(number)}',
      action: id is int
          ? (
              label: widget.isArabic ? 'عرض السند' : 'View voucher',
              onPressed: () => navigator.push(
                MaterialPageRoute(
                  builder: (_) => VoucherDetailsScreen(voucherId: id),
                ),
              ),
            )
          : null,
    );
  }

  /// Asks before a voucher that posts at once (ADR-050, خ١); true to go on.
  Future<bool> _confirmPosting({
    required String title,
    required String effect,
    required String confirmLabel,
    required List<(String, String)> facts,
  }) async {
    final answer = await confirmFinancialAction(
      context,
      title: title,
      effect: effect,
      confirmLabel: confirmLabel,
      facts: facts,
      destructive: false,
      backLabel: widget.isArabic ? 'تراجع' : 'Back',
    );
    return answer != null && mounted;
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

      // The correction posts at once: asked first (ADR-050, خ١).
      if (!await _confirmPosting(
        title: widget.isArabic ? 'تصحيح العيار؟' : 'Correct the karat?',
        effect: widget.isArabic
            ? 'يُنشأ سند معتمد ويُرحَّل قيده الآن: ينقص الوزن من العيار الأصلي ويُضاف إلى العيار المصحَّح في الخزينة نفسها.'
            : 'An approved voucher is created and posted now: the weight leaves the recorded karat and enters the corrected one, in the same safe.',
        confirmLabel: widget.isArabic ? 'تصحيح العيار' : 'Correct',
        facts: [
          (
            widget.isArabic ? 'الخزينة' : 'Safe',
            _safeByIdOrNull(_fromSafeId)?.name ?? '-',
          ),
          (
            widget.isArabic ? 'من عيار ← إلى عيار' : 'From → to karat',
            ltrIsolate('${_corrFromKarat}k → ${_corrToKarat}k'),
          ),
          (widget.isArabic ? 'الوزن' : 'Weight', _gramsText(weight)),
        ],
      )) {
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
        setState(() {
          _fromSafeId = null;
          _corrWeightController.clear();
          _notesController.clear();
        });
        _announcePosted(
          result['voucher'] as Map<String, dynamic>?,
          widget.isArabic ? 'صُحِّح العيار' : 'Karat corrected',
        );
      } catch (e) {
        if (!mounted) return;
        AppFeedback.error(
          context,
          e,
          title: widget.isArabic
              ? 'فشل تصحيح العيار'
              : 'Karat correction failed',
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

        final short = fromSafe.karatsShortFor({
          '24k': w24,
          '22k': w22,
          '21k': w21,
          '18k': w18,
        });

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

    // The transfer posts at once: asked first, with what moves (ADR-050, خ١).
    final isAr = widget.isArabic;
    final moving = _mode == 'gold'
        ? [
            for (final (k, c) in [
              ('24', _weight24kController),
              ('22', _weight22kController),
              ('21', _weight21kController),
              ('18', _weight18kController),
            ])
              if (_parseDouble(c.text) > 0)
                (isAr ? 'عيار $k' : '${k}k', _gramsText(_parseDouble(c.text))),
            for (final (k, c) in [
              ('24', _stones24kController),
              ('22', _stones22kController),
              ('21', _stones21kController),
              ('18', _stones18kController),
            ])
              if (_parseDouble(c.text) > 0)
                (
                  isAr ? 'فصوص عيار $k' : '${k}k stones',
                  _gramsText(_parseDouble(c.text)),
                ),
          ]
        : [
            (
              isAr ? 'المبلغ' : 'Amount',
              ltrIsolate(
                formatAmount(_parseDouble(_amountCashController.text)),
              ),
            ),
          ];
    if (!await _confirmPosting(
      title: isAr ? 'تنفيذ التحويل؟' : 'Make the transfer?',
      effect: isAr
          ? 'يُنشأ سند تحويل معتمد ويُرحَّل قيده الآن: يخرج من خزينة المصدر ويدخل خزينة الوجهة.'
          : 'An approved transfer voucher is created and posted now: out of the source safe, into the destination.',
      confirmLabel: isAr ? 'تنفيذ التحويل' : 'Transfer',
      facts: [
        (isAr ? 'من' : 'From', _safeByIdOrNull(_fromSafeId)?.name ?? '-'),
        (isAr ? 'إلى' : 'To', _safeByIdOrNull(_toSafeId)?.name ?? '-'),
        ...moving,
      ],
    )) {
      return;
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

      _announcePosted(
        result['voucher'] as Map<String, dynamic>?,
        widget.isArabic ? 'أُنشئ سند التحويل' : 'Transfer voucher created',
      );

      if (widget.popOnSuccess && mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(
        context,
        e,
        title: widget.isArabic
            ? 'فشل إنشاء سند التحويل'
            : 'Failed to create transfer',
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    return AppLeaveGuard(
      controllers: [
        _amountCashController,
        for (final k in _karats) ...[_weightOf(k), _stonesOf(k)],
        _corrWeightController,
        _notesController,
      ],
      child: AppDocumentShortcuts(
        onSave: () {
          if (!_isSubmitting) _submitTransfer();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              isAr ? 'التحويل بين الخزائن' : 'Transfer between safes',
            ),
          ),
          body: _isLoadingSafes && !_loadedOnce
              ? const AppLoadingView(summaryBlocks: 2, rows: 4)
              : Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      if (_isLoadingSafes) const LinearProgressIndicator(),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(AppSpace.lg),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 960),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _modeSelector(),
                                  const SizedBox(height: AppSpace.xl),
                                  if (_safes.isEmpty && !_isLoadingSafes)
                                    AppEmptyView(
                                      title: _mode == 'cash'
                                          ? (isAr
                                                ? 'لا توجد خزائن نقد أو بنك'
                                                : 'No cash or bank safes')
                                          : (isAr
                                                ? 'لا توجد خزائن ذهب'
                                                : 'No gold safes'),
                                      hint: isAr
                                          ? 'أضفها من «إدارة الخزائن».'
                                          : 'Add them in «Safes».',
                                      icon: Icons.inventory_2_outlined,
                                    )
                                  else if (_mode == 'karat_correction')
                                    ..._correctionSection()
                                  else ...[
                                    _safesRow(),
                                    const SizedBox(height: AppSpace.xl),
                                    if (_mode == 'gold')
                                      _goldTable()
                                    else
                                      _cashSection(),
                                  ],
                                  const SizedBox(height: AppSpace.lg),
                                  _notesSection(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      _footer(),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // ── the parts of the screen (ADR-050: one page, from → to, a karat table)

  TextTheme get _text => Theme.of(context).textTheme;
  ColorScheme get _cs => Theme.of(context).colorScheme;

  TextEditingController _weightOf(int k) => switch (k) {
    24 => _weight24kController,
    22 => _weight22kController,
    21 => _weight21kController,
    _ => _weight18kController,
  };

  TextEditingController _stonesOf(int k) => switch (k) {
    24 => _stones24kController,
    22 => _stones22kController,
    21 => _stones21kController,
    _ => _stones18kController,
  };

  double _goldOf(SafeBoxModel safe, int k) => switch (k) {
    24 => safe.goldBalance24k,
    22 => safe.goldBalance22k,
    21 => safe.goldBalance21k,
    _ => safe.goldBalance18k,
  };

  double _stonesHeld(int? safeId, int k) =>
      _stonesBalance[safeId]?['$k'] ?? 0.0;

  /// A weight as typed back into a field: no thousands separator.
  String _typed(double grams) => formatGrams(grams).replaceAll(',', '');

  String get _currency => context.read<SettingsProvider>().currencySymbolText;

  void _setMode(String value) {
    if (value == _mode) return;
    setState(() {
      _mode = value;
      _fromSafeId = null;
      _toSafeId = null;
      _amountCashController.clear();
      for (final k in _karats) {
        _weightOf(k).clear();
        _stonesOf(k).clear();
      }
      _corrWeightController.clear();
      _extraKarats.clear();
      _showStones = false;
    });
    _loadSafes();
  }

  /// The three operations, all in sight -- they hid in a dropdown.
  Widget _modeSelector() {
    final isAr = widget.isArabic;
    return LayoutBuilder(
      builder: (context, c) {
        final icons = c.maxWidth >= 560;
        return SegmentedButton<String>(
          key: const Key('transfer-mode'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: 'gold',
              icon: icons ? const Icon(Icons.scale_outlined) : null,
              label: Text(isAr ? 'ذهب بالوزن' : 'Gold by weight'),
            ),
            ButtonSegment(
              value: 'cash',
              icon: icons ? const Icon(Icons.payments_outlined) : null,
              label: Text(isAr ? 'نقد وبنك' : 'Cash & bank'),
            ),
            ButtonSegment(
              value: 'karat_correction',
              icon: icons ? const Icon(Icons.published_with_changes) : null,
              label: Text(isAr ? 'تصحيح عيار' : 'Karat correction'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => _setMode(s.first),
        );
      },
    );
  }

  Widget _safePicker({
    required Key key,
    required String label,
    required int? value,
    required ValueChanged<int?> onChanged,
    String? Function(int?)? validator,
  }) {
    return DropdownButtonFormField<int>(
      key: key,
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final safe in _safes)
          DropdownMenuItem<int>(
            value: safe.id!,
            child: Text(
              _mode == 'cash'
                  ? '${safe.name} (${_typeLabel(safe.safeType)})'
                  : safe.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
      validator: validator,
    );
  }

  /// A safe and what it holds: its karats (those not zero), its stones, or
  /// its cash.
  Widget _safeCard({
    required String title,
    required Widget picker,
    required SafeBoxModel? safe,
  }) {
    final isAr = widget.isArabic;
    final Widget? holds;
    if (safe == null) {
      holds = null;
    } else if (_mode == 'cash') {
      holds = Text(
        isAr
            ? 'الرصيد ${_fmtCash(safe.cashBalance)} $_currency'
            : 'Balance ${_fmtCash(safe.cashBalance)} $_currency',
        style: _text.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    } else {
      final karats = [
        for (final k in _karats)
          if (_goldOf(safe, k).abs() > _epsilon) k,
      ];
      final stones = _stonesBalance[safe.id]?['total'] ?? 0.0;
      holds = karats.isEmpty && stones <= _epsilon
          ? Text(
              isAr ? 'لا رصيد ذهب' : 'No gold held',
              style: _text.bodyMedium?.copyWith(color: _cs.onSurfaceVariant),
            )
          : Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final k in karats) _karatChip(k, _goldOf(safe, k)),
                if (stones > _epsilon)
                  _chip(
                    isAr
                        ? 'فصوص ${_fmtWeight(stones)}'
                        : 'Stones ${_fmtWeight(stones)}',
                    _cs.surfaceContainerHighest,
                    _cs.onSurface,
                  ),
              ],
            );
    }
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: _text.labelLarge?.copyWith(
                color: _cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            picker,
            if (holds != null) ...[const SizedBox(height: AppSpace.md), holds],
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, Color background, Color foreground) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.sm,
      vertical: AppSpace.xs,
    ),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.chip),
    ),
    child: Text(
      text,
      style: _text.labelLarge?.copyWith(
        color: foreground,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );

  /// A karat and its grams, in the karat's tone. A balance below zero is
  /// framed in the error's color with a warning sign -- the error's fill alone
  /// read like 18k's tone.
  Widget _karatChip(int k, double grams) {
    final tone = AppSemanticColors.of(context).karat(k);
    if (grams >= 0) {
      return _chip(
        '${k}k  ${_fmtWeight(grams)}',
        tone.container,
        tone.onContainer,
      );
    }
    return Container(
      key: Key('transfer-negative-$k'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: _cs.error),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: _cs.error),
          const SizedBox(width: AppSpace.xs),
          Text(
            '${k}k  ${_fmtWeight(grams)}',
            style: _text.labelLarge?.copyWith(
              color: _cs.error,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// From → to, side by side with a swap between them; one above the other
  /// on a narrow screen.
  Widget _safesRow() {
    final isAr = widget.isArabic;
    final from = _safeCard(
      title: isAr ? 'من' : 'From',
      safe: _safeByIdOrNull(_fromSafeId),
      picker: _safePicker(
        key: const Key('transfer-from'),
        label: isAr ? 'خزينة المصدر' : 'Source safe',
        value: _fromSafeId,
        onChanged: (v) => setState(() => _fromSafeId = v),
        validator: (v) => v == null ? (isAr ? 'مطلوب' : 'Required') : null,
      ),
    );
    final to = _safeCard(
      title: isAr ? 'إلى' : 'To',
      safe: _safeByIdOrNull(_toSafeId),
      picker: _safePicker(
        key: const Key('transfer-to'),
        label: isAr ? 'خزينة الوجهة' : 'Destination safe',
        value: _toSafeId,
        onChanged: (v) => setState(() => _toSafeId = v),
        validator: (v) {
          if (v == null) return isAr ? 'مطلوب' : 'Required';
          if (v == _fromSafeId) {
            return isAr ? 'غير خزينة المصدر' : 'Not the source safe';
          }
          return null;
        },
      ),
    );
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        final swap = IconButton.filledTonal(
          key: const Key('transfer-swap'),
          tooltip: isAr ? 'تبديل المصدر والوجهة' : 'Swap',
          onPressed: () => setState(() {
            final t = _fromSafeId;
            _fromSafeId = _toSafeId;
            _toSafeId = t;
          }),
          icon: Icon(wide ? Icons.swap_horiz : Icons.swap_vert),
        );
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              from,
              Center(child: swap),
              to,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: from),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                child: Center(child: swap),
              ),
              Expanded(child: to),
            ],
          ),
        );
      },
    );
  }

  /// One row a karat the source holds (or the employee added): what is
  /// there, what moves, what stays. «الكل» moves all of it.
  Widget _goldTable() {
    final isAr = widget.isArabic;
    final source = _safeByIdOrNull(_fromSafeId);
    if (source == null) {
      return _hint(
        isAr
            ? 'اختر خزينة المصدر لترى عياراتها وأرصدتها.'
            : 'Pick the source safe to see its karats.',
      );
    }
    final shown = [
      for (final k in _karats)
        if (_goldOf(source, k) > _epsilon ||
            _extraKarats.contains(k) ||
            _weightOf(k).text.isNotEmpty ||
            _stonesOf(k).text.isNotEmpty)
          k,
    ];
    final hidden = [
      for (final k in _karats)
        if (!shown.contains(k)) k,
    ];
    final stonesOn =
        _showStones ||
        [for (final k in _karats) _stonesOf(k).text].any((t) => t.isNotEmpty);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 600;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isAr ? 'ما يتحرك' : 'What moves',
                  style: _text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                if (shown.isEmpty)
                  _hint(
                    isAr
                        ? 'لا رصيد ذهب في خزينة المصدر.'
                        : 'The source safe holds no gold.',
                  )
                else ...[
                  if (wide) _tableHeader(),
                  for (final k in shown)
                    _goldRow(source, k, wide: wide, stonesOn: stonesOn),
                ],
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.sm,
                  children: [
                    if (hidden.isNotEmpty)
                      PopupMenuButton<int>(
                        key: const Key('transfer-other-karat'),
                        tooltip: isAr ? 'عيار آخر' : 'Another karat',
                        onSelected: (k) => setState(() => _extraKarats.add(k)),
                        itemBuilder: (_) => [
                          for (final k in hidden)
                            PopupMenuItem(value: k, child: Text('${k}k')),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpace.sm),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, size: 18, color: _cs.primary),
                              const SizedBox(width: AppSpace.xs),
                              Text(
                                isAr ? 'عيار آخر' : 'Another karat',
                                style: _text.labelLarge?.copyWith(
                                  color: _cs.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!stonesOn)
                      TextButton.icon(
                        key: const Key('transfer-show-stones'),
                        onPressed: () => setState(() => _showStones = true),
                        icon: const Icon(Icons.diamond_outlined, size: 18),
                        label: Text(
                          isAr ? 'فصوص (اختياري)' : 'Stones (optional)',
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tableHeader() {
    final isAr = widget.isArabic;
    final style = _text.labelMedium?.copyWith(color: _cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(isAr ? 'العيار' : 'Karat', style: style),
          ),
          Expanded(child: Text(isAr ? 'المتاح' : 'Available', style: style)),
          SizedBox(
            width: 200,
            child: Text(isAr ? 'الوزن المحوَّل' : 'Weight moved', style: style),
          ),
          const SizedBox(width: 72),
          Expanded(
            child: Text(isAr ? 'يبقى بعده' : 'Left after', style: style),
          ),
        ],
      ),
    );
  }

  Widget _goldRow(
    SafeBoxModel source,
    int k, {
    required bool wide,
    required bool stonesOn,
  }) {
    final isAr = widget.isArabic;
    final available = _goldOf(source, k);
    final entered = _parseDouble(_weightOf(k).text);
    final left = available - entered;
    final number = _text.bodyLarge?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final weight = SizedBox(
      width: wide ? 200 : null,
      child: _gramsField(
        key: Key('transfer-weight-$k'),
        controller: _weightOf(k),
        error: _goldOverdraftError('${k}k'),
        helper: wide
            ? null
            : (isAr
                  ? 'المتاح ${_fmtWeight(available)}'
                  : 'Available ${_fmtWeight(available)}'),
      ),
    );
    final all = SizedBox(
      width: 72,
      child: TextButton(
        key: Key('transfer-all-$k'),
        onPressed: available > _epsilon
            ? () => setState(() => _weightOf(k).text = _typed(available))
            : null,
        child: Text(isAr ? 'الكل' : 'All'),
      ),
    );
    final stonesAvailable = _stonesHeld(source.id, k);
    final stones = stonesOn
        ? Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Row(
              children: [
                if (wide) const SizedBox(width: 72),
                if (wide) const Spacer(),
                SizedBox(
                  width: wide ? 200 : null,
                  child: _gramsField(
                    key: Key('transfer-stones-$k'),
                    controller: _stonesOf(k),
                    label: isAr ? 'فصوص' : 'Stones',
                    error: _stonesOverdraftError('${k}k'),
                    helper: isAr
                        ? 'فصوص متاحة ${_fmtWeight(stonesAvailable)}'
                        : 'Stones held ${_fmtWeight(stonesAvailable)}',
                  ),
                ),
                if (wide) const SizedBox(width: 72),
                if (wide) const Spacer(),
              ],
            ),
          )
        : const SizedBox.shrink();
    final row = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _karatLabel(k),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.md),
                  child: Text(_fmtWeight(available), style: number),
                ),
              ),
              weight,
              all,
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpace.md),
                  child: Text(
                    entered > 0 ? _fmtWeight(left) : '—',
                    key: Key('transfer-left-$k'),
                    style: number?.copyWith(
                      color: left < -_epsilon ? _cs.error : null,
                    ),
                  ),
                ),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: _karatLabel(k),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(child: weight),
              all,
            ],
          );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: _cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [row, stones],
      ),
    );
  }

  Widget _karatLabel(int k) {
    final tone = AppSemanticColors.of(context).karat(k);
    return _chip('${k}k', tone.container, tone.onContainer);
  }

  Widget _gramsField({
    required Key key,
    required TextEditingController controller,
    String? label,
    String? error,
    String? helper,
    String? suffix,
    String hint = '0.000',
  }) {
    return TextField(
      key: key,
      controller: controller,
      textDirection: TextDirection.ltr,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [NormalizeNumberFormatter()],
      style: _text.bodyLarge?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        hintText: hint,
        suffixText: suffix ?? (widget.isArabic ? 'جم' : 'g'),
        errorText: error,
        helperText: error == null ? helper : null,
      ),
    );
  }

  Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
    child: Text(
      text,
      style: _text.bodyMedium?.copyWith(color: _cs.onSurfaceVariant),
    ),
  );

  Widget _cashSection() {
    final isAr = widget.isArabic;
    final source = _safeByIdOrNull(_fromSafeId);
    final target = _safeByIdOrNull(_toSafeId);
    final amount = _parseDouble(_amountCashController.text);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'المبلغ' : 'Amount',
              style: _text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _gramsField(
                    key: const Key('transfer-amount'),
                    controller: _amountCashController,
                    hint: '0.00',
                    suffix: _currency,
                    error: _cashOverdraftError(),
                    helper: source == null
                        ? null
                        : (isAr
                              ? 'المتاح ${_fmtCash(source.cashBalance)} $_currency'
                              : 'Available ${_fmtCash(source.cashBalance)} $_currency'),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                TextButton(
                  key: const Key('transfer-all-cash'),
                  onPressed: source != null && source.cashBalance > _epsilon
                      ? () => setState(
                          () => _amountCashController.text = formatAmount(
                            source.cashBalance,
                          ).replaceAll(',', ''),
                        )
                      : null,
                  child: Text(isAr ? 'الكل' : 'All'),
                ),
              ],
            ),
            if (source != null && target != null && amount > 0) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                isAr
                    ? 'بعد التحويل: ${source.name} ${_fmtCash(source.cashBalance - amount)} · ${target.name} ${_fmtCash(target.cashBalance + amount)}'
                    : 'After: ${source.name} ${_fmtCash(source.cashBalance - amount)} · ${target.name} ${_fmtCash(target.cashBalance + amount)}',
                style: _text.bodyMedium?.copyWith(color: _cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _correctionSection() {
    final isAr = widget.isArabic;
    final info = AppSemanticColors.of(context).info;
    final safe = _safeByIdOrNull(_fromSafeId);
    Widget karats(Key key, int value, ValueChanged<int> onChanged) =>
        SegmentedButton<int>(
          key: key,
          showSelectedIcon: false,
          segments: [
            for (final k in _karats) ButtonSegment(value: k, label: Text('$k')),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        );
    return [
      Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: info.container,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: info.onContainer),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                isAr
                    ? 'لتصحيح عيار سُجِّل خطأً في الخزينة نفسها: الوزن لا يتغير، العيار وحده يتصحح.'
                    : 'Fixes a karat recorded wrongly, in the same safe: the weight stays, only the karat changes.',
                style: _text.bodyMedium?.copyWith(color: info.onContainer),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      _safeCard(
        title: isAr ? 'الخزينة' : 'Safe',
        safe: safe,
        picker: _safePicker(
          key: const Key('transfer-from'),
          label: isAr ? 'الخزينة' : 'Safe',
          value: _fromSafeId,
          onChanged: (v) => setState(() => _fromSafeId = v),
          validator: (v) => v == null ? (isAr ? 'مطلوب' : 'Required') : null,
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      Card.outlined(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAr ? 'العيار المسجَّل خطأً' : 'Karat recorded',
                style: _text.labelLarge,
              ),
              const SizedBox(height: AppSpace.sm),
              karats(
                const Key('correction-from'),
                _corrFromKarat,
                (k) => setState(() => _corrFromKarat = k),
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                isAr ? 'العيار الصحيح' : 'Correct karat',
                style: _text.labelLarge,
              ),
              const SizedBox(height: AppSpace.sm),
              karats(
                const Key('correction-to'),
                _corrToKarat,
                (k) => setState(() => _corrToKarat = k),
              ),
              if (_corrFromKarat == _corrToKarat)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Text(
                    isAr
                        ? 'اختر عيارًا غير العيار المسجَّل.'
                        : 'Pick a karat other than the recorded one.',
                    style: _text.bodySmall?.copyWith(color: _cs.error),
                  ),
                ),
              const SizedBox(height: AppSpace.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _gramsField(
                      key: const Key('correction-weight'),
                      controller: _corrWeightController,
                      label: isAr ? 'الوزن' : 'Weight',
                      error: _corrOverdraftError(),
                      helper: safe == null
                          ? null
                          : (isAr
                                ? 'المتاح من عيار ${_corrFromKarat}k ${_fmtWeight(_corrAvailableBalance())}'
                                : 'Available ${_corrFromKarat}k ${_fmtWeight(_corrAvailableBalance())}'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  TextButton(
                    key: const Key('correction-all'),
                    onPressed:
                        safe != null && _corrAvailableBalance() > _epsilon
                        ? () => setState(
                            () => _corrWeightController.text = _typed(
                              _corrAvailableBalance(),
                            ),
                          )
                        : null,
                    child: Text(isAr ? 'الكل' : 'All'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _notesSection() {
    final isAr = widget.isArabic;
    if (!_showNotes && _notesController.text.isEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const Key('transfer-add-notes'),
          onPressed: () => setState(() => _showNotes = true),
          icon: const Icon(Icons.notes, size: 18),
          label: Text(isAr ? 'إضافة ملاحظة' : 'Add a note'),
        ),
      );
    }
    return TextField(
      key: const Key('transfer-notes'),
      controller: _notesController,
      autofocus: _showNotes && _notesController.text.isEmpty,
      minLines: 1,
      maxLines: 3,
      decoration: InputDecoration(
        labelText: isAr ? 'ملاحظات (اختياري)' : 'Notes (optional)',
      ),
    );
  }

  /// What stands in the way of the transfer, said beside its button -- the
  /// button waits until there is nothing.
  String? _blocker() {
    final isAr = widget.isArabic;
    if (_fromSafeId == null) {
      return _mode == 'karat_correction'
          ? (isAr ? 'اختر الخزينة' : 'Pick the safe')
          : (isAr ? 'اختر خزينة المصدر' : 'Pick the source safe');
    }
    if (_mode == 'karat_correction') {
      if (_corrFromKarat == _corrToKarat) {
        return isAr ? 'العياران متطابقان' : 'The karats are the same';
      }
      if (_parseDouble(_corrWeightController.text) <= 0) {
        return isAr ? 'أدخل الوزن' : 'Enter the weight';
      }
      return _corrOverdraftError() == null
          ? null
          : (isAr ? 'الوزن أكبر من المتاح' : 'More than available');
    }
    if (_toSafeId == null) {
      return isAr ? 'اختر خزينة الوجهة' : 'Pick the destination safe';
    }
    if (_toSafeId == _fromSafeId) {
      return isAr
          ? 'المصدر والوجهة خزينة واحدة'
          : 'Source and destination are one safe';
    }
    if (_mode == 'cash') {
      if (_parseDouble(_amountCashController.text) <= 0) {
        return isAr ? 'أدخل المبلغ' : 'Enter the amount';
      }
      return _cashOverdraftError() == null
          ? null
          : (isAr ? 'المبلغ أكبر من المتاح' : 'More than available');
    }
    if (!_validateGoldWeights()) {
      return isAr ? 'أدخل وزنًا في عيار واحد على الأقل' : 'Enter a weight';
    }
    final over = [
      for (final k in _karats) ...[
        _goldOverdraftError('${k}k'),
        _stonesOverdraftError('${k}k'),
      ],
    ].any((e) => e != null);
    return over ? (isAr ? 'وزن أكبر من المتاح' : 'More than available') : null;
  }

  /// What will move, in one line.
  String? _summary() {
    final isAr = widget.isArabic;
    switch (_mode) {
      case 'cash':
        final amount = _parseDouble(_amountCashController.text);
        return amount > 0 ? '${_fmtCash(amount)} $_currency' : null;
      case 'karat_correction':
        final w = _parseDouble(_corrWeightController.text);
        return w > 0
            ? '${ltrIsolate('${_corrFromKarat}k → ${_corrToKarat}k')} ${_fmtWeight(w)}'
            : null;
      default:
        final parts = [
          for (final k in _karats)
            if (_parseDouble(_weightOf(k).text) > 0)
              '${k}k ${_fmtWeight(_parseDouble(_weightOf(k).text))}',
        ];
        final stones = _karats.fold<double>(
          0,
          (s, k) => s + _parseDouble(_stonesOf(k).text),
        );
        if (stones > 0) {
          parts.add(
            isAr
                ? 'فصوص ${_fmtWeight(stones)}'
                : 'stones ${_fmtWeight(stones)}',
          );
        }
        return parts.isEmpty ? null : parts.join(' · ');
    }
  }

  /// Fixed under the page: what moves, what is missing, and the button.
  Widget _footer() {
    final isAr = widget.isArabic;
    final blocker = _blocker();
    final summary = _summary();
    final label = _mode == 'karat_correction'
        ? (isAr ? 'تصحيح العيار' : 'Correct karat')
        : (isAr ? 'تحويل' : 'Transfer');
    return Material(
      color: _cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _cs.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      summary == null
                          ? (isAr
                                ? 'لم يُدخَل ما يتحرك بعد'
                                : 'Nothing to move yet')
                          : (isAr ? 'يتحرك: $summary' : 'Moves: $summary'),
                      key: const Key('transfer-summary'),
                      style: _text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (blocker != null)
                      Text(
                        blocker,
                        key: const Key('transfer-blocker'),
                        style: _text.bodySmall?.copyWith(
                          color: _cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Tooltip(
                message: 'Ctrl+S',
                child: FilledButton.icon(
                  key: const Key('transfer-submit'),
                  onPressed: _isSubmitting || blocker != null
                      ? null
                      : _submitTransfer,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
