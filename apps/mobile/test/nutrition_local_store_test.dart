import 'dart:io';

import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'in_memory_nutrition_store.dart' show makeStoredEntry, makeTestFood;
import 'real_sqlite.dart';

/// NutritionLocalStore against real SQLite (KAN-127): SQL, schema upgrades
/// and upgrades the in-memory fake can't exercise. (Transaction tests land
/// with KAN-120's inTransaction.)
void main() {
  late Directory dir;
  late NutritionLocalStore store;

  setUp(() {
    dir = useRealSqlite();
    store = NutritionLocalStore(userId: 7);
  });

  tearDown(() => store.close());

  group('day payload cache', () {
    test('round-trips payloads and doubles as the seeded marker', () async {
      expect(await store.readDayPayload('2026-10-01'), isNull);
      expect(await store.isDaySeeded('2026-10-01'), isFalse);

      await store.writeDayPayload('2026-10-01', {'date': '2026-10-01'});
      await store.writeDayPayload('2026-10-01', {'date': 'overwritten'});

      expect(await store.readDayPayload('2026-10-01'), {'date': 'overwritten'});
      expect(await store.isDaySeeded('2026-10-01'), isTrue);
    });

    test('writes the per-user file name (KAN-64)', () async {
      await store.writeSyncCursor('c');
      expect(File('${dir.path}/nutrition_cache_u7.db').existsSync(), isTrue);
    });
  });

  group('entries', () {
    test('round-trip every column, including the embedded food', () async {
      final food = makeTestFood(name: 'Rice', kcal100g: 130);
      final entry = makeStoredEntry(
        uuid: 'u-1',
        serverId: 42,
        mealType: 'dinner',
        consumedAt: DateTime.utc(2026, 10, 1, 18, 30),
        quantityG: 150,
        kcal: 195,
        food: food,
        updatedAt: DateTime.utc(2026, 10, 1, 18, 31),
        pending: true,
      );
      await store.upsertEntry(entry);

      final read = (await store.readEntry('u-1'))!;
      expect(read.serverId, 42);
      expect(read.mealType, 'dinner');
      expect(read.consumedAt, DateTime.utc(2026, 10, 1, 18, 30));
      expect(read.quantityG, 150);
      expect(read.kcal, 195);
      expect(read.food.name, 'Rice');
      expect(read.food.kcal100g, 130);
      expect(read.updatedAt, DateTime.utc(2026, 10, 1, 18, 31));
      expect(read.pending, isTrue);
      expect(read.deleted, isFalse);
      expect(await store.readEntry('missing'), isNull);
    });

    test('range reads skip tombstones, honor [start, end) and sort', () async {
      DateTime at(int hour) => DateTime.utc(2026, 10, 1, hour);
      await store.upsertEntry(
        makeStoredEntry(uuid: 'late', consumedAt: at(20)),
      );
      await store.upsertEntry(
        makeStoredEntry(uuid: 'early', consumedAt: at(8)),
      );
      await store.upsertEntry(
        makeStoredEntry(uuid: 'gone', consumedAt: at(9), deleted: true),
      );
      await store.upsertEntry(makeStoredEntry(uuid: 'end', consumedAt: at(23)));

      final hits = await store.readEntriesInRange(at(0), at(23));
      expect(hits.map((e) => e.uuid), ['early', 'late']);
    });

    test('purge removes the row', () async {
      await store.upsertEntry(makeStoredEntry(uuid: 'p'));
      await store.purgeEntry('p');
      expect(await store.readEntry('p'), isNull);
    });
  });

  group('outbox', () {
    test('keeps FIFO order and counts entries, not ops', () async {
      final at = DateTime.utc(2026, 10, 1);
      for (final (kind, uuid) in const [
        (OutboxOp.create, 'a'),
        (OutboxOp.update, 'a'),
        (OutboxOp.create, 'b'),
      ]) {
        await store.enqueueOp(
          kind: kind,
          entryUuid: uuid,
          payload: {'kind': kind},
          queuedAt: at,
        );
      }

      final ops = await store.readOutbox();
      expect(ops.map((op) => '${op.kind}:${op.entryUuid}'), [
        'create:a',
        'update:a',
        'create:b',
      ]);
      expect(ops.first.payload, {'kind': 'create'});
      expect(ops.first.queuedAt, at);
      expect(await store.countPendingEntries(), 2);
      expect(await store.hasOpsFor('a'), isTrue);

      await store.removeOp(ops.first.id);
      expect((await store.readOutbox()).length, 2);
      await store.removeOpsFor('a');
      expect(await store.hasOpsFor('a'), isFalse);
      expect(await store.countPendingEntries(), 1);
    });
  });

  test('clear wipes every table but leaves the store usable', () async {
    await store.writeDayPayload('d', {});
    await store.upsertEntry(makeStoredEntry(uuid: 'x'));
    await store.writeSyncCursor('cursor');
    await store.enqueueOp(
      kind: OutboxOp.delete,
      entryUuid: 'x',
      payload: const {},
      queuedAt: DateTime.utc(2026),
    );

    await store.clear();

    expect(await store.isDaySeeded('d'), isFalse);
    expect(await store.readEntry('x'), isNull);
    expect(await store.readSyncCursor(), isNull);
    expect(await store.readOutbox(), isEmpty);
    await store.writeSyncCursor('after');
    expect(await store.readSyncCursor(), 'after');
  });

  test('data survives close and reopen', () async {
    await store.writeSyncCursor('persisted');
    await store.close();
    store = NutritionLocalStore(userId: 7);
    expect(await store.readSyncCursor(), 'persisted');
  });

  test('concurrent first calls share one open', () async {
    final results = await Future.wait([
      store.readSyncCursor(),
      store.isDaySeeded('d'),
      store.countPendingEntries(),
    ]);
    expect(results, [null, false, 0]);
  });

  test('upgrading a v1 database adds the sync tables and drops stale '
      'day payloads', () async {
    await store.close();
    final path = '${dir.path}/nutrition_cache_u9.db';
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE day_cache (date TEXT PRIMARY KEY, '
            'payload TEXT NOT NULL, cached_at TEXT NOT NULL)',
          );
          await db.insert('day_cache', {
            'date': '2026-01-01',
            'payload': '{}',
            'cached_at': '2026-01-01T00:00:00Z',
          });
        },
      ),
    );
    await v1.close();

    store = NutritionLocalStore(userId: 9);
    expect(await store.isDaySeeded('2026-01-01'), isFalse);
    await store.upsertEntry(makeStoredEntry(uuid: 'after-upgrade'));
    expect(await store.readEntry('after-upgrade'), isNotNull);
  });
}
