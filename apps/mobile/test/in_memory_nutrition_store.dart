import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_local_store.dart';

/// In-memory stand-in for [NutritionLocalStore] so tests don't touch
/// sqflite / path_provider platform channels. Mirrors the store's contract
/// closely enough for repository and widget tests: entry rows keyed by uuid,
/// FIFO outbox, day payloads keyed by date string.
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

  @override
  Future<Map<String, dynamic>?> readDayPayload(String dateKey) async =>
      dayPayloads[dateKey];

  @override
  Future<void> writeDayPayload(
    String dateKey,
    Map<String, dynamic> payload,
  ) async {
    dayPayloads[dateKey] = payload;
    payloadWrites.add(dateKey);
  }

  @override
  Future<bool> isDaySeeded(String dateKey) async =>
      dayPayloads.containsKey(dateKey);

  @override
  Future<void> upsertEntry(StoredEntry entry) async {
    entries[entry.uuid] = entry;
  }

  @override
  Future<StoredEntry?> readEntry(String uuid) async => entries[uuid];

  @override
  Future<List<StoredEntry>> readEntriesInRange(
    DateTime startUtc,
    DateTime endUtc,
  ) async {
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
    entries.remove(uuid);
  }

  @override
  Future<void> enqueueOp({
    required String kind,
    required String entryUuid,
    required Map<String, dynamic> payload,
    required DateTime queuedAt,
  }) async {
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
  Future<List<OutboxOp>> readOutbox() async => List.of(outbox);

  @override
  Future<void> removeOp(int id) async {
    outbox.removeWhere((op) => op.id == id);
  }

  @override
  Future<bool> hasOpsFor(String entryUuid) async =>
      outbox.any((op) => op.entryUuid == entryUuid);

  @override
  Future<int> countPendingEntries() async =>
      outbox.map((op) => op.entryUuid).toSet().length;

  @override
  Future<void> removeOpsFor(String entryUuid) async {
    outbox.removeWhere((op) => op.entryUuid == entryUuid);
  }

  @override
  Future<String?> readSyncCursor() async => cursor;

  @override
  Future<void> writeSyncCursor(String value) async {
    cursor = value;
  }

  @override
  Future<void> clear() async {
    dayPayloads.clear();
    entries.clear();
    outbox.clear();
    cursor = null;
    cleared = true;
  }

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
