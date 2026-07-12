import 'package:fitness_app/features/nutrition/add_food_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('categoryTagsForQuery strips punctuation', () {
    final tags = categoryTagsForQuery('apple!');

    expect(tags, unorderedEquals(['en:apple', 'en:apples']));
  });
}
