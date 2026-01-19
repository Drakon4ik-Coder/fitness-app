import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';

void main() {
  test('fetchDay preserves unexpected response message', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: ['unexpected'],
            ),
          );
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);

    expect(
      () async => await service.fetchDay(DateTime(2024, 1, 1)),
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
