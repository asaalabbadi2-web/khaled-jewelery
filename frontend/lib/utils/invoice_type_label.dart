/// اسم نوع الفاتورة كما يقرؤه الشخص، لا كما يُخزَّن (المالك، 17 أكتوبر 2026:
/// «من شراء من عميل الى شراء كسر، ومن شراء من مورد الى شراء جديد»).
///
/// النوع المخزّن (`invoice_type`) لا يتغيّر: عليه تقوم المفاتيح والتصفية
/// والربط المحاسبي. الخادم يُعيد الاسم (`invoice_type_label`) حيث يعرف الفاتورة
/// -- وتسوية حجز المكتب تُخزَّن «شراء» وهي كسر -- وهذه الدالة تقرؤه، أو تشتقّه
/// من النوع حين لا يُرسل.
library;

const Map<String, String> _labels = {
  'شراء من عميل': 'شراء كسر',
  'شراء': 'شراء جديد',
  'شراء من مورد': 'شراء جديد',
  'مرتجع شراء': 'مرتجع شراء كسر',
  'مرتجع شراء من عميل': 'مرتجع شراء كسر',
  'مرتجع شراء (مورد)': 'مرتجع شراء جديد',
  'مرتجع شراء من مورد': 'مرتجع شراء جديد',
};

const String officeBuyLabel = 'شراء كسر من مكتب';

/// The name of a stored [type]; an office's «شراء» when [officeId] is given.
String invoiceTypeLabelOf(Object? type, {Object? officeId}) {
  final kind = (type ?? '').toString().trim();
  if (kind == 'شراء' && officeId != null) return officeBuyLabel;
  return _labels[kind] ?? kind;
}

/// The name of an invoice the server sent: its own label, or one derived.
String invoiceTypeLabel(Map<dynamic, dynamic> invoice) {
  final given = (invoice['invoice_type_label'] ?? '').toString().trim();
  if (given.isNotEmpty) return given;
  return invoiceTypeLabelOf(invoice['invoice_type'], officeId: invoice['office_id']);
}
