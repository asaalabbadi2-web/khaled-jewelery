import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'add_office_screen.dart';
import 'gold_reservation_screen.dart';
import 'gold_reservations_list_screen.dart';
import 'office_detail_screen.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import '../utils/party_balance.dart';
import '../widgets/app_feedback.dart';

/// شاشة قائمة مكاتب التسكير (تسكير الذهب)
class OfficesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const OfficesScreen({super.key, required this.api, this.isArabic = true});

  @override
  State<OfficesScreen> createState() => _OfficesScreenState();
}

class _OfficesScreenState extends State<OfficesScreen> {
  List<dynamic> _offices = [];
  List<dynamic> _filteredOffices = [];
  bool _isLoading = false;
  bool _showActiveOnly = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  double _asDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  /// What is between us and the office, as on the safes' deposit card
  /// (ADR-052): below zero owed to it, above ours with it -- its riyals and
  /// its gold in the same words.
  String _sideText(double amount, String number, String unit, bool isAr, {double least = 0.005}) {
    final value = '${ltrIsolate(number)} $unit';
    if (amount < -least) return isAr ? 'مستحق للمكتب $value' : 'Owed $value';
    if (amount > least) return isAr ? 'لنا عند المكتب $value' : 'Ours $value';
    return isAr ? 'مسوّى' : 'Settled';
  }

  /// The main karat, the settings' -- never a fixed one (the owner, 20 Oct 2026).
  int get _mainKarat => context.read<SettingsProvider>().mainKarat;

  Future<void> _newReservation(Map<String, dynamic> office) async {
    final officeId = office['id'] is int ? office['id'] as int : int.tryParse('${office['id']}');
    final saved = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GoldReservationScreen(
          api: widget.api,
          isArabic: widget.isArabic,
          initialOfficeId: officeId,
        ),
      ),
    );
    if (saved != null && mounted) {
      await _loadOffices();
      if (mounted) _openOffice(office);
    }
  }

  /// One office's page: its balances, its reservations, their next steps.
  Future<void> _openOffice(Map<String, dynamic> office) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OfficeDetailScreen(
          api: widget.api,
          office: office,
          isArabic: widget.isArabic,
        ),
      ),
    );
    if (mounted) await _loadOffices();
  }

  /// The office's gold on its supplier account, all karats in the main one.
  double _goldMainEquivalentFromOffice(Map<String, dynamic> office) => goldInMainKarat({
    for (final k in const [18, 21, 22, 24]) k: _asDouble(office['balance_gold_${k}k']),
  }, _mainKarat);

  @override
  void initState() {
    super.initState();
    _loadOffices();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadOffices() async {
    setState(() => _isLoading = true);
    try {
      final offices = await widget.api.getOffices(
        activeOnly: _showActiveOnly ? true : null,
      );
      if (!mounted) return;
      setState(() {
        _offices = offices;
        _applyFilters();
      });
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر تحميل المكاتب');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilters() {
    setState(() {
      _filteredOffices = _offices.where((office) {
        if (_searchQuery.isEmpty) return true;

        final name = (office['name'] ?? '').toString().toLowerCase();
        final code = (office['office_code'] ?? '').toString().toLowerCase();
        final phone = (office['phone'] ?? '').toString().toLowerCase();
        final contact = (office['contact_person'] ?? '')
            .toString()
            .toLowerCase();
        final query = _searchQuery.toLowerCase();

        return name.contains(query) ||
            code.contains(query) ||
            phone.contains(query) ||
            contact.contains(query);
      }).toList();
    });
  }

  void _showMessage(String message, {required bool isError}) {
    if (isError) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  Future<void> _navigateToAddOffice() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AddOfficeScreen(api: widget.api, isArabic: widget.isArabic),
      ),
    );

    if (result == true) {
      _loadOffices();
    }
  }

  Future<void> _navigateToEditOffice(Map<String, dynamic> office) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddOfficeScreen(
          api: widget.api,
          isArabic: widget.isArabic,
          office: office,
        ),
      ),
    );

    if (result == true) {
      _loadOffices();
    }
  }

  /// Stopping asks first; the server stops only a settled office (the owner,
  /// 20 Oct 2026) and says why it will not.
  Future<void> _toggleOfficeStatus(Map<String, dynamic> office) async {
    final isActive = office['active'] ?? true;
    if (isActive) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('تعطيل «${office['name'] ?? ''}»؟'),
          content: const Text(
            'يُعطَّل المكتب إن لم يبقَ بيننا وبينه شيء: لا ذهب لنا في وديعته، '
            'ولا رصيد نقدي أو ذهبي، ولا حجز لم يُنفَّذ.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
            FilledButton(
              key: const Key('office-stop-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تعطيل'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    try {
      if (isActive) {
        await widget.api.deleteOffice(office['id']);
        _showMessage('تم تعطيل المكتب', isError: false);
      } else {
        await widget.api.activateOffice(office['id']);
        _showMessage('تم تفعيل المكتب', isError: false);
      }
      _loadOffices();
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: isActive ? 'لم يُعطَّل المكتب' : 'لم يُفعَّل المكتب');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'المكاتب' : 'Offices'),
        actions: [
          TextButton.icon(
            key: const Key('offices-all-reservations'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GoldReservationsListScreen(api: widget.api, isArabic: isAr),
              ),
            ),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onPrimary),
            icon: const Icon(Icons.list_alt),
            label: Text(isAr ? 'كل الحجوزات' : 'All reservations'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOffices,
            tooltip: isAr ? 'تحديث' : 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadOffices,
        child: LayoutBuilder(
          builder: (context, box) {
            // Two to a row where there is room; one on a phone.
            final columns = box.maxWidth >= 900 ? 2 : 1;
            final width = (box.maxWidth - 32 - (columns - 1) * AppSpace.md) / columns;
            return ListView(
              // Room under the last card for «إضافة مكتب», which covered its «تعديل».
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _buildSearchAndFilter(isAr),
                const SizedBox(height: AppSpace.md),
                if (!_isLoading && _filteredOffices.isNotEmpty) ...[
                  _buildSummary(isAr),
                  const SizedBox(height: AppSpace.md),
                ],
                if (_isLoading)
                  const Padding(
                    padding: EdgeInsets.all(AppSpace.xl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_filteredOffices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.xl),
                    child: Center(
                      child: Text(
                        isAr ? 'لا توجد مكاتب' : 'No offices found',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  )
                else
                  Wrap(
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.md,
                    children: [
                      for (final office in _filteredOffices)
                        SizedBox(width: width, child: _buildOfficeCard(office)),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToAddOffice,
        icon: const Icon(Icons.add),
        label: Text(isAr ? 'إضافة مكتب' : 'Add Office'),
      ),
    );
  }

  /// The search, and whether the stopped offices are shown: two chips in
  /// place of an eye and «العدد / نشط» (the owner, 20 Oct 2026).
  Widget _buildSearchAndFilter(bool isAr) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: isAr ? 'ابحث بالاسم أو الرمز أو الهاتف' : 'Search by name, code, phone',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                        _applyFilters();
                      },
                    )
                  : null,
            ),
            onChanged: (value) {
              setState(() => _searchQuery = value);
              _applyFilters();
            },
          ),
        ),
        ChoiceChip(
          key: const Key('offices-filter-active'),
          label: Text(isAr ? 'النشطة' : 'Active'),
          selected: _showActiveOnly,
          onSelected: (_) {
            if (_showActiveOnly) return;
            setState(() => _showActiveOnly = true);
            _loadOffices();
          },
        ),
        ChoiceChip(
          key: const Key('offices-filter-all'),
          label: Text(isAr ? 'الكل' : 'All'),
          selected: !_showActiveOnly,
          onSelected: (_) {
            if (!_showActiveOnly) return;
            setState(() => _showActiveOnly = false);
            _loadOffices();
          },
        ),
      ],
    );
  }

  /// The offices summed: our gold in their deposits, what is owed either
  /// way in riyals, the reservations waiting -- the list's own numbers.
  Widget _buildSummary(bool isAr) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    var deposits = 0.0, owed = 0.0, ours = 0.0;
    var waiting = 0;
    for (final o in _filteredOffices) {
      final office = Map<String, dynamic>.from(o as Map);
      if (office['deposit'] is Map) {
        deposits += _asDouble((office['deposit'] as Map)['main_karat_total']);
      }
      final cash = _asDouble(office['balance_cash']);
      if (cash < 0) owed += -cash;
      if (cash > 0) ours += cash;
      if (office['open_reservations'] is Map) {
        waiting += ((office['open_reservations'] as Map)['count'] as num? ?? 0).toInt();
      }
    }
    Widget stat(String label, String value, SemanticTone tone) => Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelMedium?.copyWith(color: tone.onContainer)),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: tone.onContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
    return Wrap(
      key: const Key('offices-summary'),
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        stat(
          isAr ? 'ذهبنا في الودائع' : 'Our gold deposited',
          '${ltrIsolate(formatGrams(deposits))} ${isAr ? 'جم بالعيار $_mainKarat' : 'g of ${_mainKarat}k'}',
          tones.gold,
        ),
        stat(
          isAr ? 'مستحق للمكاتب' : 'Owed to offices',
          '${ltrIsolate(formatAmount(owed))} $currency',
          owed > 0.005 ? tones.warning : tones.ready,
        ),
        if (ours > 0.005)
          stat(
            isAr ? 'لنا عند المكاتب' : 'Ours with offices',
            '${ltrIsolate(formatAmount(ours))} $currency',
            tones.ready,
          ),
        stat(
          isAr ? 'حجوزات مفتوحة' : 'Open reservations',
          ltrIsolate('$waiting'),
          tones.info,
        ),
      ],
    );
  }

  /// One office, compact (the owner, 20 Oct 2026: «حجم بطاقة المكتب كبير»):
  /// its name; what is between us in one line, nothing said that is nothing;
  /// its next steps.
  Widget _buildOfficeCard(dynamic raw) {
    final office = Map<String, dynamic>.from(raw as Map);
    final isAr = widget.isArabic;
    final currencySymbol = context.read<SettingsProvider>().currencySymbolText;
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final isActive = office['active'] ?? true;
    final id = office['id'];

    final cashBalance = _asDouble(office['balance_cash']);
    final goldTotal = _goldMainEquivalentFromOffice(office);
    // Our gold held there (ADR-052) -- the supplier balances beside it are the trade.
    final deposit = office['deposit'] is Map ? office['deposit'] as Map : null;
    final depositGrams = _asDouble(deposit?['main_karat_total']);
    final openCount = office['open_reservations'] is Map
        ? ((office['open_reservations'] as Map)['count'] as num? ?? 0).toInt()
        : 0;

    Widget fact(Key key, String text, SemanticTone tone) => Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: tone.onContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    final facts = <Widget>[
      if (depositGrams.abs() >= 0.0005)
        fact(
          Key('office-deposit-$id'),
          '${isAr ? 'وديعة' : 'Deposit'} ${ltrIsolate(formatGrams(depositGrams))} ${isAr ? 'جم' : 'g'}',
          tones.gold,
        ),
      if (cashBalance.abs() >= 0.005)
        fact(
          Key('office-cash-$id'),
          _sideText(cashBalance, formatAmount(cashBalance.abs()), currencySymbol, isAr),
          cashBalance < 0 ? tones.warning : tones.ready,
        ),
      if (goldTotal.abs() >= 0.0005)
        fact(
          Key('office-gold-$id'),
          _sideText(
            goldTotal,
            formatGrams(goldTotal.abs()),
            isAr ? 'جم بالعيار $_mainKarat' : 'g of ${_mainKarat}k',
            isAr,
            least: 0.0005,
          ),
          tones.info,
        ),
    ];

    return Card(
      key: Key('office-card-$id'),
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openOffice(office),
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${office['name'] ?? ''}',
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text: '  ${office['office_code'] ?? ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Only a stopped one is marked: the list is of the active.
                  if (!isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
                      decoration: BoxDecoration(
                        color: tones.blocked.container,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                      child: Text(
                        isAr ? 'معطّل' : 'Inactive',
                        style: theme.textTheme.labelMedium?.copyWith(color: tones.blocked.onContainer),
                      ),
                    ),
                ],
              ),
              ),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: facts.isEmpty
                    ? [
                        Text(
                          isAr ? 'لا شيء بيننا' : 'Nothing between us',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ]
                    : facts,
              ),
              const SizedBox(height: AppSpace.sm),
              // The next steps in sight, wrapping on a phone.
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: Key('office-new-reservation-$id'),
                    onPressed: isActive ? () => _newReservation(office) : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(isAr ? 'حجز جديد' : 'New reservation'),
                  ),
                  OutlinedButton.icon(
                    key: Key('office-reservations-$id'),
                    onPressed: () => _openOffice(office),
                    icon: const Icon(Icons.lock_clock, size: 18),
                    label: Text(
                      openCount > 0
                          ? (isAr
                                ? 'الحجوزات · ${ltrIsolate('$openCount')} مفتوحة'
                                : 'Reservations · $openCount open')
                          : (isAr ? 'الحجوزات' : 'Reservations'),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: Key('office-more-$id'),
                    tooltip: isAr ? 'المزيد' : 'More',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (choice) => choice == 'edit'
                        ? _navigateToEditOffice(office)
                        : _toggleOfficeStatus(office),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit),
                          title: Text(isAr ? 'تعديل' : 'Edit'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'status',
                        child: ListTile(
                          leading: Icon(isActive ? Icons.block : Icons.check_circle),
                          title: Text(
                            isActive ? (isAr ? 'تعطيل' : 'Deactivate') : (isAr ? 'تفعيل' : 'Activate'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
