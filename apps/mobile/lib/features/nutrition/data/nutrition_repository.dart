import 'dart:math';

import 'api_exceptions.dart';
import 'food_models.dart';
import 'nutrition_api_service.dart';
import 'nutrition_local_store.dart';

/// RFC-4122 v4 uuid without pulling in a package — the entry identity minted
/// at creation time (possibly offline) and kept for the entry's whole life.
String generateClientUuid({Random? random}) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = [
    for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Sync-aware access to the nutrition log (KAN-28 Phases 2–3).
///
/// Sits between the pages and the raw API/local store and owns the offline
/// story:
///
///  * Reads: a day renders instantly from the local entry table (or the
///    Phase-1 payload cache as fallback), then [refreshDay] converges with the
///    server — a cheap delta pull for days already seeded by a full fetch.
///  * Writes: create/edit/delete apply to the local table immediately and are
///    queued in the outbox; replay happens opportunistically on every refresh
///    and write attempt, is idempotent (client uuids), and resolves conflicts
///    last-write-wins on the mutation time.
///
/// Day grouping stays timezone-faithful because entries are grouped by the
/// device's local calendar day — the same zone the app reports to the server
/// for its server-side grouping. Rich per-day nutrient maps are only
/// server-computed; locally composed days leave [NutritionDayLog.nutrients]
/// null and the UI falls back to aggregating entries, which carry full
/// nutriment data.
class NutritionRepository {
  NutritionRepository({
    required NutritionApiService api,
    required NutritionLocalStore store,
    DateTime Function()? now,
  }) : _api = api,
       _store = store,
       _now = now ?? (() => DateTime.now().toUtc());

  final NutritionApiService _api;
  final NutritionLocalStore _store;
  final DateTime Function() _now;

  // --- reads ---

  /// The locally known state of [date]'s log, or null when this device has
  /// nothing for it yet. Never touches the network.
  Future<NutritionDayLog?> readCachedDay(DateTime date) async {
    final dateKey = NutritionApiService.formatDate(date);
    final entries = await _entriesForDay(date);
    if (entries.isNotEmpty || await _store.isDaySeeded(dateKey)) {
      return _composeDayLog(date, entries);
    }
    return null;
  }

  /// Converges with the server and returns the fresh state of [date]:
  /// replays the outbox, pulls deltas (or a full day fetch the first time a
  /// day is opened), and recomposes locally. Throws [ApiException] when the
  /// server can't be reached — callers keep showing [readCachedDay]'s result.
  Future<NutritionDayLog> refreshDay(DateTime date) async {
    final dateKey = NutritionApiService.formatDate(date);
    await pushOutbox();

    // The cursor must exist before the first full-day fetch: anything changing
    // between bootstrap and fetch gets re-delivered by the next delta pull,
    // and merging is idempotent — so nothing can slip through the gap.
    var cursor = await _store.readSyncCursor();
    if (cursor == null || cursor.isEmpty) {
      cursor = (await _api.fetchSyncPage()).nextCursor;
      if (cursor.isNotEmpty) {
        await _store.writeSyncCursor(cursor);
      }
    }

    if (!await _store.isDaySeeded(dateKey)) {
      final raw = await _api.fetchDayRaw(date);
      for (final entry in _entriesFromDayPayload(raw)) {
        await _mergeServerEntry(entry, deleted: false);
      }
      // Written after the entries so a crash in between re-fetches next time
      // instead of composing a half-seeded day.
      await _store.writeDayPayload(dateKey, raw);
      if (cursor.isNotEmpty) {
        await _pullDeltas(cursor);
      }
      // First fetch of a day: hand back the server's own view — totals, day
      // grouping and the rich nutrients map all server-computed.
      return _api.parseDayLog(raw);
    }

    // Already-seeded day: a delta pull replaces the full re-fetch. Totals are
    // simple local sums over the merged entries; the UI derives the nutrient
    // breakdown from the entries' own nutriment data.
    if (cursor.isNotEmpty) {
      await _pullDeltas(cursor);
    }
    return _composeDayLog(date, await _entriesForDay(date));
  }

  // --- writes (optimistic, offline-tolerant) ---

  /// Logs [food] locally right away and queues the server create. The entry
  /// appears in the day immediately even with no connectivity; replay dedupes
  /// on the client uuid. Requires [food] to be resolved to a backend id (foods
  /// never seen by the server can't be referenced by a queued create).
  Future<NutritionEntry> createEntry({
    required FoodItem food,
    required String mealType,
    required double quantityG,
    required DateTime consumedAt,
  }) async {
    final backendId = food.backendId;
    if (backendId == null) {
      throw ApiException('Unable to resolve food item id.');
    }
    final uuid = generateClientUuid();
    final nowUtc = _now();
    final stored = StoredEntry(
      uuid: uuid,
      mealType: mealType,
      consumedAt: consumedAt.toUtc(),
      quantityG: quantityG,
      kcal: _kcalFor(food, quantityG),
      food: food,
      updatedAt: nowUtc,
      pending: true,
    );
    await _store.upsertEntry(stored);
    await _store.enqueueOp(
      kind: OutboxOp.create,
      entryUuid: uuid,
      payload: {
        'food_item_id': backendId,
        'meal_type': mealType,
        'quantity_g': quantityG,
        'consumed_at': consumedAt.toUtc().toIso8601String(),
        // The create's LWW mutation time (KAN-28). Without it the server
        // stamps the replay's arrival time, which out-ranks — and silently
        // kills — any edit queued behind this create while offline.
        'client_updated_at': nowUtc.toIso8601String(),
      },
      queuedAt: nowUtc,
    );
    await _tryPushOutbox();
    return _toNutritionEntry(await _store.readEntry(uuid) ?? stored);
  }

  /// Applies the edit locally and queues the server patch. Returns the entry
  /// as this device now sees it; a concurrent newer edit elsewhere wins later
  /// via LWW and arrives with the next delta pull.
  Future<NutritionEntry?> updateEntry(
    NutritionEntry entry, {
    double? quantityG,
    String? mealType,
  }) async {
    final uuid = entry.uuid;
    if (uuid == null) {
      // Entry from a pre-sync payload: plain online-only edit, old behavior.
      return _api.updateEntry(
        entryId: entry.id,
        quantityG: quantityG,
        mealType: mealType,
      );
    }
    final nowUtc = _now();
    final current = await _store.readEntry(uuid) ?? _toStoredEntry(entry);
    final updated = current.copyWith(
      quantityG: quantityG,
      mealType: mealType,
      kcal: quantityG == null ? null : _kcalFor(current.food, quantityG),
      updatedAt: nowUtc,
      pending: true,
    );
    await _store.upsertEntry(updated);
    await _store.enqueueOp(
      kind: OutboxOp.update,
      entryUuid: uuid,
      payload: {
        if (quantityG != null) 'quantity_g': quantityG,
        if (mealType != null) 'meal_type': mealType,
      },
      queuedAt: nowUtc,
    );
    await _tryPushOutbox();
    final after = await _store.readEntry(uuid);
    return after == null ? null : _toNutritionEntry(after);
  }

  /// Tombstones the entry locally and queues the server delete. An entry that
  /// never reached the server is simply forgotten (its queued ops cancelled).
  Future<bool> deleteEntry(NutritionEntry entry) async {
    final uuid = entry.uuid;
    if (uuid == null) {
      await _api.deleteEntry(entryId: entry.id);
      return true;
    }
    final nowUtc = _now();
    final current = await _store.readEntry(uuid) ?? _toStoredEntry(entry);
    final neverSynced =
        current.serverId == null && await _store.hasOpsFor(uuid);
    if (neverSynced) {
      // The create is still queued — cancel the whole life of the entry.
      await _store.removeOpsFor(uuid);
      await _store.purgeEntry(uuid);
      return true;
    }
    await _store.upsertEntry(
      current.copyWith(deleted: true, updatedAt: nowUtc, pending: true),
    );
    await _store.enqueueOp(
      kind: OutboxOp.delete,
      entryUuid: uuid,
      payload: const {},
      queuedAt: nowUtc,
    );
    await _tryPushOutbox();
    return true;
  }

  /// Undoes a delete (KAN-39): brings [entry] back under its original uuid so
  /// its identity survives the delete/undo round-trip. Locally the row is
  /// un-tombstoned right away; the queued re-create carries a fresh mutation
  /// time, so it beats the tombstone LWW-wise server-side — even when the
  /// delete op is still ahead of it in the outbox, replay order converges.
  Future<NutritionEntry?> restoreEntry(NutritionEntry entry) async {
    final backendId = entry.foodItem.backendId;
    if (backendId == null) {
      throw ApiException('Unable to resolve food item id.');
    }
    final uuid = entry.uuid;
    if (uuid == null) {
      // Entry from a pre-sync payload: plain online-only re-create.
      return _api.createEntry(
        foodItemId: backendId,
        mealType: entry.mealType,
        quantityG: entry.quantityG,
        consumedAt: entry.consumedAt,
      );
    }
    final nowUtc = _now();
    await _store.upsertEntry(
      _toStoredEntry(entry).copyWith(updatedAt: nowUtc, pending: true),
    );
    await _store.enqueueOp(
      kind: OutboxOp.create,
      entryUuid: uuid,
      payload: {
        'food_item_id': backendId,
        'meal_type': entry.mealType,
        'quantity_g': entry.quantityG,
        'consumed_at': entry.consumedAt.toUtc().toIso8601String(),
        'client_updated_at': nowUtc.toIso8601String(),
      },
      queuedAt: nowUtc,
    );
    await _tryPushOutbox();
    final after = await _store.readEntry(uuid);
    return after == null ? null : _toNutritionEntry(after);
  }

  /// How many entries have queued offline writes awaiting replay. Read-only
  /// surfacing of the outbox for the UI (KAN-56) — it never changes sync
  /// behavior. Zero means everything this device wrote reached the server.
  Future<int> pendingSyncCount() => _store.countPendingEntries();

  /// Wipes all local state (day payloads, entries, queued writes, cursor).
  /// For account deletion only — logout keeps the store, which is namespaced
  /// per user id (KAN-64).
  Future<void> clear() => _store.clear();

  Future<void> close() => _store.close();

  // --- outbox replay ---

  /// Replays queued offline writes in order. Stops (keeping the remaining
  /// queue) on connectivity failures; drops ops the server has definitively
  /// rejected (4xx) — the next delta pull restores the server's truth locally.
  /// Throws nothing except unauthorized, which callers turn into a logout.
  Future<void> pushOutbox() async {
    for (final op in await _store.readOutbox()) {
      try {
        await _replayOp(op);
      } on ApiException catch (error) {
        if (error.isNetworkError) {
          return; // Still offline — leave the queue for the next attempt.
        }
        if (error.isUnauthorized) {
          rethrow;
        }
        // Server verdict: replaying again can't succeed. Drop the op and let
        // delta sync converge this entry back to the server state.
        await _store.removeOp(op.id);
        await _markPendingFromOutbox(op.entryUuid);
      }
    }
  }

  Future<void> _tryPushOutbox() async {
    try {
      await pushOutbox();
    } on ApiException {
      // Unauthorized bubbles out of explicit refreshes; an optimistic write
      // shouldn't force a logout mid-gesture.
    }
  }

  Future<void> _replayOp(OutboxOp op) async {
    switch (op.kind) {
      case OutboxOp.create:
        final created = await _api.createEntry(
          foodItemId: op.payload['food_item_id'] as int,
          mealType: op.payload['meal_type'] as String? ?? '',
          quantityG: (op.payload['quantity_g'] as num?)?.toDouble() ?? 0,
          consumedAt: DateTime.tryParse(
            op.payload['consumed_at'] as String? ?? '',
          ),
          clientUuid: op.entryUuid,
          // The create's LWW mutation time; on an undo re-create (KAN-39) it
          // also lets the server resurrect a tombstoned row instead of
          // bouncing off the dedupe. Absent only on ops queued by older app
          // versions — the server falls back to its own clock then.
          clientUpdatedAt: DateTime.tryParse(
            op.payload['client_updated_at'] as String? ?? '',
          ),
        );
        await _store.removeOp(op.id);
        final local = await _store.readEntry(op.entryUuid);
        if (local != null) {
          await _store.upsertEntry(
            local.copyWith(
              serverId: created.id,
              pending: await _store.hasOpsFor(op.entryUuid),
            ),
          );
        }
      case OutboxOp.update:
        final winner = await _api.updateEntry(
          entryUuid: op.entryUuid,
          quantityG: (op.payload['quantity_g'] as num?)?.toDouble(),
          mealType: op.payload['meal_type'] as String?,
          clientUpdatedAt: op.queuedAt,
        );
        await _store.removeOp(op.id);
        // The response is the winning state (ours, or a newer one from
        // another device) — adopt it unless yet-newer local ops are queued.
        if (!await _store.hasOpsFor(op.entryUuid)) {
          final local = await _store.readEntry(op.entryUuid);
          if (local != null && !local.deleted) {
            await _store.upsertEntry(
              _storedFromServer(winner, deleted: false, pending: false),
            );
          }
        }
      case OutboxOp.delete:
        await _api.deleteEntry(
          entryUuid: op.entryUuid,
          clientUpdatedAt: op.queuedAt,
        );
        await _store.removeOp(op.id);
        // Acknowledged: the server carries the tombstone for other devices
        // now (or dropped the delete LWW-wise, in which case the next delta
        // pull resurrects the row here). But an undo re-create queued behind
        // this delete (KAN-39) has already brought the local row back to
        // life — purging would drop the restore, so leave the row to the
        // queued create when one exists.
        if (!await _store.hasOpsFor(op.entryUuid)) {
          await _store.purgeEntry(op.entryUuid);
        }
    }
  }

  /// Recomputes the pending flag after the outbox changed shape for [uuid].
  Future<void> _markPendingFromOutbox(String uuid) async {
    final local = await _store.readEntry(uuid);
    if (local == null) {
      return;
    }
    final stillPending = await _store.hasOpsFor(uuid);
    if (local.pending != stillPending) {
      await _store.upsertEntry(local.copyWith(pending: stillPending));
    }
  }

  // --- delta sync ---

  Future<void> _pullDeltas(String cursor) async {
    var since = cursor;
    var hasMore = true;
    while (hasMore) {
      final page = await _api.fetchSyncPage(since: since);
      for (final syncEntry in page.entries) {
        await _mergeServerEntry(syncEntry.entry, deleted: syncEntry.deleted);
      }
      hasMore = page.hasMore;
      if (page.nextCursor.isEmpty || page.nextCursor == since) {
        break; // Defensive: never spin on a cursor that isn't advancing.
      }
      since = page.nextCursor;
      await _store.writeSyncCursor(since);
    }
  }

  /// LWW merge of one server-side entry state into the local table. Local
  /// rows with unsynced changes win over older server states; the queued op
  /// will fight it out server-side and the loser converges on a later pull.
  Future<void> _mergeServerEntry(
    NutritionEntry entry, {
    required bool deleted,
  }) async {
    final uuid = entry.uuid;
    if (uuid == null) {
      return; // Pre-sync server rows always carry a uuid; defensive.
    }
    final local = await _store.readEntry(uuid);
    if (local != null && local.pending) {
      final serverTime = entry.updatedAt;
      if (serverTime == null || !serverTime.isAfter(local.updatedAt)) {
        return;
      }
      // Newer change elsewhere beats the local pending one. Adopt it; the
      // queued op is left to replay and lose LWW server-side (harmless).
    }
    if (deleted) {
      await _store.purgeEntry(uuid);
      if (local != null && local.pending) {
        // Deleted elsewhere with a newer timestamp: cancel our stale ops.
        await _store.removeOpsFor(uuid);
      }
      return;
    }
    await _store.upsertEntry(
      _storedFromServer(entry, deleted: false, pending: false),
    );
  }

  // --- composition helpers ---

  Future<List<StoredEntry>> _entriesForDay(DateTime date) {
    // Group by the device's local calendar day, mirroring the server's
    // grouping in the user's profile timezone (the app keeps those aligned).
    final startLocal = DateTime(date.year, date.month, date.day);
    final endLocal = DateTime(date.year, date.month, date.day + 1);
    return _store.readEntriesInRange(startLocal.toUtc(), endLocal.toUtc());
  }

  NutritionDayLog _composeDayLog(DateTime date, List<StoredEntry> entries) {
    final meals = <String, List<NutritionEntry>>{
      for (final meal in MealType.values) meal.wireName: <NutritionEntry>[],
    };
    var kcal = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0;
    for (final stored in entries) {
      final entry = _toNutritionEntry(stored);
      (meals[entry.mealType] ??= []).add(entry);
      final factor = stored.quantityG / 100.0;
      kcal += stored.kcal;
      protein += (stored.food.proteinG100g ?? 0) * factor;
      carbs += (stored.food.carbsG100g ?? 0) * factor;
      fat += (stored.food.fatG100g ?? 0) * factor;
    }
    return NutritionDayLog(
      date: DateTime(date.year, date.month, date.day),
      totals: NutritionTotals(
        kcal: kcal,
        proteinG: protein,
        carbsG: carbs,
        fatG: fat,
      ),
      meals: meals,
      // Locally composed: the UI aggregates the entries' full nutriment data
      // instead of a server map (same fallback as pre-nutrients payloads).
      nutrients: null,
    );
  }

  List<NutritionEntry> _entriesFromDayPayload(Map<String, dynamic> raw) {
    return [for (final meal in _api.parseDayLog(raw).meals.values) ...meal];
  }

  double _kcalFor(FoodItem food, double quantityG) =>
      (food.kcal100g ?? 0) * quantityG / 100.0;

  NutritionEntry _toNutritionEntry(StoredEntry stored) {
    return NutritionEntry(
      id: stored.serverId ?? 0,
      uuid: stored.uuid,
      mealType: stored.mealType,
      consumedAt: stored.consumedAt,
      quantityG: stored.quantityG,
      kcal: stored.kcal,
      foodItem: stored.food,
      updatedAt: stored.updatedAt,
    );
  }

  StoredEntry _toStoredEntry(NutritionEntry entry) {
    return StoredEntry(
      uuid: entry.uuid!,
      serverId: entry.id == 0 ? null : entry.id,
      mealType: entry.mealType,
      consumedAt: entry.consumedAt.toUtc(),
      quantityG: entry.quantityG,
      kcal: entry.kcal,
      food: entry.foodItem,
      updatedAt: (entry.updatedAt ?? _now()).toUtc(),
    );
  }

  StoredEntry _storedFromServer(
    NutritionEntry entry, {
    required bool deleted,
    required bool pending,
  }) {
    return StoredEntry(
      uuid: entry.uuid!,
      serverId: entry.id == 0 ? null : entry.id,
      mealType: entry.mealType,
      consumedAt: entry.consumedAt.toUtc(),
      quantityG: entry.quantityG,
      kcal: entry.kcal,
      food: entry.foodItem,
      updatedAt: (entry.updatedAt ?? _now()).toUtc(),
      deleted: deleted,
      pending: pending,
    );
  }
}
