import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';

class ChangePasswordScreen extends StatefulWidget {
  final bool force;

  const ChangePasswordScreen({super.key, this.force = false});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _oldController = TextEditingController();
  final _newController = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    super.dispose();
  }

  Future<String?> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('jwt_token') ?? prefs.getString('auth_token');
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    try {
      final token = await _loadToken();
      if (token == null || token.isEmpty) {
        throw Exception('لا توجد جلسة صالحة. الرجاء تسجيل الدخول مرة أخرى');
      }

      final api = ApiService();
      await api.changePassword(
        token,
        _oldController.text.trim(),
        _newController.text.trim(),
      );

      if (!mounted) return;
      context.read<AuthProvider>().clearMustChangePassword();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تغيير كلمة المرور بنجاح')),
      );

      if (widget.force) {
        // When forced, just pop back to AuthGate (Home will appear).
        Navigator.of(context).maybePop();
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.force,
          title: Text(
            widget.force ? 'تعيين كلمة مرور جديدة' : 'تغيير كلمة المرور',
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.force)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        'لأسباب أمنية، يجب تغيير كلمة المرور المؤقتة قبل المتابعة.',
                      ),
                    ),
                  TextFormField(
                    controller: _oldController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'كلمة المرور الحالية',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'مطلوب';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _newController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'كلمة المرور الجديدة',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'مطلوب';
                      }
                      if (v.trim().length < 6) {
                        return 'يجب ألا تقل عن 6 أحرف';
                      }
                      return null;
                    },
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('حفظ'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
