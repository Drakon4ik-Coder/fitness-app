import 'package:fitness_app/features/nutrition/data/food_local_db.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _MemoryFoodDatabase implements Database {
  _MemoryFoodDatabase(Map<String, Object?> row)
    : row = Map<String, Object?>.from(row);

  final Map<String, Object?> row;
  final List<String> executedSql = [];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    executedSql.add(sql);
    if (sql.contains('ADD COLUMN last_logged_grams')) {
      row['last_logged_grams'] = null;
    } else if (sql.contains('ADD COLUMN same_amount_streak')) {
      row['same_amount_streak'] = 0;
    }
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    expect(sql, contains('same_amount_streak = CASE'));
    final values = arguments!;
    final loggedGrams = values[1]! as double;
    final isSameAmount = row['last_logged_grams'] == loggedGrams;
    row['last_used_at'] = values[0];
    row['same_amount_streak'] = isSameAmount
        ? (row['same_amount_streak']! as int) + 1
        : 1;
    row['last_logged_grams'] = values[2];
    return row['id'] == values[3] ? 1 : 0;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => [Map<String, Object?>.from(row)];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FoodItem _fatsecretFood({
  double? gramsPerPiece,
  String? pieceUnit,
  double? servingSizeG,
  String rawSourceJson = '{"food": {}}',
}) {
  return FoodItem(
    source: fatsecretSource,
    externalId: '12345',
    name: 'Hamburger',
    brands: '',
    kcal100g: 254,
    proteinG100g: 13,
    carbsG100g: 24,
    fatG100g: 12,
    servingSizeG: servingSizeG,
    gramsPerPiece: gramsPerPiece,
    pieceUnit: pieceUnit,
    rawSourceJson: rawSourceJson,
  );
}

void main() {
  final db = FoodLocalDb();

  test(
    'v7 to v8 migration keeps rows and initializes an inactive streak',
    () async {
      final existing =
          _fatsecretFood(servingSizeG: 100)
              .copyWith(localId: 7, lastUsedAt: DateTime.utc(2026, 7, 1))
              .toDbMap(includeId: true)
            ..remove('last_logged_grams')
            ..remove('same_amount_streak');
      final database = _MemoryFoodDatabase(existing);
      final localDb = FoodLocalDb(database: database);

      await localDb.upgradeSchemaForTesting(database, 7);

      expect(database.executedSql, [
        'ALTER TABLE foods ADD COLUMN last_logged_grams REAL',
        'ALTER TABLE foods ADD COLUMN same_amount_streak '
            'INTEGER NOT NULL DEFAULT 0',
      ]);
      final restored = (await localDb.fetchRecentFoods()).single;
      expect(restored.localId, 7);
      expect(restored.name, 'Hamburger');
      expect(restored.lastLoggedGrams, isNull);
      expect(restored.sameAmountStreak, 0);
    },
  );

  test(
    'same logged grams increment the streak and different grams reset it',
    () async {
      final stored = _fatsecretFood(
        servingSizeG: 100,
      ).copyWith(localId: 7).toDbMap(includeId: true);
      final database = _MemoryFoodDatabase(stored);
      final localDb = FoodLocalDb(database: database);
      final usedAt = DateTime.utc(2026, 7, 2, 12);

      await localDb.updateLastUsed(7, usedAt, 125);
      var restored = (await localDb.fetchRecentFoods()).single;
      expect(restored.lastLoggedGrams, 125);
      expect(restored.sameAmountStreak, 1);
      expect(restored.lastUsedAt, usedAt);

      await localDb.updateLastUsed(7, usedAt.add(const Duration(days: 1)), 125);
      restored = (await localDb.fetchRecentFoods()).single;
      expect(restored.lastLoggedGrams, 125);
      expect(restored.sameAmountStreak, 2);

      await localDb.updateLastUsed(7, usedAt.add(const Duration(days: 2)), 80);
      restored = (await localDb.fetchRecentFoods()).single;
      expect(restored.lastLoggedGrams, 80);
      expect(restored.sameAmountStreak, 1);
    },
  );

  test('merge keeps incoming piece fields over a piece-less local row', () {
    // Regression: a row logged before piece support (or from a search stub)
    // has null piece columns; the enriched detail fetch must win or the
    // burger/cookie quantity default vanishes on every local reload.
    final existing = _fatsecretFood(
      servingSizeG: 100,
    ).copyWith(lastLoggedGrams: 125, sameAmountStreak: 2);
    final incoming = _fatsecretFood(
      gramsPerPiece: 110,
      pieceUnit: 'burger',
      servingSizeG: 110,
      rawSourceJson: '{"food": {}, "serving_size": "1 burger (110 g)"}',
    );

    final merged = db.mergeFood(existing, incoming);

    expect(merged.gramsPerPiece, 110);
    expect(merged.pieceUnit, 'burger');
    expect(merged.servingSizeG, 110);
    expect(merged.lastLoggedGrams, 125);
    expect(merged.sameAmountStreak, 2);
  });

  test('merge keeps existing piece fields when the incoming item has none', () {
    // Same "incoming null means not fetched" contract as the other nutrition
    // fields: a piece-less search stub must not erase enriched piece data.
    final existing = _fatsecretFood(
      gramsPerPiece: 110,
      pieceUnit: 'burger',
      servingSizeG: 110,
    );
    final incoming = _fatsecretFood(servingSizeG: 100);

    final merged = db.mergeFood(existing, incoming);

    expect(merged.gramsPerPiece, 110);
    expect(merged.pieceUnit, 'burger');
  });
}
