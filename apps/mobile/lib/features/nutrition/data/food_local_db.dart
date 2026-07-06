import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'food_models.dart';

class FoodLocalDb {
  FoodLocalDb({Database? database}) : _database = database;

  Database? _database;
  Completer<Database>? _databaseCompleter;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }
    final completer = _databaseCompleter;
    if (completer != null) {
      return completer.future;
    }
    final initCompleter = Completer<Database>();
    _databaseCompleter = initCompleter;
    try {
      final db = await _openDatabase();
      _database = db;
      initCompleter.complete(db);
      return db;
    } catch (error, stackTrace) {
      initCompleter.completeError(error, stackTrace);
      rethrow;
    } finally {
      if (_databaseCompleter == initCompleter) {
        _databaseCompleter = null;
      }
    }
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

  Future<void> deleteFood(int localId) async {
    final db = await database;
    await db.delete('foods', where: 'id = ?', whereArgs: [localId]);
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

  /// Sets the favorite flag directly. Deliberately not routed through
  /// [upsertFood]: its merge ORs favorites together (so a stale fetch never
  /// clears one), which would make un-favoriting impossible.
  Future<void> setFavorite(int localId, bool isFavorite) async {
    final db = await database;
    await db.update(
      'foods',
      {'is_favorite': isFavorite ? 1 : 0},
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

  /// The caller's live override shadowing the food with [barcode], if any —
  /// lets a barcode scan resolve straight to the user's corrected copy.
  Future<FoodItem?> fetchOverrideForBarcode(String barcode) async {
    final db = await database;
    final rows = await db.query(
      'foods',
      where: 'overrides_barcode = ?',
      whereArgs: [barcode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return FoodItem.fromDbMap(rows.first);
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
    // Custom foods replace wholesale: the incoming item is the owner's edit,
    // so a field they cleared must stay cleared. Field-by-field ?? merging
    // below is for OFF rows, where incoming nulls mean "not fetched", not
    // "removed". Identity/bookkeeping still carries over.
    if (incoming.isCustom) {
      return incoming.copyWith(
        backendId: incoming.backendId ?? existing.backendId,
        lastUsedAt: incoming.lastUsedAt ?? existing.lastUsedAt,
        isFavorite: incoming.isFavorite || existing.isFavorite,
      );
    }
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
      nutritionBasis: incoming.nutritionBasis ?? existing.nutritionBasis,
      communityVerifiedAt:
          incoming.communityVerifiedAt ?? existing.communityVerifiedAt,
      rawSourceJson: hasRawJson
          ? incoming.rawSourceJson
          : existing.rawSourceJson,
      nutrimentsJson: incoming.nutrimentsJson ?? existing.nutrimentsJson,
      lastUsedAt: incoming.lastUsedAt ?? existing.lastUsedAt,
      isFavorite: incoming.isFavorite || existing.isFavorite,
    );
  }

  // Canonical column definitions for the `foods` table: name -> type/constraints.
  // This is the single source of truth — both the CREATE TABLE DDL and the
  // INSERT ... SELECT column list are derived from it, so they can never drift.
  // Insertion order is significant: it's the column order used by copies.
  static const Map<String, String> _foodsColumns = {
    'id': 'INTEGER PRIMARY KEY AUTOINCREMENT',
    'backend_id': 'INTEGER',
    'source': 'TEXT NOT NULL',
    'external_id': 'TEXT NOT NULL',
    'barcode': 'TEXT',
    'name': 'TEXT NOT NULL',
    'brands': 'TEXT NOT NULL',
    'image_url': 'TEXT',
    'image_signature': 'TEXT',
    'content_hash': 'TEXT',
    'kcal_100g': 'REAL',
    'protein_g_100g': 'REAL',
    'carbs_g_100g': 'REAL',
    'fat_g_100g': 'REAL',
    'sugars_g_100g': 'REAL',
    'fiber_g_100g': 'REAL',
    'salt_g_100g': 'REAL',
    'serving_size_g': 'REAL',
    'grams_per_piece': 'REAL',
    'piece_unit': 'TEXT',
    'nutrition_basis': 'TEXT',
    'overrides_backend_id': 'INTEGER',
    'overrides_barcode': 'TEXT',
    'community_verified_at': 'TEXT',
    'raw_source_json': 'TEXT NOT NULL',
    'nutriments_json': 'TEXT',
    'last_used_at': 'TEXT',
    'is_favorite': 'INTEGER NOT NULL DEFAULT 0',
  };

  // Column definitions for `CREATE TABLE`, e.g. "id INTEGER PRIMARY KEY, ...".
  static final String _foodsColumnsDdl = _foodsColumns.entries
      .map((column) => '${column.key} ${column.value}')
      .join(', ');

  // Snapshot of the columns as they existed at schema v3, frozen as a literal so
  // the v3 table-rebuild below never references columns added in later versions
  // (those are applied afterwards by their own ALTER steps).
  static const String _foodsColumnsV3DdlSnapshot =
      'id INTEGER PRIMARY KEY AUTOINCREMENT, backend_id INTEGER, '
      'source TEXT NOT NULL, external_id TEXT NOT NULL, barcode TEXT, '
      'name TEXT NOT NULL, brands TEXT NOT NULL, image_url TEXT, '
      'image_signature TEXT, content_hash TEXT, kcal_100g REAL, '
      'protein_g_100g REAL, carbs_g_100g REAL, fat_g_100g REAL, '
      'sugars_g_100g REAL, fiber_g_100g REAL, salt_g_100g REAL, '
      'serving_size_g REAL, raw_source_json TEXT NOT NULL, '
      'nutriments_json TEXT, last_used_at TEXT, '
      'is_favorite INTEGER NOT NULL DEFAULT 0';
  static const String _foodsColumnListV3Snapshot =
      'id, backend_id, source, external_id, barcode, name, brands, image_url, '
      'image_signature, content_hash, kcal_100g, protein_g_100g, carbs_g_100g, '
      'fat_g_100g, sugars_g_100g, fiber_g_100g, salt_g_100g, serving_size_g, '
      'raw_source_json, nutriments_json, last_used_at, is_favorite';

  Future<void> _createIndexes(DatabaseExecutor db) async {
    await db.execute('CREATE UNIQUE INDEX idx_foods_barcode ON foods(barcode)');
    await db.execute(
      'CREATE UNIQUE INDEX idx_foods_source_external_id ON foods(source, external_id)',
    );
    await db.execute('CREATE INDEX idx_foods_name ON foods(name)');
    await db.execute('CREATE INDEX idx_foods_last_used ON foods(last_used_at)');
  }

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/foods.db';
    return openDatabase(
      path,
      version: 7,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE foods ($_foodsColumnsDdl)');
        await _createIndexes(db);
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
        if (oldVersion < 3) {
          // Drop the now-unused off_image_* columns. ALTER TABLE DROP COLUMN
          // requires SQLite >= 3.35.0, which is newer than the platform SQLite
          // on many shipping Android/iOS versions, so rebuild the table instead
          // (the portable approach that works on every SQLite version).
          // onUpgrade already runs inside a transaction, so these statements
          // are applied atomically without an explicit nested transaction.
          await db.execute(
            'CREATE TABLE foods_new ($_foodsColumnsV3DdlSnapshot)',
          );
          await db.execute(
            'INSERT INTO foods_new ($_foodsColumnListV3Snapshot) '
            'SELECT $_foodsColumnListV3Snapshot FROM foods',
          );
          await db.execute('DROP TABLE foods');
          await db.execute('ALTER TABLE foods_new RENAME TO foods');
          await _createIndexes(db);
        }
        if (oldVersion < 4) {
          // Piece-based logging support: weight of one piece + its noun, both
          // nullable so existing rows simply have no piece dimension.
          await db.execute('ALTER TABLE foods ADD COLUMN grams_per_piece REAL');
          await db.execute('ALTER TABLE foods ADD COLUMN piece_unit TEXT');
        }
        if (oldVersion < 5) {
          // Cooked-basis marker (see cookedNutritionBasis); nullable, so
          // existing rows stay per-100g as sold.
          await db.execute('ALTER TABLE foods ADD COLUMN nutrition_basis TEXT');
        }
        if (oldVersion < 6) {
          // Fork-on-edit overrides (KAN-31): which global item a custom food
          // shadows, by backend id and (locally) by barcode for scan lookup.
          await db.execute(
            'ALTER TABLE foods ADD COLUMN overrides_backend_id INTEGER',
          );
          await db.execute(
            'ALTER TABLE foods ADD COLUMN overrides_barcode TEXT',
          );
        }
        if (oldVersion < 7) {
          // Community convergence marker (KAN-32): when the shared item's
          // nutrition was promoted from converged user edits. Nullable —
          // existing rows are simply unverified.
          await db.execute(
            'ALTER TABLE foods ADD COLUMN community_verified_at TEXT',
          );
        }
      },
    );
  }
}
