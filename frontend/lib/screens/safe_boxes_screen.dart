import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../app_events.dart';
import '../models/safe_box_model.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/arabic_search.dart';
import '../utils/bidi.dart';
import '../widgets/account_management.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_shortcuts.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import 'account_statement_screen.dart';
import 'add_voucher_screen.dart';
import 'clearing_settlement_screen.dart';
import 'safe_transfer_screen.dart';

/// «إدارة الخزائن» (SAFES-UI-1, the analysis of 12 Oct 2026).
///
/// The server answers: each safe's balance and the totals per type -- the
/// amount for money, the grams in the main karat for gold. The screen shows
/// them: a tile per type (which is also its filter), the safes grouped under
/// their type, a card whose details open where it is tapped. Colours come
/// from the theme.

/// The types in the order they are shown, and their names -- one name each,
/// everywhere (the tab said «شبكات» for `check`, the form «شيكات»; the card
/// networks sat under «مستحقات تحصيل»).
const safeTypeLabels = {
  'cash': 'النقدية',
  'bank': 'البنوك',
  'clearing': 'الشبكات',
  'gold': 'الذهب',
  'check': 'الشيكات',
};

/// The sections, in order -- the server's grouping: money by its type, gold
/// by its kind, as cash and the banks are apart (ADR-052): the shop's, the
/// employees' custody, deposited with offices; and a gold safe with no place,
/// a party's (ADR-051). Not types: the create form lists [safeTypeLabels].
const safeGroupLabels = {
  ...safeTypeLabels,
  'gold_shop': 'ذهب المحل',
  'gold_custody': 'عهد الذهب',
  'gold_deposit': 'ذهب مودع لدى المكاتب',
  'party_gold': 'ذهب لدى الأطراف',
};
const _groupOrder = [
  'cash',
  'bank',
  'clearing',
  'gold_shop',
  'gold',
  'gold_custody',
  'gold_deposit',
  'party_gold',
  'check',
];

/// A gold group's place, for a new safe made from its section.
const _groupPlace = {
  'gold_custody': 'custody',
  'gold_deposit': 'deposit',
  'party_gold': 'party',
};

/// Where a gold safe's gold is (ADR-045); «party»: with an office or a
/// supplier, no place -- sent as null (ADR-051).
const stockPlaceLabels = {
  'showroom': 'معروض',
  'custody': 'عهدة موظف',
  'scrap': 'كسر',
  'workshop': 'ورشة',
  'transit': 'في الطريق',
  'deposit': 'مودع لدى مكتب',
  'party': 'لدى طرف (مكتب أو مورد)',
};

/// Whose a party's gold is, as the server reads it.

const _partySideLabels = {'ours': 'لنا', 'theirs': 'علينا', 'settled': 'مسوّى'};

/// One safe's type in the singular, for its badge and the form.
const _safeTypeSingular = {
  'cash': 'نقدية',
  'bank': 'بنك',
  'clearing': 'شبكة',
  'gold': 'ذهب',
  'check': 'شيكات',
};

IconData _typeIcon(String type) => switch (type) {
  'cash' => Icons.payments_outlined,
  'bank' => Icons.account_balance_outlined,
  'clearing' => Icons.credit_card_outlined,
  'gold' || 'gold_shop' => Icons.diamond_outlined,
  'gold_custody' => Icons.badge_outlined,
  'gold_deposit' => Icons.savings_outlined,
  'party_gold' => Icons.handshake_outlined,
  'check' => Icons.receipt_long_outlined,
  _ => Icons.account_balance_wallet_outlined,
};

SemanticTone _typeTone(AppSemanticColors tones, String type) => switch (type) {
  'cash' => tones.cash,
  'bank' => tones.sectionBlue,
  'clearing' => tones.sectionTeal,
  'gold' || 'gold_shop' => tones.gold,
  'gold_custody' => tones.sectionIndigo,
  'gold_deposit' => tones.sectionAmber,
  'party_gold' => tones.sectionOrange,
  'check' => tones.sectionPurple,
  _ => tones.sectionSlate,
};

String _message(Object e) => AppFeedback.messageOf(e);

final _money = NumberFormat('#,##0.00', 'en');
final _grams = NumberFormat('#,##0.000', 'en');

class SafeBoxesScreen extends StatefulWidget {
  final ApiService api;

  /// Opens on one type; [lockFilterType] keeps it there (a report's view).
  final String? initialFilterType;
  final bool lockFilterType;
  final String? titleOverride;

  SafeBoxesScreen({
    super.key,
    ApiService? api,
    this.initialFilterType,
    this.lockFilterType = false,
    this.titleOverride,
  }) : api = api ?? ApiService();

  @override
  State<SafeBoxesScreen> createState() => _SafeBoxesScreenState();
}

class _SafeBoxesScreenState extends State<SafeBoxesScreen> {
  SafeBoxesOverview? _overview;
  Map<int, Map<String, double>> _stones = {};
  String? _error;
  bool _loading = true;
  late String _type = (widget.initialFilterType ?? '').trim().isEmpty
      ? 'all'
      : widget.initialFilterType!.trim();
  String _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _open = <int>{};

  ColorScheme get _scheme => Theme.of(context).colorScheme;
  TextTheme get _text => Theme.of(context).textTheme;
  AppSemanticColors get _tones => AppSemanticColors.of(context);

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.vaultRefreshSignal.addListener(_onVaultRefresh);
  }

  void _onVaultRefresh() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    AppEvents.vaultRefreshSignal.removeListener(_onVaultRefresh);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await widget.api.getSafeBoxesOverview();
      Map<int, Map<String, double>> stones = {};
      try {
        stones = await widget.api.getStonesBalance();
      } catch (_) {
        // The stones are informational; the safes show without them.
      }
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _stones = stones;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _message(e);
        _loading = false;
      });
    }
  }

  // ── formatting: numbers left-to-right and whole inside Arabic ──

  String get _symbol => context.read<SettingsProvider>().currencySymbolText;
  String _amount(double v) => ltrIsolate('${_money.format(v)} $_symbol');
  String _weight(double v) => ltrIsolate('${_grams.format(v)} جم');

  void _say(String text, {bool error = false}) => error
      ? AppFeedback.error(context, text)
      : AppFeedback.success(context, text);

  // ── what is shown ──

  /// The types the server reported, in the screen's order; one alone when
  /// locked. A section whose safes are all stopped is not shown -- the
  /// offices' old safes once their gold became deposits (ADR-052).
  List<String> get _types {
    final rows = _overview?.rows ?? const <SafeBoxModel>[];
    final present = (_overview?.totals.keys ?? const <String>[])
        .where(
          (t) => rows.any((sb) => (sb.group ?? sb.safeType) == t && sb.isActive),
        )
        .toSet();
    final ordered = [
      ..._groupOrder.where(present.contains),
      ...present.where((t) => !_groupOrder.contains(t)),
    ];
    if (widget.lockFilterType && _type != 'all') {
      return ordered.where((t) => _shows(t)).toList();
    }
    return ordered;
  }

  /// A filter on gold (a screen opened on «gold») shows every gold section.
  bool _shows(String group) =>
      group == _type || (_type == 'gold' && _isGoldGroup(group));

  List<SafeBoxModel> _rowsOf(String type) {
    final q = normalizeForSearch(_query);
    final rows =
        (_overview?.rows ?? const <SafeBoxModel>[]).where((sb) {
          if ((sb.group ?? sb.safeType) != type) return false;
          if (q.isEmpty) return true;
          return normalizeForSearch(
            [
              sb.name,
              sb.nameEn ?? '',
              sb.bankName ?? '',
              sb.account?.name ?? '',
              sb.account?.accountNumber ?? '',
            ].join(' '),
          ).contains(q);
        }).toList()..sort((a, b) {
          if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
          if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
          return a.name.compareTo(b.name);
        });
    return rows;
  }

  bool _isGold(SafeBoxModel sb) => sb.safeType == 'gold';

  bool _isGoldGroup(String group) =>
      group == 'gold' || group.startsWith('gold_') || group == 'party_gold';

  String _totalText(String type, SafeTypeTotal t) =>
      _isGoldGroup(type) ? _weight(t.weightMainKarat) : _amount(t.cash);

  // ── actions ──

  Future<void> _push(Widget screen) async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => screen));
    if (changed == true && mounted) _load();
  }

  void _add(SafeBoxModel sb) => _isGold(sb)
      ? _transfer(sb, toId: sb.id, note: 'إضافة رصيد إلى ${sb.name}')
      : _voucher(sb, 'receipt', 'إضافة رصيد إلى ${sb.name}');

  void _withdraw(SafeBoxModel sb) => _isGold(sb)
      ? _transfer(sb, fromId: sb.id, note: 'سحب من ${sb.name}')
      : _voucher(sb, 'payment', 'سحب من ${sb.name}');

  void _voucher(SafeBoxModel sb, String type, String description) => _push(
    AddVoucherScreen(
      voucherType: type,
      initialPartyType: 'other',
      initialOtherAccountId: sb.accountId,
      initialDescription: description,
    ),
  );

  void _transfer(
    SafeBoxModel sb, {
    int? fromId,
    int? toId,
    required String note,
  }) => _push(
    SafeTransferScreen(
      api: widget.api,
      initialMode: _isGold(sb) ? 'gold' : 'cash',
      initialFromSafeId: fromId,
      initialToSafeId: toId,
      initialNotes: note,
      popOnSuccess: true,
    ),
  );

  Future<void> _statement(SafeBoxModel sb) async {
    final account = sb.account;
    if (account == null) {
      _say('لا يوجد حساب مرتبط لعرض كشفه', error: true);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountStatementScreen(
          accountId: account.id,
          accountName: sb.name,
          entityType: 'account',
        ),
      ),
    );
  }

  Future<void> _edit([SafeBoxModel? sb]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SafeBoxForm(
        api: widget.api,
        editing: sb,
        type:
            sb?.safeType ??
            (_type == 'all' ? 'cash' : (_isGoldGroup(_type) ? 'gold' : _type)),
        place: sb == null ? _groupPlace[_type] : null,
        lockType: sb == null && widget.lockFilterType && _type != 'all',
      ),
    );
    if (saved == true && mounted) {
      _say(sb == null ? 'أُضيفت الخزينة' : 'حُفظت الخزينة');
      _load();
    }
  }

  Future<void> _delete(SafeBoxModel sb) async {
    final confirmed = await confirmFinancialAction(
      context,
      title: 'حذف الخزينة؟',
      effect:
          'تُحذف الخزينة من القائمة، ولا يُحذف حسابها ولا قيوده. خزينة مستعملة لا تُحذف: أوقفها بدل حذفها.',
      confirmLabel: 'حذف الخزينة',
      facts: [('الخزينة', sb.name)],
    );
    if (confirmed == null || !mounted) return;
    try {
      await widget.api.deleteSafeBox(sb.id!);
      _say('حُذفت الخزينة');
      _load();
    } catch (e) {
      _say(_deleteRefusal(e.toString()), error: true);
    }
  }

  /// The server refuses a safe in use and says what uses it.
  String _deleteRefusal(String raw) {
    Map<String, dynamic>? payload;
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start != -1 && end > start) {
      try {
        final decoded = json.decode(raw.substring(start, end + 1));
        if (decoded is Map<String, dynamic>) payload = decoded;
      } catch (_) {}
    }
    if (payload?['error'] == 'cannot_delete_safe_box_in_use') {
      final d = (payload?['details'] as Map?) ?? const {};
      return 'لا تُحذف الخزينة لأنها مستعملة — موظفون: ${d['employees_linked'] ?? 0}، '
          'عمليات: ${d['transactions_linked'] ?? 0}، فواتير: ${d['invoices_linked'] ?? 0}، '
          'وسائل دفع: ${d['payment_methods_linked'] ?? 0}. أوقفها بدل حذفها.';
    }
    final message = (payload?['message'] ?? payload?['error'])?.toString();
    return message?.trim().isNotEmpty == true ? message! : _message(raw);
  }

  // ── building ──

  /// Ctrl+F to search, F5 to load again (ADR-049 م٦, ADR-050 خ٤).
  @override
  Widget build(BuildContext context) => AppListShortcuts(
    searchFocus: _searchFocus,
    onRefresh: _load,
    child: _buildScreen(context),
  );

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.titleOverride ?? 'إدارة الخزائن'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_safe',
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('خزينة جديدة'),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading && _overview == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _overview == null) {
      return AppErrorView(
        title: 'تعذّر تحميل الخزائن',
        error: _error,
        onRetry: _load,
      );
    }

    final shown = _type == 'all'
        ? _types
        : _types.where(_shows).toList();
    final sections = [
      for (final t in shown)
        if (_rowsOf(t).isNotEmpty) t,
    ];

    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, c) {
          final columns = c.maxWidth >= 1100 ? 3 : (c.maxWidth >= 700 ? 2 : 1);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              if (_loading) const LinearProgressIndicator(),
              _summary(c.maxWidth),
              const SizedBox(height: 12),
              _searchField(),
              const SizedBox(height: 8),
              if (sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Column(
                    children: [
                      Icon(
                        Icons.search_off,
                        size: 40,
                        color: _scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _query.isEmpty
                            ? 'لا توجد خزائن بعد'
                            : 'لا توجد خزائن مطابقة',
                        style: TextStyle(color: _scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              for (final t in sections) ..._section(t, columns, c.maxWidth),
            ],
          );
        },
      ),
    );
  }

  /// A tile per type: its count and total -- the server's. A tap shows that type alone.
  Widget _summary(double width) {
    // Two a row on a phone; a fixed width where there is room.
    final tileWidth = width < 600 ? (width - 32 - 8) / 2 : 200.0;
    final totals = _overview?.totals ?? const <String, SafeTypeTotal>{};
    final count = totals.values.fold<int>(0, (n, t) => n + t.count);
    final canFilter = !widget.lockFilterType;
    Widget tile(
      String key,
      String label,
      IconData icon,
      SemanticTone tone,
      String value,
      String sub,
    ) {
      final selected = _type == key;
      return SizedBox(
        width: tileWidth,
        child: Card(
          key: Key('safes-tile-$key'),
          margin: EdgeInsets.zero,
          elevation: 0,
          color: selected ? tone.container : _scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? tone.fg : _scheme.outlineVariant,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: canFilter
                ? () => setState(
                    () => _type = selected && key != 'all' ? 'all' : key,
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 18, color: tone.fg),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: selected ? tone.onContainer : null,
                          ),
                        ),
                      ),
                      Text(
                        sub,
                        style: _text.bodySmall?.copyWith(
                          color: _scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      value,
                      style: _text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final mainKarat = (_overview?.mainKarat ?? context.read<SettingsProvider>().mainKarat).round();
    return Wrap(
      key: const Key('safes-summary'),
      spacing: 8,
      runSpacing: 8,
      children: [
        if (canFilter)
          tile(
            'all',
            'الكل',
            Icons.apps_rounded,
            _tones.sectionSlate,
            '$count',
            'خزينة',
          ),
        for (final t in _types)
          tile(
            t,
            safeGroupLabels[t] ?? t,
            _typeIcon(t),
            _typeTone(_tones, t),
            _totalText(t, totals[t]!),
            _isGoldGroup(t)
                ? 'عيار $mainKarat · ${totals[t]!.count}'
                : '${totals[t]!.count}',
          ),
      ],
    );
  }

  Widget _searchField() => TextField(
    controller: _search,
    focusNode: _searchFocus,
    onChanged: (v) => setState(() => _query = v),
    decoration: InputDecoration(
      hintText: 'ابحث باسم الخزينة أو الحساب أو رقمه',
      prefixIcon: const Icon(Icons.search),
      isDense: true,
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(
              tooltip: 'مسح',
              icon: const Icon(Icons.close),
              onPressed: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
    ),
  );

  List<Widget> _section(String type, int columns, double width) {
    final rows = _rowsOf(type);
    final total = _overview!.totals[type];
    final tone = _typeTone(_tones, type);
    final cardWidth = (width - 32 - 12.0 * (columns - 1)) / columns;
    return [
      Padding(
        key: Key('safes-section-$type'),
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Row(
          children: [
            Icon(_typeIcon(type), size: 18, color: tone.fg),
            const SizedBox(width: 6),
            Text(
              safeGroupLabels[type] ?? type,
              style: _text.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 6),
            Text(
              '(${rows.length})',
              style: TextStyle(color: _scheme.onSurfaceVariant),
            ),
            const Spacer(),
            if (total != null && _query.isEmpty)
              Text(
                _totalText(type, total),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final sb in rows) SizedBox(width: cardWidth, child: _card(sb)),
        ],
      ),
    ];
  }

  Widget _pill(String text, SemanticTone tone) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: tone.container,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: _text.labelSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: tone.onContainer,
      ),
    ),
  );

  Color _balanceColor(double v) => v < 0
      ? _scheme.error
      : (v.abs() < 0.0005 ? _scheme.onSurfaceVariant : _scheme.onSurface);

  SemanticTone _karatTone(String karat) => switch (karat) {
    '24k' => _tones.karat24,
    '22k' => _tones.karat22,
    '18k' => _tones.karat18,
    _ => _tones.karat21,
  };

  Widget _card(SafeBoxModel sb) {
    final gold = _isGold(sb);
    final balance = gold ? sb.goldMainKarat : sb.cashBalance;
    final tone = _typeTone(_tones, sb.safeType);
    final opened = _open.contains(sb.id);
    final karats = [
      MapEntry('24k', sb.goldBalance24k),
      MapEntry('22k', sb.goldBalance22k),
      MapEntry('21k', sb.goldBalance21k),
      MapEntry('18k', sb.goldBalance18k),
    ].where((e) => e.value.abs() > 0.0005).toList();
    final stones = _stones[sb.id]?['total'] ?? 0.0;

    return Opacity(
      opacity: sb.isActive ? 1 : 0.6,
      child: Card(
        key: Key('safe-card-${sb.id}'),
        margin: EdgeInsets.zero,
        elevation: 0,
        color: _scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: sb.id == null
              ? null
              : () => setState(
                  () => opened ? _open.remove(sb.id) : _open.add(sb.id!),
                ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_typeIcon(sb.safeType), size: 20, color: tone.fg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              sb.name.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _text.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: _scheme.onSurface,
                              ),
                            ),
                          ),
                          if (sb.isDefault) ...[
                            const SizedBox(width: 6),
                            _pill('افتراضية', _tones.gold),
                          ],
                          if (!sb.isActive) ...[
                            const SizedBox(width: 6),
                            _pill('موقوفة', _tones.blocked),
                          ],
                          if (_partySideLabels[sb.partySide] != null) ...[
                            const SizedBox(width: 6),
                            KeyedSubtree(
                              key: Key('safe-party-side-${sb.id}'),
                              child: _pill(
                                _partySideLabels[sb.partySide]!,
                                switch (sb.partySide) {
                                  'ours' => _tones.ready,
                                  'theirs' => _tones.warning,
                                  _ => _tones.silver,
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    _menu(sb),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  gold ? _weight(balance) : _amount(balance),
                  style: _text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: _balanceColor(balance),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (gold && karats.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final k in karats)
                        _pill(
                          'عيار ${ltrIsolate(k.key.replaceAll('k', ''))}: ${ltrIsolate(_grams.format(k.value))}',
                          k.value < 0 ? _tones.blocked : _karatTone(k.key),
                        ),
                    ],
                  ),
                ],
                // The gold is ours at execution; the office's riyals beside it,
                // as a bank shows a loan (ADR-052, the owner: option A).
                if ((sb.officeCash ?? 0).abs() >= 0.005) ...[
                  const SizedBox(height: 6),
                  KeyedSubtree(
                    key: Key('safe-office-cash-${sb.id}'),
                    child: _pill(
                      sb.officeCash! < 0
                          ? 'مستحق للمكتب: ${_amount(-sb.officeCash!)}'
                          : 'لنا عند المكتب: ${_amount(sb.officeCash!)}',
                      sb.officeCash! < 0 ? _tones.warning : _tones.info,
                    ),
                  ),
                ],
                if (gold && stones > 0.0005) ...[
                  const SizedBox(height: 4),
                  Text(
                    'فصوص: ${_weight(stones)}',
                    style: _text.bodySmall?.copyWith(
                      color: _scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (sb.pendingDocuments > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    _pendingText(sb, balance),
                    style: _text.bodySmall?.copyWith(color: _tones.warning.fg),
                  ),
                ],
                if (opened) ...[
                  const SizedBox(height: 6),
                  Divider(height: 1, color: _scheme.outlineVariant),
                  const SizedBox(height: 6),
                  if (sb.account != null)
                    Text(
                      'الحساب: ${ltrIsolate(sb.account!.accountNumber)} — ${sb.account!.name}',
                      style: _text.bodySmall?.copyWith(
                        color: _scheme.onSurfaceVariant,
                      ),
                    ),
                  if ((sb.bankName ?? '').trim().isNotEmpty)
                    Text(
                      'البنك: ${sb.bankName}',
                      style: _text.bodySmall?.copyWith(
                        color: _scheme.onSurfaceVariant,
                      ),
                    ),
                  if ((sb.iban ?? '').trim().isNotEmpty)
                    Text(
                      'الآيبان: ${ltrIsolate(sb.iban!)}',
                      style: _text.bodySmall?.copyWith(
                        color: _scheme.onSurfaceVariant,
                      ),
                    ),
                  if ((sb.notes ?? '').trim().isNotEmpty)
                    Text(
                      sb.notes!.trim(),
                      style: _text.bodySmall?.copyWith(
                        color: _scheme.onSurfaceVariant,
                      ),
                    ),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => _add(sb),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('إضافة'),
                    ),
                    TextButton.icon(
                      onPressed: () => _withdraw(sb),
                      icon: const Icon(Icons.remove, size: 18),
                      label: const Text('سحب'),
                    ),
                    TextButton.icon(
                      onPressed: () => _transfer(
                        sb,
                        fromId: sb.id,
                        note: 'تحويل من ${sb.name}',
                      ),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('تحويل'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Posted + pending = what should be in hand (services/safe_pending.py).
  String _pendingText(SafeBoxModel sb, double posted) {
    final docs = sb.pendingDocuments;
    if (_isGold(sb) && sb.pendingWeight.isNotEmpty) {
      final postedByKarat = {
        '24k': sb.goldBalance24k,
        '22k': sb.goldBalance22k,
        '21k': sb.goldBalance21k,
        '18k': sb.goldBalance18k,
      };
      final parts = sb.pendingWeight.entries
          .map((e) {
            final sign = e.value >= 0 ? '+' : '';
            final inHand = (postedByKarat[e.key] ?? 0.0) + e.value;
            return '${e.key}: ${ltrIsolate('$sign${_grams.format(e.value)}')} ← في اليد ${ltrIsolate(_grams.format(inHand))}';
          })
          .join(' • ');
      return 'معلّق بانتظار الاعتماد ($docs): $parts';
    }
    final sign = sb.pendingCash >= 0 ? '+' : '';
    return 'معلّق بانتظار الاعتماد ($docs): ${ltrIsolate(sign)}${_amount(sb.pendingCash)}'
        ' • المتوقع في اليد: ${_amount(posted + sb.pendingCash)}';
  }

  Widget _menu(SafeBoxModel sb) => PopupMenuButton<String>(
    tooltip: 'إجراءات الخزينة',
    icon: const Icon(Icons.more_vert),
    onSelected: (action) {
      switch (action) {
        case 'statement':
          _statement(sb);
        case 'edit':
          _edit(sb);
        case 'settlement':
          if (sb.id != null) {
            _push(ClearingSettlementScreen(initialClearingSafeBoxId: sb.id));
          }
        case 'delete':
          _delete(sb);
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: 'statement',
        child: ListTile(
          leading: Icon(Icons.receipt_long_outlined),
          title: Text('كشف حساب'),
        ),
      ),
      const PopupMenuItem(
        value: 'edit',
        child: ListTile(
          leading: Icon(Icons.edit_outlined),
          title: Text('تعديل'),
        ),
      ),
      if (sb.safeType == 'clearing')
        const PopupMenuItem(
          value: 'settlement',
          child: ListTile(
            leading: Icon(Icons.sync_alt),
            title: Text('تسوية التحصيل'),
          ),
        ),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(Icons.delete_outline, color: _scheme.error),
          title: Text('حذف', style: TextStyle(color: _scheme.error)),
        ),
      ),
    ],
  );
}

/// Add or edit a safe. Its account is searched as people write it, from the
/// active accounts -- a gold safe's from those that track weight (the server
/// refuses another). No karat: the server keeps gold safes multi-karat.
class _SafeBoxForm extends StatefulWidget {
  const _SafeBoxForm({
    required this.api,
    required this.type,
    required this.lockType,
    this.editing,
    this.place,
  });

  final ApiService api;
  final SafeBoxModel? editing;
  final String type;
  final bool lockType;

  /// A new gold safe's place, from the section it is made in.
  final String? place;

  @override
  State<_SafeBoxForm> createState() => _SafeBoxFormState();
}

class _SafeBoxFormState extends State<_SafeBoxForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _nameEn = TextEditingController(
    text: widget.editing?.nameEn ?? '',
  );
  late final _bank = TextEditingController(
    text: widget.editing?.bankName ?? '',
  );
  late final _iban = TextEditingController(text: widget.editing?.iban ?? '');
  late final _swift = TextEditingController(
    text: widget.editing?.swiftCode ?? '',
  );
  late final _branch = TextEditingController(
    text: widget.editing?.branch ?? '',
  );
  late final _notes = TextEditingController(text: widget.editing?.notes ?? '');
  late String _type = safeTypeLabels.containsKey(widget.type)
      ? widget.type
      : 'cash';
  late String? _place = widget.editing == null
      ? widget.place
      : (widget.editing!.stockLocation ?? 'party');
  late bool _active = widget.editing?.isActive ?? true;
  late bool _default = widget.editing?.isDefault ?? false;
  List<Map<String, dynamic>>? _accounts;
  Map<String, dynamic>? _account;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.api
        .getAccounts()
        .then((list) {
          if (!mounted) return;
          final accounts = list.whereType<Map<String, dynamic>>().toList();
          setState(() {
            _accounts = accounts;
            final id = widget.editing?.accountId;
            if (id != null) {
              _account = accounts.where((a) => a['id'] == id).firstOrNull;
            }
          });
        })
        .catchError((Object e) {
          if (mounted) {
            setState(() => _error = 'تعذّر تحميل الحسابات: ${_message(e)}');
          }
        });
  }

  @override
  void dispose() {
    for (final c in [_name, _nameEn, _bank, _iban, _swift, _branch, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _candidates => (_accounts ?? const [])
      .where((a) => a['is_active'] != false)
      .where((a) => _type != 'gold' || a['tracks_weight'] == true)
      .toList();

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_account == null) {
      setState(() => _error = 'اختر الحساب المرتبط');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final bank = _type == 'bank';
    final model = SafeBoxModel(
      id: widget.editing?.id,
      name: _name.text.trim(),
      nameEn: _text(_nameEn),
      safeType: _type,
      accountId: _account!['id'] as int,
      bankName: bank ? _text(_bank) : null,
      iban: bank ? _text(_iban) : null,
      swiftCode: bank ? _text(_swift) : null,
      branch: bank ? _text(_branch) : null,
      stockLocation: _place == 'party' ? null : _place,
      isActive: _active,
      isDefault: _default,
      notes: _text(_notes),
    );
    try {
      if (widget.editing == null) {
        await widget.api.createSafeBox(model);
      } else {
        await widget.api.updateSafeBox(widget.editing!.id!, model);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _message(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.editing != null;
    return AlertDialog(
      title: Text(editing ? 'تعديل الخزينة' : 'خزينة جديدة'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const Key('safe-form-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'الاسم'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'الاسم مطلوب' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nameEn,
                  decoration: const InputDecoration(
                    labelText: 'الاسم بالإنجليزية',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _type,
                  decoration: const InputDecoration(labelText: 'النوع'),
                  items: [
                    for (final e in _safeTypeSingular.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: widget.lockType
                      ? null
                      : (v) => setState(() {
                          _type = v ?? _type;
                          if (_type == 'gold' &&
                              _account?['tracks_weight'] != true) {
                            _account = null;
                          }
                        }),
                ),
                const SizedBox(height: 12),
                if (_accounts == null && _error == null)
                  const LinearProgressIndicator()
                else
                  AccountSearchField(
                    key: ValueKey('account-$_type'),
                    fieldKey: const Key('safe-form-account'),
                    accounts: _candidates,
                    selected: _account,
                    label: 'الحساب المرتبط',
                    hint: _type == 'gold'
                        ? 'حساب يتتبّع الوزن — ابحث برقمه أو اسمه'
                        : 'ابحث برقمه أو اسمه',
                    onChanged: (a) => setState(() => _account = a),
                  ),
                if (_type == 'gold') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('safe-form-place'),
                    value: _place,
                    decoration: const InputDecoration(
                      labelText: 'أين هذا الذهب؟',
                    ),
                    items: [
                      for (final e in stockPlaceLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    validator: (v) => v == null ? 'حدّد مكان الذهب' : null,
                    onChanged: (v) => setState(() => _place = v),
                  ),
                ],
                if (_type == 'bank') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bank,
                    decoration: const InputDecoration(labelText: 'اسم البنك'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _iban,
                    decoration: const InputDecoration(labelText: 'الآيبان'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _swift,
                    decoration: const InputDecoration(labelText: 'رمز السويفت'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _branch,
                    decoration: const InputDecoration(labelText: 'الفرع'),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'ملاحظات'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('نشطة'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('الافتراضية لنوعها'),
                  value: _default,
                  onChanged: (v) => setState(() => _default = v),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(editing ? 'حفظ' : 'إضافة'),
        ),
      ],
    );
  }
}
