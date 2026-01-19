import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'food_models.dart';

class FoodLocalDb {
  FoodLocalDb({Database? database}) : _database = database;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _openDatabase();
    return _database!;
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
    _database = null;
  }

  Future<FoodItem> upsertFood(FoodItem item) async {
    final db = await database;
    return _upsertFood(db, item);
  }

  Future<List<FoodItem>> upsertFoods(List<FoodItem> items) async {
    final db = await database;
    return db.transaction((txn) async {
      final results = <FoodItem>[];
      for (final item in items) {
        results.add(await _upsertFood(txn, item));
      }
      return results;
    });
  }

  Future<FoodItem> _upsertFood(DatabaseExecutor db, FoodItem item) async {
    final existing = await _findExisting(db, item);
    final merged = existing == null
        ? item
        : _mergeFood(existing, item).copyWith(localId: existing.localId);

    if (existing != null && existing.localId != null) {
      await db.update(
        'foods',
        merged.toDbMap(),
        where: 'id = ?',
        whereArgs: [existing.localId],
      );
      return merged;
    }

    final id = await db.insert(
      'foods',
      merged.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return merged.copyWith(localId: id);
  }

  Future<void> updateLastUsed(int localId, DateTime usedAt) async {
    final db = await database;
    await db.update(
      'foods',
      {'last_used_at': usedAt.toIso8601String()},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> updateBackendId(int localId, int backendId) async {
    final db = await database;
    await db.update(
      'foods',
      {'backend_id': backendId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  Future<List<FoodItem>> searchFoods(String query, {int limit = 20}) async {
    final db = await database;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return [];
    }
    final rows = await db.query(
      'foods',
      where: 'name LIKE ? COLLATE NOCASE',
      whereArgs: ['%$trimmed%'],
      orderBy: 'last_used_at IS NULL, last_used_at DESC, name ASC',
      limit: limit,
    );
    return rows.map(FoodItem.fromDbMap).toList();
  }

  Future<List<FoodItem>> fetchRecentFoods({int limit = 20}) async {
    final db = await database;
    final rows = await db.query(
      'foods',
      where: 'last_used_at IS NOT NULL',
      orderBy: 'last_used_at DESC',
      limit: limit,
    );
    return rows.map(FoodItem.fromDbMap).toList();
  }

  Future<List<FoodItem>> fetchFavorites({int limit = 20}) async {
    final db = await database;
    final rows = await db.query(
      'foods',
      where: 'is_favorite = 1',
      orderBy: 'name ASC',
      limit: limit,
    );
    return rows.map(FoodItem.fromDbMap).toList();
  }

  Future<FoodItem?> fetchByBarcode(String barcode) async {
    final db = await database;
    final rows = await db.query(
      'foods',
      where: 'barcode = ?',
      whereArgs: [barcode],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return FoodItem.fromDbMap(rows.first);
  }

  Future<FoodItem?> _findExisting(DatabaseExecutor db, FoodItem item) async {
    if (item.barcode != null && item.barcode!.isNotEmpty) {
      final rows = await db.query(
        'foods',
        where: 'barcode = ?',
        whereArgs: [item.barcode],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return FoodItem.fromDbMap(rows.first);
      }
    }

    final rows = await db.query(
      'foods',
      where: 'source = ? AND external_id = ?',
      whereArgs: [item.source, item.externalId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return FoodItem.fromDbMap(rows.first);
  }

  FoodItem _mergeFood(FoodItem existing, FoodItem incoming) {
    final rawJson = incoming.rawSourceJson.trim();
    final hasRawJson = rawJson.isNotEmpty && rawJson != '{}';
    return existing.copyWith(
      backendId: incoming.backendId ?? existing.backendId,
      source: incoming.source.isNotEmpty ? incoming.source : existing.source,
      externalId: incoming.externalId.isNotEmpty
          ? incoming.externalId
          : existing.externalId,
      barcode: (incoming.barcode != null && incoming.barcode!.isNotEmpty)
          ? incoming.barcode
          : existing.barcode,
      name: incoming.name.isNotEmpty ? incoming.name : existing.name,
      brands: incoming.brands.isNotEmpty ? incoming.brands : existing.brands,
      imageUrl: incoming.imageUrl ?? existing.imageUrl,
      offImageLargeUrl:
          incoming.offImageLargeUrl ?? existing.offImageLargeUrl,
      offImageSmallUrl:
          incoming.offImageSmallUrl ?? existing.offImageSmallUrl,
      imageSignature: incoming.imageSignature ?? existing.imageSignature,
      contentHash: incoming.contentHash.isNotEmpty
          ? incoming.contentHash
          : existing.contentHash,
      kcal100g: incoming.kcal100g ?? existing.kcal100g,
      proteinG100g: incoming.proteinG100g ?? existing.proteinG100g,
      carbsG100g: incoming.carbsG100g ?? existing.carbsG100g,
      fatG100g: incoming.fatG100g ?? existing.fatG100g,
      sugarsG100g: incoming.sugarsG100g ?? existing.sugarsG100g,
      fiberG100g: incoming.fiberG100g ?? existing.fiberG100g,
      saltG100g: incoming.saltG100g ?? existing.saltG100g,
      servingSizeG: incoming.servingSizeG ?? existing.servingSizeG,
      rawSourceJson: hasRawJson ? incoming.rawSourceJson : existing.rawSourceJson,
      nutrimentsJson: incoming.nutrimentsJson ?? existing.nutrimentsJson,
      lastUsedAt: incoming.lastUsedAt ?? existing.lastUsedAt,
      isFavorite: incoming.isFavorite || existing.isFavorite,
    );
  }

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/foods.db';
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute(
          '''
          CREATE TABLE foods (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            backend_id INTEGER,
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            barcode TEXT,
            name TEXT NOT NULL,
            brands TEXT NOT NULL,
            image_url TEXT,
            off_image_large_url TEXT,
            off_image_small_url TEXT,
            image_signature TEXT,
            content_hash TEXT,
            kcal_100g REAL,
            protein_g_100g REAL,
            carbs_g_100g REAL,
            fat_g_100g REAL,
            sugars_g_100g REAL,
            fiber_g_100g REAL,
            salt_g_100g REAL,
            serving_size_g REAL,
            raw_source_json TEXT NOT NULL,
            nutriments_json TEXT,
            last_used_at TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0
          )
          ''',
        );
        await db.execute(
          'CREATE UNIQUE INDEX idx_foods_barcode ON foods(barcode)',
        );
        await db.execute(
          'CREATE UNIQUE INDEX idx_foods_source_external_id ON foods(source, external_id)',
        );
        await db.execute('CREATE INDEX idx_foods_name ON foods(name)');
        await db.execute(
          'CREATE INDEX idx_foods_last_used ON foods(last_used_at)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE foods ADD COLUMN off_image_large_url TEXT',
          );
          await db.execute(
            'ALTER TABLE foods ADD COLUMN off_image_small_url TEXT',
          );
          await db.execute('ALTER TABLE foods ADD COLUMN image_signature TEXT');
          await db.execute('ALTER TABLE foods ADD COLUMN content_hash TEXT');
        }
      },
    );
  }
}
