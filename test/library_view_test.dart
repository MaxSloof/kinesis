import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/main.dart';
import 'package:kinesis/services/media_service.dart';

void main() {
  testWidgets('Library exposes date and size viewing options', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LibraryPage(libraryPath: null, media: MediaService())),
    );
    await tester.pump();

    expect(find.byTooltip('Sort library'), findsOneWidget);
    await tester.tap(find.byTooltip('Sort library'));
    await tester.pumpAndSettle();
    expect(find.text('Capture date (newest)'), findsOneWidget);
    expect(find.text('File size (largest)'), findsOneWidget);
    await tester.tap(find.text('File size (largest)'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Ungroup dates'), findsOneWidget);
    await tester.tap(find.byTooltip('Ungroup dates'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Group by date'), findsOneWidget);
    await tester.tap(find.byTooltip('Group by date'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('Ungroup dates'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
