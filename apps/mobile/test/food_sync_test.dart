import 'dart:async';

import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/food_sync.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

FoodItem _draft() => FoodItem(
  source: customSource,
  externalId: 'cf-test',
  name: 'Instant oats',
  brands: '',
  kcal100g: 200,
  rawSourceJson: '{}',
);

class _CompletingFoodsApi extends FoodsApiService {
  _CompletingFoodsApi() : super(accessToken: 'test-token');

  final Completer<FoodItem> upsertResult = Completer<FoodItem>();
  final Completer<int> deleteObserved = Completer<int>();
  final List<FoodItem> upserts = [];
  final List<int> deletes = [];

  @override
  Future<FoodItem> upsertCustomFood(FoodItem item) {
    upserts.add(item);
    return upsertResult.future;
  }

  @override
  Future<void> deleteCustomFood(int backendId) async {
    deletes.add(backendId);
    if (!deleteObserved.isCompleted) deleteObserved.complete(backendId);
  }
}

class _MemoryFoodDb extends FoodLocalDb {
  FoodItem? row;

  @override
  Future<FoodItem> upsertFood(FoodItem item) async {
    row = item.copyWith(localId: item.localId ?? 1);
    return row!;
  }

  @override
  Future<bool> updateBackendId(int localId, int backendId) async {
    final current = row;
    if (current == null || current.localId != localId) return false;
    row = current.copyWith(backendId: backendId);
    return true;
  }

  @override
  Future<void> deleteFood(int localId) async {
    if (row?.localId == localId) row = null;
  }
}

void main() {
  test(
    'stores locally before background upsert completes, then patches id',
    () async {
      final api = _CompletingFoodsApi();
      final db = _MemoryFoodDb();
      FoodItem? syncedCopy;
      final syncedObserved = Completer<void>();

      final stored = await saveCustomFoodDraft(
        _draft(),
        foodsApi: api,
        localDb: db,
        onUnauthorized: () async {},
        onSynced: (synced) {
          syncedCopy = synced;
          syncedObserved.complete();
        },
      );

      expect(stored?.localId, 1);
      expect(db.row?.name, 'Instant oats');
      expect(db.row?.backendId, isNull);
      expect(api.upserts, hasLength(1));
      expect(api.upsertResult.isCompleted, isFalse);

      api.upsertResult.complete(_draft().copyWith(backendId: 42));
      await syncedObserved.future;
      expect(db.row?.backendId, 42);
      expect(syncedCopy?.backendId, 42);
    },
  );

  test(
    'deleting locally during upsert compensates with backend delete',
    () async {
      final api = _CompletingFoodsApi();
      final db = _MemoryFoodDb();

      final stored = await saveCustomFoodDraft(
        _draft(),
        foodsApi: api,
        localDb: db,
        onUnauthorized: () async {},
      );
      final outcome = await deleteCustomFoodEverywhere(
        stored!,
        foodsApi: api,
        localDb: db,
        onUnauthorized: () async {},
      );
      expect(outcome, CustomFoodDeleteOutcome.deleted);

      api.upsertResult.complete(_draft().copyWith(backendId: 43));

      expect(await api.deleteObserved.future, 43);
      expect(api.deletes, [43]);
      expect(db.row, isNull);
    },
  );

  test('background unauthorized response invokes onUnauthorized', () async {
    final api = _CompletingFoodsApi();
    final db = _MemoryFoodDb();
    final unauthorizedObserved = Completer<void>();

    final stored = await saveCustomFoodDraft(
      _draft(),
      foodsApi: api,
      localDb: db,
      onUnauthorized: () async => unauthorizedObserved.complete(),
    );
    expect(stored?.localId, 1);

    api.upsertResult.completeError(
      ApiException('Unauthorized.', statusCode: 401),
    );

    await unauthorizedObserved.future;
    expect(db.row?.backendId, isNull);
  });
}
