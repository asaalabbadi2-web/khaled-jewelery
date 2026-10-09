import 'package:flutter/material.dart';
import '../providers/settings_provider.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import '../theme/app_theme.dart' as theme;
import 'audit_log_screen.dart';
import '../providers/auth_provider.dart';
import '../utils/currency_utils.dart' as cu;

/// شاشة إدارة الترحيل (Posting Management)
/// تسمح بترحيل الفواتير والقيود، ومراجعتها قبل التأثير على الحسابات
class PostingManagementScreen extends StatefulWidget {
  final bool isArabic;

  const PostingManagementScreen({super.key, this.isArabic = true});

  @override
  State<PostingManagementScreen> createState() =>
      _PostingManagementScreenState();
}

class _PostingManagementScreenState extends State<PostingManagementScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;

  // Statistics
  Map<String, dynamic> _stats = {};
  bool _isLoadingStats = false;

  // Invoices
  List<dynamic> _unpostedInvoices = [];
  List<dynamic> _postedInvoices = [];
  bool _isLoadingInvoices = false;
  final Set<int> _selectedInvoiceIds = {};

  // Journal Entries
  List<dynamic> _unpostedEntries = [];
  List<dynamic> _postedEntries = [];
  bool _isLoadingEntries = false;
  final Set<int> _selectedEntryIds = {};
  bool _userInfoInitialized = false;

  // User name for posting — read from AuthProvider directly, no dialog needed

  // Search and Filter
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _dateFilter = 'all'; // 'all', 'today', 'week', 'month'

  // Posting Settings
  bool _autoPostInvoices = false;
  bool _autoPostEntries = false;
  bool _requireApproval = true;
  bool _allowUnposting = true;
  bool _validateBalance = true;
  final TextEditingController _defaultUserController = TextEditingController();

  // Posting Permissions (Frontend-level gating)
  bool _canPostInvoices = true;
  bool _canPostEntries = true;
  bool _canBatchPostInvoices = true;
  bool _canBatchPostEntries = true;
  bool _canUnpostInvoices = true;
  bool _canUnpostEntries = true;
  bool _canSchedulePosting = true;

  // Scheduled Posting Settings
  bool _enableScheduledPosting = false;
  TimeOfDay _scheduledTime = const TimeOfDay(hour: 17, minute: 0); // 5:00 PM
  String _scheduleFrequency = 'daily'; // daily, weekly, monthly
  bool _autoPostOnSchedule = true;

  // Pagination
  static const int _pageSize = 25;
  int _unpostedInvoicesPage = 1;
  int _postedInvoicesPage = 1;
  int _unpostedEntriesPage = 1;
  int _postedEntriesPage = 1;

  // Refresh indicator
  final bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    _searchController.addListener(() {
      if (mounted) {
        setState(() {
          _searchQuery = _searchController.text;
          _unpostedInvoicesPage = 1;
          _postedInvoicesPage = 1;
          _unpostedEntriesPage = 1;
          _postedEntriesPage = 1;
        });
      }
    });
    _loadStatistics();
    _loadUnpostedInvoices();
    _loadSettings();
    _checkScheduledPosting();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_userInfoInitialized) {
      _userInfoInitialized = true;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      switch (_tabController.index) {
        case 0:
          _loadUnpostedInvoices();
          break;
        case 1:
          _loadPostedInvoices();
          break;
        case 2:
          _loadUnpostedEntries();
          break;
        case 3:
          _loadPostedEntries();
          break;
      }
    }
  }

  // =========================================
  // Load Data Functions
  // =========================================

  Future<void> _loadStatistics() async {
    setState(() => _isLoadingStats = true);
    try {
      final data = await _apiService.getPostingStats();
      if (mounted) {
        setState(() => _stats = data['stats'] ?? {});
      }
    } catch (e) {
      _showError('خطأ في تحميل الإحصائيات: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingStats = false);
    }
  }

  Future<void> _loadUnpostedInvoices() async {
    setState(() => _isLoadingInvoices = true);
    try {
      final data = await _apiService.getUnpostedInvoices();
      if (mounted) {
        setState(() {
          _unpostedInvoices = data['invoices'] ?? [];
          _selectedInvoiceIds.clear();
          _unpostedInvoicesPage = 1;
        });
      }
    } catch (e) {
      _showError('خطأ في تحميل الفواتير: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingInvoices = false);
    }
  }

  Future<void> _loadPostedInvoices() async {
    setState(() => _isLoadingInvoices = true);
    try {
      final data = await _apiService.getPostedInvoices();
      if (mounted) {
        setState(() {
          _postedInvoices = data['invoices'] ?? [];
          _postedInvoicesPage = 1;
        });
      }
    } catch (e) {
      _showError('خطأ في تحميل الفواتير: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingInvoices = false);
    }
  }

  Future<void> _loadUnpostedEntries() async {
    setState(() => _isLoadingEntries = true);
    try {
      final data = await _apiService.getUnpostedJournalEntries();
      if (mounted) {
        setState(() {
          _unpostedEntries = data['entries'] ?? [];
          _selectedEntryIds.clear();
          _unpostedEntriesPage = 1;
        });
      }
    } catch (e) {
      _showError('خطأ في تحميل القيود: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingEntries = false);
    }
  }

  Future<void> _loadPostedEntries() async {
    setState(() => _isLoadingEntries = true);
    try {
      final data = await _apiService.getPostedJournalEntries();
      if (mounted) {
        setState(() {
          _postedEntries = data['entries'] ?? [];
          _postedEntriesPage = 1;
        });
      }
    } catch (e) {
      _showError('خطأ في تحميل القيود: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _isLoadingEntries = false);
    }
  }

  /// Pagination strip shared by all tabs.
  Widget _buildPaginationStrip({
    required int currentPage,
    required int totalItems,
    required void Function(int) onPageChanged,
  }) {
    final totalPages = (totalItems / _pageSize).ceil().clamp(1, 99999);
    if (totalPages <= 1) return const SizedBox.shrink();

    // Build compact page number list (first, last, neighbours of current).
    List<int> pageNums() {
      if (totalPages <= 7) return List.generate(totalPages, (i) => i + 1);
      final nums = <int>[1];
      final start = (currentPage - 2).clamp(2, totalPages - 1);
      final end = (currentPage + 2).clamp(2, totalPages - 1);
      if (start > 2) nums.add(-1);
      for (int p = start; p <= end; p++) {
        nums.add(p);
      }
      if (end < totalPages - 1) nums.add(-1);
      nums.add(totalPages);
      return nums;
    }

    final primary = Theme.of(context).colorScheme.primary;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left, size: 18),
              onPressed: currentPage <= 1
                  ? null
                  : () => onPageChanged(currentPage - 1),
            ),
          ),
          const SizedBox(width: 2),
          ...pageNums().map<Widget>((p) {
            if (p == -1) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '…',
                  style: tt.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              );
            }
            final isActive = p == currentPage;
            return GestureDetector(
              onTap: isActive ? null : () => onPageChanged(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 30,
                height: 28,
                decoration: BoxDecoration(
                  color: isActive ? primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: isActive
                      ? null
                      : Border.all(
                          color: cs.outline.withValues(alpha: 0.35),
                          width: 1,
                        ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$p',
                  style: tt.labelSmall?.copyWith(
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    color: isActive
                        ? cs.onPrimary
                        : cs.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(width: 2),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right, size: 18),
              onPressed: currentPage >= totalPages
                  ? null
                  : () => onPageChanged(currentPage + 1),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$currentPage / $totalPages',
            style: tt.labelSmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================
  // Settings Functions
  // =========================================

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 🆕 Load core posting settings from BACKEND (authoritative source)
      try {
        final serverSettings = await _apiService.getSettings();
        setState(() {
          _autoPostInvoices = serverSettings['auto_post_invoices'] == true;
          _autoPostEntries = serverSettings['auto_post_entries'] == true;
          _requireApproval =
              serverSettings['require_approval_before_post'] == true;
          _allowUnposting = serverSettings['allow_unposting'] == true;
        });
      } catch (e) {
        // Fallback to SharedPreferences if backend unreachable
        debugPrint('⚠️ Failed to load posting settings from backend: $e');
        setState(() {
          _autoPostInvoices = prefs.getBool('posting_auto_invoices') ?? false;
          _autoPostEntries = prefs.getBool('posting_auto_entries') ?? false;
          _requireApproval = prefs.getBool('posting_require_approval') ?? true;
          _allowUnposting = prefs.getBool('posting_allow_unpost') ?? true;
        });
      }

      // Local-only preferences (permissions, schedule, etc.)
      setState(() {
        _validateBalance = prefs.getBool('posting_validate_balance') ?? true;
        _canPostInvoices = prefs.getBool('posting_perm_post_invoices') ?? true;
        _canPostEntries = prefs.getBool('posting_perm_post_entries') ?? true;
        _canBatchPostInvoices =
            prefs.getBool('posting_perm_batch_invoices') ?? true;
        _canBatchPostEntries =
            prefs.getBool('posting_perm_batch_entries') ?? true;
        _canUnpostInvoices =
            prefs.getBool('posting_perm_unpost_invoices') ?? true;
        _canUnpostEntries =
            prefs.getBool('posting_perm_unpost_entries') ?? true;
        _canSchedulePosting = prefs.getBool('posting_perm_schedule') ?? true;
        _enableScheduledPosting =
            prefs.getBool('posting_schedule_enabled') ?? false;
        _autoPostOnSchedule = prefs.getBool('posting_auto_on_schedule') ?? true;
        _scheduleFrequency =
            prefs.getString('posting_schedule_freq') ?? 'daily';
        _defaultUserController.text =
            prefs.getString('posting_default_user') ?? '';

        // Load scheduled time
        final hour = prefs.getInt('posting_schedule_hour') ?? 17;
        final minute = prefs.getInt('posting_schedule_minute') ?? 0;
        _scheduledTime = TimeOfDay(hour: hour, minute: minute);
      });

      // Restart scheduled posting if enabled
      if (_enableScheduledPosting) {
        _checkScheduledPosting();
      }
    } catch (e) {
      _showError('خطأ في تحميل الإعدادات: ${e.toString()}');
    }
  }

  Future<void> _migrateScrapGold() async {
    try {
      final res = await _apiService.migrateScrapGoldToEmployeeSafes();
      final moved = res['moved'] ?? 0;
      if (!mounted) return;
      _showSuccess('تم نقل $moved حركة لخزائن الموظفين الصحيحة');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _showError('فشل: $e');
    }
  }

  Future<void> _syncOrphanEntries() async {
    try {
      final res = await _apiService.syncOrphanJournalEntries();
      final fixed = res['fixed'] ?? 0;
      if (!mounted) return;
      _showSuccess('تم إصلاح $fixed قيد يتيم');
      _loadUnpostedEntries();
    } catch (e) {
      if (!mounted) return;
      _showError('فشل المزامنة: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      // 🆕 Save core posting settings to BACKEND
      try {
        await _apiService.updateSettings({
          'auto_post_invoices': _autoPostInvoices,
          'auto_post_entries': _autoPostEntries,
          'require_approval_before_post': _requireApproval,
          'allow_unposting': _allowUnposting,
        });
      } catch (e) {
        debugPrint('⚠️ Failed to save posting settings to backend: $e');
        _showError('فشل حفظ إعدادات الترحيل على السيرفر: ${e.toString()}');
        return;
      }

      // Local-only preferences
      final prefs = await SharedPreferences.getInstance();

      // Keep local copies as fallback cache
      await prefs.setBool('posting_auto_invoices', _autoPostInvoices);
      await prefs.setBool('posting_auto_entries', _autoPostEntries);
      await prefs.setBool('posting_require_approval', _requireApproval);
      await prefs.setBool('posting_allow_unpost', _allowUnposting);
      await prefs.setBool('posting_validate_balance', _validateBalance);
      await prefs.setBool('posting_perm_post_invoices', _canPostInvoices);
      await prefs.setBool('posting_perm_post_entries', _canPostEntries);
      await prefs.setBool('posting_perm_batch_invoices', _canBatchPostInvoices);
      await prefs.setBool('posting_perm_batch_entries', _canBatchPostEntries);
      await prefs.setBool('posting_perm_unpost_invoices', _canUnpostInvoices);
      await prefs.setBool('posting_perm_unpost_entries', _canUnpostEntries);
      await prefs.setBool('posting_perm_schedule', _canSchedulePosting);
      await prefs.setBool('posting_schedule_enabled', _enableScheduledPosting);
      await prefs.setBool('posting_auto_on_schedule', _autoPostOnSchedule);
      await prefs.setString('posting_schedule_freq', _scheduleFrequency);
      await prefs.setString(
        'posting_default_user',
        _defaultUserController.text,
      );
      await prefs.setInt('posting_schedule_hour', _scheduledTime.hour);
      await prefs.setInt('posting_schedule_minute', _scheduledTime.minute);

      _showSuccess('تم حفظ الإعدادات بنجاح');
    } catch (e) {
      _showError('خطأ في حفظ الإعدادات: ${e.toString()}');
    }
  }

  // =========================================
  // Scheduled Posting Functions
  // =========================================

  void _checkScheduledPosting() {
    if (_enableScheduledPosting && _canSchedulePosting && mounted) {
      // Check every minute if it's time to post
      Future.delayed(const Duration(minutes: 1), () {
        if (mounted && _enableScheduledPosting && _canSchedulePosting) {
          _checkIfTimeToPost();
          _checkScheduledPosting(); // Schedule next check
        }
      });
    }
  }

  void _checkIfTimeToPost() {
    if (!_canSchedulePosting) return;

    final now = DateTime.now();
    final currentTime = TimeOfDay(hour: now.hour, minute: now.minute);

    // Check if current time matches scheduled time
    if (currentTime.hour == _scheduledTime.hour &&
        currentTime.minute == _scheduledTime.minute) {
      // Check frequency
      bool shouldPost = false;
      switch (_scheduleFrequency) {
        case 'daily':
          shouldPost = true;
          break;
        case 'weekly':
          shouldPost = now.weekday == 7; // Sunday
          break;
        case 'monthly':
          shouldPost = now.day == 1; // First day of month
          break;
      }

      if (shouldPost && _autoPostOnSchedule) {
        _performScheduledPosting();
      }
    }
  }

  Future<void> _performScheduledPosting() async {
    if (!_canSchedulePosting) {
      debugPrint('Scheduled posting skipped: lack of permission');
      return;
    }
    try {
      final userName = _defaultUserController.text.isEmpty
          ? 'النظام الآلي'
          : _defaultUserController.text;

      int postedInvoices = 0;
      int postedEntries = 0;

      // Auto-post invoices if enabled
      if (_autoPostInvoices && _canPostInvoices) {
        final data = await _apiService.getUnpostedInvoices();
        final invoices = data['invoices'] ?? [];
        if (invoices.isNotEmpty) {
          final ids = invoices
              .where((i) => (i is Map))
              .map((i) => i['id'] as int)
              .toList();
          if (ids.isNotEmpty) {
            final result = await _apiService.postInvoicesBatch(ids, userName);
            postedInvoices = result['posted_count'] ?? 0;
          }
        }
      }

      // Auto-post entries if enabled
      if (_autoPostEntries && _canPostEntries) {
        final data = await _apiService.getUnpostedJournalEntries();
        final entries = data['entries'] ?? [];
        if (entries.isNotEmpty) {
          final ids = entries.map((e) => e['id'] as int).toList();
          final result = await _apiService.postJournalEntriesBatch(
            ids,
            userName,
          );
          postedEntries = result['posted_count'] ?? 0;
        }
      }

      // Reload data
      await _loadStatistics();

      _showSuccess(
        'الترحيل التلقائي: $postedInvoices فاتورة، $postedEntries قيد',
      );
    } catch (e) {
      debugPrint('Scheduled posting error: $e');
    }
  }

  Future<void> _selectScheduledTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _scheduledTime,
      builder: (context, child) {
        return Directionality(textDirection: TextDirection.rtl, child: child!);
      },
    );

    if (time != null) {
      setState(() => _scheduledTime = time);
    }
  }

  // =========================================
  // Posting Functions
  // =========================================

  Future<void> _deleteUnpostedEntry(int entryId, String entryNumber) async {
    final confirm = await _confirmAction(
      'حذف قيد غير مُرحّل',
      'سيتم حذف القيد ($entryNumber) لأنه غير مُرحّل. هل أنت متأكد؟',
    );
    if (!confirm) return;

    try {
      final result = await _apiService.deleteUnpostedJournalEntry(entryId);
      if (result['success'] == true) {
        _showSuccess(result['message'] ?? 'تم حذف القيد بنجاح');
      } else {
        _showError(result['message'] ?? 'فشل حذف القيد');
      }
      _loadUnpostedEntries();
      _loadStatistics();
    } catch (e) {
      _showError('خطأ في حذف القيد: ${e.toString()}');
    }
  }

  Future<void> _postSelectedInvoices() async {
    if (!_canBatchPostInvoices) {
      _showError('لا تملك صلاحية الترحيل الجماعي للفواتير');
      return;
    }

    if (_selectedInvoiceIds.isEmpty) {
      _showError('الرجاء اختيار فاتورة واحدة على الأقل');
      return;
    }

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final selected = _unpostedInvoices
          .whereType<Map<String, dynamic>>()
          .where((inv) => _selectedInvoiceIds.contains(inv['id']))
          .toList();

      final postableIds = selected.map((inv) => inv['id'] as int).toList();

      final result = await _apiService.postInvoicesBatch(postableIds, userName);

      if (result['success'] == true) {
        _showSuccess('تم ترحيل ${result['posted_count']} فاتورة بنجاح');
        _loadUnpostedInvoices();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _postAllInvoices() async {
    if (!_canBatchPostInvoices) {
      _showError('لا تملك صلاحية الترحيل الجماعي للفواتير');
      return;
    }

    final allFiltered = _getFilteredInvoices();
    if (allFiltered.isEmpty) return;

    final confirm = await _confirmAction(
      'ترحيل جميع الفواتير',
      'سيتم ترحيل ${allFiltered.length} فاتورة غير مرحلة. هل أنت متأكد؟',
    );
    if (!confirm) return;

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final ids = allFiltered.map((inv) => inv['id'] as int).toList();
      final result = await _apiService.postInvoicesBatch(ids, userName);

      if (result['success'] == true) {
        _showSuccess('تم ترحيل ${result['posted_count']} فاتورة بنجاح');
        _selectedInvoiceIds.clear();
        _loadUnpostedInvoices();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _postInvoice(int invoiceId) async {
    if (!_canPostInvoices) {
      _showError('لا تملك صلاحية ترحيل الفواتير');
      return;
    }

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final result = await _apiService.postInvoice(invoiceId, userName);

      if (result['success'] == true) {
        _showSuccess('تم ترحيل الفاتورة بنجاح');
        _loadUnpostedInvoices();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _unpostInvoice(int invoiceId) async {
    if (!_canUnpostInvoices) {
      _showError('لا تملك صلاحية إلغاء ترحيل الفواتير');
      return;
    }

    final confirm = await _confirmAction(
      'هل أنت متأكد من إلغاء ترحيل هذه الفاتورة؟',
      'سيتم إلغاء تأثيرها على الحسابات',
    );

    if (!confirm) return;

    try {
      final result = await _apiService.unpostInvoice(invoiceId);

      if (result['success'] == true) {
        _showSuccess('تم إلغاء الترحيل بنجاح');
        _loadPostedInvoices();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل إلغاء الترحيل');
      }
    } catch (e) {
      _showError('خطأ في إلغاء الترحيل: ${e.toString()}');
    }
  }

  Future<void> _postSelectedEntries() async {
    if (!_canBatchPostEntries) {
      _showError('لا تملك صلاحية الترحيل الجماعي للقيود');
      return;
    }

    if (_selectedEntryIds.isEmpty) {
      _showError('الرجاء اختيار قيد واحد على الأقل');
      return;
    }

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final result = await _apiService.postJournalEntriesBatch(
        _selectedEntryIds.toList(),
        userName,
      );

      if (result['success'] == true) {
        _showSuccess('تم ترحيل ${result['posted_count']} قيد بنجاح');
        if (result['errors'] != null && result['errors'].isNotEmpty) {
          _showError('تخطي بعض القيود: ${result['errors'].join(', ')}');
        }
        _loadUnpostedEntries();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _postAllEntries() async {
    if (!_canBatchPostEntries) {
      _showError('لا تملك صلاحية الترحيل الجماعي للقيود');
      return;
    }

    final allFiltered = _getFilteredEntries();
    if (allFiltered.isEmpty) return;

    final confirm = await _confirmAction(
      'ترحيل جميع القيود',
      'سيتم ترحيل ${allFiltered.length} قيد غير مرحل. هل أنت متأكد؟',
    );
    if (!confirm) return;

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final ids = allFiltered.map((e) => e['id'] as int).toList();
      final result = await _apiService.postJournalEntriesBatch(ids, userName);

      if (result['success'] == true) {
        _showSuccess('تم ترحيل ${result['posted_count']} قيد بنجاح');
        if (result['errors'] != null && result['errors'].isNotEmpty) {
          _showError('تخطي بعض القيود: ${result['errors'].join(', ')}');
        }
        _selectedEntryIds.clear();
        _loadUnpostedEntries();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _postEntry(int entryId) async {
    if (!_canPostEntries) {
      _showError('لا تملك صلاحية ترحيل القيود');
      return;
    }

    final userName = Provider.of<AuthProvider>(context, listen: false).username;

    try {
      final result = await _apiService.postJournalEntry(entryId, userName);

      if (result['success'] == true) {
        _showSuccess('تم ترحيل القيد بنجاح');
        _loadUnpostedEntries();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل الترحيل');
      }
    } catch (e) {
      _showError('خطأ في الترحيل: ${e.toString()}');
    }
  }

  Future<void> _unpostEntry(int entryId) async {
    if (!_canUnpostEntries) {
      _showError('لا تملك صلاحية إلغاء ترحيل القيود');
      return;
    }

    final confirm = await _confirmAction(
      'هل أنت متأكد من إلغاء ترحيل هذا القيد؟',
      'سيتم إلغاء تأثيره على الحسابات',
    );

    if (!confirm) return;

    try {
      final result = await _apiService.unpostJournalEntry(entryId);

      if (result['success'] == true) {
        _showSuccess('تم إلغاء الترحيل بنجاح');
        _loadPostedEntries();
        _loadStatistics();
      } else {
        _showError(result['message'] ?? 'فشل إلغاء الترحيل');
      }
    } catch (e) {
      _showError('خطأ في إلغاء الترحيل: ${e.toString()}');
    }
  }

  // =========================================
  // Helper Functions
  // =========================================

  Future<bool> _confirmAction(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.AppColors.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: theme.AppColors.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    final cleanMessage = message.replaceFirst(RegExp(r'^Exception:\s*'), '');

    if (_isSessionError(cleanMessage)) {
      _handleSessionExpired(cleanMessage);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cleanMessage.isEmpty ? message : cleanMessage),
        backgroundColor: theme.AppColors.error,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  bool _isSessionError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('تسجيل الدخول') || normalized.contains('الجلسة');
  }

  Future<void> _handleSessionExpired(String message) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('انتهت صلاحية الجلسة'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('إغلاق'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await auth.logout();
                },
                child: const Text('تسجيل الدخول مجدداً'),
              ),
            ],
          ),
        );
      },
    );
  }

  // =========================================
  // Search and Filter Functions
  // =========================================

  List<dynamic> _getFilteredInvoices() {
    List<dynamic> filtered = List.from(_unpostedInvoices);

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((invoice) {
        final id = invoice['id'].toString();
        final type = (invoice['invoice_type'] ?? '').toString().toLowerCase();
        final total = invoice['total'].toString();
        final query = _searchQuery.toLowerCase();

        return id.contains(query) ||
            type.contains(query) ||
            total.contains(query);
      }).toList();
    }

    // Apply date filter
    if (_dateFilter != 'all') {
      final now = DateTime.now();
      filtered = filtered.where((invoice) {
        try {
          final dateStr = invoice['date'] as String?;
          if (dateStr == null || dateStr.isEmpty) return false;

          final invoiceDate = DateTime.parse(dateStr);

          switch (_dateFilter) {
            case 'today':
              return invoiceDate.year == now.year &&
                  invoiceDate.month == now.month &&
                  invoiceDate.day == now.day;
            case 'week':
              final weekAgo = now.subtract(const Duration(days: 7));
              return invoiceDate.isAfter(weekAgo);
            case 'month':
              final monthAgo = now.subtract(const Duration(days: 30));
              return invoiceDate.isAfter(monthAgo);
            default:
              return true;
          }
        } catch (e) {
          return false;
        }
      }).toList();
    }

    return filtered;
  }

  List<dynamic> _getFilteredEntries() {
    List<dynamic> filtered = List.from(_unpostedEntries);

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((entry) {
        final id = entry['id'].toString();
        final number = (entry['entry_number'] ?? '').toString().toLowerCase();
        final desc = (entry['description'] ?? '').toString().toLowerCase();
        final type = (entry['entry_type'] ?? '').toString().toLowerCase();
        final query = _searchQuery.toLowerCase();

        return id.contains(query) ||
            number.contains(query) ||
            desc.contains(query) ||
            type.contains(query);
      }).toList();
    }

    // Apply date filter
    if (_dateFilter != 'all') {
      final now = DateTime.now();
      filtered = filtered.where((entry) {
        try {
          final dateStr = entry['date'] as String?;
          if (dateStr == null || dateStr.isEmpty) return false;

          final entryDate = DateTime.parse(dateStr);

          switch (_dateFilter) {
            case 'today':
              return entryDate.year == now.year &&
                  entryDate.month == now.month &&
                  entryDate.day == now.day;
            case 'week':
              final weekAgo = now.subtract(const Duration(days: 7));
              return entryDate.isAfter(weekAgo);
            case 'month':
              final monthAgo = now.subtract(const Duration(days: 30));
              return entryDate.isAfter(monthAgo);
            default:
              return true;
          }
        } catch (e) {
          return false;
        }
      }).toList();
    }

    return filtered;
  }

  Widget _buildSearchAndFilterBar() {
    final surface = Theme.of(context).colorScheme.surface;
    final fieldFill = surface.withValues(alpha: 0.92);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.AppColors.deepGold.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search bar
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'البحث برقم الفاتورة، النوع، أو المبلغ...',
              prefixIcon: const Icon(
                Icons.search,
                color: theme.AppColors.primaryGold,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                      },
                    )
                  : null,
              filled: true,
              fillColor: fieldFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Date filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 20,
                  color: theme.AppColors.darkGold,
                ),
                const SizedBox(width: 8),
                _buildFilterChip('الكل', 'all'),
                const SizedBox(width: 8),
                _buildFilterChip('اليوم', 'today'),
                const SizedBox(width: 8),
                _buildFilterChip('آخر 7 أيام', 'week'),
                const SizedBox(width: 8),
                _buildFilterChip('آخر 30 يوم', 'month'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _dateFilter == value;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _dateFilter = value;
          _unpostedInvoicesPage = 1;
          _postedInvoicesPage = 1;
          _unpostedEntriesPage = 1;
          _postedEntriesPage = 1;
        });
      },
      selectedColor: theme.AppColors.primaryGold,
      checkmarkColor: Colors.white,
      backgroundColor: Theme.of(context).colorScheme.surface,
      side: BorderSide(
        color: isSelected
            ? theme.AppColors.primaryGold
            : theme.AppColors.primaryGold.withValues(alpha: 0.2),
      ),
      labelStyle: TextStyle(
        color: isSelected
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).textTheme.bodyMedium?.color,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  Widget _buildSearchAndFilterBarForEntries() {
    final surface = Theme.of(context).colorScheme.surface;
    final fieldFill = surface.withValues(alpha: 0.92);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.AppColors.deepGold.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search bar
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'البحث برقم القيد، الوصف، أو النوع...',
              prefixIcon: const Icon(
                Icons.search,
                color: theme.AppColors.primaryGold,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                      },
                    )
                  : null,
              filled: true,
              fillColor: fieldFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Date filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 20,
                  color: theme.AppColors.darkGold,
                ),
                const SizedBox(width: 8),
                _buildFilterChip('الكل', 'all'),
                const SizedBox(width: 8),
                _buildFilterChip('اليوم', 'today'),
                const SizedBox(width: 8),
                _buildFilterChip('آخر 7 أيام', 'week'),
                const SizedBox(width: 8),
                _buildFilterChip('آخر 30 يوم', 'month'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================
  // Build Functions
  // =========================================

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Text('إدارة الترحيل'),
              if (_enableScheduledPosting) ...[
                const SizedBox(width: 8),
                const Icon(
                  Icons.schedule,
                  size: 16,
                  color: theme.AppColors.success,
                ),
                const SizedBox(width: 4),
                Text(
                  _formatTimeOfDay(_scheduledTime),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          backgroundColor: theme.AppColors.darkGold,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'سجل التدقيق',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AuditLogScreen(),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'تحديث يدوي',
              onPressed: _isSyncing
                  ? null
                  : () {
                      _loadStatistics();
                      switch (_tabController.index) {
                        case 0:
                          _loadUnpostedInvoices();
                          break;
                        case 1:
                          _loadPostedInvoices();
                          break;
                        case 2:
                          _loadUnpostedEntries();
                          break;
                        case 3:
                          _loadPostedEntries();
                          break;
                      }
                    },
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(
                child: Row(
                  children: [
                    const Icon(Icons.pending_actions),
                    const SizedBox(width: 8),
                    Text(
                      'فواتير غير مرحلة (${_stats['invoices']?['unposted'] ?? 0})',
                    ),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  children: [
                    const Icon(Icons.check_circle),
                    const SizedBox(width: 8),
                    Text(
                      'فواتير مرحلة (${_stats['invoices']?['posted'] ?? 0})',
                    ),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  children: [
                    const Icon(Icons.pending_actions),
                    const SizedBox(width: 8),
                    Text(
                      'قيود غير مرحلة (${_stats['journal_entries']?['unposted'] ?? 0})',
                    ),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  children: [
                    const Icon(Icons.check_circle),
                    const SizedBox(width: 8),
                    Text(
                      'قيود مرحلة (${_stats['journal_entries']?['posted'] ?? 0})',
                    ),
                  ],
                ),
              ),
              const Tab(
                child: Row(
                  children: [
                    Icon(Icons.settings),
                    SizedBox(width: 8),
                    Text('إعدادات الترحيل'),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            // Statistics Card (hide on settings tab)
            if (_tabController.index != 4) _buildStatisticsCard(),
            // Tab View
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildUnpostedInvoicesTab(),
                  _buildPostedInvoicesTab(),
                  _buildUnpostedEntriesTab(),
                  _buildPostedEntriesTab(),
                  _buildSettingsTab(),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: _buildFloatingActionButton(),
      ),
    );
  }

  Widget _buildStatisticsCard() {
    if (_isLoadingStats) {
      return const Card(
        margin: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final invStats = _stats['invoices'] ?? {};
    final entryStats = _stats['journal_entries'] ?? {};

    final surfaceColor = Theme.of(context).colorScheme.surface;

    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.AppColors.primaryGold.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              theme.AppColors.primaryGold.withValues(alpha: 0.15),
              theme.AppColors.lightGold.withValues(alpha: 0.08),
              surfaceColor,
            ],
            begin: AlignmentDirectional.topEnd,
            end: AlignmentDirectional.bottomStart,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  context,
                  'الفواتير',
                  invStats['total'] ?? 0,
                  invStats['posted'] ?? 0,
                  invStats['unposted'] ?? 0,
                  Icons.receipt_long,
                  pendingApproval: invStats['pending_approval'] ?? 0,
                ),
              ),
              SizedBox(
                height: 72,
                child: VerticalDivider(
                  color: theme.AppColors.primaryGold.withValues(alpha: 0.4),
                  thickness: 1.2,
                ),
              ),
              Expanded(
                child: _buildStatItem(
                  context,
                  'القيود',
                  entryStats['total'] ?? 0,
                  entryStats['posted'] ?? 0,
                  entryStats['unposted'] ?? 0,
                  Icons.auto_stories,
                  pendingApproval: entryStats['pending_approval'] ?? 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    String title,
    int total,
    int posted,
    int unposted,
    IconData icon, {
    int pendingApproval = 0,
  }) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold);

    return Column(
      children: [
        Icon(icon, size: 32, color: theme.AppColors.primaryGold),
        const SizedBox(height: 8),
        Text(title, style: titleStyle),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildStatValue(
              context,
              'الإجمالي',
              total,
              theme.AppColors.darkGold,
            ),
            _buildStatValue(context, 'مرحلة', posted, theme.AppColors.success),
            _buildStatValue(
              context,
              'غير مرحلة',
              unposted,
              theme.AppColors.warning,
            ),
            if (pendingApproval > 0)
              _buildStatValue(
                context,
                'بانتظار موافقة',
                pendingApproval,
                Colors.orange,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatValue(
    BuildContext context,
    String label,
    int value,
    Color color,
  ) {
    final valueStyle = Theme.of(
      context,
    ).textTheme.headlineSmall?.copyWith(color: color);
    final labelStyle = Theme.of(context).textTheme.bodySmall;

    return Column(
      children: [
        Text(value.toString(), style: valueStyle),
        const SizedBox(height: 4),
        Text(label, style: labelStyle),
      ],
    );
  }

  Widget _buildUnpostedInvoicesTab() {
    if (_isLoadingInvoices) {
      return const Center(child: CircularProgressIndicator());
    }

    final allFiltered = _getFilteredInvoices();
    final totalPages = (allFiltered.length / _pageSize).ceil().clamp(1, 99999);
    final safePage = _unpostedInvoicesPage.clamp(1, totalPages);
    final start = (safePage - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, allFiltered.length);
    final filteredInvoices = allFiltered.sublist(start, end);

    if (allFiltered.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty && _dateFilter == 'all'
                  ? 'جميع الفواتير مرحلة ✅'
                  : 'لا توجد فواتير تطابق البحث',
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildSearchAndFilterBar(),
        // Actions bar: Select All / Post All
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Row(
            children: [
              Text(
                '${allFiltered.length} فاتورة',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (_selectedInvoiceIds.length == allFiltered.length) {
                      _selectedInvoiceIds.clear();
                    } else {
                      _selectedInvoiceIds.addAll(
                        allFiltered.map((inv) => inv['id'] as int),
                      );
                    }
                  });
                },
                icon: Icon(
                  _selectedInvoiceIds.length == allFiltered.length
                      ? Icons.deselect
                      : Icons.select_all,
                  size: 18,
                ),
                label: Text(
                  _selectedInvoiceIds.length == allFiltered.length
                      ? 'إلغاء التحديد'
                      : 'تحديد الكل',
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _canBatchPostInvoices ? _postAllInvoices : null,
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('ترحيل الكل'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.AppColors.primaryGold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        // Selection Header
        if (_selectedInvoiceIds.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.AppColors.lightGold.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Text(
                  'تم اختيار ${_selectedInvoiceIds.length} فاتورة',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _selectedInvoiceIds.clear()),
                  icon: const Icon(Icons.clear),
                  label: const Text('إلغاء الاختيار'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _postSelectedInvoices,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('ترحيل المحدد'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.AppColors.success,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        // List + pagination
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            itemCount: filteredInvoices.length + 1,
            itemBuilder: (context, index) {
              if (index == filteredInvoices.length) {
                return _buildPaginationStrip(
                  currentPage: safePage,
                  totalItems: allFiltered.length,
                  onPageChanged: (p) =>
                      setState(() => _unpostedInvoicesPage = p),
                );
              }
              return _buildInvoiceCard(
                filteredInvoices[index],
                isPosted: false,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPostedInvoicesTab() {
    if (_isLoadingInvoices) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_postedInvoices.isEmpty) {
      return const Center(child: Text('لا توجد فواتير مرحلة'));
    }

    final totalPages = (_postedInvoices.length / _pageSize).ceil().clamp(
      1,
      99999,
    );
    final safePage = _postedInvoicesPage.clamp(1, totalPages);
    final start = (safePage - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, _postedInvoices.length);
    final pageItems = _postedInvoices.sublist(start, end);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      itemCount: pageItems.length + 1,
      itemBuilder: (context, index) {
        if (index == pageItems.length) {
          return _buildPaginationStrip(
            currentPage: safePage,
            totalItems: _postedInvoices.length,
            onPageChanged: (p) => setState(() => _postedInvoicesPage = p),
          );
        }
        return _buildInvoiceCard(pageItems[index], isPosted: true);
      },
    );
  }

  Widget _buildInvoiceCard(
    Map<String, dynamic> invoice, {
    required bool isPosted,
  }) {
    final id = invoice['id'];
    final invoiceType = invoice['invoice_type'] ?? '';
    final total = invoice['total'] ?? 0.0;
    final date = invoice['date'] ?? '';
    final postedAt = invoice['posted_at'];
    final postedBy = invoice['posted_by'];
    final isSelected = _selectedInvoiceIds.contains(id);

    final borderColor = isPosted
        ? theme.AppColors.success
        : theme.AppColors.warning;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      elevation: isSelected ? 6 : 2,
      color: isSelected
          ? theme.AppColors.lightGold.withValues(alpha: 0.25)
          : Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: theme.AppColors.primaryGold, width: 1.5)
            : BorderSide.none,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: borderColor),
              Expanded(
                child: ListTile(
                  leading: isPosted
                      ? CircleAvatar(
                          backgroundColor: theme.AppColors.success,
                          child: const Icon(Icons.check, color: Colors.white),
                        )
                      : Checkbox(
                          value: isSelected,
                          activeColor: theme.AppColors.primaryGold,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedInvoiceIds.add(id);
                              } else {
                                _selectedInvoiceIds.remove(id);
                              }
                            });
                          },
                        ),
                  title: Text(
                    'فاتورة #$id - $invoiceType',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isPosted
                          ? Theme.of(context).textTheme.bodyLarge?.color
                          : theme.AppColors.darkGold,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.attach_money,
                            size: 14,
                            color: Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          cu.SarAwareText(
                            'المبلغ: ${total.toStringAsFixed(2)} ${context.read<SettingsProvider>().currencySymbolText}',
              isNewSar: context.read<SettingsProvider>().currencyIsNewSar,
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(width: 16),
                          Icon(
                            Icons.calendar_today,
                            size: 14,
                            color: Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'التاريخ: ${_formatDate(date)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      if (isPosted && postedBy != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.verified_user,
                              size: 14,
                              color: theme.AppColors.success,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'رحّله: $postedBy في ${_formatDateTime(postedAt)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  trailing: isPosted
                      ? (_allowUnposting
                            ? IconButton(
                                icon: const Icon(
                                  Icons.cancel,
                                  color: theme.AppColors.error,
                                ),
                                onPressed: () => _unpostInvoice(id),
                                tooltip: 'إلغاء الترحيل',
                              )
                            : const Tooltip(
                                message: 'إلغاء الترحيل معطّل في الإعدادات',
                                child: Icon(
                                  Icons.lock_outline,
                                  color: Colors.grey,
                                ),
                              ))
                      : IconButton(
                          icon: const Icon(
                            Icons.check_circle,
                            color: theme.AppColors.success,
                          ),
                          onPressed: () => _postInvoice(id),
                          tooltip: 'ترحيل',
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnpostedEntriesTab() {
    if (_isLoadingEntries) {
      return const Center(child: CircularProgressIndicator());
    }

    final allFilteredEntries = _getFilteredEntries();

    if (allFilteredEntries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty && _dateFilter == 'all'
                  ? 'جميع القيود مرحلة ✅'
                  : 'لا توجد قيود تطابق البحث',
              style: const TextStyle(fontSize: 18),
            ),
          ],
        ),
      );
    }

    final entTotalPages = (allFilteredEntries.length / _pageSize).ceil().clamp(
      1,
      99999,
    );
    final entSafePage = _unpostedEntriesPage.clamp(1, entTotalPages);
    final entStart = (entSafePage - 1) * _pageSize;
    final entEnd = (entStart + _pageSize).clamp(0, allFilteredEntries.length);
    final filteredEntries = allFilteredEntries.sublist(entStart, entEnd);

    return Column(
      children: [
        _buildSearchAndFilterBarForEntries(),
        // Actions bar: Select All / Post All
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Row(
            children: [
              Text(
                '${allFilteredEntries.length} قيد',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (_selectedEntryIds.length == allFilteredEntries.length) {
                      _selectedEntryIds.clear();
                    } else {
                      _selectedEntryIds.addAll(
                        allFilteredEntries.map((e) => e['id'] as int),
                      );
                    }
                  });
                },
                icon: Icon(
                  _selectedEntryIds.length == allFilteredEntries.length
                      ? Icons.deselect
                      : Icons.select_all,
                  size: 18,
                ),
                label: Text(
                  _selectedEntryIds.length == allFilteredEntries.length
                      ? 'إلغاء التحديد'
                      : 'تحديد الكل',
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _canBatchPostEntries ? _postAllEntries : null,
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('ترحيل الكل'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.AppColors.primaryGold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        // Selection Header
        if (_selectedEntryIds.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.AppColors.lightGold.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Text(
                  'تم اختيار ${_selectedEntryIds.length} قيد',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _selectedEntryIds.clear()),
                  icon: const Icon(Icons.clear),
                  label: const Text('إلغاء الاختيار'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _postSelectedEntries,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('ترحيل المحدد'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.AppColors.success,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        // List + pagination
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            itemCount: filteredEntries.length + 1,
            itemBuilder: (context, index) {
              if (index == filteredEntries.length) {
                return _buildPaginationStrip(
                  currentPage: entSafePage,
                  totalItems: allFilteredEntries.length,
                  onPageChanged: (p) =>
                      setState(() => _unpostedEntriesPage = p),
                );
              }
              return _buildEntryCard(filteredEntries[index], isPosted: false);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPostedEntriesTab() {
    if (_isLoadingEntries) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_postedEntries.isEmpty) {
      return const Center(child: Text('لا توجد قيود مرحلة'));
    }

    final totalPages = (_postedEntries.length / _pageSize).ceil().clamp(
      1,
      99999,
    );
    final safePage = _postedEntriesPage.clamp(1, totalPages);
    final start = (safePage - 1) * _pageSize;
    final end = (start + _pageSize).clamp(0, _postedEntries.length);
    final pageItems = _postedEntries.sublist(start, end);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      itemCount: pageItems.length + 1,
      itemBuilder: (context, index) {
        if (index == pageItems.length) {
          return _buildPaginationStrip(
            currentPage: safePage,
            totalItems: _postedEntries.length,
            onPageChanged: (p) => setState(() => _postedEntriesPage = p),
          );
        }
        return _buildEntryCard(pageItems[index], isPosted: true);
      },
    );
  }

  Widget _buildEntryCard(Map<String, dynamic> entry, {required bool isPosted}) {
    final id = entry['id'];
    final entryNumber = entry['entry_number'] ?? '';
    final description = entry['description'] ?? '';
    final entryType = entry['entry_type'] ?? '';
    final date = entry['date'] ?? '';
    final postedAt = entry['posted_at'];
    final postedBy = entry['posted_by'];
    final createdBy = (entry['created_by'] ?? '').toString();
    final referenceType = (entry['reference_type'] ?? '').toString();
    final referenceNumber = (entry['reference_number'] ?? '').toString();
    final referenceId = entry['reference_id'];

    final summary = (entry['posting_summary'] is Map)
        ? (entry['posting_summary'] as Map)
        : const <String, dynamic>{};

    final linesCount = (summary['lines_count'] is num)
        ? (summary['lines_count'] as num).toInt()
        : ((entry['lines'] is List) ? (entry['lines'] as List).length : 0);

    final cashDebitTotal = (summary['cash_debit_total'] is num)
        ? (summary['cash_debit_total'] as num).toDouble()
        : 0.0;
    final cashCreditTotal = (summary['cash_credit_total'] is num)
        ? (summary['cash_credit_total'] as num).toDouble()
        : 0.0;

    final mainKarat = (summary['main_karat'] is num)
        ? (summary['main_karat'] as num).toInt()
        : 21;
    final goldDebitMain = (summary['gold_debit_main_karat'] is num)
        ? (summary['gold_debit_main_karat'] as num).toDouble()
        : 0.0;
    final goldCreditMain = (summary['gold_credit_main_karat'] is num)
        ? (summary['gold_credit_main_karat'] as num).toDouble()
        : 0.0;

    final isSelected = _selectedEntryIds.contains(id);

    final borderColor = isPosted
        ? theme.AppColors.success
        : theme.AppColors.info;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      elevation: isSelected ? 6 : 2,
      color: isSelected
          ? theme.AppColors.lightGold.withValues(alpha: 0.25)
          : Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: theme.AppColors.primaryGold, width: 1.5)
            : BorderSide.none,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: borderColor),
              Expanded(
                child: ListTile(
                  leading: isPosted
                      ? CircleAvatar(
                          backgroundColor: theme.AppColors.success,
                          child: const Icon(Icons.check, color: Colors.white),
                        )
                      : Checkbox(
                          value: isSelected,
                          activeColor: theme.AppColors.primaryGold,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selectedEntryIds.add(id);
                              } else {
                                _selectedEntryIds.remove(id);
                              }
                            });
                          },
                        ),
                  title: Text(
                    '$entryNumber - $entryType',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isPosted
                          ? Theme.of(context).textTheme.bodyLarge?.color
                          : theme.AppColors.info,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      if (referenceNumber.isNotEmpty ||
                          referenceType.isNotEmpty)
                        Row(
                          children: [
                            Icon(Icons.link, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                referenceNumber.isNotEmpty
                                    ? 'المرجع: $referenceNumber'
                                    : 'المرجع: $referenceType${referenceId != null ? ' #$referenceId' : ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      if (description.isNotEmpty)
                        Row(
                          children: [
                            Icon(
                              Icons.notes,
                              size: 14,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                description,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      if (createdBy.isNotEmpty)
                        Row(
                          children: [
                            Icon(
                              Icons.person,
                              size: 14,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'أنشأه: $createdBy',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      if (linesCount > 0)
                        Row(
                          children: [
                            Icon(
                              Icons.format_list_bulleted,
                              size: 14,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'عدد الأسطر: $linesCount',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      if (cashDebitTotal != 0.0 || cashCreditTotal != 0.0)
                        Row(
                          children: [
                            Icon(
                              Icons.payments,
                              size: 14,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'نقد: مدين ${cashDebitTotal.toStringAsFixed(2)} / دائن ${cashCreditTotal.toStringAsFixed(2)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      if (goldDebitMain != 0.0 || goldCreditMain != 0.0)
                        Row(
                          children: [
                            Icon(
                              Icons.scale,
                              size: 14,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                'ذهب (عيار $mainKarat): مدين ${goldDebitMain.toStringAsFixed(3)}g / دائن ${goldCreditMain.toStringAsFixed(3)}g',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      Row(
                        children: [
                          Icon(
                            Icons.calendar_today,
                            size: 14,
                            color: Colors.grey[600],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'التاريخ: ${_formatDate(date)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      if (isPosted && postedBy != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.verified_user,
                              size: 14,
                              color: theme.AppColors.success,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'رحّله: $postedBy في ${_formatDateTime(postedAt)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  trailing: isPosted
                      ? (_allowUnposting
                            ? IconButton(
                                icon: const Icon(
                                  Icons.cancel,
                                  color: theme.AppColors.error,
                                ),
                                onPressed: () => _unpostEntry(id),
                                tooltip: 'إلغاء الترحيل',
                              )
                            : const Tooltip(
                                message: 'إلغاء الترحيل معطّل في الإعدادات',
                                child: Icon(
                                  Icons.lock_outline,
                                  color: Colors.grey,
                                ),
                              ))
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: theme.AppColors.error,
                              ),
                              onPressed: () => _deleteUnpostedEntry(
                                id,
                                entryNumber.toString(),
                              ),
                              tooltip: 'حذف القيد غير المرحل',
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.check_circle,
                                color: theme.AppColors.success,
                              ),
                              onPressed: () => _postEntry(id),
                              tooltip: 'ترحيل',
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Card(
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.AppColors.primaryGold.withValues(alpha: 0.72),
                    theme.AppColors.darkGold,
                  ],
                  begin: AlignmentDirectional.centerEnd,
                  end: AlignmentDirectional.centerStart,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.settings_suggest,
                        size: 30,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إعدادات نظام الترحيل',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'تحكم في سلوك الترحيل والصلاحيات والأتمتة من مكان واحد',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Automatic Posting Section
          _buildSectionTitle('الترحيل التلقائي'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('ترحيل الفواتير تلقائياً'),
                  subtitle: const Text('يتم ترحيل الفواتير فور حفظها'),
                  value: _autoPostInvoices,
                  onChanged: (value) {
                    setState(() => _autoPostInvoices = value);
                    _saveSettings();
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.receipt_long,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                // Posted at creation whoever creates it when on; off, who
                // creates does not post. Only the system admin turns it --
                // the server refuses anyone else (the owner, 9 Oct 2026).
                SwitchListTile(
                  title: const Text('ترحيل القيود تلقائياً'),
                  subtitle: Text(
                    context.watch<AuthProvider>().isSystemAdmin
                        ? 'مفعّل: يُرحَّل القيد اليدوي فور حفظه أيًّا كان منشئه · معطّل: يرحّله غير منشئه'
                        : 'يغيّره مسؤول النظام وحده',
                  ),
                  value: _autoPostEntries,
                  onChanged: context.watch<AuthProvider>().isSystemAdmin
                      ? (value) {
                          setState(() => _autoPostEntries = value);
                          _saveSettings();
                        }
                      : null,
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(Icons.book, color: theme.AppColors.darkGold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Approval & Permissions Section
          _buildSectionTitle('الموافقات والصلاحيات'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('طلب موافقة قبل الترحيل'),
                  subtitle: const Text(
                    'يجب الموافقة على الفاتورة/القيد قبل الترحيل',
                  ),
                  value: _requireApproval,
                  onChanged: (value) {
                    setState(() => _requireApproval = value);
                    _saveSettings();
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.verified_user,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('السماح بإلغاء الترحيل'),
                  subtitle: const Text(
                    'يمكن إلغاء ترحيل الفواتير والقيود المرحلة',
                  ),
                  value: _allowUnposting,
                  onChanged: (value) {
                    setState(() => _allowUnposting = value);
                    _saveSettings();
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(Icons.undo, color: theme.AppColors.darkGold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Posting Permissions Section
          _buildSectionTitle('صلاحيات الترحيل (محلية)'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('ترحيل الفواتير'),
                  subtitle: const Text('السماح بترحيل الفواتير المفردة'),
                  value: _canPostInvoices,
                  onChanged: (value) {
                    setState(() => _canPostInvoices = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.receipt_long,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('ترحيل القيود'),
                  subtitle: const Text('السماح بترحيل قيود اليومية المفردة'),
                  value: _canPostEntries,
                  onChanged: (value) {
                    setState(() => _canPostEntries = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.auto_stories,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('ترحيل جماعي للفواتير'),
                  subtitle: const Text('السماح بترحيل عدة فواتير دفعة واحدة'),
                  value: _canBatchPostInvoices,
                  onChanged: (value) {
                    setState(() => _canBatchPostInvoices = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.done_all,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('ترحيل جماعي للقيود'),
                  subtitle: const Text('السماح بترحيل عدة قيود دفعة واحدة'),
                  value: _canBatchPostEntries,
                  onChanged: (value) {
                    setState(() => _canBatchPostEntries = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.library_books,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('إلغاء ترحيل الفواتير'),
                  subtitle: const Text(
                    'السماح بإلغاء الترحيل للفواتير المرحلة',
                  ),
                  value: _canUnpostInvoices,
                  onChanged: (value) {
                    setState(() => _canUnpostInvoices = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.cancel,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('إلغاء ترحيل القيود'),
                  subtitle: const Text('السماح بإلغاء الترحيل للقيود المرحلة'),
                  value: _canUnpostEntries,
                  onChanged: (value) {
                    setState(() => _canUnpostEntries = value);
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.remove_circle,
                    color: theme.AppColors.darkGold,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('التحكم في الجدولة'),
                  subtitle: const Text('السماح بتفعيل الترحيل المجدول وإدارته'),
                  value: _canSchedulePosting,
                  onChanged: (value) {
                    setState(() => _canSchedulePosting = value);
                    if (!value) {
                      _enableScheduledPosting = false;
                    }
                  },
                  activeThumbColor: theme.AppColors.primaryGold,
                  secondary: Icon(
                    Icons.schedule,
                    color: theme.AppColors.darkGold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Validation Section
          _buildSectionTitle('التحقق والمراجعة'),
          Card(
            child: SwitchListTile(
              title: const Text('التحقق من توازن القيود'),
              subtitle: const Text('منع ترحيل القيود غير المتوازنة'),
              value: _validateBalance,
              onChanged: (value) {
                setState(() => _validateBalance = value);
              },
              activeThumbColor: theme.AppColors.primaryGold,
              secondary: Icon(Icons.balance, color: theme.AppColors.darkGold),
            ),
          ),
          const SizedBox(height: 24),

          // Scheduled Posting Section
          _buildSectionTitle('جدولة الترحيل التلقائي'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(
                    'تفعيل الترحيل المجدول',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: !_canSchedulePosting
                          ? Colors.grey
                          : theme.AppColors.darkGold,
                    ),
                  ),
                  subtitle: Text(
                    !_canSchedulePosting
                        ? 'الصلاحية غير مفعلة، الرجاء التواصل مع المسؤول'
                        : _enableScheduledPosting
                        ? 'سيتم الترحيل تلقائياً في ${_formatTimeOfDay(_scheduledTime)}'
                        : 'الترحيل المجدول متوقف',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: !_canSchedulePosting
                          ? Colors.grey
                          : _enableScheduledPosting
                          ? theme.AppColors.darkGold
                          : Colors.grey[600],
                    ),
                  ),
                  value: _enableScheduledPosting,
                  activeThumbColor: theme.AppColors.primaryGold,
                  activeTrackColor: theme.AppColors.lightGold.withValues(
                    alpha: 0.6,
                  ),
                  inactiveThumbColor: Colors.grey[400],
                  inactiveTrackColor: Colors.grey[300],
                  onChanged: !_canSchedulePosting
                      ? null
                      : (value) {
                          setState(() => _enableScheduledPosting = value);
                          if (value) {
                            _checkScheduledPosting();
                            _showSuccess('تم تفعيل الترحيل المجدول');
                          } else {
                            _showSuccess('تم إيقاف الترحيل المجدول');
                          }
                        },
                  secondary: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !_canSchedulePosting
                          ? Colors.grey.shade200
                          : _enableScheduledPosting
                          ? theme.AppColors.lightGold.withValues(alpha: 0.45)
                          : theme.AppColors.lightGold.withValues(alpha: 0.2),
                      border: Border.all(
                        color: !_canSchedulePosting
                            ? Colors.grey.shade400
                            : theme.AppColors.mediumGold,
                      ),
                    ),
                    child: Icon(
                      Icons.schedule,
                      color: !_canSchedulePosting
                          ? Colors.grey
                          : _enableScheduledPosting
                          ? theme.AppColors.primaryGold
                          : theme.AppColors.darkGold,
                    ),
                  ),
                ),
                if (_enableScheduledPosting && _canSchedulePosting) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Time Selection
                        const Text(
                          'وقت الترحيل:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: _selectScheduledTime,
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.grey[50],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.access_time,
                                      color: theme.AppColors.success,
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      _formatTimeOfDay(_scheduledTime),
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: theme.AppColors.success,
                                      ),
                                    ),
                                  ],
                                ),
                                const Icon(Icons.edit, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Frequency Selection
                        const Text(
                          'التكرار:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'daily',
                              label: Text('يومياً'),
                              icon: Icon(Icons.today),
                            ),
                            ButtonSegment(
                              value: 'weekly',
                              label: Text('أسبوعياً'),
                              icon: Icon(Icons.calendar_today),
                            ),
                            ButtonSegment(
                              value: 'monthly',
                              label: Text('شهرياً'),
                              icon: Icon(Icons.calendar_month),
                            ),
                          ],
                          selected: {_scheduleFrequency},
                          onSelectionChanged: (Set<String> newSelection) {
                            setState(() {
                              _scheduleFrequency = newSelection.first;
                            });
                          },
                        ),
                        const SizedBox(height: 20),

                        // Auto-post options
                        SwitchListTile(
                          title: const Text('ترحيل تلقائي في الموعد'),
                          subtitle: const Text(
                            'سيتم الترحيل تلقائياً دون تأكيد',
                          ),
                          value: _autoPostOnSchedule,
                          dense: true,
                          onChanged: (value) {
                            setState(() => _autoPostOnSchedule = value);
                          },
                        ),

                        const SizedBox(height: 12),
                        // Info card
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.AppColors.info.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.AppColors.info.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: theme.AppColors.info,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _getScheduleDescription(),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: theme.AppColors.info,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Default User Section
          _buildSectionTitle('المستخدم الافتراضي'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'اسم المستخدم الافتراضي للترحيل',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'سيتم استخدام هذا الاسم تلقائياً عند الترحيل',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _defaultUserController,
                    decoration: const InputDecoration(
                      hintText: 'مثال: أحمد المحاسب',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Statistics Section
          _buildSectionTitle('معلومات النظام'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow('إصدار النظام', '1.0.0'),
                  const Divider(),
                  _buildInfoRow('آخر تحديث', '2025-11-10'),
                  const Divider(),
                  _buildInfoRow(
                    'إجمالي الفواتير',
                    '${_stats['invoices']?['total'] ?? 0}',
                  ),
                  const Divider(),
                  _buildInfoRow(
                    'إجمالي القيود',
                    '${_stats['journal_entries']?['total'] ?? 0}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Save Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saveSettings,
              icon: const Icon(Icons.save),
              label: const Text('حفظ الإعدادات'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.AppColors.darkGold,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Migrate scrap gold to correct employee safes
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _migrateScrapGold,
              icon: const Icon(Icons.move_down_rounded, color: Colors.deepOrange),
              label: const Text('نقل ذهب الكسر لخزائن الموظفين'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: Colors.deepOrange,
                side: const BorderSide(color: Colors.deepOrange),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),

          // Sync Orphan Entries Button
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _syncOrphanEntries,
              icon: const Icon(Icons.sync_problem, color: Colors.orange),
              label: const Text('مزامنة القيود اليتيمة'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: Colors.orange,
                side: const BorderSide(color: Colors.orange),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Reset Button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _autoPostInvoices = false;
                  _autoPostEntries = false;
                  _requireApproval = true;
                  _allowUnposting = true;
                  _validateBalance = true;
                  _canPostInvoices = true;
                  _canPostEntries = true;
                  _canBatchPostInvoices = true;
                  _canBatchPostEntries = true;
                  _canUnpostInvoices = true;
                  _canUnpostEntries = true;
                  _canSchedulePosting = true;
                  _enableScheduledPosting = false;
                  _scheduledTime = const TimeOfDay(hour: 17, minute: 0);
                  _scheduleFrequency = 'daily';
                  _autoPostOnSchedule = true;
                  _defaultUserController.clear();
                });
                _saveSettings();
                _showSuccess('تم إعادة تعيين الإعدادات للقيم الافتراضية');
              },
              icon: const Icon(Icons.restore),
              label: const Text('إعادة تعيين الإعدادات'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.AppColors.darkGold,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.AppColors.darkGold,
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildFloatingActionButton() {
    if (_tabController.index == 0 && _selectedInvoiceIds.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: _postSelectedInvoices,
        backgroundColor: theme.AppColors.success,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.check_circle),
        label: Text('ترحيل ${_selectedInvoiceIds.length} فاتورة'),
      );
    }

    if (_tabController.index == 2 && _selectedEntryIds.isNotEmpty) {
      return FloatingActionButton.extended(
        onPressed: _postSelectedEntries,
        backgroundColor: theme.AppColors.success,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.check_circle),
        label: Text('ترحيل ${_selectedEntryIds.length} قيد'),
      );
    }

    return null;
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('yyyy-MM-dd').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  String _formatDateTime(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('yyyy-MM-dd HH:mm').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  String _formatTimeOfDay(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.hour >= 12 ? 'مساءً' : 'صباحاً';
    final hour12 = time.hour > 12
        ? time.hour - 12
        : (time.hour == 0 ? 12 : time.hour);
    return '$hour12:${minute.padLeft(2, '0')} $period ($hour:$minute)';
  }

  String _getScheduleDescription() {
    String freq = '';
    switch (_scheduleFrequency) {
      case 'daily':
        freq = 'يومياً';
        break;
      case 'weekly':
        freq = 'كل أحد';
        break;
      case 'monthly':
        freq = 'أول كل شهر';
        break;
    }

    final whatToPost = [];
    if (_autoPostInvoices) whatToPost.add('الفواتير');
    if (_autoPostEntries) whatToPost.add('القيود');
    final items = whatToPost.isEmpty ? 'لا شيء' : whatToPost.join(' و ');

    return 'سيتم ترحيل $items $freq في ${_formatTimeOfDay(_scheduledTime)}';
  }
}
