import 'dart:io';

import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'real_sqlite.dart';

/// FoodLocalDb against real SQLite (KAN-127): the catalog cache's queries,
/// upsert identity rules and its eight-version schema history.
FoodItem _food({
  String name = 'Oats',
  String externalId = 'off-1',
  String? barcode = '111',
  String source = offSource,
  int? backendId,
  double? kcal = 380,
  int? overridesBackendId,
  String? overridesBarcode,
}) {
  return FoodItem(
    source: source,
    externalId: externalId,
    barcode: barcode,
    backendId: backendId,
    name: name,
    brands: 'Brand',
    kcal100g: kcal,
    overridesBackendId: overridesBackendId,
    overridesBarcode: overridesBarcode,
    rawSourceJson: '{"product": {"product_name": "$name"}}',
  );
}

void main() {
  late Directory dir;
  late FoodLocalDb db;

  setUp(() {
    dir = useRealSqlite();
    db = FoodLocalDb(userId: 3);
  });

  tearDown(() => db.close());

  test(
    'upsert inserts, then merges by barcode instead of duplicating',
    () async {
      final first = await db.upsertFood(_food(kcal: null));
      expect(first.localId, isNotNull);

      final merged = await db.upsertFood(
        _food(externalId: 'off-1', kcal: 380, name: 'Rolled oats'),
      );
      expect(merged.localId, first.localId);
      expect(merged.name, 'Rolled oats');
      expect(merged.kcal100g, 380);
      expect((await db.searchFoods('oats')).length, 1);
    },
  );

  test('barcode-less foods are matched by source + external id', () async {
    final a = await db.upsertFood(
      _food(barcode: null, source: customSource, externalId: 'cf-1'),
    );
    final b = await db.upsertFood(
      _food(
        barcode: null,
        source: customSource,
        externalId: 'cf-1',
        name: 'Granola v2',
      ),
    );
    expect(b.localId, a.localId);
    expect((await db.fetchByBarcode('111')), isNull);
  });

  test(
    'batch upsert runs in one transaction and returns stored rows',
    () async {
      final stored = await db.upsertFoods([
        _food(name: 'A', externalId: 'a', barcode: 'a'),
        _food(name: 'B', externalId: 'b', barcode: 'b'),
      ]);
      expect(stored.map((f) => f.localId), everyElement(isNotNull));
      expect((await db.fetchByBarcode('b'))!.name, 'B');
    },
  );

  test('search is case-insensitive and ranks recently used first', () async {
    final rarely = await db.upsertFood(
      _food(name: 'Apple pie', externalId: 'x', barcode: 'x'),
    );
    final often = await db.upsertFood(
      _food(name: 'apple', externalId: 'y', barcode: 'y'),
    );
    await db.updateLastUsed(often.localId!, DateTime.utc(2026, 10, 1), 100);

    final hits = await db.searchFoods('APPLE');
    expect(hits.map((f) => f.localId), [often.localId, rarely.localId]);
    expect(await db.searchFoods('   '), isEmpty);
  });

  test('last-used tracking keeps a same-amount streak', () async {
    final food = await db.upsertFood(_food());
    final id = food.localId!;
    await db.updateLastUsed(id, DateTime.utc(2026, 10, 1), 80);
    await db.updateLastUsed(id, DateTime.utc(2026, 10, 2), 80);
    var recent = (await db.fetchRecentFoods()).single;
    expect(recent.lastLoggedGrams, 80);
    expect(recent.sameAmountStreak, 2);
    expect(recent.lastUsedAt, DateTime.utc(2026, 10, 2));

    await db.updateLastUsed(id, DateTime.utc(2026, 10, 3), 120);
    recent = (await db.fetchRecentFoods()).single;
    expect(recent.sameAmountStreak, 1);
  });

  test('favorites toggle directly and survive a later upsert', () async {
    final food = await db.upsertFood(_food());
    await db.setFavorite(food.localId!, true);
    expect((await db.fetchFavorites()).single.localId, food.localId);

    await db.upsertFood(_food(name: 'Refreshed'));
    expect((await db.fetchFavorites()).single.name, 'Refreshed');

    await db.setFavorite(food.localId!, false);
    expect(await db.fetchFavorites(), isEmpty);
  });

  test('backend id patch reports whether the row still exists', () async {
    final food = await db.upsertFood(_food());
    expect(await db.updateBackendId(food.localId!, 55), isTrue);
    expect((await db.fetchByBarcode('111'))!.backendId, 55);

    await db.deleteFood(food.localId!);
    expect(await db.updateBackendId(food.localId!, 56), isFalse);
  });

  test('overrides resolve by the shadowed barcode', () async {
    await db.upsertFood(
      _food(
        source: customSource,
        externalId: 'cf-milk',
        barcode: null,
        name: 'My milk',
        overridesBackendId: 9,
        overridesBarcode: '999',
      ),
    );
    expect((await db.fetchOverrideForBarcode('999'))!.name, 'My milk');
    expect(await db.fetchOverrideForBarcode('000'), isNull);
  });

  test('clear empties the catalog', () async {
    await db.upsertFood(_food());
    await db.clear();
    expect(await db.searchFoods('oats'), isEmpty);
  });

  test('concurrent first calls share one open', () async {
    final results = await Future.wait([
      db.fetchRecentFoods(),
      db.fetchFavorites(),
    ]);
    expect(results, [isEmpty, isEmpty]);
  });

  test('a v1 database upgrades through every schema step to v8', () async {
    await db.close();
    final path = '${dir.path}/foods_u4.db';
    // v1: the original table, before signatures/hashes and every later column.
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (raw, _) async {
          await raw.execute(
            'CREATE TABLE foods (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'backend_id INTEGER, source TEXT NOT NULL, '
            'external_id TEXT NOT NULL, barcode TEXT, name TEXT NOT NULL, '
            'brands TEXT NOT NULL, image_url TEXT, kcal_100g REAL, '
            'protein_g_100g REAL, carbs_g_100g REAL, fat_g_100g REAL, '
            'sugars_g_100g REAL, fiber_g_100g REAL, salt_g_100g REAL, '
            'serving_size_g REAL, raw_source_json TEXT NOT NULL, '
            'nutriments_json TEXT, last_used_at TEXT, '
            'is_favorite INTEGER NOT NULL DEFAULT 0)',
          );
          await raw.insert('foods', {
            'source': offSource,
            'external_id': 'legacy',
            'barcode': '777',
            'name': 'Legacy bar',
            'brands': '',
            'raw_source_json': '{}',
            'is_favorite': 1,
          });
        },
      ),
    );
    await v1.close();

    db = FoodLocalDb(userId: 4);
    final legacy = (await db.fetchByBarcode('777'))!;
    expect(legacy.name, 'Legacy bar');
    expect(legacy.isFavorite, isTrue);
    expect(legacy.sameAmountStreak, 0);

    // Every later column is writable after the upgrade.
    await db.upsertFood(
      _food(
        barcode: '777',
        externalId: 'legacy',
        overridesBackendId: 1,
        overridesBarcode: '1',
      ).copyWith(gramsPerPiece: 50, pieceUnit: 'bar', nutritionBasis: 'cooked'),
    );
    final upgraded = (await db.fetchByBarcode('777'))!;
    expect(upgraded.gramsPerPiece, 50);
    expect(upgraded.pieceUnit, 'bar');
  });
}
