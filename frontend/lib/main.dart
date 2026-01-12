import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'src/url_strategy_stub.dart'
    if (dart.library.html) 'src/url_strategy_web.dart'
    as url_strategy;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'providers/settings_provider.dart';
import 'providers/quick_actions_provider.dart';
import 'providers/auth_provider.dart';
import 'theme/app_theme.dart'; // 🆕 نظام الثيم الموحد
import 'screens/home_screen_enhanced.dart';
import 'screens/add_item_screen_enhanced.dart';
import 'screens/items_screen_enhanced.dart';
import 'api_service.dart';
import 'screens/login_screen.dart';
import 'screens/change_password_screen.dart';
import 'screens/initial_setup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Make Flutter web use clean paths like /setup instead of /#/setup.
  // Set web URL strategy only when running on web.
  url_strategy.setPathUrlStrategy();

  final authProvider = AuthProvider();
  await authProvider.init();

  // معالجة الأخطاء التي يلتقطها Flutter
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      // في وضع التطوير، اطبع الخطأ للتشخيص
      debugPrint('🔴 Flutter Error: ${details.exception}');
      debugPrint('Stack trace: ${details.stack}');
    }
  };

  // معالجة الأخطاء التي لا يلتقطها Flutter (مثل async errors)
  PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      debugPrint('🔴 Uncaught Error: $error');
      debugPrint('Stack trace: $stack');
    }
    return true; // يشير إلى أن الخطأ تم معالجته
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
        ChangeNotifierProvider(
          create: (context) {
            final provider = SettingsProvider();
            final auth = context.read<AuthProvider>();
            provider.loadSettings(
              fetchRemote: auth.hasPermission('system.settings'),
            );
            return provider;
          },
        ),
        ChangeNotifierProvider(
          create: (context) => ThemeProvider(), // 🆕 مزود الثيم
        ),
        ChangeNotifierProvider(
          create: (context) =>
              QuickActionsProvider(), // 🆕 مزود الأزرار السريعة
        ),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Locale _locale = const Locale('ar');

  void _toggleLocale() {
    setState(() {
      _locale = _locale.languageCode == 'ar'
          ? const Locale('en')
          : const Locale('ar');
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return IdleLogoutWrapper(
      child: MaterialApp(
        title: 'مجوهرات خالد',
        builder: (context, widget) {
          // تخصيص widget الخطأ
          ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
            return Scaffold(
              backgroundColor: const Color(0xFF222222),
              body: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red, width: 2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 64,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        kDebugMode ? 'خطأ في العرض' : 'حدث خطأ',
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 12),
                        Text(
                          errorDetails.exception.toString(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          };

          if (widget != null) return widget;
          throw StateError('widget is null');
        },

        // 🎨 نظام الثيم الموحد
        theme: LightTheme.theme, // الوضع الفاتح
        darkTheme: DarkTheme.theme, // الوضع الداكن
        themeMode: themeProvider.themeMode, // الوضع الحالي

        locale: _locale,
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routes: {
          '/add_item': (context) => Consumer<AuthProvider>(
            builder: (context, auth, _) {
              if (auth.isAuthenticated) {
                return AddItemScreenEnhanced(api: ApiService());
              }
              return const LoginScreen();
            },
          ),
          '/items': (context) => Consumer<AuthProvider>(
            builder: (context, auth, _) {
              if (auth.isAuthenticated) {
                return ItemsScreenEnhanced(api: ApiService());
              }
              return const LoginScreen();
            },
          ),
          '/setup': (context) => AuthGate(
            onToggleLocale: _toggleLocale,
            isArabic: _locale.languageCode == 'ar',
          ),
        },
        onUnknownRoute: (settings) {
          // معالجة الصفحات غير الموجودة (404)
          // إعادة التوجيه للصفحة الرئيسية تلقائياً
          return MaterialPageRoute(
            builder: (context) => AuthGate(
              onToggleLocale: _toggleLocale,
              isArabic: _locale.languageCode == 'ar',
            ),
          );
        },
        home: AuthGate(
          onToggleLocale: _toggleLocale,
          isArabic: _locale.languageCode == 'ar',
        ),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class IdleLogoutWrapper extends StatefulWidget {
  final Widget child;

  const IdleLogoutWrapper({super.key, required this.child});

  @override
  State<IdleLogoutWrapper> createState() => _IdleLogoutWrapperState();
}

class _IdleLogoutWrapperState extends State<IdleLogoutWrapper>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime _lastActivityAt = DateTime.now();

  void _onAuthInvalidation() {
    final err = ApiService.authInvalidation.value;
    if (err == null) return;
    // Clear first to prevent re-entrancy.
    ApiService.authInvalidation.value = null;
    final auth = context.read<AuthProvider>();
    if (auth.isAuthenticated) {
      auth.logout();
    }
  }

  bool _onKeyEvent(KeyEvent event) {
    _recordActivity();
    return false;
  }

  Duration _idleTimeoutFor(SettingsProvider settings) {
    if (!settings.idleTimeoutEnabled) {
      return Duration.zero;
    }
    final minutes = settings.idleTimeoutMinutes;
    if (minutes <= 0) {
      return Duration.zero;
    }
    return Duration(minutes: minutes);
  }

  void _recordActivity() {
    _lastActivityAt = DateTime.now();
    _restartTimerIfNeeded();
  }

  void _restartTimerIfNeeded() {
    if (!mounted) return;

    final auth = context.read<AuthProvider>();
    final settings = context.read<SettingsProvider>();
    if (!auth.isAuthenticated) {
      _timer?.cancel();
      _timer = null;
      return;
    }

    if (!settings.idleTimeoutEnabled) {
      _timer?.cancel();
      _timer = null;
      return;
    }

    final timeout = _idleTimeoutFor(settings);
    if (timeout == Duration.zero) {
      return;
    }

    _timer?.cancel();
    _timer = Timer(timeout, () {
      _handleTimeout();
    });
  }

  Future<void> _handleTimeout() async {
    if (!mounted) return;

    final auth = context.read<AuthProvider>();
    if (!auth.isAuthenticated) return;

    final settings = context.read<SettingsProvider>();

    final timeout = _idleTimeoutFor(settings);
    if (timeout == Duration.zero) return;

    final elapsed = DateTime.now().difference(_lastActivityAt);
    if (elapsed < timeout) {
      _restartTimerIfNeeded();
      return;
    }

    await auth.logout();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    ApiService.authInvalidation.addListener(_onAuthInvalidation);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restartTimerIfNeeded();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recordActivity();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    ApiService.authInvalidation.removeListener(_onAuthInvalidation);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AuthProvider, SettingsProvider>(
      builder: (context, auth, settings, _) {
        // Keep timer state synced with auth/settings changes.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _restartTimerIfNeeded();
        });

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _recordActivity(),
          onPointerSignal: (_) => _recordActivity(),
          child: widget.child,
        );
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  final VoidCallback? onToggleLocale;
  final bool isArabic;

  const AuthGate({
    super.key,
    required this.onToggleLocale,
    required this.isArabic,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (auth.isLoading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (auth.needsSetup) {
          // Keep the URL in sync with the setup requirement (web-first).
          final currentRoute = ModalRoute.of(context)?.settings.name;
          if (currentRoute != '/setup') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              Navigator.of(context).pushReplacementNamed('/setup');
            });
          }
          return const InitialSetupScreen();
        }

        // In development, allow quick access to the app without login only when
        // a developer explicitly enables the bypass via a compile-time flag.
        // Use `--dart-define=BYPASS_AUTH_FOR_DEVELOPMENT=true` when running.
        const bool bypassFlag = bool.fromEnvironment(
          'BYPASS_AUTH_FOR_DEVELOPMENT',
          defaultValue: false,
        );

        if (auth.isAuthenticated ||
            (kDebugMode && bypassFlag && !auth.needsSetup)) {
          if (auth.isAuthenticated && auth.mustChangePassword) {
            return const ChangePasswordScreen(force: true);
          }
          return HomeScreenEnhanced(
            onToggleLocale: onToggleLocale,
            isArabic: isArabic,
          );
        }
        return const LoginScreen();
      },
    );
  }
}
