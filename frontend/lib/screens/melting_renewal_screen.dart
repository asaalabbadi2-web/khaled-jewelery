import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../utils.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_button_styles.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_leave_guard.dart';
import '../widgets/app_bar_tab_bar.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/app_state_views.dart';
import 'safe_boxes_screen.dart' show SafeBoxesScreen, stockPlaceLabels;
import 'voucher_details_screen.dart';

/// Grams as Arabic reads them: the number whole and left-to-right, then its
/// unit (ADR-050, خ٣).
String _grams(double v) => '${ltrIsolate(formatGrams(v))} جم';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('التجديد والتكسير'),
        bottom: AppBarTabBar(
          controller: _tabController,
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

  /// The category it leaves the showroom from (melting) or joins it in
  /// (renewal) -- ت3; the other side is its karat's scrap category.
  int? categoryId;

  /// A renewal's stones sold by their value -- on the showroom's counter, not
  /// in its gold -- rather than counted as gold (ت6ب; the owner, 23 Oct 2026).
  bool stonesByValue = false;
  final TextEditingController goldCtrl = TextEditingController();
  final TextEditingController stonesCtrl = TextEditingController();

  _WeightLine({required this.karat});

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
  Map<int, Map<String, double>> _stonesMap =
      {}; // safe_box_id → {total, 18, 21, 22, 24}
  bool _loading = true;

  /// Why the safes did not load: said with a retry, not over an empty form
  /// that takes typing (ADR-057 ر٥).
  Object? _loadError;

  // The showroom's categories (not scrap), each line's of its karat (ت3).
  List<Map<String, dynamic>> _categories = [];

  // ── اختيارات ─────────────────────────────────────────────────
  int? _fromSafeId;
  int? _toSafeId;

  // ── أسطر الأوزان ─────────────────────────────────────────────
  final List<_WeightLine> _lines = [];

  // ── مصنعية تالفة (تكسير فقط) ─────────────────────────────────
  // Its account is its role's, «المصنعية التالفة بالتكسير» in «الربط
  // المحاسبي» (ت2) -- it was chosen here each time from every expense.
  final _wageCtrl = TextEditingController();

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
    _lines.add(_WeightLine(karat: _mainKarat));
    _load();
  }

  /// A new line's karat: the settings' main karat, never a fixed one, until
  /// the source safe's fullest karat is known.
  int get _mainKarat => context.read<SettingsProvider>().mainKarat;

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
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        widget.api.getSafeBoxBalances(type: 'gold'),
        widget.api.getStonesBalance(),
        SharedPreferences.getInstance(),
        widget.api.getCategories(),
      ]);

      // The shop's own gold: a party's is not melted from here (ADR-051).
      final safes = (results[0] as List<SafeBoxModel>)
          .where((s) => !s.holdsPartyGold)
          .toList();
      final stones = results[1] as Map<int, Map<String, double>>;
      final prefs = results[2] as SharedPreferences;
      final categories = [
        for (final c in results[3] as List)
          if (c is Map && c['is_scrap'] != true && c['is_active'] != false)
            Map<String, dynamic>.from(c),
      ];

      setState(() {
        _safes = safes;
        _stonesMap = stones;
        _categories = categories;

        // استعادة آخر اختيار -- ما دام في الاتجاه المسموح للعملية
        final savedFrom = prefs.getInt(_prefFrom);
        final savedTo = prefs.getInt(_prefTo);
        if (_sourceSafes.any((s) => s.id == savedFrom)) _fromSafeId = savedFrom;
        if (_targetSafes.any((s) => s.id == savedTo)) _toSafeId = savedTo;

        _applyDefaults();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e;
        });
      }
    }
  }

  // One way each, by the safe's stock location -- the server's law (ت1):
  // melting takes the showroom's jewellery to a scrap safe; renewal brings a
  // scrap safe's or a custody's gold to the showroom. The target was the
  // first safe with «كسر» in its name.
  static const _ways = {
    'melting': ({'showroom'}, {'scrap'}),
    'renewal': ({'scrap', 'custody'}, {'showroom'}),
  };

  List<SafeBoxModel> get _sourceSafes => _safes
      .where((s) => _ways[widget.opType]!.$1.contains(s.stockLocation))
      .toList();

  List<SafeBoxModel> get _targetSafes => _safes
      .where((s) => _ways[widget.opType]!.$2.contains(s.stockLocation))
      .toList();

  void _applyDefaults() {
    final sources = _sourceSafes;
    final targets = _targetSafes;
    if (!sources.any((s) => s.id == _fromSafeId)) {
      _fromSafeId = sources.isEmpty ? null : sources.first.id;
    }
    if (!targets.any((s) => s.id == _toSafeId)) {
      _toSafeId = targets.isEmpty
          ? null
          : targets
                .firstWhere((s) => s.isDefault, orElse: () => targets.first)
                .id;
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
  SafeBoxModel? _safeById(int? id) => _safeIn(_safes, id);

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
      // A melting's stones are the showroom's gold, weighed with it (ت5).
      final weight = line.goldWeight + (_isMelting ? line.stonesWeight : 0.0);
      asked[line.karat] = (asked[line.karat] ?? 0) + weight;
    }
    for (final MapEntry(key: karat, value: weight) in asked.entries) {
      final avail = _goldAvailable(_fromSafeId, karat);
      if (weight > avail + 1e-6) {
        _snack(
          'عيار ${karat}k: '
          'الوزن ${_grams(weight)} '
          'يتجاوز الرصيد ${_grams(avail)}',
          error: true,
        );
        return;
      }
    }

    final wageAmt = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;
    final notes = _notesCtrl.text.trim().isEmpty
        ? null
        : _notesCtrl.text.trim();
    // All the lines in one request: one voucher, the wage posted once
    // (ADR-050). One request per line posted the wage per line.
    final lines = [
      for (final line in _lines)
        (
          karat: line.karat,
          goldWeight: line.goldWeight,
          stonesWeight: line.stonesWeight,
          categoryId: line.categoryId,
          stonesByValue: !_isMelting && line.stonesByValue,
        ),
    ];
    final wage = (_isMelting && wageAmt > 0) ? wageAmt : null;

    // The entry the server will post, before it is posted (ت2): the
    // confirmation showed a summary the screen built. A refusal (a wage with
    // its role unmapped, a way not allowed) is said and nothing is sent.
    setState(() => _submitting = true);
    final Map<String, dynamic> preview;
    try {
      preview = await widget.api.previewMeltingRenewal(
        operationType: widget.opType,
        fromSafeBoxId: _fromSafeId!,
        toSafeBoxId: _toSafeId!,
        lines: lines,
        damageWageAmount: wage,
        notes: notes,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        AppFeedback.error(context, e, title: 'لم يُعرض القيد');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    final confirmed = await _showConfirm([
      for (final l in (preview['lines'] as List? ?? const []))
        Map<String, dynamic>.from(l as Map),
    ]);
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    try {
      final res = await widget.api.createMeltingRenewal(
        operationType: widget.opType,
        fromSafeBoxId: _fromSafeId!,
        toSafeBoxId: _toSafeId!,
        lines: lines,
        damageWageAmount: wage,
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

  /// The server's [entry] lines, as it will post them (ت2).
  Future<bool?> _showConfirm(List<Map<String, dynamic>> entry) {
    final fromSafe = _safeById(_fromSafeId);
    final toSafe = _safeById(_toSafeId);
    final opLabel = _isMelting ? 'التكسير' : 'التجديد';
    final currency = context.read<SettingsProvider>().currencySymbolText;
    String amountOf(Map<String, dynamic> l) {
      final amount = (l['amount'] as num?)?.toDouble() ?? 0.0;
      if (l['amount_type'] == 'gold') {
        final karat = (l['karat'] as num?)?.round();
        return '${_grams(amount)}${karat == null ? '' : ' · ${karat}k'}';
      }
      return '${ltrIsolate(formatAmount(amount))} $currency';
    }

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
              Text('القيد', style: Theme.of(context).textTheme.titleSmall),
              for (final l in entry)
                _cRow(
                  '${l['side'] == 'debit' ? 'مدين' : 'دائن'} · '
                  '${ltrIsolate('${l['account_number'] ?? ''}')} ${l['account_name'] ?? ''}',
                  amountOf(l),
                ),
              if (!_isMelting)
                for (final l in _lines.where(
                  (l) => l.stonesByValue && l.stonesWeight > 0,
                ))
                  _cRow(
                    'أحجار ${l.karat}k تُباع بقيمتها — إلى عدّاد المعروض',
                    _grams(l.stonesWeight),
                  ),
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
                ? AppButtonStyles.primary(
                    context,
                    AppSemanticColors.of(context).warning,
                  )
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
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
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
      _lines.add(_WeightLine(karat: _mainKarat));
      _fromSafeId = null;
      _toSafeId = null;
      _wageCtrl.clear();
      _notesCtrl.clear();
      _applyDefaults();
    });
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    error ? AppFeedback.error(context, msg) : AppFeedback.success(context, msg);
  }

  /// No safe on one side of the operation's way: said, with where a safe's
  /// place is set -- an empty list said nothing (ADR-057 ر٥).
  Widget _noSafe(BuildContext context, Set<String> places) {
    String named(Set<String> p) =>
        p.map((k) => '«${stockPlaceLabels[k] ?? k}»').join(' أو ');
    final (from, to) = _ways[widget.opType]!;
    return AppEmptyView(
      icon: Icons.inventory_2_outlined,
      title:
          'لا خزينة ${places.map((k) => stockPlaceLabels[k] ?? k).join(' ولا ')}',
      hint:
          '${_isMelting ? 'التكسير' : 'التجديد'} ينقل الذهب من خزينة ${named(from)} '
          'إلى خزينة ${named(to)}. حدّد «أين هذا الذهب؟» لخزينة من «إدارة الخزائن».',
      actionLabel: 'إدارة الخزائن',
      actionIcon: Icons.account_balance_outlined,
      onAction: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SafeBoxesScreen(api: widget.api)),
        );
        if (mounted) _load();
      },
    );
  }

  /// Something typed that leaving would lose (ADR-050, خ٤). The lines come
  /// and go as the employee works, so the guard asks the form, not a list of
  /// fields taken when it opened.
  bool get _typed =>
      _lines.length > 1 ||
      _lines.any(
        (l) =>
            l.goldCtrl.text.trim().isNotEmpty ||
            l.stonesCtrl.text.trim().isNotEmpty,
      ) ||
      _wageCtrl.text.trim().isNotEmpty ||
      _notesCtrl.text.trim().isNotEmpty;

  // ── بناء الواجهة ──────────────────────────────────────────────
  /// Ctrl+S executes, Ctrl+Enter adds a karat line, Esc asks before typing
  /// is lost -- the keys of every document screen (ADR-049 م٦).
  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoadingView(summaryBlocks: 2, rows: 3);
    if (_loadError != null) {
      return AppErrorView(
        title: 'تعذّر تحميل الخزائن',
        error: _loadError,
        onRetry: _load,
      );
    }
    final missing = _sourceSafes.isEmpty
        ? _ways[widget.opType]!.$1
        : _targetSafes.isEmpty
        ? _ways[widget.opType]!.$2
        : null;
    if (missing != null) return _noSafe(context, missing);
    return AppLeaveGuard(
      controllers: const [],
      isDirty: () => _typed,
      child: AppDocumentShortcuts(
        onSave: () {
          if (!_submitting) _submit();
        },
        onAddLine: _addLine,
        child: _buildForm(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final semantic = AppSemanticColors.of(context);
    final tone = _isMelting ? semantic.warning : semantic.gold;
    final header = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant);
    final wageAmt = double.tryParse(_wageCtrl.text.trim()) ?? 0.0;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // ── بانر توضيحي ──────────────────────────────────────
          _InfoBanner(isMelting: _isMelting, tone: tone),
          const SizedBox(height: 14),

          // ── الخزائن: جنبًا إلى جنب، وعلى الهاتف واحدة فوق الأخرى ──
          LayoutBuilder(
            builder: (context, box) {
              final from = _VaultCard(
                title: 'خزينة المصدر',
                icon: Icons.output,
                tone: tone,
                safes: _sourceSafes,
                value: _fromSafeId,
                excludeId: _toSafeId,
                stonesBalance: _stonesFor(_fromSafeId),
                onChanged: (v) => setState(() {
                  _fromSafeId = v;
                  _applyDefaults();
                }),
                highlightKarats: _lines.map((l) => l.karat).toSet(),
                goldAvailable: (k) => _goldAvailable(_fromSafeId, k),
              );
              final to = _VaultCard(
                title: 'خزينة الوجهة',
                icon: Icons.input,
                tone: tone,
                safes: _targetSafes,
                value: _toSafeId,
                excludeId: _fromSafeId,
                stonesBalance: _stonesFor(_toSafeId),
                onChanged: (v) => setState(() => _toSafeId = v),
                highlightKarats: const {},
                goldAvailable: (k) => _goldAvailable(_toSafeId, k),
                isDestination: true,
              );
              if (box.maxWidth < 600) {
                return Column(children: [from, const SizedBox(height: 12), to]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: from),
                  const SizedBox(width: 12),
                  Expanded(child: to),
                ],
              );
            },
          ),
          const SizedBox(height: 14),

          // ── أسطر الأوزان ────────────────────────────────────
          _SectionCard(
            title: 'أسطر الأوزان',
            icon: Icons.scale,
            tone: tone,
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
                      SizedBox(
                        width: 110,
                        child: Text('العيار', style: header),
                      ),
                      Expanded(child: Text('وزن الذهب (جم)', style: header)),
                      const SizedBox(width: 8),
                      Expanded(child: Text('غير الذهب (جم)', style: header)),
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
                    categories: _categories,
                    categoryLabel: _isMelting
                        ? 'تصنيف ما يُكسَّر'
                        : 'يدخل المعروض بتصنيف',
                    asksStonesKind: !_isMelting,
                    availableKarats: _availableKarats,
                    goldAvailable: (k) => _goldAvailable(_fromSafeId, k),
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
                      style: TextButton.styleFrom(foregroundColor: tone.fg),
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
              tone: semantic.warning,
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
                    const SizedBox(height: 8),
                    Text(
                      'تُقيَّد على حساب «المصنعية التالفة بالتكسير» في الربط المحاسبي',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
                      ? AppButtonStyles.primary(context, semantic.warning)
                      : null,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
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
  final List<Map<String, dynamic>> categories;
  final String categoryLabel;

  /// A renewal asks how a line's stones are sold (ت6ب).
  final bool asksStonesKind;
  final List<int> availableKarats;
  final double Function(int karat) goldAvailable;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  const _WeightLineRow({
    super.key,
    required this.line,
    required this.categories,
    required this.categoryLabel,
    this.asksStonesKind = false,
    required this.availableKarats,
    required this.goldAvailable,
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
    final ofKarat = [
      for (final c in widget.categories)
        if ('${c['karat'] ?? ''}'.trim() == '${widget.line.karat}') c,
    ];

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
                    setState(() {
                      widget.line.karat = v;
                      widget.line.categoryId =
                          null; // a category is of its karat
                    });
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
                  // What is not gold, one field (the owner, 23 Oct 2026):
                  // stones, iron, a clasp.
                  decoration: const InputDecoration(
                    hintText: 'فصوص، حديد…',
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
                        icon: Icon(
                          Icons.remove_circle_outline,
                          size: 20,
                          color: cs.error,
                        ),
                        onPressed: widget.onRemove,
                      )
                    : const SizedBox(),
              ),
            ],
          ),

          // ── كيف تُباع الأحجار (ت6ب) ────────────────────
          if (widget.asksStonesKind && widget.line.stonesWeight > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('تُحسب ذهبًا'),
                    tooltip: 'تدخل المعروض بالوزن القائم، وتُباع ذهبًا',
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('تُباع بقيمتها'),
                    tooltip:
                        'تبقى أحجارًا في عدّاد المعروض، وتُباع ذهبًا + قيمتها',
                  ),
                ],
                selected: {widget.line.stonesByValue},
                showSelectedIcon: false,
                onSelectionChanged: (v) {
                  setState(() => widget.line.stonesByValue = v.first);
                  widget.onChanged();
                },
              ),
            ),

          // ── التصنيف (ت3) ───────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: DropdownButtonFormField<int>(
              key: ValueKey('category-${widget.line.karat}'),
              value: ofKarat.any((c) => c['id'] == widget.line.categoryId)
                  ? widget.line.categoryId
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: widget.categoryLabel,
                prefixIcon: const Icon(Icons.category_outlined, size: 18),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final c in ofKarat)
                  DropdownMenuItem<int>(
                    value: c['id'] as int?,
                    child: Text(
                      '${c['name'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                setState(() => widget.line.categoryId = v);
                widget.onChanged();
              },
              validator: (v) => v == null ? 'اختر التصنيف' : null,
            ),
          ),

          // ── رصيد العيار مدمج أسفل السطر ──────────────────
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: _InlineBalance(
              karat: widget.line.karat,
              goldAvail: avail,
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
  final bool over;
  final ColorScheme cs;

  const _InlineBalance({
    required this.karat,
    required this.goldAvail,
    required this.over,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    final goldColor = over
        ? cs.error
        : (goldAvail > 0 ? AppSemanticColors.of(context).ready.fg : cs.outline);
    final small = Theme.of(context).textTheme.labelSmall;

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
              'ذهب ${karat}k: ${_grams(goldAvail)}',
              style: small?.copyWith(color: goldColor),
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
  final SemanticTone tone;
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
    required this.tone,
    required this.safes,
    required this.value,
    required this.onChanged,
    required this.stonesBalance,
    required this.highlightKarats,
    required this.goldAvailable,
    this.excludeId,
    this.isDestination = false,
  });

  SafeBoxModel? _safe() => _safeIn(safes, value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final safe = _safe();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value != null ? tone.fg : cs.outlineVariant,
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
              color: tone.container,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 15, color: tone.onContainer),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: tone.onContainer,
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
                        ? TextStyle(color: theme.disabledColor)
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
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.outline),
              ),

            // فصوص
            if (stonesBalance > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.diamond_outlined,
                    size: 13,
                    color: AppSemanticColors.of(context).gold.fg,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'فصوص: ${_grams(stonesBalance)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppSemanticColors.of(context).gold.fg,
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
        '${karat}k  ${ltrIsolate(formatGrams(weight))}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: fg,
        ),
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
          'إجمالي الذهب: ${_grams(goldTotal)}',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
        ),
        if (stonesTotal > 0)
          Text(
            'إجمالي غير الذهب: ${_grams(stonesTotal)}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w500,
              color: AppSemanticColors.of(context).gold.fg,
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
  final SemanticTone tone;

  const _InfoBanner({required this.isMelting, required this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isMelting ? Icons.recycling : Icons.auto_fix_high,
            color: tone.onContainer,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isMelting
                  ? 'نقل الذهب الصافي من خزينة المعروض إلى صندوق الكسر. '
                        'غير الذهب (فصوص، حديد…) يخرج من المعروض ويُعدم.'
                  : 'نقل الذهب الصافي من المصدر إلى خزينة المعروض. '
                        'غير الذهب (فصوص، حديد…) يدخل المعروض ذهبًا مقابل إيراد وزني.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tone.onContainer),
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
  final SemanticTone tone;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.tone,
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
              color: tone.container,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: tone.onContainer),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: tone.onContainer,
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

SafeBoxModel? _safeIn(List<SafeBoxModel> safes, int? id) {
  for (final s in safes) {
    if (s.id == id) return s;
  }
  return null;
}
