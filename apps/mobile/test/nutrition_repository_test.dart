import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'in_memory_nutrition_store.dart';

/// Scripted fake of the nutrition API: an in-memory "server" with a
/// connectivity switch. Emulates the KAN-28 server semantics the repository
/// relies on — uuid dedupe on create, LWW on update/delete, delta pages.
class _FakeNutritionApi implements NutritionApiService {
  // Only used for parseDayLog (pure parsing), never performs I/O.
  final NutritionApiService _parser = NutritionApiService(
    accessToken: 'token',
    dio: Dio(),
  );

  bool offline = false;
  int _nextServerId = 100;

  /// Server-side entries by uuid; value null means tombstone.
  final Map<String, NutritionEntry?> serverEntries = {};
  final List<String> createUuids = [];
  int updateCalls = 0;
  int deleteCalls = 0;
  int syncCalls = 0;
  int dayFetches = 0;

  /// Scripted delta pages, consumed one per [fetchSyncPage] with a `since`.
  final List<SyncPage> deltaPages = [];

  Map<String, dynamic> dayPayload = {
    'date': '2024-01-01',
    'totals': {'kcal': 0, 'protein_g': 0, 'carbs_g': 0, 'fat_g': 0},
    'meals': {'breakfast': [], 'lunch': [], 'dinner': [], 'snacks': []},
  };

  void _checkOnline(String what) {
    if (offline) {
      throw ApiException('offline: $what', isNetworkError: true);
    }
  }

  @override
  Future<NutritionEntry> createEntry({
    required int foodItemId,
    required String mealType,
    required double quantityG,
    DateTime? consumedAt,
    String? clientUuid,
  }) async {
    _checkOnline('create');
    if (clientUuid != null && serverEntries.containsKey(clientUuid)) {
      final existing = serverEntries[clientUuid];
      if (existing != null) {
        return existing; // idempotent replay
      }
    }
    createUuids.add(clientUuid ?? '');
    final entry = NutritionEntry(
      id: _nextServerId++,
      uuid: clientUuid,
      mealType: mealType,
      consumedAt: consumedAt ?? DateTime.now().toUtc(),
      quantityG: quantityG,
      kcal: quantityG * 1.5,
      foodItem: makeTestFood(backendId: foodItemId),
      updatedAt: DateTime.now().toUtc(),
    );
    if (clientUuid != null) {
      serverEntries[clientUuid] = entry;
    }
    return entry;
  }

  @override
  Future<NutritionEntry> updateEntry({
    int? entryId,
    String? entryUuid,
    double? quantityG,
    String? mealType,
    DateTime? clientUpdatedAt,
  }) async {
    _checkOnline('update');
    updateCalls++;
    final existing = serverEntries[entryUuid];
    if (existing == null) {
      throw ApiException('Entry not found.', statusCode: 404);
    }
    if (clientUpdatedAt != null &&
        existing.updatedAt != null &&
        existing.updatedAt!.isAfter(clientUpdatedAt)) {
      return existing; // LWW: newer change stands, respond with it
    }
    final updated = NutritionEntry(
      id: existing.id,
      uuid: existing.uuid,
      mealType: mealType ?? existing.mealType,
      consumedAt: existing.consumedAt,
      quantityG: quantityG ?? existing.quantityG,
      kcal: (quantityG ?? existing.quantityG) * 1.5,
      foodItem: existing.foodItem,
      updatedAt: clientUpdatedAt ?? DateTime.now().toUtc(),
    );
    serverEntries[entryUuid!] = updated;
    return updated;
  }

  @override
  Future<void> deleteEntry({
    int? entryId,
    String? entryUuid,
    DateTime? clientUpdatedAt,
  }) async {
    _checkOnline('delete');
    deleteCalls++;
    if (entryUuid != null) {
      serverEntries[entryUuid] = null;
    }
  }

  @override
  Future<SyncPage> fetchSyncPage({String? since, int? limit}) async {
    _checkOnline('sync');
    syncCalls++;
    if (since == null) {
      return const SyncPage(
        entries: [],
        nextCursor: 'cursor-0',
        hasMore: false,
      );
    }
    if (deltaPages.isEmpty) {
      return SyncPage(entries: const [], nextCursor: since, hasMore: false);
    }
    return deltaPages.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> fetchDayRaw(DateTime date) async {
    _checkOnline('day');
    dayFetches++;
    return dayPayload;
  }

  @override
  Future<NutritionDayLog> fetchDay(DateTime date) async =>
      parseDayLog(await fetchDayRaw(date));

  @override
  NutritionDayLog parseDayLog(Map<String, dynamic> data) =>
      _parser.parseDayLog(data);

  @override
  Future<Map<String, MealTimeStat>> fetchMealTimes() async => {};

  @override
  void updateToken(String accessToken) {}
}

NutritionEntry _serverEntry({
  required String uuid,
  int id = 500,
  String mealType = 'lunch',
  double quantityG = 100,
  DateTime? consumedAt,
  DateTime? updatedAt,
}) {
  final now = DateTime.now();
  return NutritionEntry(
    id: id,
    uuid: uuid,
    mealType: mealType,
    consumedAt: (consumedAt ?? DateTime(now.year, now.month, now.day, 13))
        .toUtc(),
    quantityG: quantityG,
    kcal: quantityG * 1.5,
    foodItem: makeTestFood(),
    updatedAt: (updatedAt ?? now).toUtc(),
  );
}

void main() {
  late _FakeNutritionApi api;
  late InMemoryNutritionStore store;
  late NutritionRepository repo;
  final today = DateTime.now();

  setUp(() {
    api = _FakeNutritionApi();
    store = InMemoryNutritionStore();
    repo = NutritionRepository(api: api, store: store);
  });

  Future<void> seedToday() async {
    store.dayPayloads[NutritionApiService.formatDate(today)] = api.dayPayload;
    store.cursor = 'cursor-0';
  }

  group('offline create', () {
    test('appears in the local day immediately and queues an op', () async {
      api.offline = true;

      final entry = await repo.createEntry(
        food: makeTestFood(backendId: 7),
        mealType: 'lunch',
        quantityG: 200,
        consumedAt: DateTime(today.year, today.month, today.day, 13),
      );

      expect(entry.uuid, isNotNull);
      expect(entry.id, 0); // no server id yet
      final day = await repo.readCachedDay(today);
      expect(day, isNotNull);
      expect(day!.meals['lunch'], hasLength(1));
      expect(day.totals.kcal, closeTo(300, 0.01)); // 150 kcal/100g × 200 g
      expect(store.outbox, hasLength(1));
      expect(api.createUuids, isEmpty); // never reached the server
    });

    test('replays on reconnect without duplicating', () async {
      api.offline = true;
      final entry = await repo.createEntry(
        food: makeTestFood(backendId: 7),
        mealType: 'lunch',
        quantityG: 200,
        consumedAt: DateTime(today.year, today.month, today.day, 13),
      );

      api.offline = false;
      await seedToday();
      await repo.refreshDay(today);
      // A second refresh must not replay the create again (outbox drained).
      await repo.refreshDay(today);

      expect(api.createUuids, [entry.uuid]);
      expect(store.outbox, isEmpty);
      final stored = store.entries[entry.uuid]!;
      expect(stored.serverId, isNotNull);
      expect(stored.pending, isFalse);
    });

    test('requires a backend-resolved food', () async {
      expect(
        () => repo.createEntry(
          food: makeTestFood(backendId: null),
          mealType: 'lunch',
          quantityG: 100,
          consumedAt: today,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('offline edit and delete', () {
    test('edit applies locally and replays with its mutation time', () async {
      await seedToday();
      final uuid = 'synced-1';
      store.entries[uuid] = makeStoredEntry(uuid: uuid, serverId: 500);
      api.serverEntries[uuid] = _serverEntry(
        uuid: uuid,
        updatedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );

      api.offline = true;
      final edited = await repo.updateEntry(
        NutritionEntry(
          id: 500,
          uuid: uuid,
          mealType: 'breakfast',
          consumedAt: store.entries[uuid]!.consumedAt,
          quantityG: 100,
          kcal: 150,
          foodItem: makeTestFood(),
        ),
        quantityG: 250,
      );

      expect(edited!.quantityG, 250);
      expect(store.entries[uuid]!.pending, isTrue);

      api.offline = false;
      await repo.refreshDay(today);

      expect(api.updateCalls, 1);
      expect(api.serverEntries[uuid]!.quantityG, 250);
      expect(store.outbox, isEmpty);
      expect(store.entries[uuid]!.pending, isFalse);
    });

    test('delete tombstones locally, hides the entry, and replays', () async {
      await seedToday();
      final uuid = 'synced-2';
      store.entries[uuid] = makeStoredEntry(uuid: uuid, serverId: 501);
      api.serverEntries[uuid] = _serverEntry(uuid: uuid, id: 501);

      api.offline = true;
      await repo.deleteEntry(
        NutritionEntry(
          id: 501,
          uuid: uuid,
          mealType: 'breakfast',
          consumedAt: store.entries[uuid]!.consumedAt,
          quantityG: 100,
          kcal: 150,
          foodItem: makeTestFood(),
        ),
      );

      final day = await repo.readCachedDay(today);
      expect(day!.meals.values.expand((e) => e), isEmpty);

      api.offline = false;
      await repo.refreshDay(today);

      expect(api.deleteCalls, 1);
      expect(api.serverEntries[uuid], isNull); // tombstoned server-side
      expect(store.entries.containsKey(uuid), isFalse); // purged after ack
    });

    test('deleting a never-synced entry cancels its queued create', () async {
      api.offline = true;
      final entry = await repo.createEntry(
        food: makeTestFood(backendId: 7),
        mealType: 'snacks',
        quantityG: 50,
        consumedAt: DateTime(today.year, today.month, today.day, 16),
      );

      await repo.deleteEntry(entry);

      expect(store.outbox, isEmpty);
      expect(store.entries, isEmpty);

      api.offline = false;
      await seedToday();
      await repo.refreshDay(today);
      expect(api.createUuids, isEmpty); // the create never replayed
    });
  });

  group('delta sync', () {
    test('merges created, updated and tombstoned entries', () async {
      await seedToday();
      store.entries['gone'] = makeStoredEntry(uuid: 'gone', serverId: 1);
      api.deltaPages.add(
        SyncPage(
          entries: [
            SyncEntry(entry: _serverEntry(uuid: 'new-1'), deleted: false),
            SyncEntry(entry: _serverEntry(uuid: 'gone'), deleted: true),
          ],
          nextCursor: 'cursor-1',
          hasMore: false,
        ),
      );

      final day = await repo.refreshDay(today);

      expect(api.dayFetches, 0); // seeded day: delta pull, no full re-fetch
      expect(store.entries.containsKey('new-1'), isTrue);
      expect(store.entries.containsKey('gone'), isFalse);
      expect(day.meals['lunch'], hasLength(1));
      expect(store.cursor, 'cursor-1');
    });

    test('follows has_more pagination', () async {
      await seedToday();
      api.deltaPages.addAll([
        SyncPage(
          entries: [SyncEntry(entry: _serverEntry(uuid: 'p1'), deleted: false)],
          nextCursor: 'cursor-1',
          hasMore: true,
        ),
        SyncPage(
          entries: [SyncEntry(entry: _serverEntry(uuid: 'p2'), deleted: false)],
          nextCursor: 'cursor-2',
          hasMore: false,
        ),
      ]);

      await repo.refreshDay(today);

      expect(store.entries.keys, containsAll(['p1', 'p2']));
      expect(store.cursor, 'cursor-2');
    });

    test('keeps a pending local change over an older server delta', () async {
      await seedToday();
      final uuid = 'contested';
      final localTime = DateTime.now().toUtc();
      store.entries[uuid] = makeStoredEntry(
        uuid: uuid,
        serverId: 600,
        quantityG: 250,
        updatedAt: localTime,
        pending: true,
      );
      api.deltaPages.add(
        SyncPage(
          entries: [
            SyncEntry(
              entry: _serverEntry(
                uuid: uuid,
                quantityG: 999,
                updatedAt: localTime.subtract(const Duration(minutes: 30)),
              ),
              deleted: false,
            ),
          ],
          nextCursor: 'cursor-1',
          hasMore: false,
        ),
      );

      await repo.refreshDay(today);

      expect(store.entries[uuid]!.quantityG, 250); // local pending change wins
    });

    test('adopts a newer server delta over a pending local change', () async {
      await seedToday();
      final uuid = 'contested-2';
      final localTime = DateTime.now().toUtc().subtract(
        const Duration(hours: 1),
      );
      store.entries[uuid] = makeStoredEntry(
        uuid: uuid,
        serverId: 601,
        quantityG: 250,
        updatedAt: localTime,
        pending: true,
      );
      api.deltaPages.add(
        SyncPage(
          entries: [
            SyncEntry(
              entry: _serverEntry(
                uuid: uuid,
                quantityG: 999,
                updatedAt: localTime.add(const Duration(minutes: 30)),
              ),
              deleted: false,
            ),
          ],
          nextCursor: 'cursor-1',
          hasMore: false,
        ),
      );

      await repo.refreshDay(today);

      expect(store.entries[uuid]!.quantityG, 999); // newer edit elsewhere wins
    });
  });

  group('refresh paths', () {
    test('first open bootstraps the cursor before the full fetch', () async {
      await repo.refreshDay(today);

      expect(api.syncCalls, greaterThanOrEqualTo(1));
      expect(store.cursor, 'cursor-0');
      expect(api.dayFetches, 1);
      expect(
        store.dayPayloads.containsKey(NutritionApiService.formatDate(today)),
        isTrue,
      );
    });

    test('server-rejected ops are dropped, not retried forever', () async {
      await seedToday();
      final uuid = 'rejected';
      store.entries[uuid] = makeStoredEntry(
        uuid: uuid,
        serverId: 700,
        pending: true,
      );
      // No matching server entry → the fake responds 404 to the update.
      await store.enqueueOp(
        kind: 'update',
        entryUuid: uuid,
        payload: {'quantity_g': 50},
        queuedAt: DateTime.now().toUtc(),
      );

      await repo.refreshDay(today);

      expect(store.outbox, isEmpty); // dropped after the 404
      expect(store.entries[uuid]!.pending, isFalse);
    });

    test('clear wipes entries, outbox and cursor', () async {
      await seedToday();
      store.entries['x'] = makeStoredEntry(uuid: 'x');
      await store.enqueueOp(
        kind: 'update',
        entryUuid: 'x',
        payload: const {},
        queuedAt: DateTime.now().toUtc(),
      );

      await repo.clear();

      expect(store.entries, isEmpty);
      expect(store.outbox, isEmpty);
      expect(store.cursor, isNull);
      expect(store.dayPayloads, isEmpty);
    });
  });
}
