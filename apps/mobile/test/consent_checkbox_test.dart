import 'package:fitness_app/ui_components/consent_checkbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('toggling the checkbox reports the new value', (tester) async {
    bool? reported;
    await _pump(
      tester,
      ConsentCheckbox(
        value: false,
        onChanged: (value) => reported = value,
        label: const TextSpan(text: 'I agree.'),
      ),
    );

    await tester.tap(find.byType(Checkbox));

    expect(reported, isTrue);
  });

  testWidgets('a null onChanged disables the checkbox', (tester) async {
    await _pump(
      tester,
      const ConsentCheckbox(
        value: false,
        onChanged: null,
        label: TextSpan(text: 'I agree.'),
      ),
    );

    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
  });

  testWidgets('inline links fire their tap callback', (tester) async {
    var tapped = false;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ConsentCheckbox(
          value: false,
          onChanged: (_) {},
          label: TextSpan(
            children: [
              const TextSpan(text: 'See the '),
              ConsentCheckbox.link(
                context,
                'terms',
                onTap: () => tapped = true,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('terms'));

    expect(tapped, isTrue);
  });
}
