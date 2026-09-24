import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/supplier_settlement_model.dart';
import '../providers/auth_provider.dart';

/// حدود تسوية فروقات حسابات الموردين — عرضًا وتعديلًا.
///
/// هذه الأرقام **سياسة** (بيانات) لا **قانون** (كود): تتغيّر دون نشر. لكن لم يكن
/// لها سطح تُغيَّر من خلاله، فالطريق الوحيد إليها كان SQL يدويًا — وهذا هو السبب
/// الحقيقي لبقاء «تنازل مورد موثّق» محجوزًا خلف حدّ تقريب ٥ ريالات: لم يستطع أحد
/// رفعه.
///
/// الشاشة **لا تحسب ولا تقترح رقمًا**. تعرض ما يُرجعه الخادم، وترسل ما يكتبه
/// المستخدم. القيم الأولية هي الحدود السارية نفسها، حتى لا يبدّل الحفظ شيئًا لم
/// يقصده أحد.
///
/// والحفظ **يُغلق** الصفّ الساري ويُدرج صفًّا جديدًا — لا يعدّله. تسوية مرحّلة
/// جمّدت رقم السياسة التي حُكم عليها بها.
class SupplierSettlementPolicyScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SupplierSettlementPolicyScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SupplierSettlementPolicyScreen> createState() =>
      _SupplierSettlementPolicyScreenState();
}

/// حقول حدّ واحد — عامًّا كان أو لسبب. مجموعة نصوص، لا أرقام مشتقّة.
class _LimitFields {
  final TextEditingController toleranceCash = TextEditingController();
  final TextEditingController toleranceWeight = TextEditingController();
  final TextEditingController reviewThreshold = TextEditingController();
  final TextEditingController periodCapCash = TextEditingController();
  final TextEditingController periodCapWeight = TextEditingController();

  /// هل لهذا السبب صفّ خاص، أم يرث الحدّ العام؟ يبدأ كما وصل من الخادم.
  bool isExplicit = false;
  bool requiresManager = false;

  /// السبب OTHER يستلزم مديرًا دائمًا بقوة الكود — السياسة لا تُخفّض ذلك.
  bool alwaysRequiresManager = false;

  void dispose() {
    toleranceCash.dispose();
    toleranceWeight.dispose();
    reviewThreshold.dispose();
    periodCapCash.dispose();
    periodCapWeight.dispose();
  }
}

class _SupplierSettlementPolicyScreenState
    extends State<SupplierSettlementPolicyScreen> {
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;

  Map<String, dynamic>? _policy;
  final _LimitFields _globals = _LimitFields();
  final Map<String, _LimitFields> _perReason = {
    for (final code in kSettlementReasonCodes) code: _LimitFields(),
  };
  final TextEditingController _notes = TextEditingController();

  bool get _canEdit => context
      .read<AuthProvider>()
      .hasPermission('supplier_settlement_adjustments.approve');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _globals.dispose();
    for (final fields in _perReason.values) {
      fields.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  // ── تحميل ────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final body = await widget.api.getSupplierSettlementPolicy();
      final policy = body['policy'];
      if (policy is! Map<String, dynamic>) {
        setState(() {
          _policy = null;
          _isLoading = false;
          _errorMessage = body['message']?.toString();
        });
        return;
      }

      _globals.toleranceCash.text = _text(policy['tolerance_cash']);
      _globals.toleranceWeight.text = _text(policy['tolerance_weight']);
      _globals.reviewThreshold.text = _text(policy['review_threshold_cash']);
      _globals.periodCapCash.text = _text(policy['period_cap_cash']);
      _globals.periodCapWeight.text = _text(policy['period_cap_weight']);

      final rows = policy['reason_limits'];
      if (rows is List) {
        for (final row in rows) {
          if (row is! Map) continue;
          final fields = _perReason[row['reason_code']?.toString()];
          if (fields == null) continue;
          // القيم النافذة كما قرّرها الخادم — سواء من صفّ خاص أو بالوراثة.
          // لا خانة فارغة يُترك تفسيرها للقارئ.
          fields.toleranceCash.text = _text(row['tolerance_cash']);
          fields.toleranceWeight.text =
              _text(row['tolerance_weight_main_karat']);
          fields.reviewThreshold.text = _text(row['review_threshold_cash']);
          fields.periodCapCash.text = _text(row['period_cap_cash']);
          fields.periodCapWeight.text =
              _text(row['period_cap_weight_main_karat']);
          fields.isExplicit = row['is_explicit'] == true;
          fields.requiresManager = row['requires_manager_approval'] == true;
          fields.alwaysRequiresManager = row['always_requires_manager'] == true;
        }
      }

      setState(() {
        _policy = policy;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = '$e';
      });
    }
  }

  static String _text(dynamic value) {
    if (value == null) return '';
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null) return '$value';
    // يُطبع كما هو دون تقريب: ٠٫٠٥ حدّ حقيقي وليس صفرًا.
    final asString = number.toString();
    return asString.endsWith('.0')
        ? asString.substring(0, asString.length - 2)
        : asString;
  }

  // ── حفظ ──────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final ar = widget.isArabic;
    final globals = <String, double>{};
    for (final entry in {
      'tolerance_cash': _globals.toleranceCash,
      'tolerance_weight': _globals.toleranceWeight,
      'review_threshold_cash': _globals.reviewThreshold,
      'period_cap_cash': _globals.periodCapCash,
      'period_cap_weight': _globals.periodCapWeight,
    }.entries) {
      final parsed = double.tryParse(entry.value.text.trim());
      if (parsed == null) {
        _showError(ar
            ? 'الحدود العامة يجب أن تكون أرقامًا'
            : 'Global limits must be numbers');
        return;
      }
      globals[entry.key] = parsed;
    }

    final reasonLimits = <Map<String, dynamic>>[];
    for (final code in kSettlementReasonCodes) {
      final fields = _perReason[code]!;
      if (!fields.isExplicit) continue; // يرث الحدّ العام — لا صفّ له
      final tolerance = double.tryParse(fields.toleranceCash.text.trim());
      final weight = double.tryParse(fields.toleranceWeight.text.trim());
      if (tolerance == null || weight == null) {
        _showError(ar
            ? 'حدود ${settlementReasonLabel(code)} يجب أن تكون أرقامًا'
            : 'Limits for $code must be numbers');
        return;
      }
      reasonLimits.add({
        'reason_code': code,
        'tolerance_cash': tolerance,
        'tolerance_weight_main_karat': weight,
        // الحقول الثلاثة اختيارية: الفراغ يعني «استخدم الحدّ العام»، ولذلك
        // يُرسَل null ولا تُنسخ قيمة العام فيه — نسخها تجمّدها.
        'review_threshold_cash':
            double.tryParse(fields.reviewThreshold.text.trim()),
        'period_cap_cash': double.tryParse(fields.periodCapCash.text.trim()),
        'period_cap_weight_main_karat':
            double.tryParse(fields.periodCapWeight.text.trim()),
        'requires_manager_approval': fields.requiresManager,
      });
    }

    final confirmed = await _confirmNewPolicyRow(ar, reasonLimits.length);
    if (confirmed != true) return;

    setState(() => _isSaving = true);
    try {
      await widget.api.createSupplierSettlementPolicy(
        toleranceCash: globals['tolerance_cash']!,
        toleranceWeight: globals['tolerance_weight']!,
        periodCapCash: globals['period_cap_cash']!,
        periodCapWeight: globals['period_cap_weight']!,
        reviewThresholdCash: globals['review_threshold_cash']!,
        reasonLimits: reasonLimits,
        notes: _notes.text,
      );
      if (!mounted) return;
      _notes.clear();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ar
            ? 'سُجّلت حدود جديدة، وأُغلقت السابقة'
            : 'New limits recorded; the previous row was closed'),
        backgroundColor: Colors.green,
      ));
      setState(() => _isSaving = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      // رسالة الخادم هي الشرح: حدّ لا يُمكن بلوغه، أو رقم سالب، أو سبب مجهول.
      _showError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      _showError('$e');
    }
  }

  Future<bool?> _confirmNewPolicyRow(bool ar, int explicitCount) {
    return showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: ar ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: AlertDialog(
          title: Text(ar ? 'تثبيت حدود جديدة' : 'Record new limits'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ar
                    ? 'سيُغلق صفّ الحدود الساري ويُدرج صفّ جديد. التسويات المرحّلة '
                        'تبقى محكومة بالحدود التي حُكم عليها بها — لا يتغيّر شيء '
                        'في ماضيها.'
                    : 'The current row is closed and a new one inserted. Posted '
                        'settlements stay judged by the limits in force at the '
                        'time.',
              ),
              const SizedBox(height: 12),
              Text(
                ar
                    ? 'أسباب لها حدود خاصة: $explicitCount — والباقي يرث الحدّ العام.'
                    : 'Reasons with their own limits: $explicitCount',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: ar ? 'سبب التغيير (اختياري)' : 'Reason (optional)',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(ar ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(ar ? 'تثبيت' : 'Record'),
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: Theme.of(context).colorScheme.error,
      duration: const Duration(seconds: 6),
    ));
  }

  // ── بناء ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ar = widget.isArabic;
    return Directionality(
      textDirection: ar ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(ar ? 'حدود تسوية الموردين' : 'Supplier settlement limits'),
          actions: [
            IconButton(
              tooltip: ar ? 'تحديث' : 'Refresh',
              onPressed: _isLoading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _buildBody(ar),
        floatingActionButton: (_policy == null || !_canEdit)
            ? null
            : FloatingActionButton.extended(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(Icons.save),
                label: Text(ar ? 'تثبيت حدود جديدة' : 'Record new limits'),
              ),
      ),
    );
  }

  Widget _buildBody(bool ar) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_policy == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.policy_outlined,
                  size: 40, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(
                _errorMessage ??
                    (ar
                        ? 'لا توجد سياسة تسوية سارية'
                        : 'No settlement policy in force'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _load,
                child: Text(ar ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildExplanation(ar),
        const SizedBox(height: 12),
        _buildGlobalCard(ar),
        const SizedBox(height: 4),
        for (final code in kSettlementReasonCodes) _buildReasonCard(code, ar),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildExplanation(bool ar) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.info_outline, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                ar ? 'ثلاث بوابات، لا واحدة' : 'Three gates, not one',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: scheme.primary),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              ar
                  ? 'كل تسوية تمرّ بثلاثة حدود: حدّ العملية الواحدة، وحدّ المراجعة '
                      '(ما فوقه ليس فرق تسوية أصلًا)، والسقف الشهري المتراكم لكل '
                      'مورد. رفع واحد منها فقط لا يكفي — ولذلك لكل سبب ثلاثتها.'
                  : 'Every settlement passes three limits: the per-operation '
                      'tolerance, the review threshold, and the monthly cap. '
                      'Raising one alone is not enough.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              ar
                  ? 'والوزن يُقاس دائمًا بمكافئ العيار الرئيسي — العيارات لا تُقارن '
                      'إلا بعد التوحيد.'
                  : 'Weight is always measured in main-karat equivalent.',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalCard(bool ar) {
    final from = _policy?['effective_from']?.toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.public, size: 18),
              const SizedBox(width: 6),
              Text(
                ar ? 'الحدود العامة' : 'Global limits',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (from != null)
                Text(
                  ar ? 'سارية من $from' : 'In force from $from',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
            ]),
            const SizedBox(height: 4),
            Text(
              ar
                  ? 'تحكم كل سبب لا حدود خاصة له.'
                  : 'Govern every reason without its own limits.',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            _numberRow([
              _number(_globals.toleranceCash,
                  ar ? 'حدّ العملية — نقد' : 'Operation — cash', ar),
              _number(_globals.toleranceWeight,
                  ar ? 'حدّ العملية — وزن' : 'Operation — weight', ar),
            ]),
            const SizedBox(height: 8),
            _numberRow([
              _number(_globals.periodCapCash,
                  ar ? 'السقف الشهري — نقد' : 'Monthly cap — cash', ar),
              _number(_globals.periodCapWeight,
                  ar ? 'السقف الشهري — وزن' : 'Monthly cap — weight', ar),
            ]),
            const SizedBox(height: 8),
            _number(_globals.reviewThreshold,
                ar ? 'حدّ المراجعة — نقد' : 'Review threshold — cash', ar),
          ],
        ),
      ),
    );
  }

  Widget _buildReasonCard(String code, bool ar) {
    final fields = _perReason[code]!;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  settlementReasonLabel(code, isArabic: ar),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                fields.isExplicit
                    ? (ar ? 'حدود خاصة' : 'Own limits')
                    : (ar ? 'يرث العام' : 'Inherits global'),
                style: TextStyle(
                  fontSize: 11,
                  color: fields.isExplicit ? scheme.primary : Colors.grey,
                ),
              ),
              Switch(
                value: fields.isExplicit,
                onChanged: _canEdit
                    ? (value) => setState(() => fields.isExplicit = value)
                    : null,
              ),
            ]),
            if (!fields.isExplicit)
              Text(
                ar
                    ? 'الحدود النافذة الآن هي الحدود العامة أعلاه.'
                    : 'The global limits above govern this reason.',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            if (fields.isExplicit) ...[
              const SizedBox(height: 10),
              _numberRow([
                _number(fields.toleranceCash,
                    ar ? 'حدّ العملية — نقد' : 'Operation — cash', ar),
                _number(fields.toleranceWeight,
                    ar ? 'حدّ العملية — وزن' : 'Operation — weight', ar),
              ]),
              const SizedBox(height: 8),
              _numberRow([
                _number(fields.periodCapCash,
                    ar ? 'السقف الشهري — نقد' : 'Monthly cap — cash', ar,
                    hint: ar ? 'اتركه فارغًا للعام' : 'Empty = global'),
                _number(fields.periodCapWeight,
                    ar ? 'السقف الشهري — وزن' : 'Monthly cap — weight', ar,
                    hint: ar ? 'اتركه فارغًا للعام' : 'Empty = global'),
              ]),
              const SizedBox(height: 8),
              _number(fields.reviewThreshold,
                  ar ? 'حدّ المراجعة — نقد' : 'Review threshold — cash', ar,
                  hint: ar ? 'اتركه فارغًا للعام' : 'Empty = global'),
              const SizedBox(height: 4),
              Text(
                ar
                    ? 'السقف الشهري الخاص يُحسب على تسويات هذا السبب وحده، فلا '
                        'يستهلك مخصّص الأسباب الأخرى.'
                    : 'An own monthly cap counts only this reason\'s settlements.',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  ar ? 'يستلزم اعتماد مدير' : 'Requires manager approval',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: fields.alwaysRequiresManager
                    ? Text(
                        ar
                            ? 'إلزامي بقوة الكود لهذا السبب — لا يمكن إلغاؤه من هنا'
                            : 'Enforced in code for this reason',
                        style: const TextStyle(fontSize: 11),
                      )
                    : null,
                value: fields.alwaysRequiresManager || fields.requiresManager,
                onChanged: (!_canEdit || fields.alwaysRequiresManager)
                    ? null
                    : (value) => setState(() => fields.requiresManager = value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _numberRow(List<Widget> children) => Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: children[i]),
          ],
        ],
      );

  Widget _number(
    TextEditingController controller,
    String label,
    bool ar, {
    String? hint,
  }) {
    return TextField(
      controller: controller,
      enabled: _canEdit,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      // الأرقام تُقرأ يسارًا-يمينًا داخل واجهة عربية.
      textDirection: ui.TextDirection.ltr,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }
}
