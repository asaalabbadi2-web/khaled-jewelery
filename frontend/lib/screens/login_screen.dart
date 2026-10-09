import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../widgets/app_logo.dart';
import '../widgets/gold_price_ticker_bar.dart';
import 'forgot_password_screen.dart';

/// The sign-in screen.
///
/// It says what stands in the way, as the server says it (the owner,
/// 10 Oct 2026): a wrong password, too many attempts (the button waits, and
/// says for how long), an inactive account, an account that asks for its
/// verification code (the field appears), a server nobody answers (the status
/// below is tapped to ask again). It used to call every refusal a wrong
/// password, and clear what was typed. Its colors come from the theme
/// (ADR-038): it reads in the dark mode too.
class LoginScreen extends StatefulWidget {
  /// Asks whether the server answers; tests pass their own. Default: GET /health.
  final Future<bool> Function()? pingServer;

  const LoginScreen({super.key, this.pingServer});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _ServerStatus { checking, online, offline }

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  /// The server counts five failed attempts a minute (auth_routes._rate_limit_login).
  static const _waitAfterTooManyAttempts = 60;

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _otpFocusNode = FocusNode();
  // FocusNode ثابت للـ KeyboardListener بدلاً من إنشائه في كل build
  final _kbFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _askOtp = false; // the account asked for its verification code
  String? _usernameError; // خطأ حقل اسم المستخدم
  String? _loginError; // خطأ المصادقة (أسفل كلمة المرور)
  String? _otpError; // خطأ رمز التحقق
  int _waitSeconds = 0; // too many attempts: the button waits this long
  Timer? _waitTimer;
  _ServerStatus _serverStatus = _ServerStatus.checking;

  // ── Animations ─────────────────────────────────────────────────────────
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;

  late AnimationController _shimmerCtrl;

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _fadeCtrl.forward();

    _shakeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -9.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -9.0, end: 9.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 9.0, end: -9.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -9.0, end: 9.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 9.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.easeInOut));

    _shimmerCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));

    for (final node in [_usernameFocusNode, _passwordFocusNode, _otpFocusNode]) {
      node.addListener(_onFocusChange);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _usernameFocusNode.requestFocus();
    });
    _pingServer();
  }

  bool get _anyFieldFocused =>
      _usernameFocusNode.hasFocus ||
      _passwordFocusNode.hasFocus ||
      _otpFocusNode.hasFocus;

  void _onFocusChange() {
    if (_anyFieldFocused) {
      _shimmerCtrl.repeat(reverse: true);
    } else {
      _shimmerCtrl.stop();
      _shimmerCtrl.value = 0;
    }
    // نُعيد البناء فقط لتحديث لون الأيقونة/الحدود عند تغيّر التركيز
    // الأخطاء تُمسح عند الكتابة (onChanged) لا عند التركيز
    setState(() {});
  }

  Future<bool> _defaultPing() async {
    final base = ApiService.resolvedBaseUrl.replaceFirst(RegExp(r'/api$'), '');
    final res = await http
        .get(Uri.parse('$base/health'))
        .timeout(const Duration(seconds: 5));
    return res.statusCode < 500;
  }

  Future<void> _pingServer() async {
    if (mounted) setState(() => _serverStatus = _ServerStatus.checking);
    bool online;
    try {
      online = await (widget.pingServer ?? _defaultPing)();
    } catch (_) {
      online = false;
    }
    if (mounted) {
      setState(() =>
          _serverStatus = online ? _ServerStatus.online : _ServerStatus.offline);
    }
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    for (final node in [_usernameFocusNode, _passwordFocusNode, _otpFocusNode]) {
      node
        ..removeListener(_onFocusChange)
        ..dispose();
    }
    _kbFocusNode.dispose();
    _fadeCtrl.dispose();
    _shakeCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  // ── Validation يدوي — بدون Form لتجنب HTML form-submit على Flutter Web ──
  bool _validate() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty) {
      setState(() {
        _usernameError = 'اسم المستخدم مطلوب';
        _loginError = null;
      });
      _usernameFocusNode.requestFocus();
      return false;
    }
    if (password.isEmpty) {
      setState(() {
        _loginError = 'كلمة المرور مطلوبة';
        _usernameError = null;
      });
      _passwordFocusNode.requestFocus();
      return false;
    }
    if (_askOtp && _otpController.text.trim().isEmpty) {
      setState(() {
        _otpError = 'رمز التحقق مطلوب';
        _loginError = null;
      });
      _otpFocusNode.requestFocus();
      return false;
    }
    return true;
  }

  void _startWait() {
    _waitTimer?.cancel();
    setState(() => _waitSeconds = _waitAfterTooManyAttempts);
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _waitSeconds = _waitSeconds - 1);
      if (_waitSeconds <= 0) {
        timer.cancel();
        setState(() => _loginError = null);
      }
    });
  }

  Future<void> _attemptLogin() async {
    if (_waitSeconds > 0) return;
    setState(() {
      _loginError = null;
      _usernameError = null;
      _otpError = null;
    });
    if (!_validate()) return;

    final auth = context.read<AuthProvider>();
    final success = await auth.login(
      _usernameController.text.trim(),
      _passwordController.text.trim(),
      otp: _askOtp ? _otpController.text.trim() : null,
    );
    if (!mounted) return;

    if (success) {
      // أخبر المتصفح بحفظ اسم المستخدم في autocomplete
      TextInput.finishAutofillContext(shouldSave: true);
      return;
    }

    // لا نستدعي finishAutofillContext(false) هنا —
    // يُعيد المتصفح على الويب مسح حقول AutofillGroup كليهما عند استدعائه.
    final refusal = auth.loginRefusal;
    switch (refusal?.code) {
      case 'otp_required':
        // Right credentials, a second step: keep them, ask for the code.
        setState(() {
          _askOtp = true;
          _loginError = null;
        });
        _otpFocusNode.requestFocus();
        return;
      case 'otp_invalid':
        _otpController.clear();
        setState(() => _otpError = refusal!.message);
        _otpFocusNode.requestFocus();
        await _shakeCtrl.forward(from: 0);
        return;
      case 'rate_limited':
        setState(() => _loginError = refusal!.message);
        _startWait();
        return;
      case 'unreachable':
      case 'unavailable':
        // Nothing was refused, so nothing typed is lost.
        setState(() {
          _loginError = refusal!.message;
          _serverStatus = _ServerStatus.offline;
        });
        return;
      default:
        _passwordController.clear();
        setState(() => _loginError =
            refusal?.message ?? 'اسم المستخدم أو كلمة المرور غير صحيحة');
        _passwordFocusNode.requestFocus();
        await _shakeCtrl.forward(from: 0);
    }
  }

  void _clearFields() {
    _usernameController.clear();
    _passwordController.clear();
    _otpController.clear();
    setState(() {
      _loginError = null;
      _usernameError = null;
      _otpError = null;
      _askOtp = false;
    });
    _usernameFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLoading = context.watch<AuthProvider>().isLoading;
    final settings = context.watch<SettingsProvider>();
    // The background: the theme's gold deepening toward the corner it is lit
    // from; the card and the words on it are the theme's surface and text.
    final backgroundEnd = Color.lerp(scheme.primary, scheme.scrim, 0.35)!;

    return KeyboardListener(
      focusNode: _kbFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _clearFields();
        }
      },
      child: Scaffold(
        body: FadeTransition(
          opacity: _fadeAnim,
          child: Stack(
            children: [
              // ── خلفية ─────────────────────────────────────────────
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primary, backgroundEnd],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                ),
              ),

              // ── ماسة هندسية — زخرفة وحيدة ────────────────────────
              Positioned(
                top: -80,
                right: -80,
                child: Transform.rotate(
                  angle: 0.7854,
                  child: Container(
                    width: 300,
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: scheme.onPrimary.withValues(alpha: 0.10),
                          width: 1.5),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -20,
                right: -20,
                child: Transform.rotate(
                  angle: 0.7854,
                  child: Container(
                    width: 170,
                    height: 170,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: scheme.onPrimary.withValues(alpha: 0.06),
                          width: 1),
                    ),
                  ),
                ),
              ),

              // ── المحتوى ───────────────────────────────────────────
              Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildCard(theme, isLoading),
                            const SizedBox(height: 20),
                            _buildFooter(theme),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (settings.showGoldPriceTickerOnLogin)
                    GoldPriceTickerBar(
                      isArabic: true,
                      currencySymbol: settings.currencySymbolText,
                      isNewSar: settings.currencyIsNewSar,
                      refreshInterval: settings.goldPriceTickerRefreshInterval,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(ThemeData theme, bool isLoading) {
    final scheme = theme.colorScheme;
    final waiting = _waitSeconds > 0;
    return AnimatedBuilder(
      animation: Listenable.merge([_shakeCtrl, _shimmerCtrl]),
      builder: (context, _) {
        return Card(
          elevation: 6,
          shadowColor: scheme.shadow.withValues(alpha: 0.22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
                color: scheme.primary.withValues(alpha: 0.18), width: 1),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── شعار ────────────────────────────────────────
                  const Center(child: AppLogo.gold(width: 120, height: 120)),
                  const SizedBox(height: 12),

                  Text(
                    'Khaled Jewellery',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                      letterSpacing: 0.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Gold Management ERP System',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.3,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  // ── فاصل ◇ ──────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    child: Row(
                      children: [
                        Expanded(
                            child: Divider(
                                color: scheme.outlineVariant, thickness: 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(Icons.diamond_outlined,
                              size: 14, color: scheme.outline),
                        ),
                        Expanded(
                            child: Divider(
                                color: scheme.outlineVariant, thickness: 1)),
                      ],
                    ),
                  ),

                  // ── اسم المستخدم ─────────────────────────────────
                  _fieldLabel('اسم المستخدم', scheme),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('login-username'),
                    controller: _usernameController,
                    focusNode: _usernameFocusNode,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.text,
                    // autofillHints بدون AutofillGroup: يُفعّل autocomplete المتصفح
                    // دون إنشاء <form> HTML يُسبّب page reload عند Enter
                    autofillHints: const [AutofillHints.username],
                    onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                    onChanged: (_) {
                      if (_usernameError != null) {
                        setState(() => _usernameError = null);
                      }
                    },
                    style: TextStyle(color: scheme.onSurface, fontSize: 15),
                    decoration: _fieldDecoration(
                      scheme,
                      icon: Icons.person_outline,
                      hasFocus: _usernameFocusNode.hasFocus,
                      hasError: _usernameError != null,
                    ),
                  ),
                  if (_usernameError != null)
                    _inlineError(_usernameError!, scheme),
                  const SizedBox(height: 18),

                  // ── كلمة المرور ──────────────────────────────────
                  _fieldLabel('كلمة المرور', scheme),
                  const SizedBox(height: 6),
                  Transform.translate(
                    offset: Offset(_shakeAnim.value, 0),
                    child: TextField(
                      key: const Key('login-password'),
                      controller: _passwordController,
                      focusNode: _passwordFocusNode,
                      obscureText: _obscurePassword,
                      textInputAction:
                          _askOtp ? TextInputAction.next : TextInputAction.go,
                      onSubmitted: (_) => _askOtp
                          ? _otpFocusNode.requestFocus()
                          : _attemptLogin(),
                      onChanged: (_) {
                        if (_loginError != null && !waiting) {
                          setState(() => _loginError = null);
                        }
                      },
                      keyboardType: TextInputType.visiblePassword,
                      style: TextStyle(color: scheme.onSurface, fontSize: 15),
                      decoration: _fieldDecoration(
                        scheme,
                        icon: Icons.lock_outline,
                        hasFocus: _passwordFocusNode.hasFocus,
                        hasError: _loginError != null,
                        suffix: IconButton(
                          tooltip: _obscurePassword
                              ? 'إظهار كلمة المرور'
                              : 'إخفاء كلمة المرور',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 22,
                            color: scheme.onSurfaceVariant,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                    ),
                  ),
                  if (_loginError != null)
                    _inlineError(_loginError!, scheme,
                        key: const Key('login-error')),

                  // ── رمز التحقق — يظهر حين يطلبه الحساب ───────────
                  if (_askOtp) ...[
                    const SizedBox(height: 18),
                    _fieldLabel('رمز التحقق (من تطبيق المصادقة)', scheme),
                    const SizedBox(height: 6),
                    TextField(
                      key: const Key('login-otp'),
                      controller: _otpController,
                      focusNode: _otpFocusNode,
                      textInputAction: TextInputAction.go,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      autofillHints: const [AutofillHints.oneTimeCode],
                      onSubmitted: (_) => _attemptLogin(),
                      onChanged: (_) {
                        if (_otpError != null) setState(() => _otpError = null);
                      },
                      style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 18,
                          letterSpacing: 4),
                      decoration: _fieldDecoration(
                        scheme,
                        icon: Icons.shield_outlined,
                        hasFocus: _otpFocusNode.hasFocus,
                        hasError: _otpError != null,
                      ),
                    ),
                    if (_otpError != null)
                      _inlineError(_otpError!, scheme,
                          key: const Key('login-otp-error')),
                  ],

                  // ── نسيت كلمة المرور ─────────────────────────────
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: isLoading
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const ForgotPasswordScreen())),
                      child: Text(
                        'نسيت كلمة المرور؟',
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── دخول النظام ──────────────────────────────────
                  SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      key: const Key('login-submit'),
                      onPressed: isLoading || waiting ? null : _attemptLogin,
                      icon: isLoading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: scheme.onPrimary),
                            )
                          : Icon(waiting ? Icons.timer_outlined : Icons.login_rounded,
                              size: 22),
                      label: Text(
                        isLoading
                            ? 'جارٍ الدخول...'
                            : waiting
                                ? 'انتظر $_waitSeconds ثانية'
                                : 'دخول النظام',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
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

  /// The server's state, said on a surface of its own so it reads on the gold
  /// in both modes; tapped when nobody answers, it asks again.
  Widget _buildFooter(ThemeData theme) {
    final scheme = theme.colorScheme;
    final tones = AppSemanticColors.of(context);
    final (tone, label) = switch (_serverStatus) {
      _ServerStatus.checking => (tones.warning, 'جارٍ الفحص...'),
      _ServerStatus.online => (tones.ready, 'متصل'),
      _ServerStatus.offline => (tones.blocked, 'غير متصل — اضغط لإعادة الفحص'),
    };
    final status = Material(
      color: scheme.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        key: const Key('login-server-status'),
        borderRadius: BorderRadius.circular(20),
        onTap: _serverStatus == _ServerStatus.checking ? null : _pingServer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text('الخادم: $label',
                  style: TextStyle(fontSize: 12, color: scheme.onSurface)),
              if (_serverStatus == _ServerStatus.offline) ...[
                const SizedBox(width: 6),
                Icon(Icons.refresh, size: 14, color: scheme.onSurfaceVariant),
              ],
            ],
          ),
        ),
      ),
    );

    return Column(
      children: [
        status,
        const SizedBox(height: 6),
        Text(
          'Version 1.0.0  ·  © 2026 Khaled Jewellery ERP',
          style: TextStyle(
              fontSize: 11, color: scheme.onPrimary.withValues(alpha: 0.75)),
        ),
      ],
    );
  }

  Widget _fieldLabel(String text, ColorScheme scheme) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      );

  Widget _inlineError(String message, ColorScheme scheme, {Key? key}) => Padding(
        padding: const EdgeInsets.only(top: 5, right: 4),
        child: Text(
          message,
          key: key,
          style: TextStyle(fontSize: 12, color: scheme.error),
          textAlign: TextAlign.right,
        ),
      );

  InputDecoration _fieldDecoration(
    ColorScheme scheme, {
    required IconData icon,
    required bool hasFocus,
    bool hasError = false,
    Widget? suffix,
  }) {
    const radius = BorderRadius.all(Radius.circular(10));
    final shimmerColor = Color.lerp(
        scheme.primary, scheme.primaryContainer, _shimmerCtrl.value)!;
    final activeBorderColor = hasError ? scheme.error : shimmerColor;

    return InputDecoration(
      prefixIcon: Icon(icon,
          size: 22,
          color: hasFocus
              ? (hasError ? scheme.error : shimmerColor)
              : scheme.onSurfaceVariant),
      suffixIcon: suffix,
      border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(
              color: hasError ? scheme.error : scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: activeBorderColor, width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: radius, borderSide: BorderSide(color: scheme.error)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: scheme.error, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      filled: true,
      fillColor: scheme.surfaceContainerLow,
    );
  }
}
