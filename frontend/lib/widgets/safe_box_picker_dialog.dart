import 'package:flutter/material.dart';

import '../models/safe_box_model.dart';

class SafeBoxPickerDialog extends StatefulWidget {
  final List<SafeBoxModel> safeBoxes;
  final int? selectedSafeBoxId;
  final String? filterSafeType;
  final bool excludeGold;

  const SafeBoxPickerDialog({
    super.key,
    required this.safeBoxes,
    this.selectedSafeBoxId,
    this.filterSafeType,
    this.excludeGold = true,
  });

  @override
  State<SafeBoxPickerDialog> createState() => _SafeBoxPickerDialogState();
}

class _SafeBoxPickerDialogState extends State<SafeBoxPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _showAllTypes = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SafeBoxModel> _filtered() {
    Iterable<SafeBoxModel> items = widget.safeBoxes;

    if (widget.excludeGold) {
      items = items.where((sb) => (sb.safeType).toLowerCase() != 'gold');
    }

    final filterType = (widget.filterSafeType ?? '').trim().toLowerCase();
    if (!_showAllTypes && filterType.isNotEmpty) {
      items = items.where((sb) => (sb.safeType).toLowerCase() == filterType);
    }

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((sb) {
        final name = sb.name.toLowerCase();
        final bank = (sb.bankName ?? '').toLowerCase();
        final iban = (sb.iban ?? '').toLowerCase();
        return name.contains(q) || bank.contains(q) || iban.contains(q);
      });
    }

    final list = items.toList();
    list.sort((a, b) {
      final ad = a.isDefault ? 1 : 0;
      final bd = b.isDefault ? 1 : 0;
      if (ad != bd) return bd.compareTo(ad);
      return a.name.compareTo(b.name);
    });
    return list;
  }

  String _typeLabel(String safeType) {
    switch (safeType.toLowerCase()) {
      case 'cash':
        return 'نقد';
      case 'bank':
        return 'بنك';
      case 'clearing':
        return 'مستحقات تحصيل';
      case 'check':
        return 'شيكات';
      case 'gold':
        return 'ذهب';
      default:
        return safeType;
    }
  }

  IconData _typeIcon(String safeType) {
    switch (safeType.toLowerCase()) {
      case 'cash':
        return Icons.payments;
      case 'bank':
        return Icons.account_balance;
      case 'clearing':
        return Icons.swap_horiz;
      case 'check':
        return Icons.receipt_long;
      case 'gold':
        return Icons.currency_exchange;
      default:
        return Icons.lock;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();

    return AlertDialog(
      title: const Text('اختيار خزينة'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'ابحث بالاسم/البنك/IBAN',
                suffixIcon: _query.isEmpty
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.filterSafeType == null || widget.filterSafeType!.isEmpty
                        ? 'كل الأنواع'
                        : 'التصفية: ${_typeLabel(widget.filterSafeType!)}',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _showAllTypes = !_showAllTypes),
                  icon: Icon(_showAllTypes ? Icons.filter_alt_off : Icons.filter_alt),
                  label: Text(_showAllTypes ? 'عرض الكل' : 'تطبيق النوع'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'لا توجد خزائن مطابقة',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final sb = filtered[index];
                    final selected = (sb.id != null && sb.id == widget.selectedSafeBoxId);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: selected
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                            : Colors.grey.shade200,
                        child: Icon(
                          _typeIcon(sb.safeType),
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade700,
                        ),
                      ),
                      title: Text(sb.name),
                      subtitle: Text(
                        '${_typeLabel(sb.safeType)} • حساب: ${sb.accountId}${sb.isDefault ? ' • افتراضية' : ''}',
                      ),
                      trailing: selected
                          ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, sb),
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
