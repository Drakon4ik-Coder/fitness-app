import 'package:dio/dio.dart';
import 'package:fitness_app/core/app_log.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_dio.dart';

/// AuthService request shapes and error mapping (KAN-131). Error copy matters:
/// auth endpoints stay deliberately vague (account-enumeration defense,
/// CLAUDE.md rule 9), so these pin exactly what users see.
void main() {
  final logged = <String>[];

  setUp(() {
    logged.clear();
    appErrorLogger = (context, error, stackTrace) => logged.add(context);
  });

  tearDown(() => appErrorLogger = null);

  Matcher authError(String message, {bool emailUnverified = false}) =>
      isA<AuthException>()
          .having((e) => e.message, 'message', message)
          .having((e) => e.emailUnverified, 'emailUnverified', emailUnverified);

  group('login', () {
    test('returns the token pair', () async {
      final log = <RequestOptions>[];
      final service = AuthService(
        dio: scriptedDio((_) => ok({'access': 'a', 'refresh': 'r'}), log: log),
      );
      final tokens = await service.login(email: 'e@x.com', password: 'pw');
      expect(tokens.accessToken, 'a');
      expect(tokens.refreshToken, 'r');
      expect(log.single.path, '/api/v1/auth/token');
      expect(log.single.data, {'email': 'e@x.com', 'password': 'pw'});
    });

    test('flags an unverified email from the 400 message', () async {
      final service = AuthService(
        dio: scriptedDio(
          (_) => status(400, {
            'detail': ['Please confirm your email first.'],
          }),
        ),
      );
      await expectLater(
        service.login(email: 'e', password: 'p'),
        throwsA(
          authError('Please confirm your email first.', emailUnverified: true),
        ),
      );
    });

    test('a bare 401 reads as invalid credentials', () async {
      final service = AuthService(dio: scriptedDio((_) => status(401)));
      await expectLater(
        service.login(email: 'e', password: 'p'),
        throwsA(authError('Invalid email or password.')),
      );
    });

    test('server errors and odd payloads read as try-again-later', () async {
      for (final reply in [
        status(500),
        ok('not a map'),
        ok({'access': 'a'}),
      ]) {
        final service = AuthService(dio: scriptedDio((_) => reply));
        await expectLater(
          service.login(email: 'e', password: 'p'),
          throwsA(isA<AuthException>()),
        );
      }
      final typed = AuthService(dio: scriptedDio((_) => ok({'access': 1})));
      await expectLater(
        typed.login(email: 'e', password: 'p'),
        throwsA(authError('Unable to sign in. Please try again later.')),
      );
      expect(logged, contains('login'));
    });
  });

  group('googleLogin', () {
    test('returns tokens, maps 401 detail, and hides other failures', () async {
      final good = AuthService(
        dio: scriptedDio((_) => ok({'access': 'a', 'refresh': 'r'})),
      );
      expect((await good.googleLogin('id')).accessToken, 'a');

      final rejected = AuthService(
        dio: scriptedDio((_) => status(401, {'detail': 'Account disabled.'})),
      );
      await expectLater(
        rejected.googleLogin('id'),
        throwsA(authError('Account disabled.')),
      );

      final bare401 = AuthService(dio: scriptedDio((_) => status(401)));
      await expectLater(
        bare401.googleLogin('id'),
        throwsA(authError('Google sign-in was rejected.')),
      );

      const later = 'Unable to sign in with Google. Please try again later.';
      for (final reply in [status(503), ok({})]) {
        final service = AuthService(dio: scriptedDio((_) => reply));
        await expectLater(
          service.googleLogin('id'),
          throwsA(isA<AuthException>()),
        );
      }
      await expectLater(
        AuthService(dio: BrokenDio()).googleLogin('id'),
        throwsA(authError(later)),
      );
    });
  });

  group('refresh', () {
    test('returns the new access token or asks to sign in again', () async {
      final service = AuthService(dio: scriptedDio((_) => ok({'access': 'n'})));
      expect(await service.refresh('r'), 'n');

      const expired = 'Session expired. Please sign in again.';
      for (final dio in [
        scriptedDio((_) => status(401)),
        scriptedDio((_) => ok({'access': 3})),
        BrokenDio(),
      ]) {
        await expectLater(
          AuthService(dio: dio).refresh('r'),
          throwsA(isA<AuthException>()),
        );
      }
      await expectLater(
        AuthService(dio: BrokenDio()).refresh('r'),
        throwsA(authError(expired)),
      );
    });
  });

  group('register', () {
    test('posts consent flags and surfaces validation messages', () async {
      final log = <RequestOptions>[];
      final service = AuthService(dio: scriptedDio((_) => ok(), log: log));
      await service.register(
        email: 'e@x.com',
        password: 'pw',
        acceptTerms: true,
        acceptHealthData: true,
      );
      expect(log.single.data, {
        'email': 'e@x.com',
        'password': 'pw',
        'accept_terms': true,
        'accept_health_data': true,
      });

      Future<void> register(Dio dio) => AuthService(dio: dio).register(
        email: 'e',
        password: 'p',
        acceptTerms: true,
        acceptHealthData: true,
      );
      await expectLater(
        register(
          scriptedDio(
            (_) => status(400, {
              'password': ['Too common.'],
            }),
          ),
        ),
        throwsA(authError('Too common.')),
      );
      await expectLater(
        register(scriptedDio((_) => status(400, []))),
        throwsA(authError('Please check your details and try again.')),
      );
      await expectLater(
        register(scriptedDio((_) => status(500))),
        throwsA(authError('Unable to register. Please try again later.')),
      );
      await expectLater(
        register(BrokenDio()),
        throwsA(authError('Unable to register. Please try again later.')),
      );
    });
  });

  group('emails', () {
    test('resend and reset only ever say "try again later"', () async {
      final fine = AuthService(dio: scriptedDio((_) => ok()));
      await fine.resendVerification('e');
      await fine.requestPasswordReset('e');

      const resendMsg = 'Could not resend the email. Please try again later.';
      const resetMsg = 'Could not send the email. Please try again later.';
      for (final dio in [scriptedDio((_) => status(500)), BrokenDio()]) {
        await expectLater(
          AuthService(dio: dio).resendVerification('e'),
          throwsA(authError(resendMsg)),
        );
        await expectLater(
          AuthService(dio: dio).requestPasswordReset('e'),
          throwsA(authError(resetMsg)),
        );
      }
    });
  });

  group('authenticated calls', () {
    test('updateTimezone is best-effort', () async {
      final log = <RequestOptions>[];
      await AuthService(
        dio: scriptedDio((_) => ok(), log: log),
      ).updateTimezone(accessToken: 't', timezone: 'Europe/London');
      expect(log.single.data, {'timezone': 'Europe/London'});
      expect(log.single.headers['Authorization'], 'Bearer t');

      // A failure is swallowed: the next launch simply tries again.
      await AuthService(
        dio: scriptedDio((_) => status(500)),
      ).updateTimezone(accessToken: 't', timezone: 'UTC');
    });

    test('fetchMe parses the account and degrades to null', () async {
      final info = await AuthService(
        dio: scriptedDio(
          (_) => ok({
            'email': 'me@x.com',
            'display_name': 'Me',
            'username': 'me',
            'has_password': false,
            'accepted_policy_version': '1',
            'current_policy_version': '2',
          }),
        ),
      ).fetchMe(accessToken: 't');
      expect(info!.username, 'me');
      expect(info.hasPassword, isFalse);
      expect(info.currentPolicyVersion, '2');

      expect(
        await AuthService(
          dio: scriptedDio((_) => ok('nope')),
        ).fetchMe(accessToken: 't'),
        isNull,
      );
      expect(
        await AuthService(
          dio: scriptedDio((_) => status(401)),
        ).fetchMe(accessToken: 't'),
        isNull,
      );
    });

    test('acceptPolicy, changePassword and deleteAccount map errors', () async {
      final service = AuthService(dio: scriptedDio((_) => ok()));
      await service.acceptPolicy(accessToken: 't');
      await service.changePassword(
        accessToken: 't',
        currentPassword: 'a',
        newPassword: 'b',
      );
      await service.deleteAccount(accessToken: 't', password: 'a');

      final rejecting = AuthService(
        dio: scriptedDio((_) => status(403, {'detail': 'Nope.'})),
      );
      await expectLater(
        rejecting.acceptPolicy(accessToken: 't'),
        throwsA(authError('Nope.')),
      );
      await expectLater(
        rejecting.changePassword(
          accessToken: 't',
          currentPassword: 'a',
          newPassword: 'b',
        ),
        throwsA(authError('Nope.')),
      );
      await expectLater(
        rejecting.deleteAccount(accessToken: 't', googleIdToken: 'g'),
        throwsA(authError('Nope.')),
      );

      final broken = AuthService(dio: BrokenDio());
      await expectLater(
        broken.acceptPolicy(accessToken: 't'),
        throwsA(authError('Could not save your consent. Please try again.')),
      );
      await expectLater(
        broken.changePassword(
          accessToken: 't',
          currentPassword: 'a',
          newPassword: 'b',
        ),
        throwsA(
          authError('Could not change the password. Please try again later.'),
        ),
      );
      await expectLater(
        broken.deleteAccount(accessToken: 't'),
        throwsA(
          authError('Could not delete the account. Please try again later.'),
        ),
      );
      expect(
        logged,
        containsAll(['acceptPolicy', 'changePassword', 'deleteAccount']),
      );
    });

    test('updateProfile can clear the username and maps errors', () async {
      final log = <RequestOptions>[];
      await AuthService(
        dio: scriptedDio((_) => ok(), log: log),
      ).updateProfile(accessToken: 't', displayName: 'D', clearUsername: true);
      expect(log.single.data, {'display_name': 'D', 'username': null});

      await expectLater(
        AuthService(
          dio: scriptedDio((_) => status(400)),
        ).updateProfile(accessToken: 't', username: 'taken'),
        throwsA(authError('Unable to update profile.')),
      );
    });
  });

  test('AuthException prints its message', () {
    expect(AuthException('hello').toString(), 'hello');
  });
}
