import 'package:dio/dio.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/google_auth_service.dart';
import 'package:fitness_app/features/nutrition/settings/profile_settings_page.dart';
import 'package:fitness_app/ui_system/lumina_health_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Dio whose requests are all resolved by [onRequest], for stubbing the
/// page's network calls without hitting a server.
Dio _stubDio(
  void Function(RequestOptions, RequestInterceptorHandler) onRequest,
) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: onRequest));
  return dio;
}

/// Stubs /auth/me and DELETE /auth/me: the delete succeeds only with
/// [acceptedPassword] or [acceptedIdToken]; anything else gets the backend's
/// vague 403.
Dio _accountDio({
  bool hasPassword = true,
  String? acceptedPassword,
  String? acceptedIdToken,
  List<Map<String, dynamic>>? deleteBodies,
}) {
  return _stubDio((options, handler) {
    if (options.method == 'DELETE') {
      final body = (options.data as Map).cast<String, dynamic>();
      deleteBodies?.add(body);
      final ok =
          (acceptedPassword != null && body['password'] == acceptedPassword) ||
          (acceptedIdToken != null && body['id_token'] == acceptedIdToken);
      if (ok) {
        handler.resolve(Response(requestOptions: options, statusCode: 204));
      } else {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: options,
              statusCode: 403,
              data: {'detail': 'Re-authentication failed.'},
            ),
          ),
        );
      }
      return;
    }
    handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'email': 'me@example.com',
          'display_name': 'Casey',
          'username': '',
          'has_password': hasPassword,
        },
      ),
    );
  });
}

class _FakeGoogleAuthService extends GoogleAuthService {
  _FakeGoogleAuthService(this.token);

  final String? token;
  int calls = 0;

  @override
  Future<String?> signInAndGetToken() async {
    calls += 1;
    return token;
  }
}

void main() {
  void enlargeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required Dio dio,
    required Future<void> Function() onAccountDeleted,
    GoogleAuthService? googleAuthService,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LuminaHealthTheme.dark(),
        home: ProfileSettingsPage(
          accessToken: 'token',
          authService: AuthService(dio: dio),
          initialDisplayName: 'Casey',
          initialUsername: '',
          email: 'me@example.com',
          onAccountDeleted: onAccountDeleted,
          googleAuthService: googleAuthService,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inDialog(String text) =>
      find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  testWidgets('password flow: wrong password shows error, right one deletes', (
    tester,
  ) async {
    enlargeView(tester);
    final deleteBodies = <Map<String, dynamic>>[];
    var deletedCalls = 0;

    await pumpPage(
      tester,
      dio: _accountDio(
        acceptedPassword: 'hunter2hunter2',
        deleteBodies: deleteBodies,
      ),
      onAccountDeleted: () async => deletedCalls += 1,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete account?'), findsOneWidget);

    await tester.tap(inDialog('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm your password'), findsOneWidget);

    // Wrong password: the vague server message appears, nothing is wiped and
    // the dialog stays open for a retry.
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'wrong-password',
    );
    await tester.tap(inDialog('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Re-authentication failed.'), findsOneWidget);
    expect(deletedCalls, 0);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'hunter2hunter2',
    );
    await tester.tap(inDialog('Delete account'));
    await tester.pumpAndSettle();

    expect(deletedCalls, 1);
    expect(deleteBodies.last, {'password': 'hunter2hunter2'});
  });

  testWidgets('google flow: fresh id token re-auths and deletes', (
    tester,
  ) async {
    enlargeView(tester);
    final deleteBodies = <Map<String, dynamic>>[];
    var deletedCalls = 0;
    final google = _FakeGoogleAuthService('fresh-id-token');

    await pumpPage(
      tester,
      dio: _accountDio(
        hasPassword: false,
        acceptedIdToken: 'fresh-id-token',
        deleteBodies: deleteBodies,
      ),
      onAccountDeleted: () async => deletedCalls += 1,
      googleAuthService: google,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog('Delete'));
    await tester.pumpAndSettle();

    // OAuth-only account: no password dialog, straight to the Google re-auth.
    expect(find.text('Confirm your password'), findsNothing);
    expect(google.calls, 1);
    expect(deletedCalls, 1);
    expect(deleteBodies.single, {'id_token': 'fresh-id-token'});
  });

  testWidgets('google flow: dismissing the account picker aborts', (
    tester,
  ) async {
    enlargeView(tester);
    var deletedCalls = 0;
    final google = _FakeGoogleAuthService(null);

    await pumpPage(
      tester,
      dio: _accountDio(hasPassword: false),
      onAccountDeleted: () async => deletedCalls += 1,
      googleAuthService: google,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog('Delete'));
    await tester.pumpAndSettle();

    expect(google.calls, 1);
    expect(deletedCalls, 0);
  });

  testWidgets('cancelling the confirm dialog deletes nothing', (tester) async {
    enlargeView(tester);
    final deleteBodies = <Map<String, dynamic>>[];
    var deletedCalls = 0;

    await pumpPage(
      tester,
      dio: _accountDio(
        acceptedPassword: 'irrelevant',
        deleteBodies: deleteBodies,
      ),
      onAccountDeleted: () async => deletedCalls += 1,
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(deleteBodies, isEmpty);
    expect(deletedCalls, 0);
  });
}
