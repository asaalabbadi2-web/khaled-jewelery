import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import 'add_office_screen.dart';
import 'add_voucher_screen.dart';
import 'gold_reservation_screen.dart';
import 'supplier_ledger_screen.dart';

/// One office's page (ADR-052; the owner 19 Oct 2026: «the journey from an
/// office to its reservation to its execution, easy to reach and use»).
///
/// It was a dialog behind a tap on the office's card. Here: what is ours there
/// and what is owed, the next steps in sight -- a new reservation, paying the
/// office, its statement -- and its reservations by state, each with its one
/// next step: execute or cancel an open one, undo an executed one.
class OfficeDetailScreen extends StatefulWidget {
  const OfficeDetailScreen({
    super.key,
    required this.api,
    required this.office,
    this.isArabic = true,
  });

  final ApiService api;

  /// The office as the offices list sent it: balances, deposit, open count.
  final Map<String, dynamic> office;
  final bool isArabic;

  @override
  State<OfficeDetailScreen> createState() => _OfficeDetailScreenState();
}

enum _Segment { open, executed, cancelled }

class _OfficeDetailScreenState extends State<OfficeDetailScreen> {
  late Map<String, dynamic> _office = widget.office;
  List<Map<String, dynamic>>? _reservations;
  Object? _error;
  _Segment _segment = _Segment.open;
  final _busy = <int>{};

  bool get _isAr => widget.isArabic;
  AppSemanticColors get _tones => AppSemanticColors.of(context);
  TextTheme get _text => Theme.of(context).textTheme;
  ColorScheme get _scheme => Theme.of(context).colorScheme;
  String get _currency => context.read<SettingsProvider>().currencySymbolText;

  int? get _officeId => _asInt(_office['id']);
  int? get _supplierId => _asInt(_office['supplier_id']);

  static int? _asInt(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');
  static double _asDouble(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([
        widget.api.getOffices(),
        widget.api.getOfficeReservations(
          officeId: _officeId,
          page: 1,
          perPage: 200,
          orderBy: 'reservation_date',
          orderDirection: 'desc',
        ),
      ]);
      final offices = (results[0] as List).whereType<Map>();
      final fresh = offices
          .map((o) => Map<String, dynamic>.from(o))
          .where((o) => _asInt(o['id']) == _officeId)
          .firstOrNull;
      final body = results[1] as Map<String, dynamic>;
      final rows = (body['data'] is List ? body['data'] as List : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        if (fresh != null) _office = fresh;
        _reservations = rows;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // ── what a reservation is ──

  _Segment _segmentOf(Map<String, dynamic> r) {
    if ((r['status'] ?? '').toString() == 'cancelled') return _Segment.cancelled;
    if (r['purchase_invoice_id'] != null) return _Segment.executed;
    return _Segment.open;
  }

  List<Map<String, dynamic>> _rowsOf(_Segment s) =>
      (_reservations ?? const []).where((r) => _segmentOf(r) == s).toList();

  String _segmentLabel(_Segment s) => switch (s) {
    _Segment.open => _isAr ? 'مفتوحة' : 'Open',
    _Segment.executed => _isAr ? 'منفَّذة' : 'Executed',
    _Segment.cancelled => _isAr ? 'ملغاة' : 'Cancelled',
  };

  String _grams(double v) => '${ltrIsolate(formatGrams(v))} ${_isAr ? 'جم' : 'g'}';
  String _amount(double v) => '${ltrIsolate(formatAmount(v))} $_currency';

  String _date(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null ? '—' : ltrIsolate(DateFormat('yyyy-MM-dd').format(d.toLocal()));
  }

  // ── the steps ──

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_isAr ? 'رجوع' : 'Back'),
          ),
          FilledButton(
            key: const Key('office-confirm-action'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(int id, Future<void> Function() step, String done) async {
    setState(() => _busy.add(id));
    try {
      await step();
      if (mounted) AppFeedback.success(context, done);
      await _load();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _execute(Map<String, dynamic> r) async {
    final id = _asInt(r['id'])!;
    final grams = _asDouble(r['weight_grams']);
    final rest = _asDouble(r['total_amount']) - _asDouble(r['paid_amount']);
    final ok = await _confirm(
      _isAr ? 'تنفيذ الحجز' : 'Execute',
      _isAr
          ? 'يدخل ${_grams(grams)} عيار ${r['karat'] ?? ''} وديعة «${_office['name'] ?? ''}»، '
                'ويصبح ${_amount(rest)} دينًا للمكتب، وتُعتمد فاتورة الشراء.'
          : 'The gold enters the office deposit, the rest is owed, the purchase is approved.',
      _isAr ? 'تنفيذ' : 'Execute',
    );
    if (!ok) return;
    await _run(
      id,
      () => widget.api.settleOfficeReservation(
        id,
        executionPricePerGram: _asDouble(r['price_per_gram']) > 0
            ? _asDouble(r['price_per_gram'])
            : null,
      ),
      _isAr ? 'نُفّذ الحجز — الذهب في الوديعة' : 'Executed',
    );
  }

  Future<void> _cancel(Map<String, dynamic> r) async {
    final id = _asInt(r['id'])!;
    final ok = await _confirm(
      _isAr ? 'إلغاء الحجز' : 'Cancel reservation',
      _isAr
          ? 'يُلغى الحجز ${r['reservation_code'] ?? ''} ولا يُنفَّذ.'
          : 'The reservation is cancelled.',
      _isAr ? 'إلغاء الحجز' : 'Cancel it',
    );
    if (!ok) return;
    await _run(
      id,
      () => widget.api.cancelOfficeReservation(id),
      _isAr ? 'أُلغي الحجز' : 'Cancelled',
    );
  }

  Future<void> _undo(Map<String, dynamic> r) async {
    final id = _asInt(r['id'])!;
    final ok = await _confirm(
      _isAr ? 'إلغاء التنفيذ' : 'Undo execution',
      _isAr
          ? 'يخرج ${_grams(_asDouble(r['weight_grams']))} من الوديعة، وتُلغى فاتورة الشراء، ويعود الحجز مفتوحًا.'
          : 'The gold leaves the deposit, the purchase is voided, the reservation reopens.',
      _isAr ? 'إلغاء التنفيذ' : 'Undo',
    );
    if (!ok) return;
    await _run(
      id,
      () => widget.api.unsettleOfficeReservation(id),
      _isAr ? 'أُلغي التنفيذ وعاد الحجز مفتوحًا' : 'Execution undone',
    );
  }

  Future<void> _newReservation() async {
    final saved = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GoldReservationScreen(
          api: widget.api,
          isArabic: _isAr,
          initialOfficeId: _officeId,
        ),
      ),
    );
    if (saved != null) {
      setState(() => _segment = _Segment.open);
      await _load();
    }
  }

  Future<void> _pay() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        // The supplier alone: it sets the party too (initialPartyType would clear it).
        builder: (_) => AddVoucherScreen(
          voucherType: 'payment',
          initialSupplierId: _supplierId,
          apiService: widget.api,
        ),
      ),
    );
    await _load();
  }

  Future<void> _statement() async {
    final id = _supplierId;
    if (id == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SupplierLedgerScreen(
          api: widget.api,
          supplierId: id,
          supplierName: (_office['name'] ?? '').toString(),
          isArabic: _isAr,
        ),
      ),
    );
  }

  Future<void> _edit() async {
    final saved = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddOfficeScreen(
          api: widget.api,
          isArabic: _isAr,
          office: _office,
        ),
      ),
    );
    if (saved != null) await _load();
  }

  // ── the page ──

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: _isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text((_office['name'] ?? '').toString()),
          actions: [
            IconButton(
              tooltip: _isAr ? 'تحديث' : 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _error != null
            ? AppErrorView(
                title: _isAr ? 'تعذّر تحميل المكتب' : 'Could not load the office',
                error: _error,
                onRetry: _load,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _header(),
                            const SizedBox(height: AppSpace.lg),
                            _reservationsSection(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _tile(Key key, String label, String value, SemanticTone tone) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _text.labelMedium?.copyWith(color: tone.onContainer)),
          const SizedBox(height: AppSpace.xs),
          Text(
            value,
            style: _text.titleMedium?.copyWith(
              color: tone.onContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final deposit = _office['deposit'] is Map ? _office['deposit'] as Map : null;
    final cash = _asDouble(_office['balance_cash']);
    // The trade account's gold in the main karat -- usually none.
    final main = context.read<SettingsProvider>().mainKarat;
    final trade = [18, 21, 22, 24].fold<double>(
      0,
      (s, k) => s + _asDouble(_office['balance_gold_${k}k']) * k / main,
    );
    final cashText = cash < -0.005
        ? (_isAr ? 'مستحق للمكتب ${_amount(-cash)}' : 'Owed ${_amount(-cash)}')
        : cash > 0.005
        ? (_isAr ? 'لنا عند المكتب ${_amount(cash)}' : 'Ours ${_amount(cash)}')
        : (_isAr ? 'مسوّى' : 'Settled');

    final tiles = <Widget>[
      _tile(
        const Key('office-page-deposit'),
        _isAr ? 'وديعة الذهب' : 'Gold deposit',
        deposit == null
            ? (_isAr ? 'لا وديعة' : 'No deposit')
            : _grams(_asDouble(deposit['main_karat_total'])),
        _tones.gold,
      ),
      _tile(
        const Key('office-page-cash'),
        _isAr ? 'الحساب النقدي' : 'Cash',
        cashText,
        cash < -0.005 ? _tones.warning : _tones.ready,
      ),
      if (trade.abs() >= 0.0005)
        _tile(
          const Key('office-page-trade'),
          _isAr ? 'ذهب الحساب التجاري' : 'Trade gold',
          _grams(trade),
          _tones.info,
        ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (_office['name'] ?? '').toString(),
                        style: _text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        [
                          (_office['office_code'] ?? '').toString(),
                          if ((_office['phone'] ?? '').toString().isNotEmpty)
                            ltrIsolate(_office['phone'].toString()),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: _text.bodySmall?.copyWith(color: _scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(_isAr ? 'تعديل' : 'Edit'),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            LayoutBuilder(
              builder: (context, c) {
                final perRow = c.maxWidth >= 720 ? tiles.length : 1;
                return Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final t in tiles)
                      SizedBox(
                        width: (c.maxWidth - AppSpace.sm * (perRow - 1)) / perRow,
                        child: t,
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpace.md),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                FilledButton.icon(
                  key: const Key('office-page-new-reservation'),
                  onPressed: _office['active'] == false ? null : _newReservation,
                  icon: const Icon(Icons.add),
                  label: Text(_isAr ? 'حجز جديد' : 'New reservation'),
                ),
                OutlinedButton.icon(
                  key: const Key('office-page-pay'),
                  onPressed: _supplierId == null ? null : _pay,
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(_isAr ? 'سداد المكتب' : 'Pay the office'),
                ),
                OutlinedButton.icon(
                  key: const Key('office-page-statement'),
                  onPressed: _supplierId == null ? null : _statement,
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: Text(_isAr ? 'كشف الحساب' : 'Statement'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _reservationsSection() {
    if (_reservations == null) return const AppLoadingView(summaryBlocks: 0, rows: 3);
    final rows = _rowsOf(_segment);
    final grams = rows.fold<double>(0, (s, r) => s + _asDouble(r['weight_grams']));
    final amount = rows.fold<double>(0, (s, r) => s + _asDouble(r['total_amount']));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(_isAr ? 'الحجوزات' : 'Reservations', style: _text.titleMedium),
            const Spacer(),
            SegmentedButton<_Segment>(
              key: const Key('office-page-segments'),
              segments: [
                for (final s in _Segment.values)
                  ButtonSegment(
                    value: s,
                    label: Text('${_segmentLabel(s)} (${ltrIsolate('${_rowsOf(s).length}')})'),
                  ),
              ],
              selected: {_segment},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _segment = v.first),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        if (rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Text(
              _isAr
                  ? '${ltrIsolate('${rows.length}')} حجز · ${_grams(grams)} · ${_amount(amount)}'
                  : '${rows.length} · ${_grams(grams)} · ${_amount(amount)}',
              key: const Key('office-page-summary'),
              style: _text.bodyMedium?.copyWith(color: _scheme.onSurfaceVariant),
            ),
          ),
        if (rows.isEmpty)
          AppEmptyView(
            title: switch (_segment) {
              _Segment.open => _isAr ? 'لا حجوزات مفتوحة' : 'No open reservations',
              _Segment.executed => _isAr ? 'لا حجوزات منفَّذة' : 'None executed',
              _Segment.cancelled => _isAr ? 'لا حجوزات ملغاة' : 'None cancelled',
            },
            icon: Icons.lock_clock,
            actionLabel: _segment == _Segment.open ? (_isAr ? 'حجز جديد' : 'New reservation') : null,
            actionIcon: _segment == _Segment.open ? Icons.add : null,
            onAction: _segment == _Segment.open ? _newReservation : null,
          )
        else
          for (final r in rows) _reservationCard(r),
      ],
    );
  }

  Widget _pill(String text, SemanticTone tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
    decoration: BoxDecoration(
      color: tone.container,
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Text(text, style: _text.labelSmall?.copyWith(color: tone.onContainer)),
  );

  Widget _reservationCard(Map<String, dynamic> r) {
    final id = _asInt(r['id']) ?? 0;
    final seg = _segmentOf(r);
    final busy = _busy.contains(id);
    final total = _asDouble(r['total_amount']);
    final paid = _asDouble(r['paid_amount']);
    final (stateText, stateTone) = switch (seg) {
      _Segment.open => (_isAr ? 'محجوز' : 'Reserved', _tones.warning),
      _Segment.executed => (_isAr ? 'منفَّذ — الذهب في الوديعة' : 'Executed', _tones.ready),
      _Segment.cancelled => (_isAr ? 'ملغى' : 'Cancelled', _tones.blocked),
    };
    return Card(
      key: Key('office-page-reservation-$id'),
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    ltrIsolate((r['reservation_code'] ?? '#$id').toString()),
                    style: _text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                _pill(stateText, stateTone),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              [
                _date(r['reservation_date']),
                '${_isAr ? 'عيار' : 'K'} ${r['karat'] ?? ''}',
                _grams(_asDouble(r['weight_grams'])),
                '${_amount(_asDouble(r['price_per_gram']))} / ${_isAr ? 'جم' : 'g'}',
              ].join(' · '),
              style: _text.bodyMedium,
            ),
            Text(
              _isAr
                  ? 'الإجمالي ${_amount(total)} · المدفوع ${_amount(paid)}'
                        '${seg != _Segment.cancelled && total - paid > 0.005 ? ' · المتبقي ${_amount(total - paid)}' : ''}'
                  : 'Total ${_amount(total)} · paid ${_amount(paid)}',
              style: _text.bodySmall?.copyWith(color: _scheme.onSurfaceVariant),
            ),
            if (seg != _Segment.cancelled) ...[
              const SizedBox(height: AppSpace.sm),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpace.sm,
                children: [
                  if (seg == _Segment.open) ...[
                    TextButton(
                      key: Key('office-page-cancel-$id'),
                      onPressed: busy ? null : () => _cancel(r),
                      child: Text(_isAr ? 'إلغاء الحجز' : 'Cancel'),
                    ),
                    FilledButton.icon(
                      key: Key('office-page-execute-$id'),
                      onPressed: busy ? null : () => _execute(r),
                      icon: const Icon(Icons.check),
                      label: Text(_isAr ? 'تنفيذ' : 'Execute'),
                    ),
                  ] else
                    OutlinedButton.icon(
                      key: Key('office-page-undo-$id'),
                      onPressed: busy ? null : () => _undo(r),
                      icon: const Icon(Icons.undo),
                      label: Text(_isAr ? 'إلغاء التنفيذ' : 'Undo execution'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
