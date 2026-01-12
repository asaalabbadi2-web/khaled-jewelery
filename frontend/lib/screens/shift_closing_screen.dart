import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

class ShiftClosingScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const ShiftClosingScreen({
    super.key,
    required this.api,
    required this.isArabic,
  });

  @override
  State<ShiftClosingScreen> createState() => _ShiftClosingScreenState();
}

class _ShiftClosingScreenState extends State<ShiftClosingScreen> {
  bool _loading = false;
  bool _submitting = false;

  bool _goldLoading = false;
  Map<String, dynamic>? _goldTotals;
  final Map<String, TextEditingController> _goldActualControllers = {};

  bool _settleCashSafes = false;

  String? _from;
  String? _to;

  List<Map<String, dynamic>> _rows = [];
  final Map<int, TextEditingController> _actualControllers = {};
  final Map<int, bool> _actualEditable = {};
  final Map<int, Map<String, int>> _cashDenominations = {};

  @override
  void initState() {
    super.initState();
    _loadSummary();
    _loadGoldSummary();
  }

  @override
  void dispose() {
    for (final c in _actualControllers.values) {
      c.dispose();
    }
    for (final c in _goldActualControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSummary() async {
    setState(() => _loading = true);
    try {
      final data = await widget.api.getShiftClosingSummary();
      final rows = (data['rows'] as List?)?.cast<dynamic>() ?? [];

      final parsed = <Map<String, dynamic>>[];
      for (final r in rows) {
        if (r is Map) {
          final pmId = (r['payment_method_id'] as num?)?.toInt();
          if (pmId == null) continue;

          final expected = (r['expected_amount'] as num?)?.toDouble() ?? 0.0;
          final isCash = (r['is_cash'] == true) || (r['category'] == 'cash');
          parsed.add({
            'payment_method_id': pmId,
            'payment_method_name': (r['payment_method_name'] ?? '').toString(),
            'expected_amount': expected,
            'is_cash': isCash,
          });

          // Prefill actual amount with expected for convenience.
          final ctrl = _actualControllers.putIfAbsent(
            pmId,
            () => TextEditingController(text: expected.toStringAsFixed(2)),
          );

          // Keep UI reactive (difference + totals).
          ctrl.removeListener(_onAnyActualChanged);
          ctrl.addListener(_onAnyActualChanged);

          // Digital methods: default locked (editable only if user chooses).
          _actualEditable.putIfAbsent(pmId, () => isCash);
        }
      }

      if (!mounted) return;
      setState(() {
        _from = (data['from'] ?? '').toString();
        _to = (data['to'] ?? '').toString();
        _rows = parsed;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? 'تعذر تحميل ملخص الوردية: ${e.toString()}'
                : 'Failed to load shift summary: ${e.toString()}',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadGoldSummary() async {
    setState(() => _goldLoading = true);
    try {
      final data = await widget.api.getShiftClosingGoldSummary(
        from: _from,
        to: _to,
      );
      final totals = (data['totals'] as Map?)?.cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _goldTotals = totals;
      });

      if (totals != null) {
        for (final k in const ['18k', '21k', '22k', '24k']) {
          final expected = (totals[k] as num?)?.toDouble() ?? 0.0;
          final ctrl = _goldActualControllers.putIfAbsent(
            k,
            () => TextEditingController(text: expected.toStringAsFixed(3)),
          );
          ctrl.removeListener(_onAnyActualChanged);
          ctrl.addListener(_onAnyActualChanged);
        }
      }
    } catch (e) {
      // Gold tab is informational; avoid noisy snackbars.
      if (!mounted) return;
      setState(() {
        _goldTotals = null;
      });
    } finally {
      if (mounted) setState(() => _goldLoading = false);
    }
  }

  void _onAnyActualChanged() {
    if (!mounted) return;
    setState(() {});
  }

  double _parseAmount(String input) {
    final v = input.trim();
    if (v.isEmpty) return 0.0;
    return double.tryParse(v) ?? 0.0;
  }

  Future<void> _openCashDenominationsDialog({
    required int paymentMethodId,
    required String paymentMethodName,
  }) async {
    final denominations = <String>[
      '500',
      '200',
      '100',
      '50',
      '20',
      '10',
      '5',
      '1',
    ];

    final existing = _cashDenominations[paymentMethodId] ?? {};
    final controllers = <String, TextEditingController>{
      for (final d in denominations)
        d: TextEditingController(text: (existing[d] ?? 0).toString()),
    };

    double computeTotal() {
      double total = 0.0;
      for (final d in denominations) {
        final denom = double.tryParse(d) ?? 0.0;
        final count = int.tryParse(controllers[d]!.text.trim()) ?? 0;
        if (denom <= 0 || count <= 0) continue;
        total += denom * count;
      }
      return total;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            widget.isArabic
                ? 'تفتيت النقدية: $paymentMethodName'
                : 'Cash Denominations: $paymentMethodName',
          ),
          content: StatefulBuilder(
            builder: (ctx2, setState2) {
              final total = computeTotal();
              return SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final d in denominations)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 80,
                                child: Text(
                                  widget.isArabic ? '$d ر.س' : '$d SAR',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: controllers[d],
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: false,
                                        signed: false,
                                      ),
                                  onChanged: (_) => setState2(() {}),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: widget.isArabic
                                        ? 'العدد'
                                        : 'Count',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          widget.isArabic
                              ? 'الإجمالي: ${total.toStringAsFixed(2)}'
                              : 'Total: ${total.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final c in controllers.values) {
                  c.dispose();
                }
                Navigator.of(ctx).pop();
              },
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final selected = <String, int>{};
                for (final d in denominations) {
                  final count = int.tryParse(controllers[d]!.text.trim()) ?? 0;
                  if (count > 0) selected[d] = count;
                }
                _cashDenominations[paymentMethodId] = selected;
                final total = computeTotal();
                _actualControllers[paymentMethodId]?.text = total
                    .toStringAsFixed(2);

                for (final c in controllers.values) {
                  c.dispose();
                }
                Navigator.of(ctx).pop();
              },
              child: Text(widget.isArabic ? 'تطبيق' : 'Apply'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;

    double totalExpected = 0.0;
    double totalActual = 0.0;
    for (final row in _rows) {
      final pmId = row['payment_method_id'] as int;
      final expected = (row['expected_amount'] as num?)?.toDouble() ?? 0.0;
      totalExpected += expected;
      totalActual += _parseAmount(_actualControllers[pmId]?.text ?? '');
    }
    final totalDiff = totalActual - totalExpected;

    double goldDiffAbsMax = 0.0;
    if (_goldTotals != null) {
      for (final k in const ['18k', '21k', '22k', '24k']) {
        final expected = (_goldTotals![k] as num?)?.toDouble() ?? 0.0;
        final actual = _parseAmount(_goldActualControllers[k]?.text ?? '');
        final diff = actual - expected;
        goldDiffAbsMax = goldDiffAbsMax < diff.abs()
            ? diff.abs()
            : goldDiffAbsMax;
      }
    }

    // Confirm if there is any shortage/excess.
    if (totalDiff.abs() >= 0.01 || goldDiffAbsMax >= 0.001) {
      final isShortage = totalDiff < 0;
      final amount = totalDiff.abs();

      String extraGoldMsg = '';
      if (_goldTotals != null && goldDiffAbsMax >= 0.001) {
        extraGoldMsg = widget.isArabic
            ? '\n\nيوجد فرق في مطابقة الذهب. الرجاء التأكد قبل المتابعة.'
            : '\n\nThere is a difference in gold reconciliation. Please verify before proceeding.';
      }

      String baseMsg;
      if (totalDiff.abs() < 0.01) {
        baseMsg = widget.isArabic
            ? 'لا يوجد فرق نقدي، هل تريد المتابعة؟'
            : 'No cash difference. Do you want to proceed?';
      } else {
        baseMsg = widget.isArabic
            ? (isShortage
                  ? 'يوجد عجز بقيمة ${amount.toStringAsFixed(2)}، هل أنت متأكد من ترحيل العجز؟'
                  : 'يوجد فائض بقيمة ${amount.toStringAsFixed(2)}، هل أنت متأكد من المتابعة؟')
            : (isShortage
                  ? 'There is a shortage of ${amount.toStringAsFixed(2)}. Do you want to proceed?'
                  : 'There is an excess of ${amount.toStringAsFixed(2)}. Do you want to proceed?');
      }

      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (ctx) {
              return AlertDialog(
                title: Text(
                  widget.isArabic ? 'تأكيد الإغلاق' : 'Confirm Closing',
                ),
                content: Text(baseMsg + extraGoldMsg),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(widget.isArabic ? 'نعم، متابعة' : 'Proceed'),
                  ),
                ],
              );
            },
          ) ??
          false;

      if (!confirmed) return;
    }

    final entries = <Map<String, dynamic>>[];
    for (final row in _rows) {
      final pmId = row['payment_method_id'] as int;
      final expected = (row['expected_amount'] as num?)?.toDouble() ?? 0.0;
      final ctrl = _actualControllers[pmId];
      final actual = _parseAmount(ctrl?.text ?? '');
      final isCash = row['is_cash'] == true;

      final payload = <String, dynamic>{
        'payment_method_id': pmId,
        'expected_amount': expected,
        'actual_amount': actual,
      };

      if (isCash) {
        final denoms = _cashDenominations[pmId];
        if (denoms != null && denoms.isNotEmpty) {
          payload['denominations'] = denoms;
        }
      }

      entries.add(payload);
    }

    setState(() => _submitting = true);
    try {
      Map<String, double>? goldActuals;
      if (_goldTotals != null) {
        goldActuals = {
          for (final k in const ['18k', '21k', '22k', '24k'])
            k: _parseAmount(_goldActualControllers[k]?.text ?? ''),
        };
      }

      final resp = await widget.api.submitShiftClosingReport(
        entries: entries,
        from: _from,
        to: _to,
        settleCash: _settleCashSafes,
        goldActuals: goldActuals,
      );

      if (!mounted) return;
      final entityNumber = (resp['entity_number'] ?? '').toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? 'تم حفظ تقرير الإغلاق (${entityNumber.isEmpty ? '—' : entityNumber})'
                : 'Shift closing saved (${entityNumber.isEmpty ? '-' : entityNumber})',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? 'تعذر حفظ تقرير الإغلاق: ${e.toString()}'
                : 'Failed to submit shift closing: ${e.toString()}',
          ),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currencySymbol =
        context.watch<SettingsProvider>().currencySymbol.isNotEmpty
        ? context.watch<SettingsProvider>().currencySymbol
        : 'ر.س';

    double totalExpected = 0.0;
    double totalActual = 0.0;
    for (final row in _rows) {
      final pmId = row['payment_method_id'] as int;
      final expected = (row['expected_amount'] as num?)?.toDouble() ?? 0.0;
      totalExpected += expected;
      totalActual += _parseAmount(_actualControllers[pmId]?.text ?? '');
    }
    final totalDiff = totalActual - totalExpected;
    final diffColor = totalDiff < 0
        ? Theme.of(context).colorScheme.error
        : AppColors.success;

    Widget buildCashTab() {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_rows.isEmpty) {
        return Center(
          child: Text(
            widget.isArabic
                ? 'لا توجد بيانات للوردية الحالية'
                : 'No data for current shift',
            style: const TextStyle(color: Colors.grey),
          ),
        );
      }

      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    DataColumn(
                      label: Text(
                        widget.isArabic ? 'وسيلة الدفع' : 'Payment Method',
                      ),
                    ),
                    DataColumn(
                      numeric: true,
                      label: Text(
                        widget.isArabic ? 'المبلغ المتوقع' : 'Expected',
                      ),
                    ),
                    DataColumn(
                      numeric: true,
                      label: Text(widget.isArabic ? 'المبلغ الفعلي' : 'Actual'),
                    ),
                    DataColumn(
                      numeric: true,
                      label: Text(widget.isArabic ? 'الفرق' : 'Difference'),
                    ),
                  ],
                  rows: _rows.map((row) {
                    final pmId = row['payment_method_id'] as int;
                    final name = (row['payment_method_name'] ?? '').toString();
                    final expected =
                        (row['expected_amount'] as num?)?.toDouble() ?? 0.0;
                    final ctrl = _actualControllers[pmId]!;

                    final actual = _parseAmount(ctrl.text);
                    final diff = actual - expected;
                    final isCash = row['is_cash'] == true;
                    final editable = _actualEditable[pmId] ?? isCash;

                    return DataRow(
                      cells: [
                        DataCell(
                          Text(
                            name.isEmpty
                                ? (widget.isArabic
                                      ? 'وسيلة #$pmId'
                                      : 'Method #$pmId')
                                : name,
                          ),
                        ),
                        DataCell(
                          Text(
                            '${expected.toStringAsFixed(2)} $currencySymbol',
                          ),
                        ),
                        DataCell(
                          SizedBox(
                            width: 240,
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: ctrl,
                                    readOnly: isCash,
                                    enabled: isCash || editable,
                                    onTap: isCash
                                        ? () {
                                            FocusScope.of(context).unfocus();
                                            _openCashDenominationsDialog(
                                              paymentMethodId: pmId,
                                              paymentMethodName: name.isEmpty
                                                  ? '#$pmId'
                                                  : name,
                                            );
                                          }
                                        : null,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      hintText: widget.isArabic
                                          ? (isCash
                                                ? 'اضغط للتفتيت'
                                                : 'أدخل الفعلي')
                                          : (isCash
                                                ? 'Tap to count'
                                                : 'Enter actual'),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                if (!isCash)
                                  IconButton(
                                    tooltip: widget.isArabic
                                        ? (editable ? 'قفل' : 'تعديل')
                                        : (editable ? 'Lock' : 'Edit'),
                                    onPressed: () {
                                      setState(() {
                                        _actualEditable[pmId] =
                                            !(_actualEditable[pmId] ?? false);
                                      });
                                    },
                                    icon: Icon(
                                      editable ? Icons.lock_open : Icons.lock,
                                      size: 18,
                                    ),
                                  ),
                                if (isCash)
                                  IconButton(
                                    tooltip: widget.isArabic
                                        ? 'تفتيت'
                                        : 'Denominations',
                                    onPressed: () {
                                      _openCashDenominationsDialog(
                                        paymentMethodId: pmId,
                                        paymentMethodName: name.isEmpty
                                            ? '#$pmId'
                                            : name,
                                      );
                                    },
                                    icon: const Icon(Icons.calculate, size: 18),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            diff.toStringAsFixed(2),
                            style: TextStyle(
                              color: diff < 0
                                  ? Theme.of(context).colorScheme.error
                                  : AppColors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isArabic ? 'إجمالي المتوقع' : 'Total expected',
                        ),
                        Text(
                          '${totalExpected.toStringAsFixed(2)} $currencySymbol',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isArabic ? 'إجمالي الفعلي' : 'Total actual',
                        ),
                        Text(
                          '${totalActual.toStringAsFixed(2)} $currencySymbol',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isArabic ? 'صافي الفرق' : 'Net difference',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: diffColor,
                          ),
                        ),
                        Text(
                          '${totalDiff.toStringAsFixed(2)} $currencySymbol',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: diffColor,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 18),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _settleCashSafes,
                      onChanged: (v) {
                        setState(() => _settleCashSafes = v);
                      },
                      title: Text(
                        widget.isArabic
                            ? 'تصفير خزائن الكاش بعد الإغلاق'
                            : 'Settle cash safes after closing',
                      ),
                      subtitle: Text(
                        widget.isArabic
                            ? 'يسجّل حركة تسوية في دفتر الخزينة'
                            : 'Writes settlement ledger movements',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        widget.isArabic ? 'تأكيد الإغلاق' : 'Confirm Closing',
                      ),
              ),
            ),
          ),
        ],
      );
    }

    Widget buildGoldTab() {
      if (_goldLoading) {
        return const Center(child: CircularProgressIndicator());
      }

      final totals = _goldTotals;
      if (totals == null) {
        return Center(
          child: Text(
            widget.isArabic
                ? 'تعذر تحميل ملخص الذهب'
                : 'Failed to load gold summary',
            style: const TextStyle(color: Colors.grey),
          ),
        );
      }

      double w18 = (totals['18k'] as num?)?.toDouble() ?? 0.0;
      double w21 = (totals['21k'] as num?)?.toDouble() ?? 0.0;
      double w22 = (totals['22k'] as num?)?.toDouble() ?? 0.0;
      double w24 = (totals['24k'] as num?)?.toDouble() ?? 0.0;

      double toPure24(double w18, double w21, double w22, double w24) {
        return (w18 * (18.0 / 24.0)) +
            (w21 * (21.0 / 24.0)) +
            (w22 * (22.0 / 24.0)) +
            (w24 * 1.0);
      }

      Widget buildRow(String label, String key, double expected) {
        final ctrl = _goldActualControllers.putIfAbsent(
          key,
          () => TextEditingController(text: expected.toStringAsFixed(3)),
        );
        final actual = _parseAmount(ctrl.text);
        final diff = actual - expected;
        final diffColor = diff.abs() < 0.001
            ? Colors.grey
            : (diff < 0
                  ? Theme.of(context).colorScheme.error
                  : AppColors.success);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text(label)),
              Expanded(
                flex: 3,
                child: Text(
                  widget.isArabic
                      ? 'المتوقع: ${expected.toStringAsFixed(3)} جم'
                      : 'Expected: ${expected.toStringAsFixed(3)} g',
                ),
              ),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: ctrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: false,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: widget.isArabic ? 'الفعلي (جم)' : 'Actual (g)',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  diff >= 0
                      ? '+${diff.toStringAsFixed(3)}'
                      : diff.toStringAsFixed(3),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: diffColor,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                buildRow(widget.isArabic ? 'عيار 18' : '18k', '18k', w18),
                const Divider(),
                buildRow(widget.isArabic ? 'عيار 21' : '21k', '21k', w21),
                const Divider(),
                buildRow(widget.isArabic ? 'عيار 22' : '22k', '22k', w22),
                const Divider(),
                buildRow(widget.isArabic ? 'عيار 24' : '24k', '24k', w24),
                const Divider(),
                Builder(
                  builder: (ctx) {
                    final a18 = _parseAmount(
                      _goldActualControllers['18k']?.text ?? '',
                    );
                    final a21 = _parseAmount(
                      _goldActualControllers['21k']?.text ?? '',
                    );
                    final a22 = _parseAmount(
                      _goldActualControllers['22k']?.text ?? '',
                    );
                    final a24 = _parseAmount(
                      _goldActualControllers['24k']?.text ?? '',
                    );

                    final expectedPure = toPure24(w18, w21, w22, w24);
                    final actualPure = toPure24(a18, a21, a22, a24);
                    final diffPure = actualPure - expectedPure;
                    final diffColor = diffPure.abs() < 0.001
                        ? Colors.grey
                        : (diffPure < 0
                              ? Theme.of(context).colorScheme.error
                              : AppColors.success);

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Text(
                              widget.isArabic
                                  ? 'إجمالي الذهب الصافي (24)'
                                  : 'Total Pure Gold (24k)',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              widget.isArabic
                                  ? 'المتوقع: ${expectedPure.toStringAsFixed(3)} جم'
                                  : 'Expected: ${expectedPure.toStringAsFixed(3)} g',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              widget.isArabic
                                  ? 'الفعلي: ${actualPure.toStringAsFixed(3)} جم'
                                  : 'Actual: ${actualPure.toStringAsFixed(3)} g',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: Text(
                              diffPure >= 0
                                  ? '+${diffPure.toStringAsFixed(3)}'
                                  : diffPure.toStringAsFixed(3),
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: diffColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Directionality(
      textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.isArabic ? 'إغلاق اليومية' : 'Shift Closing'),
            bottom: TabBar(
              tabs: [
                Tab(text: widget.isArabic ? 'السيولة المالية' : 'Cash'),
                Tab(text: widget.isArabic ? 'أوزان الذهب' : 'Gold'),
              ],
            ),
            actions: [
              IconButton(
                onPressed: (_loading || _goldLoading)
                    ? null
                    : () {
                        _loadSummary();
                        _loadGoldSummary();
                      },
                icon: const Icon(Icons.refresh),
                tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
              ),
            ],
          ),
          body: TabBarView(children: [buildCashTab(), buildGoldTab()]),
        ),
      ),
    );
  }
}
