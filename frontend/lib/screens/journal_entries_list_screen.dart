import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../app_route_observer.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/currency_utils.dart' as cu;
import '../widgets/cancelled_vouchers_bar.dart';
import '../widgets/widgets.dart';
import 'journal_entry_form.dart';

enum _JournalEntriesListView { table, cards }

enum _JournalEntryRowAction { preview, edit, post, unpost, print, delete }

class JournalEntriesListScreen extends StatefulWidget {
  final bool isArabic;

  const JournalEntriesListScreen({super.key, this.isArabic = true});

  @override
  State<JournalEntriesListScreen> createState() =>
      _JournalEntriesListScreenState();
}

class _JournalEntriesListScreenState extends State<JournalEntriesListScreen>
    with RouteAware {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _contentScrollController = ScrollController();
  final ScrollController _tableHorizontalController = ScrollController();
  final GlobalKey _toolbarKey = GlobalKey();
  double _toolbarHeight = 160;

  List<Map<String, dynamic>> _entries = const [];
  List<Map<String, dynamic>> _accounts = const [];
  List<String> _availableCreators = const [];
  List<String> _availableEntryTypes = const [];
  Map<String, dynamic> _currentSummary = const {};

  bool _isLoading = true;

  // Cancelled vouchers and their reversals: hidden by default (the owner,
  // 9 Oct 2026); the bar above the list shows them.
  bool _includeCancelled = false;
  int _cancelledCount = 0;
  bool _cancelledHidden = false;
  String? _error;

  int _currencyDecimalPlaces = 2;
  int _mainKarat = 21;

  int _currentPage = 1;
  int _totalPages = 1;
  int _totalEntries = 0;
  int _perPage = 25;

  String _searchType = 'all';
  String _status = 'all';
  String _entryType = 'all';
  String _sortBy = 'date';
  bool _sortAscending = false;
  String? _selectedCreator;
  int? _selectedAccountId;
  double? _minCash;
  double? _maxCash;
  DateTimeRange? _dateRange;

  _JournalEntriesListView _viewMode = _JournalEntriesListView.table;
  Timer? _searchDebounce;

  String get _currencySymbol =>
      context.read<SettingsProvider>().currencySymbolText;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
    _loadEntries();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.unsubscribe(this);
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
    _syncSettings();
  }

  @override
  void didPopNext() {
    _loadEntries(forceRefresh: true);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _contentScrollController.dispose();
    _tableHorizontalController.dispose();
    super.dispose();
  }

  void _syncSettings() {
    final settings = context.read<SettingsProvider>();
    final nextDecimals = settings.decimalPlaces;
    final nextMainKarat = settings.mainKarat;

    if (nextDecimals != _currencyDecimalPlaces || nextMainKarat != _mainKarat) {
      setState(() {
        _currencyDecimalPlaces = nextDecimals;
        _mainKarat = nextMainKarat;
      });
    }
  }

  Map<String, dynamic> _stringKeyMap(dynamic raw) {
    if (raw is! Map) {
      return <String, dynamic>{};
    }
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _loadEntries({int? page, bool forceRefresh = false}) async {
    if (!mounted) {
      return;
    }

    final targetPage = page ?? _currentPage;
    setState(() {
      _isLoading = true;
      if (forceRefresh) {
        _error = null;
      }
    });

    try {
      final futures = <Future<dynamic>>[
        _apiService.getJournalEntriesPage(
          page: targetPage,
          perPage: _perPage,
          sortBy: _sortBy,
          sortOrder: _sortAscending ? 'asc' : 'desc',
          search: _searchController.text.trim(),
          searchType: _searchType,
          status: _status,
          entryType: _entryType,
          accountId: _selectedAccountId,
          creator: _selectedCreator,
          dateFrom: _dateRange?.start,
          dateTo: _dateRange?.end,
          minCash: _minCash,
          maxCash: _maxCash,
          includeCancelled: _includeCancelled,
        ),
      ];

      final shouldLoadAccounts = _accounts.isEmpty || forceRefresh;
      if (shouldLoadAccounts) {
        futures.add(_apiService.getAccounts());
      }

      final results = await Future.wait(futures);
      final data = _stringKeyMap(results[0]);

      final entriesRaw = (data['journal_entries'] as List?) ?? const [];
      final creatorsRaw = (data['available_creators'] as List?) ?? const [];
      final typesRaw = (data['available_entry_types'] as List?) ?? const [];

      final nextEntries = entriesRaw
          .map(_stringKeyMap)
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
      final nextCreators =
          creatorsRaw
              .map(
                (entry) =>
                    _stringKeyMap(entry)['name']?.toString().trim() ?? '',
              )
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final nextEntryTypes =
          typesRaw
              .map(
                (entry) =>
                    _stringKeyMap(entry)['name']?.toString().trim() ?? '',
              )
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      List<Map<String, dynamic>> nextAccounts = _accounts;
      if (shouldLoadAccounts && results.length > 1) {
        final rawAccounts = (results[1] as List?) ?? const [];
        nextAccounts = rawAccounts
            .map(_stringKeyMap)
            .where((account) => account.isNotEmpty)
            .toList(growable: false);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _entries = nextEntries;
        _accounts = nextAccounts;
        _availableCreators = nextCreators;
        _availableEntryTypes = nextEntryTypes;
        _currentSummary = _stringKeyMap(data['current_summary']);
        final cancelled = _stringKeyMap(data['cancelled_hidden']);
        _cancelledCount = _asInt(cancelled['count']) ?? 0;
        _cancelledHidden = cancelled['hidden'] == true;
        _totalEntries = _asInt(data['total']) ?? nextEntries.length;
        _totalPages = math.max(1, _asInt(data['pages']) ?? 1);
        _currentPage = math.max(1, _asInt(data['current_page']) ?? targetPage);
        _perPage = _asInt(data['per_page']) ?? _perPage;
        _error = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
      _showSnackBar(
        widget.isArabic
            ? 'فشل تحميل قيود اليومية'
            : 'Failed to load journal entries',
        isError: true,
      );
    }
  }

  int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse('${value ?? ''}');
  }

  double _asDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse('${value ?? ''}') ?? 0.0;
  }

  String _formatDate(dynamic raw) {
    if (raw == null) {
      return '—';
    }
    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) {
      return raw.toString();
    }
    return DateFormat('dd/MM/yyyy').format(parsed);
  }

  String _formatDateTime(dynamic raw) {
    if (raw == null) {
      return '—';
    }
    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) {
      return raw.toString();
    }
    return DateFormat('dd/MM/yyyy HH:mm').format(parsed);
  }

  String _formatCash(dynamic raw) {
    final formatted = NumberFormat(
      '#,##0.${'0' * _currencyDecimalPlaces}',
      widget.isArabic ? 'ar' : 'en',
    ).format(_asDouble(raw));
    return '$formatted $_currencySymbol';
  }

  String _formatGold(dynamic raw) {
    final amount = _asDouble(raw);
    return '${NumberFormat('#,##0.###', widget.isArabic ? 'ar' : 'en').format(amount)} ${widget.isArabic ? 'غ' : 'g'}';
  }

  String _searchTypeLabel(String value) {
    switch (value) {
      case 'id':
        return widget.isArabic ? 'المعرف' : 'ID';
      case 'number':
        return widget.isArabic ? 'رقم القيد' : 'Entry No.';
      case 'description':
        return widget.isArabic ? 'الوصف' : 'Description';
      case 'reference':
        return widget.isArabic ? 'المرجع' : 'Reference';
      case 'creator':
        return widget.isArabic ? 'المنشئ' : 'Creator';
      case 'amount':
        return widget.isArabic ? 'النقد' : 'Cash';
      case 'gold':
        return widget.isArabic ? 'الذهب' : 'Gold';
      default:
        return widget.isArabic ? 'الكل' : 'All';
    }
  }

  String _searchHint() {
    switch (_searchType) {
      case 'id':
        return widget.isArabic ? 'معرف القيد...' : 'Entry ID...';
      case 'number':
        return widget.isArabic ? 'رقم القيد...' : 'Entry number...';
      case 'description':
        return widget.isArabic ? 'الوصف أو البيان...' : 'Description...';
      case 'reference':
        return widget.isArabic ? 'المرجع...' : 'Reference...';
      case 'creator':
        return widget.isArabic ? 'اسم المنشئ...' : 'Creator name...';
      case 'amount':
        return widget.isArabic ? 'المبلغ النقدي...' : 'Cash amount...';
      case 'gold':
        return widget.isArabic ? 'وزن الذهب...' : 'Gold amount...';
      default:
        return widget.isArabic
            ? 'ابحث برقم القيد أو الوصف أو المرجع'
            : 'Search by number, description, or reference';
    }
  }

  int get _activeFiltersCount {
    int count = 0;
    if (_searchController.text.trim().isNotEmpty) {
      count++;
    }
    if (_searchType != 'all') {
      count++;
    }
    if (_status != 'all') {
      count++;
    }
    if (_entryType != 'all') {
      count++;
    }
    if (_selectedCreator != null) {
      count++;
    }
    if (_selectedAccountId != null) {
      count++;
    }
    if (_dateRange != null) {
      count++;
    }
    if (_minCash != null || _maxCash != null) {
      count++;
    }
    if (_sortBy != 'date' || _sortAscending) {
      count++;
    }
    return count;
  }

  String _selectedAccountLabel() {
    if (_selectedAccountId == null) {
      return widget.isArabic ? 'الحساب' : 'Account';
    }

    for (final account in _accounts) {
      if (_asInt(account['id']) == _selectedAccountId) {
        return accountLabelOf(account);
      }
    }
    return widget.isArabic ? 'الحساب' : 'Account';
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPage = 1;
      });
      _loadEntries(page: 1);
    });
  }

  Future<void> _openAccountPicker() async {
    final selected = await showAccountPickerBottomSheet(
      context: context,
      accounts: _accounts,
      title: widget.isArabic ? 'اختيار الحساب' : 'Select Account',
      isArabic: widget.isArabic,
      selectedId: _selectedAccountId,
      showTracksWeightFilter: true,
      showLeafOnlyFilter: true,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedAccountId = _asInt(selected?['id']);
      _currentPage = 1;
    });
    await _loadEntries(page: 1);
  }

  Future<void> _showCashRangeSheet() async {
    final minController = TextEditingController(
      text: _minCash == null
          ? ''
          : _minCash!.toStringAsFixed(_currencyDecimalPlaces),
    );
    final maxController = TextEditingController(
      text: _maxCash == null
          ? ''
          : _maxCash!.toStringAsFixed(_currencyDecimalPlaces),
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isArabic ? 'نطاق القيمة النقدية' : 'Cash range',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: minController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: widget.isArabic ? 'من' : 'Min',
                        suffixText: _currencySymbol,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: maxController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: widget.isArabic ? 'إلى' : 'Max',
                        suffixText: _currencySymbol,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      setState(() {
                        _minCash = null;
                        _maxCash = null;
                        _currentPage = 1;
                      });
                      _loadEntries(page: 1);
                    },
                    child: Text(widget.isArabic ? 'مسح' : 'Clear'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      setState(() {
                        _minCash = double.tryParse(minController.text.trim());
                        _maxCash = double.tryParse(maxController.text.trim());
                        _currentPage = 1;
                      });
                      _loadEntries(page: 1);
                    },
                    child: Text(widget.isArabic ? 'تطبيق' : 'Apply'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    minController.dispose();
    maxController.dispose();
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: _dateRange,
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _dateRange = picked;
      _currentPage = 1;
    });
    await _loadEntries(page: 1);
  }

  Future<void> _clearFilters() async {
    _searchDebounce?.cancel();
    setState(() {
      _searchController.clear();
      _searchType = 'all';
      _status = 'all';
      _entryType = 'all';
      _sortBy = 'date';
      _sortAscending = false;
      _selectedCreator = null;
      _selectedAccountId = null;
      _dateRange = null;
      _minCash = null;
      _maxCash = null;
      _currentPage = 1;
    });
    await _loadEntries(page: 1);
  }

  Future<void> _changeSort(String sortBy) async {
    setState(() {
      if (_sortBy == sortBy) {
        _sortAscending = !_sortAscending;
      } else {
        _sortBy = sortBy;
        _sortAscending = false;
      }
      _currentPage = 1;
    });
    await _loadEntries(page: 1);
  }

  List<int> _buildPageNumbers() {
    if (_totalPages <= 7) {
      return List<int>.generate(_totalPages, (index) => index + 1);
    }

    final pages = <int>[1];
    final start = (_currentPage - 2).clamp(2, _totalPages - 1);
    final end = (_currentPage + 2).clamp(2, _totalPages - 1);

    if (start > 2) {
      pages.add(-1);
    }
    for (int page = start; page <= end; page++) {
      pages.add(page);
    }
    if (end < _totalPages - 1) {
      pages.add(-1);
    }
    pages.add(_totalPages);
    return pages;
  }

  Future<void> _openPreview(Map<String, dynamic> entry) async {
    // عرض شاشة تحميل مؤقتة
    var loaderVisible = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => loaderVisible = false);

    try {
      final id = entry['id'];
      final details = await _apiService.getJournalEntryById(id is int ? id : int.parse(id.toString()));
      if (!mounted) return;
      if (loaderVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        loaderVisible = false;
      }

      final merged = <String, dynamic>{...entry, ...details};

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _JournalEntryDetailSheet(
          entry: merged,
          isArabic: widget.isArabic,
          apiService: _apiService,
          onEdit: entry['is_posted'] != true ? () { Navigator.pop(ctx); _openEditor(entry); } : null,
          onPost: entry['is_posted'] != true ? () { Navigator.pop(ctx); _postEntry(entry); } : null,
          onDelete: entry['is_posted'] != true ? () { Navigator.pop(ctx); _deleteEntry(entry); } : null,
        ),
      );
    } catch (e) {
      if (loaderVisible && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) _showSnackBar(widget.isArabic ? 'فشل تحميل القيد: $e' : 'Failed to load entry: $e', isError: true);
    }
  }

  Future<void> _openEditor([Map<String, dynamic>? entry]) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AddEditJournalEntryScreen(entry: entry, isEditMode: entry != null),
      ),
    );
    if (result == true && mounted) {
      await _loadEntries(page: _currentPage, forceRefresh: true);
    }
  }

  Future<void> _postEntry(Map<String, dynamic> entry) async {
    final auth = context.read<AuthProvider>();
    final postedBy = auth.username.trim().isNotEmpty
        ? auth.username.trim()
        : auth.fullName.trim();

    if (postedBy.isEmpty) {
      _showSnackBar(
        widget.isArabic
            ? 'تعذر تحديد المستخدم الحالي'
            : 'Unable to resolve current user',
        isError: true,
      );
      return;
    }

    try {
      await _apiService.postJournalEntry(_asInt(entry['id']) ?? 0, postedBy);
      _showSnackBar(
        widget.isArabic ? 'تم ترحيل القيد' : 'Entry posted successfully',
      );
      await _loadEntries(page: _currentPage, forceRefresh: true);
    } catch (e) {
      _showSnackBar(
        widget.isArabic ? 'فشل ترحيل القيد' : 'Failed to post entry',
        isError: true,
      );
    }
  }

  Future<void> _unpostEntry(Map<String, dynamic> entry) async {
    final confirmed = await _confirmAction(
      title: widget.isArabic ? 'فك ترحيل القيد' : 'Unpost entry',
      message: widget.isArabic
          ? 'سيتم إزالة تأثير القيد من الأرصدة. هل تريد المتابعة؟'
          : 'This removes the entry impact from balances. Continue?',
    );
    if (!confirmed) {
      return;
    }

    try {
      await _apiService.unpostJournalEntry(_asInt(entry['id']) ?? 0);
      _showSnackBar(
        widget.isArabic ? 'تم فك ترحيل القيد' : 'Entry unposted successfully',
      );
      await _loadEntries(page: _currentPage, forceRefresh: true);
    } catch (e) {
      _showSnackBar(
        widget.isArabic ? 'فشل فك ترحيل القيد' : 'Failed to unpost entry',
        isError: true,
      );
    }
  }

  Future<void> _deleteEntry(Map<String, dynamic> entry) async {
    final reason = await _promptDeletionReason();
    if (reason == null || reason.trim().isEmpty) {
      return;
    }

    final confirmed = await _confirmAction(
      title: widget.isArabic ? 'حذف القيد' : 'Delete entry',
      message: widget.isArabic
          ? 'سيتم حذف القيد حذفًا ناعمًا ويمكن استرجاعه لاحقًا.'
          : 'The entry will be soft-deleted and can be restored later.',
    );
    if (!confirmed) {
      return;
    }

    try {
      await _apiService.deleteUnpostedJournalEntry(
        _asInt(entry['id']) ?? 0,
        reason: reason.trim(),
      );
      _showSnackBar(
        widget.isArabic ? 'تم حذف القيد' : 'Entry deleted successfully',
      );
      await _loadEntries(page: _currentPage, forceRefresh: true);
    } catch (e) {
      _showSnackBar(
        widget.isArabic ? 'فشل حذف القيد' : 'Failed to delete entry',
        isError: true,
      );
    }
  }

  Future<String?> _promptDeletionReason() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(widget.isArabic ? 'سبب الحذف' : 'Deletion reason'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: widget.isArabic
                  ? 'مثال: قيد أُدخل بالخطأ'
                  : 'Example: created by mistake',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: Text(widget.isArabic ? 'متابعة' : 'Continue'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(widget.isArabic ? 'تأكيد' : 'Confirm'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _handleRowAction(
    Map<String, dynamic> entry,
    _JournalEntryRowAction action,
  ) async {
    final isPosted = entry['is_posted'] == true;
    switch (action) {
      case _JournalEntryRowAction.preview:
      case _JournalEntryRowAction.print:
        await _openPreview(entry);
        break;
      case _JournalEntryRowAction.edit:
        if (!isPosted) {
          await _openEditor(entry);
        }
        break;
      case _JournalEntryRowAction.post:
        if (!isPosted) {
          await _postEntry(entry);
        }
        break;
      case _JournalEntryRowAction.unpost:
        if (isPosted) {
          await _unpostEntry(entry);
        }
        break;
      case _JournalEntryRowAction.delete:
        if (!isPosted) {
          await _deleteEntry(entry);
        }
        break;
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? theme.colorScheme.error
            : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool emphasize = false,
  }) {
    final theme = Theme.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < 700;

    final card = Container(
      padding: EdgeInsets.all(isCompact ? 10 : 14),
      decoration: BoxDecoration(
        gradient: emphasize
            ? LinearGradient(
                colors: [
                  color.withValues(alpha: 0.14),
                  theme.colorScheme.surface,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: emphasize ? null : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(isCompact ? 14 : 18),
        border: Border.all(
          color: color.withValues(alpha: emphasize ? 0.28 : 0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: isCompact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Container(
            width: isCompact ? 30 : 42,
            height: isCompact ? 30 : 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(isCompact ? 9 : 12),
            ),
            child: Icon(icon, color: color, size: isCompact ? 15 : 20),
          ),
          SizedBox(width: isCompact ? 8 : 10),
          isCompact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    context.read<SettingsProvider>().buildText(
                      value,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: emphasize
                            ? FontWeight.w900
                            : FontWeight.w800,
                        color: color,
                      ),
                    ),
                  ],
                )
              : Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      context.read<SettingsProvider>().buildText(
                        value,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: emphasize
                              ? FontWeight.w900
                              : FontWeight.w800,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.62,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ],
      ),
    );

    if (isCompact) {
      return SizedBox(width: 170, child: card);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 250),
      child: card,
    );
  }

  Widget _buildStatisticsSection() {
    final totalEntries =
        _asInt(_currentSummary['total_entries']) ?? _totalEntries;
    final postedCount =
        _asInt(_currentSummary['posted_count']) ??
        _entries.where((entry) => entry['is_posted'] == true).length;
    final unpostedCount =
        _asInt(_currentSummary['unposted_count']) ??
        _entries.where((entry) => entry['is_posted'] != true).length;
    final totalCash = _asDouble(_currentSummary['total_cash']);
    final totalGold = _asDouble(_currentSummary['total_gold_main_karat']);

    final cards = [
      _buildSummaryCard(
        title: widget.isArabic ? 'إجمالي القيود' : 'Entries',
        value: '$totalEntries',
        subtitle: widget.isArabic
            ? 'بعد الفلاتر الحالية'
            : 'After current filters',
        icon: Icons.receipt_long_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      _buildSummaryCard(
        title: widget.isArabic ? 'قيود مرحلة' : 'Posted',
        value: '$postedCount',
        subtitle: widget.isArabic ? 'مرتبطة بالأرصدة' : 'Affects balances',
        icon: Icons.verified_outlined,
        color: Colors.green,
      ),
      _buildSummaryCard(
        title: widget.isArabic ? 'قيود غير مرحلة' : 'Unposted',
        value: '$unpostedCount',
        subtitle: widget.isArabic ? 'جاهزة للمراجعة' : 'Ready for review',
        icon: Icons.pending_actions_outlined,
        color: Colors.orange,
      ),
      _buildSummaryCard(
        title: widget.isArabic ? 'إجمالي النقد' : 'Total cash',
        value: _formatCash(totalCash),
        subtitle: widget.isArabic
            ? 'على النتائج المطابقة'
            : 'Across matching results',
        icon: Icons.payments_outlined,
        color: Colors.blue,
      ),
      _buildSummaryCard(
        title: widget.isArabic ? 'إجمالي الذهب' : 'Total gold',
        value: _formatGold(totalGold),
        subtitle: widget.isArabic
            ? 'بالمكافئ على العيار الرئيسي $_mainKarat'
            : 'Main karat equivalent $_mainKarat',
        icon: Icons.scale_outlined,
        color: const Color(0xFFD4A017),
        emphasize: true,
      ),
    ];

    final isCompact = MediaQuery.sizeOf(context).width < 700;
    if (!isCompact) {
      return Wrap(spacing: 10, runSpacing: 10, children: cards);
    }

    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) => cards[index],
      ),
    );
  }

  void _measureToolbarHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _toolbarKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox) return;
      final measuredHeight = renderObject.size.height;
      if (measuredHeight <= 0) return;
      if ((measuredHeight - _toolbarHeight).abs() < 0.5) return;
      setState(() {
        _toolbarHeight = measuredHeight;
      });
    });
  }

  Widget _buildPinnedToolbarSliver() {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.28;
    _measureToolbarHeight();
    return AnimatedPinnedHeader(
      height: _toolbarHeight.clamp(0.0, maxHeight),
      backgroundColor: theme.scaffoldBackgroundColor,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: KeyedSubtree(
            key: _toolbarKey,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _buildManagementToolbar(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusChip({
    required String value,
    required String label,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final selected = _status == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      labelStyle: theme.textTheme.bodySmall?.copyWith(
        color: selected ? Colors.white : color,
        fontWeight: FontWeight.w700,
      ),
      selectedColor: color,
      backgroundColor: color.withValues(alpha: 0.08),
      side: BorderSide(color: color.withValues(alpha: 0.25)),
      onSelected: (_) async {
        setState(() {
          _status = value;
          _currentPage = 1;
        });
        await _loadEntries(page: 1);
      },
    );
  }

  Widget _buildManagementToolbar() {
    final theme = Theme.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < 700;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildFilterRow(
                  isCompact: isCompact,
                  children: [
                    _statusChip(
                      value: 'all',
                      label: widget.isArabic ? 'الكل' : 'All',
                      color: theme.colorScheme.primary,
                    ),
                    _statusChip(
                      value: 'posted',
                      label: widget.isArabic ? 'مرحلة' : 'Posted',
                      color: Colors.green,
                    ),
                    _statusChip(
                      value: 'unposted',
                      label: widget.isArabic ? 'غير مرحلة' : 'Unposted',
                      color: Colors.orange,
                    ),
                  ],
                ),
              ),
              if (_activeFiltersCount > 0)
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.close, size: 16),
                  label: Text(
                    widget.isArabic ? 'مسح الفلاتر' : 'Clear filters',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildFilterRow(
            isCompact: isCompact,
            children: [
              SizedBox(
                width: 430,
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => _scheduleSearch(),
                  onSubmitted: (_) {
                    _searchDebounce?.cancel();
                    setState(() {
                      _currentPage = 1;
                    });
                    _loadEntries(page: 1);
                  },
                  decoration: InputDecoration(
                    hintText: _searchHint(),
                    prefixIconConstraints: const BoxConstraints(minWidth: 164),
                    prefixIcon: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 8,
                        end: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.search, size: 18),
                          const SizedBox(width: 6),
                          PopupMenuButton<String>(
                            initialValue: _searchType,
                            tooltip: widget.isArabic
                                ? 'نوع البحث'
                                : 'Search type',
                            onSelected: (value) async {
                              setState(() {
                                _searchType = value;
                                _currentPage = 1;
                              });
                              await _loadEntries(page: 1);
                            },
                            itemBuilder: (context) => [
                              PopupMenuItem<String>(
                                value: 'all',
                                child: Text(widget.isArabic ? 'الكل' : 'All'),
                              ),
                              PopupMenuItem<String>(
                                value: 'id',
                                child: Text(widget.isArabic ? 'المعرف' : 'ID'),
                              ),
                              PopupMenuItem<String>(
                                value: 'number',
                                child: Text(
                                  widget.isArabic
                                      ? 'رقم القيد'
                                      : 'Entry number',
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'description',
                                child: Text(
                                  widget.isArabic ? 'الوصف' : 'Description',
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'reference',
                                child: Text(
                                  widget.isArabic ? 'المرجع' : 'Reference',
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'creator',
                                child: Text(
                                  widget.isArabic ? 'المنشئ' : 'Creator',
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'amount',
                                child: Text(widget.isArabic ? 'النقد' : 'Cash'),
                              ),
                              PopupMenuItem<String>(
                                value: 'gold',
                                child: Text(widget.isArabic ? 'الذهب' : 'Gold'),
                              ),
                            ],
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.outline.withValues(
                                    alpha: 0.16,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _searchTypeLabel(_searchType),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.arrow_drop_down, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    suffixIcon: _searchController.text.trim().isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _currentPage = 1;
                              });
                              _loadEntries(page: 1);
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String>(
                  value: _entryType,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'نوع القيد' : 'Entry type',
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: 'all',
                      child: Text(widget.isArabic ? 'الكل' : 'All'),
                    ),
                    ..._availableEntryTypes.map(
                      (type) => DropdownMenuItem<String>(
                        value: type,
                        child: Text(type, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _entryType = value;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<String?>(
                  value: _selectedCreator,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'المنشئ' : 'Creator',
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(widget.isArabic ? 'الكل' : 'All'),
                    ),
                    ..._availableCreators.map(
                      (creator) => DropdownMenuItem<String?>(
                        value: creator,
                        child: Text(creator, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: (value) async {
                    setState(() {
                      _selectedCreator = value;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: _openAccountPicker,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: Text(
                  _selectedAccountLabel(),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_selectedAccountId != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _selectedAccountId = null;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                  icon: const Icon(Icons.close, size: 16),
                  label: Text(widget.isArabic ? 'مسح الحساب' : 'Clear account'),
                ),
              OutlinedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.date_range_outlined, size: 18),
                label: Text(
                  _dateRange == null
                      ? (widget.isArabic ? 'من - إلى' : 'From - To')
                      : '${DateFormat('dd/MM/yyyy').format(_dateRange!.start)} - ${DateFormat('dd/MM/yyyy').format(_dateRange!.end)}',
                ),
              ),
              if (_dateRange != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _dateRange = null;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                  icon: const Icon(Icons.close, size: 16),
                  label: Text(widget.isArabic ? 'مسح التاريخ' : 'Clear date'),
                ),
              OutlinedButton.icon(
                onPressed: _showCashRangeSheet,
                icon: const Icon(Icons.tune, size: 18),
                label: Text(
                  _minCash == null && _maxCash == null
                      ? (widget.isArabic ? 'قيمة نقدية' : 'Cash range')
                      : '${_minCash?.toStringAsFixed(_currencyDecimalPlaces) ?? '0'} - ${_maxCash?.toStringAsFixed(_currencyDecimalPlaces) ?? '∞'}',
                ),
              ),
              SizedBox(
                width: 160,
                child: DropdownButtonFormField<String>(
                  value: _sortBy,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'الترتيب' : 'Sort by',
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: 'date',
                      child: Text(widget.isArabic ? 'التاريخ' : 'Date'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'number',
                      child: Text(widget.isArabic ? 'رقم القيد' : 'Entry no.'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'description',
                      child: Text(widget.isArabic ? 'الوصف' : 'Description'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'type',
                      child: Text(widget.isArabic ? 'نوع القيد' : 'Type'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'creator',
                      child: Text(widget.isArabic ? 'المنشئ' : 'Creator'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'cash',
                      child: Text(widget.isArabic ? 'النقد' : 'Cash'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'gold',
                      child: Text(widget.isArabic ? 'الذهب' : 'Gold'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'status',
                      child: Text(widget.isArabic ? 'الحالة' : 'Status'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'reference',
                      child: Text(widget.isArabic ? 'المرجع' : 'Reference'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'id',
                      child: Text(widget.isArabic ? 'المعرف' : 'ID'),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _sortBy = value;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  setState(() {
                    _sortAscending = !_sortAscending;
                    _currentPage = 1;
                  });
                  await _loadEntries(page: 1);
                },
                icon: Icon(
                  _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 18,
                ),
                label: Text(
                  _sortAscending
                      ? (widget.isArabic ? 'تصاعدي' : 'Ascending')
                      : (widget.isArabic ? 'تنازلي' : 'Descending'),
                ),
              ),
              SizedBox(
                width: 110,
                child: DropdownButtonFormField<int>(
                  value: _perPage,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: widget.isArabic ? 'الصفوف' : 'Rows',
                    isDense: true,
                  ),
                  items: const [10, 25, 50, 100]
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) async {
                    if (value == null || value == _perPage) {
                      return;
                    }
                    setState(() {
                      _perPage = value;
                      _currentPage = 1;
                    });
                    await _loadEntries(page: 1);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow({
    required bool isCompact,
    required List<Widget> children,
  }) {
    if (!isCompact) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            children[i],
          ],
        ],
      ),
    );
  }

  Widget _buildTypeBadge(String type) {
    final theme = Theme.of(context);
    Color color;
    switch (type) {
      case 'افتتاحي':
        color = Colors.blue;
        break;
      case 'دوري':
        color = Colors.purple;
        break;
      case 'إقفال':
        color = Colors.redAccent;
        break;
      case 'تسوية':
        color = Colors.teal;
        break;
      default:
        color = theme.colorScheme.primary;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        type,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildStatusBadge(bool isPosted) {
    final theme = Theme.of(context);
    final color = isPosted ? Colors.green : Colors.orange;
    final label = isPosted
        ? (widget.isArabic ? 'مرحّل' : 'Posted')
        : (widget.isArabic ? 'غير مرحّل' : 'Unposted');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPosted ? Icons.verified_outlined : Icons.pending_actions_outlined,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderCell({
    required String label,
    required double width,
    AlignmentGeometry alignment = Alignment.center,
    VoidCallback? onTap,
    bool isActive = false,
    TextAlign textAlign = TextAlign.center,
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.center,
  }) {
    final theme = Theme.of(context);
    final child = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: isActive ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 4),
            Icon(
              _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
              size: 14,
              color: theme.colorScheme.primary,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return child;
    }

    return InkWell(onTap: onTap, child: child);
  }

  Widget _buildMetricHeaderCell({
    required String label,
    required String unit,
    required double width,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool isActive = false,
  }) {
    final theme = Theme.of(context);
    final content = Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: isActive ? 0.34 : 0.18),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: isActive ? color : Colors.grey.shade800,
                      height: 1.0,
                    ),
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 13,
                    color: color,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              unit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color.withValues(alpha: 0.92),
                fontWeight: FontWeight.w700,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(onTap: onTap, child: content);
  }

  Widget _buildBodyCell({
    required double width,
    required Widget child,
    AlignmentGeometry alignment = Alignment.center,
  }) {
    return Container(
      width: width,
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: alignment,
      child: child,
    );
  }

  Widget _buildMetricValueCell({
    required double width,
    required String value,
    required IconData icon,
    required Color color,
    required bool emphasize,
  }) {
    return _buildBodyCell(
      width: width,
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasize ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: color.withValues(alpha: emphasize ? 0.26 : 0.14),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: context.read<SettingsProvider>().buildText(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
                  color: emphasize ? color.withValues(alpha: 0.98) : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRowActions(Map<String, dynamic> entry) {
    final isPosted = entry['is_posted'] == true;

    PopupMenuItem<_JournalEntryRowAction> item({
      required _JournalEntryRowAction value,
      required IconData icon,
      required String label,
      bool enabled = true,
    }) {
      return PopupMenuItem<_JournalEntryRowAction>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 10),
            Text(label),
          ],
        ),
      );
    }

    return PopupMenuButton<_JournalEntryRowAction>(
      tooltip: widget.isArabic ? 'الإجراءات' : 'Actions',
      onSelected: (action) => _handleRowAction(entry, action),
      itemBuilder: (context) => [
        item(
          value: _JournalEntryRowAction.preview,
          icon: Icons.visibility_outlined,
          label: widget.isArabic ? 'عرض' : 'Preview',
        ),
        item(
          value: _JournalEntryRowAction.edit,
          icon: Icons.edit_outlined,
          label: widget.isArabic ? 'تعديل' : 'Edit',
          enabled: !isPosted,
        ),
        item(
          value: _JournalEntryRowAction.post,
          icon: Icons.publish_outlined,
          label: widget.isArabic ? 'ترحيل' : 'Post',
          enabled: !isPosted,
        ),
        item(
          value: _JournalEntryRowAction.unpost,
          icon: Icons.undo_outlined,
          label: widget.isArabic ? 'فك الترحيل' : 'Unpost',
          enabled: isPosted,
        ),
        item(
          value: _JournalEntryRowAction.print,
          icon: Icons.print_outlined,
          label: widget.isArabic ? 'طباعة' : 'Print',
        ),
        item(
          value: _JournalEntryRowAction.delete,
          icon: Icons.delete_outline,
          label: widget.isArabic ? 'حذف' : 'Delete',
          enabled: !isPosted,
        ),
      ],
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.more_horiz, size: 18),
      ),
    );
  }

  Widget _buildJournalTable() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final viewportWidth = MediaQuery.sizeOf(context).width - 36;
    const baseColumnWidths = <String, double>{
      'number': 132,
      'description': 224,
      'creator': 104,
      'date': 104,
      'type': 96,
      'accounts': 188,
      'cash': 148,
      'gold': 148,
      'status': 112,
      'reference': 146,
      'actions': 52,
    };
    const widthDistribution = <String, double>{
      'description': 0.30,
      'creator': 0.10,
      'date': 0.02,
      'type': 0.08,
      'accounts': 0.20,
      'cash': 0.09,
      'gold': 0.09,
      'status': 0.04,
      'reference': 0.08,
    };
    final minContentWidth = baseColumnWidths.values.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    final tableWidth = math.max(viewportWidth, minContentWidth);
    final extraWidth = math.max(0.0, tableWidth - minContentWidth);

    final widths = <String, double>{
      for (final entry in baseColumnWidths.entries)
        entry.key:
            entry.value + (extraWidth * (widthDistribution[entry.key] ?? 0.0)),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 520.0;

        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.12),
            ),
          ),
          child: SingleChildScrollView(
            controller: _tableHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              height: tableHeight,
              child: Column(
                children: [
                  Container(
                    height: 66,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.45,
                      ),
                      border: Border(
                        bottom: BorderSide(
                          color: colorScheme.outline.withValues(alpha: 0.18),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        _buildHeaderCell(
                          label: widget.isArabic ? 'رقم القيد' : 'Entry no.',
                          width: widths['number']!,
                          onTap: () => _changeSort('number'),
                          isActive: _sortBy == 'number',
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'الوصف' : 'Description',
                          width: widths['description']!,
                          onTap: () => _changeSort('description'),
                          isActive: _sortBy == 'description',
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'المنشئ' : 'Creator',
                          width: widths['creator']!,
                          onTap: () => _changeSort('creator'),
                          isActive: _sortBy == 'creator',
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'التاريخ' : 'Date',
                          width: widths['date']!,
                          alignment: Alignment.center,
                          onTap: () => _changeSort('date'),
                          isActive: _sortBy == 'date',
                          textAlign: TextAlign.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'النوع' : 'Type',
                          width: widths['type']!,
                          alignment: Alignment.center,
                          onTap: () => _changeSort('type'),
                          isActive: _sortBy == 'type',
                          textAlign: TextAlign.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'الحسابات' : 'Accounts',
                          width: widths['accounts']!,
                        ),
                        _buildMetricHeaderCell(
                          label: widget.isArabic ? 'النقد' : 'Cash',
                          unit: _currencySymbol,
                          width: widths['cash']!,
                          icon: Icons.payments_outlined,
                          color: Colors.blue.shade700,
                          onTap: () => _changeSort('cash'),
                          isActive: _sortBy == 'cash',
                        ),
                        _buildMetricHeaderCell(
                          label: widget.isArabic ? 'وزن الذهب' : 'Gold weight',
                          unit: widget.isArabic
                              ? '${_mainKarat}k / غ'
                              : '${_mainKarat}k / g',
                          width: widths['gold']!,
                          icon: Icons.scale_outlined,
                          color: const Color(0xFFD4A017),
                          onTap: () => _changeSort('gold'),
                          isActive: _sortBy == 'gold',
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'الحالة' : 'Status',
                          width: widths['status']!,
                          alignment: Alignment.center,
                          onTap: () => _changeSort('status'),
                          isActive: _sortBy == 'status',
                          textAlign: TextAlign.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                        ),
                        _buildHeaderCell(
                          label: widget.isArabic ? 'المرجع' : 'Reference',
                          width: widths['reference']!,
                          onTap: () => _changeSort('reference'),
                          isActive: _sortBy == 'reference',
                        ),
                        _buildHeaderCell(
                          label: '⋮',
                          width: widths['actions']!,
                          alignment: Alignment.center,
                          textAlign: TextAlign.center,
                          mainAxisAlignment: MainAxisAlignment.center,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () =>
                          _loadEntries(page: _currentPage, forceRefresh: true),
                      child: ListView.builder(
                        primary: true,
                        padding: EdgeInsets.zero,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          final isPosted = entry['is_posted'] == true;
                          final accountsPreview =
                              ((entry['accounts_preview'] as List?) ?? const [])
                                  .map((account) => account.toString())
                                  .where((account) => account.trim().isNotEmpty)
                                  .join(' • ');
                          final lineCount = _asInt(entry['line_count']) ?? 0;
                          final creator = (entry['creator_name'] ?? '')
                              .toString()
                              .trim();
                          final reference = (entry['reference_display'] ?? '')
                              .toString()
                              .trim();
                          final description = (entry['description'] ?? '')
                              .toString()
                              .trim();

                          return Material(
                            color: index.isEven
                                ? colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.14)
                                : colorScheme.surface,
                            child: InkWell(
                              onTap: () => _openPreview(entry),
                              child: Container(
                                height: 68,
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: colorScheme.outline.withValues(
                                        alpha: 0.1,
                                      ),
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    _buildBodyCell(
                                      width: widths['number']!,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Text(
                                            (entry['entry_number'] ?? '—')
                                                .toString(),
                                            textAlign: TextAlign.center,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                  color: colorScheme.primary,
                                                ),
                                          ),
                                          Text(
                                            '#${_asInt(entry['id']) ?? 0}',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: colorScheme.onSurface
                                                      .withValues(alpha: 0.52),
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _buildBodyCell(
                                      width: widths['description']!,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Text(
                                            description.isEmpty
                                                ? (widget.isArabic
                                                      ? 'بدون وصف'
                                                      : 'No description')
                                                : description,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          Text(
                                            widget.isArabic
                                                ? '$lineCount أسطر'
                                                : '$lineCount lines',
                                            textAlign: TextAlign.center,
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: colorScheme.onSurface
                                                      .withValues(alpha: 0.52),
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _buildBodyCell(
                                      width: widths['creator']!,
                                      child: Text(
                                        creator.isEmpty ? '—' : creator,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                    _buildBodyCell(
                                      width: widths['date']!,
                                      alignment: Alignment.center,
                                      child: Text(_formatDate(entry['date'])),
                                    ),
                                    _buildBodyCell(
                                      width: widths['type']!,
                                      alignment: Alignment.center,
                                      child: _buildTypeBadge(
                                        (entry['entry_type'] ?? '')
                                                .toString()
                                                .trim()
                                                .isEmpty
                                            ? (widget.isArabic
                                                  ? 'عادي'
                                                  : 'Normal')
                                            : (entry['entry_type'] ?? '')
                                                  .toString(),
                                      ),
                                    ),
                                    _buildBodyCell(
                                      width: widths['accounts']!,
                                      child: Text(
                                        accountsPreview.isEmpty
                                            ? '—'
                                            : accountsPreview,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                    _buildMetricValueCell(
                                      width: widths['cash']!,
                                      value: _formatCash(entry['cash_total']),
                                      icon: Icons.payments_outlined,
                                      color: Colors.blue.shade700,
                                      emphasize: false,
                                    ),
                                    _buildMetricValueCell(
                                      width: widths['gold']!,
                                      value: _formatGold(
                                        entry['gold_total_main_karat'],
                                      ),
                                      icon: Icons.scale_outlined,
                                      color: const Color(0xFFD4A017),
                                      emphasize: true,
                                    ),
                                    _buildBodyCell(
                                      width: widths['status']!,
                                      alignment: Alignment.center,
                                      child: _buildStatusBadge(isPosted),
                                    ),
                                    _buildBodyCell(
                                      width: widths['reference']!,
                                      child: Text(
                                        reference.isEmpty ? '—' : reference,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                    _buildBodyCell(
                                      width: widths['actions']!,
                                      alignment: Alignment.center,
                                      child: _buildRowActions(entry),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEntryCard(Map<String, dynamic> entry) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accountsPreview = ((entry['accounts_preview'] as List?) ?? const [])
        .map((account) => account.toString())
        .where((account) => account.trim().isNotEmpty)
        .join(' • ');
    final isPosted = entry['is_posted'] == true;
    final description = (entry['description'] ?? '').toString().trim();
    final reference = (entry['reference_display'] ?? '').toString().trim();
    final creator = (entry['creator_name'] ?? '').toString().trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openPreview(entry),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (entry['entry_number'] ?? '—').toString(),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '#${_asInt(entry['id']) ?? 0} • ${_formatDateTime(entry['date'])}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.56,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildStatusBadge(isPosted),
                  const SizedBox(width: 8),
                  _buildRowActions(entry),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                description.isEmpty
                    ? (widget.isArabic ? 'بدون وصف' : 'No description')
                    : description,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTypeBadge(
                    (entry['entry_type'] ?? '').toString().trim().isEmpty
                        ? (widget.isArabic ? 'عادي' : 'Normal')
                        : (entry['entry_type'] ?? '').toString(),
                  ),
                  if (creator.isNotEmpty)
                    Chip(
                      label: Text(creator),
                      avatar: const Icon(Icons.person_outline, size: 16),
                    ),
                  if (reference.isNotEmpty)
                    Chip(
                      label: Text(reference),
                      avatar: const Icon(Icons.link_outlined, size: 16),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                accountsPreview.isEmpty
                    ? (widget.isArabic
                          ? 'لا توجد معاينة للحسابات'
                          : 'No account preview')
                    : accountsPreview,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildInfoTile(
                      icon: Icons.payments_outlined,
                      label: widget.isArabic ? 'النقد' : 'Cash',
                      value: _formatCash(entry['cash_total']),
                      accent: Colors.blue.shade700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildInfoTile(
                      icon: Icons.scale_outlined,
                      label: widget.isArabic ? 'وزن الذهب' : 'Gold weight',
                      value: _formatGold(entry['gold_total_main_karat']),
                      accent: const Color(0xFFD4A017),
                      emphasize: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
    Color? accent,
    bool emphasize = false,
  }) {
    final theme = Theme.of(context);
    final resolvedAccent = accent ?? theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: emphasize
            ? LinearGradient(
                colors: [
                  resolvedAccent.withValues(alpha: 0.14),
                  theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.22,
                  ),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: emphasize
            ? null
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: resolvedAccent.withValues(alpha: emphasize ? 0.22 : 0.10),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: emphasize ? 20 : 18, color: resolvedAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                context.read<SettingsProvider>().buildText(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: emphasize ? FontWeight.w900 : FontWeight.w800,
                    color: emphasize ? resolvedAccent : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationStrip() {
    if (_totalEntries == 0 || _totalPages <= 1) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final pageNumbers = _buildPageNumbers();
    final start = ((_currentPage - 1) * _perPage) + 1;
    final end = (_currentPage * _perPage) > _totalEntries
        ? _totalEntries
        : (_currentPage * _perPage);

    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text(
              widget.isArabic
                  ? 'عرض $start-$end من $_totalEntries'
                  : 'Showing $start-$end of $_totalEntries',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, size: 18),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: (_isLoading || _currentPage <= 1)
                    ? null
                    : () => _loadEntries(page: _currentPage - 1),
              ),
            ),
            ...pageNumbers.map((page) {
              if (page == -1) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    '…',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                );
              }

              final isActive = page == _currentPage;
              return GestureDetector(
                onTap: (_isLoading || isActive)
                    ? null
                    : () => _loadEntries(page: page),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 30,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isActive
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: isActive
                        ? null
                        : Border.all(
                            color: theme.colorScheme.outline.withValues(
                              alpha: 0.35,
                            ),
                          ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$page',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isActive
                          ? Colors.white
                          : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              );
            }),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                icon: const Icon(Icons.chevron_right, size: 18),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: (_isLoading || _currentPage >= _totalPages)
                    ? null
                    : () => _loadEntries(page: _currentPage + 1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            _activeFiltersCount > 0
                ? (widget.isArabic
                      ? 'لا توجد نتائج مطابقة'
                      : 'No matching entries')
                : (widget.isArabic
                      ? 'لا توجد قيود يومية'
                      : 'No journal entries'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isArabic
                ? 'أضف قيدًا جديدًا أو عدّل الفلاتر الحالية'
                : 'Add a new entry or adjust the current filters',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null && _entries.isEmpty && !_isLoading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.isArabic ? 'تعذر تحميل البيانات' : 'Unable to load data',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _loadEntries(forceRefresh: true),
                icon: const Icon(Icons.refresh),
                label: Text(widget.isArabic ? 'إعادة المحاولة' : 'Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_isLoading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.isEmpty) {
      return _buildEmptyState();
    }

    if (_viewMode == _JournalEntriesListView.table) {
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _buildJournalTable(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: _buildPaginationStrip(),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadEntries(page: _currentPage, forceRefresh: true),
      child: ListView(
        primary: true,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        children: [
          ..._entries.map(_buildEntryCard),
          const SizedBox(height: 8),
          _buildPaginationStrip(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    return Directionality(
      textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isArabic ? 'قيود اليومية' : 'Journal Entries'),
          actions: [
            IconButton(
              tooltip: _viewMode == _JournalEntriesListView.table
                  ? (widget.isArabic ? 'عرض البطاقات' : 'Card view')
                  : (widget.isArabic ? 'عرض الجدول' : 'Table view'),
              icon: Icon(
                _viewMode == _JournalEntriesListView.table
                    ? Icons.view_agenda_outlined
                    : Icons.table_rows_outlined,
              ),
              onPressed: () {
                setState(() {
                  _viewMode = _viewMode == _JournalEntriesListView.table
                      ? _JournalEntriesListView.cards
                      : _JournalEntriesListView.table;
                });
              },
            ),
            IconButton(
              tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  _loadEntries(page: _currentPage, forceRefresh: true),
            ),
            IconButton(
              tooltip: widget.isArabic ? 'إضافة قيد' : 'Add entry',
              icon: const Icon(Icons.add),
              onPressed: () => _openEditor(),
            ),
          ],
        ),
        body: NestedScrollView(
          controller: _contentScrollController,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _buildStatisticsSection(),
              ),
            ),
            if (_cancelledCount > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: CancelledVouchersBar(
                    count: _cancelledCount,
                    hidden: _cancelledHidden,
                    busy: _isLoading,
                    onToggle: () {
                      setState(() => _includeCancelled = !_includeCancelled);
                      _loadEntries(page: 1);
                    },
                  ),
                ),
              ),
            _buildPinnedToolbarSliver(),
          ],
          body: Column(
            children: [
              if (_isLoading && _entries.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Bottom Sheet - تفاصيل القيد اليومي
// ═══════════════════════════════════════════════════════════════════════════

class _JournalEntryDetailSheet extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool isArabic;
  final ApiService apiService;
  final VoidCallback? onEdit;
  final VoidCallback? onPost;
  final VoidCallback? onDelete;

  const _JournalEntryDetailSheet({
    required this.entry,
    required this.isArabic,
    required this.apiService,
    this.onEdit,
    this.onPost,
    this.onDelete,
  });

  static const Color _gold = Color(0xFFB8860B);
  static const Color _goldLight = Color(0xFFFFF8E1);

  double _toDouble(dynamic v) =>
      v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

  String _fmt(double v, {int decimals = 3}) => v.toStringAsFixed(decimals);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPosted = entry['is_posted'] == true;
    final entryNumber = entry['entry_number']?.toString() ?? '-';
    final date = _parseDate(entry['date']);
    final description = entry['description']?.toString() ?? '';
    final entryType = entry['entry_type']?.toString() ?? 'عادي';
    final createdBy = entry['created_by']?.toString() ?? '-';
    final lines = _parseLines();

    final totalCashDebit  = lines.fold(0.0, (s, l) => s + _cellVal(l, 'cash_debit'));
    final totalCashCredit = lines.fold(0.0, (s, l) => s + _cellVal(l, 'cash_credit'));
    final totalGoldDebit  = lines.fold(0.0, (s, l) => s + _cellVal(l, 'gold_debit'));
    final totalGoldCredit = lines.fold(0.0, (s, l) => s + _cellVal(l, 'gold_credit'));

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.97,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // ── مقبض السحب ──────────────────────────────────────────
              _buildHandle(),

              // ── رأس الـ Sheet ────────────────────────────────────────
              _buildHeader(context, entryNumber, date, isPosted, entryType, createdBy),

              // ── الوصف ────────────────────────────────────────────────
              if (description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      description,
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),

              // ── ملخص المبالغ ─────────────────────────────────────────
              _buildTotalsRow(context, totalCashDebit, totalCashCredit, totalGoldDebit, totalGoldCredit, lines),

              // ── جدول البنود ──────────────────────────────────────────
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: [
                    const SizedBox(height: 8),
                    _buildLinesHeader(context),
                    const Divider(height: 1),
                    ...lines.map((l) => _buildLineRow(context, l)),
                    const SizedBox(height: 16),
                    // معلومات إضافية
                    _buildMetaBox(context),
                  ],
                ),
              ),

              // ── أزرار الإجراءات ──────────────────────────────────────
              _buildActions(context, isPosted),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey[300],
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );

  Widget _buildHeader(BuildContext context, String number, String date,
      bool isPosted, String type, String creator) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_gold, const Color(0xFFA07010)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.receipt_long, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${ isArabic ? "قيد يومي" : "Journal Entry"} $number',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _chip(date, Icons.calendar_today, Colors.white70),
                    const SizedBox(width: 8),
                    _chip(type, Icons.label_outline, Colors.white70),
                    const SizedBox(width: 8),
                    _chip(creator, Icons.person_outline, Colors.white70),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isPosted ? Colors.green[700] : Colors.orange[700],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isArabic
                  ? (isPosted ? 'مرحَّل' : 'غير مرحَّل')
                  : (isPosted ? 'Posted' : 'Unposted'),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, IconData icon, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 11, color: color)),
    ],
  );

  Widget _buildTotalsRow(BuildContext context, double cashDebit, double cashCredit, double goldDebit, double goldCredit, List<Map<String, dynamic>> lines) {

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _goldLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6C800).withOpacity(0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _totalCard(context, isArabic ? 'مدين نقد' : 'Cash Debit', _fmt(cashDebit, decimals: 2),
              context.read<SettingsProvider>().currencySymbolText, Colors.green[700]!),
          Container(width: 1, height: 40, color: Colors.grey[300]),
          _totalCard(context, isArabic ? 'دائن نقد' : 'Cash Credit', _fmt(cashCredit, decimals: 2),
              context.read<SettingsProvider>().currencySymbolText, Colors.red[700]!),
          Container(width: 1, height: 40, color: Colors.grey[300]),
          _totalCard(context, isArabic ? 'مدين ذهب' : 'Gold Debit', _fmt(goldDebit),
              isArabic ? 'جم' : 'g', _gold),
          Container(width: 1, height: 40, color: Colors.grey[300]),
          _totalCard(context, isArabic ? 'دائن ذهب' : 'Gold Credit', _fmt(goldCredit),
              isArabic ? 'جم' : 'g', Colors.orange[700]!),
        ],
      ),
    );
  }

  Widget _totalCard(BuildContext context, String label, String value, String unit, Color color) {
    final isNewSar = context.read<SettingsProvider>().currencyIsNewSar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        const SizedBox(height: 2),
        RichText(text: TextSpan(
          children: [
            TextSpan(text: value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
            const TextSpan(text: ' '),
            if (isNewSar)
              cu.SarSymbolSpan(fontSize: 11, color: Colors.grey[600]!)
            else
              TextSpan(text: unit, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        )),
      ],
    );
  }

  Widget _buildLinesHeader(BuildContext context) {
    final style = TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey[700]);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Expanded(flex: 3, child: Text(isArabic ? 'الحساب' : 'Account', style: style)),
            SizedBox(width: 80, child: Text(isArabic ? 'مدين نقد' : 'Dr Cash', style: style, textAlign: TextAlign.center)),
            SizedBox(width: 80, child: Text(isArabic ? 'دائن نقد' : 'Cr Cash', style: style, textAlign: TextAlign.center)),
            SizedBox(width: 90, child: Text(isArabic ? 'مدين ذهب' : 'Dr Gold', style: style, textAlign: TextAlign.center)),
            SizedBox(width: 90, child: Text(isArabic ? 'دائن ذهب' : 'Cr Gold', style: style, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }

  Widget _buildLineRow(BuildContext context, Map<String, dynamic> line) {
    final accountName = line['account_name']?.toString() ??
        line['account']?.toString() ?? '-';
    final accountNumber = line['account_number']?.toString() ?? '';
    final desc = line['description']?.toString() ?? '';
    final drCash = _cellVal(line, 'cash_debit');
    final crCash = _cellVal(line, 'cash_credit');
    final drGoldStr = _goldKaratStr(line, 'debit');
    final crGoldStr = _goldKaratStr(line, 'credit');

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    accountNumber.isNotEmpty ? '$accountNumber - $accountName' : accountName,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (desc.isNotEmpty)
                    Text(desc, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                ],
              ),
            ),
            _amountCell(drCash > 0 ? _fmt(drCash, decimals: 2) : '-', Colors.green[700]!, 80),
            _amountCell(crCash > 0 ? _fmt(crCash, decimals: 2) : '-', Colors.red[700]!, 80),
            _amountCell(drGoldStr.isNotEmpty ? drGoldStr : '-', Colors.amber[800]!, 90),
            _amountCell(crGoldStr.isNotEmpty ? crGoldStr : '-', Colors.orange[800]!, 90),
          ],
        ),
      ),
    );
  }

  Widget _amountCell(String text, Color color, double width) => SizedBox(
    width: width,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        color: text == '-' ? Colors.grey[400] : color,
        fontWeight: text == '-' ? FontWeight.normal : FontWeight.bold,
      ),
    ),
  );

  Widget _buildMetaBox(BuildContext context) {
    final refType = entry['reference_type']?.toString() ?? '';
    final refNumber = entry['reference_number']?.toString() ?? '';
    final notes = entry['notes']?.toString() ?? '';
    if (refType.isEmpty && refNumber.isEmpty && notes.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue[100]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (refType.isNotEmpty || refNumber.isNotEmpty) ...[
            Row(children: [
              const Icon(Icons.link, size: 14, color: Colors.blueGrey),
              const SizedBox(width: 4),
              Text(
                '${isArabic ? "مرجع" : "Ref"}: $refType ${refNumber.isNotEmpty ? "($refNumber)" : ""}'.trim(),
                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ]),
          ],
          if (notes.isNotEmpty) ...[
            if (refType.isNotEmpty) const SizedBox(height: 4),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.note_outlined, size: 14, color: Colors.blueGrey),
              const SizedBox(width: 4),
              Expanded(child: Text(notes, style: const TextStyle(fontSize: 12, color: Colors.blueGrey))),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, bool isPosted) {
    if (onEdit == null && onPost == null && onDelete == null) {
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 12, top: 8, left: 16, right: 16),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            label: Text(isArabic ? 'إغلاق' : 'Close'),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 12,
        top: 8, left: 16, right: 16,
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
              label: Text(isArabic ? 'إغلاق' : 'Close'),
            ),
          ),
          if (onEdit != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
                label: Text(isArabic ? 'تعديل' : 'Edit'),
              ),
            ),
          ],
          if (onPost != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: onPost,
                style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                icon: const Icon(Icons.check_circle_outline),
                label: Text(isArabic ? 'ترحيل' : 'Post'),
              ),
            ),
          ],
          if (onDelete != null) ...[
            const SizedBox(width: 8),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              color: Colors.red[700],
              tooltip: isArabic ? 'حذف' : 'Delete',
            ),
          ],
        ],
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _parseLines() {
    final linesRaw = entry['lines'];
    if (linesRaw == null) return [];
    if (linesRaw is List) {
      return linesRaw.map((l) => l is Map<String, dynamic> ? l : Map<String, dynamic>.from(l as Map)).toList();
    }
    return [];
  }

  double _cellVal(Map<String, dynamic> line, String key) {
    // بنية ال API: cash_debit / cash_credit / debit_18k / debit_21k / debit_22k / debit_24k
    switch (key) {
      case 'cash_debit':  return _toDouble(line['cash_debit']);
      case 'cash_credit': return _toDouble(line['cash_credit']);
      case 'gold_debit':
        return _toDouble(line['debit_18k']) + _toDouble(line['debit_21k'])
             + _toDouble(line['debit_22k']) + _toDouble(line['debit_24k']);
      case 'gold_credit':
        return _toDouble(line['credit_18k']) + _toDouble(line['credit_21k'])
             + _toDouble(line['credit_22k']) + _toDouble(line['credit_24k']);
    }
    // fallback: amount_type / line_type pattern
    final lineType   = line['line_type']?.toString() ?? '';
    final amountType = line['amount_type']?.toString() ?? 'cash';
    final amount     = _toDouble(line['amount'] ?? 0);
    if (key == 'cash_debit'  && lineType == 'debit'  && amountType == 'cash')  return amount;
    if (key == 'cash_credit' && lineType == 'credit' && amountType == 'cash')  return amount;
    if (key == 'gold_debit'  && lineType == 'debit'  && amountType == 'gold')  return amount;
    if (key == 'gold_credit' && lineType == 'credit' && amountType == 'gold')  return amount;
    return 0.0;
  }

  /// يُرجع نص العيار الدائن/المدين بشكل "خا0k: X جم"
  String _goldKaratStr(Map<String, dynamic> line, String prefix) {
    final parts = <String>[];
    for (final k in [18, 21, 22, 24]) {
      final v = _toDouble(line['${prefix}_${k}k']);
      if (v > 0.0001) parts.add('عيار $k: ${_fmt(v)}');
    }
    return parts.join('  ');
  }

  String _parseDate(dynamic raw) {
    if (raw == null) return '-';
    final s = raw.toString();
    try {
      final dt = DateTime.parse(s);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return s;
    }
  }
}
