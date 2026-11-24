import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/main.dart';

void main() {
  testWidgets('help menu replays the welcome guide to the end', (
    tester,
  ) async {
    await tester.pumpWidget(const KinesisApp());
    await tester.tap(find.byTooltip('Help'));
    await tester.pumpAndSettle();
    expect(find.text('Open on GitHub'), findsOneWidget);

    await tester.tap(find.text('Replay welcome guide'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Kinesis'), findsOneWidget);

    while (find.text('Next').evaluate().isNotEmpty) {
      await tester.tap(find.text('Next'));
      await tester.pump();
    }
    await tester.tap(find.text('Back'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
