import 'dart:async';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'food_models.dart';

/// One meal entry as held in the local entry-level cache (KAN-28).
///
/// [uuid] is the client-generated identity shared with the server, stable from
/// the moment an entry is created (possibly offline) so replays and other
/// devices dedupe on it. [serverId] arrives once the server has seen the entry.
class StoredEntry {
  const StoredEntry({
    required this.uuid,
    this.serverId,
    required this.mealType,
    required this.consumedAt,
    required this.quantityG,
    required this.kcal,
    required this.food,
    required this.updatedAt,
    this.deleted = false,
    this.pending = false,
  });

  final String uuid;
  final int? serverId;
  final String mealType;

  /// True UTC instant, mirroring the server's `consumed_at`.
  final DateTime consumedAt;
  final double quantityG;
  final double kcal;
  final FoodItem food;

  /// Last-write-wins mutation time (UTC). For a local offline change this is
  /// the moment the user made it; for server rows it's the server's value.
  final DateTime updatedAt;

  /// Tombstone: the entry is deleted but kept so the delete can sync out (and
  /// so a delta-merge can't resurrect it).
  final bool deleted;

  /// Has local changes not yet acknowledged by the server (outbox not empty
  /// for this entry). A pending row wins over older server deltas.
  final bool pending;

  StoredEntry copyWith({
    int? serverId,
    String? mealType,
    double? quantityG,
    double? kcal,
    DateTime? updatedAt,
    bool? deleted,
    bool? pending,
  }) {
    return StoredEntry(
      uuid: uuid,
      serverId: serverId ?? this.serverId,
      mealType: mealType ?? this.mealType,
      consumedAt: consumedAt,
      quantityG: quantityG ?? this.quantityG,
      kcal: kcal ?? this.kcal,
      food: food,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
      pending: pending ?? this.pending,
    );
  }
}

/// A queued offline write awaiting replay ("outbox").
class OutboxOp {
  const OutboxOp({
    required this.id,
    required this.kind,
    required this.entryUuid,
    required this.payload,
    required this.queuedAt,
  });

  static const create = 'create';
  static const update = 'update';
  static const delete = 'delete';

  final int id;
  final String kind;
  final String entryUuid;

  /// Op-specific fields (e.g. the create body or the patch diff).
  final Map<String, dynamic> payload;

  /// When the user made the change — the LWW mutation time sent on replay.
  final DateTime queuedAt;
}

/// Local SQLite store backing the nutrition log (KAN-28 Phases 2–3).
///
/// Grew out of the Phase-1 day-payload cache (still the `day_cache` table, so
/// a v1 database upgrades in place) into a real sync layer:
///
///  * `entries`   — entry-level mirror of the user's log, merged from full-day
///                  fetches, delta pulls, and optimistic local writes.
///  * `outbox`    — offline creates/edits/deletes queued for replay.
///  * `sync_meta` — the delta-sync cursor and similar bookkeeping.
///
/// The server remains the source of truth; everything here is reconstructible
/// from it except unsynced outbox ops. Methods are not best-effort — callers
/// (the repository) decide what failures may be swallowed.
class NutritionLocalStore {
  NutritionLocalStore({Database? database}) : _database = database;

  static const _syncCursorKey = 'sync_cursor';

  Database? _database;
  Completer<Database>? _databaseCompleter;

  Future<Database> get _db async {
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

  // --- day payload cache (Phase 1, unchanged semantics) ---

  /// Returns the cached raw `/day` payload for [dateKey], or null.
  Future<Map<String, dynamic>?> readDayPayload(String dateKey) async {
    final db = await _db;
    final rows = await db.query(
      'day_cache',
      columns: ['payload'],
      where: 'date = ?',
      whereArgs: [dateKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final payload = rows.first['payload'] as String?;
    if (payload == null) {
      return null;
    }
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Overwrites the cached payload for [dateKey]. Doubles as the marker that
  /// the day was seeded from a full fetch (see [isDaySeeded]).
  Future<void> writeDayPayload(
    String dateKey,
    Map<String, dynamic> payload,
  ) async {
    final db = await _db;
    await db.insert('day_cache', {
      'date': dateKey,
      'payload': jsonEncode(payload),
      'cached_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Whether [dateKey] was ever seeded by a full `/day` fetch. Seeded days can
  /// be composed from the entry table + delta pulls; unseeded days need a full
  /// fetch first.
  Future<bool> isDaySeeded(String dateKey) async {
    final db = await _db;
    final rows = await db.query(
      'day_cache',
      columns: ['date'],
      where: 'date = ?',
      whereArgs: [dateKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // --- entry-level cache ---

  /// Inserts or replaces [entry] unconditionally. Merge policy (LWW, pending
  /// protection) lives in the repository, which reads before writing.
  Future<void> upsertEntry(StoredEntry entry) async {
    final db = await _db;
    await db.insert(
      'entries',
      _entryToRow(entry),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<StoredEntry?> readEntry(String uuid) async {
    final db = await _db;
    final rows = await db.query(
      'entries',
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _entryFromRow(rows.first);
  }

  /// Live (non-tombstoned) entries with `consumed_at` in `[startUtc, endUtc)`,
  /// ordered by time — the day-composition query.
  Future<List<StoredEntry>> readEntriesInRange(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final db = await _db;
    final rows = await db.query(
      'entries',
      where: 'deleted = 0 AND consumed_at_ms >= ? AND consumed_at_ms < ?',
      whereArgs: [
        startUtc.millisecondsSinceEpoch,
        endUtc.millisecondsSinceEpoch,
      ],
      orderBy: 'consumed_at_ms ASC',
    );
    return [for (final row in rows) _entryFromRow(row)];
  }

  /// Permanently forgets a tombstone once the server has acknowledged the
  /// delete (or the entry never reached the server at all).
  Future<void> purgeEntry(String uuid) async {
    final db = await _db;
    await db.delete('entries', where: 'uuid = ?', whereArgs: [uuid]);
  }

  // --- outbox ---

  Future<void> enqueueOp({
    required String kind,
    required String entryUuid,
    required Map<String, dynamic> payload,
    required DateTime queuedAt,
  }) async {
    final db = await _db;
    await db.insert('outbox', {
      'kind': kind,
      'entry_uuid': entryUuid,
      'payload': jsonEncode(payload),
      'queued_at_ms': queuedAt.millisecondsSinceEpoch,
    });
  }

  /// All queued ops, oldest first — replay order matters (a create must reach
  /// the server before edits that reference the same uuid).
  Future<List<OutboxOp>> readOutbox() async {
    final db = await _db;
    final rows = await db.query('outbox', orderBy: 'id ASC');
    return [
      for (final row in rows)
        OutboxOp(
          id: row['id'] as int,
          kind: row['kind'] as String,
          entryUuid: row['entry_uuid'] as String,
          payload: _decodeObject(row['payload'] as String?),
          queuedAt: DateTime.fromMillisecondsSinceEpoch(
            row['queued_at_ms'] as int,
            isUtc: true,
          ),
        ),
    ];
  }

  Future<void> removeOp(int id) async {
    final db = await _db;
    await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  /// Entries with at least one queued op — i.e. writes the server hasn't
  /// acknowledged yet. Read-only surfacing for the UI (KAN-56); counts
  /// entries, not ops, so three edits to one entry read as "1 waiting".
  Future<int> countPendingEntries() async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT entry_uuid) AS c FROM outbox',
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<bool> hasOpsFor(String entryUuid) async {
    final db = await _db;
    final rows = await db.query(
      'outbox',
      columns: ['id'],
      where: 'entry_uuid = ?',
      whereArgs: [entryUuid],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Drops every queued op for one entry (e.g. deleting an entry that only
  /// ever existed offline cancels its queued create/edits outright).
  Future<void> removeOpsFor(String entryUuid) async {
    final db = await _db;
    await db.delete('outbox', where: 'entry_uuid = ?', whereArgs: [entryUuid]);
  }

  // --- sync metadata ---

  Future<String?> readSyncCursor() => _readMeta(_syncCursorKey);

  Future<void> writeSyncCursor(String cursor) =>
      _writeMeta(_syncCursorKey, cursor);

  Future<String?> _readMeta(String key) async {
    final db = await _db;
    final rows = await db.query(
      'sync_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _writeMeta(String key, String value) async {
    final db = await _db;
    await db.insert('sync_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Drops everything. Call on logout so the next user on this device can't
  /// see (or accidentally replay writes into) the previous user's log — the
  /// store isn't namespaced per user.
  Future<void> clear() async {
    final db = await _db;
    await db.delete('day_cache');
    await db.delete('entries');
    await db.delete('outbox');
    await db.delete('sync_meta');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
    _database = null;
  }

  Map<String, Object?> _entryToRow(StoredEntry entry) {
    return {
      'uuid': entry.uuid,
      'server_id': entry.serverId,
      'meal_type': entry.mealType,
      'consumed_at_ms': entry.consumedAt.millisecondsSinceEpoch,
      'quantity_g': entry.quantityG,
      'kcal': entry.kcal,
      'food_json': jsonEncode(entry.food.toDbMap()),
      'updated_at_ms': entry.updatedAt.millisecondsSinceEpoch,
      'deleted': entry.deleted ? 1 : 0,
      'pending': entry.pending ? 1 : 0,
    };
  }

  StoredEntry _entryFromRow(Map<String, Object?> row) {
    return StoredEntry(
      uuid: row['uuid'] as String,
      serverId: row['server_id'] as int?,
      mealType: (row['meal_type'] as String?) ?? '',
      consumedAt: DateTime.fromMillisecondsSinceEpoch(
        row['consumed_at_ms'] as int,
        isUtc: true,
      ),
      quantityG: (row['quantity_g'] as num?)?.toDouble() ?? 0,
      kcal: (row['kcal'] as num?)?.toDouble() ?? 0,
      food: FoodItem.fromDbMap(
        _decodeObject(row['food_json'] as String?).cast<String, Object?>(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at_ms'] as int,
        isUtc: true,
      ),
      deleted: (row['deleted'] as int? ?? 0) == 1,
      pending: (row['pending'] as int? ?? 0) == 1,
    );
  }

  static Map<String, dynamic> _decodeObject(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/nutrition_cache.db';
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createDayCache(db);
        await _createSyncTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createSyncTables(db);
          // A day_cache row now doubles as "this day was seeded into the
          // entries table" (see isDaySeeded) — v1 rows never were, and their
          // entries also predate client uuids. Drop them; they're only a
          // cache and re-fetch on next open.
          await db.delete('day_cache');
        }
      },
    );
  }

  static Future<void> _createDayCache(Database db) async {
    await db.execute(
      'CREATE TABLE day_cache ('
      'date TEXT PRIMARY KEY, '
      'payload TEXT NOT NULL, '
      'cached_at TEXT NOT NULL)',
    );
  }

  static Future<void> _createSyncTables(Database db) async {
    await db.execute(
      'CREATE TABLE entries ('
      'uuid TEXT PRIMARY KEY, '
      'server_id INTEGER, '
      'meal_type TEXT NOT NULL, '
      'consumed_at_ms INTEGER NOT NULL, '
      'quantity_g REAL NOT NULL, '
      'kcal REAL NOT NULL, '
      'food_json TEXT NOT NULL, '
      'updated_at_ms INTEGER NOT NULL, '
      'deleted INTEGER NOT NULL DEFAULT 0, '
      'pending INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE INDEX entries_consumed_at_idx ON entries (consumed_at_ms)',
    );
    await db.execute(
      'CREATE TABLE outbox ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'kind TEXT NOT NULL, '
      'entry_uuid TEXT NOT NULL, '
      'payload TEXT NOT NULL, '
      'queued_at_ms INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE sync_meta ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL)',
    );
  }
}
