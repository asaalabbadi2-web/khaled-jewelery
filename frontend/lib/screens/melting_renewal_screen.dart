import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../utils.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import 'voucher_details_screen.dart';

// ═══════════════════════════════════════════════════════════════════
//  الشاشة الرئيسية
// ═══════════════════════════════════════════════════════════════════
class MeltingRenewalScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const MeltingRenewalScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<MeltingRenewalScreen> createState() => _MeltingRenewalScreenState();
}

class _MeltingRenewalScreenState extends State<MeltingRenewalScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('التجديد والتكسير'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: cs.primary,
          labelColor: cs.primary,
          tabs: const [
            Tab(icon: Icon(Icons.recycling), text: 'تكسير المخزون'),
            Tab(icon: Icon(Icons.auto_fix_high), text: 'تجديد القطع'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _OperationForm(api: widget.api, opType: 'melting'),
          _OperationForm(api: widget.api, opType: 'renewal'),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  سطر وزن واحد (عيار + ذهب + فصوص)
// ═══════════════════════════════════════════════════════════════════
class _WeightLine {
  int karat;
  final TextEditingController goldCtrl = TextEditingController();
  final TextEditingController stonesCtrl = TextEditingController();

  _WeightLine({this.karat = 21});

  double get goldWeight => double.tryParse(goldCtrl.text.trim()) ?? 0.0;
  double get stonesWeight => double.tryParse(stonesCtrl.text.trim()) ?? 0.0;

  void dispose() {
    goldCtrl.dispose();
    stonesCtrl.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════
//  نموذج العملية
// ═══════════════════════════════════════════════════════════════════
class _OperationForm extends StatefulWidget {
  final ApiService api;
  final String opType;

  const _OperationForm({required this.api, required this.opType});

  @override
  State<_OperationForm> createState() => _OperationFormState();
}

class _OperationFormState extends State<_OperationForm> {
  final _formKey = GlobalKey<FormState>();

  // ── بيانات محملة ─────────────────────────────────────────────
  List<SafeBoxModel> _safes = [];
  Map<int, Map<String, double>> _stonesMap = {}; // safe_box_id → {total, 18, 21, 22, 24}
  List<Map<String, dynamic>> _wageAccounts = [];
  bool _loading = true;

  // ── اختيارات ─────────────────────────────────────────────────
  int? _fromSafeId;
  int? _toSafeId;

  // ── أسطر الأوزان ─────────────────────────────────────────────
  final List<_WeightLine> _lines = [_WeightLine()];

  // ── مصنعية تالفة (تكسير فقط) ─────────────────────────────────
  final _wageCtrl = TextEditingController();
  int? _wageAccountId;

  // ── ملاحظات ──────────────────────────────────────────────────
  final _notesCtrl = TextEditingController();

  bool _submitting = false;

  bool get _isMelting => widget.opType == 'melting';
  String get _prefFrom => 'mr2_from_${widget.opType}';
  String get _prefTo => 'mr2_to_${widget.opType}';

  static const _availableKarats = [24, 22, 21, 18];

  // ── دورة الحياة ──────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _wageCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  // ── تحميل البيانات ───────────────────────────────────────────
  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        widget.api.getSafeBoxBalances(type: 'gold'),
        widget.api.getStonesBalance(),
        widget.api.getAccounts(),
        SharedPreferences.getInstance(),
      ]);

      final safes = results[0] as List<SafeBoxModel>;
      final stones = results[1] as Map<int, Map<String, double>>;
      final accounts = results[2] as List;
      final prefs = results[3] as SharedPreferences;

      final wageAccs = accounts
          .whereType<Map<String, dynamic>>()
          .where((a) => (a['type'] ?? '').toString().toLowerCase() == 'expense')
          .toList();

      setState(() {
        _safes = safes;
        _stonesMap = stones;
        _wageAccounts = wageAccs;

        // استعادة آخر اختيار
        final ids = safes.map((s) => s.id).toSet();
        final savedFrom = prefs.getInt(_prefFrom);
        final savedTo = prefs.getInt(_prefTo);
        if (savedFrom != null && ids.contains(savedFrom)) {
          _fromSafeId = savedFrom;
        }
        if (savedTo != null && ids.contains(savedTo)) _toSafeId = savedTo;

        _applyDefaults();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        AppFeedback.error(context, e, title: 'تعذّر تحميل الخزائن والحسابات');
      }
    }
  }

  void _applyDefaults() {
    if (_safes.isEmpty) return;
    _fromSafeId ??= _safes.first.id;

    if (_toSafeId == null || _toSafeId == _fromSafeId) {
      final target = _isMelting
          ? _safes.firstWhere(
              (s) => s.isDefault || s.name.contains('كسر'),
              orElse: () => _safes.firstWhere(
                (s) => s.id != _fromSafeId,
                orElse: () => _safes.first,
              ),
            )
          : _safes.firstWhere(
              (s) => s.isDefault,
              orElse: () => _safes.firstWhere(
                (s) => s.id != _fromSafeId,
                orElse: () => _safes.first,
              ),
            );
      if (target.id != _fromSafeId) _toSafeId = target.id;
    }

    // اختيار العيار الأعلى رصيداً في الخزنة المصدر للسطر الأول
    if (_lines.isNotEmpty) {
      final s = _safeById(_fromSafeId);
      if (s != null) {
        final best =
            {
                  24: s.goldBalance24k,
                  22: s.goldBalance22k,
                  21: s.goldBalance21k,
                  18: s.goldBalance18k,
                }.entries
                .where((e) => e.value > 0)
                .fold<MapEntry<int, double>?>(
                  null,
                  (p, e) => p == null || e.value > p.value ? e : p,
                );
        if (best != null) _lines[0].karat = best.key;
      }
    }
  }

  // ── مساعدات الرصيد ───────────────────────────────────────────
  SafeBoxModel? _safeById(int? id) => id == null
      ? null
      : _safes.firstWhere((s) => s.id == id, orElse: () => _safes.first);

  double _goldAvailable(int? safeId, int karat) {
    final s = _safeById(safeId);
    if (s == null) return 0.0;
    switch (karat) {
      case 18:
        return s.goldBalance18k;
      case 21:
        return s.goldBalance21k;
      case 22:
        return s.goldBalance22k;
      case 24:
        return s.goldBalance24k;
      default:
        return 0.0;
    }
  }

  double _stonesFor(int? safeId) =>
      safeId == null ? 0.0 : (_stonesMap[safeId]?['total'] ?? 0.0);

  Map<String, double> _stonesInfoFor(int? safeId) => safeId == null
      ? const {'total': 0.0, '18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0}
      : (_stonesMap[safeId] ?? const {'total': 0.0, '18': 0.0, '21': 0.0, '22': 0.0, '24': 0.0});

  // ── إدارة الأسطر ─────────────────────────────────────────────
  void _addLine() {
    setState(() => _lines.add(_WeightLine(karat: _lines.last.karat)));
  }

  void _removeLine(int index) {
    if (_lines.length <= 1) return;
    setState(() {
      _lines[index].dispose();
      _lines.removeAt(index);
    });
  }

  // ── إرسال ────────────────────────────────────────────────────
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_fromSafeId == null || _toSafeId == null) {
      _snack('اختر خزينة المصدر والوجهة', error: true);
      return;
    }
    if (_fromSafeId == _toSafeId) {
      _snack('المصدر والوجهة يجب أن يختلفا', error: true);
      return;
    }

    // التحقق من الأسطر
    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].goldWeight <= 0) {
        _snack('السطر ${i + 1}: أدخل وزن الذهب', error: true);
        return;
      }
    }
    // A karat's lines together against its balance, as the server checks.
    final asked = <int, double>{};
    for (final line in _lines) {
      asked[line.karat] = (asked[line.karat] ?? 0) + line.goldWeight;
    }
    for (final MapEntry(key: karat, value: weight) in asked.entries) {
      final avail = _goldAvailable(_fromSafeId, karat);
      if (weight > avail + 1e-6) {
        _snack(
          'عيار ${karat}k: '
          'الوزن ${weight.toStringAsFixed(3)} جم '
          'يتجاوز الرصيد ${avail.toStringAsFixed(3)} جم',
          error: true,
        );
        return;
      }
    }

    // A wage without its account was dropped by the server unsaid, while the
    // confirmation showed it.
    final wageTyped = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;
    if (_isMelting && wageTyped > 0 && _wageAccountId == null) {
      _snack('اختر حساب مصروف المصنعية', error: true);
      return;
    }

    final confirmed = await _showConfirm();
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    final wageAmt = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;
    final notes = _notesCtrl.text.trim().isEmpty
        ? null
        : _notesCtrl.text.trim();
    try {
      // All the lines in one request: one voucher, the wage posted once
      // (ADR-050). One request per line posted the wage per line.
      final res = await widget.api.createMeltingRenewal(
        operationType: widget.opType,
        fromSafeBoxId: _fromSafeId!,
        toSafeBoxId: _toSafeId!,
        lines: [
          for (final line in _lines)
            (
              karat: line.karat,
              goldWeight: line.goldWeight,
              stonesWeight: line.stonesWeight,
            ),
        ],
        damageWageAmount: (_isMelting && wageAmt > 0) ? wageAmt : null,
        damageWageAccountId: (_isMelting && wageAmt > 0)
            ? _wageAccountId
            : null,
        notes: notes,
      );
      final voucher = res['voucher'] as Map?;
      final number = (voucher?['voucher_number'] ?? '').toString();
      final id = voucher?['id'];
      // The server says when the stones' entries were not posted (their
      // accounts unset); the screen dropped it.
      final warning = (res['warning'] ?? '').toString();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefFrom, _fromSafeId!);
      await prefs.setInt(_prefTo, _toSafeId!);

      if (!mounted) return;
      final navigator = Navigator.of(context);
      final done = _isMelting ? 'سُجِّل التكسير' : 'سُجِّل التجديد';
      final say = warning.isEmpty ? AppFeedback.success : AppFeedback.warning;
      say(
        context,
        [
          number.isEmpty ? done : '$done: ${ltrIsolate(number)}',
          if (warning.isNotEmpty) warning,
        ].join('\n'),
        action: id is int
            ? (
                label: 'عرض السند',
                onPressed: () => navigator.push(
                  MaterialPageRoute(
                    builder: (_) => VoucherDetailsScreen(voucherId: id),
                  ),
                ),
              )
            : null,
      );
      _reset();
      _load();
    } catch (e) {
      if (mounted) {
        AppFeedback.error(
          context,
          e,
          title: _isMelting ? 'لم يُسجَّل التكسير' : 'لم يُسجَّل التجديد',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool?> _showConfirm() {
    final fromSafe = _safeById(_fromSafeId);
    final toSafe = _safeById(_toSafeId);
    final opLabel = _isMelting ? 'التكسير' : 'التجديد';
    final wageAmt = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تأكيد $opLabel'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cRow('من', fromSafe?.name ?? '—'),
              _cRow('إلى', toSafe?.name ?? '—'),
              const Divider(),
              ..._lines.map(
                (l) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _cRow(
                      'عيار ${l.karat}k — ذهب',
                      '${l.goldWeight.toStringAsFixed(3)} جم',
                    ),
                    if (l.stonesWeight > 0)
                      _cRow(
                        'فصوص ${l.karat}k',
                        '${l.stonesWeight.toStringAsFixed(3)} جم',
                      ),
                  ],
                ),
              ),
              if (wageAmt > 0 && _isMelting) ...[
                const Divider(),
                _cRow(
                  'مصنعية تالفة',
                  '${wageAmt.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}',
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: _isMelting
                ? FilledButton.styleFrom(backgroundColor: Colors.orange[800])
                : null,
            child: Text('تأكيد $opLabel'),
          ),
        ],
      ),
    );
  }

  Widget _cRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
      ],
    ),
  );

  void _reset() {
    setState(() {
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      _lines.add(_WeightLine());
      _fromSafeId = null;
      _toSafeId = null;
      _wageAccountId = null;
      _wageCtrl.clear();
      _notesCtrl.clear();
      _applyDefaults();
    });
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    error ? AppFeedback.error(context, msg) : AppFeedback.success(context, msg);
  }

  // ── بناء الواجهة ──────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final cs = Theme.of(context).colorScheme;
    final opColor = _isMelting ? Colors.orange[800]! : cs.primary;
    final wageAmt = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // ── بانر توضيحي ──────────────────────────────────────
          _InfoBanner(isMelting: _isMelting, color: opColor),
          const SizedBox(height: 14),

          // ── الخزائن (صف جنباً إلى جنب على الشاشات الواسعة) ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _VaultCard(
                  title: 'خزينة المصدر',
                  icon: Icons.output,
                  color: opColor,
                  safes: _safes,
                  value: _fromSafeId,
                  excludeId: _toSafeId,
                  stonesBalance: _stonesFor(_fromSafeId),
                  onChanged: (v) => setState(() {
                    _fromSafeId = v;
                    _applyDefaults();
                  }),
                  highlightKarats: _lines.map((l) => l.karat).toSet(),
                  goldAvailable: (k) => _goldAvailable(_fromSafeId, k),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _VaultCard(
                  title: 'خزينة الوجهة',
                  icon: Icons.input,
                  color: opColor,
                  safes: _safes,
                  value: _toSafeId,
                  excludeId: _fromSafeId,
                  stonesBalance: _stonesFor(_toSafeId),
                  onChanged: (v) => setState(() => _toSafeId = v),
                  highlightKarats: const {},
                  goldAvailable: (k) => _goldAvailable(_toSafeId, k),
                  isDestination: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── أسطر الأوزان ────────────────────────────────────
          _SectionCard(
            title: 'أسطر الأوزان',
            icon: Icons.scale,
            color: opColor,
            child: Column(
              children: [
                // رأس الجدول
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 110,
                        child: Text(
                          'العيار',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                      const Expanded(
                        child: Text(
                          'وزن الذهب (جم)',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'فصوص (جم)',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(width: 32),
                    ],
                  ),
                ),
                const Divider(height: 4),

                // أسطر البيانات
                ...List.generate(
                  _lines.length,
                  (i) => _WeightLineRow(
                    key: ValueKey(i),
                    line: _lines[i],
                    availableKarats: _availableKarats,
                    goldAvailable: (k) => _goldAvailable(_fromSafeId, k),
                    stonesInfo: _stonesInfoFor(_fromSafeId),
                    canRemove: _lines.length > 1,
                    onRemove: () => _removeLine(i),
                    onChanged: () => setState(() {}),
                  ),
                ),

                const Divider(height: 12),

                // شريط الإجمالي + زر إضافة
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _addLine,
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                      label: const Text('إضافة سطر عيار'),
                      style: TextButton.styleFrom(foregroundColor: opColor),
                    ),
                    const Spacer(),
                    _TotalBadge(
                      goldTotal: _lines.fold(0.0, (s, l) => s + l.goldWeight),
                      stonesTotal: _lines.fold(
                        0.0,
                        (s, l) => s + l.stonesWeight,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── مصنعية تالفة (تكسير فقط) ────────────────────────
          if (_isMelting) ...[
            const SizedBox(height: 12),
            _SectionCard(
              title: 'مصنعية تالفة (اختياري)',
              icon: Icons.construction_outlined,
              color: Colors.deepOrange,
              child: Column(
                children: [
                  TextFormField(
                    controller: _wageCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [NormalizeNumberFormatter()],
                    decoration: InputDecoration(
                      labelText:
                          'المبلغ (${context.read<SettingsProvider>().currencySymbolText})',
                      prefixIcon: const Icon(Icons.payments_outlined),
                      suffixText: context
                          .read<SettingsProvider>()
                          .currencySymbolText,
                      border: const OutlineInputBorder(),
                      helperText: 'قيمة أجرة الصنعة المهدرة بالتكسير',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (wageAmt > 0) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      value: _wageAccountId,
                      decoration: const InputDecoration(
                        labelText: 'حساب مصروف المصنعية',
                        prefixIcon: Icon(Icons.account_balance_outlined),
                        border: OutlineInputBorder(),
                      ),
                      items: _wageAccounts
                          .map(
                            (a) => DropdownMenuItem<int>(
                              value: a['id'] as int?,
                              child: Text(
                                '${a['account_number'] ?? ''} · ${a['name'] ?? ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _wageAccountId = v),
                    ),
                  ],
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // ── ملاحظات ──────────────────────────────────────────
          TextFormField(
            controller: _notesCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'ملاحظات (اختياري)',
              prefixIcon: Icon(Icons.note_outlined),
              border: OutlineInputBorder(),
            ),
          ),

          const SizedBox(height: 20),

          // ── أزرار ────────────────────────────────────────────
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('إعادة'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  style: _isMelting
                      ? FilledButton.styleFrom(
                          backgroundColor: Colors.orange[800],
                        )
                      : null,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _isMelting ? Icons.recycling : Icons.auto_fix_high,
                        ),
                  label: Text(_isMelting ? 'تنفيذ التكسير' : 'تنفيذ التجديد'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  سطر وزن واحد (عيار + ذهب + فصوص + رصيد مدمج)
// ═══════════════════════════════════════════════════════════════════
class _WeightLineRow extends StatefulWidget {
  final _WeightLine line;
  final List<int> availableKarats;
  final double Function(int karat) goldAvailable;
  final Map<String, double> stonesInfo;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  const _WeightLineRow({
    super.key,
    required this.line,
    required this.availableKarats,
    required this.goldAvailable,
    required this.stonesInfo,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });

  @override
  State<_WeightLineRow> createState() => _WeightLineRowState();
}

class _WeightLineRowState extends State<_WeightLineRow> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final avail = widget.goldAvailable(widget.line.karat);
    final entered = widget.line.goldWeight;
    final over = entered > 0 && entered > avail + 1e-6;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── اختيار العيار ───────────────────────────────
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<int>(
                  value: widget.line.karat,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    isDense: true,
                  ),
                  items: widget.availableKarats
                      .map(
                        (k) => DropdownMenuItem(value: k, child: Text('${k}k')),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => widget.line.karat = v);
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),

              // ── وزن الذهب ──────────────────────────────────
              Expanded(
                child: TextFormField(
                  controller: widget.line.goldCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [NormalizeNumberFormatter()],
                  onChanged: (_) {
                    setState(() {});
                    widget.onChanged();
                  },
                  decoration: InputDecoration(
                    hintText: '0.000',
                    suffixText: 'جم',
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    isDense: true,
                    errorText: over
                        ? 'أكثر من المتاح ${ltrIsolate(formatGrams(avail))}'
                        : null,
                    errorStyle: const TextStyle(fontSize: 10),
                  ),
                  validator: (v) {
                    final d = double.tryParse(v?.trim() ?? '');
                    if (d == null || d <= 0) return 'مطلوب';
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 8),

              // ── وزن الفصوص ─────────────────────────────────
              Expanded(
                child: TextFormField(
                  controller: widget.line.stonesCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [NormalizeNumberFormatter()],
                  onChanged: (_) {
                    setState(() {});
                    widget.onChanged();
                  },
                  decoration: const InputDecoration(
                    hintText: '—',
                    suffixText: 'جم',
                    prefixIcon: Icon(Icons.diamond_outlined, size: 14),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 4),

              // ── حذف السطر ──────────────────────────────────
              SizedBox(
                width: 28,
                child: widget.canRemove
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          size: 20,
                          color: Colors.red,
                        ),
                        onPressed: widget.onRemove,
                      )
                    : const SizedBox(),
              ),
            ],
          ),

          // ── رصيد العيار مدمج أسفل السطر ──────────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: _InlineBalance(
              karat: widget.line.karat,
              goldAvail: avail,
              stonesAvail: widget.stonesInfo['${widget.line.karat}'] ?? 0.0,
              stonesTotal: widget.stonesInfo['total'] ?? 0.0,
              over: over,
              cs: cs,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  رصيد مدمج أسفل كل سطر
// ═══════════════════════════════════════════════════════════════════
class _InlineBalance extends StatelessWidget {
  final int karat;
  final double goldAvail;
  final double stonesAvail;  // فصوص خاصة بهذا العيار
  final double stonesTotal;  // إجمالي الفصوص في الخزينة
  final bool over;
  final ColorScheme cs;

  const _InlineBalance({
    required this.karat,
    required this.goldAvail,
    required this.stonesAvail,
    required this.stonesTotal,
    required this.over,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final goldColor = over
        ? Colors.red[700]!
        : (goldAvail > 0 ? Colors.green[700]! : cs.outline);

    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        // ذهب متاح لهذا العيار
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              over ? Icons.warning_amber_rounded : Icons.check_circle_outline,
              size: 13,
              color: goldColor,
            ),
            const SizedBox(width: 3),
            Text(
              'ذهب ${karat}k: ${goldAvail.toStringAsFixed(3)} جم',
              style: TextStyle(fontSize: 11, color: goldColor),
            ),
          ],
        ),
        // فصوص — عرض مدمج (عيار محدد أو إجمالي)
        if (stonesAvail > 0.0001 || stonesTotal > 0.0001)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.diamond_outlined, size: 11, color: Color(0xFFB56A2F)),
              const SizedBox(width: 3),
              Text(
                stonesAvail > 0.0001
                    ? '♦ ${stonesAvail.toStringAsFixed(3)} جم'
                    : '♦ ${stonesTotal.toStringAsFixed(3)} جم',
                style: TextStyle(
                  fontSize: 10.5,
                  color: stonesAvail > 0.0001
                      ? const Color(0xFFB56A2F)
                      : Colors.grey,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  بطاقة الخزينة مع لوحة الرصيد
// ═══════════════════════════════════════════════════════════════════
class _VaultCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<SafeBoxModel> safes;
  final int? value;
  final int? excludeId;
  final double stonesBalance;
  final ValueChanged<int?> onChanged;
  final Set<int> highlightKarats;
  final double Function(int) goldAvailable;
  final bool isDestination;

  const _VaultCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.safes,
    required this.value,
    required this.onChanged,
    required this.stonesBalance,
    required this.highlightKarats,
    required this.goldAvailable,
    this.excludeId,
    this.isDestination = false,
  });

  SafeBoxModel? _safe() => value == null
      ? null
      : safes.firstWhere((s) => s.id == value, orElse: () => safes.first);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final safe = _safe();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value != null ? color.withOpacity(0.4) : cs.outlineVariant,
          width: value != null ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── رأس البطاقة ──────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),

          // ── Dropdown الخزينة ──────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: DropdownButtonFormField<int>(
              value: value,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 12,
                ),
                isDense: true,
              ),
              items: safes.map((s) {
                final disabled = s.id == excludeId;
                return DropdownMenuItem<int>(
                  value: s.id,
                  enabled: !disabled,
                  child: Text(
                    s.name,
                    style: disabled
                        ? const TextStyle(color: Colors.grey)
                        : null,
                  ),
                );
              }).toList(),
              onChanged: onChanged,
              validator: (v) => v == null ? 'مطلوب' : null,
            ),
          ),

          // ── لوحة الرصيد ──────────────────────────────────
          if (safe != null)
            _BalancePanel(
              safe: safe,
              stonesBalance: stonesBalance,
              highlightKarats: highlightKarats,
              goldAvailable: goldAvailable,
            ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  لوحة الرصيد داخل بطاقة الخزينة
// ═══════════════════════════════════════════════════════════════════
class _BalancePanel extends StatelessWidget {
  final SafeBoxModel safe;
  final double stonesBalance;
  final Set<int> highlightKarats;
  final double Function(int) goldAvailable;

  const _BalancePanel({
    required this.safe,
    required this.stonesBalance,
    required this.highlightKarats,
    required this.goldAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final karats = {
      24: safe.goldBalance24k,
      22: safe.goldBalance22k,
      21: safe.goldBalance21k,
      18: safe.goldBalance18k,
    };
    final hasAnyGold = karats.values.any((v) => v > 0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // أرصدة العيارات
            if (hasAnyGold)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: karats.entries
                    .where((e) => e.value > 0)
                    .map(
                      (e) => _KaratPill(
                        karat: e.key,
                        weight: e.value,
                        highlighted: highlightKarats.contains(e.key),
                        cs: cs,
                      ),
                    )
                    .toList(),
              )
            else
              Text(
                'لا يوجد رصيد',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),

            // فصوص
            if (stonesBalance > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.diamond_outlined,
                    size: 13,
                    color: Colors.purple,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'فصوص: ${stonesBalance.toStringAsFixed(3)} جم',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.purple,
                      fontWeight: FontWeight.w500,
                    ),
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

// ═══════════════════════════════════════════════════════════════════
//  شريحة عيار
// ═══════════════════════════════════════════════════════════════════
class _KaratPill extends StatelessWidget {
  final int karat;
  final double weight;
  final bool highlighted;
  final ColorScheme cs;

  const _KaratPill({
    required this.karat,
    required this.weight,
    required this.highlighted,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final bg = highlighted ? cs.primaryContainer : cs.surfaceContainerHigh;
    final fg = highlighted ? cs.onPrimaryContainer : cs.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: highlighted ? Border.all(color: cs.primary, width: 1.5) : null,
      ),
      child: Text(
        '${karat}k  ${weight.toStringAsFixed(3)}',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  شارة الإجمالي
// ═══════════════════════════════════════════════════════════════════
class _TotalBadge extends StatelessWidget {
  final double goldTotal;
  final double stonesTotal;

  const _TotalBadge({required this.goldTotal, required this.stonesTotal});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'إجمالي الذهب: ${goldTotal.toStringAsFixed(3)} جم',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
        ),
        if (stonesTotal > 0)
          Text(
            'إجمالي الفصوص: ${stonesTotal.toStringAsFixed(3)} جم',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.purple,
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  مكونات مساعدة
// ═══════════════════════════════════════════════════════════════════
class _InfoBanner extends StatelessWidget {
  final bool isMelting;
  final Color color;

  const _InfoBanner({required this.isMelting, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(
            isMelting ? Icons.recycling : Icons.auto_fix_high,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isMelting
                  ? 'نقل الذهب الصافي من خزينة المعروض إلى صندوق الكسر. يمكن إضافة أكثر من سطر عيار.'
                  : 'نقل الذهب الصافي من المصدر إلى خزينة المعروض. الفصوص تُسجَّل كأصل وإيراد تلقائياً.',
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: color.withOpacity(0.07),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }
}
