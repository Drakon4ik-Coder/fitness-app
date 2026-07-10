import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/features/nutrition/account_page.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/settings/about_settings_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget wrap(Widget child) =>
      MaterialApp(theme: LuminaHealthTheme.dark(), home: child);

  Future<void> pumpAboutPage(
    WidgetTester tester, {
    Future<bool> Function(Uri)? openUrl,
    Future<String> Function()? loadVersion,
  }) async {
    enlargeView(tester);
    await tester.pumpWidget(
      wrap(
        AboutSettingsPage(
          loadVersion: loadVersion ?? () async => '1.2.3 (45)',
          openUrl: openUrl ?? (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the installed version', (tester) async {
    await pumpAboutPage(tester);

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('1.2.3 (45)'), findsOneWidget);
  });

  testWidgets('external rows open the expected URLs in the browser', (
    tester,
  ) async {
    final opened = <Uri>[];
    await pumpAboutPage(
      tester,
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );

    await tester.tap(find.text('Privacy policy'));
    await tester.tap(find.text('Powered by Open Food Facts'));
    await tester.tap(find.text('Open Database License (ODbL)'));
    await tester.pumpAndSettle();

    expect(opened, [
      Uri.parse(kPrivacyPolicyUrl),
      Uri.parse(kOpenFoodFactsUrl),
      Uri.parse(kOdblLicenseUrl),
    ]);
  });

  testWidgets('failed URL launch surfaces a snackbar instead of nothing', (
    tester,
  ) async {
    await pumpAboutPage(tester, openUrl: (_) async => false);

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open'), findsOneWidget);
  });

  testWidgets('licenses row opens the Flutter license page with Symbio entry', (
    tester,
  ) async {
    await pumpAboutPage(tester);

    await tester.tap(find.text('Open-source licenses'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Symbio'), findsWidgets);
    expect(find.text('© 2026 Symbio · Apache License 2.0'), findsOneWidget);
  });

  testWidgets('settings hub has an About row that pushes the About page', (
    tester,
  ) async {
    enlargeView(tester);

    // Resolves every request so the hub's startup /me fetch doesn't hang.
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'email': 'me@example.com', 'display_name': 'Casey'},
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      wrap(
        AccountPage(
          accessToken: 'token',
          preferencesApi: PreferencesApiService(accessToken: 'token'),
          authService: AuthService(dio: dio),
          onLogout: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('About Symbio'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutSettingsPage), findsOneWidget);
  });
}
