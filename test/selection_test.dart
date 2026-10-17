import 'package:flutter_test/flutter_test.dart';
import 'package:kinesis/domain/selection.dart';

void main() {
  group('MediaSelection', () {
    test('a plain click toggles an item and becomes the range anchor', () {
      final selection = MediaSelection();

      selection.tap(4, displayOrder: [4, 2, 0], extend: false);
      expect(selection.indices, {4});
      expect(selection.anchor, 4);

      selection.tap(2, displayOrder: [4, 2, 0], extend: false);
      expect(selection.indices, {4, 2});
      expect(selection.anchor, 2);

      selection.tap(2, displayOrder: [4, 2, 0], extend: false);
      expect(selection.indices, {4});
      expect(selection.anchor, 2);
    });

    test('a shift-click selects every displayed item in between', () {
      final selection = MediaSelection();
      const displayOrder = [4, 2, 0, 3, 1];

      selection.tap(4, displayOrder: displayOrder, extend: false);
      selection.tap(0, displayOrder: displayOrder, extend: true);

      // Logical indices 4, 2 and 0 are adjacent in the displayed grid, even
      // though the logical order differs.
      expect(selection.indices, {4, 2, 0});
      expect(selection.anchor, 4);
    });

    test('a shift-click extends in either direction and keeps other items', () {
      final selection = MediaSelection();
      const displayOrder = [0, 1, 2, 3, 4];

      selection.tap(1, displayOrder: displayOrder, extend: false);
      selection.tap(3, displayOrder: displayOrder, extend: true);
      expect(selection.indices, {1, 2, 3});

      selection.tap(4, displayOrder: displayOrder, extend: false);
      selection.tap(2, displayOrder: displayOrder, extend: true);
      expect(selection.indices, {1, 3, 4, 2});
      expect(selection.anchor, 4);
    });

    test('a shift-click without an anchor selects the clicked item', () {
      final selection = MediaSelection();

      selection.tap(3, displayOrder: [0, 1, 2, 3], extend: true);

      expect(selection.indices, {3});
      expect(selection.anchor, 3);
    });

    test('a shift-click after re-sorting starts a new range', () {
      final selection = MediaSelection();

      selection.tap(1, displayOrder: [0, 1, 2], extend: false);
      selection.resetAnchor();
      selection.tap(2, displayOrder: [2, 1, 0], extend: true);

      expect(selection.indices, {1, 2});
      expect(selection.anchor, 2);
    });

    test('toggling a date group selects it, then clears it', () {
      final selection = MediaSelection();
      const group = [1, 2, 3];

      selection.tap(5, displayOrder: [1, 2, 3, 5], extend: false);
      expect(selection.toggleAll(group), isTrue);

      expect(selection.indices, {1, 2, 3, 5});
      expect(selection.anchor, 3);

      expect(selection.toggleAll(group), isFalse);
      expect(selection.indices, {5});
      expect(selection.anchor, isNull);
    });

    test('replacing or clearing the selection resets the anchor', () {
      final selection = MediaSelection();
      selection.tap(0, displayOrder: [0, 1], extend: false);
      selection.tap(1, displayOrder: [0, 1], extend: true);

      selection.replaceWith([3]);
      expect(selection.indices, {3});
      expect(selection.anchor, isNull);

      selection.tap(3, displayOrder: [3, 4], extend: false);
      selection.clear();
      expect(selection.indices, isEmpty);
      expect(selection.anchor, isNull);
    });
  });
}
