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

/// Persists a custom-food draft: best-effort backend upsert (offline keeps
/// the local copy; a later meal submit re-syncs anything missing a
/// backendId), then the local store. Returns the stored item, or null when
/// the session was unauthorized — [onUnauthorized] has already run then.
Future<FoodItem?> saveCustomFoodDraft(
  FoodItem draft, {
  required FoodsApiService foodsApi,
  required FoodLocalDb localDb,
  required Future<void> Function() onUnauthorized,
}) async {
  var item = draft;
  try {
    final synced = await foodsApi.upsertCustomFood(item);
    item = item.copyWith(backendId: synced.backendId);
  } on ApiException catch (error) {
    if (error.isUnauthorized) {
      await onUnauthorized();
      return null;
    }
    // Offline or server hiccup: keep the local copy, sync on submit.
  }
  return localDb.upsertFood(item);
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
