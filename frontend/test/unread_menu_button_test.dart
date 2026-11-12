// Run with:  flutter test test/unread_menu_button_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/widgets/unread_menu_button.dart';

void main() {
  Future<ValueNotifier<int>> pump(WidgetTester t, int n) async {
    final unread = ValueNotifier<int>(n);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.blue,
        body: Center(child: UnreadMenuButton(unread: unread, onPressed: () {})),
      ),
    ));
    return unread;
  }

  final dot = find.byKey(const ValueKey('menu-unread-dot'));

  testWidgets('no unread → no dot', (t) async {
    await pump(t, 0);
    expect(dot, findsNothing);
  });

  testWidgets('1, 9 or 100 unread → the same dot, never a number', (t) async {
    final unread = await pump(t, 1);
    for (final n in [1, 9, 100]) {
      unread.value = n;
      await t.pump();
      expect(dot, findsOneWidget);
      expect(find.text('$n'), findsNothing);
    }
  });

  testWidgets('dot disappears only when the count reaches 0', (t) async {
    final unread = await pump(t, 2);
    unread.value = 1;
    await t.pump();
    expect(dot, findsOneWidget);
    unread.value = 0;
    await t.pump();
    expect(dot, findsNothing);
  });

  testWidgets('it is a solid red circle', (t) async {
    await pump(t, 3);
    final box = t.widget<Container>(dot).decoration as BoxDecoration;
    expect(box.color, const Color(0xFFE53935));
    expect(box.shape, BoxShape.circle);
  });
}
