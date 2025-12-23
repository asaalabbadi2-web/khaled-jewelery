import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';

/// شاشة ملف المستخدم - عرض تفاصيل كاملة للمستخدم
class UserProfileScreen extends StatefulWidget {
  final ApiService api;
  final int userId;
  final bool isArabic;

  const UserProfileScreen({
    super.key,
    required this.api,
    required this.userId,
    this.isArabic = true,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _auditLogs = [];
  bool _loading = false;
  String? _token;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadToken();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('jwt_token');
    if (_token == null || _token!.isEmpty) {
      final legacy = prefs.getString('auth_token');
      if (legacy != null && legacy.isNotEmpty) {
        _token = legacy;
        await prefs.setString('jwt_token', legacy);
      }
    }
    if (_token != null) {
      _loadUserData();
    }
  }

  Future<void> _loadUserData() async {
    if (_token == null) return;

    setState(() => _loading = true);
    try {
      // Load user details
      final userResponse = await widget.api.getUserById(_token!, widget.userId);
      if (userResponse['success'] == true) {
        setState(() {
          _user = userResponse['user'];
        });
      }

      // Load recent audit logs for this user
      try {
        final logsResponse = await widget.api.getAuditLogsByUser(
          _user!['username'],
          limit: 20,
        );
        if (logsResponse['success'] == true) {
          setState(() {
            _auditLogs = List<Map<String, dynamic>>.from(
              logsResponse['logs'] ?? [],
            );
          });
        }
      } catch (e) {
        debugPrint('Error loading audit logs: $e');
      }

      // Note: Sessions endpoint might need to be added to backend
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : const Color(0xFFFFD700),
      ),
    );
  }

  String _formatDateTime(String? dateStr) {
    if (dateStr == null) return widget.isArabic ? 'غير متوفر' : 'N/A';
    try {
      final dt = DateTime.parse(dateStr);
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (e) {
      return dateStr;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isArabic ? 'ملف المستخدم' : 'User Profile',
        ),
        backgroundColor: const Color(0xFFFFD700),
        foregroundColor: Colors.black87,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.black87,
          unselectedLabelColor: Colors.black45,
          indicatorColor: Colors.black87,
          tabs: [
            Tab(
              icon: const Icon(Icons.info_outline),
              text: widget.isArabic ? 'المعلومات' : 'Info',
            ),
            Tab(
              icon: const Icon(Icons.history),
              text: widget.isArabic ? 'النشاط' : 'Activity',
            ),
            Tab(
              icon: const Icon(Icons.security),
              text: widget.isArabic ? 'الأمان' : 'Security',
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _user == null
              ? Center(
                  child: Text(
                    widget.isArabic
                        ? 'فشل تحميل بيانات المستخدم'
                        : 'Failed to load user data',
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildInfoTab(),
                    _buildActivityTab(),
                    _buildSecurityTab(),
                  ],
                ),
    );
  }

  Widget _buildInfoTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Card with Avatar
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.3),
                    child: Icon(
                      _user!['is_admin'] == true
                          ? Icons.admin_panel_settings
                          : Icons.person,
                      size: 40,
                      color: const Color(0xFFB8860B),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _user!['full_name'] ?? _user!['username'],
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '@${_user!['username']}',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: Colors.grey[600],
                              ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _buildStatusChip(
                              _user!['is_active'] == true
                                  ? (widget.isArabic ? 'نشط' : 'Active')
                                  : (widget.isArabic ? 'معطل' : 'Inactive'),
                              _user!['is_active'] == true
                                  ? Colors.green
                                  : Colors.red,
                            ),
                            const SizedBox(width: 8),
                            if (_user!['is_admin'] == true)
                              _buildStatusChip(
                                widget.isArabic ? 'مدير' : 'Admin',
                                Colors.deepPurple,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Basic Information
          _buildSectionTitle(
            widget.isArabic ? 'المعلومات الأساسية' : 'Basic Information',
            Icons.badge_outlined,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow(
                    widget.isArabic ? 'البريد الإلكتروني' : 'Email',
                    _user!['email'] ?? '-',
                    Icons.email_outlined,
                  ),
                  const Divider(),
                  _buildInfoRow(
                    widget.isArabic ? 'الهاتف' : 'Phone',
                    _user!['phone'] ?? '-',
                    Icons.phone_outlined,
                  ),
                  const Divider(),
                  _buildInfoRow(
                    widget.isArabic ? 'القسم' : 'Department',
                    _user!['department'] ?? '-',
                    Icons.business_outlined,
                  ),
                  const Divider(),
                  _buildInfoRow(
                    widget.isArabic ? 'الوظيفة' : 'Position',
                    _user!['position'] ?? '-',
                    Icons.work_outline,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Roles and Permissions
          _buildSectionTitle(
            widget.isArabic ? 'الأدوار والصلاحيات' : 'Roles & Permissions',
            Icons.vpn_key_outlined,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.isArabic ? 'الأدوار:' : 'Roles:',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_user!['roles'] != null && (_user!['roles'] as List).isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: (_user!['roles'] as List).map((role) {
                        return Chip(
                          avatar: const Icon(Icons.group_work, size: 18),
                          label: Text(
                            widget.isArabic
                                ? (role['name_ar'] ?? role['name'])
                                : role['name'],
                          ),
                          backgroundColor:
                              const Color(0xFFFFD700).withValues(alpha: 0.2),
                        );
                      }).toList(),
                    )
                  else
                    Text(
                      widget.isArabic ? 'لا توجد أدوار' : 'No roles assigned',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Timeline Information
          _buildSectionTitle(
            widget.isArabic ? 'معلومات زمنية' : 'Timeline',
            Icons.access_time,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow(
                    widget.isArabic ? 'تاريخ الإنشاء' : 'Created At',
                    _formatDateTime(_user!['created_at']),
                    Icons.calendar_today,
                  ),
                  const Divider(),
                  _buildInfoRow(
                    widget.isArabic ? 'آخر تحديث' : 'Last Updated',
                    _formatDateTime(_user!['updated_at']),
                    Icons.update,
                  ),
                  const Divider(),
                  _buildInfoRow(
                    widget.isArabic ? 'آخر تسجيل دخول' : 'Last Login',
                    _formatDateTime(_user!['last_login']),
                    Icons.login,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActivityTab() {
    return _auditLogs.isEmpty
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.history, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text(
                  widget.isArabic ? 'لا توجد أنشطة' : 'No activity logs',
                  style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                ),
              ],
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _auditLogs.length,
            itemBuilder: (context, index) {
              final log = _auditLogs[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: log['status'] == 'success'
                        ? Colors.green.withValues(alpha: 0.2)
                        : Colors.red.withValues(alpha: 0.2),
                    child: Icon(
                      _getActionIcon(log['action']),
                      color: log['status'] == 'success'
                          ? Colors.green
                          : Colors.red,
                    ),
                  ),
                  title: Text(
                    log['description'] ?? log['action'] ?? '-',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(_formatDateTime(log['created_at'])),
                      if (log['ip_address'] != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'IP: ${log['ip_address']}',
                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                  trailing: Chip(
                    label: Text(
                      log['category'] ?? '-',
                      style: const TextStyle(fontSize: 11),
                    ),
                    backgroundColor: Colors.grey[200],
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              );
            },
          );
  }

  Widget _buildSecurityTab() {
    final isLocked = _user!['is_locked'] == true;
    final failedAttempts = _user!['failed_login_attempts'] ?? 0;
    final lockedUntil = _user!['locked_until'];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Security Status Card
          Card(
            elevation: 2,
            color: isLocked ? Colors.red.shade50 : Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(
                    isLocked ? Icons.lock : Icons.lock_open,
                    size: 48,
                    color: isLocked ? Colors.red : Colors.green,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isLocked
                              ? (widget.isArabic ? 'الحساب مقفول' : 'Account Locked')
                              : (widget.isArabic ? 'الحساب آمن' : 'Account Secure'),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isLocked ? Colors.red : Colors.green,
                              ),
                        ),
                        if (isLocked && lockedUntil != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${widget.isArabic ? 'حتى' : 'Until'}: ${_formatDateTime(lockedUntil)}',
                            style: TextStyle(color: Colors.grey[700]),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          _buildSectionTitle(
            widget.isArabic ? 'إحصائيات الأمان' : 'Security Stats',
            Icons.analytics_outlined,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Card(
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 32,
                          color: failedAttempts > 0 ? Colors.orange : Colors.green,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '$failedAttempts',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: failedAttempts > 0 ? Colors.orange : Colors.green,
                              ),
                        ),
                        Text(
                          widget.isArabic ? 'محاولات فاشلة' : 'Failed Attempts',
                          style: const TextStyle(fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Card(
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.vpn_key,
                          size: 32,
                          color: Color(0xFFFFD700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _user!['password_changed_at'] != null ? '✓' : '?',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        Text(
                          widget.isArabic ? 'كلمة المرور' : 'Password',
                          style: const TextStyle(fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          _buildSectionTitle(
            widget.isArabic ? 'معلومات إضافية' : 'Additional Info',
            Icons.info_outline,
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildInfoRow(
                    widget.isArabic ? 'آخر فشل تسجيل دخول' : 'Last Failed Login',
                    _formatDateTime(_user!['last_failed_login']),
                    Icons.error_outline,
                  ),
                  if (_user!['password_changed_at'] != null) ...[
                    const Divider(),
                    _buildInfoRow(
                      widget.isArabic ? 'آخر تغيير كلمة مرور' : 'Password Last Changed',
                      _formatDateTime(_user!['password_changed_at']),
                      Icons.vpn_key_outlined,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFFB8860B)),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  IconData _getActionIcon(String? action) {
    if (action == null) return Icons.circle;
    
    if (action.contains('login')) return Icons.login;
    if (action.contains('logout')) return Icons.logout;
    if (action.contains('create')) return Icons.add_circle_outline;
    if (action.contains('update')) return Icons.edit_outlined;
    if (action.contains('delete')) return Icons.delete_outline;
    if (action.contains('post')) return Icons.publish;
    if (action.contains('unpost')) return Icons.unpublished;
    
    return Icons.circle;
  }
}
