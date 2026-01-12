import 'package:flutter/material.dart';
import '../api_service.dart';

class SecuritySessionsScreen extends StatefulWidget {
  const SecuritySessionsScreen({super.key});

  @override
  State<SecuritySessionsScreen> createState() => _SecuritySessionsScreenState();
}

class _SecuritySessionsScreenState extends State<SecuritySessionsScreen> {
  final ApiService _api = ApiService();
  bool _loading = true;
  bool _adminView = false;
  List<dynamic> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() => _loading = true);
    try {
      final data = await _api.getSessions(includeAll: _adminView);
      if (!mounted) return;
      setState(() => _sessions = data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تحميل الجلسات: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _terminate(int id) async {
    try {
      await _api.terminateSession(id.toString());
      await _loadSessions();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم إنهاء الجلسة')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إنهاء الجلسة: $e')));
    }
  }

  Future<void> _terminateAll() async {
    try {
      await _api.terminateAllSessions();
      await _loadSessions();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم إنهاء جميع الجلسات')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر إنهاء الجلسات: $e')));
    }
  }

  Widget _buildSessionCard(dynamic s) {
    return Card(
      child: ListTile(
        title: Text('جلسة #${s['id']} — IP: ${s['ip_address'] ?? '-'}'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (s['device_info'] != null) Text('الجهاز: ${s['device_info']}'),
            if (s['user_agent'] != null)
              Text(
                'المتصفح: ${s['user_agent']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            Text('الإنشاء: ${s['created_at'] ?? '-'}'),
            Text('آخر نشاط: ${s['last_activity'] ?? '-'}'),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (s['is_active'] == true)
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'إنهاء الجلسة',
                onPressed: () => _terminate(s['id'] as int),
              )
            else
              const Icon(Icons.check_circle, color: Colors.green),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('إدارة الجلسات'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSessions),
          IconButton(
            icon: Icon(_adminView ? Icons.visibility : Icons.visibility_off),
            tooltip: 'عرض كل الجلسات (للمسؤول)',
            onPressed: () {
              setState(() => _adminView = !_adminView);
              _loadSessions();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadSessions,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _terminateAll,
                        icon: const Icon(Icons.close_fullscreen),
                        label: const Text('إنهاء جميع الجلسات'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _adminView ? 'وضع المسؤول: كل الجلسات' : 'جلساتي فقط',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_sessions.isEmpty)
                    const Center(child: Text('لا توجد جلسات نشطة حالياً'))
                  else
                    ..._sessions.map(_buildSessionCard),
                ],
              ),
      ),
    );
  }
}
