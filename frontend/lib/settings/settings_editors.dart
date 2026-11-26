import 'dart:convert';

import '../utils/currency_utils.dart' as cu;
import '../utils/display_date.dart';
import '../utils/wage_treatment.dart';
import 'settings_registry.dart';

/// How a setting moved into the center is edited (settings spec v2, phase 7).
/// The sections in [movedSections] are edited in the center alone: the old
/// settings tabs no longer hold their keys, and no longer send them -- a stale
/// value from the old screen would write over the center's
/// (test/settings_registry_test.dart holds both).
const movedSections = {
  SettingsSection.company,
  SettingsSection.goldPrices,
  SettingsSection.salesInvoices,
  SettingsSection.tax,
  SettingsSection.paymentsSafes,
  SettingsSection.accounting,
  SettingsSection.itemsPieces,
  SettingsSection.usersSecurity,
};


enum EditorKind { text, toggle, percent, choice, currency, karats, number, safe }

class EditorSpec {
  const EditorSpec(this.kind,
      {this.options = const [],
      this.max = 100,
      this.step = 0.5,
      this.digits = false,
      this.hint,
      this.dependsOn,
      this.min = 0,
      this.decimals = 2,
      this.fraction = false,
      this.unit = '',
      this.group,
      this.unset,
      this.safeType,
      this.explain,
      this.source,
      this.lockedBy});

  final EditorKind kind;

  /// A choice's (stored value, label).
  final List<(Object, String)> options;

  /// A percent's largest value (it is stored as a fraction), and its step.
  final double max;
  final double step;
  final bool digits;
  final String? hint;

  /// A toggle this one is set under: off, this one is not edited (as before).
  final String? dependsOn;

  /// A number's bounds (as written), its decimals, its unit; [fraction]: kept
  /// by the server as a hundredth of what is written (98 % is 0.98). A
  /// number's [options] are presets offered beside it.
  final double min;
  final int decimals;
  final bool fraction;
  final String unit;

  /// Settings that are one policy: changed together, in one confirmation and
  /// one save -- a part changed alone would be priced by, and stamped with,
  /// terms no one set (the office terms; routes/system.py stamps a price on
  /// each change).
  final String? group;

  /// A choice that has no default: a value not among its options is not set,
  /// said so -- never its first option (the main karat: main_karat_not_set).
  final String? unset;

  /// A safe's type ('cash', 'gold'): its options are the safes of that type,
  /// read when the section opens ([withOptions]); none chosen is null.
  final String? safeType;

  /// What a value does, said beside it and in its confirmation (the wage
  /// treatment's two ways) -- from the settings as the server sent them too
  /// (since when the coding is open).
  final String Function(Object? value, Map<String, dynamic> server)? explain;

  /// The column the server keeps this setting in and versions it by, when it
  /// is not the key (coding_on is coding_from, its day: routes/system.py
  /// _VERSION_COLUMN). A toggle with a source is on while the source is set.
  final String? source;

  /// What the server says when it no longer takes a change: the setting is then
  /// shown, said locked, and not offered (the main karat, D9).
  final String? lockedBy;

  /// The key the server sends this setting's value and version under.
  String sourceOf(String key) => source ?? key;

  /// This spec with [options] -- a safe's, known once the safes are read.
  EditorSpec withOptions(List<(Object, String)> options) => EditorSpec(kind,
      options: options,
      max: max,
      step: step,
      digits: digits,
      hint: hint,
      dependsOn: dependsOn,
      min: min,
      decimals: decimals,
      fraction: fraction,
      unit: unit,
      group: group,
      unset: unset,
      safeType: safeType,
      explain: explain,
      source: source,
      lockedBy: lockedBy);

  /// The value as the editor holds it, from what the server sent.
  Object? read(Object? raw) => switch (kind) {
        EditorKind.toggle when source != null => raw != null && '$raw'.isNotEmpty,
        EditorKind.toggle => raw == true || raw == 1 || raw == 'true',
        EditorKind.percent => _percent(raw),
        EditorKind.choice => _choice(raw),
        EditorKind.karats => _karats(raw),
        EditorKind.number => _written(raw),
        EditorKind.safe => raw is num && raw != 0 ? raw.toInt() : int.tryParse('${raw ?? ''}'),
        _ => raw?.toString() ?? '',
      };

  /// The value as the server keeps it.
  Object? write(Object? value) => switch (kind) {
        EditorKind.percent => ((value as num?)?.toDouble() ?? 0) / 100,
        EditorKind.text || EditorKind.currency => (value as String? ?? '').trim(),
        EditorKind.number => _stored(value),
        _ => value,
      };

  /// Whether two held values are one (a percent by its hundredth).
  bool same(Object? a, Object? b) => switch (kind) {
        EditorKind.percent => (((a as num?) ?? 0) - ((b as num?) ?? 0)).abs() < 0.005,
        EditorKind.text || EditorKind.currency => '${a ?? ''}'.trim() == '${b ?? ''}'.trim(),
        EditorKind.karats => '${a ?? const []}' == '${b ?? const []}',
        EditorKind.number => _sameNumber(a, b),
        _ => a == b,
      };

  static bool _sameNumber(Object? a, Object? b) {
    final x = _parse(a), y = _parse(b);
    if (x == null || y == null) return '${a ?? ''}'.trim() == '${b ?? ''}'.trim();
    return (x - y).abs() < 1e-9;
  }

  /// What is wrong with a held value, or null -- a number out of its bounds.
  String? invalid(Object? value) {
    if (kind != EditorKind.number) return null;
    final v = _parse(value);
    if (v == null) return 'اكتب رقمًا';
    if (v < min) return max.isInfinite ? 'لا يقل عن ${_say(min)}' : 'بين ${_say(min)} و${_say(max)}';
    if (v > max) return 'بين ${_say(min)} و${_say(max)}';
    if (decimals == 0 && v != v.roundToDouble()) return 'رقم صحيح';
    return null;
  }

  /// The value said as a reader says it (a financial setting's before and after).
  String display(Object? value) => switch (kind) {
        EditorKind.toggle => value == true ? 'مفعّل' : 'معطّل',
        EditorKind.percent => '${cu.formatAmount((value as num?) ?? 0, decimals: 1)}%',
        EditorKind.karats => [for (final k in (value as List? ?? const [])) 'عيار $k'].join('، '),
        EditorKind.number => _parse(value) == null ? '—' : '${_say(_parse(value)!)}${unit.isEmpty ? '' : ' $unit'}',
        EditorKind.choice when value == null && unset != null => unset!,
        EditorKind.currency => options.firstWhere((o) => o.$1 == value, orElse: () => (value ?? '', '${value ?? '—'}')).$2,
        EditorKind.safe when value == null => 'غير محدد',
        EditorKind.safe => options.firstWhere((o) => o.$1 == value, orElse: () => (value as Object, 'خزينة رقم $value (غير موجودة حاليًا)')).$2,
        EditorKind.choice => options.firstWhere((o) => o.$1 == value, orElse: () => (value ?? '', '${value ?? '—'}')).$2,
        _ => '${value ?? ''}'.isEmpty ? '—' : '$value',
      };

  static double? _parse(Object? held) => double.tryParse('${held ?? ''}'.trim());

  // At most its decimals, no trailing zeros: 1.35, 43, 0.75.
  String _say(double v) {
    final text = cu.formatAmount(v, decimals: decimals);
    return text.contains('.') ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : text;
  }

  String _written(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    if (v == null) return '';
    return _plain(fraction ? v * 100 : v);
  }

  // The number as typed back into its field: plain digits, no grouping.
  String _plain(double v) {
    final r = (v * 10000).round() / 10000;
    return r == r.roundToDouble() ? '${r.toInt()}' : '$r';
  }

  Object? _stored(Object? held) {
    final v = _parse(held);
    if (v == null) return null;
    if (fraction) return (v * 100).round() / 10000;
    return decimals == 0 ? v.round() : v;
  }

  // As the old screen read them: a list, its JSON, or «24,22»; only the
  // known karats, sorted; none is 24 (a VAT-exempt list is never empty).
  static List<int> _karats(Object? raw) {
    Iterable<Object?> parts = const [];
    if (raw is List) {
      parts = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        parts = decoded is List ? decoded : raw.split(',');
      } catch (_) {
        parts = raw.split(',');
      }
    }
    final out = <int>{
      for (final p in parts)
        if (int.tryParse('$p'.trim()) case final int k when karatOptions.contains(k)) k,
    }.toList()
      ..sort();
    return out.isEmpty ? [24] : out;
  }

  // As the old screen read them: a fraction up to 1 is a share, above it a percent.
  static double _percent(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}') ?? 0;
    return v <= 1.0 ? v * 100 : v;
  }

  Object? _choice(Object? raw) {
    for (final (value, _) in options) {
      if ('$value'.toUpperCase() == '${raw ?? ''}'.toUpperCase()) return value;
    }
    if (unset != null) return null;
    return options.isEmpty ? raw : options.first.$1;
  }
}

const dateFormats = ['DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];

const _office = 'office_terms';

String _wageExplained(Object? mode, Map<String, dynamic> _) => wageModeExplanation('$mode');

// As the old tab said it: open since its day, or what opening it does.
String _codingExplained(Object? on, Map<String, dynamic> server) => on == true && server['coding_from'] != null
    ? 'مفتوح منذ ${displayDate(server['coding_from'])}: «ترميز من المخزون الموجود» في محطة ترميز القطع، '
        'تصنيفًا تصنيفًا قبل جرد 31 ديسمبر. الاستلام من المورد يبقى كما هو.'
    : 'عند التفعيل يُفتح «ترميز من المخزون الموجود» في محطة ترميز القطع من اليوم، '
        'لتُرمَّز قطع المخزون قبل جرد 31 ديسمبر. الاستلام من المورد يبقى كما هو.';

/// A group's name and what it says, as one setting is named (its parts keep
/// their own labels).
const policyGroups = {
  _office: (
    'شروط سعر مكتب التسكير',
    'سعر السوق في النظام هو سعر مكتب التسكير لا سعر الأونصة العالمي: '
        'كيلو عيار 24 = (الأونصة + الرسوم الرئيسية + الرسوم الخاصة) × 32.148 × 3.75، '
        'وغرام 21 = الكيلو ÷ 1143 − خصم 21، وغرام 18 = الكيلو ÷ 1333 − خصم 18، و22 من 21. '
        'عدّلها حين يغيّرها المكتب.'
  ),
};
const karatOptions = [18, 21, 22, 24];

final Map<String, EditorSpec> editors = {
  // المنشأة
  'company_name': const EditorSpec(EditorKind.text),
  'company_address': const EditorSpec(EditorKind.text),
  'company_phone': const EditorSpec(EditorKind.text, digits: true),
  'company_tax_number': const EditorSpec(EditorKind.text, digits: true, hint: '15 رقمًا، أوله وآخره 3'),
  'company_cr_number': const EditorSpec(EditorKind.text, digits: true),
  'show_company_logo': const EditorSpec(EditorKind.toggle),
  'invoice_prefix': const EditorSpec(EditorKind.text, hint: 'INV'),
  'currency_symbol': EditorSpec(EditorKind.currency, options: [for (final (l, v) in cu.kCurrencyOptions) (v, l)]),
  'decimal_places': const EditorSpec(EditorKind.choice, options: [(2, '2'), (3, '3'), (4, '4')]),
  'date_format': EditorSpec(EditorKind.choice, options: [for (final f in dateFormats) (f, f)]),
  // الذهب والأسعار
  'main_karat': const EditorSpec(EditorKind.choice,
      options: [(18, 'عيار 18'), (21, 'عيار 21'), (22, 'عيار 22'), (24, 'عيار 24')], unset: 'غير مضبوط',
      lockedBy: 'main_karat_locked'),
  'buy_price_ratio': const EditorSpec(EditorKind.number, min: 50, max: 100, fraction: true, unit: '%', hint: 'مثلًا 98'),
  'office_main_fees_usd': const EditorSpec(EditorKind.number, max: 500, decimals: 4, unit: 'دولار للأونصة', group: _office),
  'office_custom_fees_usd': const EditorSpec(EditorKind.number, max: 500, decimals: 4, unit: 'دولار للأونصة', group: _office),
  'office_discount_21': const EditorSpec(EditorKind.number, max: 50, decimals: 4, unit: 'ريال للغرام', group: _office),
  'office_discount_18': const EditorSpec(EditorKind.number, max: 50, decimals: 4, unit: 'ريال للغرام', group: _office),
  'gold_price_auto_update_enabled': const EditorSpec(EditorKind.toggle),
  'gold_price_auto_update_interval_seconds': const EditorSpec(EditorKind.number,
      min: 10, max: 7 * 24 * 3600, decimals: 0, unit: 'ثانية', dependsOn: 'gold_price_auto_update_enabled',
      options: [(15, 'كل 15 ثانية'), (60, 'كل دقيقة'), (300, 'كل 5 دقائق')]),
  // المدفوعات والخزائن -- all five level 3
  'employee_cash_safes_enabled': const EditorSpec(EditorKind.toggle),
  'employee_gold_safes_enabled': const EditorSpec(EditorKind.toggle),
  'main_cash_safe_box_id': const EditorSpec(EditorKind.safe, safeType: 'cash'),
  'sale_gold_safe_box_id': const EditorSpec(EditorKind.safe, safeType: 'gold'),
  'main_scrap_gold_safe_box_id': const EditorSpec(EditorKind.safe, safeType: 'gold'),
  // المحاسبة والاعتماد
  'voucher_auto_post': const EditorSpec(EditorKind.toggle),
  'accountant_approval_limit_cash':
      const EditorSpec(EditorKind.number, max: double.infinity, unit: 'ريال', hint: 'صفر = لا يعتمد المحاسب شيئًا'),
  'accountant_approval_limit_gold_grams': const EditorSpec(EditorKind.number,
      max: double.infinity, decimals: 3, unit: 'غرام بالعيار الرئيسي', hint: 'صفر = لا يعتمد المحاسب شيئًا'),
  'gold_settlement_tolerance_grams':
      const EditorSpec(EditorKind.number, max: 5, decimals: 3, unit: 'غرام بالعيار الرئيسي', hint: 'مثلًا 0.05'),
  // The server's default is expense: a value it does not know is expense, as the old tab read it.
  'manufacturing_wage_mode': EditorSpec(EditorKind.choice, options: [
    for (final mode in [kWageModeExpense, kWageModeInventory]) (mode, wageModeLabel(mode)),
  ], explain: _wageExplained),
  // الأصناف والقطع
  'coding_on': const EditorSpec(EditorKind.toggle, source: 'coding_from', explain: _codingExplained),
  // المستخدمون والأمان
  'idle_timeout_enabled': const EditorSpec(EditorKind.toggle),
  'idle_timeout_minutes': const EditorSpec(EditorKind.number,
      min: 1, max: 10080, decimals: 0, unit: 'دقيقة', hint: 'مثلًا 30', dependsOn: 'idle_timeout_enabled'),
  // البيع والفواتير
  'allow_discount': const EditorSpec(EditorKind.toggle),
  'default_discount_rate': const EditorSpec(EditorKind.percent, max: 50, dependsOn: 'allow_discount'),
  'allow_manual_invoice_items': const EditorSpec(EditorKind.toggle),
  'allow_partial_invoice_payments': const EditorSpec(EditorKind.toggle),
  'require_auth_for_invoice_create': const EditorSpec(EditorKind.toggle),
  // الضريبة -- all four level 3: changed one at a time, through the confirmation
  'sales_vat_enabled': const EditorSpec(EditorKind.toggle),
  'tax_enabled': const EditorSpec(EditorKind.toggle),
  'tax_rate': const EditorSpec(EditorKind.percent, max: 30, step: 0.1, dependsOn: 'tax_enabled'),
  'vat_exempt_karats': const EditorSpec(EditorKind.karats, dependsOn: 'tax_enabled'),
};

/// A group part's own name, its group's said once above it («الرسوم الرئيسية»).
String partLabel(SettingEntry e) => editors[e.key]!.group == null ? e.label : e.label.split(': ').last;

/// The settings of [section] edited in the center, in the registry's order.
List<SettingEntry> editedIn(SettingsSection section) => [
      for (final e in entriesOf(section))
        if (e.kind == SettingKind.setting && movedSections.contains(section) && editors.containsKey(e.key)) e,
    ];
