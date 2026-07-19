import 'dart:convert';

import 'package:fitness_app/features/nutrition/data/fatsecret_mapper.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/nutrient_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact `foods.search` "Big Mac" hit from the FatSecret proxy contract
/// (KAN-67 spec): a single serving object (not a list), all numbers as
/// strings, and a "Per 1 burger" description basis (not per-100g).
Map<String, dynamic> _bigMacSearchHit({String description = ''}) => {
  'food_id': '33691',
  'food_name': 'Big Mac',
  'food_type': 'Brand',
  'brand_name': "McDonald's UK",
  'food_description': description,
  'food_url': 'https://example.invalid/big-mac',
};

/// The matching `food.get.v4` detail: `servings.serving` is a single object
/// (the object-vs-array quirk), the burger's whole-portion nutrition, in mg/µg
/// for the micronutrients.
Map<String, dynamic> _bigMacDetail() => {
  'food_id': '33691',
  'food_name': 'Big Mac',
  'food_type': 'Brand',
  'brand_name': "McDonald's UK",
  'servings': {
    'serving': {
      'serving_id': '12345',
      'serving_description': '1 burger',
      'metric_serving_amount': '219.000',
      'metric_serving_unit': 'g',
      'number_of_units': '1.000',
      'measurement_description': 'burger',
      'calories': '550',
      'carbohydrate': '44.00',
      'protein': '25.00',
      'fat': '29.00',
      'saturated_fat': '10.00',
      'sugar': '9.00',
      'fiber': '3.00',
      'sodium': '1010',
      'potassium': '400',
      'cholesterol': '80',
      'calcium': '120',
      'iron': '4.20',
      'vitamin_a': '80',
      'vitamin_c': '1.0',
      'vitamin_d': '0.5',
    },
  },
};

NutrientSpec _specFor(String key) =>
    kNutrientCatalog.firstWhere((spec) => spec.key == key);

void main() {
  final mapper = FatSecretMapper();

  group('mapSummary', () {
    test('parses macros from a per-100g food_description basis', () {
      final item = mapper.mapSummary(
        _bigMacSearchHit(
          description:
              'Per 100g - Calories: 234kcal | Fat: 11.00g | Carbs: 20.00g | '
              'Protein: 12.00g',
        ),
      );

      expect(item, isNotNull);
      expect(item!.source, fatsecretSource);
      expect(item.externalId, '33691');
      expect(item.name, 'Big Mac');
      expect(item.brands, "McDonald's UK");
      expect(item.kcal100g, 234);
      expect(item.fatG100g, 11);
      expect(item.carbsG100g, 20);
      expect(item.proteinG100g, 12);
      expect(item.nutrimentsJson, isNotNull);
      expect(item.nutrimentsJson!['energy-kcal_100g'], 234);
    });

    test('a "Per 1 burger" (non-100g) basis leaves macros null', () {
      final item = mapper.mapSummary(
        _bigMacSearchHit(
          description:
              'Per 1 burger - Calories: 550kcal | Fat: 29.00g | Carbs: '
              '44.00g | Protein: 25.00g',
        ),
      );

      expect(item, isNotNull);
      expect(item!.kcal100g, isNull);
      expect(item.fatG100g, isNull);
      expect(item.carbsG100g, isNull);
      expect(item.proteinG100g, isNull);
      expect(item.nutrimentsJson, isNull);
    });

    test('a per-100g basis with no parseable values yields null '
        'nutrimentsJson, not an empty map (no-nutrition guard depends on '
        'null)', () {
      final item = mapper.mapSummary(
        _bigMacSearchHit(description: 'Per 100g -'),
      );

      expect(item, isNotNull);
      expect(item!.kcal100g, isNull);
      expect(item.nutrimentsJson, isNull);
    });

    test('null food_id yields no item', () {
      final food = _bigMacSearchHit()..remove('food_id');
      expect(mapper.mapSummary(food), isNull);
    });

    test('maps the preferred v3 search image and hashes its URL signature', () {
      final withoutImage = mapper.mapSummary(_bigMacSearchHit())!;
      final food = _bigMacSearchHit()
        ..['food_images'] = {
          'food_image': [
            {
              'image_url': 'https://images.example/thumb.png',
              'image_type': 'Thumbnail',
            },
            {
              'image_url': 'https://images.example/standard.png',
              'image_type': 'Standard',
            },
          ],
        };

      final item = mapper.mapSummary(food)!;
      final changedFood = _bigMacSearchHit()
        ..['food_images'] = {
          'food_image': {
            'image_url': 'https://images.example/changed.png',
            'image_type': 'Standard',
          },
        };
      final changedItem = mapper.mapSummary(changedFood)!;

      expect(item.imageUrl, 'https://images.example/standard.png');
      expect(item.imageSignature, hasLength(64));
      expect(item.contentHash, isNot(withoutImage.contentHash));
      expect(changedItem.imageSignature, isNot(item.imageSignature));
      expect(changedItem.contentHash, isNot(item.contentHash));
    });

    test('no search image preserves the pre-image hash exactly', () {
      final item = mapper.mapSummary(_bigMacSearchHit())!;

      expect(item.imageUrl, isNull);
      expect(item.imageSignature, isNull);
      expect(
        item.contentHash,
        'b94651b11a8cdaa5e089f7e4df4b211cb802646166ea7120e0d0aba5c6d9f021',
      );
    });
  });

  group('mapDetail', () {
    test('normalizes a single-serving-object payload to per-100g values', () {
      final item = mapper.mapDetail(_bigMacDetail());

      expect(item, isNotNull);
      // 550 kcal / 219 g * 100 = ~251.14 kcal/100g.
      expect(item!.kcal100g, closeTo(251.14, 0.01));
      expect(item.proteinG100g, closeTo(25.00 * 100 / 219, 0.001));
      expect(item.carbsG100g, closeTo(44.00 * 100 / 219, 0.001));
      expect(item.fatG100g, closeTo(29.00 * 100 / 219, 0.001));
      expect(item.source, fatsecretSource);
      expect(item.externalId, '33691');
    });

    test('piece derivation: gramsPerPiece, pieceUnit and servingSizeG come '
        'from the burger serving', () {
      final item = mapper.mapDetail(_bigMacDetail());

      expect(item, isNotNull);
      expect(item!.gramsPerPiece, closeTo(219, 0.001));
      expect(item.pieceUnit, 'burger');
      expect(item.servingSizeG, closeTo(219, 0.001));
    });

    test('salt_100g = sodium_100g * 2.5 (OFF convention)', () {
      final item = mapper.mapDetail(_bigMacDetail());

      expect(item, isNotNull);
      final sodiumG100g = item!.nutrimentsJson!['sodium_100g'] as double;
      expect(item.saltG100g, closeTo(sodiumG100g * 2.5, 1e-9));
    });

    test('mg- and µg-basis nutrients read back to FatSecret\'s original '
        'values through the catalog\'s per-100g helper', () {
      final item = mapper.mapDetail(_bigMacDetail());
      expect(item, isNotNull);

      final factor = 100 / 219.0;

      // sodium: 1010 mg in a 219 g serving -> mg per 100g, read back via the
      // catalog helper (spec unit 'mg') should match the scaled raw value.
      final sodiumMg = nutrientPer100g(
        _specFor('sodium'),
        item!.nutrimentsJson,
      );
      expect(sodiumMg, closeTo(1010 * factor, 0.01));

      final potassiumMg = nutrientPer100g(
        _specFor('potassium'),
        item.nutrimentsJson,
      );
      expect(potassiumMg, closeTo(400 * factor, 0.01));

      final cholesterolMg = nutrientPer100g(
        _specFor('cholesterol'),
        item.nutrimentsJson,
      );
      expect(cholesterolMg, closeTo(80 * factor, 0.01));

      final calciumMg = nutrientPer100g(
        _specFor('calcium'),
        item.nutrimentsJson,
      );
      expect(calciumMg, closeTo(120 * factor, 0.01));

      final ironMg = nutrientPer100g(_specFor('iron'), item.nutrimentsJson);
      expect(ironMg, closeTo(4.20 * factor, 0.01));

      final vitaminCMg = nutrientPer100g(
        _specFor('vitamin_c'),
        item.nutrimentsJson,
      );
      expect(vitaminCMg, closeTo(1.0 * factor, 0.01));

      // vitamin A/D: µg basis.
      final vitaminAUg = nutrientPer100g(
        _specFor('vitamin_a'),
        item.nutrimentsJson,
      );
      expect(vitaminAUg, closeTo(80 * factor, 0.01));

      final vitaminDUg = nutrientPer100g(
        _specFor('vitamin_d'),
        item.nutrimentsJson,
      );
      expect(vitaminDUg, closeTo(0.5 * factor, 0.01));
    });

    test('serving as a single object (not a list) is handled', () {
      final food = _bigMacDetail();
      expect((food['servings'] as Map)['serving'], isA<Map>());
      final item = mapper.mapDetail(food);
      expect(item, isNotNull);
    });

    test('food_images as a single object maps into detail image fields', () {
      final food = _bigMacDetail()
        ..['food_images'] = {
          'food_image': {
            'image_url': 'https://images.example/detail.png',
            'image_type': 'Standard',
          },
        };

      final item = mapper.mapDetail(food)!;

      expect(item.imageUrl, 'https://images.example/detail.png');
      expect(item.imageSignature, hasLength(64));
    });

    test('food_images as a list prefers a large display image', () {
      final food = _bigMacDetail()
        ..['food_images'] = {
          'food_image': [
            {
              'image_url': 'https://images.example/isolated.png',
              'image_type': 'Isolated',
            },
            {
              'image_url': 'https://images.example/large.png',
              'image_type': 'Large',
            },
          ],
        };

      final item = mapper.mapDetail(food)!;

      expect(item.imageUrl, 'https://images.example/large.png');
      expect(item.imageSignature, hasLength(64));
    });

    test('no detail image preserves the pre-image hash exactly', () {
      final item = mapper.mapDetail(_bigMacDetail())!;

      expect(item.imageUrl, isNull);
      expect(item.imageSignature, isNull);
      expect(
        item.contentHash,
        '474d65b395ab29f8be7bf1e81ec1611eb990af32d88edba00d86756f67d723ae',
      );
    });

    test('every numeric value in the payload arrives as a string, and '
        'mapping still succeeds', () {
      final serving = ((_bigMacDetail()['servings'] as Map)['serving'] as Map)
          .cast<String, dynamic>();
      for (final key in const [
        'metric_serving_amount',
        'number_of_units',
        'calories',
        'protein',
        'carbohydrate',
        'fat',
        'sodium',
        'vitamin_a',
      ]) {
        expect(serving[key], isA<String>(), reason: '$key should be a string');
      }
      expect(mapper.mapDetail(_bigMacDetail()), isNotNull);
    });

    test('no serving with a usable metric mass yields null (refuses to '
        'invent a weight)', () {
      final food = {
        'food_id': '999',
        'food_name': 'Mystery Item',
        'servings': {
          'serving': [
            {
              'serving_description': '1 serving',
              // No metric_serving_unit/amount at all.
              'calories': '100',
            },
          ],
        },
      };
      expect(mapper.mapDetail(food), isNull);
    });

    test('a serving list with mixed metric units picks the g/ml one', () {
      final food = {
        'food_id': '42',
        'food_name': 'Two Servings',
        'servings': {
          'serving': [
            {
              'serving_description': '1 oz',
              'metric_serving_amount': '28.35',
              'metric_serving_unit': 'oz',
              'measurement_description': 'oz',
              'calories': '100',
            },
            {
              'serving_description': '100 g',
              'metric_serving_amount': '100.000',
              'metric_serving_unit': 'g',
              'measurement_description': 'g',
              'calories': '250',
            },
          ],
        },
      };
      final item = mapper.mapDetail(food);
      expect(item, isNotNull);
      expect(item!.kcal100g, 250);
    });

    test('empty food_id yields no item', () {
      final food = _bigMacDetail();
      food['food_id'] = '';
      expect(mapper.mapDetail(food), isNull);
    });

    Map<String, dynamic> foodWithMeasurement(String measurement) => {
      'food_id': '7',
      'food_name': 'Roast Chicken',
      'servings': {
        'serving': {
          'serving_description': '1 $measurement',
          'metric_serving_amount': '98.000',
          'metric_serving_unit': 'g',
          'number_of_units': '1.000',
          'measurement_description': measurement,
          'calories': '160',
        },
      },
    };

    test('a qualified mass description ("oz, with bone, cooked ...") is not '
        'a countable piece — no piece unit is offered', () {
      final item = mapper.mapDetail(
        foodWithMeasurement('oz, with bone, cooked (yield after bone removed)'),
      );

      expect(item, isNotNull);
      expect(item!.gramsPerPiece, isNull);
      expect(item.pieceUnit, isNull);
      // Falls back to the serving's metric mass for the default amount.
      expect(item.servingSizeG, closeTo(98, 0.001));
    });

    test('"serving (98g)" is a portion size, not a piece', () {
      final item = mapper.mapDetail(foodWithMeasurement('serving (98g)'));

      expect(item, isNotNull);
      expect(item!.gramsPerPiece, isNull);
      expect(item.pieceUnit, isNull);
      expect(item.servingSizeG, closeTo(98, 0.001));
    });

    test('fractional measure counts ("1/2 cup", "1 1/2 cups") are still '
        'masses, not pieces', () {
      for (final measurement in ['1/2 cup', '1 1/2 cups']) {
        final item = mapper.mapDetail(foodWithMeasurement(measurement));
        expect(item, isNotNull, reason: measurement);
        expect(item!.gramsPerPiece, isNull, reason: measurement);
        expect(item.pieceUnit, isNull, reason: measurement);
      }
    });

    test('a fractional count on a genuine piece noun ("1/2 slice") keeps '
        'the piece and the clean label', () {
      final item = mapper.mapDetail(foodWithMeasurement('1/2 slice'));
      expect(item, isNotNull);
      expect(item!.pieceUnit, 'slice');
    });

    test('a qualified piece ("slice, large") stays a piece and its unit '
        'label is the clean head noun', () {
      final item = mapper.mapDetail(foodWithMeasurement('slice, large'));

      expect(item, isNotNull);
      expect(item!.gramsPerPiece, closeTo(98, 0.001));
      expect(item.pieceUnit, 'slice');
    });

    // The backend stores no piece columns; fromBackendDetail re-derives the
    // piece from the raw blob's OFF-style serving_size text. mapDetail plants
    // a synthetic one, so the piece default must survive ingest → reload.
    FoodItem roundTrip(FoodItem item) {
      final payload = item.toBackendPayload()..['id'] = 42;
      return FoodItem.fromBackendDetail(payload);
    }

    test('piece metadata survives the backend round trip', () {
      final item = mapper.mapDetail(_bigMacDetail())!;
      final reloaded = roundTrip(item);

      expect(reloaded.gramsPerPiece, closeTo(219, 0.001));
      expect(reloaded.pieceUnit, 'burger');
      expect(reloaded.servingSizeG, closeTo(219, 0.001));
      // The verbatim FatSecret payload is still intact next to the synthetic
      // serving text.
      final raw = jsonDecode(reloaded.rawSourceJson) as Map<String, dynamic>;
      expect((raw['food'] as Map)['food_id'], '33691');
      expect(raw['serving_size'], '1 burger (219 g)');
    });

    test('a multi-piece serving (3 cookies per 210 g) round-trips to the '
        'same per-piece weight', () {
      final food = {
        'food_id': '55',
        'food_name': 'Choc Cookies',
        'servings': {
          'serving': {
            'serving_description': '3 cookies',
            'metric_serving_amount': '210.000',
            'metric_serving_unit': 'g',
            'number_of_units': '3.000',
            'measurement_description': 'cookies',
            'calories': '900',
          },
        },
      };
      final item = mapper.mapDetail(food)!;
      expect(item.gramsPerPiece, closeTo(70, 0.001));

      final reloaded = roundTrip(item);
      expect(reloaded.gramsPerPiece, closeTo(70, 0.001));
      expect(reloaded.pieceUnit, 'cookie');
    });

    test('a piece-less detail plants no synthetic serving_size', () {
      final item = mapper.mapDetail(foodWithMeasurement('serving (98g)'))!;
      final raw = jsonDecode(item.rawSourceJson) as Map<String, dynamic>;
      expect(raw.containsKey('serving_size'), isFalse);
    });

    test('content hash changes when the measurement description changes '
        'with an unchanged metric amount', () {
      final base = _bigMacDetail();
      final renamed = _bigMacDetail();
      ((renamed['servings'] as Map)['serving']
              as Map<String, dynamic>)['measurement_description'] =
          'sandwich';

      final original = mapper.mapDetail(base)!;
      final updated = mapper.mapDetail(renamed)!;

      // Same 219 g portion, different piece noun: the synthetic serving_size
      // in rawSourceJson changes too, so the hash must change or the check
      // flow would leave the stale text on the backend and reloads would
      // resurrect the old piece unit.
      expect(original.servingSizeG, updated.servingSizeG);
      expect(original.pieceUnit, isNot(updated.pieceUnit));
      expect(original.contentHash, isNot(updated.contentHash));
    });
  });
}
