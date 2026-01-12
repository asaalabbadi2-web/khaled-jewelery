import 'package:flutter/material.dart';

import '../api_service.dart';

class UsernameRecoveryScreen extends StatefulWidget {
  const UsernameRecoveryScreen({super.key});

  @override
  State<UsernameRecoveryScreen> createState() => _UsernameRecoveryScreenState();
}

class _UsernameRecoveryScreenState extends State<UsernameRecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _identifierController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    try {
      final api = ApiService();
      final res = await api.forgotUsername(
        identifier: _identifierController.text.trim(),
      );

      if (!mounted) return;

      final msg =
          (res['message'] ?? 'تم إرسال اسم المستخدم إذا كانت البيانات صحيحة')
              .toString();

      // In dev mode, backend may return debug_username.
      final debugUsername = (res['debug_username'] ?? '').toString().trim();
      final display = debugUsername.isNotEmpty
          ? 'اسم المستخدم الخاص بك هو: $debugUsername'
          : msg;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(display)));

      if (debugUsername.isNotEmpty) {
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
        appBar: AppBar(title: const Text('استعادة اسم المستخدم')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'أدخل البريد الإلكتروني أو رقم الجوال المرتبط بالحساب، وسيتم إرسال اسم المستخدم.',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _identifierController,
                    decoration: const InputDecoration(
                      labelText: 'البريد الإلكتروني أو رقم الجوال',
                      prefixIcon: Icon(Icons.person_search),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'مطلوب';
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
                          : const Text('إرسال'),
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
