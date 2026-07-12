import 'dart:convert';

/// Extracts the numeric `user_id` claim from a simplejwt access token.
///
/// Used only to pick which per-user local database files to open (KAN-64) —
/// deliberately no signature check, since authorization stays server-side and
/// this must work offline at app start. Returns null on any malformed input,
/// in which case callers fall back to the unscoped legacy behavior.
int? userIdFromAccessToken(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final payload = json.decode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map) return null;
    final id = payload['user_id'];
    if (id is int) return id;
    if (id is String) return int.tryParse(id);
    return null;
  } on FormatException {
    return null;
  }
}
