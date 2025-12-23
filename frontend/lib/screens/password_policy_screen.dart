import 'package:flutter/material.dart';

import '../api_service.dart';

class PasswordPolicyScreen extends StatefulWidget {
  const PasswordPolicyScreen({super.key});

  @override
  State<PasswordPolicyScreen> createState() => _PasswordPolicyScreenState();
}

class _PasswordPolicyScreenState extends State<PasswordPolicyScreen> {
  final ApiService _api = ApiService();
  final _minLengthCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  final _historyCtrl = TextEditingController();

  bool _requireUpper = true;
  bool _requireLower = true;
  bool _requireDigit = true;
  bool _requireSpecial = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _minLengthCtrl.dispose();
    _expiryCtrl.dispose();
    _historyCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await _api.getPasswordPolicy();
      final policy = data['policy'] as Map<String, dynamic>? ?? {};
      _minLengthCtrl.text = (policy['min_length'] ?? 8).toString();
      _expiryCtrl.text = (policy['expiry_days'] ?? 90).toString();
      _historyCtrl.text = (policy['history_count'] ?? 5).toString();
      _requireUpper = policy['require_uppercase'] ?? true;
      _requireLower = policy['require_lowercase'] ?? true;
      _requireDigit = policy['require_digit'] ?? true;
      _requireSpecial = policy['require_special'] ?? true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل السياسة: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final payload = {
        'min_length': int.tryParse(_minLengthCtrl.text) ?? 8,
        'expiry_days': int.tryParse(_expiryCtrl.text),
        'history_count': int.tryParse(_historyCtrl.text) ?? 5,
        'require_uppercase': _requireUpper,
        'require_lowercase': _requireLower,
        'require_digit': _requireDigit,
        'require_special': _requireSpecial,
      };
      await _api.updatePasswordPolicy(payload);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حفظ سياسة كلمة المرور')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر الحفظ: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildSwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile.adaptive(
      title: Text(label),
      value: value,
      onChanged: (val) => setState(() => onChanged(val)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سياسة كلمة المرور'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _minLengthCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'الحد الأدنى للطول',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _expiryCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'مدة الانتهاء بالأيام (0 = بدون)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _historyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'منع إعادة آخر (N) كلمات مرور',
                  ),
                ),
                const Divider(height: 32),
                _buildSwitch('تطلب حرف كبير', _requireUpper, (v) => _requireUpper = v),
                _buildSwitch('تطلب حرف صغير', _requireLower, (v) => _requireLower = v),
                _buildSwitch('تطلب رقم', _requireDigit, (v) => _requireDigit = v),
                _buildSwitch('تطلب رمز خاص', _requireSpecial, (v) => _requireSpecial = v),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('حفظ السياسة'),
                  ),
                ),
              ],
            ),
    );
  }
}
