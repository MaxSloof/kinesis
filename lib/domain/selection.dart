import 'dart:collection';

/// Tracks selected review items in the ingest grid.
///
/// Items are stored by logical index, while range selection is resolved
/// against the current display order so grouping and sorting match what the
/// user sees.
class MediaSelection {
  final Set<int> _selected = <int>{};
  int? _anchor;

  Set<int> get indices => UnmodifiableSetView(_selected);
  int get length => _selected.length;
  bool get isEmpty => _selected.isEmpty;
  bool get isNotEmpty => _selected.isNotEmpty;

  /// The item a subsequent shift-click extends from.
  int? get anchor => _anchor;

  bool contains(int index) => _selected.contains(index);

  bool containsAll(Iterable<int> indices) =>
      indices.isNotEmpty && indices.every(_selected.contains);

  /// Replaces the selection after the source listing has been rebuilt.
  void replaceWith(Iterable<int> indices) {
    _selected
      ..clear()
      ..addAll(indices);
    _anchor = null;
  }

  void selectAll(Iterable<int> indices) {
    _selected.addAll(indices);
    _anchor = null;
  }

  void removeAll(Iterable<int> indices) {
    final removed = indices.toSet();
    _selected.removeAll(removed);
    if (removed.contains(_anchor)) _anchor = null;
  }

  void clear() {
    _selected.clear();
    _anchor = null;
  }

  /// Drops the range anchor without changing the selected items, for display
  /// order changes such as re-sorting.
  void resetAnchor() => _anchor = null;

  /// Handles a click on [index]. A plain click toggles the item and becomes the
  /// range anchor; [extend] (shift-click) selects every displayed item between
  /// the anchor and [index].
  void tap(int index, {required List<int> displayOrder, required bool extend}) {
    if (!extend) {
      if (!_selected.remove(index)) _selected.add(index);
      _anchor = index;
      return;
    }

    final anchor = _anchor;
    if (anchor == null || anchor == index) {
      _selected.add(index);
      _anchor = index;
      return;
    }

    final anchorPosition = displayOrder.indexOf(anchor);
    final targetPosition = displayOrder.indexOf(index);
    if (anchorPosition < 0 || targetPosition < 0) {
      _selected.add(index);
      _anchor = index;
      return;
    }

    final start = anchorPosition < targetPosition
        ? anchorPosition
        : targetPosition;
    final end = anchorPosition < targetPosition
        ? targetPosition
        : anchorPosition;
    for (var position = start; position <= end; position++) {
      _selected.add(displayOrder[position]);
    }
  }

  /// Selects every index, or clears the group when all of them are selected.
  /// Returns whether the group is selected afterwards.
  bool toggleAll(Iterable<int> indices) {
    final items = indices.toList();
    if (items.isNotEmpty && items.every(_selected.contains)) {
      removeAll(items);
      return false;
    }
    _selected.addAll(items);
    if (items.isNotEmpty) _anchor = items.last;
    return true;
  }
}
