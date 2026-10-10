/// The chart of accounts as a tree, for the accounts list (10 Oct 2026).
///
/// Built from what /api/accounts already sends -- each account's parent_id --
/// so the list reads as the chart does: a parent, then its children indented
/// under it, folded until opened.
library;

class AccountTreeRow {
  final Map<String, dynamic> account;
  final int depth;
  final bool hasChildren;
  final bool expanded;

  const AccountTreeRow(this.account, this.depth, {required this.hasChildren, required this.expanded});

  int? get id => _id(account);
}

int? _id(Map<String, dynamic> a) {
  final v = a['id'];
  return v is int ? v : int.tryParse('${v ?? ''}');
}

int? _parentId(Map<String, dynamic> a) {
  final v = a['parent_id'];
  return v is int ? v : int.tryParse('${v ?? ''}');
}

/// The visible rows: roots first, each parent followed by its children in
/// account-number order, a folded parent's children left out.
///
/// [include] keeps an account (the screen's filters); a parent is kept while
/// any account under it is, so a match is never orphaned from its place.
/// [collapsed] are the parents folded.
List<AccountTreeRow> accountTreeRows(
  List<Map<String, dynamic>> accounts, {
  required Set<int> collapsed,
  bool Function(Map<String, dynamic>)? include,
}) {
  final byId = <int, Map<String, dynamic>>{};
  for (final a in accounts) {
    final id = _id(a);
    if (id != null) byId[id] = a;
  }
  final children = <int?, List<Map<String, dynamic>>>{};
  for (final a in accounts) {
    final parent = _parentId(a);
    children.putIfAbsent(byId.containsKey(parent) ? parent : null, () => []).add(a);
  }
  int byNumber(Map<String, dynamic> x, Map<String, dynamic> y) =>
      '${x['account_number'] ?? ''}'.compareTo('${y['account_number'] ?? ''}');
  for (final list in children.values) {
    list.sort(byNumber);
  }

  final kept = <int, bool>{};
  bool keeps(Map<String, dynamic> a) {
    final id = _id(a);
    if (id != null && kept.containsKey(id)) return kept[id]!;
    final self = include == null || include(a);
    final any = self || (children[id] ?? const []).any(keeps);
    if (id != null) kept[id] = any;
    return any;
  }

  final rows = <AccountTreeRow>[];
  void walk(Map<String, dynamic> a, int depth) {
    if (!keeps(a)) return;
    final id = _id(a);
    final kids = (children[id] ?? const []).where(keeps).toList();
    final open = !collapsed.contains(id);
    rows.add(AccountTreeRow(a, depth, hasChildren: kids.isNotEmpty, expanded: open));
    if (open) {
      for (final k in kids) {
        walk(k, depth + 1);
      }
    }
  }

  for (final root in children[null] ?? const <Map<String, dynamic>>[]) {
    walk(root, 0);
  }
  return rows;
}

/// Every parent but the roots: the tree opens on the roots and their children.
Set<int> accountTreeDefaultCollapsed(List<Map<String, dynamic>> accounts) {
  final ids = {for (final a in accounts) _id(a)}..remove(null);
  final parents = <int>{};
  for (final a in accounts) {
    final p = _parentId(a);
    if (p != null && ids.contains(p)) parents.add(p);
  }
  final roots = {
    for (final a in accounts)
      if (_parentId(a) == null || !ids.contains(_parentId(a))) _id(a)
  };
  return parents.difference(roots.whereType<int>().toSet());
}
