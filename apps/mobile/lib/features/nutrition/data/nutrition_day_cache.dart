import 'dart:async';
import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Local stale-while-revalidate cache for nutrition day logs.
///
/// Stores the server's raw `/nutrition/day` payload keyed by date string, so
/// the page can render a day instantly (and offline) while a fresh copy is
/// fetched in the background. The server stays the source of truth — this never
/// originates data, it only mirrors the last response and is safe to wipe.
///
/// Every method is best-effort: callers wrap usage so a missing/corrupt cache
/// degrades to network-only rather than breaking the page.
class NutritionDayCache {
  NutritionDayCache({Database? database}) : _database = database;

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

  /// Returns the cached raw payload for [dateKey], or null if absent/corrupt.
  Future<Map<String, dynamic>?> read(String dateKey) async {
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

  /// Overwrites the cached payload for [dateKey] with the latest server response.
  Future<void> write(String dateKey, Map<String, dynamic> payload) async {
    final db = await _db;
    await db.insert(
      'day_cache',
      {
        'date': dateKey,
        'payload': jsonEncode(payload),
        'cached_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Drops every cached day. Call on logout so the next user can't briefly see
  /// the previous user's log (the cache isn't namespaced per user).
  Future<void> clear() async {
    final db = await _db;
    await db.delete('day_cache');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
    _database = null;
  }

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/nutrition_cache.db';
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE day_cache ('
          'date TEXT PRIMARY KEY, '
          'payload TEXT NOT NULL, '
          'cached_at TEXT NOT NULL)',
        );
      },
    );
  }
}
