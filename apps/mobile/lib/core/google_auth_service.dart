import 'package:google_sign_in/google_sign_in.dart';

import 'app_log.dart';
import 'auth_service.dart';
import 'environment.dart';

class GoogleAuthService {
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: EnvironmentConfig.googleServerClientId,
    );
    _initialized = true;
  }

  /// Show the native account picker.
  /// Returns a google id token or null if user dismisses
  Future<String?> signInAndGetToken() async {
    await _ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: const ['email', 'profile'],
      );
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        // Sign-in succeeded but no ID token came back
        throw AuthException(
          'Google sign-in did not return a token. Please try again.',
        );
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      // User exited - not an error
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    } catch (error, stackTrace) {
      logError('googleSignIn', error, stackTrace);
      rethrow;
    }
  }
}
