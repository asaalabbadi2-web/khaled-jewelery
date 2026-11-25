import '../utils/currency_utils.dart' as cu;
import 'settings_registry.dart';

/// How a setting moved into the center is edited (settings spec v2, phase 7).
/// The sections in [movedSections] are edited in the center alone: the old
/// settings tabs no longer hold their keys, and no longer send them -- a stale
/// value from the old screen would write over the center's
/// (test/settings_registry_test.dart holds both).
const movedSections = {SettingsSection.company, SettingsSection.salesInvoices};

enum EditorKind { text, toggle, percent, choice, currency }

class EditorSpec {
  const EditorSpec(this.kind,
      {this.options = const [], this.max = 100, this.digits = false, this.hint, this.dependsOn});

  final EditorKind kind;

  /// A choice's (stored value, label).
  final List<(Object, String)> options;

  /// A percent's largest value (it is stored as a fraction).
  final double max;
  final bool digits;
  final String? hint;

  /// A toggle this one is set under: off, this one is not edited (as before).
  final String? dependsOn;

  /// The value as the editor holds it, from what the server sent.
  Object? read(Object? raw) => switch (kind) {
        EditorKind.toggle => raw == true || raw == 1 || raw == 'true',
        EditorKind.percent => _percent(raw),
        EditorKind.choice => _choice(raw),
        _ => raw?.toString() ?? '',
      };

  /// The value as the server keeps it.
  Object? write(Object? value) => switch (kind) {
        EditorKind.percent => ((value as num?)?.toDouble() ?? 0) / 100,
        EditorKind.text || EditorKind.currency => (value as String? ?? '').trim(),
        _ => value,
      };

  /// Whether two held values are one (a percent by its hundredth).
  bool same(Object? a, Object? b) => switch (kind) {
        EditorKind.percent => (((a as num?) ?? 0) - ((b as num?) ?? 0)).abs() < 0.005,
        EditorKind.text || EditorKind.currency => '${a ?? ''}'.trim() == '${b ?? ''}'.trim(),
        _ => a == b,
      };

  // As the old screen read them: a fraction up to 1 is a share, above it a percent.
  static double _percent(Object? raw) {
    final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}') ?? 0;
    return v <= 1.0 ? v * 100 : v;
  }

  Object? _choice(Object? raw) {
    for (final (value, _) in options) {
      if ('$value'.toUpperCase() == '${raw ?? ''}'.toUpperCase()) return value;
    }
    return options.isEmpty ? raw : options.first.$1;
  }
}

const dateFormats = ['DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];

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
  // البيع والفواتير
  'allow_discount': const EditorSpec(EditorKind.toggle),
  'default_discount_rate': const EditorSpec(EditorKind.percent, max: 50, dependsOn: 'allow_discount'),
  'allow_manual_invoice_items': const EditorSpec(EditorKind.toggle),
  'allow_partial_invoice_payments': const EditorSpec(EditorKind.toggle),
  'require_auth_for_invoice_create': const EditorSpec(EditorKind.toggle),
};

/// The settings of [section] edited in the center, in the registry's order.
List<SettingEntry> editedIn(SettingsSection section) => [
      for (final e in entriesOf(section))
        if (e.kind == SettingKind.setting && movedSections.contains(section) && editors.containsKey(e.key)) e,
    ];
