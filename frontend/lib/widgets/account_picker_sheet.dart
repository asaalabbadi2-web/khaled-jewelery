import 'package:flutter/material.dart';

typedef AccountPredicate = bool Function(Map<String, dynamic> account);

enum AccountTransactionFilter { all, cash, gold, both }

enum AccountTracksWeightFilter { all, weightOnly, nonWeightOnly }

enum AccountLeafFilter { all, leafOnly }

int? _idOf(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}');
}

/// The ids some account names as its parent: the group accounts.
Set<int> parentAccountIdsOf(Iterable<Map<String, dynamic>> accounts) => {
      for (final a in accounts)
        if (_idOf(a['parent_id'] ?? a['parentId']) != null)
          _idOf(a['parent_id'] ?? a['parentId'])!,
    };

/// A detail account -- one posted to -- is one no account is under; never
/// judged by how long its number is (ACCT-LEAF-1: by length, the voucher
/// screen offered 48 group accounts and hid 27 detail ones, 310 رأس المال
/// among them, 15 Oct 2026).
bool isLeafAccount(Map<String, dynamic> account, Set<int> parentIds) {
  final id = _idOf(account['id']);
  return id == null || !parentIds.contains(id);
}

String accountNumberOf(Map<String, dynamic> account) {
  final v =
      account['account_number'] ??
      account['number'] ??
      account['accountNumber'];
  return (v ?? '').toString();
}

String accountNameOf(Map<String, dynamic> account) {
  final v = account['name'] ?? account['name_ar'] ?? account['nameAr'];
  return (v ?? '').toString();
}

String accountNameEnOf(Map<String, dynamic> account) {
  final v = account['name_en'] ?? account['nameEn'];
  return (v ?? '').toString();
}

String accountLabelOf(Map<String, dynamic> account) {
  final number = accountNumberOf(account).trim();
  final name = accountNameOf(account).trim();
  if (number.isEmpty) return name;
  if (name.isEmpty) return number;
  return '$number - $name';
}

bool accountTracksWeight(Map<String, dynamic> account) {
  final v = account['tracks_weight'];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.toLowerCase() == 'true' || v == '1';
  return false;
}

String accountTransactionTypeOf(Map<String, dynamic> account) {
  final v = account['transaction_type'] ?? account['transactionType'];
  return (v ?? 'both').toString();
}

String accountTransactionTypeLabel(
  String transactionType, {
  required bool isArabic,
}) {
  final t = transactionType.trim().toLowerCase();
  if (isArabic) {
    if (t == 'cash') return 'نقدي';
    if (t == 'gold') return 'ذهبي';
    return 'كلاهما';
  }
  if (t == 'cash') return 'Cash';
  if (t == 'gold') return 'Gold';
  return 'Both';
}

Future<Map<String, dynamic>?> showAccountPickerBottomSheet({
  required BuildContext context,
  required List<Map<String, dynamic>> accounts,
  String title = 'اختيار حساب',
  bool isArabic = true,
  int? selectedId,
  String? initialQuery,
  AccountPredicate? predicate,
  bool showTransactionTypeFilter = true,
  bool showTracksWeightFilter = false,
  bool showLeafOnlyFilter = false,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final searchCtrl = TextEditingController(text: initialQuery ?? '');
      AccountTransactionFilter txFilter = AccountTransactionFilter.all;
      AccountTracksWeightFilter weightFilter = AccountTracksWeightFilter.all;
      AccountLeafFilter leafFilter = AccountLeafFilter.all;

      int? toInt(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return int.tryParse('${v ?? ''}');
      }

      final parentIds = parentAccountIdsOf(accounts);

      // Same merge as the accounts list screen (see _annotateMemoLinks in
      // accounts_screen.dart): a leaf financial account paired with a leaf
      // memo/weight account already gets both posted to it automatically
      // (see _resolve_account_id_for_amount_type in routes.py), so picking
      // either one is the same choice. Hide the memo side from the default
      // list -- picking the financial side covers both -- and surface the
      // pairing as a hint on the financial side's row instead. Category-
      // level pairs (the memo side also has children) are left alone; only
      // hide a leaf-to-leaf pair.
      final accountsById = <int, Map<String, dynamic>>{};
      for (final a in accounts) {
        final id = toInt(a['id']);
        if (id != null) accountsById[id] = a;
      }
      final absorbedMemoIds = <int>{};
      final memoNameByFinancialId = <int, String>{};
      for (final a in accounts) {
        final id = toInt(a['id']);
        if (id == null || accountTracksWeight(a)) continue;
        if (parentIds.contains(id)) continue;
        final memoId = toInt(a['memo_account_id'] ?? a['memoAccountId']);
        if (memoId == null) continue;
        final memo = accountsById[memoId];
        if (memo == null || !accountTracksWeight(memo)) continue;
        if (parentIds.contains(memoId)) continue;
        absorbedMemoIds.add(memoId);
        memoNameByFinancialId[id] = accountLabelOf(memo);
      }

      List<Map<String, dynamic>> applyFilters(String q) {
        final query = q.trim().toLowerCase();
        final result = <Map<String, dynamic>>[];

        bool txOk(Map<String, dynamic> a) {
          if (!showTransactionTypeFilter) return true;
          final t = accountTransactionTypeOf(a).toLowerCase();
          switch (txFilter) {
            case AccountTransactionFilter.all:
              return true;
            case AccountTransactionFilter.cash:
              return t == 'cash';
            case AccountTransactionFilter.gold:
              return t == 'gold';
            case AccountTransactionFilter.both:
              return t == 'both';
          }
        }

        bool weightOk(Map<String, dynamic> a) {
          if (!showTracksWeightFilter) return true;
          final isWeight = accountTracksWeight(a);
          switch (weightFilter) {
            case AccountTracksWeightFilter.all:
              return true;
            case AccountTracksWeightFilter.weightOnly:
              return isWeight;
            case AccountTracksWeightFilter.nonWeightOnly:
              return !isWeight;
          }
        }

        bool leafOk(Map<String, dynamic> a) {
          if (!showLeafOnlyFilter) return true;
          if (leafFilter == AccountLeafFilter.all) return true;
          return isLeafAccount(a, parentIds);
        }

        bool queryOk(Map<String, dynamic> a) {
          if (query.isEmpty) return true;
          final numStr = accountNumberOf(a).toLowerCase();
          final name = accountNameOf(a).toLowerCase();
          final nameEn = accountNameEnOf(a).toLowerCase();
          if (numStr.contains(query) ||
              name.contains(query) ||
              nameEn.contains(query)) {
            return true;
          }
          // digits-only assist
          final digits = query.replaceAll(RegExp(r'[^0-9]'), '');
          if (digits.isNotEmpty) {
            return numStr.contains(digits) || numStr.startsWith(digits);
          }
          return false;
        }

        final explicitlyWantsWeight =
            txFilter == AccountTransactionFilter.gold ||
            weightFilter == AccountTracksWeightFilter.weightOnly;

        for (final a in accounts) {
          if (predicate != null && !predicate(a)) continue;
          if (!txOk(a)) continue;
          if (!weightOk(a)) continue;
          if (!leafOk(a)) continue;
          if (!queryOk(a)) continue;
          if (!explicitlyWantsWeight) {
            final id = toInt(a['id']);
            if (id != null &&
                absorbedMemoIds.contains(id) &&
                id != selectedId) {
              continue;
            }
          }
          result.add(a);
        }

        result.sort((a, b) {
          final an = accountNumberOf(a);
          final bn = accountNumberOf(b);
          final ai = int.tryParse(an);
          final bi = int.tryParse(bn);
          if (ai != null && bi != null) return ai.compareTo(bi);
          return an.compareTo(bn);
        });

        // Keep the sheet responsive on web.
        if (result.length > 800) {
          return result.take(800).toList(growable: false);
        }

        return result;
      }

      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          final visible = applyFilters(searchCtrl.text);

          Widget chip({
            required bool selected,
            required String label,
            required VoidCallback onTap,
          }) {
            return FilterChip(
              selected: selected,
              label: Text(label),
              onSelected: (_) => onTap(),
            );
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 10,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: isArabic
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          textAlign: isArabic
                              ? TextAlign.right
                              : TextAlign.left,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                        tooltip: isArabic ? 'إغلاق' : 'Close',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: searchCtrl,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: isArabic
                          ? 'ابحث بالرقم أو الاسم...'
                          : 'Search by number or name...',
                      suffixIcon: searchCtrl.text.trim().isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                searchCtrl.clear();
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (showTransactionTypeFilter) ...[
                    Align(
                      alignment: isArabic
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          chip(
                            selected: txFilter == AccountTransactionFilter.all,
                            label: isArabic ? 'الكل' : 'All',
                            onTap: () => setSheetState(() {
                              txFilter = AccountTransactionFilter.all;
                            }),
                          ),
                          chip(
                            selected: txFilter == AccountTransactionFilter.cash,
                            label: isArabic ? 'نقدي' : 'Cash',
                            onTap: () => setSheetState(() {
                              txFilter = AccountTransactionFilter.cash;
                            }),
                          ),
                          chip(
                            selected: txFilter == AccountTransactionFilter.gold,
                            label: isArabic ? 'ذهبي' : 'Gold',
                            onTap: () => setSheetState(() {
                              txFilter = AccountTransactionFilter.gold;
                            }),
                          ),
                          chip(
                            selected: txFilter == AccountTransactionFilter.both,
                            label: isArabic ? 'كلاهما' : 'Both',
                            onTap: () => setSheetState(() {
                              txFilter = AccountTransactionFilter.both;
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (showTracksWeightFilter) ...[
                    Align(
                      alignment: isArabic
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          chip(
                            selected:
                                weightFilter == AccountTracksWeightFilter.all,
                            label: isArabic ? 'كل الحسابات' : 'All accounts',
                            onTap: () => setSheetState(() {
                              weightFilter = AccountTracksWeightFilter.all;
                            }),
                          ),
                          chip(
                            selected:
                                weightFilter ==
                                AccountTracksWeightFilter.weightOnly,
                            label: isArabic ? 'وزني فقط' : 'Weight only',
                            onTap: () => setSheetState(() {
                              weightFilter =
                                  AccountTracksWeightFilter.weightOnly;
                            }),
                          ),
                          chip(
                            selected:
                                weightFilter ==
                                AccountTracksWeightFilter.nonWeightOnly,
                            label: isArabic ? 'غير وزني' : 'Non-weight',
                            onTap: () => setSheetState(() {
                              weightFilter =
                                  AccountTracksWeightFilter.nonWeightOnly;
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (showLeafOnlyFilter) ...[
                    Align(
                      alignment: isArabic
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          chip(
                            selected: leafFilter == AccountLeafFilter.all,
                            label: isArabic ? 'كل الحسابات' : 'All accounts',
                            onTap: () => setSheetState(() {
                              leafFilter = AccountLeafFilter.all;
                            }),
                          ),
                          chip(
                            selected: leafFilter == AccountLeafFilter.leafOnly,
                            label: isArabic
                                ? 'حسابات فرعية فقط'
                                : 'Leaf accounts only',
                            onTap: () => setSheetState(() {
                              leafFilter = AccountLeafFilter.leafOnly;
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          isArabic
                              ? 'النتائج: ${visible.length}'
                              : 'Results: ${visible.length}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey.shade700,
                          ),
                          textAlign: isArabic
                              ? TextAlign.right
                              : TextAlign.left,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 520,
                    child: visible.isEmpty
                        ? Center(
                            child: Text(
                              isArabic ? 'لا توجد نتائج' : 'No results',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          )
                        : ListView.separated(
                            itemCount: visible.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final a = visible[i];
                              final id = a['id'];
                              final idInt = id is int
                                  ? id
                                  : (id is num
                                        ? id.toInt()
                                        : int.tryParse('$id'));
                              final selected =
                                  (selectedId != null && idInt == selectedId);

                              final label = accountLabelOf(a);
                              final memoName = memoNameByFinancialId[idInt];
                              final txLabel = memoName == null
                                  ? accountTransactionTypeLabel(
                                      accountTransactionTypeOf(a),
                                      isArabic: isArabic,
                                    )
                                  : (isArabic
                                        ? '⚖️ يشمل الحساب الوزني المرتبط: $memoName'
                                        : '⚖️ Includes linked weight account: $memoName');

                              return ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  backgroundColor: selected
                                      ? theme.colorScheme.primary.withValues(
                                          alpha: 0.12,
                                        )
                                      : Colors.grey.shade200,
                                  child: Icon(
                                    Icons.account_tree_outlined,
                                    color: selected
                                        ? theme.colorScheme.primary
                                        : Colors.grey.shade700,
                                  ),
                                ),
                                title: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  txLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.grey.shade600,
                                  ),
                                  textAlign: isArabic
                                      ? TextAlign.right
                                      : TextAlign.left,
                                ),
                                trailing: selected
                                    ? Icon(
                                        Icons.check_circle,
                                        color: theme.colorScheme.primary,
                                      )
                                    : null,
                                onTap: () => Navigator.pop(ctx, a),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class AccountPickerFormField extends FormField<int> {
  AccountPickerFormField({
    super.key,
    super.validator,
    required BuildContext context,
    required List<Map<String, dynamic>> accounts,
    required ValueChanged<int?> onChanged,
    int? value,
    String labelText = 'الحساب',
    String hintText = 'اختر حساب',
    String title = 'اختيار حساب',
    bool isArabic = true,
    bool enabled = true,
    String? helperText,
    bool allowClear = false,
    String clearLabelAr = 'جميع الحسابات',
    String clearLabelEn = 'All accounts',
    AccountPredicate? predicate,
    bool showTransactionTypeFilter = true,
    bool showTracksWeightFilter = false,
  }) : super(
         initialValue: value,
         builder: (state) {
           Map<String, dynamic>? selectedAccount;
           if (state.value != null) {
             try {
               selectedAccount = accounts.firstWhere((a) {
                 final raw = a['id'];
                 final id = raw is int
                     ? raw
                     : (raw is num
                           ? raw.toInt()
                           : int.tryParse('${raw ?? ''}'));
                 return id == state.value;
               });
             } catch (_) {
               selectedAccount = null;
             }
           }

           final display = selectedAccount != null
               ? accountLabelOf(selectedAccount)
               : hintText;
           final txLabel = selectedAccount != null
               ? accountTransactionTypeLabel(
                   accountTransactionTypeOf(selectedAccount),
                   isArabic: isArabic,
                 )
               : null;

           Future<void> pick() async {
             if (!enabled) return;
             final picked = await showAccountPickerBottomSheet(
               context: context,
               accounts: accounts,
               title: title,
               isArabic: isArabic,
               selectedId: state.value,
               predicate: predicate,
               showTransactionTypeFilter: showTransactionTypeFilter,
               showTracksWeightFilter: showTracksWeightFilter,
             );
             if (picked == null) return;
             final raw = picked['id'];
             final id = raw is int
                 ? raw
                 : (raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}'));
             state.didChange(id);
             onChanged(id);
           }

           void clear() {
             if (!enabled) return;
             state.didChange(null);
             onChanged(null);
           }

           return InkWell(
             onTap: pick,
             child: InputDecorator(
               decoration: InputDecoration(
                 labelText: labelText,
                 border: const OutlineInputBorder(),
                 errorText: state.errorText,
                 helperText: helperText,
                 suffixIcon: Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     if (allowClear && state.value != null)
                       IconButton(
                         tooltip: isArabic ? clearLabelAr : clearLabelEn,
                         icon: const Icon(Icons.clear),
                         onPressed: clear,
                       ),
                     IconButton(
                       tooltip: isArabic ? 'بحث/فلترة' : 'Search/Filter',
                       icon: const Icon(Icons.manage_search),
                       onPressed: pick,
                     ),
                   ],
                 ),
               ),
               child: Row(
                 children: [
                   Expanded(
                     child: Text(
                       display,
                       maxLines: 1,
                       overflow: TextOverflow.ellipsis,
                       style: selectedAccount != null
                           ? const TextStyle(fontWeight: FontWeight.w600)
                           : TextStyle(color: Colors.grey.shade600),
                     ),
                   ),
                   if (txLabel != null) ...[
                     const SizedBox(width: 10),
                     Text(
                       txLabel,
                       style: TextStyle(
                         color: Colors.grey.shade600,
                         fontSize: 11,
                       ),
                     ),
                   ],
                   const SizedBox(width: 6),
                   const Icon(Icons.arrow_drop_down),
                 ],
               ),
             ),
           );
         },
       );
}
