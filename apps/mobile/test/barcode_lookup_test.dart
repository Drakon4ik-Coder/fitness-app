import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/barcode_lookup_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Shows fetch from OFF message on 404 fetch_external',
      (WidgetTester tester) async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 404,
                data: {'fetch_external': true},
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeLookupPage(
          accessToken: 'token',
          onLogout: () async {},
          dio: dio,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Lookup'));
    await tester.pumpAndSettle();

    expect(find.text('Fetch from OFF (coming next)'), findsOneWidget);
  });
}
