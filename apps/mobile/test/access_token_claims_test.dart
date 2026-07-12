import 'dart:convert';

import 'package:fitness_app/core/access_token_claims.dart';
import 'package:flutter_test/flutter_test.dart';

String _jwt(Map<String, dynamic> payload) {
  String seg(Object o) => base64Url.encode(utf8.encode(json.encode(o)));
  // Signature is irrelevant — the helper never verifies it.
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(payload)}.sig';
}

void main() {
  test('extracts the numeric user_id claim', () {
    expect(userIdFromAccessToken(_jwt({'user_id': 42, 'exp': 1})), 42);
  });

  test('accepts a stringified user_id', () {
    expect(userIdFromAccessToken(_jwt({'user_id': '7'})), 7);
  });

  test('returns null when the claim is missing or unusable', () {
    expect(userIdFromAccessToken(_jwt({'sub': 'x'})), isNull);
    expect(userIdFromAccessToken(_jwt({'user_id': 'abc'})), isNull);
    expect(userIdFromAccessToken(_jwt({'user_id': 1.5})), isNull);
  });

  test('returns null on malformed tokens instead of throwing', () {
    expect(userIdFromAccessToken(''), isNull);
    expect(userIdFromAccessToken('not-a-jwt'), isNull);
    expect(userIdFromAccessToken('a.b.c'), isNull);
    expect(userIdFromAccessToken('a.###.c'), isNull);
  });
}
