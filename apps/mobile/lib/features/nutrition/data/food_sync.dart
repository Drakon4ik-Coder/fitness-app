import 'dart:async' show unawaited;

import 'api_exceptions.dart';
import 'food_local_db.dart';
import 'food_models.dart';
import 'foods_api_service.dart';

/// Resolves a backend id for a catalog (non-custom) food through the
/// check/ingest flow. Returns the resolved item and whether the backend
/// already holds good images for it.
Future<(FoodItem, bool)> ensureGlobalBackendId(
  FoodItem item, {
  required FoodsApiService foodsApi,
}) async {
  if (item.backendId != null) return (item, false);
  if (item.contentHash.isNotEmpty) {
    final check = await foodsApi.checkFood(
      source: item.source,
      externalId: item.externalId,
      contentHash: item.contentHash,
      imageSignature: item.imageSignature,
    );
    if (check.upToDate && check.foodItemId != null) {
      return (item.copyWith(backendId: check.foodItemId), check.imagesOk);
    }
  }
  final result = await foodsApi.ingestFood(item);
  return (result.item, result.imagesOk);
}

/// Persists a custom-food draft locally, then starts a best-effort backend
/// upsert. A later meal submit re-syncs anything still missing a backend id.
Future<FoodItem?> saveCustomFoodDraft(
  FoodItem draft, {
  required FoodsApiService foodsApi,
  required FoodLocalDb localDb,
  required Future<void> Function() onUnauthorized,
  void Function(FoodItem synced)? onSynced,
}) async {
  final stored = await localDb.upsertFood(draft);
  unawaited(
    _syncCustomFoodDraft(
      stored,
      foodsApi: foodsApi,
      localDb: localDb,
      onUnauthorized: onUnauthorized,
      onSynced: onSynced,
    ),
  );
  return stored;
}

Future<void> _syncCustomFoodDraft(
  FoodItem item, {
  required FoodsApiService foodsApi,
  required FoodLocalDb localDb,
  required Future<void> Function() onUnauthorized,
  required void Function(FoodItem synced)? onSynced,
}) async {
  try {
    final synced = await foodsApi.upsertCustomFood(item);
    final backendId = synced.backendId;
    final localId = item.localId;
    if (backendId == null || localId == null) return;

    final stillExists = await localDb.updateBackendId(localId, backendId);
    if (!stillExists) {
      // Create -> delete while this upsert was in flight must delete the row
      // the server just created, or it resurrects in typeahead on next sync.
      await foodsApi.deleteCustomFood(backendId);
      return;
    }
    onSynced?.call(item.copyWith(backendId: backendId));
  } on ApiException catch (error) {
    if (error.isUnauthorized) {
      try {
        await onUnauthorized();
      } catch (_) {
        // Background work must never surface an unhandled async error.
      }
    }
    // Offline or server hiccup: keep the local copy, sync on submit.
  } catch (_) {
    // The local draft is already safe; background failures are non-blocking.
  }
}

enum CustomFoodDeleteOutcome { deleted, unauthorized, failed }

/// Deletes a custom food: backend soft-delete first (aborting on failure so
/// the two stores never diverge — a locally-deleted food would otherwise
/// resurface from typeahead), then the local row.
Future<CustomFoodDeleteOutcome> deleteCustomFoodEverywhere(
  FoodItem item, {
  required FoodsApiService foodsApi,
  required FoodLocalDb localDb,
  required Future<void> Function() onUnauthorized,
}) async {
  if (item.backendId != null) {
    try {
      await foodsApi.deleteCustomFood(item.backendId!);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await onUnauthorized();
        return CustomFoodDeleteOutcome.unauthorized;
      }
      return CustomFoodDeleteOutcome.failed;
    }
  }
  if (item.localId != null) {
    await localDb.deleteFood(item.localId!);
  }
  return CustomFoodDeleteOutcome.deleted;
}
