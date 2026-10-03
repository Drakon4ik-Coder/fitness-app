import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fitness_app/core/app_log.dart';
import 'package:fitness_app/core/auth_interceptor.dart';
import 'package:fitness_app/core/auth_service.dart';
import 'package:fitness_app/core/auth_storage.dart';
import 'package:fitness_app/core/environment.dart';
import 'package:fitness_app/core/google_auth_service.dart';
import 'package:fitness_app/core/version_check_service.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/food_sync.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/off_image_downloader.dart';
import 'package:fitness_app/features/nutrition/data/off_rate_limiter.dart';
import 'package:fitness_app/features/nutrition/data/preferences_api_service.dart';
import 'package:fitness_app/features/nutrition/data/user_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'fake_dio.dart';

/// Request shapes, response parsing and failure handling of the services the
/// pages sit on (KAN-131). Everything runs in-process via [scriptedDio].
FoodItem _food({int? backendId, String contentHash = 'h'}) => FoodItem(
  source: offSource,
  externalId: 'e-1',
  barcode: '111',
  backendId: backendId,
  name: 'Oats',
  brands: '',
  contentHash: contentHash,
  rawSourceJson: '{}',
);

Map<String, dynamic> _detail({int id = 9, String name = 'Oats'}) => {
  'id': id,
  'source': offSource,
  'external_id': 'e-1',
  'name': name,
  'raw_source_json': <String, dynamic>{},
  'images_ok': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Expected failures below would otherwise debug-print their traces.
  setUp(() => appErrorLogger = (context, error, stackTrace) {});
  tearDown(() => appErrorLogger = null);

  group('FoodsApiService', () {
    test('typeahead maps summaries and tolerates an empty body', () async {
      final log = <RequestOptions>[];
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio(
          (_) => ok([
            {'id': 1, 'name': 'Oats', 'source': offSource},
            'junk',
          ]),
          log: log,
        ),
      );
      final hits = await api.typeahead('oat', limit: 5);
      expect(hits.single.backendId, 1);
      expect(log.single.queryParameters, {'q': 'oat', 'limit': 5});

      final empty = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok()),
      );
      expect(await empty.typeahead('oat'), isEmpty);
    });

    test('ingest, custom upsert and check parse their payloads', () async {
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((request) {
          return switch (request.path) {
            '/api/v1/foods/check' => ok({
              'exists': true,
              'up_to_date': true,
              'food_item_id': 9,
              'images_ok': false,
            }),
            _ => ok(_detail()),
          };
        }),
      );
      final ingested = await api.ingestFood(_food());
      expect(ingested.item.backendId, 9);
      expect(ingested.imagesOk, isTrue);
      expect((await api.upsertCustomFood(_food())).backendId, 9);
      final check = await api.checkFood(
        source: offSource,
        externalId: 'e-1',
        contentHash: 'h',
        imageSignature: 'sig',
      );
      expect(check.upToDate, isTrue);
      expect(check.foodItemId, 9);
      expect(check.imagesOk, isFalse);
    });

    test('unexpected bodies become ApiExceptions', () async {
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok('not json')),
      );
      await expectLater(api.ingestFood(_food()), throwsA(isA<ApiException>()));
      await expectLater(
        api.upsertCustomFood(_food()),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        api.checkFood(source: offSource, externalId: 'e', contentHash: 'h'),
        throwsA(isA<ApiException>()),
      );
    });

    test('deleting an already-gone custom food is a success', () async {
      final gone = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => status(404)),
      );
      await gone.deleteCustomFood(5);

      final failing = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => status(500)),
      );
      await expectLater(
        failing.deleteCustomFood(5),
        throwsA(isA<ApiException>()),
      );
    });

    test('image upload is best-effort', () async {
      final log = <RequestOptions>[];
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok(_detail(name: 'With image')), log: log),
      );
      final updated = await api.uploadFoodImages(
        foodItemId: 9,
        bytes: Uint8List.fromList([1, 2, 3]),
        contentType: 'image/jpeg',
        imageSignature: 'sig',
      );
      expect(updated!.name, 'With image');
      expect(log.single.path, '/api/v1/foods/9/images');

      final empty = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok()),
      );
      expect(
        await empty.uploadFoodImages(
          foodItemId: 9,
          bytes: Uint8List(1),
          contentType: 'image/png',
        ),
        isNull,
      );
      final failing = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => status(500)),
      );
      expect(
        await failing.uploadFoodImages(
          foodItemId: 9,
          bytes: Uint8List(1),
          contentType: 'image/png',
        ),
        isNull,
      );
    });

    test('updateToken rewrites the auth header', () async {
      final log = <RequestOptions>[];
      final api = FoodsApiService(
        accessToken: 'old',
        dio: scriptedDio((_) => ok(<dynamic>[]), log: log),
      )..updateToken('new');
      await api.typeahead('x');
      expect(log.single.headers['Authorization'], 'Bearer new');
    });
  });

  group('NutritionApiService', () {
    test('meal times skip malformed rows and default the spread', () async {
      final api = NutritionApiService(
        accessToken: 't',
        dio: scriptedDio(
          (_) => ok({
            'meal_times': {
              'lunch': {'typical_hour': 12.5},
              'dinner': {'typical_hour': null},
              'breakfast': 'junk',
            },
          }),
        ),
      )..updateToken('t2');
      final times = await api.fetchMealTimes();
      expect(times.keys, ['lunch']);
      expect(times['lunch']!.halfWidth, 2.0);
      expect(times['lunch']!.sampleCount, 0);
    });

    test('update by uuid sends the LWW mutation time', () async {
      final log = <RequestOptions>[];
      final entry = {
        'id': 3,
        'client_uuid': 'u-1',
        'meal_type': 'lunch',
        'consumed_at': '2026-10-01T12:00:00Z',
        'quantity_g': 150,
        'kcal': 200,
        'food_item': _detail(),
      };
      final api = NutritionApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok(entry), log: log),
      );
      final updated = await api.updateEntry(
        entryUuid: 'u-1',
        quantityG: 150,
        mealType: 'lunch',
        clientUpdatedAt: DateTime.utc(2026, 10, 1, 12, 5),
      );
      expect(updated.quantityG, 150);
      expect(log.single.path, '/api/v1/nutrition/entries/by-uuid/u-1');
      expect(log.single.data, {
        'quantity_g': 150.0,
        'meal_type': 'lunch',
        'client_updated_at': '2026-10-01T12:05:00.000Z',
      });
    });

    test('sync pages carry tombstones and the cursor params', () async {
      final log = <RequestOptions>[];
      final api = NutritionApiService(
        accessToken: 't',
        dio: scriptedDio(
          (_) => ok({
            'entries': [
              {
                'id': 3,
                'client_uuid': 'u-1',
                'meal_type': 'lunch',
                'consumed_at': '2026-10-01T12:00:00Z',
                'quantity_g': 100,
                'kcal': 130,
                'food_item': _detail(),
                'deleted': true,
              },
            ],
            'next_cursor': 'c2',
            'has_more': false,
          }),
          log: log,
        ),
      );
      final page = await api.fetchSyncPage(since: 'c1', limit: 50);
      expect(page.entries.single.deleted, isTrue);
      expect(page.nextCursor, 'c2');
      expect(log.single.queryParameters, {'since': 'c1', 'limit': 50});
    });

    test('unexpected bodies become ApiExceptions', () async {
      final api = NutritionApiService(
        accessToken: 't',
        dio: scriptedDio((_) => ok('nope')),
      );
      await expectLater(api.fetchMealTimes(), throwsA(isA<ApiException>()));
      await expectLater(
        api.updateEntry(entryId: 1, quantityG: 1),
        throwsA(isA<ApiException>()),
      );
      await expectLater(api.fetchSyncPage(), throwsA(isA<ApiException>()));
    });
  });

  group('PreferencesApiService', () {
    test('rejects unexpected bodies and follows token updates', () async {
      final log = <RequestOptions>[];
      final api = PreferencesApiService(
        accessToken: 'a',
        dio: scriptedDio((_) => ok('nope'), log: log),
      )..updateToken('b');
      await expectLater(api.fetch(), throwsA(isA<ApiException>()));
      await expectLater(
        api.update(calorieGoal: 2000),
        throwsA(isA<ApiException>()),
      );
      expect(log.first.headers['Authorization'], 'Bearer b');
    });
  });

  test('UserPreferences.copyWith replaces and clears fields', () {
    const prefs = UserPreferences(calorieGoal: 2000);
    final updated = prefs.copyWith(
      weightUnit: 'lb',
      heightUnit: 'in',
      energyUnit: 'kj',
      nutrientGoals: {'protein': 150},
      focusNutrients: ['protein'],
      warnNutrients: ['sugars'],
    );
    expect(updated.weightUnit, 'lb');
    expect(updated.calorieGoal, 2000);
    expect(updated.warnNutrients, ['sugars']);
    expect(prefs.copyWith(clearCalorieGoal: true).calorieGoal, isNull);
  });

  group('AuthInterceptor', () {
    setUp(
      () => FlutterSecureStorage.setMockInitialValues({'refresh_token': 'r'}),
    );

    test('a 401 refreshes once, retries, and re-heads every client', () async {
      var protectedCalls = 0;
      final dio = scriptedDio((request) {
        protectedCalls++;
        return status(401);
      });
      final retried = <RequestOptions>[];
      AuthInterceptor(
        storage: AuthStorage(),
        authService: AuthService(
          dio: scriptedDio((_) => ok({'access': 'fresh'})),
        ),
        onSessionExpired: () async => fail('session should survive'),
        accessToken: 'stale',
        retryClient: scriptedDio((_) => ok({'ok': true}), log: retried),
      ).attachTo(dio);

      final response = await dio.get<Object?>('/api/v1/nutrition/day');

      expect(response.data, {'ok': true});
      expect(protectedCalls, 1);
      expect(retried.single.headers['Authorization'], 'Bearer fresh');
      expect(dio.options.headers['Authorization'], 'Bearer fresh');
      expect(await AuthStorage().getAccessToken(), 'fresh');
    });

    test('a failed refresh expires the session', () async {
      var expired = 0;
      final dio = scriptedDio((_) => status(401));
      AuthInterceptor(
        storage: AuthStorage(),
        authService: AuthService(dio: scriptedDio((_) => status(401))),
        onSessionExpired: () async => expired++,
        accessToken: 'stale',
      ).attachTo(dio);

      await expectLater(dio.get<Object?>('/x'), throwsA(isA<DioException>()));
      expect(expired, 1);
    });

    test('a failing retry surfaces its own error', () async {
      final dio = scriptedDio((_) => status(401));
      AuthInterceptor(
        storage: AuthStorage(),
        authService: AuthService(
          dio: scriptedDio((_) => ok({'access': 'fresh'})),
        ),
        onSessionExpired: () async {},
        accessToken: 'stale',
        retryClient: scriptedDio((_) => status(500)),
      ).attachTo(dio);

      await expectLater(
        dio.get<Object?>('/x'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            500,
          ),
        ),
      );
    });
  });

  test('AuthStorage saves and clears tokens', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final storage = AuthStorage();
    await storage.saveAccessToken('a');
    expect(await storage.getAccessToken(), 'a');
    await storage.clear();
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
  });

  group('food sync', () {
    test('a known backend id short-circuits', () async {
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((_) => fail('no request expected')),
      );
      final (item, imagesOk) = await ensureGlobalBackendId(
        _food(backendId: 4),
        foodsApi: api,
      );
      expect(item.backendId, 4);
      expect(imagesOk, isFalse);
    });

    test('an up-to-date check skips the ingest', () async {
      final paths = <String>[];
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((request) {
          paths.add(request.path);
          return ok({
            'exists': true,
            'up_to_date': true,
            'food_item_id': 7,
            'images_ok': true,
          });
        }),
      );
      final (item, imagesOk) = await ensureGlobalBackendId(
        _food(),
        foodsApi: api,
      );
      expect(item.backendId, 7);
      expect(imagesOk, isTrue);
      expect(paths, ['/api/v1/foods/check']);
    });

    test('a stale check falls through to ingest', () async {
      final api = FoodsApiService(
        accessToken: 't',
        dio: scriptedDio((request) {
          if (request.path == '/api/v1/foods/check') {
            return ok({'exists': true, 'up_to_date': false});
          }
          return ok(_detail(id: 11));
        }),
      );
      final (item, _) = await ensureGlobalBackendId(_food(), foodsApi: api);
      expect(item.backendId, 11);
    });

    test('custom delete reports unauthorized and failed outcomes', () async {
      final custom = _food(backendId: 5);
      var loggedOut = 0;
      final unauthorized = await deleteCustomFoodEverywhere(
        custom,
        foodsApi: FoodsApiService(
          accessToken: 't',
          dio: scriptedDio((_) => status(401)),
        ),
        localDb: FoodLocalDb(),
        onUnauthorized: () async => loggedOut++,
      );
      expect(unauthorized, CustomFoodDeleteOutcome.unauthorized);
      expect(loggedOut, 1);

      final failed = await deleteCustomFoodEverywhere(
        custom,
        foodsApi: FoodsApiService(
          accessToken: 't',
          dio: scriptedDio((request) => throw offline(request)),
        ),
        localDb: FoodLocalDb(),
        onUnauthorized: () async {},
      );
      expect(failed, CustomFoodDeleteOutcome.failed);
    });
  });

  group('OffImageDownloader', () {
    test('returns bytes with a normalized content type', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<List<int>>(
              requestOptions: options,
              statusCode: 200,
              data: [1, 2, 3],
              headers: Headers.fromMap({
                'content-type': ['image/png; charset=binary'],
              }),
            ),
          ),
        ),
      );
      final downloader = OffImageDownloader(
        dio: dio,
        rateLimiter: OffRateLimiter(),
      );
      final result = await downloader.downloadImage('https://img/x.png');
      expect(result!.bytes, [1, 2, 3]);
      expect(result.contentType, 'image/png');

      final unlimited = await downloader.downloadImage(
        'https://cdn/y.png',
        useOffRateLimit: false,
      );
      expect(unlimited, isNotNull);
    });

    test('empty bodies and failures come back as null', () async {
      final empty = OffImageDownloader(dio: scriptedDio((_) => ok(<int>[])));
      expect(await empty.downloadImage('u', useOffRateLimit: false), isNull);
      final failing = OffImageDownloader(dio: scriptedDio((_) => status(404)));
      expect(await failing.downloadImage('u', useOffRateLimit: false), isNull);
    });
  });

  group('OffRateLimiter', () {
    test('reports the wait until the oldest call ages out', () {
      var now = DateTime.utc(2026, 10, 1, 12);
      final limiter = OffRateLimiter(
        maxCalls: 1,
        window: const Duration(seconds: 60),
        now: () => now,
      );
      expect(limiter.timeUntilNextAllowed(), isNull);
      limiter.run('a', () async => 1);
      now = now.add(const Duration(seconds: 20));
      expect(limiter.timeUntilNextAllowed(), const Duration(seconds: 40));
    });

    test('exception copy names the service and the wait', () {
      expect(
        OffRateLimitException(const Duration(milliseconds: 500)).toString(),
        'OpenFoodFacts is temporarily rate limited. Try again in a moment.',
      );
      expect(
        OffRateLimitException(const Duration(seconds: 30), 'FatSecret').message,
        'FatSecret is temporarily rate limited. Try again in 30s.',
      );
    });
  });

  group('GoogleAuthService', () {
    test('returns the id token, initializing once', () async {
      final signIn = _FakeGoogleSignIn(token: 'id-token');
      final service = GoogleAuthService(signIn: signIn);
      expect(await service.signInAndGetToken(), 'id-token');
      expect(await service.signInAndGetToken(), 'id-token');
      expect(signIn.initializeCalls, 1);
    });

    test('a cancelled picker is a null, not an error', () async {
      final service = GoogleAuthService(
        signIn: _FakeGoogleSignIn(
          error: const GoogleSignInException(
            code: GoogleSignInExceptionCode.canceled,
          ),
        ),
      );
      expect(await service.signInAndGetToken(), isNull);
    });

    test('a missing token and real failures are surfaced', () async {
      await expectLater(
        GoogleAuthService(
          signIn: _FakeGoogleSignIn(token: null),
        ).signInAndGetToken(),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        GoogleAuthService(
          signIn: _FakeGoogleSignIn(
            error: const GoogleSignInException(
              code: GoogleSignInExceptionCode.clientConfigurationError,
            ),
          ),
        ).signInAndGetToken(),
        throwsA(isA<GoogleSignInException>()),
      );
    });
  });

  test('environment exposes its build-time configuration', () {
    expect(EnvironmentConfig.environmentName, isNotEmpty);
    expect(EnvironmentConfig.googleServerClientId, isA<String>());
    expect(EnvironmentConfig.sentryDsn, isA<String>());
    expect(VersionCheckService(), isA<VersionCheckService>());
  });
}

class _FakeGoogleSignIn extends Fake implements GoogleSignIn {
  _FakeGoogleSignIn({this.token, this.error});

  final String? token;
  final GoogleSignInException? error;
  int initializeCalls = 0;

  @override
  Future<void> initialize({
    String? clientId,
    String? serverClientId,
    String? nonce,
    String? hostedDomain,
  }) async {
    initializeCalls++;
  }

  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const [],
  }) async {
    final failure = error;
    if (failure != null) throw failure;
    return _FakeAccount(token);
  }
}

class _FakeAccount extends Fake implements GoogleSignInAccount {
  _FakeAccount(this.token);

  final String? token;

  @override
  GoogleSignInAuthentication get authentication =>
      GoogleSignInAuthentication(idToken: token);
}
