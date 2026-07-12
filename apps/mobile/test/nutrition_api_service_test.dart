import 'package:dio/dio.dart';
import 'package:fitness_app/features/nutrition/data/api_exceptions.dart';
import 'package:fitness_app/features/nutrition/data/nutrition_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fetchDay preserves unexpected response message', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: null),
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

  test('updateEntry PATCHes the entry and parses the response', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'id': 42,
                'meal_type': 'breakfast',
                'consumed_at': '2024-01-01T08:00:00Z',
                'quantity_g': 250,
                'kcal': 500,
                'food_item': {
                  'id': 7,
                  'name': 'Editable Food',
                  'kcal_100g': 200,
                },
              },
            ),
          );
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);
    final entry = await service.updateEntry(entryId: 42, quantityG: 250);

    expect(captured.method, 'PATCH');
    expect(captured.path, '/api/v1/nutrition/entries/42');
    expect(captured.data, {'quantity_g': 250});
    expect(entry.id, 42);
    expect(entry.quantityG, 250);
    expect(entry.kcal, 500);
    expect(entry.foodItem.name, 'Editable Food');
  });

  test('createEntry sends consumed_at as a true UTC instant', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 201,
              data: {
                'id': 1,
                'meal_type': 'lunch',
                'consumed_at': '2024-06-01T11:30:00Z',
                'quantity_g': 100,
                'kcal': 200,
                'food_item': {'id': 7, 'name': 'F', 'kcal_100g': 200},
              },
            ),
          );
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);
    // A local wall-clock time with a +2h offset; the server must receive the
    // equivalent UTC instant (Z-suffixed), not the naive local string.
    final localNoon = DateTime.parse('2024-06-01T13:30:00+02:00');
    await service.createEntry(
      foodItemId: 7,
      mealType: 'lunch',
      quantityG: 100,
      consumedAt: localNoon,
    );

    final sent = (captured.data as Map)['consumed_at'] as String;
    expect(sent, '2024-06-01T11:30:00.000Z');
  });

  test('updateEntry wraps a Dio error in ApiException', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 400),
            ),
          );
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);

    await expectLater(
      () async => service.updateEntry(entryId: 42, quantityG: 0),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          400,
        ),
      ),
    );
  });

  test('deleteEntry DELETEs the entry', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(Response(requestOptions: options, statusCode: 204));
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);
    await service.deleteEntry(entryId: 42);

    expect(captured.method, 'DELETE');
    expect(captured.path, '/api/v1/nutrition/entries/42');
  });

  test('deleteEntry wraps a Dio error in ApiException', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 404),
            ),
          );
        },
      ),
    );

    final service = NutritionApiService(accessToken: 'token', dio: dio);

    await expectLater(
      () async => service.deleteEntry(entryId: 42),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          404,
        ),
      ),
    );
  });
}
