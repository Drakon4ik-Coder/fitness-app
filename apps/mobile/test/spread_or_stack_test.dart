import 'package:fitness_app/ui_components/spread_or_stack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpAtWidth(WidgetTester tester, double width) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const SpreadOrStack(
              leading: Text('LABEL', style: TextStyle(fontSize: 10)),
              trailing: Text('99g', style: TextStyle(fontSize: 10)),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shares a line, pushed to opposite edges, while it fits', (
    tester,
  ) async {
    await _pumpAtWidth(tester, 200);

    final leading = tester.getRect(find.text('LABEL'));
    final trailing = tester.getRect(find.text('99g'));
    expect(leading.top, trailing.top);
    expect(leading.left, 0);
    expect(trailing.right, 200);
  });

  testWidgets('stacks trailing under leading once both no longer fit', (
    tester,
  ) async {
    // 5 + 3 test-font glyphs at 10px plus the gap can't share 60px.
    await _pumpAtWidth(tester, 60);

    final leading = tester.getRect(find.text('LABEL'));
    final trailing = tester.getRect(find.text('99g'));
    expect(trailing.top, greaterThanOrEqualTo(leading.bottom));
    expect(trailing.left, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scales a single side wider than the slot instead of clipping', (
    tester,
  ) async {
    await _pumpAtWidth(tester, 30);

    final leading = tester.getRect(find.text('LABEL'));
    expect(leading.width, lessThanOrEqualTo(30));
    expect(tester.takeException(), isNull);
  });
}
