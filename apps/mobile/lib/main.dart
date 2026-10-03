import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'core/app_log.dart';
import 'core/auth_interceptor.dart';
import 'core/auth_service.dart';
import 'core/auth_storage.dart';
import 'core/environment.dart';
import 'core/policy_consent_gate.dart';
import 'core/update_gate.dart';
import 'core/version_check_service.dart';
import 'features/login_page.dart';
import 'features/main_shell.dart';
import 'ui_components/ui_components.dart';
import 'ui_system/lumina_health_theme.dart';

// coverage:ignore-start
// Process bootstrap: runApp plus optional Sentry init. It runs on every app
// launch and can't run inside a widget test (it would replace the test's own
// binding), so it's excluded from the coverage gate (KAN-131). Everything it
// launches (FitnessApp and down) is covered by the widget tests.
Future<void> main() async {
  // Crash reporting is opt-in per build (--dart-define=SENTRY_DSN=...) and
  // never enabled for local runs: dev sessions against localhost would only
  // add noise to the shared Sentry projects. Staging and prod builds report
  // to the same project, separated by the `environment` tag (= APP_ENV).
  final sentryDsn = EnvironmentConfig.sentryDsn;
  if (sentryDsn.isEmpty || EnvironmentConfig.environmentName == 'local') {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const FitnessApp());
    return;
  }

  await SentryFlutter.init(
    (options) {
      options.dsn = sentryDsn;
      options.environment = EnvironmentConfig.environmentName;
      options.tracesSampleRate = 0.1;
    },
    appRunner: () {
      // Swallowed service-layer errors (typed ApiExceptions the UI degrades
      // gracefully) become breadcrumbs, not events: they are context for the
      // next real crash, not incidents on their own.
      appErrorLogger = (context, error, stackTrace) {
        unawaited(
          Sentry.addBreadcrumb(
            Breadcrumb(
              category: context,
              message: error.toString(),
              level: SentryLevel.warning,
            ),
          ),
        );
      };
      runApp(const FitnessApp());
    },
  );
}
// coverage:ignore-end

class FitnessApp extends StatelessWidget {
  const FitnessApp({super.key, this.versionService});

  /// Injected by tests; defaults to the real /health/ probe (KAN-100).
  final VersionCheckService? versionService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Symbio',
      // Dark-only design system: `theme` (the light slot) is set to the dark
      // theme so the app always renders dark regardless of OS brightness.
      theme: LuminaHealthTheme.dark(),
      // The forced-update gate wraps the whole app (not just the signed-in
      // shell) so a too-old build is blocked before login can even start.
      home: UpdateGate(versionService: versionService, child: const AuthGate()),
    );
  }
}

/// Builds the signed-in shell; injectable so tests can stand in for
/// [MainShell], which opens the on-device databases.
typedef ShellBuilder =
    Widget Function(
      String accessToken,
      Future<void> Function() onLogout,
      AuthInterceptor? authInterceptor,
    );

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    this.authStorage,
    this.authService,
    this.shellBuilder,
  });

  final AuthStorage? authStorage;
  final AuthService? authService;
  final ShellBuilder? shellBuilder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AuthStorage _authStorage = widget.authStorage ?? AuthStorage();
  late final AuthService _authService = widget.authService ?? AuthService();

  bool _isLoading = true;
  String? _accessToken;
  AuthInterceptor? _authInterceptor;

  @override
  void initState() {
    super.initState();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final token = await _authStorage.getAccessToken();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = token;
      _authInterceptor = token != null
          ? AuthInterceptor(
              storage: _authStorage,
              authService: _authService,
              onSessionExpired: _handleLogout,
              accessToken: token,
            )
          : null;
      _isLoading = false;
    });
    if (token != null) unawaited(_reportTimezone(token));
  }

  Future<void> _handleLoggedIn() async {
    final token = await _authStorage.getAccessToken();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = token;
      _authInterceptor = token != null
          ? AuthInterceptor(
              storage: _authStorage,
              authService: _authService,
              onSessionExpired: _handleLogout,
              accessToken: token,
            )
          : null;
    });
    if (token != null) unawaited(_reportTimezone(token));
  }

  /// Tell the backend the device's IANA timezone so it can convert UTC meal
  /// timestamps back to the user's wall clock. Best-effort and non-blocking.
  Future<void> _reportTimezone(String accessToken) async {
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      await _authService.updateTimezone(
        accessToken: accessToken,
        timezone: timezone,
      );
    } catch (_) {
      // Non-critical; the backend keeps the last known zone (UTC by default).
    }
  }

  Future<void> _handleLogout() async {
    await _authStorage.clear();
    if (!mounted) {
      return;
    }
    setState(() {
      _accessToken = null;
      _authInterceptor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      // Mirror the native splash (brand background + SYMBIO mark) so there is
      // no jarring flash between the OS splash and the Flutter loading state.
      final colorScheme = Theme.of(context).colorScheme;
      return Scaffold(
        backgroundColor: colorScheme.surfaceContainerLowest,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(),
              const SizedBox(height: 32),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_accessToken == null) {
      return LoginPage(
        authService: _authService,
        authStorage: _authStorage,
        onLoggedIn: _handleLoggedIn,
      );
    }

    // The consent gate sits inside AuthGate (it needs a signed-in user):
    // Google sign-ins get no signup checkboxes, and a policy bump re-prompts
    // existing users — both consent here before the shell's API use (KAN-103).
    return PolicyConsentGate(
      accessToken: _accessToken!,
      authService: _authService,
      child:
          widget.shellBuilder?.call(
            _accessToken!,
            _handleLogout,
            _authInterceptor,
          ) ??
          MainShell(
            accessToken: _accessToken!,
            onLogout: _handleLogout,
            authInterceptor: _authInterceptor,
          ),
    );
  }
}
