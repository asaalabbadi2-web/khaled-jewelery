import 'package:flutter/material.dart';
import '../api_service.dart';

class TwoFASetupScreen extends StatefulWidget {
  const TwoFASetupScreen({super.key});

  @override
  State<TwoFASetupScreen> createState() => _TwoFASetupScreenState();
}

class _TwoFASetupScreenState extends State<TwoFASetupScreen> {
  final ApiService _api = ApiService();
  bool _loading = false;
  String? _secret;
  String? _otpUri;
  final _codeCtrl = TextEditingController();
  List<String> _recoveryCodes = [];

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startSetup() async {
    setState(() {
      _loading = true;
      _recoveryCodes = [];
    });
    try {
      final data = await _api.setup2FA();
      if (!mounted) return;
      setState(() {
        _secret = data['secret'] as String?;
        _otpUri = data['otp_uri'] as String?;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر إنشاء 2FA: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    setState(() => _loading = true);
    try {
      final data = await _api.verify2FA(_codeCtrl.text.trim());
      if (!mounted) return;
      setState(() {
        _recoveryCodes = (data['recovery_codes'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تفعيل التحقق الثنائي')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل التفعيل: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _disable() async {
    setState(() => _loading = true);
    try {
      await _api.disable2FA();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تعطيل التحقق الثنائي')),
      );
      setState(() {
        _secret = null;
        _otpUri = null;
        _recoveryCodes = [];
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('فشل التعطيل: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('التحقق الثنائي (2FA)'),
        actions: [IconButton(onPressed: _disable, icon: const Icon(Icons.lock_open))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'قم بإنشاء رمز 2FA ثم امسح QR أو أدخل السر في تطبيق المصادقة.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _loading ? null : _startSetup,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('إنشاء رمز جديد'),
          ),
          if (_secret != null) ...[
            const SizedBox(height: 16),
            SelectableText('السر: $_secret'),
            if (_otpUri != null) ...[
              const SizedBox(height: 8),
              SelectableText('رابط OTP: $_otpUri'),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _codeCtrl,
              decoration: const InputDecoration(
                labelText: 'أدخل رمز التحقق من التطبيق',
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loading ? null : _verify,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('تفعيل 2FA'),
            ),
          ],
          if (_recoveryCodes.isNotEmpty) ...[
            const Divider(height: 32),
            const Text('رموز الاسترداد (احفظها في مكان آمن):'),
            const SizedBox(height: 8),
            ..._recoveryCodes.map((c) => SelectableText('• $c')),
          ],
          if (_loading) const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }
}
