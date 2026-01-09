import 'package:flutter/material.dart';

import '../api_service.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
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
      final res = await api.forgotPassword(
        identifier: _identifierController.text.trim(),
      );

      if (!mounted) return;

      final debugOtp = (res['debug_otp'] ?? '').toString().trim();
      final message = (res['message'] ?? 'تم إرسال رمز إعادة التعيين').toString();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResetPasswordConfirmScreen(
            identifier: _identifierController.text.trim(),
            debugOtp: debugOtp.isNotEmpty ? debugOtp : null,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('نسيت كلمة المرور')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'أدخل البريد الإلكتروني أو اسم المستخدم. سيتم إرسال رمز صالح لمدة 15 دقيقة إلى البريد المسجل بالحساب. (حالياً الإرسال عبر البريد فقط)',
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _identifierController,
                    decoration: const InputDecoration(
                      labelText: 'البريد الإلكتروني أو اسم المستخدم',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                    validator: (v) {
                      final value = (v ?? '').trim();
                      if (value.isEmpty) return 'مطلوب';
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
                          : const Text('إرسال الرمز'),
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

class ResetPasswordConfirmScreen extends StatefulWidget {
  final String identifier;
  final String? debugOtp;

  const ResetPasswordConfirmScreen({
    super.key,
    required this.identifier,
    this.debugOtp,
  });

  @override
  State<ResetPasswordConfirmScreen> createState() => _ResetPasswordConfirmScreenState();
}

class _ResetPasswordConfirmScreenState extends State<ResetPasswordConfirmScreen> {
  final _formKey = GlobalKey<FormState>();
  final _otpController = TextEditingController();
  final _newController = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.debugOtp != null && widget.debugOtp!.isNotEmpty) {
      _otpController.text = widget.debugOtp!;
    }
  }

  @override
  void dispose() {
    _otpController.dispose();
    _newController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    try {
      final api = ApiService();
      await api.confirmPasswordReset(
        otpOrToken: _otpController.text.trim(),
        newPassword: _newController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت إعادة تعيين كلمة المرور بنجاح')),
      );
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('إعادة تعيين كلمة المرور')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('أدخل الرمز المرسل، ثم اختر كلمة مرور جديدة.'),
                  if (widget.debugOtp != null && widget.debugOtp!.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'ملاحظة تطوير: تم تعبئة الرمز تلقائياً لأن AUTH_DEBUG_RETURN_SECRETS مفعّل.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _otpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'الرمز (OTP)',
                      prefixIcon: Icon(Icons.password),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'مطلوب';
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
                      if (v == null || v.trim().isEmpty) return 'مطلوب';
                      if (v.trim().length < 6) return 'يجب ألا تقل عن 6 أحرف';
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
                          : const Text('تأكيد'),
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
