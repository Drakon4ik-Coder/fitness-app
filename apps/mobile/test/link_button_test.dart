import 'package:fitness_app/ui_components/link_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    // Unbounded Row mirrors the auth-page footers LinkButton lives in.
    return MaterialApp(
      home: Scaffold(body: Row(children: [child])),
    );
  }

  testWidgets('fires onPressed and exposes button semantics', (
    WidgetTester tester,
  ) async {
    final handle = tester.ensureSemantics();
    var pressed = false;
    await tester.pumpWidget(
      wrap(LinkButton(label: 'Tap me', onPressed: () => pressed = true)),
    );

    expect(
      tester.getSemantics(find.text('Tap me')),
      containsSemantics(isButton: true),
    );

    // 44pt minimum touch target even for short labels.
    final size = tester.getSize(find.byType(LinkButton));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));

    await tester.tap(find.byType(LinkButton));
    expect(pressed, isTrue);
    handle.dispose();
  });

  testWidgets('null onPressed disables the button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(const LinkButton(label: 'Disabled', onPressed: null)),
    );

    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.enabled, isFalse);
  });
}
