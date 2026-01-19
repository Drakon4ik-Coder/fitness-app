import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/food_models.dart';
import 'package:fitness_app/features/nutrition/data/foods_api_service.dart';

void main() {
  test('ingestFood preserves unexpected response message', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: null,
            ),
          );
        },
      ),
    );

    final service = FoodsApiService(accessToken: 'token', dio: dio);
    final item = FoodItem(
      source: offSource,
      externalId: '123',
      name: 'Test Food',
      brands: 'Test Brand',
      rawSourceJson: '{}',
    );

    expect(
      () async => await service.ingestFood(item),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'Unexpected response from server.',
        ),
      ),
    );
  });
}
