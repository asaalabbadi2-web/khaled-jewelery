import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../utils/party_balance.dart';

/// A customer or supplier picked by name, code or phone (the voucher screen
/// review, 20 Oct 2026): the search takes the typing at once; each party
/// shows its code, phone and what is between us; the dialog keeps its height
/// while it is searched, so the result does not move from under the hand.
class PartyPickerDialog extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> items;
  final int? selectedId;
  final String emptyText;
  final String currencySymbol;

  /// The karat a party's gold is said in, all its karats as one figure;
  /// the settings' when not given -- never a fixed one.
  final int? mainKarat;

  const PartyPickerDialog({
    super.key,
    required this.title,
    required this.items,
    this.selectedId,
    this.emptyText = 'لا توجد بيانات',
    this.currencySymbol = 'ر.س',
    this.mainKarat,
  });

  @override
  State<PartyPickerDialog> createState() => _PartyPickerDialogState();
}

class _PartyPickerDialogState extends State<PartyPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  String _asString(dynamic v) => (v ?? '').toString().trim();

  String _phoneOf(Map<String, dynamic> item) {
    return _asString(
      item['phone'] ??
          item['phone_number'] ??
          item['customer_phone'] ??
          item['supplier_phone'],
    );
  }

  String _mobileOf(Map<String, dynamic> item) {
    return _asString(item['mobile'] ?? item['mobile_number']);
  }

  List<Map<String, dynamic>> _filtered() {
    final q = _query.trim().toLowerCase();
    Iterable<Map<String, dynamic>> items = widget.items;

    if (q.isNotEmpty) {
      items = items.where((m) {
        final name = _asString(m['name']).toLowerCase();
        final phone = _phoneOf(m).toLowerCase();
        final mobile = _mobileOf(m).toLowerCase();
        final idNo = _asString(m['identity_number']).toLowerCase();
        final code = _codeOf(m).toLowerCase();
        return name.contains(q) ||
            phone.contains(q) ||
            mobile.contains(q) ||
            idNo.contains(q) ||
            code.contains(q);
      });
    }

    final list = items.toList();
    list.sort((a, b) {
      final an = _asString(a['name']);
      final bn = _asString(b['name']);
      return an.compareTo(bn);
    });
    return list;
  }

  String _codeOf(Map<String, dynamic> item) => _asString(
    item['supplier_code'] ?? item['customer_code'] ?? item['code'],
  );

  String _subtitle(Map<String, dynamic> item) {
    final phone = _phoneOf(item);
    final mobile = _mobileOf(item);
    final parts = <String>[];
    final code = _codeOf(item);
    if (code.isNotEmpty) parts.add(code);
    if (phone.isNotEmpty) parts.add(phone);
    if (mobile.isNotEmpty && mobile != phone) parts.add(mobile);
    final balance = partyBalanceBrief(
      item,
      currencySymbol: widget.currencySymbol,
      mainKarat: widget.mainKarat ?? context.read<SettingsProvider>().mainKarat,
    );
    return [
      parts.join(' • '),
      if (balance != null && balance.isNotEmpty) balance.join(' • '),
    ].where((p) => p.isNotEmpty).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The height it opens with, kept while it is searched.
    final height = (MediaQuery.sizeOf(context).height * 0.7).clamp(240.0, 600.0);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: height,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              // Enter takes the one party the search leaves.
              onSubmitted: (_) {
                if (filtered.length == 1) Navigator.pop(context, filtered.single);
              },
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'ابحث بالاسم / الجوال / الهاتف',
                suffixIcon: _query.trim().isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          setState(() {
                            _query = '';
                            _searchController.clear();
                          });
                        },
                        icon: const Icon(Icons.close),
                        tooltip: 'مسح',
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  widget.emptyText,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = filtered[index];
                    final id = _toInt(item['id']);
                    final name = _asString(item['name']);
                    final selected = (id != null && id == widget.selectedId);
                    final subtitle = _subtitle(item);

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: selected
                            ? cs.primary.withValues(alpha: 0.15)
                            : cs.surfaceContainerHighest,
                        child: Icon(
                          Icons.person_outline,
                          color: selected ? cs.primary : cs.onSurfaceVariant,
                        ),
                      ),
                      title: Text(name.isEmpty ? 'بدون اسم' : name),
                      subtitle: subtitle.isEmpty ? null : Text(subtitle),
                      trailing: selected
                          ? Icon(
                              Icons.check_circle,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, item),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
      ],
    );
  }
}
