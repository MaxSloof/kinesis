import 'package:flutter/material.dart';

import '../services/camera_cards.dart';

/// Quick picks for mounted camera cards. Detection runs when the widget is
/// first shown and when the user taps refresh; there is no background polling.
class CameraCardPicks extends StatefulWidget {
  const CameraCardPicks({
    super.key,
    required this.onSelected,
    this.enabled = true,
    this.detect = detectCameraCards,
  });

  final ValueChanged<String> onSelected;
  final bool enabled;
  final Future<List<CameraCard>> Function() detect;

  @override
  State<CameraCardPicks> createState() => _CameraCardPicksState();
}

class _CameraCardPicksState extends State<CameraCardPicks> {
  List<CameraCard> _cards = const [];
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    var cards = const <CameraCard>[];
    try {
      cards = await widget.detect();
    } on Object {
      // Detection is a convenience; the folder picker always works.
    }
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final card in _cards)
        ActionChip(
          avatar: const Icon(Icons.sd_card_outlined, size: 18),
          label: Text(card.name),
          tooltip: card.path,
          onPressed: widget.enabled ? () => widget.onSelected(card.path) : null,
        ),
      IconButton(
        onPressed: _checking ? null : _refresh,
        icon: const Icon(Icons.refresh),
        tooltip: 'Look for camera cards',
      ),
    ],
  );
}
