import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fitness_app/features/barcode_lookup_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Shows legacy message on lookup',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BarcodeLookupPage(
          accessToken: 'token',
          onLogout: () async {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Lookup'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Legacy screen'), findsOneWidget);
  });
}
