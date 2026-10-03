import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/off_client.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_dio.dart';

// Response-shape and failure edges of the OFF client (KAN-131).

/// A limiter whose every slot fails with a non-Dio error, to reach the
/// clients' defensive catch-alls.
class _ExplodingLimiter extends OffRateLimiter {
  @override
  Future<T> run<T>(String key, Future<T> Function() action) =>
      throw StateError('limiter broke');
}

OffClient _client(Object? data, {String country = 'uk', List<Uri>? seen}) {
  final dio = scriptedDio((request) {
    seen?.add(request.uri);
    return ok(data);
  });
  return OffClient(dio: dio, rateLimiter: OffRateLimiter(), country: country);
}

void main() {
  group('fetchProduct', () {
    test('returns the product with the raw payload', () async {
      final product = await _client({
        'status': 1,
        'product': {'code': '123', 'product_name': 'Oats'},
      }).fetchProduct(' 123 ');
      expect(product?.product['product_name'], 'Oats');
      expect(product?.rawJson, contains('"status":1'));
    });

    test('maps empty, not-found and malformed bodies to null', () async {
      expect(await _client(null).fetchProduct('1'), isNull);
      expect(await _client({'status': 0}).fetchProduct('1'), isNull);
      expect(
        await _client({'status': 1, 'product': 'nope'}).fetchProduct('1'),
        isNull,
      );
    });

    test('an unexpected failure becomes a friendly OffException', () async {
      final client = OffClient(dio: Dio(), rateLimiter: _ExplodingLimiter());
      await expectLater(
        client.fetchProduct('1'),
        throwsA(
          isA<OffException>().having(
            (e) => e.toString(),
            'message',
            'Unable to fetch from OFF.',
          ),
        ),
      );
    });
  });

  group('searchProducts', () {
    test('scopes the query by country and category tags', () async {
      final seen = <Uri>[];
      final results = await _client(
        {
          'hits': [
            {'code': '1', 'product_name': 'Muesli'},
          ],
        },
        seen: seen,
      ).searchProducts('muesli', categoryTag: ' en:breakfast-cereals ');

      expect(results.single.product['product_name'], 'Muesli');
      final q = seen.single.queryParameters['q']!;
      expect(q, contains('countries_tags:"en:united-kingdom"'));
      expect(q, contains('categories_tags:"en:breakfast-cereals"'));
    });

    test('free-form country names become tag slugs', () async {
      final seen = <Uri>[];
      await _client(
        {'hits': []},
        country: 'United States',
        seen: seen,
      ).searchProducts('oats');
      expect(
        seen.single.queryParameters['q'],
        contains('countries_tags:"united-states"'),
      );
    });

    test('empty or malformed bodies yield no results', () async {
      expect(await _client(null).searchProducts('oats'), isEmpty);
      expect(await _client({'hits': 'nope'}).searchProducts('oats'), isEmpty);
    });

    test('an unexpected failure becomes a friendly OffException', () async {
      final client = OffClient(dio: Dio(), rateLimiter: _ExplodingLimiter());
      await expectLater(
        client.searchProducts('oats'),
        throwsA(
          isA<OffException>().having(
            (e) => e.message,
            'message',
            'Unable to search OFF.',
          ),
        ),
      );
    });
  });
}
