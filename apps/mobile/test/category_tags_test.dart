import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/add_food_sheet.dart';

void main() {
  test('categoryTagsForQuery strips punctuation', () {
    final tags = categoryTagsForQuery('apple!');

    expect(
      tags,
      unorderedEquals(['en:apple', 'en:apples']),
    );
  });
}
