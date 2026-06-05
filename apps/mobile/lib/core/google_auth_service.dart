import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

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
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      // User exited - not an error
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return null;
      }
      rethrow;
    } catch (e, st) {
      debugPrint('GOOGLE SIGN-IN ERROR: $e');
      debugPrint('$st');
      rethrow;
    }
  }
}