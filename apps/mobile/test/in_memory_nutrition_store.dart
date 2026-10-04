import 'dart:async';

import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';

/// In-memory stand-in for [NutritionLocalStore] so tests don't touch
/// sqflite / path_provider platform channels. Mirrors the store's contract
/// closely enough for repository and widget tests: entry rows keyed by uuid,
/// FIFO outbox, day payloads keyed by date string.
///
/// Transactions mirror the real store's failure modes too (KAN-120): writes
/// roll back when the action throws, and touching this outer store from
/// inside a transaction's own call chain throws a [StateError] — the real
/// store deadlocks there — while unrelated concurrent calls still go through
/// (the real store just makes them wait).
class InMemoryNutritionStore implements NutritionLocalStore {
  InMemoryNutritionStore({Map<String, Map<String, dynamic>>? seedPayloads})
    : dayPayloads = {...?seedPayloads};

  final Map<String, Map<String, dynamic>> dayPayloads;
  final Map<String, StoredEntry> entries = {};
  final List<OutboxOp> outbox = [];
  int _nextOpId = 1;
  String? cursor;
  bool cleared = false;
  final List<String> payloadWrites = [];

  /// Uuids whose [upsertEntry] throws — lets tests fail a merge mid-page.
  final Set<String> failUpsertFor = {};

  /// Zone marker for "running inside one of this store's transactions".
  final Object _txnZoneKey = Object();
  bool _viaTxnView = false;

  void _guard(String method) {
    if (!_viaTxnView && identical(Zone.current[_txnZoneKey], this)) {
      throw StateError(
        '$method() called on the outer store inside inTransaction — the '
        'real store deadlocks here. Use the store handed to the action.',
      );
    }
  }

  /// Runs [call] as the transaction-bound view. The fake's methods do all
  /// their work synchronously before their first await, so the flag only
  /// needs to hold for the synchronous part of the call.
  Future<T> _asTxnView<T>(Future<T> Function() call) {
    _viaTxnView = true;
    try {
      return call();
    } finally {
      _viaTxnView = false;
    }
  }

  @override
  Future<T> inTransaction<T>(
    Future<T> Function(NutritionLocalStore txnStore) action,
  ) async {
    _guard('inTransaction');
    final payloadsBefore = Map.of(dayPayloads);
    final entriesBefore = Map.of(entries);
    final outboxBefore = List.of(outbox);
    final nextOpIdBefore = _nextOpId;
    final cursorBefore = cursor;
    final payloadWritesBefore = List.of(payloadWrites);
    try {
      return await runZoned(
        () => action(_InMemoryTxnView(this)),
        zoneValues: {_txnZoneKey: this},
      );
    } catch (_) {
      dayPayloads
        ..clear()
        ..addAll(payloadsBefore);
      entries
        ..clear()
        ..addAll(entriesBefore);
      outbox
        ..clear()
        ..addAll(outboxBefore);
      _nextOpId = nextOpIdBefore;
      cursor = cursorBefore;
      payloadWrites
        ..clear()
        ..addAll(payloadWritesBefore);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>?> readDayPayload(String dateKey) async {
    _guard('readDayPayload');
    return dayPayloads[dateKey];
  }

  @override
  Future<void> writeDayPayload(
    String dateKey,
    Map<String, dynamic> payload,
  ) async {
    _guard('writeDayPayload');
    dayPayloads[dateKey] = payload;
    payloadWrites.add(dateKey);
  }

  @override
  Future<bool> isDaySeeded(String dateKey) async {
    _guard('isDaySeeded');
    return dayPayloads.containsKey(dateKey);
  }

  @override
  Future<void> upsertEntry(StoredEntry entry) async {
    _guard('upsertEntry');
    if (failUpsertFor.contains(entry.uuid)) {
      throw StateError('injected upsert failure for ${entry.uuid}');
    }
    entries[entry.uuid] = entry;
  }

  @override
  Future<StoredEntry?> readEntry(String uuid) async {
    _guard('readEntry');
    return entries[uuid];
  }

  @override
  Future<List<StoredEntry>> readEntriesInRange(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    _guard('readEntriesInRange');
    final hits = entries.values
        .where(
          (entry) =>
              !entry.deleted &&
              !entry.consumedAt.isBefore(startUtc) &&
              entry.consumedAt.isBefore(endUtc),
        )
        .toList();
    hits.sort((a, b) => a.consumedAt.compareTo(b.consumedAt));
    return hits;
  }

  @override
  Future<void> purgeEntry(String uuid) async {
    _guard('purgeEntry');
    entries.remove(uuid);
  }

  @override
  Future<void> enqueueOp({
    required String kind,
    required String entryUuid,
    required Map<String, dynamic> payload,
    required DateTime queuedAt,
  }) async {
    _guard('enqueueOp');
    outbox.add(
      OutboxOp(
        id: _nextOpId++,
        kind: kind,
        entryUuid: entryUuid,
        payload: payload,
        queuedAt: queuedAt,
      ),
    );
  }

  @override
  Future<List<OutboxOp>> readOutbox() async {
    _guard('readOutbox');
    return List.of(outbox);
  }

  @override
  Future<void> removeOp(int id) async {
    _guard('removeOp');
    outbox.removeWhere((op) => op.id == id);
  }

  @override
  Future<bool> hasOpsFor(String entryUuid) async {
    _guard('hasOpsFor');
    return outbox.any((op) => op.entryUuid == entryUuid);
  }

  @override
  Future<int> countPendingEntries() async {
    _guard('countPendingEntries');
    return outbox.map((op) => op.entryUuid).toSet().length;
  }

  @override
  Future<void> removeOpsFor(String entryUuid) async {
    _guard('removeOpsFor');
    outbox.removeWhere((op) => op.entryUuid == entryUuid);
  }

  @override
  Future<String?> readSyncCursor() async {
    _guard('readSyncCursor');
    return cursor;
  }

  @override
  Future<void> writeSyncCursor(String value) async {
    _guard('writeSyncCursor');
    cursor = value;
  }

  @override
  Future<void> clear() async {
    _guard('clear');
    dayPayloads.clear();
    entries.clear();
    outbox.clear();
    cursor = null;
    cleared = true;
  }

  @override
  Future<void> close() async {}
}

/// The transaction-bound view handed to an [InMemoryNutritionStore]
/// transaction's action: forwards to the outer store's state, bypassing the
/// deadlock guard, and joins (rather than nests) further transactions —
/// mirroring the real store's bound view.
class _InMemoryTxnView implements NutritionLocalStore {
  _InMemoryTxnView(this._store);

  final InMemoryNutritionStore _store;

  @override
  Future<T> inTransaction<T>(
    Future<T> Function(NutritionLocalStore txnStore) action,
  ) => action(this);

  @override
  Future<Map<String, dynamic>?> readDayPayload(String dateKey) =>
      _store._asTxnView(() => _store.readDayPayload(dateKey));

  @override
  Future<void> writeDayPayload(String dateKey, Map<String, dynamic> payload) =>
      _store._asTxnView(() => _store.writeDayPayload(dateKey, payload));

  @override
  Future<bool> isDaySeeded(String dateKey) =>
      _store._asTxnView(() => _store.isDaySeeded(dateKey));

  @override
  Future<void> upsertEntry(StoredEntry entry) =>
      _store._asTxnView(() => _store.upsertEntry(entry));

  @override
  Future<StoredEntry?> readEntry(String uuid) =>
      _store._asTxnView(() => _store.readEntry(uuid));

  @override
  Future<List<StoredEntry>> readEntriesInRange(
    DateTime startUtc,
    DateTime endUtc,
  ) => _store._asTxnView(() => _store.readEntriesInRange(startUtc, endUtc));

  @override
  Future<void> purgeEntry(String uuid) =>
      _store._asTxnView(() => _store.purgeEntry(uuid));

  @override
  Future<void> enqueueOp({
    required String kind,
    required String entryUuid,
    required Map<String, dynamic> payload,
    required DateTime queuedAt,
  }) => _store._asTxnView(
    () => _store.enqueueOp(
      kind: kind,
      entryUuid: entryUuid,
      payload: payload,
      queuedAt: queuedAt,
    ),
  );

  @override
  Future<List<OutboxOp>> readOutbox() =>
      _store._asTxnView(() => _store.readOutbox());

  @override
  Future<void> removeOp(int id) => _store._asTxnView(() => _store.removeOp(id));

  @override
  Future<bool> hasOpsFor(String entryUuid) =>
      _store._asTxnView(() => _store.hasOpsFor(entryUuid));

  @override
  Future<int> countPendingEntries() =>
      _store._asTxnView(() => _store.countPendingEntries());

  @override
  Future<void> removeOpsFor(String entryUuid) =>
      _store._asTxnView(() => _store.removeOpsFor(entryUuid));

  @override
  Future<String?> readSyncCursor() =>
      _store._asTxnView(() => _store.readSyncCursor());

  @override
  Future<void> writeSyncCursor(String cursor) =>
      _store._asTxnView(() => _store.writeSyncCursor(cursor));

  @override
  Future<void> clear() => _store._asTxnView(() => _store.clear());

  @override
  Future<void> close() async {}
}

/// Minimal food for stored-entry fixtures.
FoodItem makeTestFood({
  int? backendId = 7,
  String name = 'Test Food',
  double kcal100g = 150,
  double proteinG100g = 10,
}) {
  return FoodItem(
    backendId: backendId,
    source: 'off',
    externalId: 'test-$name',
    name: name,
    brands: '',
    kcal100g: kcal100g,
    proteinG100g: proteinG100g,
    carbsG100g: 20,
    fatG100g: 5,
    rawSourceJson: '{}',
  );
}

/// A stored entry fixture defaulting to "synced, today at noon local".
StoredEntry makeStoredEntry({
  required String uuid,
  int? serverId = 1,
  String mealType = 'breakfast',
  DateTime? consumedAt,
  double quantityG = 100,
  double kcal = 150,
  FoodItem? food,
  DateTime? updatedAt,
  bool deleted = false,
  bool pending = false,
}) {
  final now = DateTime.now();
  return StoredEntry(
    uuid: uuid,
    serverId: serverId,
    mealType: mealType,
    consumedAt: (consumedAt ?? DateTime(now.year, now.month, now.day, 12))
        .toUtc(),
    quantityG: quantityG,
    kcal: kcal,
    food: food ?? makeTestFood(),
    updatedAt: (updatedAt ?? now).toUtc(),
    deleted: deleted,
    pending: pending,
  );
}
