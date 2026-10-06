import 'dart:async';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../utils/bidi.dart';
import 'public_holidays_dialog.dart';

/// A payment method's settlement schedule, as the settings screen holds it
/// (ADR-037). The field names are the server's.
class SettlementScheduleValue {
  /// 'days' = a daily batch (closes at midnight); 'weekday' = a weekly batch.
  final String batchPeriod;

  /// Weekly batch: its last day (0 = Monday .. 6 = Sunday).
  final int? closeWeekday;

  /// 'days' = N days after the batch closes; 'weekday' = the next given weekday.
  final String depositRule;
  final int depositDays;
  final int? depositWeekday;

  /// Days the bank deposits nothing (optional).
  final Set<int> bankWeekend;
  final bool skipPublicHolidays;

  /// A flexible plan holds the batches until their net reaches [minNet].
  final bool flexible;
  final double minNet;

  const SettlementScheduleValue({
    required this.batchPeriod,
    required this.closeWeekday,
    required this.depositRule,
    required this.depositDays,
    required this.depositWeekday,
    required this.bankWeekend,
    required this.skipPublicHolidays,
    required this.flexible,
    required this.minNet,
  });

  factory SettlementScheduleValue.fromMethod(Map<String, dynamic>? m) {
    int? asInt(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? '');
    String pick(dynamic v, String fallback) {
      final s = v?.toString().trim().toLowerCase() ?? '';
      return (s == 'days' || s == 'weekday') ? s : fallback;
    }

    final weekend = (m?['bank_weekend_days']?.toString() ?? '')
        .split(',')
        .map((e) => int.tryParse(e.trim()))
        .whereType<int>()
        .toSet();
    final minNet =
        double.tryParse(m?['min_settlement_amount']?.toString() ?? '') ?? 0.0;
    return SettlementScheduleValue(
      batchPeriod: pick(m?['settlement_schedule_type'], 'days'),
      closeWeekday: asInt(m?['settlement_weekday']),
      depositRule: pick(m?['deposit_schedule_type'], 'days'),
      depositDays: asInt(m?['deposit_delay_days']) ?? 1,
      depositWeekday: asInt(m?['deposit_weekday']),
      bankWeekend: weekend,
      skipPublicHolidays: m?['skip_public_holidays'] == true,
      flexible: minNet > 0,
      minNet: minNet,
    );
  }

  SettlementScheduleValue copyWith({
    String? batchPeriod,
    int? closeWeekday,
    String? depositRule,
    int? depositDays,
    int? depositWeekday,
    Set<int>? bankWeekend,
    bool? skipPublicHolidays,
    bool? flexible,
    double? minNet,
  }) => SettlementScheduleValue(
    batchPeriod: batchPeriod ?? this.batchPeriod,
    closeWeekday: closeWeekday ?? this.closeWeekday,
    depositRule: depositRule ?? this.depositRule,
    depositDays: depositDays ?? this.depositDays,
    depositWeekday: depositWeekday ?? this.depositWeekday,
    bankWeekend: bankWeekend ?? this.bankWeekend,
    skipPublicHolidays: skipPublicHolidays ?? this.skipPublicHolidays,
    flexible: flexible ?? this.flexible,
    minNet: minNet ?? this.minNet,
  );

  /// The minimum the server stores: 0 for a fixed plan.
  double get minSettlementAmount => flexible ? minNet : 0.0;

  Map<String, dynamic> toPayload() => {
    'settlement_schedule_type': batchPeriod,
    'settlement_weekday': batchPeriod == 'weekday' ? closeWeekday : null,
    'deposit_schedule_type': depositRule,
    'deposit_delay_days': depositRule == 'days' ? depositDays : 0,
    'deposit_weekday': depositRule == 'weekday' ? depositWeekday : null,
    'bank_weekend_days': (bankWeekend.toList()..sort()),
    'skip_public_holidays': skipPublicHolidays,
    'min_settlement_amount': minSettlementAmount,
  };
}

/// Weekdays in the order a Saudi week is read (Sunday first); values are the
/// server's (0 = Monday .. 6 = Sunday).
const List<MapEntry<int, String>> kWeekdaysAr = [
  MapEntry(6, 'الأحد'),
  MapEntry(0, 'الاثنين'),
  MapEntry(1, 'الثلاثاء'),
  MapEntry(2, 'الأربعاء'),
  MapEntry(3, 'الخميس'),
  MapEntry(4, 'الجمعة'),
  MapEntry(5, 'السبت'),
];

/// The settlement and deposit schedule of one payment method: four questions,
/// and the server's preview of what they do to the next sale days. The screen
/// computes no date -- the preview is the server's (ADR-037).
class SettlementScheduleEditor extends StatefulWidget {
  final SettlementScheduleValue initial;
  final ValueChanged<SettlementScheduleValue> onChanged;
  final ApiService api;
  final Color fieldFill;

  const SettlementScheduleEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.api,
    required this.fieldFill,
  });

  @override
  State<SettlementScheduleEditor> createState() =>
      _SettlementScheduleEditorState();
}

class _SettlementScheduleEditorState extends State<SettlementScheduleEditor> {
  late SettlementScheduleValue _v = widget.initial;
  late final TextEditingController _minController = TextEditingController(
    text: _v.minNet > 0 ? _v.minNet.toStringAsFixed(2) : '',
  );
  late final TextEditingController _daysController = TextEditingController(
    text: _v.depositDays.toString(),
  );

  Timer? _debounce;
  bool _previewLoading = false;
  String? _previewError;
  String? _summary;
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _minController.dispose();
    _daysController.dispose();
    super.dispose();
  }

  void _set(SettlementScheduleValue next) {
    setState(() => _v = next);
    widget.onChanged(next);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _refreshPreview);
  }

  Future<void> _refreshPreview() async {
    if (!mounted) return;
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final res = await widget.api.previewPaymentMethodSchedule({
        ..._v.toPayload(),
        'days': 7,
      });
      if (!mounted) return;
      setState(() {
        _summary = res['summary']?.toString();
        _rows = ((res['rows'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _previewLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewError = e.toString().replaceFirst('Exception: ', '');
        _rows = const [];
        _summary = null;
        _previewLoading = false;
      });
    }
  }

  InputDecoration _decor(String label, {String? helper, IconData? icon}) =>
      InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        prefixIcon: icon == null ? null : Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: widget.fieldFill,
      );

  Widget _section(String title, String hint, List<Widget> children) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _weekdayDropdown({
    required String label,
    required int? value,
    required ValueChanged<int?> onChanged,
    Set<int> disabled = const {},
  }) => DropdownButtonFormField<int>(
    initialValue: value,
    decoration: _decor(label, icon: Icons.event),
    items: [
      for (final d in kWeekdaysAr)
        DropdownMenuItem(
          value: d.key,
          enabled: !disabled.contains(d.key),
          child: Text(disabled.contains(d.key) ? '${d.value} (عطلة البنك)' : d.value),
        ),
    ],
    onChanged: onChanged,
    validator: (v) => v == null ? 'مطلوب' : null,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. The plan
        _section('الخطة', 'الثابتة تُحوَّل مهما كان المبلغ، والمرنة تنتظر حتى يبلغ الصافي حدًّا أدنى.', [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('ثابتة'), icon: Icon(Icons.event_repeat)),
              ButtonSegment(value: true, label: Text('مرنة'), icon: Icon(Icons.savings_outlined)),
            ],
            selected: {_v.flexible},
            onSelectionChanged: (s) => _set(_v.copyWith(flexible: s.first)),
          ),
          if (_v.flexible) ...[
            const SizedBox(height: 10),
            TextFormField(
              controller: _minController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: _decor(
                'الحد الأدنى (صافيًا بعد العمولة وضريبتها)',
                helper: 'ما دونه يُحتجز ويُضاف إلى الإيداع التالي، ثم يُحوَّل كله معًا.',
                icon: Icons.account_balance_wallet_outlined,
              ),
              validator: (v) {
                final n = double.tryParse(v ?? '') ?? 0;
                return (_v.flexible && n <= 0) ? 'اكتب مبلغًا أكبر من صفر' : null;
              },
              onChanged: (v) => _set(_v.copyWith(minNet: double.tryParse(v) ?? 0)),
            ),
          ],
        ]),

        // 2. The batch
        _section('الدفعة', 'متى تُقفل المبيعات التي يحملها تحويل واحد.', [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'days', label: Text('يومية'), icon: Icon(Icons.today)),
              ButtonSegment(value: 'weekday', label: Text('أسبوعية'), icon: Icon(Icons.date_range)),
            ],
            selected: {_v.batchPeriod},
            onSelectionChanged: (s) => _set(_v.copyWith(batchPeriod: s.first)),
          ),
          const SizedBox(height: 10),
          if (_v.batchPeriod == 'weekday')
            _weekdayDropdown(
              label: 'آخر يوم في الدفعة (تُقفل نهايته)',
              value: _v.closeWeekday,
              onChanged: (d) => _set(_v.copyWith(closeWeekday: d)),
            )
          else
            Text('تُقفل منتصف كل ليلة.', style: theme.textTheme.bodySmall),
        ]),

        // 3. The deposit
        _section('الإيداع في البنك', 'متى يصل مال الدفعة إلى حساب البنك. هو تاريخ سند التسوية.', [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'days', label: Text('بعد عدد أيام')),
              ButtonSegment(value: 'weekday', label: Text('في يوم محدد')),
            ],
            selected: {_v.depositRule},
            onSelectionChanged: (s) => _set(_v.copyWith(depositRule: s.first)),
          ),
          const SizedBox(height: 10),
          if (_v.depositRule == 'weekday')
            _weekdayDropdown(
              label: 'يوم الإيداع',
              value: _v.depositWeekday,
              disabled: _v.bankWeekend,
              onChanged: (d) => _set(_v.copyWith(depositWeekday: d)),
            )
          else
            TextFormField(
              controller: _daysController,
              keyboardType: TextInputType.number,
              decoration: _decor(
                'عدد الأيام بعد إقفال الدفعة',
                helper: '1 = اليوم التالي (مدى في أغلب البنوك)',
                icon: Icons.schedule_send,
              ),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return (n == null || n < 0 || n > 30) ? 'بين 0 و 30' : null;
              },
              onChanged: (v) => _set(_v.copyWith(depositDays: int.tryParse(v) ?? 0)),
            ),
        ]),

        // 4. Days the bank deposits nothing
        _section('أيام لا يودع فيها البنك (اختياري)',
            'إن وقع الإيداع في أحدها انتقل إلى أول يوم بعده يعمل فيه البنك.', [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final d in kWeekdaysAr)
                FilterChip(
                  label: Text(d.value),
                  selected: _v.bankWeekend.contains(d.key),
                  onSelected: (on) {
                    final next = Set<int>.from(_v.bankWeekend);
                    on ? next.add(d.key) : next.remove(d.key);
                    _set(_v.copyWith(bankWeekend: next));
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('لا إيداع في الإجازات الرسمية'),
            subtitle: const Text('من تقويم الإجازات (العيدان، اليوم الوطني …)'),
            value: _v.skipPublicHolidays,
            onChanged: (on) => _set(_v.copyWith(skipPublicHolidays: on)),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.edit_calendar_outlined),
              label: const Text('تقويم الإجازات الرسمية'),
              onPressed: () async {
                await PublicHolidaysDialog.show(context, api: widget.api);
                _refreshPreview();
              },
            ),
          ),
        ]),

        // The preview -- the server's
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.visibility_outlined, size: 18),
                  const SizedBox(width: 6),
                  Text('معاينة: متى يصل المال إلى البنك',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (_previewLoading)
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              const SizedBox(height: 8),
              if (_previewError != null)
                Text(_previewError!, style: TextStyle(color: theme.colorScheme.error))
              else ...[
                if (_summary != null) Text(_summary!, style: theme.textTheme.bodySmall),
                const SizedBox(height: 6),
                for (final r in _rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text('مبيعات ${r['sale_weekday']} ${ltrIsolate('${r['sale_day']}')}')),
                        const Icon(Icons.arrow_back, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('تُودَع ${r['deposit_weekday']} ${ltrIsolate('${r['deposit_day']}')}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
