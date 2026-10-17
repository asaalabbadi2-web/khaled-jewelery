import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_service.dart';
import '../utils.dart';
import '../utils/arabic_search.dart';
import '../web_file_io.dart' as web_io;

/// Managing the chart -- add, edit, delete, export, import (CHART-UI-1).
///
/// Moved from «شجرة الحسابات» (ChartOfAccountsScreen) into the one accounts
/// screen. The server decides: it suggests the next number, validates it,
/// refuses a delete that would break something, and offers a parallel weight
/// account's removal. Colours come from the theme.

/// The five account types, in Arabic. The server spells them one way (CHART-UI-1).
const accountTypeLabels = {
  'Asset': 'أصول',
  'Liability': 'خصوم',
  'Equity': 'حقوق ملكية',
  'Revenue': 'إيرادات',
  'Expense': 'مصروفات',
};

/// An account's type label -- whatever the case it arrives in.
String accountTypeLabel(String? type) {
  final t = (type ?? '').trim().toLowerCase();
  for (final e in accountTypeLabels.entries) {
    if (e.key.toLowerCase() == t) return e.value;
  }
  return type ?? '';
}

String _message(Object e) => e.toString().replaceFirst('Exception: ', '');

void _say(BuildContext context, String text, {bool error = false}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        text,
        style: error ? TextStyle(color: scheme.onError) : null,
      ),
      backgroundColor: error ? scheme.error : null,
    ),
  );
}

/// An account found by number or name as people write them (أ/ا، ١٢٣) --
/// the one search for picking an account: a parent here, a safe's account in
/// «إدارة الخزائن» (SAFES-UI-1).
class AccountSearchField extends StatelessWidget {
  const AccountSearchField({
    super.key,
    required this.accounts,
    required this.selected,
    required this.onChanged,
    required this.label,
    this.hint,
    this.clearTooltip,
    this.fieldKey,
    this.validator,
  });

  final List<Map<String, dynamic>> accounts;
  final Map<String, dynamic>? selected;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final String label;
  final String? hint;
  final String? clearTooltip;
  final Key? fieldKey;
  final FormFieldValidator<String>? validator;

  static String labelOf(Map<String, dynamic> a) =>
      '${a['account_number']} — ${a['name']}';

  @override
  Widget build(BuildContext context) {
    return Autocomplete<Map<String, dynamic>>(
      initialValue: TextEditingValue(
        text: selected == null ? '' : labelOf(selected!),
      ),
      displayStringForOption: labelOf,
      optionsBuilder: (value) {
        final q = normalizeForSearch(value.text);
        if (q.isEmpty) return const Iterable.empty();
        return accounts
            .where((a) => normalizeForSearch(labelOf(a)).contains(q))
            .take(20);
      },
      onSelected: onChanged,
      fieldViewBuilder: (context, controller, focus, submit) => TextFormField(
        key: fieldKey,
        controller: controller,
        focusNode: focus,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: selected == null
              ? null
              : IconButton(
                  tooltip: clearTooltip,
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    controller.clear();
                    onChanged(null);
                  },
                ),
        ),
      ),
    );
  }
}

/// Add a root account, a child of [parent], or edit [editing]. True when saved.
Future<bool> showAccountForm(
  BuildContext context, {
  required ApiService api,
  required List<Map<String, dynamic>> accounts,
  Map<String, dynamic>? editing,
  Map<String, dynamic>? parent,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _AccountForm(
      api: api,
      accounts: accounts,
      editing: editing,
      parent: parent,
    ),
  );
  return saved == true;
}

class _AccountForm extends StatefulWidget {
  final ApiService api;
  final List<Map<String, dynamic>> accounts;
  final Map<String, dynamic>? editing;
  final Map<String, dynamic>? parent;

  const _AccountForm({
    required this.api,
    required this.accounts,
    this.editing,
    this.parent,
  });

  @override
  State<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<_AccountForm> {
  final _form = GlobalKey<FormState>();
  final _number = TextEditingController();
  late final TextEditingController _name = TextEditingController(
    text: (widget.editing?['name'] ?? '').toString(),
  );
  late Map<String, dynamic>? _parent = widget.editing != null
      ? _byId(widget.editing!['parent_id'])
      : widget.parent;
  late String _type =
      (widget.editing?['type'] ?? widget.parent?['type'] ?? 'Asset').toString();
  late bool _gramProfit = widget.editing?['include_in_gram_profit'] == true;
  bool _parallel = false;
  String? _parallelNumber;
  bool _suggesting = false;
  bool _saving = false;

  bool get _editing => widget.editing != null;

  Map<String, dynamic>? _byId(dynamic id) => id == null
      ? null
      : widget.accounts.where((a) => a['id'] == id).firstOrNull;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _number.text = normalizeNumber(
        widget.editing!['account_number']?.toString(),
      );
    } else {
      _suggest();
    }
  }

  @override
  void dispose() {
    _number.dispose();
    _name.dispose();
    super.dispose();
  }

  /// The next number under the parent -- the server's; a root's, the next root.
  Future<void> _suggest() async {
    final parent = _parent;
    if (parent == null) {
      final roots = widget.accounts.where((a) => a['parent_id'] == null);
      final top = roots.fold<int>(0, (m, a) {
        final n =
            int.tryParse(normalizeNumber(a['account_number']?.toString())) ?? 0;
        return n > m ? n : m;
      });
      setState(() {
        _number.text = '${top + 1}';
        _parallel = false;
      });
      return;
    }
    setState(() => _suggesting = true);
    try {
      final s = await widget.api.getNextAccountNumber(
        normalizeNumber(parent['account_number']?.toString()),
      );
      if (!mounted) return;
      setState(() {
        _number.text = normalizeNumber(s['suggested_number']?.toString() ?? '');
        _parallel = s['parent_has_parallel'] == true;
        _parallelNumber = s['suggested_parallel_number']?.toString();
        _type = (parent['type'] ?? _type).toString();
      });
    } catch (e) {
      if (mounted) {
        _say(context, 'تعذّر اقتراح رقم الحساب: ${_message(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final number = normalizeNumber(_number.text);
      final parent = _parent;
      if (parent != null) {
        final v = await widget.api.validateAccountNumber(
          accountNumber: number,
          parentAccountNumber: normalizeNumber(
            parent['account_number']?.toString(),
          ),
          excludeAccountId: _editing ? widget.editing!['id'] as int : null,
        );
        if (v['is_valid'] != true) {
          if (mounted) {
            _say(
              context,
              v['message']?.toString() ?? 'رقم الحساب غير صالح',
              error: true,
            );
          }
          return;
        }
      }
      final data = <String, dynamic>{
        'name': _name.text.trim(),
        'account_number': number,
        'type': _type,
        'parent_id': parent?['id'],
        'include_in_gram_profit': _gramProfit,
      };
      if (_editing) {
        await widget.api.updateAccount(widget.editing!['id'] as int, data);
      } else {
        await widget.api.addAccount({...data, 'create_parallel': _parallel});
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _say(context, _message(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The parent, found by number or name as people write them (أ/ا، ١٢٣).
  Widget _parentField() {
    return AccountSearchField(
      fieldKey: const Key('account-form-parent'),
      accounts: widget.accounts
          .where((a) => !_editing || a['id'] != widget.editing!['id'])
          .toList(),
      selected: _parent,
      label: 'الحساب الأصلي',
      hint: 'ابحث برقم أو اسم — فارغ لحساب رئيسي',
      clearTooltip: 'حساب رئيسي',
      onChanged: (a) {
        setState(() => _parent = a);
        if (!_editing) _suggest();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // A child is what its parent is -- the server's rule (CHART-002 4c4): a weight
    // parent's child tracks weight. Its mark, not its number's first digit.
    final parentWeight = _parent?['tracks_weight'];
    final isMemo = parentWeight == true || parentWeight == 1 || '$parentWeight' == 'true';
    return AlertDialog(
      title: Text(
        _editing
            ? 'تعديل الحساب'
            : (_parent != null ? 'إضافة حساب فرعي' : 'إضافة حساب رئيسي'),
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _parentField(),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('account-form-number'),
                  controller: _number,
                  decoration: InputDecoration(
                    labelText: 'رقم الحساب',
                    suffixIcon: _suggesting
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    NormalizeNumberFormatter(),
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  onChanged: (_) => setState(() {}),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'الرجاء إدخال رقم' : null,
                ),
                TextFormField(
                  key: const Key('account-form-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'اسم الحساب'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'الرجاء إدخال اسم' : null,
                ),
                const SizedBox(height: 8),
                if (_parent == null)
                  DropdownButtonFormField<String>(
                    initialValue: accountTypeLabels.containsKey(_type)
                        ? _type
                        : 'Asset',
                    decoration: const InputDecoration(labelText: 'نوع الحساب'),
                    items: [
                      for (final e in accountTypeLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  )
                else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('نوع الحساب'),
                    trailing: Text(accountTypeLabel(_type)),
                    subtitle: const Text('من الحساب الأصلي'),
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _gramProfit,
                  title: const Text('يدخل في تقرير ربح الجرام'),
                  subtitle: const Text(
                    'يُحسب ضمن الربح الوزني إيرادًا أو مصروفًا',
                  ),
                  onChanged: (v) => setState(() => _gramProfit = v),
                ),
                if (!_editing && !isMemo) ...[
                  const Divider(height: 24),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _parallel,
                    title: const Text('إنشاء حساب موازٍ وزني'),
                    subtitle: Text(
                      _parallelNumber != null
                          ? 'الحساب الموازي المقترح: $_parallelNumber'
                          : 'يُنشئ حسابًا بالرقم نفسه مسبوقًا بـ 7',
                    ),
                    onChanged: (v) => setState(() => _parallel = v),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('account-form-save'),
          onPressed: _saving || _suggesting ? null : _save,
          child: Text(_editing ? 'حفظ' : 'إضافة'),
        ),
      ],
    );
  }
}

/// Delete [account] -- the server refuses what would break something, and
/// asks about a parallel weight account. True when deleted.
Future<bool> deleteAccountFlow(
  BuildContext context, {
  required ApiService api,
  required Map<String, dynamic> account,
}) async {
  final label = '${account['account_number']} «${account['name']}»';
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('حذف الحساب'),
      content: Text(
        'يُحذف $label نهائيًا. لا يُحذف حساب له حركات أو حسابات فرعية أو ربط — '
        'والإيقاف يُبقيه بتاريخه.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          key: const Key('account-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('حذف'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  return _delete(context, api, account, null);
}

Future<bool> _delete(
  BuildContext context,
  ApiService api,
  Map<String, dynamic> account,
  bool? withParallel,
) async {
  try {
    final result = await api.deleteAccount(
      account['id'] as int,
      deleteParallel: withParallel,
    );
    if (result['result'] != 'confirm_required') return true;
    if (!context.mounted) return false;
    final parallel = Map<String, dynamic>.from(
      result['parallel_account'] as Map,
    );
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('الحساب الموازي'),
        content: Text(
          'الحساب مرتبط بحساب موازٍ بلا حركات:\n'
          '${parallel['account_number']} — ${parallel['name']}\n\nهل يُحذف معه؟',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          TextButton(
            key: const Key('account-delete-only-this'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('هذا فقط'),
          ),
          FilledButton(
            key: const Key('account-delete-both'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('الاثنان'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return false;
    return _delete(context, api, account, choice);
  } catch (e) {
    if (context.mounted) _say(context, _message(e), error: true);
    return false;
  }
}

/// The chart as JSON: copy it, or download it on the web.
Future<void> exportAccountsFlow(
  BuildContext context, {
  required ApiService api,
}) async {
  try {
    final json = await api.exportAccounts();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تصدير شجرة الحسابات'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(json, textDirection: TextDirection.ltr),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              Navigator.pop(context);
              _say(context, 'نُسخ JSON إلى الحافظة');
            },
            child: const Text('نسخ'),
          ),
          if (kIsWeb)
            TextButton(
              onPressed: () {
                try {
                  web_io.downloadString('accounts.json', json);
                } catch (e) {
                  _say(context, 'فشل التنزيل: ${_message(e)}', error: true);
                }
              },
              child: const Text('تنزيل'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (context.mounted) {
      _say(context, 'تعذّر التصدير: ${_message(e)}', error: true);
    }
  }
}

/// Import a chart exported as JSON. True when imported.
Future<bool> importAccountsFlow(
  BuildContext context, {
  required ApiService api,
}) async {
  final input = TextEditingController();
  final done = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('استيراد شجرة الحسابات'),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: TextField(
          controller: input,
          maxLines: null,
          expands: true,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            hintText: '{"accounts": [...]}',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        if (kIsWeb)
          TextButton(
            onPressed: () async {
              try {
                final content = await web_io.pickJsonFile();
                if (content != null) input.text = content;
              } catch (e) {
                if (context.mounted) {
                  _say(context, 'فشل تحميل الملف: ${_message(e)}', error: true);
                }
              }
            },
            child: const Text('اختر ملفًا'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () async {
            final payload = input.text.trim();
            if (payload.isEmpty) {
              _say(context, 'الصق محتوى JSON أولًا', error: true);
              return;
            }
            try {
              final res = await api.importAccountsFromJsonString(payload);
              if (!context.mounted) return;
              Navigator.pop(context, true);
              _say(
                context,
                'استُورد: ${res['created'] ?? 0} جديد، ${res['updated'] ?? 0} محدَّث',
              );
            } catch (e) {
              if (context.mounted) {
                _say(context, 'فشل الاستيراد: ${_message(e)}', error: true);
              }
            }
          },
          child: const Text('استيراد'),
        ),
      ],
    ),
  );
  input.dispose();
  return done == true;
}
